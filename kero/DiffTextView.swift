//
//  DiffTextView.swift
//  kero
//
//  STTextView-based rendering for the diff viewer: one "code pane" is a text
//  view inside a scroll view, a full-width decoration underlay behind it
//  (row tints, word-level emphasis, deletion markers), and a native gutter
//  with per-file line numbers to its left.
//
//  The text view is transparent and the scroll view draws no background; the
//  underlay sits *behind* the scroll view, viewport-sized, and repaints on
//  scroll and after every viewport layout pass. Everything it draws is
//  derived from the layout manager's actual fragment frames, so decorations
//  stay glued to the text through resizes, elastic scrolling, and variable
//  line heights.
//

import AppKit
import STTextKitPlus
import STTextView

// MARK: - Colors

/// Diff colors derived from the selected ghostty theme: added/removed tints
/// from ANSI green/red over the theme background. Resolved per draw against
/// the current appearance so theme and appearance switches repaint correctly.
struct DiffColorScheme {
    let background: NSColor
    let addedRow: NSColor
    let removedRow: NSColor
    let addedEmphasis: NSColor
    let removedEmphasis: NSColor
    let fillerRow: NSColor
    let fillerStripe: NSColor
    let collapsedBand: NSColor
    let gutterText: NSColor
    let addedGutterText: NSColor
    let removedGutterText: NSColor
    let deletionMarker: NSColor
    let annotationText: NSColor

    static func current(dark: Bool) -> DiffColorScheme {
        let theme = Theme.terminal(dark: dark)
        let background = theme.backgroundNSColor
        // ANSI green/red follow the theme; fall back to fixed diff hues for
        // palettes that don't define them.
        let green = theme.paletteNSColor(2) ?? NSColor(
            srgbRed: 0.25, green: 0.65, blue: 0.35, alpha: 1
        )
        let red = theme.paletteNSColor(1) ?? NSColor(
            srgbRed: 0.85, green: 0.35, blue: 0.35, alpha: 1
        )
        let foreground = theme.foregroundNSColor

        func over(_ tint: NSColor, _ fraction: CGFloat) -> NSColor {
            background.blended(withFraction: fraction, of: tint) ?? background
        }

        return DiffColorScheme(
            background: background,
            addedRow: over(green, 0.16),
            removedRow: over(red, 0.16),
            addedEmphasis: over(green, 0.38),
            removedEmphasis: over(red, 0.38),
            fillerRow: over(foreground, 0.03),
            fillerStripe: over(foreground, 0.06),
            collapsedBand: over(foreground, 0.05),
            gutterText: theme.surfaceNSColor(elevation: 0.35),
            addedGutterText: over(green, 0.75),
            removedGutterText: over(red, 0.75),
            deletionMarker: red,
            annotationText: theme.surfaceNSColor(elevation: 0.5)
        )
    }
}

/// Labels for a collapsed-run separator, shared by the underlay's drawn text
/// and the gutter's accessibility elements.
enum DiffCollapsedRunLabel {
    static func text(hiddenLines: Int) -> String {
        hiddenLines == 1
            ? String(
                localized: "1 unmodified line",
                comment: "Separator row standing in for one folded context line in a diff."
            )
            : String(
                localized: "\(hiddenLines) unmodified lines",
                comment: "Separator row standing in for folded context lines in a diff."
            )
    }

    static func expandAction(hiddenLines: Int) -> String {
        String(
            localized: "Expand \(text(hiddenLines: hiddenLines))",
            comment: "Accessibility action for a folded run of context lines in a diff."
        )
    }
}

// MARK: - Decorations model

