//
//  SelectionResizeTests.swift
//  SwiftTerm
//
//  A rows-only resize (an iOS software keyboard rising or falling) keeps the
//  selection; a column change reflows lines and drops it.
//

#if os(macOS)
import Foundation
import Testing
import AppKit
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct SelectionResizeTests {
    private func makeView(rows: Int) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        _ = view.processSizeChange(newSize: size(view, cols: 40, rows: rows))
        return view
    }

    private func size(_ view: TerminalView, cols: Int, rows: Int) -> CGSize {
        CGSize(width: CGFloat(cols) * view.cellDimension.width + 0.5,
               height: CGFloat(rows) * view.cellDimension.height + 0.5)
    }

    /// Fills every row so shrinking pushes lines into scrollback, then
    /// selects the word "target" on the last screen row.
    private func selectTarget(in view: TerminalView) {
        let rows = view.withTerminal { $0.rows }
        for i in 0..<(rows - 1) { view.feed(text: "line \(i)\r\n") }
        view.feed(text: "pick target here")
        view.withTerminal { terminal in
            let row = terminal.displayBuffer.yBase + rows - 1
            view.selection.selectWordOrExpression(at: Position(col: 6, row: row),
                                                  in: terminal.displayBuffer)
        }
    }

    @Test func rowsOnlyResizeKeepsSelection() {
        let view = makeView(rows: 40)
        #expect(view.withTerminal { ($0.cols, $0.rows) } == (40, 40))
        selectTarget(in: view)
        #expect(view.selection.getSelectedText() == "target")

        #expect(view.processSizeChange(newSize: size(view, cols: 40, rows: 24)))
        #expect(view.withTerminal { $0.rows } == 24)
        #expect(view.selection.active)
        #expect(view.selection.getSelectedText() == "target")

        #expect(view.processSizeChange(newSize: size(view, cols: 40, rows: 40)))
        #expect(view.withTerminal { $0.rows } == 40)
        #expect(view.selection.active)
        #expect(view.selection.getSelectedText() == "target")
    }

    @Test func columnResizeClearsSelection() {
        let view = makeView(rows: 40)
        selectTarget(in: view)
        #expect(view.selection.getSelectedText() == "target")

        #expect(view.processSizeChange(newSize: size(view, cols: 30, rows: 40)))
        #expect(view.withTerminal { $0.cols } == 30)
        #expect(!view.selection.active)
    }
}
#endif
