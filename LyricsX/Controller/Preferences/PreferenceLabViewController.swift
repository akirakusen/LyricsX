//
//  PreferenceLabViewController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import MusicPlayer

class PreferenceLabViewController: NSViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        if let systemMediaButton = view.viewWithTag(6005) as? NSButton {
            systemMediaButton.title = NSLocalizedString(
                "Legacy system Now Playing fallback",
                comment: "system Now Playing preference"
            )
            systemMediaButton.toolTip = NSLocalizedString(
                "Uses the older macOS media-session bridge for players without direct integration.",
                comment: "system Now Playing preference tooltip"
            )
            if #available(macOS 15.4, *) {
                defaults[.useSystemWideNowPlaying] = false
                systemMediaButton.state = .off
                systemMediaButton.isEnabled = false
            } else {
                systemMediaButton.isEnabled = MusicPlayers.SystemMedia.available
            }
        }
    }
}
