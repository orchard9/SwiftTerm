import Testing
@testable import SwiftTerm

struct TerminalContentSnapshotCoreTests {
    private final class Fixture {
        let delegate = TerminalTestDelegate()
        let terminal: Terminal

        init(scrollback: Int = 20) {
            terminal = Terminal(
                delegate: delegate,
                options: TerminalOptions(cols: 12, rows: 4, scrollback: scrollback))
        }

        func feed(_ text: String) {
            terminal.terminalLock.withLock {
                terminal.feed(text: text)
            }
        }
    }

    @Test func terminalCopiedModesReflectInputState() {
        let fixture = Fixture()
        fixture.feed("\u{1b}=\u{1b}[?1h\u{1b}[?1002h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[>8u")
        let input = fixture.terminal.inputStateSnapshot()
        #expect(input.dimensions == TerminalDimensions(cols: 12, rows: 4))
        #expect(input.isAlternateBuffer == false)
        #expect(input.applicationCursor)
        #expect(input.applicationKeypad)
        #expect(input.mouseMode == .buttonEventTracking)
        #expect(input.bracketedPasteMode)
        #expect(input.keyboardEnhancementFlags.contains(.reportAllKeys))
        #expect(input.focusReportingEnabled)

        fixture.feed("\u{1b}>\u{1b}[?1l\u{1b}[?1002l\u{1b}[?2004l\u{1b}[?1004l")
        let reset = fixture.terminal.inputStateSnapshot()
        #expect(reset.applicationCursor == false)
        #expect(reset.applicationKeypad == false)
        #expect(reset.mouseMode == .off)
        #expect(reset.bracketedPasteMode == false)
        #expect(reset.focusReportingEnabled == false)
    }

    @Test(arguments: [
        ("", ""),
        ("A", "A"),
        ("A  ", "A  "),
        ("A\u{1b}[3GX", "A X"),
        ("界", "界"),
        ("界 ", "界 "),
        ("1234567890界", "1234567890界"),
        ("12345678901界", "12345678901"),
        ("e\u{301}", "e\u{301}"),
        ("\u{A98F}\u{A9C0}\u{A994}\u{A9B8}", "\u{A98F}\u{A9C0}\u{A994}\u{A9B8}"),
        ("\u{1b}[44m\u{1b}[2K", ""),
    ])
    func rowTextMatchesDisplayTextWithoutNUL(sample: (String, String)) throws {
        let fixture = Fixture()
        fixture.feed(sample.0)
        let row = try #require(fixture.terminal.contentSnapshot(region: .viewport).rows.first)
        let reference = fixture.terminal.terminalLock.withLock {
            fixture.terminal.translateBufferLineToString(
                buffer: fixture.terminal.displayBuffer,
                line: fixture.terminal.displayBuffer.yDisp,
                start: 0,
                end: -1)
        }
        #expect(row.text == reference)
        #expect(row.text == sample.1)
        #expect(!row.text.contains("\u{0}"))
    }

    @Test func cellsPreserveNULTailsWhileRowTextHidesThem() throws {
        let wide = Fixture()
        wide.feed("界 ")
        let wideRow = try #require(wide.terminal.contentSnapshot(region: .viewport).rows.first)
        #expect(wideRow.cells[0].text == "界")
        #expect(wideRow.cells[0].width == 2)
        #expect(wideRow.cells[1].text == "\u{0}")
        #expect(wideRow.cells[1].width == 0)
        #expect(wideRow.text == "界 ")

        let gap = Fixture()
        gap.feed("A\u{1b}[3GX")
        let gapRow = try #require(gap.terminal.contentSnapshot(region: .viewport).rows.first)
        #expect(gapRow.cells[1].text == "\u{0}")
        #expect(gapRow.cells[1].width == 1)
        #expect(gapRow.text == "A X")
    }

    @Test func copiedRowsExposeWrapFlags() throws {
        let fixture = Fixture()
        fixture.feed("1234567890123\r\nnext")
        let snapshot = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(snapshot.rows[0].text == "123456789012")
        #expect(snapshot.rows[0].isWrapped == false)
        #expect(snapshot.rows[1].text == "3")
        #expect(snapshot.rows[1].isWrapped == true)
        #expect(snapshot.rows[2].text == "next")
        #expect(snapshot.rows[2].isWrapped == false)
    }