/// Everything a code pane needs to decorate its document, keyed by paragraph
/// (row) index. Built from a `DiffSideDocument` in review mode, or from the
/// edit-mode line lists while the buffer is live. Nonisolated: edit-mode
/// decorations are rebuilt off the main actor as the user types.
nonisolated struct DiffDecorations {
    struct Row {
        let kind: DiffRowKind
        let oldLine: Int?
        let newLine: Int?
        /// Word-level changed spans in *document* UTF-16 coordinates.
        let emphasis: [NSRange]
        let missingNewline: Bool
        /// Present on `.collapsed` separator rows.
        var collapsed: DiffCollapsedRun? = nil
    }

    /// A removed block rendered as read-only ghost rows in the gap above its
    /// anchor paragraph (edit mode). Lines are pre-baked with the old file's
    /// syntax colors and word-level emphasis backgrounds.
    struct GhostBlock {
        /// Buffer paragraph index the block precedes; `rows.count` means the
        /// block sits after the last line (a deletion at end-of-file).
        let anchorLine: Int
        /// 1-based old-file number of the first ghost line.
        let firstOldLine: Int
        let lines: [NSAttributedString]
    }

    let rows: [Row]
    /// UTF-16 offset of each row's start; empty in edit mode, where the live
    /// buffer's offsets drift between recomputes and rows are addressed by
    /// paragraph counting instead.
    let lineStartOffsets: [Int]
    /// Edit mode: the buffer snapshot's per-line start offsets, backing
    /// paragraph-spacing application and emphasis geometry. Kept separate
    /// from `lineStartOffsets` so row geometry stays paragraph-counted
    /// against the live buffer.
    var editSnapshotOffsets: [Int] = []
    /// Edit mode: ghost deletion blocks keyed by anchor paragraph.
    var ghostsByAnchor: [Int: GhostBlock] = [:]
    let maxOldLine: Int
    let maxNewLine: Int

    static let empty = DiffDecorations(
        rows: [], lineStartOffsets: [], maxOldLine: 0, maxNewLine: 0
    )

    static func review(_ document: DiffSideDocument) -> DiffDecorations {
        var rows: [Row] = []
        rows.reserveCapacity(document.rows.count)
        var maxOld = 0
        var maxNew = 0
        for (index, row) in document.rows.enumerated() {
            let start = document.lineStartOffsets[index]
            rows.append(Row(
                kind: row.kind,
                oldLine: row.oldLine,
                newLine: row.newLine,
                emphasis: row.emphasis.map {
                    NSRange(location: start + $0.location, length: $0.length)
                },
                missingNewline: row.missingNewline,
                collapsed: row.collapsed
            ))
            maxOld = max(maxOld, row.oldLine ?? 0)
            maxNew = max(maxNew, row.newLine ?? 0)
        }
        return DiffDecorations(
            rows: rows,
            lineStartOffsets: document.lineStartOffsets,
            maxOldLine: maxOld,
            maxNewLine: maxNew
        )
    }

    static func edit(
        state: DiffEditState,
        snapshotOffsets: [Int],
        lineCount: Int,
        ghostBlocks: [GhostBlock]
    ) -> DiffDecorations {
        let added = Set(state.addedLines)
        // An empty buffer still renders one (empty) line.
        let rowCount = max(1, lineCount)
        var rows: [Row] = []
        rows.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let emphasis = (state.addedEmphasis[index] ?? []).compactMap { range -> NSRange? in
                guard index < snapshotOffsets.count else { return nil }
                return NSRange(
                    location: snapshotOffsets[index] + range.location, length: range.length
                )
            }
            rows.append(Row(
                kind: added.contains(index) ? .added : .context,
                oldLine: nil,
                newLine: index + 1,
                emphasis: emphasis,
                missingNewline: false
            ))
        }
        var ghostsByAnchor: [Int: GhostBlock] = [:]
        var maxOld = 0
        for block in ghostBlocks {
            ghostsByAnchor[block.anchorLine] = block
            maxOld = max(maxOld, block.firstOldLine + block.lines.count - 1)
        }
        var decorations = DiffDecorations(
            rows: rows,
            lineStartOffsets: [],
            maxOldLine: maxOld,
            maxNewLine: rowCount
        )
        decorations.editSnapshotOffsets = snapshotOffsets
        decorations.ghostsByAnchor = ghostsByAnchor
        return decorations
    }

    /// Row index containing a document UTF-16 offset (review mode only).
    func rowIndex(forUTF16Offset offset: Int) -> Int? {
        guard !lineStartOffsets.isEmpty else { return nil }
        var lo = 0
        var hi = lineStartOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStartOffsets[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: - Viewport layout hook

/// Repaints the decoration underlay and gutter after each viewport layout
/// pass — the moment fragment frames for the visible range are final.
struct DiffViewportSyncPlugin: STPlugin {
    let onLayout: () -> Void

    func setUp(context: any Context) {
        context.events.onDidLayoutViewport { _ in
            onLayout()
        }
    }
}

// MARK: - Text view

/// The pane's text view: reports focus so the tab model can track the active
/// side, and lets clicks on collapsed-run separator rows expand them instead
/// of placing a caret in the (empty) separator line.
final class DiffTextView: STTextView {
    var onBecomeFirstResponder: (() -> Void)?
    /// Returns true when the click landed on a collapsed-run separator and
    /// was consumed by expanding it.
    var handleCollapsedClick: ((NSPoint) -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleCollapsedClick?(point) == true { return }
        super.mouseDown(with: event)
    }
}

// MARK: - Rows geometry

/// One visible row resolved against the current layout: its index, metadata,
/// and frame in text-view coordinates.
private struct DiffVisibleRow {
    let index: Int
    let frame: CGRect
}

/// Shared row-geometry walk used by the underlay and the gutter. Enumerates
/// the viewport's layout fragments and yields one entry per visual row.
///
/// Row indexes come from the immutable document's line-start table in review
/// mode; in edit mode (live buffer) they're derived by counting the text
/// elements before the viewport — the same technique STTextView's own gutter
/// uses, always correct against the current buffer.
@MainActor
private enum DiffRowGeometry {
    static func visibleRows(
        textView: STTextView, decorations: DiffDecorations
    ) -> [DiffVisibleRow] {
        let layoutManager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else {
            return []
        }

        let byOffsets = !decorations.lineStartOffsets.isEmpty
        var nextCountedIndex = 0
        if !byOffsets {
            nextCountedIndex = contentManager.textElements(
                for: NSTextRange(
                    location: layoutManager.documentRange.location,
                    end: viewportRange.location
                )!
            ).count
        }

        var rows: [DiffVisibleRow] = []
        layoutManager.enumerateTextLayoutFragments(in: viewportRange) { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            let baseIndex: Int
            if byOffsets {
                let offset = contentManager.offset(
                    from: layoutManager.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                baseIndex = decorations.rowIndex(forUTF16Offset: offset) ?? 0
            } else {
                baseIndex = nextCountedIndex
            }

            var lineOffset = 0
            for lineFragment in fragment.textLineFragments
            where lineFragment.isExtraLineFragment
                || fragment.textLineFragments.first == lineFragment {
                let bounds = lineFragment.typographicBounds
                rows.append(DiffVisibleRow(
                    index: baseIndex + lineOffset,
                    frame: CGRect(
                        x: fragmentFrame.origin.x,
                        y: fragmentFrame.origin.y + bounds.minY,
                        width: fragmentFrame.width,
                        height: bounds.height
                    )
                ))
                lineOffset += 1
            }
            nextCountedIndex = baseIndex + max(1, lineOffset)
            return true
        }
        return rows
    }
}

// MARK: - Decoration underlay

/// Viewport-sized view behind the scroll view. Paints the pane background,
/// per-row diff tints, word-level emphasis, edit-mode deletion markers, and
/// the "no newline at end of file" glyph.
final class DiffDecorationUnderlayView: NSView {
    weak var textView: STTextView?
    weak var clipView: NSClipView?
    var decorations: DiffDecorations = .empty {
        didSet { needsDisplay = true }
    }
    /// Font for the "N unmodified lines" separator label, derived from the
    /// pane's code font.
    var labelFont: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Text-view coordinates → this view's coordinates. The underlay's frame
    /// matches the scroll view's, and the clip view fills the scroll view, so
    /// the mapping is a translation by the scroll offset.
    private func converted(_ rect: CGRect) -> CGRect {
        guard let clipView else { return rect }
        return rect.offsetBy(
            dx: -clipView.bounds.origin.x, dy: -clipView.bounds.origin.y
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scheme = DiffColorScheme.current(dark: dark)

        scheme.background.setFill()
        dirtyRect.fill()

        guard let textView, !decorations.rows.isEmpty else { return }
        let rows = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
        guard !rows.isEmpty else { return }

        for row in rows {
            guard row.index < decorations.rows.count else { continue }
            let metadata = decorations.rows[row.index]
            let rowRect = CGRect(
                x: 0,
                y: converted(row.frame).origin.y,
                width: bounds.width,
                height: row.frame.height
            )
            // Pad the intersection test one point so the deletion marker
            // straddling the row's top edge isn't clipped away.
            guard rowRect.insetBy(dx: 0, dy: -2).intersects(dirtyRect) else { continue }

            switch metadata.kind {
            case .context:
                break
            case .added:
                scheme.addedRow.setFill()
                rowRect.fill()
            case .removed:
                scheme.removedRow.setFill()
                rowRect.fill()
            case .filler:
                scheme.fillerRow.setFill()
                rowRect.fill()
                drawFillerStripes(in: rowRect, color: scheme.fillerStripe)
            case .collapsed:
                scheme.collapsedBand.setFill()
                rowRect.fill()
                if let info = metadata.collapsed {
                    let label = NSAttributedString(
                        string: DiffCollapsedRunLabel.text(hiddenLines: info.hiddenLines),
                        attributes: [
                            .font: labelFont,
                            .foregroundColor: scheme.annotationText,
                        ]
                    )
                    let size = label.size()
                    label.draw(at: CGPoint(x: 12, y: rowRect.midY - size.height / 2))
                }
            }

            if !metadata.emphasis.isEmpty {
                let emphasisColor = metadata.kind == .added
                    ? scheme.addedEmphasis : scheme.removedEmphasis
                emphasisColor.setFill()
                for range in metadata.emphasis {
                    for segment in segmentRects(for: range) {
                        let rect = converted(segment).intersection(rowRect)
                        guard !rect.isNull, rect.width > 0 else { continue }
                        NSBezierPath(
                            roundedRect: rect.insetBy(dx: 0, dy: 0.5),
                            xRadius: 2, yRadius: 2
                        ).fill()
                    }
                }
            }

            if metadata.missingNewline {
                drawMissingNewlineBadge(
                    after: converted(row.frame), scheme: scheme
                )
            }

            // Read-only deletion ghosts (edit mode): the paragraph carries
            // spacing above it exactly tall enough for the block, and the
            // lines are drawn into that gap.
            if let block = decorations.ghostsByAnchor[row.index] {
                drawGhostBlock(
                    block,
                    endingAt: rowRect.minY,
                    rowHeight: row.frame.height,
                    textX: converted(row.frame).origin.x,
                    scheme: scheme
                )
            }
            // A deletion at end-of-file anchors past the last row and draws
            // below it (the last paragraph carries spacing after).
            if row.index == decorations.rows.count - 1,
               let block = decorations.ghostsByAnchor[decorations.rows.count] {
                drawGhostBlock(
                    block,
                    endingAt: rowRect.maxY + CGFloat(block.lines.count) * row.frame.height,
                    rowHeight: row.frame.height,
                    textX: converted(row.frame).origin.x,
                    scheme: scheme
                )
            }
        }
    }

    /// Draws one ghost block whose last line's bottom edge sits at `bottomY`.
    private func drawGhostBlock(
        _ block: DiffDecorations.GhostBlock,
        endingAt bottomY: CGFloat,
        rowHeight: CGFloat,
        textX: CGFloat,
        scheme: DiffColorScheme
    ) {
        var y = bottomY - CGFloat(block.lines.count) * rowHeight
        for line in block.lines {
            let rect = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            if rect.intersects(bounds) {
                scheme.removedRow.setFill()
                rect.fill()
                line.draw(at: CGPoint(x: textX, y: y))
            }
            y += rowHeight
        }
    }

    /// Frames for a document range, in text-view coordinates. Ranges here are
    /// always within a single row, so segment enumeration yields one rect.
    private func segmentRects(for range: NSRange) -> [CGRect] {
        guard let textView,
              let textRange = NSTextRange(range, in: textView.textContentManager)
        else { return [] }
        var rects: [CGRect] = []
        textView.textLayoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: .rangeNotRequired
        ) { _, frame, _, _ in
            if frame.width > 0 { rects.append(frame) }
            return true
        }
        return rects
    }

    private func drawFillerStripes(in rect: CGRect, color: NSColor) {
        // Sparse diagonal hatching so filler rows read as "no content" rather
        // than empty lines.
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let step: CGFloat = 8
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.line(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        path.stroke()
    }

    private func drawMissingNewlineBadge(after lineFrame: CGRect, scheme: DiffColorScheme) {
        let text = NSAttributedString(
            string: "⌐ no newline",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(8, lineFrame.height * 0.5)),
                .foregroundColor: scheme.annotationText,
            ]
        )
        let size = text.size()
        text.draw(at: CGPoint(
            x: lineFrame.maxX + 8,
            y: lineFrame.midY - size.height / 2
        ))
    }
}

// MARK: - Gutter

/// Which line numbers a pane's gutter shows.
enum DiffGutterLayout {
    /// One column carrying each row's own side: old numbers on removed rows,
    /// new numbers on added and context rows (unified view).
    case single
    /// A single column of old-file numbers (split view, left side).
    case oldOnly
    /// A single column of new-file numbers (split right side and edit mode).
    case newOnly
}

/// Fixed-width gutter to the left of a code pane: line numbers per file side,
/// a +/− change marker, row tint continuation, and edit-mode deletion
/// wedges. Sits outside the scroll view and repaints on scroll, so its
/// content never scrolls horizontally with the code.
final class DiffGutterView: NSView {
    weak var textView: STTextView?
    weak var clipView: NSClipView?
    var layoutStyle: DiffGutterLayout = .single
    var decorations: DiffDecorations = .empty {
        didSet {
            recalculateThickness()
            needsDisplay = true
        }
    }
    var font: NSFont = TerminalFont.current() {
        didSet {
            recalculateThickness()
            needsDisplay = true
        }
    }

    /// Width the pane should give the gutter for the current decorations.
    private(set) var thickness: CGFloat = 40

    private static let leadingPad: CGFloat = 8
    private static let markerWidth: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        // An AX group (not an ignored view): its children are the virtual
        // "Expand N unmodified lines" buttons from accessibilityChildren(),
        // which an ignored view would drop from the hierarchy entirely.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(
            localized: "Diff gutter",
            comment: "Accessibility label for the diff view's line-number column."
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The number font: the code font's family at a slightly reduced size,
    /// matching how the editor's gutter reads against its text.
    private var numberFont: NSFont {
        let size = max(8, font.pointSize - 1.5)
        return NSFont(descriptor: font.fontDescriptor, size: size)
            ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private func digitWidth(_ font: NSFont) -> CGFloat {
        ("8" as NSString).size(withAttributes: [.font: font]).width
    }

    private func recalculateThickness() {
        let numberFont = numberFont
        let digit = digitWidth(numberFont)
        func columnWidth(maxLine: Int) -> CGFloat {
            let digits = max(2, String(max(1, maxLine)).count)
            return CGFloat(digits) * digit
        }
        var width = Self.leadingPad
        switch layoutStyle {
        case .single:
            width += columnWidth(
                maxLine: max(decorations.maxOldLine, decorations.maxNewLine)
            )
        case .oldOnly:
            width += columnWidth(maxLine: decorations.maxOldLine)
        case .newOnly:
            width += columnWidth(maxLine: decorations.maxNewLine)
        }
        width += Self.markerWidth
        thickness = ceil(width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scheme = DiffColorScheme.current(dark: dark)

        scheme.background.setFill()
        dirtyRect.fill()

        guard let textView, let clipView, !decorations.rows.isEmpty else { return }
        let rows = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)

        let numberFont = numberFont
        let digit = digitWidth(numberFont)

        func columnWidth(maxLine: Int) -> CGFloat {
            CGFloat(max(2, String(max(1, maxLine)).count)) * digit
        }

        // Right edge of the single number column per layout.
        let numberRight: CGFloat
        switch layoutStyle {
        case .single:
            numberRight = Self.leadingPad + columnWidth(
                maxLine: max(decorations.maxOldLine, decorations.maxNewLine)
            )
        case .oldOnly:
            numberRight = Self.leadingPad + columnWidth(maxLine: decorations.maxOldLine)
        case .newOnly:
            numberRight = Self.leadingPad + columnWidth(maxLine: decorations.maxNewLine)
        }
        let markerX = bounds.width - Self.markerWidth + 3

        for row in rows {
            guard row.index < decorations.rows.count else { continue }
            let metadata = decorations.rows[row.index]
            let y = row.frame.origin.y - clipView.bounds.origin.y
            let rowRect = CGRect(x: 0, y: y, width: bounds.width, height: row.frame.height)
            guard rowRect.intersects(dirtyRect) else { continue }

            var numberColor = scheme.gutterText
            var accentBar: NSColor?
            var marker: String?
            switch metadata.kind {
            case .context:
                break
            case .added:
                scheme.addedRow.setFill()
                rowRect.fill()
                numberColor = scheme.addedGutterText
                accentBar = scheme.addedGutterText
                marker = "+"
            case .removed:
                scheme.removedRow.setFill()
                rowRect.fill()
                numberColor = scheme.removedGutterText
                accentBar = scheme.removedGutterText
                marker = "−"
            case .filler:
                scheme.fillerRow.setFill()
                rowRect.fill()
            case .collapsed:
                scheme.collapsedBand.setFill()
                rowRect.fill()
                drawExpandChevrons(
                    in: rowRect,
                    direction: metadata.collapsed?.direction ?? .both,
                    color: scheme.annotationText
                )
                continue
            }

            // Edge accent on changed rows, like diffs.com's inline view.
            if let accentBar {
                accentBar.setFill()
                CGRect(x: 0, y: rowRect.minY, width: 3, height: rowRect.height).fill()
            }

            // The number a row shows is its own side's: old for removed rows,
            // new for added and context (matching diffs.com's inline gutter);
            // split sides carry their fixed file side.
            let line: Int?
            switch layoutStyle {
            case .single:
                line = metadata.kind == .removed ? metadata.oldLine : metadata.newLine
            case .oldOnly:
                line = metadata.oldLine
            case .newOnly:
                line = metadata.newLine
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: numberColor,
            ]
            if let line {
                let string = NSAttributedString(string: String(line), attributes: attributes)
                let size = string.size()
                string.draw(at: CGPoint(
                    x: numberRight - size.width,
                    y: rowRect.midY - size.height / 2
                ))
            }
            if let marker {
                let string = NSAttributedString(string: marker, attributes: attributes)
                let size = string.size()
                string.draw(at: CGPoint(x: markerX, y: rowRect.midY - size.height / 2))
            }

            if let block = decorations.ghostsByAnchor[row.index] {
                drawGhostGutterRows(
                    block,
                    endingAt: rowRect.minY,
                    rowHeight: rowRect.height,
                    numberFont: numberFont,
                    numberRight: numberRight,
                    markerX: markerX,
                    scheme: scheme
                )
            }
            if row.index == decorations.rows.count - 1,
               let block = decorations.ghostsByAnchor[decorations.rows.count] {
                drawGhostGutterRows(
                    block,
                    endingAt: rowRect.maxY + CGFloat(block.lines.count) * rowRect.height,
                    rowHeight: rowRect.height,
                    numberFont: numberFont,
                    numberRight: numberRight,
                    markerX: markerX,
                    scheme: scheme
                )
            }
        }
    }

    /// Gutter side of a deletion ghost block: row tints, old-file numbers,
    /// and − markers, ending at `bottomY`.
    private func drawGhostGutterRows(
        _ block: DiffDecorations.GhostBlock,
        endingAt bottomY: CGFloat,
        rowHeight: CGFloat,
        numberFont: NSFont,
        numberRight: CGFloat,
        markerX: CGFloat,
        scheme: DiffColorScheme
    ) {
        var y = bottomY - CGFloat(block.lines.count) * rowHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: scheme.removedGutterText,
        ]
        for lineOffset in 0..<block.lines.count {
            let rect = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            if rect.intersects(bounds) {
                scheme.removedRow.setFill()
                rect.fill()
                scheme.removedGutterText.setFill()
                CGRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
                let number = NSAttributedString(
                    string: String(block.firstOldLine + lineOffset), attributes: attributes
                )
                let numberSize = number.size()
                number.draw(at: CGPoint(
                    x: numberRight - numberSize.width,
                    y: rect.midY - numberSize.height / 2
                ))
                let marker = NSAttributedString(string: "−", attributes: attributes)
                let markerSize = marker.size()
                marker.draw(at: CGPoint(x: markerX, y: rect.midY - markerSize.height / 2))
            }
            y += rowHeight
        }
    }

    /// The expand affordance on a collapsed run: a chevron pointing where the
    /// revealed lines will appear, or a stacked pair for middle gaps that
    /// reveal at both edges.
    private func drawExpandChevrons(
        in rowRect: CGRect, direction: DiffCollapsedRun.Direction, color: NSColor
    ) {
        color.setStroke()
        let centerX = bounds.width / 2
        let width: CGFloat = 7
        let rise: CGFloat = 3.5
        let gap: CGFloat = 2.5

        func chevron(tipY: CGFloat, pointingUp: Bool) {
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let baseY = tipY + (pointingUp ? rise : -rise)
            path.move(to: CGPoint(x: centerX - width / 2, y: baseY))
            path.line(to: CGPoint(x: centerX, y: tipY))
            path.line(to: CGPoint(x: centerX + width / 2, y: baseY))
            path.stroke()
        }

        switch direction {
        case .revealUp:
            chevron(tipY: rowRect.midY - rise / 2, pointingUp: true)
        case .revealDown:
            chevron(tipY: rowRect.midY + rise / 2, pointingUp: false)
        case .both:
            chevron(tipY: rowRect.midY - gap - rise, pointingUp: true)
            chevron(tipY: rowRect.midY + gap + rise, pointingUp: false)
        }
    }

    // MARK: Expansion interaction

    /// Fired with the fold's metadata when a collapsed separator row is
    /// clicked.
    var onExpandRun: ((DiffCollapsedRun) -> Void)?

    /// The collapsed run at a point in gutter coordinates, if any.
    private func collapsedRun(atGutterPoint point: NSPoint) -> DiffCollapsedRun? {
        guard let textView, let clipView else { return nil }
        let documentY = point.y + clipView.bounds.origin.y
        guard let row = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
            .first(where: { documentY >= $0.frame.minY && documentY < $0.frame.maxY }),
            row.index < decorations.rows.count
        else { return nil }
        return decorations.rows[row.index].collapsed
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let fold = collapsedRun(atGutterPoint: point) {
            onExpandRun?(fold)
            return
        }
        super.mouseDown(with: event)
    }

    /// Each visible collapsed row is exposed as an accessibility button, so
    /// the fold can be expanded without a pointer.
    private final class ExpandAXElement: NSAccessibilityElement {
        var onPress: (() -> Void)?

        override func accessibilityPerformPress() -> Bool {
            guard let onPress else { return false }
            onPress()
            return true
        }
    }

    /// Owned by the view: the AX bridge resolves returned elements lazily, so
    /// elements built fresh inside `accessibilityChildren()` would be gone by
    /// the time an assistive client queries them.
    private var expandElements: [ExpandAXElement] = []

    override func accessibilityChildren() -> [Any]? {
        guard let textView, let clipView else { return nil }
        var elements: [ExpandAXElement] = []
        for row in DiffRowGeometry.visibleRows(textView: textView, decorations: decorations) {
            guard row.index < decorations.rows.count,
                  let info = decorations.rows[row.index].collapsed
            else { continue }
            let element = ExpandAXElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(
                DiffCollapsedRunLabel.expandAction(hiddenLines: info.hiddenLines)
            )
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(
                x: 0,
                y: row.frame.origin.y - clipView.bounds.origin.y,
                width: bounds.width,
                height: row.frame.height
            ))
            element.onPress = { [weak self] in
                self?.onExpandRun?(info)
            }
            elements.append(element)
        }
        expandElements = elements
        return elements.isEmpty ? nil : elements
    }
}

// MARK: - Code pane

/// Clip view that reports every scroll movement directly from its bounds
/// setters. NSScrollView reconfigures its subview stack when the find bar
/// appears, which can silently detach a bounds-change notification observer;
/// an override cannot be bypassed, so split-pane scroll sync and decoration
/// repaints survive.
private final class DiffClipView: NSClipView {
    var onBoundsChange: (() -> Void)?

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onBoundsChange?()
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        onBoundsChange?()
    }
}

