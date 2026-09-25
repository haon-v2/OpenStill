import AppKit
import OpenStillCore

/// OpenStill → Settings… (⌘,). Holds update preferences; later milestones add more sections.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let updates: UpdateController
    private let version = NSTextField(labelWithString: "")
    private let method = NSTextField(wrappingLabelWithString: "")
    private let automatic = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let lastChecked = NSTextField(labelWithString: "")
    private let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
    private let releases = NSButton(title: "View All Releases", target: nil, action: nil)

    init(updates: UpdateController) {
        self.updates = updates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build(in: window)
        updates.changed = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(in window: NSWindow) {
        let title = NSTextField(labelWithString: "Updates"); title.font = .systemFont(ofSize: 15, weight: .semibold)
        version.font = .systemFont(ofSize: 12)
        method.font = .systemFont(ofSize: 11); method.textColor = .secondaryLabelColor
        automatic.target = self; automatic.action = #selector(toggleAutomatic)
        automatic.setAccessibilityHelp("Checks once a day and tells you when a newer OpenStill is available")
        lastChecked.font = .systemFont(ofSize: 11); lastChecked.textColor = .secondaryLabelColor
        for button in [checkNow, releases] { button.bezelStyle = .rounded; button.target = self }
        checkNow.action = #selector(check); releases.action = #selector(openReleases)
        checkNow.keyEquivalent = "\r"
        let buttons = NSStackView(views: [checkNow, releases]); buttons.spacing = 8
        let privacy = NSTextField(wrappingLabelWithString: "Only OpenStill's public release list on GitHub is requested. Nothing about you or your photos is sent.")
        privacy.font = .systemFont(ofSize: 11); privacy.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, version, method, automatic, lastChecked, buttons, privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.setCustomSpacing(16, after: method); stack.setCustomSpacing(16, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(stack); window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            method.widthAnchor.constraint(equalToConstant: 412), privacy.widthAnchor.constraint(equalToConstant: 412)
        ])
    }

    func refresh() {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String, build = info["CFBundleVersion"] as? String
        version.stringValue = short.map { "OpenStill \($0)" + (build.map { " (build \($0))" } ?? "") } ?? "OpenStill development build"
        method.stringValue = updates.usesSparkle
            ? "Updates download, are checked against OpenStill's signing key, and install from here. OpenStill relaunches when done."
            : "This build finds new releases on GitHub and opens the download page; you replace OpenStill in Applications yourself."
        automatic.state = updates.automaticChecks ? .on : .off
        if let date = updates.lastChecked {
            lastChecked.stringValue = "Last checked " + date.formatted(.relative(presentation: .named))
        } else { lastChecked.stringValue = "Not checked yet" }
        checkNow.isEnabled = !updates.isChecking
    }
    @objc private func toggleAutomatic() { updates.automaticChecks = automatic.state == .on; refresh() }
    @objc private func check() { updates.checkForUpdates(self); refresh() }
    @objc private func openReleases() { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}
