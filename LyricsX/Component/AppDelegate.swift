//
//  AppDelegate.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import GenericID
import MASShortcut
import MusicPlayer

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    
    static var shared: AppDelegate? {
        return NSApplication.shared.delegate as? AppDelegate
    }
    
    @IBOutlet weak var lyricsOffsetTextField: NSTextField!
    @IBOutlet weak var lyricsOffsetStepper: NSStepper!
    @IBOutlet weak var statusBarMenu: NSMenu!
    
    var karaokeLyricsWC: KaraokeLyricsWindowController?
    private var lastPresentedYouTubeMusicSetupIssue: YouTubeMusicSetupIssue?
    
    lazy var searchLyricsWC: NSWindowController = {
        // swiftlint:disable:next force_cast
        let searchVC = NSStoryboard.main!.instantiateController(withIdentifier: .init("SearchLyricsViewController")) as! SearchLyricsViewController
        let window = NSWindow(contentViewController: searchVC)
        window.title = NSLocalizedString("Search Lyrics", comment: "window title")
        return NSWindowController(window: window)
    }()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        registerUserDefaults()

        defaultNC.addObserver(
            self,
            selector: #selector(handleYouTubeMusicSetupRequired(_:)),
            name: .youTubeMusicSetupRequired,
            object: nil
        )
        defaultNC.addObserver(
            self,
            selector: #selector(handleYouTubeMusicSetupResolved(_:)),
            name: .youTubeMusicSetupResolved,
            object: nil
        )
        let youtubeMusicItem = NSMenuItem(
            title: NSLocalizedString("Set Up YouTube Music...", comment: "menu item"),
            action: #selector(showYouTubeMusicSetupAction(_:)),
            keyEquivalent: ""
        )
        youtubeMusicItem.target = self
        if let preferencesIndex = statusBarMenu.items.firstIndex(where: { $0.tag == 300 }) {
            statusBarMenu.insertItem(youtubeMusicItem, at: preferencesIndex)
        }

        let controller = AppController.shared
        
        karaokeLyricsWC = KaraokeLyricsWindowController()
        karaokeLyricsWC?.showWindow(nil)
        
        MenuBarLyricsController.shared.statusItem.menu = statusBarMenu
        statusBarMenu.delegate = self
        
        lyricsOffsetStepper.bind(.value,
                                 to: controller,
                                 withKeyPath: #keyPath(AppController.lyricsOffset),
                                 options: [.continuouslyUpdatesValue: true])
        lyricsOffsetTextField.bind(.value,
                                   to: controller,
                                   withKeyPath: #keyPath(AppController.lyricsOffset),
                                   options: [.continuouslyUpdatesValue: true])
        
        setupShortcuts()
        
        NSRunningApplication.runningApplications(withBundleIdentifier: lyricsXHelperIdentifier).forEach { $0.terminate() }
        
        let sharedKeys: [UserDefaults.DefaultsKeys] = [
            .launchAndQuitWithPlayer,
            .preferredPlayerIndex,
        ]
        sharedKeys.forEach {
            groupDefaults.bind(NSBindingName($0.key), withDefaultName: $0)
        }
        
        #if !IS_FOR_MAS
        if #available(OSX 10.12.2, *) {
            observeDefaults(key: .touchBarLyricsEnabled, options: [.new, .initial]) { _, change in
                if change.newValue, TouchBarLyricsController.shared == nil {
                    TouchBarLyricsController.shared = TouchBarLyricsController()
                } else if !change.newValue, TouchBarLyricsController.shared != nil {
                    TouchBarLyricsController.shared = nil
                }
            }
        }
        #endif
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        if AppController.shared.currentLyrics?.metadata.needsPersist == true {
            AppController.shared.currentLyrics?.persist()
        }
        if defaults[.launchAndQuitWithPlayer] {
            let url = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LoginItems/LyricsXHelper.app")
            groupDefaults[.launchHelperTime] = Date()
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                if let error {
                    log("launch LyricsX Helper failed. reason: \(error)")
                } else {
                    log("launch LyricsX Helper succeeded.")
                }
            }
        }
    }
    
    private func setupShortcuts() {
        let binder = MASShortcutBinder.shared()!
        binder.bindBoolShortcut(.shortcutToggleMenuBarLyrics, target: .menuBarLyricsEnabled)
        binder.bindBoolShortcut(.shortcutToggleKaraokeLyrics, target: .desktopLyricsEnabled)
        binder.bindShortcut(.shortcutShowLyricsWindow, to: #selector(showLyricsHUD))
        binder.bindShortcut(.shortcutOffsetIncrease, to: #selector(increaseOffset))
        binder.bindShortcut(.shortcutOffsetDecrease, to: #selector(decreaseOffset))
        binder.bindShortcut(.shortcutWriteToiTunes, to: #selector(writeToiTunes))
        binder.bindShortcut(.shortcutWrongLyrics, to: #selector(wrongLyrics))
        binder.bindShortcut(.shortcutSearchLyrics, to: #selector(searchLyrics))
    }
    
    // MARK: - NSMenuDelegate
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(writeToiTunes(_:))?:
            return selectedPlayer.name == .appleMusic && AppController.shared.currentLyrics != nil
        case #selector(searchLyrics(_:))?:
            return selectedPlayer.currentTrack != nil
        default:
            return true
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 202)?.isEnabled = AppController.shared.currentLyrics != nil
    }
    
    // MARK: - Menubar Action
    
    var lyricsHUD: NSWindowController?
    
    @IBAction func showLyricsHUD(_ sender: Any?) {
        // swiftlint:disable:next force_cast
        let controller = lyricsHUD ?? NSStoryboard.main?.instantiateController(withIdentifier: .init("LyricsHUD")) as! NSWindowController
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        lyricsHUD = controller
    }
    
    @IBAction func aboutLyricsXAction(_ sender: Any) {
        if #available(OSX 10.13, *) {
            #if IS_FOR_MAS
                let channel = "App Store"
            #else
                let channel = "GitHub"
            #endif
            let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "Unknown"
            let versionString = "\(channel) Version \(version)"
            NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: versionString])
        } else {
            NSApp.orderFrontStandardAboutPanel(sender)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func openReleasesAction(_ sender: Any) {
        #if IS_FOR_MAS
        return
        #else
        NSWorkspace.shared.open(lyricsXReleasesURL)
        #endif
    }

    @objc private func handleYouTubeMusicSetupRequired(_ notification: Notification) {
        guard let issue = notification.object as? YouTubeMusicSetupIssue,
              issue != lastPresentedYouTubeMusicSetupIssue else { return }
        lastPresentedYouTubeMusicSetupIssue = issue
        presentYouTubeMusicSetup(issue: issue)
    }

    @objc private func handleYouTubeMusicSetupResolved(_ notification: Notification) {
        lastPresentedYouTubeMusicSetupIssue = nil
    }

    @objc private func showYouTubeMusicSetupAction(_ sender: Any?) {
        presentYouTubeMusicSetup(issue: nil)
    }

    private func presentYouTubeMusicSetup(issue: YouTubeMusicSetupIssue?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let firstAction: () -> Void
        let secondAction: () -> Void
        switch issue {
        case .automationDenied:
            alert.messageText = NSLocalizedString(
                "Allow Chrome Automation",
                comment: "YouTube Music automation alert title"
            )
            alert.informativeText = NSLocalizedString(
                "LyricsX cannot control Google Chrome because Automation access was denied. Open System Settings > Privacy & Security > Automation and enable Google Chrome for LyricsX. Then return to Chrome and keep JavaScript from Apple Events enabled.",
                comment: "YouTube Music automation recovery instructions"
            )
            alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: "alert button"))
            alert.addButton(withTitle: NSLocalizedString("Open Chrome", comment: "alert button"))
            firstAction = openAutomationSettings
            secondAction = openChrome
        case .chromeJavaScriptDisabled:
            alert.messageText = NSLocalizedString(
                "Enable YouTube Music Control",
                comment: "YouTube Music Chrome alert title"
            )
            alert.informativeText = NSLocalizedString(
                "In Google Chrome, choose View > Developer > Allow JavaScript from Apple Events. LyricsX only runs its integration script in music.youtube.com tabs.",
                comment: "YouTube Music Chrome setup instructions"
            )
            alert.addButton(withTitle: NSLocalizedString("Open Chrome", comment: "alert button"))
            alert.addButton(withTitle: NSLocalizedString("Learn More", comment: "alert button"))
            firstAction = openChrome
            secondAction = openYouTubeMusicSetupHelp
        case nil:
            alert.messageText = NSLocalizedString(
                "Finish YouTube Music Setup",
                comment: "YouTube Music setup alert title"
            )
            alert.informativeText = NSLocalizedString(
                "In Google Chrome, choose View > Developer > Allow JavaScript from Apple Events. If LyricsX was previously denied access, enable Google Chrome for LyricsX in System Settings > Privacy & Security > Automation. LyricsX only runs scripts in music.youtube.com tabs.",
                comment: "YouTube Music setup instructions"
            )
            alert.addButton(withTitle: NSLocalizedString("Open Chrome", comment: "alert button"))
            alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: "alert button"))
            firstAction = openChrome
            secondAction = openAutomationSettings
        }
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "alert button"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            firstAction()
        case .alertSecondButtonReturn:
            secondAction()
        default:
            break
        }
    }

    private func openAutomationSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        )!
        NSWorkspace.shared.open(url)
    }

    private func openYouTubeMusicSetupHelp() {
        NSWorkspace.shared.open(URL(string: "https://support.google.com/chrome/?p=applescript")!)
    }

    private func openChrome() {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome"
        ) else {
            log("Google Chrome is not installed.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: chromeURL,
            configuration: configuration
        ) { _, error in
            if let error {
                log("Failed to open Google Chrome: \(error)")
            }
        }
    }
    
    @IBAction func increaseOffset(_ sender: Any?) {
        AppController.shared.lyricsOffset += 100
    }
    
    @IBAction func decreaseOffset(_ sender: Any?) {
        AppController.shared.lyricsOffset -= 100
    }
    
    @IBAction func showCurrentLyricsInFinder(_ sender: Any?) {
        guard let lyrics = AppController.shared.currentLyrics else {
            return
        }
        if lyrics.metadata.needsPersist {
            lyrics.persist()
        }
        if let url = lyrics.metadata.localURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    @IBAction func writeToiTunes(_ sender: Any?) {
        AppController.shared.writeToiTunes(overwrite: true)
    }
    
    @IBAction func searchLyrics(_ sender: Any?) {
        searchLyricsWC.window?.makeKeyAndOrderFront(nil)
        (searchLyricsWC.contentViewController as! SearchLyricsViewController?)?.reloadKeyword()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func wrongLyrics(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        defaults[.noSearchingTrackIds].append(track.id)
        if defaults[.writeToiTunesAutomatically] {
            track.setLyrics("")
        }
        if let url = AppController.shared.currentLyrics?.metadata.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        AppController.shared.currentLyrics = nil
        AppController.shared.searchCanceller?.cancel()
    }
    
    @IBAction func doNotSearchLyricsForThisAlbum(_ sender: Any?) {
        guard let track = selectedPlayer.currentTrack,
            let album = track.album else {
            return
        }
        defaults[.noSearchingAlbumNames].append(album)
        if defaults[.writeToiTunesAutomatically] {
            track.setLyrics("")
        }
        if let url = AppController.shared.currentLyrics?.metadata.localURL {
            try? FileManager.default.removeItem(at: url)
        }
        AppController.shared.currentLyrics = nil
    }
    
    func registerUserDefaults() {
        let currentLang = NSLocale.preferredLanguages.first!
        let isZh = currentLang.hasPrefix("zh") || currentLang.hasPrefix("yue")
        let isHant = isZh && (currentLang.contains("-Hant") || currentLang.contains("-HK"))
        
        let defaultsUrl = Bundle.main.url(forResource: "UserDefaults", withExtension: "plist")!
        if let dict = NSDictionary(contentsOf: defaultsUrl) as? [String: Any] {
            defaults.register(defaults: dict)
        }
        defaults.register(defaults: [
            .desktopLyricsColor: #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1),
            .desktopLyricsProgressColor: #colorLiteral(red: 0.1985405816, green: 1, blue: 0.8664234302, alpha: 1),
            .desktopLyricsShadowColor: #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1),
            .desktopLyricsBackgroundColor: #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.6041579279),
            .lyricsWindowTextColor: #colorLiteral(red: 0.7540688515, green: 0.7540867925, blue: 0.7540771365, alpha: 1),
            .lyricsWindowHighlightColor: #colorLiteral(red: 0.8866666667, green: 1, blue: 0.8, alpha: 1),
            .preferBilingualLyrics: isZh,
            .chineseConversionIndex: isHant ? 2 : 0,
            .desktopLyricsXPositionFactor: 0.5,
            .desktopLyricsYPositionFactor: 0.9,
        ])
    }
}

extension MASShortcutBinder {
    
    func bindShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, to action: @escaping () -> Void) {
        bindShortcut(withDefaultsKey: defaultsKay.key, toAction: action)
    }
    
    func bindBoolShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, target: UserDefaults.DefaultsKey<Bool>) {
        bindShortcut(withDefaultsKey: defaultsKay.key) {
            defaults[target] = !defaults[target]
        }
    }
    
    func bindShortcut<T>(_ defaultsKay: UserDefaults.DefaultsKey<T>, to action: Selector) {
        bindShortcut(defaultsKay) {
            let target = NSApplication.shared.target(forAction: action) as AnyObject?
            _ = target?.perform(action, with: self)
        }
    }
}
