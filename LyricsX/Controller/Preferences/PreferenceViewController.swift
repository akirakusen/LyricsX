//
//  PreferenceViewController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa

class PreferenceViewController: NSTabViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        let symbols = ["gearshape", "textformat", "command", "line.3.horizontal.decrease.circle", "flask"]
        for (item, symbol) in zip(tabViewItems, symbols) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        }
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.toolbarStyle = .preference
        view.window?.titlebarAppearsTransparent = true
    }
}
