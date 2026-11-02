import CoreSSH
import Foundation

#if canImport(UIKit)
    import SwiftTerm
    import UIKit

    /// Bridges an SSH PTY (`ShellStreams` from CoreSSH) to a SwiftTerm
    /// `TerminalView` (spec §4.3). All interaction happens on the main actor:
    /// SwiftTerm views are UIKit-backed and the shell writer is thread-safe.
    ///
    /// `@preconcurrency` on the conformance is intentional: SwiftTerm's
    /// `TerminalViewDelegate` is not annotated for concurrency, so Swift 6
    /// would otherwise reject main-actor-isolated requirements.
    @MainActor
    public final class TerminalSession: @preconcurrency TerminalViewDelegate {
        public let terminalView: TerminalView
        public private(set) var title: String = ""
        public private(set) var currentDirectory: String?
        /// Set when tmux markers appear in the output (spec §4.2 attach hint).
        public var onTmuxDetected: (() -> Void)?

        private let stdin: ShellStdin
        private var outputTask: Task<Void, Never>?
        private let fontName: String
        private let theme: TerminalTheme

        /// Live font size (pinch-to-zoom on the phone changes it).
        public private(set) var currentFontSize: Int

        public init(
            shell: ShellStreams,
            fontName: String = "Menlo",
            fontSize: Int = 12,
            theme: TerminalTheme = .dark
        ) {
            stdin = shell.stdin
            self.fontName = fontName
            currentFontSize = fontSize
            self.theme = theme

            // Scrollback >= 10000 lines (spec §4.3).
            let options = TerminalOptions(scrollback: 10000)
            terminalView = TerminalView(frame: .zero, options: options)
            terminalView.terminalDelegate = self
            applyStyle()

            outputTask = Task { @MainActor [weak self] in
                for await event in shell.output {
                    self?.handle(event)
                }
            }
        }

        deinit {
            outputTask?.cancel()
        }

        /// Feed one shell event into the emulator.
        private func handle(_ event: ShellEvent) {
            switch event {
            case let .stdout(data):
                terminalView.feed(byteArray: Array(data)[0 ..< data.count])
                if TmuxDetector.containsTmuxMarker(in: data) {
                    onTmuxDetected?()
                }
            case let .stderr(data):
                terminalView.feed(byteArray: Array(data)[0 ..< data.count])
            case .exited:
                break
            }
        }

        public func stop() {
            outputTask?.cancel()
            outputTask = nil
        }

        /// Sends bytes to the remote shell (extension keyboard bar, pastes).
        public func send(_ text: String) {
            Task { try? await stdin.write(Data(text.utf8)) }
        }

        /// Sets the terminal font size, clamped to a readable range. Changing it
        /// reflows the emulator, which reports a new column count and resizes the
        /// remote PTY — this is pinch-to-zoom on the phone.
        public func setFontSize(_ size: Int) {
            let clamped = min(max(size, 8), 28)
            guard clamped != currentFontSize else { return }
            currentFontSize = clamped
            terminalView.font = font(ofSize: clamped)
        }

        private func applyStyle() {
            terminalView.nativeBackgroundColor = uiColor(theme.background)
            terminalView.nativeForegroundColor = uiColor(theme.foreground)
            terminalView.caretColor = uiColor(theme.cursor)
            terminalView.font = font(ofSize: currentFontSize)
            terminalView.installColors(theme.ansi.map(swiftColor))
        }

        private func font(ofSize size: Int) -> UIFont {
            UIFont(name: fontName, size: CGFloat(size))
                ?? UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        }

        private func uiColor(_ rgba: TerminalRGBA) -> UIColor {
            UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }

        private func swiftColor(_ rgba: TerminalRGBA) -> SwiftTerm.Color {
            SwiftTerm.Color(
                red8: UInt16(rgba.red * 255),
                green8: UInt16(rgba.green * 255),
                blue8: UInt16(rgba.blue * 255)
            )
        }

        // MARK: - TerminalViewDelegate

        public func send(source _: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            Task { try? await stdin.write(payload) }
        }

        public func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) {
            Task { try? await stdin.resize(cols: newCols, rows: newRows) }
        }

        public func setTerminalTitle(source _: TerminalView, title: String) {
            self.title = title
        }

        public func hostCurrentDirectoryUpdate(source _: TerminalView, directory: String?) {
            currentDirectory = directory
        }

        public func scrolled(source _: TerminalView, position _: Double) {}

        public func requestOpenLink(source _: TerminalView, link: String, params _: [String: String]) {
            guard let url = URL(string: link), UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url)
        }

        public func clipboardCopy(source _: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }

        public func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
    }
#endif