    @Test(arguments: [false, true])
    func pendingWrapPreservesLogicalColumnAndDistinguishesWideFit(useMargins: Bool) {
        let fixture = Fixture()
        if useMargins {
            fixture.feed("\u{1b}[?69h\u{1b}[3;8s")
        }
        let left = useMargins ? 2 : 0
        let right = useMargins ? 7 : 11
        fixture.feed("\u{1b}[1;\(right + 1)Ha")
        let narrowEdge = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(narrowEdge.layout.leftMargin == left)
        #expect(narrowEdge.layout.rightMargin == right)
        #expect(narrowEdge.cursorColumn == right + 1)
        #expect(narrowEdge.isWrapPending)
        fixture.feed("b")
        let wrapped = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(wrapped.cursorRow == wrapped.liveTopRow + 1)
        #expect(wrapped.cursorColumn == left + 1)
        #expect(wrapped.rows[1].cells[left].text == "b")
        #expect(wrapped.rows[1].isWrapped)
        #expect(!wrapped.isWrapPending)

        fixture.feed("\u{1b}[2;\(right)H界")
        let wideEdge = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(wideEdge.rows[1].cells[right - 1].width == 2)
        #expect(wideEdge.rows[1].cells[right].width == 0)
        #expect(wideEdge.cursorColumn == right + 1)
        #expect(wideEdge.isWrapPending)

        fixture.feed("\u{1b}[2;\(right + 1)H")
        let beforeWide = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(beforeWide.cursorColumn == right)
        #expect(!beforeWide.isWrapPending)
        fixture.feed("界")
        let wideOverflow = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(wideOverflow.cursorRow == wideOverflow.liveTopRow + 2)
        #expect(wideOverflow.cursorColumn == left + 2)
        #expect(wideOverflow.rows[2].cells[left].text == "界")
        #expect(wideOverflow.rows[2].cells[left].width == 2)
        #expect(wideOverflow.rows[2].isWrapped)
    }

    @Test func disabledWrapOverwritesNarrowEdgeAndRejectsWideOverflow() {
        let fixture = Fixture()
        fixture.feed("\u{1b}[?69h\u{1b}[3;8s\u{1b}[?7l\u{1b}[1;8Ha")
        let edge = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(!edge.layout.autoWrapEnabled)
        #expect(edge.cursorColumn == 8)
        #expect(!edge.isWrapPending)
        fixture.feed("b界")
        let after = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(after.cursorRow == after.liveTopRow)
        #expect(after.cursorColumn == 8)
        #expect(after.rows[0].cells[7].text == "b")
        #expect(after.rows[1].text.isEmpty)
        #expect(!after.isWrapPending)

        fixture.feed("\u{1b}[?69l\u{1b}[1;12Hx")
        let fullWidth = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(!fullWidth.layout.leftRightMarginModeEnabled)
        #expect(fullWidth.layout.leftMargin == 0)
        #expect(fullWidth.layout.rightMargin == 11)
        #expect(fullWidth.rows[0].cells[11].text == "x")
    }

    @Test func originAndScrollBoundsUseLiveScreenCoordinates() {
        let fixture = Fixture()
        fixture.feed("history\r\nhistory\r\nhistory\r\nhistory\r\nhistory")
        fixture.feed("\u{1b}[2J\u{1b}[Htop\u{1b}[4;1Hbottom")
        fixture.feed("\u{1b}[2;3r\u{1b}[?69h\u{1b}[3;8s\u{1b}[?6h\u{1b}[H")
        let origin = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(origin.liveTopRow > 0)
        #expect(origin.layout.originModeEnabled)
        #expect(origin.layout.scrollTop == 1)
        #expect(origin.layout.scrollBottom == 2)
        #expect(origin.cursorRow == origin.liveTopRow + origin.layout.scrollTop)
        #expect(origin.cursorColumn == origin.layout.leftMargin)

        fixture.feed("abcdefghijkl")
        let edge = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(edge.cursorRow == edge.liveTopRow + edge.layout.scrollBottom)
        #expect(edge.isWrapPending)
        fixture.feed("m")
        let scrolled = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(scrolled.rows[0].text == "top")
        #expect(scrolled.rows[1].text == "  ghijkl")
        #expect(scrolled.rows[2].text == "  m")
        #expect(scrolled.rows[3].text == "bottom")
        #expect(scrolled.cursorRow == edge.cursorRow)
        #expect(scrolled.cursorColumn == 3)
        #expect(edge.rows[1].text == "  abcdef")
        #expect(edge.rows[2].text == "  ghijkl")
    }

    @Test func softResetSnapshotReportsEffectiveInsertionRatherThanModeMirror() {
        let fixture = Fixture()
        fixture.feed("abcd\u{1b}[4h\u{1b}[!p\u{1b}[1;2HX")
        let inserted = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(inserted.layout.insertModeEnabled)
        #expect(inserted.rows[0].text == "aXbcd")
        fixture.feed("\u{1b}[4l\u{1b}[1;2HY")
        let replaced = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(!replaced.layout.insertModeEnabled)
        #expect(replaced.rows[0].text == "aYbcd")
        #expect(inserted.rows[0].text == "aXbcd")
    }

