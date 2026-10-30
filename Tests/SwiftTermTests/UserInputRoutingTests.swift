#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

/// Keeps the replies the terminal generates itself away from the host
/// delegate, as a host does when it forwards them on a separate channel.
private final class ReplyRecordingTerminalView: TerminalView {
    private let replies = Locked([[UInt8]]())

    nonisolated var recordedReplies: [[UInt8]] {
        replies.withLock { $0 }
    }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        replies.withLock { $0.append(Array(data)) }
    }
}

private final class InputCapturingDelegate: TerminalViewDelegate {
    var sent: [[UInt8]] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// User input the view encodes reaches ``TerminalViewDelegate/send(source:data:)``;
/// only the replies the terminal generates take `send(source: Terminal, data:)`.
@MainActor
struct UserInputRoutingTests {
    private let esc = "\u{1b}"

    private func makeView() -> (ReplyRecordingTerminalView, InputCapturingDelegate) {
        let view = ReplyRecordingTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 160))
        let delegate = InputCapturingDelegate()
        view.terminalDelegate = delegate
        return (view, delegate)
    }

    @Test func pastedTextTakesTheInputPathAndQueryRepliesDoNot() {
        let (view, delegate) = makeView()
        view.feed(text: "\(esc)[?2004h")

        view.pasteText("ls -l")

        #expect(delegate.sent == [Array("\(esc)[200~ls -l\(esc)[201~".utf8)])
        #expect(view.recordedReplies.isEmpty)

        // A status report is the terminal's own reply, not user input.
        view.feed(text: "\(esc)[5n")
        #expect(view.recordedReplies == [Array("\(esc)[0n".utf8)])
        #expect(delegate.sent.count == 1)
    }

    @Test func pasteRejectedBySafetyPolicyIsResentAsInput() {
        let (view, delegate) = makeView()

        // Unbracketed text with a newline needs the relaxed policy.
        view.pasteText("echo a\necho b")

        #expect(delegate.sent == [Array("echo a\recho b".utf8)])
        #expect(view.recordedReplies.isEmpty)
    }

    @Test func pastedTextRegistersSemanticSubmission() {
        let (view, delegate) = makeView()
        view.feed(text: "\(esc)]133;A;cl=line\u{07}>\(esc)]133;B\u{07}hi")
        #expect(view.withTerminal { $0.buffer.semanticInput } == .armed)

        view.pasteText("\r")

        #expect(delegate.sent == [[0x0d]])
        #expect(view.withTerminal { $0.buffer.semanticInput } == .submitted)
    }
}
#endif