/// One diff column: gutter + decoration underlay + transparent scroll/text
/// stack. Configured once as review (immutable attributed document) or edit
/// (live buffer with the editor's syntax plugin); the mode never changes for
/// a given instance because STTextView plugins cannot be detached.
final class DiffCodePaneView: NSView {
    enum Mode {
        case review
        case edit
    }

    let mode: Mode
    let scrollView = NSScrollView()
    let textView = DiffTextView()
    private let underlay = DiffDecorationUnderlayView()
    private let gutter = DiffGutterView()
    /// Re-entrancy guard for vertical scroll syncing between split panes.
    private var isSyncingScroll = false

    var onVerticalScroll: ((CGFloat) -> Void)?
    var onFocus: (() -> Void)?
    /// Fired with the fold's metadata when the user activates a collapsed-run
    /// separator (row click, gutter click, or accessibility press).
    var onExpandCollapsedRun: ((DiffCollapsedRun) -> Void)?
    /// Set while a fold-expansion click is waiting for its rebuilt document,
    /// so the swap keeps the raw scroll offset instead of re-anchoring by
    /// line. Single-shot.
    private var pendingExpansionSwap = false
    /// Identity of the display whose document this pane currently shows, so
    /// re-renders skip the expensive document swap when nothing changed.
    var renderedDisplayID: UUID?

