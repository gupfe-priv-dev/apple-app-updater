import AppKit

/// One line in the updates table. A reference type on purpose: the checkbox
/// cell and the table's data source both mutate the same instance, and a value
/// type would need write-back plumbing for no benefit.
@MainActor
final class UpdateRow {
    /// Index into the coordinator's tool list — the routing key for installs.
    let toolIndex: Int
    let toolID: String
    let managerLabel: String
    let item: UpdateItem
    /// False for tools that upgrade everything in one command. Those rows still
    /// have a checkbox, but toggling one toggles its whole manager group —
    /// pretending otherwise would promise targeting the tool can't deliver.
    let targetable: Bool

    var isSelected: Bool = true
    /// Warning shown in the Status column — a remembered failure, or the
    /// result of the run that just happened.
    var status: String = ""
    /// True only for a remembered failure. Tracked separately from `status`
    /// because plenty of rows carry a status that isn't a failure (an opaque
    /// manager's "unknown until run", a finished row's "✓ updated").
    var flaggedFailure = false
    /// Set once this row's update actually ran, so finished rows read as done
    /// rather than as still-pending work.
    var didSucceed = false

    init(toolIndex: Int, toolID: String, managerLabel: String,
         item: UpdateItem, targetable: Bool) {
        self.toolIndex = toolIndex
        self.toolID = toolID
        self.managerLabel = managerLabel
        self.item = item
        self.targetable = targetable

        // Pre-flag false friends: anything that failed its last attempt starts
        // unchecked with the reason visible, so a run doesn't silently repeat
        // a known-bad update.
        if let last = History.lastFailure(tool: toolID, token: item.token) {
            status = "⚠ " + History.flagText(for: last)
            flaggedFailure = true
            isSelected = false
        }
    }

    var name: String { item.name }
    var current: String { item.current ?? "—" }
    var available: String { item.latest ?? "—" }
    /// The CLI identity, shown when it differs from the display name (mas ids).
    var token: String { item.token }

    /// Colour for the Status column: orange for a warning, green once done.
    var statusColor: NSColor {
        if didSucceed { return .systemGreen }
        return status.isEmpty ? .secondaryLabelColor : .systemOrange
    }
}
