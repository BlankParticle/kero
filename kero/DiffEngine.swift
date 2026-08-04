//
//  DiffEngine.swift
//  kero
//
//  Native diff computation for the diff viewer: line-level diff, word-level
//  intraline highlights, and the row/document models the STTextView-based
//  viewer renders. Everything here is pure and nonisolated so a diff can be
//  computed off the main actor.
//

import Foundation

// MARK: - Line model

/// One line of a file, sliced out of the original string without copying.
/// `utf16Range` addresses the line's content (no terminator) in the source
/// string, so highlight runs computed against the whole file can be re-based
/// onto diff documents.
nonisolated struct DiffSourceLine {
    let text: Substring
    let utf16Range: NSRange
}

nonisolated enum DiffLineSplitter {
    /// Splits on `\n` only (git content normalizes nothing; a `\r` stays part
    /// of the line and renders as-is, matching `git diff`). A trailing
    /// newline's phantom empty last component is dropped — it is a terminator,
    /// not a line. `hasTrailingNewline` preserves the distinction so callers
    /// can still detect "\ No newline at end of file" changes.
    static func lines(of text: String) -> (lines: [DiffSourceLine], hasTrailingNewline: Bool) {
        var lines: [DiffSourceLine] = []
        var lineStart = text.startIndex
        var utf16Offset = 0
        let end = text.endIndex
        var index = lineStart
        while index < end {
            if text[index] == "\n" {
                let content = text[lineStart..<index]
                let length = content.utf16.count
                lines.append(DiffSourceLine(
                    text: content,
                    utf16Range: NSRange(location: utf16Offset, length: length)
                ))
                utf16Offset += length + 1
                index = text.index(after: index)
                lineStart = index
            } else {
                index = text.index(after: index)
            }
        }
        let hasTrailingNewline = !text.isEmpty && lineStart == end
        if !hasTrailingNewline && !text.isEmpty {
            let content = text[lineStart..<end]
            lines.append(DiffSourceLine(
                text: content,
                utf16Range: NSRange(location: utf16Offset, length: content.utf16.count)
            ))
        }
        return (lines, hasTrailingNewline)
    }
}

// MARK: - Line diff

/// A run of consecutive lines with one fate. Offsets index the line arrays.
nonisolated enum DiffLineOp: Equatable {
    case equal(oldStart: Int, newStart: Int, count: Int)
    case delete(oldStart: Int, count: Int)
    case insert(newStart: Int, count: Int)
}

