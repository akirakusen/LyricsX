//
//  MenuBarLyrics.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXExtensions
import CXShim
import GenericID
import LyricsCore
import MusicPlayer
import OpenCC
import SwiftCF
import AccessibilityExt

class MenuBarLyricsController {
    
    static let shared = MenuBarLyricsController()
    
    let statusItem: NSStatusItem
    let lyricsItem: NSStatusItem
    var buttonImage = #imageLiteral(resourceName: "status_bar_icon")
    var buttonlength: CGFloat = 30
    
    private var screenLyrics = "" {
        didSet {
            updateStatusItem()
        }
    }
    
    private var cancelBag = Set<AnyCancellable>()
    
    private init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lyricsItem = NSStatusBar.system.statusItem(withLength: 0)
        (lyricsItem.button?.cell as? NSButtonCell)?.highlightsBy = []
        lyricsItem.button?.title = ""
        AppController.shared.$currentLyrics
            .combineLatest(AppController.shared.$currentLineIndex)
            .receive(on: DispatchQueue.lyricsDisplay.cx)
            .map { Self.lyricsText(event: $0) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main.cx)
            .sink { [weak self] lyrics in
                self?.screenLyrics = lyrics
            }
            .store(in: &cancelBag)
        workspaceNC.cx
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .signal()
            .invoke(MenuBarLyricsController.updateStatusItem, weaklyOn: self)
            .store(in: &cancelBag)
        defaults.publisher(for: [.menuBarLyricsEnabled, .combinedMenubarLyrics])
            .prepend()
            .invoke(MenuBarLyricsController.updateStatusItem, weaklyOn: self)
            .store(in: &cancelBag)
    }
    
    private static func lyricsText(event: (lyrics: Lyrics?, index: Int?)) -> String {
        guard !defaults[.disableLyricsWhenPaused] || selectedPlayer.playbackState.isPlaying,
            let lyrics = event.lyrics,
            let index = event.index else {
            return ""
        }
        guard lyrics.lines.indices.contains(index) else {
            return ""
        }
        var newScreenLyrics = lyrics.lines[index].content
        if let converter = ChineseConverter.shared, lyrics.metadata.language?.hasPrefix("zh") == true {
            newScreenLyrics = converter.convert(newScreenLyrics)
        }
        return newScreenLyrics
    }
    
    @objc private func updateStatusItem() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItem()
            }
            return
        }

        guard defaults[.menuBarLyricsEnabled], !screenLyrics.isEmpty else {
            setImageStatusItem()
            hideLyricsItem()
            return
        }
        
        if defaults[.combinedMenubarLyrics] {
            updateCombinedStatusLyrics()
        } else {
            updateSeparateStatusLyrics()
        }
    }
    
    private func updateSeparateStatusLyrics() {
        setImageStatusItem()
        
        lyricsItem.button?.title = screenLyrics
        lyricsItem.length = NSStatusItem.variableLength
    }
    
    private func updateCombinedStatusLyrics() {
        hideLyricsItem()
        
        setTextStatusItem(string: screenLyrics)
        if statusItem.isVisibe {
            return
        }
        
        // truncation
        var components = screenLyrics.components(options: [.byWords])
        while !components.isEmpty, !statusItem.isVisibe {
            components.removeLast()
            let proposed = components.joined() + "..."
            setTextStatusItem(string: proposed)
        }
    }
    
    private func setTextStatusItem(string: String) {
        statusItem.button?.title = string
        statusItem.button?.image = nil
        statusItem.length = NSStatusItem.variableLength
    }
    
    private func setImageStatusItem() {
        statusItem.button?.title = ""
        statusItem.button?.image = buttonImage
        statusItem.length = buttonlength
    }

    private func hideLyricsItem() {
        lyricsItem.button?.title = ""
        lyricsItem.length = 0
    }
}

// MARK: - Status Item Visibility

private extension NSStatusItem {
    
    var isVisibe: Bool {
        guard let buttonFrame = button?.frame,
            let frame = button?.window?.convertToScreen(buttonFrame) else {
                return false
        }
        
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return false
        }
        let carbonPoint = CGPoint(x: point.x, y: screen.frame.height - point.y - 1)
        
        guard let element = try? AXUIElement.systemWide().element(at: carbonPoint),
            let pid = try? element.pid() else {
            return false
        }
        
        return getpid() == pid
    }
}

private extension String {
    
    func components(options: String.EnumerationOptions) -> [String] {
        var components: [String] = []
        let range = Range(uncheckedBounds: (startIndex, endIndex))
        enumerateSubstrings(in: range, options: options) { _, _, range, _ in
            components.append(String(self[range]))
        }
        return components
    }
}
