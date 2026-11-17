import AppKit
import SwiftUI

/// Spreadsheet view of a page of documents: an NSTableView, so thousands of
/// rows and dozens of columns scroll at 120 Hz.
struct DocumentTable: NSViewRepresentable {
    @Bindable var m: DocumentsModel

    func makeCoordinator() -> Coordinator { Coordinator(m) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let tv = NSTableView()
        tv.style = .fullWidth
        tv.usesAlternatingRowBackgroundColors = true
        tv.gridStyleMask = [.solidVerticalGridLineMask]
        tv.gridColor = Theme.hairline
        tv.rowHeight = 24
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsColumnReordering = true
        tv.allowsMultipleSelection = false
        tv.backgroundColor = Theme.panel
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.target = context.coordinator
        tv.doubleAction = #selector(Coordinator.doubleClick(_:))
        scroll.documentView = tv
        context.coordinator.table = tv
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.m = m
        context.coordinator.reload()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var m: DocumentsModel
        weak var table: NSTableView?
        private var shownDocs: [BDoc] = []
        private var shownColumns: [String] = []

        init(_ m: DocumentsModel) { self.m = m }

        @MainActor func reload() {
            guard let table else { return }
            let cols = m.columns
            if cols != shownColumns {
                for c in table.tableColumns { table.removeTableColumn(c) }
                let idx = NSTableColumn(identifier: .init("#"))
                idx.title = ""
                idx.width = 44
                idx.minWidth = 30
                table.addTableColumn(idx)
                for c in cols {
                    let col = NSTableColumn(identifier: .init(c))
                    col.title = c
                    col.headerCell.font = .systemFont(ofSize: 11.5, weight: .semibold)
                    col.width = width(for: c)
                    col.minWidth = 50
                    table.addTableColumn(col)
                }
                shownColumns = cols
            }
            if m.docs != shownDocs {
                shownDocs = m.docs
                table.reloadData()
            }
            let sel = m.selected.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != sel { table.selectRowIndexes(sel, byExtendingSelection: false) }
        }

        @MainActor private func width(for col: String) -> CGFloat {
            if col == "_id" { return 210 }
            let sample = m.docs.prefix(30).compactMap { $0[col] }.map { BFormat.preview($0, max: 60).count }
            let chars = max(col.count + 2, sample.max() ?? 8)
            return CGFloat(min(max(chars, 6), 46)) * 7.4 + 16
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shownDocs.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column else { return nil }
            let id = column.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let tf = NSTextField(labelWithString: "")
                tf.lineBreakMode = .byTruncatingTail
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            let tf = cell.textField!
            if id.rawValue == "#" {
                tf.stringValue = "\(row + 1)"
                tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                tf.textColor = Theme.text3
                tf.alignment = .right
                return cell
            }
            tf.alignment = .left
            tf.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            if let v = shownDocs[row][id.rawValue] {
                tf.stringValue = BFormat.preview(v, max: 200)
                tf.textColor = v.isContainer ? Theme.text3 : Theme.typeColor(v)
                if case .number = v.numberKind { tf.alignment = .right }
            } else {
                tf.stringValue = "—"
                tf.textColor = Theme.hairline.withAlphaComponent(0.4)
            }
            return cell
        }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard let t = table else { return }
            let r = t.selectedRow
            Task { @MainActor in self.m.selected = r >= 0 ? r : nil }
        }

        @objc func doubleClick(_ sender: Any?) {
            guard let t = table, t.clickedRow >= 0 else { return }
            let r = t.clickedRow
            Task { @MainActor in if !self.m.session.readOnly { self.m.beginEdit(r) } }
        }
    }
}

extension BValue {
    enum NumberKind { case number, other }
    var numberKind: NumberKind {
        switch self { case .double, .int32, .int64, .decimal: return .number; default: return .other }
    }
}
