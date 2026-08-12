import AppKit

/// The Settings window's content: a standard macOS preferences tab controller —
/// icon-and-label toolbar across the top, one pane per section, window resizing
/// to fit the selected pane.
///
/// `.toolbar` is what every native preferences window uses; AppKit provides the
/// toolbar, the selection, and the resize animation, so there's nothing here
/// but the pane list.
@MainActor
final class SettingsViewController: NSTabViewController {

    private var panes: [SettingsPane] = []

    init(tools: [Tool], appDelegate: AppDelegate?) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar

        for section in SettingsPane.Section.allCases {
            let pane = SettingsPane(section: section, tools: tools)
            pane.appDelegate = appDelegate
            panes.append(pane)

            let item = NSTabViewItem(viewController: pane)
            item.label = section.title
            item.image = NSImage(systemSymbolName: section.symbol,
                                 accessibilityDescription: section.title)
            addTabViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Refresh whatever is on screen. Panes not currently visible rebuild
    /// themselves in viewWillAppear, so there's no need to touch them here.
    func rebuild() {
        let index = selectedTabViewItemIndex
        guard index >= 0, index < panes.count else { return }
        panes[index].rebuild()
    }

    /// Resize the window to the selected pane, keeping the title bar still.
    /// NSTabViewController supplies the toolbar and the selection but not this;
    /// every native preferences window does it itself.
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow(to: item?.viewController as? SettingsPane, animated: true)
    }

    /// Size the window to a pane, keeping the title bar still.
    ///
    /// NSTabViewController supplies the toolbar and the selection but not this;
    /// every native preferences window does it itself. It's called on selection
    /// *and* when the window is first shown — `didSelect` never fires for the
    /// pane that's already selected, so without the second call the window kept
    /// whatever size it was created at until you clicked another tab, then
    /// jumped to the right size at the next opportunity. Mid-jump the pane
    /// hadn't drawn yet, which is what made it look momentarily empty.
    func fitWindow(to pane: SettingsPane?, animated: Bool) {
        guard let pane = pane ?? currentPane, let window = view.window else { return }

        // Chrome = titlebar + toolbar, measured rather than assumed: this
        // controller's own view *is* the pane area, so whatever the window has
        // beyond it is chrome. (`contentRect(forFrameRect:)` can't be used —
        // it doesn't account for the toolbar.)
        let chrome = window.frame.height - view.frame.height
        let target = chrome + pane.fittedHeight
        var frame = window.frame
        let delta = target - frame.height
        guard abs(delta) > 0.5 else { return }
        frame.size.height = target
        frame.origin.y -= delta      // grow downward, title bar stays put
        window.setFrame(frame, display: true, animate: animated)
    }

    /// The pane on screen right now.
    var currentPane: SettingsPane? {
        let i = selectedTabViewItemIndex
        return (i >= 0 && i < panes.count) ? panes[i] : nil
    }
}
