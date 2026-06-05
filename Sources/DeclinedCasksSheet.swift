import AppKit

/// Sheet for managing the persistent "don't suggest this cask" list. Backed
/// by `~/Library/Application Support/UpdateAll/declined-casks.json`. The
/// scan's safe-bucket prompt appends a token when the user clicks No; this
/// sheet lets them un-block one or more without editing JSON by hand.
final class DeclinedCasksSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var sheet: NSWindow!
    private var table: NSTableView!
    private weak var removeButton: NSButton?
    private var tokens: [String] = []

    /// Present as a sheet attached to `parent`. Saves on Done; cancel discards.
    func present(over parent: NSWindow) {
        tokens = Registry.declinedCasks().sorted()
        buildWindow()
        parent.beginSheet(sheet, completionHandler: nil)
    }

    private func buildWindow() {
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        sheet.title = "Don't suggest these casks"
        sheet.isReleasedWhenClosed = false

        let info = NSTextField(wrappingLabelWithString:
            "These cask tokens are skipped during scan so the safe-bucket prompt never re-offers them. Select rows and click Remove to allow them again on the next scan.")
        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder

        table = NSTableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .inset
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("token"))
        col.title = "Cask"
        col.minWidth = 200
        table.addTableColumn(col)
        scroll.documentView = table

        let remove = NSButton(title: "Remove",
                              target: self,
                              action: #selector(removeSelected))
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.bezelStyle = .rounded
        remove.isEnabled = false
        removeButton = remove

        let done = NSButton(title: "Done",
                            target: self,
                            action: #selector(doneTapped))
        done.translatesAutoresizingMaskIntoConstraints = false
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let content = sheet.contentView!
        content.addSubview(info)
        content.addSubview(scroll)
        content.addSubview(remove)
        content.addSubview(done)
        NSLayoutConstraint.activate([
            info.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: remove.topAnchor, constant: -14),

            remove.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            remove.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { tokens.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("token-cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                   ?? makeTokenCell(identifier: id)
        cell.textField?.stringValue = tokens[row]
        return cell
    }

    private func makeTokenCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12)
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton?.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    // MARK: Actions

    @objc private func removeSelected() {
        let indexes = table.selectedRowIndexes.sorted(by: >)
        for i in indexes { tokens.remove(at: i) }
        table.reloadData()
        removeButton?.isEnabled = false
    }

    @objc private func doneTapped() {
        Registry.setDeclines(Set(tokens))
        sheet.sheetParent?.endSheet(sheet)
    }
}