    var decorations: DiffDecorations = .empty {
        didSet {
            underlay.decorations = decorations
            gutter.decorations = decorations
            let thickness = gutter.thickness
            if abs(thickness - gutterWidth) > 0.5 {
                gutterWidth = thickness
                needsLayout = true
            }
            if mode == .edit {
                applyGhostSpacing()
            }
        }
    }

    /// Ghost spacing last applied, keyed by buffer paragraph index →
    /// (rows above, rows after), so refreshes only touch paragraphs whose
    /// ghost blocks changed.
    private var appliedGhostSpacing: [Int: GhostSpacing] = [:]

    private struct GhostSpacing: Equatable {
        var rowsBefore = 0
        var rowsAfter = 0
    }

    /// Replaces the edit buffer's text, resetting the spacing bookkeeping
    /// that referred to the previous document.
    func setEditBufferText(_ text: String) {
        appliedGhostSpacing = [:]
        textView.text = text
    }

    /// Gives each ghost anchor paragraph spacing above it (or after it, for
    /// an end-of-file block) exactly tall enough for its ghost rows; the
    /// underlay and gutter draw the removed lines into those gaps.
    private func applyGhostSpacing() {
        guard rowHeight > 0 else { return }
        let offsets = decorations.editSnapshotOffsets
        let lastLine = max(0, decorations.rows.count - 1)

        // One paragraph can carry spacing on both edges (a deletion before
        // the last line plus one at end-of-file), so merge per paragraph
        // before touching attributes — paragraph style is a single value.
        var wanted: [Int: GhostSpacing] = [:]
        for (anchor, block) in decorations.ghostsByAnchor {
            if anchor >= decorations.rows.count {
                wanted[lastLine, default: GhostSpacing()].rowsAfter = block.lines.count
            } else {
                wanted[anchor, default: GhostSpacing()].rowsBefore = block.lines.count
            }
        }
        guard wanted != appliedGhostSpacing else { return }

        let documentLength = (textView.text ?? "").utf16.count

        func paragraphRange(forLine line: Int) -> NSRange? {
            guard line < offsets.count else { return nil }
            let start = offsets[line]
            let end = line + 1 < offsets.count ? offsets[line + 1] : documentLength
            guard start <= documentLength else { return nil }
            return NSRange(location: start, length: max(0, min(end, documentLength) - start))
        }

        let base = DiffTypography.paragraphStyle(for: textView.font)

        for (line, _) in appliedGhostSpacing where wanted[line] == nil {
            if let range = paragraphRange(forLine: line) {
                textView.addAttributes([.paragraphStyle: base], range: range)
            }
        }
        for (line, spacing) in wanted where appliedGhostSpacing[line] != spacing {
            guard let range = paragraphRange(forLine: line),
                  let style = base.mutableCopy() as? NSMutableParagraphStyle
            else { continue }
            style.paragraphSpacingBefore = CGFloat(spacing.rowsBefore) * rowHeight
            style.paragraphSpacing = CGFloat(spacing.rowsAfter) * rowHeight
            textView.addAttributes([.paragraphStyle: style], range: range)
        }
        appliedGhostSpacing = wanted
        textView.needsLayout = true
    }