    @Test func selectedBufferBoundsRemainDistinctFromGlobalModes() {
        let fixture = Fixture()
        fixture.feed("\u{1b}[?69h\u{1b}[3;8s\u{1b}[1;3r\u{1b}[1;3HN")
        fixture.feed("\u{1b}[?1049h\u{1b}[4;10s\u{1b}[2;4r\u{1b}[?6h\u{1b}[HA")
        fixture.feed("\u{1b}[?25l\u{1b}[?2026h")
        let active = fixture.terminal.contentSnapshot(region: .viewport)
        let normal = fixture.terminal.contentSnapshot(region: .viewport, buffer: .normal)
        #expect(active.layout.leftMargin == 3)
        #expect(active.layout.rightMargin == 9)
        #expect(active.layout.scrollTop == 1)
        #expect(active.layout.scrollBottom == 3)
        #expect(active.cursorRow == active.liveTopRow + 1)
        #expect(active.cursorColumn == 4)
        #expect(active.rows[1].cells[3].text == "A")
        #expect(normal.layout.leftMargin == 2)
        #expect(normal.layout.rightMargin == 7)
        #expect(normal.layout.scrollTop == 0)
        #expect(normal.layout.scrollBottom == 2)
        #expect(normal.cursorRow == normal.liveTopRow)
        #expect(normal.cursorColumn == 3)
        #expect(normal.rows[0].cells[2].text == "N")
        for snapshot in [active, normal] {
            #expect(snapshot.inputState.isAlternateBuffer)
            #expect(snapshot.layout.leftRightMarginModeEnabled)
            #expect(snapshot.layout.originModeEnabled)
            #expect(snapshot.layout.synchronizedOutputActive)
            #expect(!snapshot.layout.cursorVisible)
        }
        fixture.feed("\u{1b}[?2026l\u{1b}[?25h\u{1b}[?6l")
        let ended = fixture.terminal.contentSnapshot(region: .viewport, buffer: .normal)
        #expect(!ended.layout.synchronizedOutputActive)
        #expect(ended.layout.cursorVisible)
        #expect(!ended.layout.originModeEnabled)
        #expect(normal.layout.synchronizedOutputActive)
        #expect(!normal.layout.cursorVisible)
    }

    @Test func lineWidthEligibilityAndLayoutSurviveResizeAndResetAsValues() {
        let fixture = Fixture()
        fixture.feed("\u{1b}#6wide\u{1b}[2;1H\u{1b}#3top\u{1b}[3;1H\u{1b}#4bottom")
        fixture.feed("\u{1b}[4;1Hsingle\u{1b}[?69h\u{1b}[3;10s\u{1b}[2;4r\u{1b}[4h\u{1b}[?7l")
        let copied = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(copied.rows.map(\.isSingleWidth) == [false, false, false, true])
        fixture.terminal.terminalLock.withLock {
            fixture.terminal.resize(cols: 8, rows: 3)
        }
        let resized = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(resized.inputState.dimensions == TerminalDimensions(cols: 8, rows: 3))
        #expect(resized.layout.rightMargin == 7)
        #expect(resized.layout.scrollBottom == 2)
        #expect(resized.rows.allSatisfy { $0.cells.count == 8 })
        fixture.feed("\u{1b}c")
        let reset = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(reset.layout.autoWrapEnabled)
        #expect(!reset.layout.insertModeEnabled)
        #expect(!reset.layout.leftRightMarginModeEnabled)
        #expect(!reset.layout.originModeEnabled)
        #expect(reset.layout.leftMargin == 0)
        #expect(reset.layout.rightMargin == 7)
        #expect(reset.layout.scrollTop == 0)
        #expect(reset.layout.scrollBottom == 2)
        #expect(reset.rows.allSatisfy { $0.isSingleWidth })
        #expect(reset.rows.allSatisfy { $0.text.isEmpty })
        #expect(copied.inputState.dimensions == TerminalDimensions(cols: 12, rows: 4))
        #expect(copied.layout.rightMargin == 9)
        #expect(copied.layout.scrollTop == 1)
        #expect(copied.layout.scrollBottom == 3)
        #expect(copied.layout.insertModeEnabled)
        #expect(!copied.layout.autoWrapEnabled)
        #expect(copied.rows.map(\.text) == ["wide", "top", "bottom", "single"])
        #expect(copied.rows.map(\.isSingleWidth) == [false, false, false, true])
    }

