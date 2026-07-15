//
//  AppDelegate.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import ScriptingBridge

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    var musicPlayers: [SBApplication] = []
    var shouldWaitForPlayerQuit = false

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard groupDefaults.bool(forKey: launchAndQuitWithPlayer) else {
            NSApplication.shared.terminate(nil)
            return
        }
        
        let index = groupDefaults.integer(forKey: preferredPlayerIndex)
        guard playerBundleIdentifiers.indices.contains(index) else {
            NSLog("LyricsXHelper stopped: preferred player index \(index) is unavailable.")
            NSApplication.shared.terminate(nil)
            return
        }
        let ident = playerBundleIdentifiers[index]
        musicPlayers = ident.compactMap(SBApplication.init)
        
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLaunchedAsLoginItem = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let isLaunchedByMain = (groupDefaults.object(forKey: launchHelperTime) as? Date).map { Date().timeIntervalSince($0) < 10 } ?? false
        shouldWaitForPlayerQuit = !isLaunchedAsLoginItem && isLaunchedByMain && musicPlayers.contains { $0.isRunning }
        
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(checkTargetApplication), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(checkTargetApplication), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        
        checkTargetApplication()
    }
    
    @objc func checkTargetApplication() {
        let isRunning = musicPlayers.contains { $0.isRunning }
        if shouldWaitForPlayerQuit {
            shouldWaitForPlayerQuit = isRunning
            return
        } else if isRunning {
            self.launchMainAndQuit()
        }
    }

    func launchMainAndQuit() {
        var host = Bundle.main.bundleURL
        for _ in 0..<4 {
            host.deleteLastPathComponent()
        }
        NSWorkspace.shared.openApplication(at: host, configuration: .init()) { _, error in
            if let error {
                NSLog("launch LyricsX failed. reason: \(error)")
            } else {
                NSLog("launch LyricsX succeeded.")
            }
            NSApp.terminate(nil)
        }
    }

}

let playerBundleIdentifiers = [
    ["com.apple.Music", "com.apple.iTunes"],
    ["com.spotify.client"],
    ["com.coppertino.Vox"],
    ["com.audirvana.Audirvana-Studio", "com.audirvana.Audirvana", "com.audirvana.Audirvana-Plus"],
    ["com.swinsian.Swinsian"],
]

let groupDefaults = UserDefaults(suiteName: "QU3VK35N64.group.com.akirakusen.LyricsX")!

// Preference
let preferredPlayerIndex = "PreferredPlayerIndex"
let launchAndQuitWithPlayer = "LaunchAndQuitWithPlayer"
let launchHelperTime = "launchHelperTime"
