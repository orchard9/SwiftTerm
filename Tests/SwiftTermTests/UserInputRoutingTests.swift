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

    /// A view in a borderless window so AppKit events carry usable locations.
    private func makeWindowedView() -> (ReplyRecordingTerminalView, InputCapturingDelegate, NSWindow) {
        let (view, delegate) = makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        return (view, delegate, window)
    }

    private func leftClick(on view: TerminalView, in window: NSWindow,
                           col: Int) -> (down: NSEvent, up: NSEvent) {
        let point = CGPoint(x: (CGFloat(col) + 0.5) * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!
        return (down, up)
    }

    @Test func mouseReportsTakeTheInputPathAndQueryRepliesDoNot() {
        let (view, delegate, window) = makeWindowedView()
        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
        let click = leftClick(on: view, in: window, col: 1)

        view.mouseDown(with: click.down)
        view.mouseUp(with: click.up)

        #expect(delegate.sent == [Array("\(esc)[<0;2;1M".utf8), Array("\(esc)[<0;2;1m".utf8)])
        #expect(view.recordedReplies.isEmpty)

        // A status report is the terminal's own reply, not user input.
        view.feed(text: "\(esc)[5n")
        #expect(view.recordedReplies == [Array("\(esc)[0n".utf8)])
        #expect(delegate.sent.count == 2)
    }

    @Test func semanticPromptClickTakesTheInputPath() {
        let (view, delegate, window) = makeWindowedView()
        view.feed(text: "\(esc)]133;A;click_events=1\u{07}>\(esc)]133;B\u{07}hi")
        let click = leftClick(on: view, in: window, col: 1)

        view.mouseDown(with: click.down)
        view.mouseUp(with: click.up)

        #expect(delegate.sent == [Array("\(esc)[<0;2;1M".utf8)])
        #expect(view.recordedReplies.isEmpty)
        // Like a mouse report, the click is not a submission.
        #expect(view.withTerminal { $0.buffer.semanticInput } == .armed)
    }

    @Test func buttonDragTakesTheInputPath() {
        let (view, delegate, window) = makeWindowedView()
        view.feed(text: "\(esc)[?1002h\(esc)[?1006h")
        let click = leftClick(on: view, in: window, col: 1)
        let dragPoint = CGPoint(x: 3.5 * view.cellDimension.width,
                                y: view.frame.height - 0.5 * view.cellDimension.height)
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: dragPoint,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 3, clickCount: 1, pressure: 1)!

        view.mouseDown(with: click.down)
        view.mouseDragged(with: drag)

        #expect(delegate.sent == [Array("\(esc)[<0;2;1M".utf8), Array("\(esc)[<32;4;1M".utf8)])
        #expect(view.recordedReplies.isEmpty)
    }

    /// Hover is not deliberate input: a host must be able to keep it from
    /// counting as typing, so it takes the reply path.
    @Test func hoverMotionTakesTheReplyPath() {
        let (view, delegate, window) = makeWindowedView()
        view.feed(text: "\(esc)[?1003h\(esc)[?1006h")
        let point = CGPoint(x: 2.5 * view.cellDimension.width,
                            y: view.frame.height - 0.5 * view.cellDimension.height)
        let move = NSEvent.mouseEvent(with: .mouseMoved, location: point,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 0, pressure: 0)!

        view.mouseMoved(with: move)

        #expect(view.recordedReplies == [Array("\(esc)[<35;3;1M".utf8)])
        #expect(delegate.sent.isEmpty)
    }

    /// Scrolling is not typing either: wheel reports take the reply path.
    @Test func wheelReportsTakeTheReplyPath() throws {
        let (view, delegate, _) = makeWindowedView()
        view.feed(text: "\(esc)[?1000h\(esc)[?1006h")
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                      wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: 10, y: 10)
        let wheel = try #require(NSEvent(cgEvent: cg))

        view.scrollWheel(with: wheel)

        let replies = view.recordedReplies
        #expect(!replies.isEmpty)
        #expect(replies.allSatisfy { String(decoding: $0, as: UTF8.self).hasPrefix("\(esc)[<64;") })
        #expect(delegate.sent.isEmpty)
    }
}
#endif
