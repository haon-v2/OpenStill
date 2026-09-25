import AppKit
import OpenStillCore

/// "Check for Updates…" and the once-a-day automatic check against OpenStill's GitHub releases.
final class UpdateController: NSObject, NSMenuItemValidation {
    private static let automaticKey = "CheckForUpdatesAutomatically"
    private static let lastCheckKey = "LastUpdateCheck"
    private static let skippedKey = "SkippedUpdateVersion"
    private var checking = false
    private let defaults = UserDefaults.standard

    private var automatic: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }
    /// Nil when running outside the app bundle (swift run), where there is no version to compare.
    private var installedVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    func checkAtLaunch() {
        guard automatic, installedVersion != nil else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24*60*60 { return }
        check(userInitiated: false)
    }
    @objc func checkForUpdates(_ sender: Any?) { check(userInitiated: true) }
    @objc func toggleAutomaticChecks(_ sender: NSMenuItem) { automatic.toggle(); sender.state = automatic ? .on : .off }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomaticChecks(_:)) { item.state = automatic ? .on : .off }
        if item.action == #selector(checkForUpdates(_:)) { return !checking }
        return true
    }

    private func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        UpdateCheck.fetchReleases { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.defaults.set(Date(), forKey: Self.lastCheckKey)
                self.finish(result, userInitiated: userInitiated)
            }
        }
    }
    private func finish(_ result: Result<[AppRelease], Error>, userInitiated: Bool) {
        let installed = installedVersion ?? "0"
        switch result {
        case .failure(let error):
            guard userInitiated else { return }
            show("Couldn’t check for updates", error.localizedDescription, buttons: ["OK"])
        case .success(let releases):
            guard let release = UpdateCheck.newest(in: releases, newerThan: installed) else {
                if userInitiated { show("OpenStill is up to date", "Version \(installed) is the newest release on GitHub.", buttons: ["OK"]) }
                return
            }
            if !userInitiated, defaults.string(forKey: Self.skippedKey) == release.versionString { return }
            let kind = release.prerelease ? " is a pre-release on GitHub." : " is on GitHub."
            let answer = show("OpenStill \(release.versionString) is available",
                              "\(release.title)\(kind) You have version \(installed). Download it from the release page, then replace OpenStill in Applications. Your edits and library stay as they are.",
                              buttons: ["View Release", "Skip This Version", "Later"])
            if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
            else if answer == .alertSecondButtonReturn { defaults.set(release.versionString, forKey: Self.skippedKey) }
        }
    }
    @discardableResult private func show(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}
