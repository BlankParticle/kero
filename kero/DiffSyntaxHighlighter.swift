//
//  DiffSyntaxHighlighter.swift
//  kero
//
//  Offline syntax highlighting for the diff viewer. The review documents are
//  read-only and rebuilt wholesale on reload, so instead of running the live
//  Neon plugin over an interleaved diff document (whose mixed old/new lines
//  aren't parseable source), each side of the diff is parsed *as its own
//  file* and the resulting color runs are re-based line-by-line onto the
//  rendered documents. Removed lines get the old file's colors, added and
//  context lines the new file's — the same per-side model web diff renderers
//  use, with the editor's exact grammars and theme.
//

import AppKit
import STPluginNeon
import SwiftTreeSitter

/// One foreground-color run in a source file (UTF-16 offsets).
nonisolated struct DiffHighlightRun {
    let range: NSRange
    let color: NSColor
}

/// Inputs the off-main highlight pass needs from the main actor: the resolved
/// language and its compiled query (shared with the editor's cache), plus the
/// theme used to map capture names to colors.
struct DiffHighlightContext {
    let language: SyntaxLanguage
    let query: SwiftTreeSitter.Query
    let theme: STPluginNeonAppKit.Theme
}

enum DiffSyntaxHighlighter {
    /// Per-side texts beyond this size skip highlighting; the diff still
    /// renders, plain. Whole-file query execution over multi-megabyte
    /// generated files costs seconds for colors nobody reads.
    nonisolated static let highlightByteLimit = 1_500_000

    /// Resolves the language and compiled highlights query for `path`,
    /// compiling (off the main thread) and caching on first use. Returns nil
    /// for file types without a grammar — the diff renders unhighlighted.
    static func context(for path: String) async -> DiffHighlightContext? {
        guard let language = SyntaxHighlighting.language(for: path) else { return nil }
        let theme = SyntaxHighlighting.theme
        if let cached = HighlightQueryCache.cached(language) {
            return DiffHighlightContext(language: language, query: cached, theme: theme)
        }
        let data = SyntaxHighlighting.highlightsData(for: language)
        let parser = language.parser
        let query = await Task.detached(priority: .userInitiated) {
            try? SwiftTreeSitter.Query(language: Language(language: parser), data: data)
        }.value
        guard let query else { return nil }
        HighlightQueryCache.store(query, for: language)
        return DiffHighlightContext(language: language, query: query, theme: theme)
    }

    /// Whole-file highlight runs for one side's text. Pure compute — parse,
    /// query, capture→color — meant for a detached task.
    nonisolated static func runs(
        text: String, context: DiffHighlightContext
    ) -> [DiffHighlightRun] {
        guard !text.isEmpty, text.utf8.count <= highlightByteLimit else { return [] }
        let parser = Parser()
        do {
            try parser.setLanguage(context.language.parser)
        } catch {
            return []
        }
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [] }

        let predicateContext = SwiftTreeSitter.Predicate.Context(string: text)
        var runs: [DiffHighlightRun] = []
        for named in context.query.execute(node: root, in: tree)
            .resolve(with: predicateContext).highlights() {
            guard named.range.length > 0,
                  !SyntaxCaptureStyle.ignoredCaptures.contains(named.name),
                  let color = SyntaxCaptureStyle.color(for: named.name, theme: context.theme)
            else { continue }
            runs.append(DiffHighlightRun(range: named.range, color: color))
        }
        return runs
    }

    /// Builds the document's attributed text: base attributes over the whole
    /// string, then each row colored by the runs of its own source file.
    nonisolated static func attributedDocument(
        _ document: DiffSideDocument,
        oldRuns: [DiffHighlightRun],
        newRuns: [DiffHighlightRun],
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: document.text, attributes: baseAttributes
        )
        applyRuns(oldRuns, source: .old, to: attributed, document: document)
        applyRuns(newRuns, source: .new, to: attributed, document: document)
        return attributed
    }

    /// Bakes an edit-mode ghost block: the removed lines' text with the old
    /// file's syntax colors and word-level emphasis as background color,
    /// ready for the decoration underlay to draw into the ghost gap. Uses the
    /// same forward-pointer walk as `applyRuns` (block lines ascend through
    /// the old file), which stays correct for multi-line runs.
    nonisolated static func attributedGhostLines(
        oldText: NSString,
        block: DiffEditGhostBlock,
        runs: [DiffHighlightRun],
        baseAttributes: [NSAttributedString.Key: Any],
        emphasisColor: NSColor
    ) -> [NSAttributedString] {
        var first = 0
        return block.lines.map { line in
            let attributed = NSMutableAttributedString(
                string: oldText.substring(with: line.sourceRange),
                attributes: baseAttributes
            )
            let lineStart = line.sourceRange.location
            let lineEnd = lineStart + line.sourceRange.length

            while first < runs.count,
                  runs[first].range.location + runs[first].range.length <= lineStart {
                first += 1
            }
            var index = first
            while index < runs.count {
                let run = runs[index]
                index += 1
                if run.range.location >= lineEnd { break }
                let overlapStart = max(run.range.location, lineStart)
                let overlapEnd = min(run.range.location + run.range.length, lineEnd)
                guard overlapEnd > overlapStart else { continue }
                attributed.addAttribute(
                    .foregroundColor,
                    value: run.color,
                    range: NSRange(
                        location: overlapStart - lineStart, length: overlapEnd - overlapStart
                    )
                )
            }
            for emphasis in line.emphasis {
                let clamped = NSIntersectionRange(
                    emphasis, NSRange(location: 0, length: line.sourceRange.length)
                )
                guard clamped.length > 0 else { continue }
                attributed.addAttribute(.backgroundColor, value: emphasisColor, range: clamped)
            }
            return attributed
        }
    }

    /// Merge-walk of one side's runs against that side's rows. Both are
    /// ordered by source position (rows sourced from one file appear in file
    /// order in every diff document), so a forward pointer suffices; it only
    /// passes a run once that run can no longer overlap any later row. Runs
    /// are position-ordered with later captures painting over earlier ones on
    /// overlap — sequential `addAttribute` preserves that. Multi-line runs
    /// (block comments, strings) overlap several rows and are re-applied to
    /// each.
    private nonisolated static func applyRuns(
        _ runs: [DiffHighlightRun],
        source: DiffRowSource,
        to attributed: NSMutableAttributedString,
        document: DiffSideDocument
    ) {
        guard !runs.isEmpty else { return }
        var first = 0
        for (rowIndex, row) in document.rows.enumerated()
        where row.source == source && row.sourceRange.length > 0 {
            let rowStart = row.sourceRange.location
            let rowEnd = rowStart + row.sourceRange.length
            let documentStart = document.lineStartOffsets[rowIndex]

            // Runs wholly before this row can never overlap a later row.
            while first < runs.count,
                  runs[first].range.location + runs[first].range.length <= rowStart {
                first += 1
            }
            var index = first
            while index < runs.count {
                let run = runs[index]
                index += 1
                if run.range.location >= rowEnd { break }
                let overlapStart = max(run.range.location, rowStart)
                let overlapEnd = min(run.range.location + run.range.length, rowEnd)
                guard overlapEnd > overlapStart else { continue }
                attributed.addAttribute(
                    .foregroundColor,
                    value: run.color,
                    range: NSRange(
                        location: documentStart + (overlapStart - rowStart),
                        length: overlapEnd - overlapStart
                    )
                )
            }
        }
    }
}
