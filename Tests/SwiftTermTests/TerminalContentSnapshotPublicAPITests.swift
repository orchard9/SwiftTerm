import Testing
import SwiftTerm

struct TerminalContentSnapshotPublicAPITests {
    @Test(arguments: [(true, 1, false), (true, 2, true), (false, 2, false)])
    func publicInitializersExposePendingWrapBoundary(sample: (Bool, Int, Bool)) {
        let dimensions = TerminalDimensions(cols: 2, rows: 1)
        let input = TerminalInputStateSnapshot(
            dimensions: dimensions,
            isAlternateBuffer: false,
            applicationCursor: false,
            applicationKeypad: false,
            bracketedPasteMode: false,
            mouseMode: .off,
            keyboardEnhancementFlags: [],
            focusReportingEnabled: false)
        let layout = TerminalContentLayoutSnapshot(
            autoWrapEnabled: sample.0,
            insertModeEnabled: false,
            leftRightMarginModeEnabled: false,
            originModeEnabled: false,
            leftMargin: 0,
            rightMargin: 1,
            scrollTop: 0,
            scrollBottom: 0,
            synchronizedOutputActive: false,
            cursorVisible: true)
        let cell = TerminalCellSnapshot(text: "x", width: 1, attribute: .empty)
        let row = TerminalContentRowSnapshot(
            absoluteRow: 7,
            cells: [cell],
            isSingleWidth: true,
            isWrapped: true)
        let snapshot = TerminalContentSnapshot(
            inputState: input,
            layout: layout,
            capturedRange: 7..<8,
            liveTopRow: 7,
            rows: [row],
            cursorRow: 7,
            cursorColumn: sample.1)

        #expect(snapshot.isWrapPending == sample.2)
    }

    @Test func publicMetricsAndInitializerUseDisplayRowTextConversion() throws {
        let wideWidth = try #require(TerminalTextMetrics.simpleGraphemeWidth("界"))
        let row = TerminalContentRowSnapshot(
            absoluteRow: 8,
            cells: [
                TerminalCellSnapshot(text: "界", width: wideWidth, attribute: .empty),
                TerminalCellSnapshot(text: "\u{0}", width: 0, attribute: .empty),
                TerminalCellSnapshot(text: "", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: "x", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: " ", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: " ", width: 1, attribute: .empty),
                TerminalCellSnapshot(text: "\u{0}", width: 1, attribute: .empty),
            ],
            isSingleWidth: true,
            isWrapped: false)

        #expect(row.text == "界 x  ")
        #expect(!row.text.contains("\u{0}"))
    }

    @Test func publicInitializerHandlesOutOfRangeSyntheticWidths() {
        let row = TerminalContentRowSnapshot(
            absoluteRow: 9,
            cells: [
                TerminalCellSnapshot(text: "a", width: Int.max, attribute: .empty),
            ],
            isSingleWidth: true)

        #expect(row.text == "a")
    }
}
