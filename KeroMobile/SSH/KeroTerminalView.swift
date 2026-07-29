import SwiftTerm
import UIKit

final class KeroTerminalView: TerminalView, TerminalViewDelegate {
    weak var session: TerminalSessionModel?

    private var lastSize: CGSize = .zero
    private var metalSetupAttempted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !metalSetupAttempted else {
            return
        }
        metalSetupAttempted = true
        try? setUseMetal(true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        lastSize = bounds.size
        let terminal = getTerminal()
        session?.resize(
            columns: terminal.cols,
            rows: terminal.rows,
            viewSize: bounds.size,
            scale: window?.screen.scale ?? UIScreen.main.scale
        )
    }

    private func configure() {
        terminalDelegate = self
        backgroundColor = .black
        nativeBackgroundColor = .black
        nativeForegroundColor = UIColor(
            red: 0.86,
            green: 0.89,
            blue: 0.87,
            alpha: 1
        )
        caretColor = UIColor(
            red: 0.45,
            green: 0.82,
            blue: 0.62,
            alpha: 1
        )
        selectedTextBackgroundColor = UIColor.systemGreen.withAlphaComponent(0.32)
        keyboardAppearance = .dark
        linkReporting = .implicit
        linkHighlightMode = .always
        // Kero owns the persistent touch-key row below the terminal. SwiftTerm's
        // keyboard accessory would otherwise duplicate those controls.
        inputAccessoryView = nil
        accessibilityLabel = "SSH terminal"
    }

    func setFontSize(_ size: CGFloat) {
        guard abs(font.pointSize - size) > 0.1 else {
            return
        }
        font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(
            columns: newCols,
            rows: newRows,
            viewSize: bounds.size,
            scale: window?.screen.scale ?? UIScreen.main.scale
        )
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        session?.updateTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(
        source: TerminalView,
        link: String,
        params: [String: String]
    ) {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            return
        }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else {
            return
        }
        UIPasteboard.general.string = text
    }

    func clipboardRead(source: TerminalView) -> Data? {
        // A remote process must not silently read the local clipboard.
        nil
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