    private var gutterWidth: CGFloat = 40

    init(mode: Mode, gutterLayout: DiffGutterLayout) {
        self.mode = mode
        super.init(frame: .zero)
        gutter.layoutStyle = gutterLayout

        wantsLayer = true

        // Transparent stack: the underlay paints the background (and tints)
        // behind everything.
        let clipView = DiffClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true
        scrollView.documentView = textView
        clipView.onBoundsChange = { [weak self] in
            self?.handleScrolled()
        }

        textView.isEditable = mode == .edit
        textView.isSelectable = true
        textView.highlightSelectedLine = false
        textView.showsLineNumbers = false
        textView.isHorizontallyResizable = true
        textView.isIncrementalSearchingEnabled = true
        // Review documents are swapped wholesale (fold expansion, reloads);
        // the caret-follow scroll after such a swap would jump to the top and
        // discard the restored scroll position. Editors keep it for typing.
        textView.scrollsSelectionToVisibleOnTextChange = mode == .edit
        textView.onBecomeFirstResponder = { [weak self] in self?.onFocus?() }

        underlay.textView = textView
        underlay.clipView = scrollView.contentView
        gutter.textView = textView
        gutter.clipView = scrollView.contentView

        textView.handleCollapsedClick = { [weak self] point in
            self?.expandCollapsedRow(atDocumentY: point.y) ?? false
        }
        gutter.onExpandRun = { [weak self] fold in
            self?.activateFold(fold)
        }

        addSubview(underlay)
        addSubview(gutter)
        addSubview(scrollView)

        // Repaint decorations after every viewport layout pass; scroll
        // movements are reported synchronously by DiffClipView above.
        textView.addPlugin(DiffViewportSyncPlugin { [weak self] in
            self?.underlay.needsDisplay = true
            self?.gutter.needsDisplay = true
        })
    }

