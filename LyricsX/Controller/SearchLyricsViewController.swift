//
//  SearchLyricsViewController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXExtensions
import CXShim
import LyricsService
import MusicPlayer

class SearchLyricsViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
    
    var imageCache = NSCache<NSURL, NSImage>()
    
    @objc dynamic var searchArtist = ""
    @objc dynamic var searchTitle = "" {
        didSet {
            searchButton?.isEnabled = !searchTitle.isEmpty
        }
    }
    
    let lyricsManager = LyricsProviders.Group()
    var searchRequest: LyricsSearchRequest?
    var searchCanceller: Cancellable?
    var searchResult: [Lyrics] = []
    var progressObservation: NSKeyValueObservation?
    private var searchGeneration: UInt = 0
    private var searchResultKeys = Set<String>()
    
    @IBOutlet weak var artworkView: NSImageView!
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var searchButton: NSButton!
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    // NSTextView doesn't support weak references
    @IBOutlet var lyricsPreviewTextView: NSTextView!
    
    @IBOutlet weak var hideLrcPreviewConstraint: NSLayoutConstraint?
    @IBOutlet var normalConstraint: NSLayoutConstraint!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        normalConstraint.isActive = false
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        reloadKeyword()
    }
    
    func reloadKeyword() {
        guard let track = selectedPlayer.currentTrack else {
            clearSearchState()
            return
        }
        let artist = track.artist ?? ""
        let title = track.title ?? ""
        if (searchArtist, searchTitle) != (artist, title) {
            (searchArtist, searchTitle) = (artist, title)
            searchAction(nil)
        }
    }
    
    @IBAction func searchAction(_ sender: Any?) {
        searchGeneration &+= 1
        let generation = searchGeneration
        searchCanceller?.cancel()
        searchCanceller = nil
        progressObservation?.invalidate()
        progressObservation = nil
        searchResult = []
        searchResultKeys.removeAll(keepingCapacity: true)
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
        lyricsPreviewTextView.string = " "
        
        let track = selectedPlayer.currentTrack
        let duration = track?.duration.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let normalizedTitle = searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            searchRequest = nil
            progressIndicator.stopAnimation(nil)
            tableView.reloadData()
            return
        }
        let normalizedArtist = searchArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchTerm: LyricsSearchRequest.SearchTerm = normalizedArtist.isEmpty
            ? .keyword(normalizedTitle)
            : .info(title: normalizedTitle, artist: normalizedArtist)
        let req = LyricsSearchRequest(
            searchTerm: searchTerm,
            duration: duration,
            limit: 8
        )
        searchRequest = req
        searchCanceller = lyricsManager.lyricsPublisher(request: req)
            .timeout(.seconds(10), scheduler: DispatchQueue.lyricsDisplay.cx)
            .receive(on: DispatchQueue.main.cx)
            .sink(receiveCompletion: { [weak self] _ in
                guard let self = self,
                    self.searchGeneration == generation,
                    self.searchRequest == req else {
                    return
                }
                self.progressIndicator.stopAnimation(nil)
            }, receiveValue: { [weak self] lyrics in
                self?.lyricsReceived(lyrics: lyrics, request: req, generation: generation)
            })
        progressIndicator.startAnimation(nil)
        tableView.reloadData()
    }
    
    @IBAction func useLyricsAction(_ sender: Any) {
        guard let index = tableView.selectedRowIndexes.first,
            searchResult.indices.contains(index) else {
            return
        }
        
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
        
        let lrc = searchResult[index]
        AppController.shared.useLyrics(lrc, for: track, writeToPlayer: true)
    }
    
    // MARK: - LyricsSourceDelegate
    
    private func lyricsReceived(lyrics: Lyrics, request: LyricsSearchRequest, generation: UInt) {
        guard searchGeneration == generation,
            searchRequest == request,
            lyrics.metadata.request == request else {
            return
        }
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        guard searchResultKeys.insert(searchResultKey(for: lyrics)).inserted else {
            return
        }
        let selectedRow = tableView.selectedRow
        let selectedLyrics = searchResult.indices.contains(selectedRow)
            ? searchResult[selectedRow]
            : nil
        if let idx = searchResult.firstIndex(where: { lyrics.quality > $0.quality }) {
            searchResult.insert(lyrics, at: idx)
        } else {
            searchResult.append(lyrics)
        }
        tableView.reloadData()
        if let selectedLyrics = selectedLyrics,
            let selectedRow = searchResult.firstIndex(where: { $0 === selectedLyrics }) {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
    }
    
    // MARK: - TableViewDelegate
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return searchResult.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard searchResult.indices.contains(row),
            let ident = tableColumn?.identifier else {
            return nil
        }
        
        switch ident {
        case .searchResultColumnTitle:
            return searchResult[row].idTags[.title] ?? "[lacking]"
        case .searchResultColumnArtist:
            return searchResult[row].idTags[.artist] ?? "[lacking]"
        case .searchResultColumnSource:
            return searchResult[row].metadata.service?.rawValue ?? "[lacking]"
        default:
            return nil
        }
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        guard searchResult.indices.contains(index) else {
            lyricsPreviewTextView.string = " "
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            return
        }
        if self.hideLrcPreviewConstraint?.isActive == true {
            self.expandPreview()
        }
        self.lyricsPreviewTextView.string = self.searchResult[index].description
        self.updateImage()
    }
    
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        guard let index = rowIndexes.first,
            searchResult.indices.contains(index) else {
            return false
        }
        let lrcContent = searchResult[index].description
        pboard.declareTypes([.string, .filePromise], owner: self)
        pboard.setString(lrcContent, forType: .string)
        pboard.setPropertyList(["lrc"], forType: .filePromise)
        return true
    }
    
    func tableView(_ tableView: NSTableView, namesOfPromisedFilesDroppedAtDestination dropDestination: URL, forDraggedRowsWith indexSet: IndexSet) -> [String] {
        return indexSet.compactMap { index -> String? in
            guard searchResult.indices.contains(index) else {
                return nil
            }
            let fileName = searchResult[index].fileName ?? "Unknown"
            
            let destURL = dropDestination.appendingPathComponent(fileName)
            let lrcStr = searchResult[index].description
            
            do {
                try lrcStr.write(to: destURL, atomically: true, encoding: .utf8)
            } catch {
                log(error.localizedDescription)
                return nil
            }
            
            return fileName
        }
    }
    
    // MARK: - NSTextFieldDelegate
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchAction(nil)
            return true
        }
        return false
    }
    
    private func expandPreview() {
        guard let window = view.window else {
            return
        }
        let expandingHeight = -view.subviews.reduce(0) { min($0, $1.frame.minY) }
        let windowFrame = window.frame.with {
            $0.size.height += expandingHeight
            $0.origin.y -= expandingHeight
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.33
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            hideLrcPreviewConstraint?.animator().isActive = false
            window.setFrame(windowFrame, display: false, animate: true)
            view.needsUpdateConstraints = true
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.normalConstraint.isActive = true
        })
    }
    
    private func updateImage() {
        let index = tableView.selectedRow
        guard searchResult.indices.contains(index) else {
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            return
        }
        guard let url = searchResult[index].metadata.artworkURL else {
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            return
        }
        
        if let cacheImage = imageCache.object(forKey: url as NSURL) {
            artworkView.image = cacheImage
            return
        }
        
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
        let generation = searchGeneration
        DispatchQueue.global().async { [weak self] in
            guard let image = NSImage(contentsOf: url) else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                    self.searchGeneration == generation else {
                    return
                }
                self.imageCache.setObject(image, forKey: url as NSURL)
                let selectedRow = self.tableView.selectedRow
                guard self.searchResult.indices.contains(selectedRow),
                    self.searchResult[selectedRow].metadata.artworkURL == url else {
                    return
                }
                self.artworkView.image = image
            }
        }
    }

    private func clearSearchState() {
        searchGeneration &+= 1
        searchCanceller?.cancel()
        searchCanceller = nil
        progressObservation?.invalidate()
        progressObservation = nil
        searchRequest = nil
        searchResult = []
        searchResultKeys.removeAll(keepingCapacity: true)
        searchArtist = ""
        searchTitle = ""
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
        lyricsPreviewTextView.string = " "
        progressIndicator.stopAnimation(nil)
        tableView.reloadData()
    }

    private func searchResultKey(for lyrics: Lyrics) -> String {
        if let serviceToken = lyrics.metadata.serviceToken, !serviceToken.isEmpty {
            return "\(lyrics.metadata.service?.rawValue ?? ""):\(serviceToken)"
        }
        return lyrics.description
    }

}