/// Line-level diff tuned for real-world source files:
///
/// 1. Common prefix/suffix trimming — the dominant case (a small edit in a
///    large file) collapses to a tiny middle region.
/// 2. Patience anchoring — lines unique to both sides pin the alignment, then
///    each gap recurses. Bounded and fast even when the middle is huge (e.g.
///    a regenerated lockfile), and it produces the readable, structure-aware
///    splits patience diff is known for.
/// 3. Myers for small gaps — optimal diffs where it's affordable; gaps too
///    large for Myers *with no unique anchors* degrade to whole-block
///    replace, which is also what such content (minified/generated text)
///    reads best as.
nonisolated enum DiffEngine {
    /// Gaps at most this many lines per side go to Myers; larger anchor-free
    /// gaps become a single replace block. Myers is O((N+M)·D), so the worst
    /// case here stays around a few million steps.
    private static let myersLimit = 700

    static func lineOps(old: [DiffSourceLine], new: [DiffSourceLine]) -> [DiffLineOp] {
        var builder = OpsBuilder()
        // Hash once: line equality during the diff is then integer comparison
        // with a rare full-text confirmation on hash collisions.
        let oldHashes = old.map { $0.text.hashValue }
        let newHashes = new.map { $0.text.hashValue }
        let oldTexts = old.map(\.text)
        let newTexts = new.map(\.text)
        let context = Context(
            oldHashes: oldHashes, newHashes: newHashes,
            oldTexts: oldTexts, newTexts: newTexts
        )
        diffRegion(
            context, old: 0..<old.count, new: 0..<new.count, into: &builder
        )
        let ops = builder.finish()
        #if DEBUG
        assertReconstructs(ops: ops, oldCount: old.count, newCount: new.count)
        #endif
        return ops
    }

    private struct Context {
        let oldHashes: [Int]
        let newHashes: [Int]
        let oldTexts: [Substring]
        let newTexts: [Substring]

        func linesEqual(_ oldIndex: Int, _ newIndex: Int) -> Bool {
            oldHashes[oldIndex] == newHashes[newIndex]
                && oldTexts[oldIndex] == newTexts[newIndex]
        }
    }

    /// Accumulates ops while merging adjacent runs of the same kind, so the
    /// recursive splits can emit freely.
    private struct OpsBuilder {
        private var ops: [DiffLineOp] = []

        mutating func equal(oldStart: Int, newStart: Int, count: Int) {
            guard count > 0 else { return }
            if case .equal(let o, let n, let c) = ops.last,
               o + c == oldStart, n + c == newStart {
                ops[ops.count - 1] = .equal(oldStart: o, newStart: n, count: c + count)
            } else {
                ops.append(.equal(oldStart: oldStart, newStart: newStart, count: count))
            }
        }

        mutating func delete(oldStart: Int, count: Int) {
            guard count > 0 else { return }
            if case .delete(let o, let c) = ops.last, o + c == oldStart {
                ops[ops.count - 1] = .delete(oldStart: o, count: c + count)
            } else {
                ops.append(.delete(oldStart: oldStart, count: count))
            }
        }

        mutating func insert(newStart: Int, count: Int) {
            guard count > 0 else { return }
            if case .insert(let n, let c) = ops.last, n + c == newStart {
                ops[ops.count - 1] = .insert(newStart: n, count: c + count)
            } else {
                ops.append(.insert(newStart: newStart, count: count))
            }
        }

        /// Reorders each changed block to deletes-then-inserts (the shape the
        /// viewer renders) without moving blocks across equal runs.
        func finish() -> [DiffLineOp] {
            var result: [DiffLineOp] = []
            result.reserveCapacity(ops.count)
            var pendingInserts: [DiffLineOp] = []
            for op in ops {
                switch op {
                case .equal:
                    result.append(contentsOf: pendingInserts)
                    pendingInserts.removeAll(keepingCapacity: true)
                    result.append(op)
                case .delete:
                    result.append(op)
                case .insert:
                    pendingInserts.append(op)
                }
            }
            result.append(contentsOf: pendingInserts)
            return result
        }
    }

    private static func diffRegion(
        _ context: Context, old: Range<Int>, new: Range<Int>, into builder: inout OpsBuilder
    ) {
        var old = old
        var new = new

        // Common prefix.
        var prefixCount = 0
        while prefixCount < old.count, prefixCount < new.count,
              context.linesEqual(old.lowerBound + prefixCount, new.lowerBound + prefixCount) {
            prefixCount += 1
        }
        if prefixCount > 0 {
            builder.equal(oldStart: old.lowerBound, newStart: new.lowerBound, count: prefixCount)
            old = (old.lowerBound + prefixCount)..<old.upperBound
            new = (new.lowerBound + prefixCount)..<new.upperBound
        }

        // Common suffix. Emitted only after the middle is diffed, to keep
        // output ordered.
        var suffixCount = 0
        while suffixCount < old.count, suffixCount < new.count,
              context.linesEqual(old.upperBound - 1 - suffixCount, new.upperBound - 1 - suffixCount) {
            suffixCount += 1
        }
        let suffixOldStart = old.upperBound - suffixCount
        let suffixNewStart = new.upperBound - suffixCount
        old = old.lowerBound..<suffixOldStart
        new = new.lowerBound..<suffixNewStart

        defer {
            builder.equal(oldStart: suffixOldStart, newStart: suffixNewStart, count: suffixCount)
        }

        if old.isEmpty && new.isEmpty {
            return
        }
        if old.isEmpty {
            builder.insert(newStart: new.lowerBound, count: new.count)
            return
        }
        if new.isEmpty {
            builder.delete(oldStart: old.lowerBound, count: old.count)
            return
        }

        if old.count <= myersLimit && new.count <= myersLimit {
            myersDiff(context, old: old, new: new, into: &builder)
            return
        }

        let anchors = patienceAnchors(context, old: old, new: new)
        guard !anchors.isEmpty else {
            // A huge region with no unique common line: generated content.
            // Optimal alignment is unaffordable and would not read better.
            builder.delete(oldStart: old.lowerBound, count: old.count)
            builder.insert(newStart: new.lowerBound, count: new.count)
            return
        }

        var oldCursor = old.lowerBound
        var newCursor = new.lowerBound
        for anchor in anchors {
            diffRegion(
                context,
                old: oldCursor..<anchor.oldIndex,
                new: newCursor..<anchor.newIndex,
                into: &builder
            )
            builder.equal(oldStart: anchor.oldIndex, newStart: anchor.newIndex, count: 1)
            oldCursor = anchor.oldIndex + 1
            newCursor = anchor.newIndex + 1
        }
        diffRegion(
            context, old: oldCursor..<old.upperBound, new: newCursor..<new.upperBound, into: &builder
        )
    }

    // MARK: Patience anchors

    private struct Anchor {
        let oldIndex: Int
        let newIndex: Int
    }

    /// Lines that appear exactly once on each side, matched up, then reduced
    /// to their longest increasing subsequence so the anchors are mutually
    /// consistent.
    private static func patienceAnchors(
        _ context: Context, old: Range<Int>, new: Range<Int>
    ) -> [Anchor] {
        struct Occurrence {
            var oldIndex = -1
            var oldCount = 0
            var newIndex = -1
            var newCount = 0
        }
        // Keyed by hash; a collision can merge two distinct lines and either
        // inflate a count (anchor discarded — harmless) or pair different
        // lines, so candidate pairs are text-confirmed below.
        var table: [Int: Occurrence] = [:]
        table.reserveCapacity(min(old.count + new.count, 4096))
        for index in old {
            table[context.oldHashes[index], default: Occurrence()].oldCount += 1
            table[context.oldHashes[index]]?.oldIndex = index
        }
        for index in new {
            table[context.newHashes[index], default: Occurrence()].newCount += 1
            table[context.newHashes[index]]?.newIndex = index
        }

        var candidates: [Anchor] = []
        for occurrence in table.values
        where occurrence.oldCount == 1 && occurrence.newCount == 1 {
            guard context.linesEqual(occurrence.oldIndex, occurrence.newIndex) else { continue }
            candidates.append(Anchor(oldIndex: occurrence.oldIndex, newIndex: occurrence.newIndex))
        }
        candidates.sort { $0.oldIndex < $1.oldIndex }
        guard !candidates.isEmpty else { return [] }

        // Longest increasing subsequence by newIndex (patience sorting).
        var pileTops: [Int] = [] // candidate index of the top of each pile
        var previous = [Int](repeating: -1, count: candidates.count)
        for (index, candidate) in candidates.enumerated() {
            var lo = 0
            var hi = pileTops.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidates[pileTops[mid]].newIndex < candidate.newIndex {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            if lo > 0 {
                previous[index] = pileTops[lo - 1]
            }
            if lo == pileTops.count {
                pileTops.append(index)
            } else {
                pileTops[lo] = index
            }
        }

        var chain: [Anchor] = []
        var cursor = pileTops.last ?? -1
        while cursor >= 0 {
            chain.append(candidates[cursor])
            cursor = previous[cursor]
        }
        return chain.reversed()
    }

    // MARK: Myers

    /// Classic greedy O((N+M)·D) Myers over a small region, emitting ops by
    /// backtracking the trace. Region sizes are capped by `myersLimit`.
    private static func myersDiff(
        _ context: Context, old: Range<Int>, new: Range<Int>, into builder: inout OpsBuilder
    ) {
        let n = old.count
        let m = new.count
        let maxD = n + m
        let offset = maxD
        // v[k + offset] = furthest x on diagonal k
        var v = [Int](repeating: 0, count: 2 * maxD + 1)
        var trace: [[Int]] = []

        var foundD = -1
        outer: for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset] // down: insert
                } else {
                    x = v[k - 1 + offset] + 1 // right: delete
                }
                var y = x - k
                while x < n, y < m,
                      context.linesEqual(old.lowerBound + x, new.lowerBound + y) {
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n, y >= m {
                    foundD = d
                    break outer
                }
                k += 2
            }
        }
        precondition(foundD >= 0, "Myers must terminate at d ≤ n+m")

        // Backtrack from (n, m) to (0, 0), collecting steps in reverse.
        enum Step { case equalOne, deleteOne, insertOne }
        var steps: [Step] = []
        var x = n
        var y = m
        var d = foundD
        while d > 0 {
            let vPrev = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vPrev[k - 1 + offset] < vPrev[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vPrev[prevK + offset]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                steps.append(.equalOne)
                x -= 1
                y -= 1
            }
            if x == prevX {
                steps.append(.insertOne)
                y -= 1
            } else {
                steps.append(.deleteOne)
                x -= 1
            }
            d -= 1
        }
        while x > 0, y > 0 {
            steps.append(.equalOne)
            x -= 1
            y -= 1
        }
        while x > 0 {
            steps.append(.deleteOne)
            x -= 1
        }
        while y > 0 {
            steps.append(.insertOne)
            y -= 1
        }

        var oldCursor = old.lowerBound
        var newCursor = new.lowerBound
        for step in steps.reversed() {
            switch step {
            case .equalOne:
                builder.equal(oldStart: oldCursor, newStart: newCursor, count: 1)
                oldCursor += 1
                newCursor += 1
            case .deleteOne:
                builder.delete(oldStart: oldCursor, count: 1)
                oldCursor += 1
            case .insertOne:
                builder.insert(newStart: newCursor, count: 1)
                newCursor += 1
            }
        }
    }

    #if DEBUG
    /// The one invariant every correct line diff satisfies: walking the ops
    /// consumes both sides exactly once, in order.
    private static func assertReconstructs(ops: [DiffLineOp], oldCount: Int, newCount: Int) {
        var oldCovered = 0
        var newCovered = 0
        for op in ops {
            switch op {
            case .equal(let oldStart, let newStart, let count):
                assert(oldStart == oldCovered && newStart == newCovered, "equal op out of order")
                oldCovered += count
                newCovered += count
            case .delete(let oldStart, let count):
                assert(oldStart == oldCovered, "delete op out of order")
                oldCovered += count
            case .insert(let newStart, let count):
                assert(newStart == newCovered, "insert op out of order")
                newCovered += count
            }
        }
        assert(oldCovered == oldCount && newCovered == newCount, "diff does not cover both files")
    }
    #endif
}