    /// Every scroll tick: repaint the viewport-fixed decoration layers and
    /// mirror the vertical offset to the sibling pane (split view).
    private func handleScrolled() {
        underlay.needsDisplay = true
        gutter.needsDisplay = true
        if !isSyncingScroll {
            onVerticalScroll?(scrollView.contentView.bounds.origin.y)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        let contentFrame = CGRect(
            x: gutterWidth, y: 0,
            width: max(0, bounds.width - gutterWidth), height: bounds.height
        )
        scrollView.frame = contentFrame
        underlay.frame = contentFrame
        // Row rects span the current width; a resize must repaint them.
        underlay.needsDisplay = true
        gutter.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        underlay.needsDisplay = true
        gutter.needsDisplay = true
    }

    /// Follow a sibling pane's vertical scroll without echoing it back.
    func setVerticalScrollOffset(_ y: CGFloat) {
        let clipView = scrollView.contentView
        guard abs(clipView.bounds.origin.y - y) > 0.01 else { return }
        isSyncingScroll = true
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
        isSyncingScroll = false
    }

    var verticalScrollOffset: CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    /// The fixed row height from the last applied paragraph style, for
    /// layout-independent scroll math.
    private var rowHeight: CGFloat = 0
    /// Review documents have a known row count; with the pinned line height
    /// that fixes the exact content height, so both split sides agree on
    /// their scroll range instead of trusting TextKit2's estimates (which
    /// undershoot runs of empty filler lines). Nil for the live edit buffer.
    private var fixedRowCount: Int?

    func setFixedRowCount(_ rows: Int?) {
        fixedRowCount = rows
        applyContentHeightOverride()
    }

    /// Marks the coming document swap as a fold expansion and reports it.
    private func activateFold(_ info: DiffCollapsedRun) {
        pendingExpansionSwap = true
        onExpandCollapsedRun?(info)
    }

    /// Swaps in a review document while keeping the reading position.
    ///
    /// Fold expansion inserts rows at the clicked separator, which is on
    /// screen — every row above the viewport keeps its index — so keeping the
    /// raw scroll offset leaves the content above the separator untouched
    /// while the revealed lines flow in at the click point (how GitHub and
    /// diffs.com behave). Other swaps (reloads, font/theme rebuilds) may
    /// change content anywhere, so they re-anchor to the first visible row
    /// carrying file line numbers instead.
    func setReviewDocument(_ text: NSAttributedString, decorations newDecorations: DiffDecorations) {
        let isExpansionSwap = pendingExpansionSwap
        pendingExpansionSwap = false
        let savedOffset = scrollView.contentView.bounds.origin.y

        var lineAnchor: (oldLine: Int?, newLine: Int?, viewportY: CGFloat)?
        if !isExpansionSwap, rowHeight > 0, !decorations.rows.isEmpty {
            for row in DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
            where row.frame.maxY > savedOffset {
                guard row.index < decorations.rows.count else { continue }
                let metadata = decorations.rows[row.index]
                if metadata.oldLine != nil || metadata.newLine != nil {
                    lineAnchor = (metadata.oldLine, metadata.newLine, row.frame.minY - savedOffset)
                    break
                }
            }
        }

        textView.attributedText = text
        decorations = newDecorations
        setFixedRowCount(newDecorations.rows.count)

        if isExpansionSwap {
            setVerticalScrollOffset(savedOffset)
            return
        }
        guard let lineAnchor else { return }
        if let index = newDecorations.rows.firstIndex(where: {
            $0.oldLine == lineAnchor.oldLine && $0.newLine == lineAnchor.newLine
        }) {
            setVerticalScrollOffset(max(0, CGFloat(index) * rowHeight - lineAnchor.viewportY))
        }
    }

    /// Expands the collapsed run whose separator row contains `documentY`
    /// (text-view coordinates); returns whether one was hit.
    private func expandCollapsedRow(atDocumentY documentY: CGFloat) -> Bool {
        guard let row = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
            .first(where: { documentY >= $0.frame.minY && documentY < $0.frame.maxY }),
            row.index < decorations.rows.count,
            let info = decorations.rows[row.index].collapsed
        else { return false }
        activateFold(info)
        return true
    }

    private func applyContentHeightOverride() {
        let height = fixedRowCount.map { CGFloat($0) * rowHeight }
        if textView.overrideContentHeight != height {
            textView.overrideContentHeight = height
            textView.needsLayout = true
        }
    }

    /// Guarded assignments: the font/color/paragraph-style setters restyle the
    /// whole document, and this runs on every re-render (each keystroke while
    /// editing).
    func applyTypography(font: NSFont, paragraphStyle: NSParagraphStyle, textColor: NSColor) {
        if textView.font != font {
            textView.font = font
        }
        if !textView.defaultParagraphStyle.isEqual(paragraphStyle) {
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes[.paragraphStyle] = paragraphStyle
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
        }
        if gutter.font != font {
            gutter.font = font
        }
        let labelFont = NSFont(
            descriptor: font.fontDescriptor, size: max(8, font.pointSize - 1.5)
        ) ?? font
        if underlay.labelFont != labelFont {
            underlay.labelFont = labelFont
        }
        rowHeight = paragraphStyle.maximumLineHeight
        applyContentHeightOverride()
    }

    /// First visible row index, for carrying the reading position across
    /// review/edit mode switches.
    var firstVisibleRowIndex: Int? {
        DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
            .first(where: { $0.frame.maxY > scrollView.contentView.bounds.minY + 1 })?
            .index
    }

    /// Scrolls so `rowIndex` is the first visible row. Rows have a fixed
    /// height (the paragraph style pins line height), so this needs no layout
    /// to have happened yet.
    func scrollToRow(_ rowIndex: Int) {
        guard rowIndex > 0, rowHeight > 0 else {
            setVerticalScrollOffset(0)
            return
        }
        setVerticalScrollOffset(CGFloat(rowIndex) * rowHeight)
    }
}
