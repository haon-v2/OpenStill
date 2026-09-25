import AppKit
import OpenStillCore
import Sparkle

/// "Check for Updates…" and the automatic daily check. With a Sparkle feed and public key in Info.plist, Sparkle downloads,
/// verifies and installs the update in-app; otherwise the app compares against OpenStill's GitHub releases and links to them.
final class UpdateController: NSObject, NSMenuItemValidation {
    private static let automaticKey = "CheckForUpdatesAutomatically"
    private static let migratedKey = "UpdateSettingsMovedToSparkle"
    private static let lastCheckKey = "LastUpdateCheck"
    private static let skippedKey = "SkippedUpdateVersion"
    private var checking = false
    private let defaults = UserDefaults.standard
    /// Nil outside the app bundle (swift run) and in builds without a Sparkle key.
    private let sparkle: SPUStandardUpdaterController?

    override init() {
        if Bundle.main.bundleURL.pathExtension == "app", UpdateCheck.sparkleConfigured(info: Bundle.main.infoDictionary) {
            sparkle = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            sparkle = nil
        }
        super.init()
        // Carry over "Check for Updates Automatically" from the GitHub check the first time Sparkle runs.
        if let updater = sparkle?.updater, !defaults.bool(forKey: Self.migratedKey) {
            if defaults.object(forKey: Self.automaticKey) as? Bool == false { updater.automaticallyChecksForUpdates = false }
            defaults.set(true, forKey: Self.migratedKey)
        }
    }

    /// Called after a GitHub check finishes, so an open Settings window can refresh.
    var changed: (() -> Void)?
    var usesSparkle: Bool { sparkle != nil }
    var automaticChecks: Bool { get { automatic } set { automatic = newValue } }
    var lastChecked: Date? { sparkle?.updater.lastUpdateCheckDate ?? defaults.object(forKey: Self.lastCheckKey) as? Date }
    var isChecking: Bool { sparkle.map { !$0.updater.canCheckForUpdates } ?? checking }

    private var automatic: Bool {
        get { sparkle?.updater.automaticallyChecksForUpdates ?? defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set {
            if let updater = sparkle?.updater { updater.automaticallyChecksForUpdates = newValue }
            else { defaults.set(newValue, forKey: Self.automaticKey) }
        }
    }
    /// Nil when running outside the app bundle (swift run), where there is no version to compare.
    private var installedVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// Sparkle schedules its own checks; the GitHub check runs at most once a day at launch.
    func checkAtLaunch() {
        guard sparkle == nil, automatic, installedVersion != nil else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24*60*60 { return }
        check(userInitiated: false)
    }
    @objc func checkForUpdates(_ sender: Any?) {
        if let sparkle { sparkle.checkForUpdates(sender) } else { check(userInitiated: true) }
    }
    @objc func toggleAutomaticChecks(_ sender: NSMenuItem) { automatic.toggle(); sender.state = automatic ? .on : .off }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomaticChecks(_:)) { item.state = automatic ? .on : .off }
        if item.action == #selector(checkForUpdates(_:)) { return sparkle?.updater.canCheckForUpdates ?? !checking }
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
                self.changed?()
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