// MARK: - Intraline (word-level) diff

/// Character ranges (relative to each line's own content) that differ within
/// a paired removed/added line.
nonisolated struct DiffIntralineResult {
    var oldRanges: [NSRange]
    var newRanges: [NSRange]
}

nonisolated enum DiffIntraline {
    /// Lines longer than this (in tokens) skip word diffing: the pairing is
    /// almost certainly generated content where per-word emphasis is noise.
    private static let tokenLimit = 400
    /// If more than this fraction of both lines changed, the pair reads as a
    /// rewrite; per-word emphasis would highlight nearly everything.
    private static let noiseThreshold = 0.66

    /// A token is a run of alphanumerics (plus `_`), a run of spaces/tabs, or
    /// a single other character. Ranges are UTF-16, line-relative.
    private static func tokenize(_ line: Substring) -> [(text: Substring, range: NSRange)] {
        var tokens: [(Substring, NSRange)] = []
        var utf16Offset = 0
        var index = line.startIndex

        func kind(_ character: Character) -> Int {
            if character.isLetter || character.isNumber || character == "_" { return 0 }
            if character == " " || character == "\t" { return 1 }
            return 2
        }

        while index < line.endIndex {
            let start = index
            let startOffset = utf16Offset
            let tokenKind = kind(line[index])
            utf16Offset += line[index].utf16.count
            index = line.index(after: index)
            if tokenKind != 2 {
                while index < line.endIndex, kind(line[index]) == tokenKind {
                    utf16Offset += line[index].utf16.count
                    index = line.index(after: index)
                }
            }
            tokens.append((line[start..<index], NSRange(
                location: startOffset, length: utf16Offset - startOffset
            )))
        }
        return tokens
    }

    /// Word-level diff for one removed/added line pair, or nil when emphasis
    /// would be noise. Token sequences are diffed with the same Myers used for
    /// lines (token counts are small).
    static func diff(old: Substring, new: Substring) -> DiffIntralineResult? {
        guard old != new else { return nil }
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard oldTokens.count <= tokenLimit, newTokens.count <= tokenLimit,
              !oldTokens.isEmpty, !newTokens.isEmpty
        else { return nil }

        var builder = TokenOpsBuilder()
        myersTokens(
            oldTexts: oldTokens.map(\.text),
            newTexts: newTokens.map(\.text),
            into: &builder
        )
        let ops = builder.ops

        var oldRanges: [NSRange] = []
        var newRanges: [NSRange] = []
        var changedOld = 0
        var changedNew = 0
        for op in ops {
            switch op {
            case .equal:
                break
            case .delete(let start, let count):
                let union = unionRange(oldTokens[start..<(start + count)].map(\.range))
                oldRanges.append(union)
                changedOld += union.length
            case .insert(let start, let count):
                let union = unionRange(newTokens[start..<(start + count)].map(\.range))
                newRanges.append(union)
                changedNew += union.length
            }
        }

        let oldLength = max(1, old.utf16.count)
        let newLength = max(1, new.utf16.count)
        if Double(changedOld) / Double(oldLength) > noiseThreshold,
           Double(changedNew) / Double(newLength) > noiseThreshold {
            return nil
        }
        // Merge ranges separated by nothing (adjacent) so emphasis rectangles
        // don't splinter.
        return DiffIntralineResult(
            oldRanges: mergeAdjacent(oldRanges),
            newRanges: mergeAdjacent(newRanges)
        )
    }

    private struct TokenOpsBuilder {
        var ops: [DiffLineOp] = []

        mutating func equal(_ count: Int) {
            guard count > 0 else { return }
            appendMerged(.equal(oldStart: nextOld, newStart: nextNew, count: count))
        }
        mutating func delete(_ count: Int) {
            guard count > 0 else { return }
            appendMerged(.delete(oldStart: nextOld, count: count))
        }
        mutating func insert(_ count: Int) {
            guard count > 0 else { return }
            appendMerged(.insert(newStart: nextNew, count: count))
        }

        private var nextOld = 0
        private var nextNew = 0

        private mutating func appendMerged(_ op: DiffLineOp) {
            switch op {
            case .equal(_, _, let count):
                if case .equal(let o, let n, let c) = ops.last {
                    ops[ops.count - 1] = .equal(oldStart: o, newStart: n, count: c + count)
                } else {
                    ops.append(op)
                }
                nextOld += count
                nextNew += count
            case .delete(_, let count):
                if case .delete(let o, let c) = ops.last {
                    ops[ops.count - 1] = .delete(oldStart: o, count: c + count)
                } else {
                    ops.append(op)
                }
                nextOld += count
            case .insert(_, let count):
                if case .insert(let n, let c) = ops.last {
                    ops[ops.count - 1] = .insert(newStart: n, count: c + count)
                } else {
                    ops.append(op)
                }
                nextNew += count
            }
        }
    }

    /// Myers on token sequences; same algorithm as the line version, kept
    /// separate because the inputs and the builder are simpler.
    private static func myersTokens(
        oldTexts: [Substring], newTexts: [Substring],
        into builder: inout TokenOpsBuilder
    ) {
        func equalTokens(_ oldIndex: Int, _ newIndex: Int) -> Bool {
            oldTexts[oldIndex] == newTexts[newIndex]
        }

        let n = oldTexts.count
        let m = newTexts.count
        let maxD = n + m
        let offset = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 1)
        var trace: [[Int]] = []

        var foundD = -1
        outer: for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]
                } else {
                    x = v[k - 1 + offset] + 1
                }
                var y = x - k
                while x < n, y < m, equalTokens(x, y) {
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n, y >= m {
                    foundD = d
                    break outer
                }
                k += 2
            }
        }
        precondition(foundD >= 0)

        enum Step { case equalOne, deleteOne, insertOne }
        var steps: [Step] = []
        var x = n
        var y = m
        var d = foundD
        while d > 0 {
            let vPrev = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vPrev[k - 1 + offset] < vPrev[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vPrev[prevK + offset]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                steps.append(.equalOne)
                x -= 1
                y -= 1
            }
            if x == prevX {
                steps.append(.insertOne)
                y -= 1
            } else {
                steps.append(.deleteOne)
                x -= 1
            }
            d -= 1
        }
        while x > 0, y > 0 {
            steps.append(.equalOne)
            x -= 1
            y -= 1
        }
        while x > 0 { steps.append(.deleteOne); x -= 1 }
        while y > 0 { steps.append(.insertOne); y -= 1 }

        for step in steps.reversed() {
            switch step {
            case .equalOne: builder.equal(1)
            case .deleteOne: builder.delete(1)
            case .insertOne: builder.insert(1)
            }
        }
    }

    private static func unionRange(_ ranges: [NSRange]) -> NSRange {
        guard let first = ranges.first else { return NSRange(location: 0, length: 0) }
        var union = first
        for range in ranges.dropFirst() {
            union = NSUnionRange(union, range)
        }
        return union
    }

    private static func mergeAdjacent(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.location <= last.location + last.length {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

// MARK: - Diff rows and documents

/// What one visible row of the diff is.
nonisolated enum DiffRowKind {
    case context
    case removed
    case added
    /// Split view only: blank spacer opposite the other side's extra lines.
    case filler
    /// Stands in for a folded run of unmodified lines; expandable.
    case collapsed
}

/// Metadata carried by a `.collapsed` row.
nonisolated struct DiffCollapsedRun: Equatable {
    /// Where a click reveals lines, fixed by the gap's position in the file
    /// (ported from Pierre's separator buttons).
    enum Direction: Equatable {
        /// Gap above the first change: reveal from the hidden range's end,
        /// growing upward from the content below.
        case revealUp
        /// Gap after the last change: reveal from the hidden range's start,
        /// growing downward from the content above.
        case revealDown
        /// Gap between changes: reveal a chunk at both edges.
        case both
    }

    /// How many unmodified lines the row still hides.
    let hiddenLines: Int
    /// Stable identity of the equal run within the diff (ordinal of the equal
    /// run in the op stream), used to record expansion.
    let runIndex: Int
    let direction: Direction
}

/// Lines a fold has revealed at each edge of its hidden range. Mirrors
/// Pierre's `expandedHunks` entries: counters accumulate per click and the
/// fold disappears once they cover the range.
nonisolated struct DiffRunExpansion: Equatable {
    var fromStart = 0
    var fromEnd = 0
}

/// A block of removed lines shown as read-only ghosts in edit mode, anchored
/// to the new-file line it precedes. Mirrors Pierre's editable diffs, where
/// the buffer holds only the new file and deletions are render-layer rows.
nonisolated struct DiffEditGhostBlock {
    struct Line {
        /// The line's content range in the *old* file (UTF-16, no terminator).
        let sourceRange: NSRange
        /// Word-level changed spans, relative to the line's own content.
        let emphasis: [NSRange]
    }

    /// 0-based new-file line index the block sits in front of; a value equal
    /// to the new file's line count marks a deletion at end-of-file.
    let anchorLine: Int
    /// 1-based old-file number of the first ghost line.
    let firstOldLine: Int
    let lines: [Line]
}

/// Live decorations for the edit-mode buffer (the plain new file).
nonisolated struct DiffEditState {
    let addedLines: [Int]
    /// New-file line index → word-level changed spans (line-relative).
    let addedEmphasis: [Int: [NSRange]]
    let ghosts: [DiffEditGhostBlock]
}

/// How much context stays visible around changes, and how folding behaves —
/// constants ported from Pierre's diff renderer defaults.
nonisolated enum DiffCollapse {
    /// Unmodified lines kept visible on each side of a change.
    static let contextLines = 3
    /// Lines revealed per expander click (Pierre's `expansionLineCount`).
    static let expansionLineCount = 100
    /// Gaps of at most this many lines render inline instead of folding
    /// (Pierre's `collapsedContextThreshold`). Applies to the original gap;
    /// a partially expanded fold persists down to its last hidden line.
    static let inlineGapThreshold = 1
}

/// Which original file a row's text was sliced from, for re-basing that
/// file's syntax-highlight runs onto the rendered document.
nonisolated enum DiffRowSource {
    case old
    case new
    case none
}

/// One row of a rendered diff document.
nonisolated struct DiffRow {
    let kind: DiffRowKind
    /// 1-based line numbers in each file; nil when the row has no line on
    /// that side.
    let oldLine: Int?
    let newLine: Int?
    let source: DiffRowSource
    /// The row's content range in its source file (UTF-16, no terminator).
    let sourceRange: NSRange
    /// Word-level changed spans, relative to the row's own content.
    var emphasis: [NSRange]
    /// True on the last line of a side that does not end with a newline while
    /// the other side does (or the file's own terminator was removed/added).
    var missingNewline: Bool
    /// Present on `.collapsed` rows only.
    var collapsed: DiffCollapsedRun? = nil
}

/// A full document the viewer hands to one STTextView: the joined text plus
/// per-row metadata aligned with its paragraphs.
nonisolated struct DiffSideDocument {
    let text: String
    let rows: [DiffRow]
    /// UTF-16 offset of each row's first character in `text`; one entry per
    /// row. Row i spans `lineStart[i] ..< lineStart[i] + length(i)`.
    let lineStartOffsets: [Int]
}

/// The content-derived half of a diff — line arrays, ops, and the
/// trailing-newline adjustment — computed once per old/new pair and cached so
/// expanding a folded run only rebuilds documents, not the diff itself.
nonisolated struct DiffCore {
    let oldLines: [DiffSourceLine]
    let newLines: [DiffSourceLine]
    let ops: [DiffLineOp]
    let oldMissingNewline: Bool
    let newMissingNewline: Bool

    static func compute(oldText: String, newText: String) -> DiffCore {
        let (oldLines, oldTrailing) = DiffLineSplitter.lines(of: oldText)
        let (newLines, newTrailing) = DiffLineSplitter.lines(of: newText)
        var ops = DiffEngine.lineOps(old: oldLines, new: newLines)

        // A trailing-newline difference is a real change to the last line that
        // line-splitting hides. Convert the final shared line into a
        // removed/added pair so it surfaces.
        var oldMissingNewline = false
        var newMissingNewline = false
        if oldTrailing != newTrailing, !oldLines.isEmpty, !newLines.isEmpty {
            oldMissingNewline = !oldTrailing
            newMissingNewline = !newTrailing
            if case .equal(let oldStart, let newStart, let count) = ops.last,
               oldStart + count == oldLines.count, newStart + count == newLines.count {
                ops.removeLast()
                if count > 1 {
                    ops.append(.equal(oldStart: oldStart, newStart: newStart, count: count - 1))
                }
                ops.append(.delete(oldStart: oldLines.count - 1, count: 1))
                ops.append(.insert(newStart: newLines.count - 1, count: 1))
            }
        }

        return DiffCore(
            oldLines: oldLines,
            newLines: newLines,
            ops: ops,
            oldMissingNewline: oldMissingNewline,
            newMissingNewline: newMissingNewline
        )
    }
}

/// Everything the viewer needs for one old/new content pair, precomputed off
/// the main actor: the shared line diff plus unified and split documents.
nonisolated struct DiffComputation {
    let unified: DiffSideDocument
    let splitLeft: DiffSideDocument
    let splitRight: DiffSideDocument
    /// Live decorations for the edit-mode buffer: added lines, word-level
    /// emphasis, and read-only deletion ghost blocks.
    let editState: DiffEditState

    /// Builds the rendered documents. `expansions` carries how far each
    /// folded run has been revealed (keyed by `DiffCollapsedRun.runIndex`);
    /// pass nil to disable folding entirely and render every line.
    static func build(core: DiffCore, expansions: [Int: DiffRunExpansion]?) -> DiffComputation {
        let blocks = DiffBlocks(ops: core.ops)
        let unified = buildUnified(
            blocks: blocks, oldLines: core.oldLines, newLines: core.newLines,
            oldMissingNewline: core.oldMissingNewline,
            newMissingNewline: core.newMissingNewline,
            expansions: expansions
        )
        let (left, right) = buildSplit(
            blocks: blocks, oldLines: core.oldLines, newLines: core.newLines,
            oldMissingNewline: core.oldMissingNewline,
            newMissingNewline: core.newMissingNewline,
            expansions: expansions
        )

        return DiffComputation(
            unified: unified,
            splitLeft: left,
            splitRight: right,
            editState: editState(
                ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
            )
        )
    }

    /// Full render with no folding — the shape the invariant tests verify.
    static func compute(oldText: String, newText: String) -> DiffComputation {
        build(core: .compute(oldText: oldText, newText: newText), expansions: nil)
    }

    // MARK: Collapse planning

    /// How one equal run renders: visible line stretches interleaved with at
    /// most one fold.
    private enum EqualSegment {
        /// Offsets within the run to render as context rows.
        case lines(Range<Int>)
        /// Offsets within the run hidden behind a separator row.
        case fold(hidden: Range<Int>, runIndex: Int, direction: DiffCollapsedRun.Direction)
    }

    /// Ported from Pierre's `Wt`: the fold decision uses the *original* gap
    /// size against the inline threshold, expansion counters are clamped to
    /// the range, and counters that cover the range render everything.
    private static func equalSegments(
        count: Int,
        runIndex: Int,
        hasChangeBefore: Bool,
        hasChangeAfter: Bool,
        expansions: [Int: DiffRunExpansion]?
    ) -> [EqualSegment] {
        guard let expansions else {
            return [.lines(0..<count)]
        }
        let lead = hasChangeBefore ? DiffCollapse.contextLines : 0
        let trail = hasChangeAfter ? DiffCollapse.contextLines : 0
        let hidden = count - lead - trail
        guard hidden > DiffCollapse.inlineGapThreshold else {
            return [.lines(0..<count)]
        }
        let expansion = expansions[runIndex] ?? DiffRunExpansion()
        let fromStart = min(max(expansion.fromStart, 0), hidden)
        let fromEnd = min(max(expansion.fromEnd, 0), hidden)
        guard fromStart + fromEnd < hidden else {
            return [.lines(0..<count)]
        }

        let direction: DiffCollapsedRun.Direction
        switch (hasChangeBefore, hasChangeAfter) {
        case (false, _): direction = .revealUp
        case (_, false): direction = .revealDown
        default: direction = .both
        }

        let headVisible = lead + fromStart
        let tailVisible = trail + fromEnd
        var segments: [EqualSegment] = []
        if headVisible > 0 {
            segments.append(.lines(0..<headVisible))
        }
        segments.append(.fold(
            hidden: headVisible..<(count - tailVisible),
            runIndex: runIndex,
            direction: direction
        ))
        if tailVisible > 0 {
            segments.append(.lines((count - tailVisible)..<count))
        }
        return segments
    }

    private static func collapsedRow(
        hidden: Int, runIndex: Int, direction: DiffCollapsedRun.Direction
    ) -> DiffRow {
        DiffRow(
            kind: .collapsed,
            oldLine: nil,
            newLine: nil,
            source: .none,
            sourceRange: NSRange(location: 0, length: 0),
            emphasis: [],
            missingNewline: false,
            collapsed: DiffCollapsedRun(
                hiddenLines: hidden, runIndex: runIndex, direction: direction
            )
        )
    }

    /// Edit-mode state, mirroring Pierre's editable diffs: the buffer holds
    /// only the new file, while removed lines surface as read-only ghost
    /// blocks anchored to the new-file line they sit in front of
    /// (`anchorLine == line count` marks a deletion at end-of-file). Rebuilt
    /// live (debounced) as the user types.
    static func editState(
        ops: [DiffLineOp], oldLines: [DiffSourceLine], newLines: [DiffSourceLine]
    ) -> DiffEditState {
        var added: [Int] = []
        var addedEmphasis: [Int: [NSRange]] = [:]
        var ghosts: [DiffEditGhostBlock] = []
        var newCursor = 0

        var pendingDeletes: [Int] = []
        var pendingInserts: [Int] = []
        func flushBlock() {
            guard !pendingDeletes.isEmpty || !pendingInserts.isEmpty else { return }
            // Word-level pairing, same index-wise rule the review documents use.
            var ghostEmphasis: [Int: [NSRange]] = [:]
            for pair in 0..<min(pendingDeletes.count, pendingInserts.count) {
                let oldIndex = pendingDeletes[pair]
                let newIndex = pendingInserts[pair]
                if let result = DiffIntraline.diff(
                    old: oldLines[oldIndex].text, new: newLines[newIndex].text
                ) {
                    ghostEmphasis[oldIndex] = result.oldRanges
                    addedEmphasis[newIndex] = result.newRanges
                }
            }
            if !pendingDeletes.isEmpty {
                let anchor = pendingInserts.first ?? newCursor
                ghosts.append(DiffEditGhostBlock(
                    anchorLine: anchor,
                    firstOldLine: pendingDeletes[0] + 1,
                    lines: pendingDeletes.map { index in
                        DiffEditGhostBlock.Line(
                            sourceRange: oldLines[index].utf16Range,
                            emphasis: ghostEmphasis[index] ?? []
                        )
                    }
                ))
            }
            pendingDeletes.removeAll(keepingCapacity: true)
            pendingInserts.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case .equal(_, _, let count):
                flushBlock()
                newCursor += count
            case .delete(let oldStart, let count):
                pendingDeletes.append(contentsOf: oldStart..<(oldStart + count))
            case .insert(let newStart, let count):
                pendingInserts.append(contentsOf: newStart..<(newStart + count))
                added.append(contentsOf: newStart..<(newStart + count))
                newCursor += count
            }
        }
        flushBlock()

        return DiffEditState(
            addedLines: added, addedEmphasis: addedEmphasis, ghosts: ghosts
        )
    }

    /// Change blocks: consecutive delete+insert ops between equal runs, with
    /// intraline emphasis computed for index-paired lines.
    private struct DiffBlocks {
        struct Block {
            var deletes: [Int] = []   // old line indexes
            var inserts: [Int] = []   // new line indexes
        }
        /// Ordered walk items: either an equal run or a change block.
        enum Item {
            case equal(oldStart: Int, newStart: Int, count: Int)
            case block(Block)
        }
        var items: [Item] = []

        init(ops: [DiffLineOp]) {
            var pending = Block()
            func flush() {
                if !pending.deletes.isEmpty || !pending.inserts.isEmpty {
                    items.append(.block(pending))
                    pending = Block()
                }
            }
            for op in ops {
                switch op {
                case .equal(let oldStart, let newStart, let count):
                    flush()
                    items.append(.equal(oldStart: oldStart, newStart: newStart, count: count))
                case .delete(let oldStart, let count):
                    pending.deletes.append(contentsOf: oldStart..<(oldStart + count))
                case .insert(let newStart, let count):
                    pending.inserts.append(contentsOf: newStart..<(newStart + count))
                }
            }
            flush()
        }
    }

    /// Intraline emphasis for a block, pairing removed/added lines by index.
    private static func blockEmphasis(
        _ block: DiffBlocks.Block, oldLines: [DiffSourceLine], newLines: [DiffSourceLine]
    ) -> (old: [Int: [NSRange]], new: [Int: [NSRange]]) {
        var old: [Int: [NSRange]] = [:]
        var new: [Int: [NSRange]] = [:]
        for pair in 0..<min(block.deletes.count, block.inserts.count) {
            let oldIndex = block.deletes[pair]
            let newIndex = block.inserts[pair]
            if let result = DiffIntraline.diff(
                old: oldLines[oldIndex].text, new: newLines[newIndex].text
            ) {
                old[oldIndex] = result.oldRanges
                new[newIndex] = result.newRanges
            }
        }
        return (old, new)
    }

    private struct DocumentBuilder {
        private var parts: [Substring] = []
        private(set) var rows: [DiffRow] = []
        private(set) var lineStartOffsets: [Int] = []
        private var utf16Length = 0

        mutating func append(_ row: DiffRow, text: Substring) {
            lineStartOffsets.append(utf16Length)
            rows.append(row)
            parts.append(text)
            utf16Length += text.utf16.count + 1
        }

        func document() -> DiffSideDocument {
            DiffSideDocument(
                text: parts.joined(separator: "\n"),
                rows: rows,
                lineStartOffsets: lineStartOffsets
            )
        }
    }

    private static func buildUnified(
        blocks: DiffBlocks, oldLines: [DiffSourceLine], newLines: [DiffSourceLine],
        oldMissingNewline: Bool, newMissingNewline: Bool,
        expansions: [Int: DiffRunExpansion]?
    ) -> DiffSideDocument {
        var builder = DocumentBuilder()
        var runIndex = -1
        for (itemIndex, item) in blocks.items.enumerated() {
            switch item {
            case .equal(let oldStart, let newStart, let count):
                runIndex += 1
                let segments = equalSegments(
                    count: count,
                    runIndex: runIndex,
                    hasChangeBefore: itemIndex > 0,
                    hasChangeAfter: itemIndex < blocks.items.count - 1,
                    expansions: expansions
                )
                for segment in segments {
                    switch segment {
                    case .lines(let range):
                        for offset in range {
                            let newIndex = newStart + offset
                            builder.append(
                                DiffRow(
                                    kind: .context,
                                    oldLine: oldStart + offset + 1,
                                    newLine: newIndex + 1,
                                    source: .new,
                                    sourceRange: newLines[newIndex].utf16Range,
                                    emphasis: [],
                                    missingNewline: false
                                ),
                                text: newLines[newIndex].text
                            )
                        }
                    case .fold(let hidden, let run, let direction):
                        builder.append(
                            collapsedRow(
                                hidden: hidden.count, runIndex: run, direction: direction
                            ),
                            text: ""
                        )
                    }
                }
            case .block(let block):
                let emphasis = blockEmphasis(block, oldLines: oldLines, newLines: newLines)
                for oldIndex in block.deletes {
                    builder.append(
                        DiffRow(
                            kind: .removed,
                            oldLine: oldIndex + 1,
                            newLine: nil,
                            source: .old,
                            sourceRange: oldLines[oldIndex].utf16Range,
                            emphasis: emphasis.old[oldIndex] ?? [],
                            missingNewline: oldMissingNewline && oldIndex == oldLines.count - 1
                        ),
                        text: oldLines[oldIndex].text
                    )
                }
                for newIndex in block.inserts {
                    builder.append(
                        DiffRow(
                            kind: .added,
                            oldLine: nil,
                            newLine: newIndex + 1,
                            source: .new,
                            sourceRange: newLines[newIndex].utf16Range,
                            emphasis: emphasis.new[newIndex] ?? [],
                            missingNewline: newMissingNewline && newIndex == newLines.count - 1
                        ),
                        text: newLines[newIndex].text
                    )
                }
            }
        }
        return builder.document()
    }

    private static func buildSplit(
        blocks: DiffBlocks, oldLines: [DiffSourceLine], newLines: [DiffSourceLine],
        oldMissingNewline: Bool, newMissingNewline: Bool,
        expansions: [Int: DiffRunExpansion]?
    ) -> (left: DiffSideDocument, right: DiffSideDocument) {
        var left = DocumentBuilder()
        var right = DocumentBuilder()

        func filler() -> DiffRow {
            DiffRow(
                kind: .filler, oldLine: nil, newLine: nil,
                source: .none, sourceRange: NSRange(location: 0, length: 0),
                emphasis: [], missingNewline: false
            )
        }

        var runIndex = -1
        for (itemIndex, item) in blocks.items.enumerated() {
            switch item {
            case .equal(let oldStart, let newStart, let count):
                runIndex += 1
                let segments = equalSegments(
                    count: count,
                    runIndex: runIndex,
                    hasChangeBefore: itemIndex > 0,
                    hasChangeAfter: itemIndex < blocks.items.count - 1,
                    expansions: expansions
                )
                for segment in segments {
                    switch segment {
                    case .lines(let range):
                        for offset in range {
                            let oldIndex = oldStart + offset
                            let newIndex = newStart + offset
                            left.append(
                                DiffRow(
                                    kind: .context,
                                    oldLine: oldIndex + 1,
                                    newLine: newIndex + 1,
                                    source: .old,
                                    sourceRange: oldLines[oldIndex].utf16Range,
                                    emphasis: [],
                                    missingNewline: false
                                ),
                                text: oldLines[oldIndex].text
                            )
                            right.append(
                                DiffRow(
                                    kind: .context,
                                    oldLine: oldIndex + 1,
                                    newLine: newIndex + 1,
                                    source: .new,
                                    sourceRange: newLines[newIndex].utf16Range,
                                    emphasis: [],
                                    missingNewline: false
                                ),
                                text: newLines[newIndex].text
                            )
                        }
                    case .fold(let hidden, let run, let direction):
                        // Same separator on both sides at the same row index,
                        // preserving the split alignment invariant.
                        left.append(
                            collapsedRow(
                                hidden: hidden.count, runIndex: run, direction: direction
                            ),
                            text: ""
                        )
                        right.append(
                            collapsedRow(
                                hidden: hidden.count, runIndex: run, direction: direction
                            ),
                            text: ""
                        )
                    }
                }
            case .block(let block):
                let emphasis = blockEmphasis(block, oldLines: oldLines, newLines: newLines)
                let rowCount = max(block.deletes.count, block.inserts.count)
                for rowOffset in 0..<rowCount {
                    if rowOffset < block.deletes.count {
                        let oldIndex = block.deletes[rowOffset]
                        left.append(
                            DiffRow(
                                kind: .removed,
                                oldLine: oldIndex + 1,
                                newLine: nil,
                                source: .old,
                                sourceRange: oldLines[oldIndex].utf16Range,
                                emphasis: emphasis.old[oldIndex] ?? [],
                                missingNewline: oldMissingNewline && oldIndex == oldLines.count - 1
                            ),
                            text: oldLines[oldIndex].text
                        )
                    } else {
                        left.append(filler(), text: "")
                    }
                    if rowOffset < block.inserts.count {
                        let newIndex = block.inserts[rowOffset]
                        right.append(
                            DiffRow(
                                kind: .added,
                                oldLine: nil,
                                newLine: newIndex + 1,
                                source: .new,
                                sourceRange: newLines[newIndex].utf16Range,
                                emphasis: emphasis.new[newIndex] ?? [],
                                missingNewline: newMissingNewline && newIndex == newLines.count - 1
                            ),
                            text: newLines[newIndex].text
                        )
                    } else {
                        right.append(filler(), text: "")
                    }
                }
            }
        }
        return (left.document(), right.document())
    }
}