    @Test func inactiveNormalBufferKeepsItsOwnGeometryDuringAlternateResize() {
        let fixture = Fixture()
        fixture.feed("one\r\ntwo\r\nthree\r\nfour\r\n123456789012")
        let before = fixture.terminal.contentSnapshot(region: .history(maximumScrollbackRows: 10))
        fixture.feed("\u{1b}[?1049h")
        fixture.terminal.terminalLock.withLock {
            fixture.terminal.resize(cols: 8, rows: 3)
        }
        let normal = fixture.terminal.contentSnapshot(
            region: .history(maximumScrollbackRows: 10), buffer: .normal)
        #expect(normal.inputState.isAlternateBuffer)
        #expect(normal.inputState.dimensions == TerminalDimensions(cols: 8, rows: 3))
        #expect(normal.layout.rightMargin == 11)
        #expect(normal.layout.scrollBottom == 3)
        #expect(normal.liveTopRow == before.liveTopRow)
        #expect(normal.cursorRow == normal.liveTopRow + normal.layout.scrollBottom)
        #expect(normal.cursorColumn == 12)
        #expect(normal.isWrapPending)
        #expect(normal.rows == before.rows)
        let active = fixture.terminal.contentSnapshot(region: .viewport)
        #expect(active.layout.rightMargin == 7)
        #expect(active.layout.scrollBottom == 2)
        #expect(active.rows.count == 3)
        #expect(active.rows.allSatisfy { $0.cells.count == 8 })
    }

    @Test func narrowedAlternateScreenDoesNotExposeOffscreenCells() throws {
        let fixture = Fixture()
        fixture.feed("\u{1b}[?1049hABCDEFGHIJKL")
        fixture.terminal.terminalLock.withLock {
            fixture.terminal.resize(cols: 8, rows: 4)
            fixture.terminal.feed(text: "\u{1b}[2J\u{1b}[Hx")
        }

        let snapshot = fixture.terminal.contentSnapshot(region: .viewport)
        let row = try #require(snapshot.rows.first)
        #expect(snapshot.inputState.dimensions == TerminalDimensions(cols: 8, rows: 4))
        #expect(row.cells.count == 8)
        #expect(row.text == "x")
    }

    @Test func normalBufferIsCopiedWhileAlternateScreenIsActive() throws {
        let fixture = Fixture()
        fixture.feed("shell1\r\nshell2\r\nshell3\r\nshell4\r\nshell5")
        fixture.feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[Heditor")

        let active = fixture.terminal.contentSnapshot(region: .history(maximumScrollbackRows: 10))
        #expect(active.inputState.isAlternateBuffer)
        #expect(active.rows.map(\.text).contains("editor"))

        let normal = fixture.terminal.contentSnapshot(region: .history(maximumScrollbackRows: 10),
                                                      buffer: .normal)
        #expect(normal.inputState.isAlternateBuffer)
        #expect(normal.rows.map(\.text) == ["shell1", "shell2", "shell3", "shell4", "shell5"])
        let cursorIndex = normal.cursorRow - normal.capturedRange.lowerBound
        #expect(normal.rows[cursorIndex].text == "shell5")
        #expect(normal.cursorColumn == 6)
    }

    @Test func historyIsBoundedAndUsesScrollInvariantCoordinates() throws {
        let fixture = Fixture(scrollback: 800)
        fixture.feed((0..<1_000).map { "row\($0)\r\n" }.joined())
        let bounded = fixture.terminal.contentSnapshot(
            region: .history(maximumScrollbackRows: 500))
        #expect(bounded.rows.count == 504)
        #expect(bounded.capturedRange.count == bounded.rows.count)
        #expect(bounded.rows.map(\.absoluteRow) == Array(bounded.capturedRange))
        #expect(bounded.liveTopRow == bounded.capturedRange.upperBound - 4)
        #expect(bounded.capturedRange.lowerBound > 0)
    }

    @Test func valueTypesAreCheckedSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(TerminalDimensions.self)
        requireSendable(TerminalInputStateSnapshot.self)
        requireSendable(TerminalContentLayoutSnapshot.self)
        requireSendable(TerminalContentRegion.self)
        requireSendable(TerminalCellSnapshot.self)
        requireSendable(TerminalContentRowSnapshot.self)
        requireSendable(TerminalContentSnapshot.self)
    }

    #if !os(iOS) && !os(Windows) && !os(WASI)
    @Test func headlessTerminalExposesSnapshots() throws {
        let headless = HeadlessTerminal(
            options: TerminalOptions(cols: 12, rows: 4, scrollback: 20),
            directDelivery: true
        ) { _ in }
        headless.dataReceived(slice: Array("headless".utf8)[...])
        #expect(headless.terminalInputStateSnapshot().dimensions == TerminalDimensions(cols: 12, rows: 4))
        let snapshot = headless.terminalContentSnapshot(region: .viewport)
        #expect(snapshot.rows.first?.text == "headless")
    }
    #endif
}
