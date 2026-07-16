//
//  AppController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import AppKit
import CXShim
import CXExtensions
import LyricsService
import MusicPlayer
import OpenCC
import Regex

class AppController: NSObject {
    
    static let shared = AppController()
    private static let lyricsQueueKey = DispatchSpecificKey<UInt8>()
    private static let lyricsQueueValue: UInt8 = 1
    
    let lyricsManager = LyricsProviders.Group()
    
    @Published var currentLyrics: Lyrics? {
        willSet {
            currentLineIndex = nil
        }
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.willChangeValue(forKey: "lyricsOffset")
                self?.didChangeValue(forKey: "lyricsOffset")
            }
            scheduleCurrentLineCheck()
        }
    }
    
    @Published var currentLineIndex: Int?
    
    private var searchCanceller: Cancellable?
    private var searchGeneration: UInt64 = 0
    private var activeSearchTrackID: String?
    private var activeSearchRequests: [LyricsSearchRequest] = []
    private var activeSearchSeeds: [LyricsSearchSeed] = []
    private var activeSearchStageReceivedLyrics = false
    private var currentLyricsTrack: MusicTrack?
    private var currentLyricsIsConfident = false
    
    private var cancelBag = Set<AnyCancellable>()
    private var currentLineCheckWorkItem: DispatchWorkItem?
    
    @objc dynamic var lyricsOffset: Int {
        get {
            if DispatchQueue.getSpecific(key: Self.lyricsQueueKey) == Self.lyricsQueueValue {
                return currentLyrics?.offset ?? 0
            }
            return DispatchQueue.lyricsDisplay.sync {
                currentLyrics?.offset ?? 0
            }
        }
        set {
            performOnLyricsQueue { [weak self] in
                self?.currentLyrics?.offset = newValue
                self?.currentLyrics?.metadata.needsPersist = true
                self?.rescheduleCurrentLineCheck()
            }
        }
    }
    
    private override init() {
        super.init()
        DispatchQueue.lyricsDisplay.setSpecific(
            key: Self.lyricsQueueKey,
            value: Self.lyricsQueueValue
        )
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay.cx)
            .invoke(AppController.currentTrackChanged, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay.cx)
            .invoke(AppController.scheduleCurrentLineCheck, weaklyOn: self)
            .store(in: &cancelBag)

        defaults.publisher(for: [.lyricsFilterEnabled, .lyricsFilterKeys])
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay.cx)
            .invoke(AppController.refilterCurrentLyrics, weaklyOn: self)
            .store(in: &cancelBag)
        
        workspaceNC.cx.publisher(for: NSWorkspace.didTerminateApplicationNotification, object: nil)
            .sink { n in
                let bundleID = (n.userInfo![NSWorkspace.applicationUserInfoKey] as! NSRunningApplication).bundleIdentifier
                if defaults[.launchAndQuitWithPlayer], (selectedPlayer.designatedPlayer as? MusicPlayers.Scriptable)?.playerBundleID == bundleID {
                    NSApplication.shared.terminate(nil)
                }
            }.store(in: &cancelBag)
        workspaceNC.cx.publisher(for: NSWorkspace.didWakeNotification, object: nil)
            .sink { [weak self] _ in
                selectedPlayer.updatePlayerState()
                self?.scheduleCurrentLineCheck()
            }
            .store(in: &cancelBag)
        performOnLyricsQueue { [weak self] in
            self?.currentTrackChanged()
        }
    }
    
    func scheduleCurrentLineCheck() {
        performOnLyricsQueue { [weak self] in
            self?.rescheduleCurrentLineCheck()
        }
    }

    private func rescheduleCurrentLineCheck() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.lyricsDisplay))
        currentLineCheckWorkItem?.cancel()
        currentLineCheckWorkItem = nil
        guard let lyrics = currentLyrics else {
            return
        }
        let playbackState = MusicPlayers.Selected.shared.playbackState
        let playbackTime = playbackState.time
        guard playbackTime.isFinite else {
            currentLineIndex = nil
            return
        }
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        let validIndex = index.flatMap { lyrics.lines.indices.contains($0) ? $0 : nil }
        if currentLineIndex != validIndex {
            currentLineIndex = validIndex
        }
        let nextLineTime = next.flatMap {
            lyrics.lines.indices.contains($0)
                ? lyrics.lines[$0].position - lyrics.adjustedTimeDelay
                : nil
        }
        guard let delay = LyricsTimelineRefreshPolicy.nextDelay(
            isPlaying: playbackState.isPlaying,
            playbackTime: playbackTime,
            nextLineTime: nextLineTime
        ) else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.rescheduleCurrentLineCheck()
        }
        currentLineCheckWorkItem = workItem
        DispatchQueue.lyricsDisplay.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }
    
    func writeToiTunes(overwrite: Bool) {
        guard DispatchQueue.getSpecific(key: Self.lyricsQueueKey) == Self.lyricsQueueValue else {
            let expectedTrackID = selectedPlayer.currentTrack?.id
            performOnLyricsQueue { [weak self] in
                self?.writeToiTunes(
                    overwrite: overwrite,
                    expectedTrackID: expectedTrackID
                )
            }
            return
        }
        writeToiTunes(overwrite: overwrite, expectedTrackID: nil)
    }

    private func writeToiTunes(overwrite: Bool, expectedTrackID: String?) {
        guard selectedPlayer.name == .appleMusic,
            let currentLyrics = currentLyrics,
            let track = currentLyricsTrack,
            expectedTrackID == nil || track.id == expectedTrackID,
            selectedPlayer.currentTrack?.id == track.id,
            let sbTrack = track.originalTrack,
            overwrite || (sbTrack.value(forKey: "lyrics") as! String?)?.isEmpty != false else {
            return
        }
        let content = currentLyrics.lines.map { line -> String in
            var content = line.content
            if let converter = ChineseConverter.shared {
                content = converter.convert(content)
            }
            if defaults[.writeiTunesWithTranslation] {
                // TODO: tagged translation
                let code = currentLyrics.metadata.translationLanguages.first
                if var translation = line.attachments[.translation(languageCode: code)] {
                    if let converter = ChineseConverter.shared {
                        translation = converter.convert(translation)
                    }
                    content += "\n" + translation
                }
            }
            return content
        }.joined(separator: "\n")
        // swiftlint:disable:next force_try
        let regex = Regex(#"\n{3,}"#)
        let replaced = content.replacingMatches(of: regex, with: "\n\n")
        sbTrack.setValue(replaced, forKey: "lyrics")
    }
    
    func currentTrackChanged() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.lyricsDisplay))
        invalidateSearch()
        if currentLyrics?.metadata.needsPersist == true {
            currentLyrics?.persist()
        }
        currentLyrics = nil
        currentLyricsTrack = nil
        currentLyricsIsConfident = false
        currentLineIndex = nil
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            return
        }
        let youTubeMusicSearchSeeds = (track.originalTrack as? YouTubeMusicSearchContext)?
            .searchSeeds
        var searchSeeds = youTubeMusicSearchSeeds ?? []
        searchSeeds.append(LyricsSearchSeed(title: title, artist: artist))
        
        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }
        
        // (fileURL, isSecurityScoped, needsSearching, validatesCachedMetadata)
        var candidateLyricsURL: [(URL, Bool, Bool, Bool)] = []
        
        if defaults[.loadLyricsBesideTrack] {
            if let fileName = track.fileURL?.deletingPathExtension() {
                candidateLyricsURL += [
                    (fileName.appendingPathExtension("lrcx"), false, false, false),
                    (fileName.appendingPathExtension("lrc"), false, false, false)
                ]
            }
        }
        let (url, security) = defaults.lyricsSavingPath()
        let titleForReading = title.replacingOccurrences(of: "/", with: ":")
        let artistForReading = artist.replacingOccurrences(of: "/", with: ":")
        let fileName = url.appendingPathComponent("\(titleForReading) - \(artistForReading)")
        candidateLyricsURL += [
            (fileName.appendingPathExtension("lrcx"), security, false, true),
            (fileName.appendingPathExtension("lrc"), security, true, true)
        ]
        
        for (url, security, needsSearching, validatesCachedMetadata) in candidateLyricsURL {
            if security {
                guard url.startAccessingSecurityScopedResource() else {
                    continue
                }
            }
            defer {
                if security {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            if let lrcContents = try? String(contentsOf: url, encoding: String.Encoding.utf8),
                let lyrics = Lyrics(lrcContents),
                !validatesCachedMetadata
                    || youTubeMusicSearchSeeds == nil
                    || LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                        cachedTitle: lyrics.idTags[.title],
                        cachedArtist: lyrics.idTags[.artist],
                        cachedDuration: lyrics.length,
                        trackDuration: track.duration,
                        searchSeeds: searchSeeds
                    ) {
                lyrics.metadata.localURL = url
                lyrics.metadata.title = title
                lyrics.metadata.artist = artist
                lyrics.filtrate()
                lyrics.recognizeLanguage()
                currentLyricsTrack = track
                currentLyricsIsConfident = true
                currentLyrics = lyrics
                if needsSearching {
                    break
                } else {
                    return
                }
            }
        }
        
        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }
        
        let candidates = LyricsSearchCandidatePlanner.candidates(
            from: searchSeeds,
            maximumCount: 8
        )
        let paired = Array(candidates.filter { $0.tier == .paired }.prefix(4))
        let titleOnly = Array(candidates.filter { $0.tier == .titleOnly }.prefix(2))
        let duration = track.duration.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let generation = searchGeneration
        activeSearchTrackID = track.id
        activeSearchSeeds = searchSeeds

        if paired.isEmpty {
            startAutomaticSearch(
                candidates: titleOnly,
                fallbackCandidates: [],
                duration: duration,
                trackID: track.id,
                generation: generation
            )
        } else {
            startAutomaticSearch(
                candidates: paired,
                fallbackCandidates: titleOnly,
                duration: duration,
                trackID: track.id,
                generation: generation
            )
        }
    }
    
    // MARK: LyricsSourceDelegate
    
    @discardableResult
    private func lyricsReceived(
        lyrics: Lyrics,
        generation: UInt64,
        trackID: String
    ) -> LyricsSearchResultMatch? {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.lyricsDisplay))
        guard generation == searchGeneration,
              activeSearchTrackID == trackID,
              selectedPlayer.currentTrack?.id == trackID,
              let request = lyrics.metadata.request,
              activeSearchRequests.contains(request),
              let track = selectedPlayer.currentTrack else {
            return nil
        }
        let match: LyricsSearchResultMatch
        if track.originalTrack is YouTubeMusicSearchContext {
            match = LyricsSearchResultMatchPolicy.evaluate(
                resultTitle: lyrics.idTags[.title],
                resultArtist: lyrics.idTags[.artist],
                resultDuration: lyrics.length,
                trackDuration: track.duration,
                searchSeeds: activeSearchSeeds
            )
        } else {
            match = LyricsSearchResultMatch(
                isPlausible: true,
                isConfident: lyricsMatchesRequest(lyrics, request: request)
            )
        }
        guard match.isPlausible else {
            return nil
        }
        let incomingIsConfident = match.isConfident
        if defaults[.strictSearchEnabled] && !incomingIsConfident {
            return nil
        }
        let incomingQuality = lyrics.quality
        let currentQuality = currentLyrics.map(\.quality)
        guard LyricsSearchResultSelectionPolicy.shouldReplace(
            currentQuality: currentQuality,
            currentIsConfident: currentLyricsIsConfident,
            incomingQuality: incomingQuality,
            incomingIsConfident: incomingIsConfident
        ) else {
            return nil
        }
        lyrics.associateWithTrack(track)
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyricsTrack = track
        currentLyricsIsConfident = incomingIsConfident
        currentLyrics = lyrics
        return LyricsSearchResultMatch(
            isPlausible: true,
            isConfident: incomingIsConfident
        )
    }

    private func lyricsMatchesRequest(
        _ lyrics: Lyrics,
        request: LyricsSearchRequest
    ) -> Bool {
        switch request.searchTerm {
        case .info:
            return lyrics.isMatched()
        case let .keyword(title):
            guard let resultTitle = lyrics.idTags[.title] else { return false }
            return LyricsSearchCandidatePlanner.titlesLikelyMatch(resultTitle, title)
        }
    }

    private func startAutomaticSearch(
        candidates: [LyricsSearchCandidate],
        fallbackCandidates: [LyricsSearchCandidate],
        duration: TimeInterval,
        trackID: String,
        generation: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.lyricsDisplay))
        guard generation == searchGeneration,
              selectedPlayer.currentTrack?.id == trackID else {
            return
        }
        guard !candidates.isEmpty else {
            finishAutomaticSearch(generation: generation, trackID: trackID)
            return
        }

        let generationValue = String(generation)
        let requests = candidates.map { candidate in
            let searchTerm: LyricsSearchRequest.SearchTerm
            if let artist = candidate.artist, !artist.isEmpty {
                searchTerm = .info(title: candidate.title, artist: artist)
            } else {
                searchTerm = .keyword(candidate.title)
            }
            return LyricsSearchRequest(
                searchTerm: searchTerm,
                duration: duration,
                limit: 5,
                userInfo: ["lyricsXSearchGeneration": generationValue]
            )
        }
        activeSearchRequests = requests
        activeSearchStageReceivedLyrics = false

        searchCanceller = Publishers.MergeMany(
            requests.map { lyricsManager.lyricsPublisher(request: $0) }
        )
        .receive(on: DispatchQueue.lyricsDisplay.cx)
        .timeout(.seconds(10), scheduler: DispatchQueue.lyricsDisplay.cx)
        .sink(
            receiveCompletion: { [weak self] _ in
                guard let self,
                      generation == self.searchGeneration,
                      self.activeSearchTrackID == trackID,
                      selectedPlayer.currentTrack?.id == trackID else {
                    return
                }
                self.searchCanceller = nil
                if !self.activeSearchStageReceivedLyrics, !fallbackCandidates.isEmpty {
                    self.startAutomaticSearch(
                        candidates: fallbackCandidates,
                        fallbackCandidates: [],
                        duration: duration,
                        trackID: trackID,
                        generation: generation
                    )
                } else {
                    self.finishAutomaticSearch(
                        generation: generation,
                        trackID: trackID
                    )
                }
            },
            receiveValue: { [weak self] lyrics in
                guard let self else { return }
                if let match = self.lyricsReceived(
                    lyrics: lyrics,
                    generation: generation,
                    trackID: trackID
                ), match.isConfident {
                    self.activeSearchStageReceivedLyrics = true
                }
            }
        )
    }

    private func finishAutomaticSearch(generation: UInt64, trackID: String) {
        guard generation == searchGeneration,
              activeSearchTrackID == trackID,
              selectedPlayer.currentTrack?.id == trackID else {
            return
        }
        searchCanceller = nil
        activeSearchRequests = []
        activeSearchSeeds = []
        activeSearchStageReceivedLyrics = false
        activeSearchTrackID = nil
        if defaults[.writeToiTunesAutomatically], currentLyrics != nil {
            writeToiTunes(overwrite: true)
        }
    }

    private func invalidateSearch() {
        searchGeneration &+= 1
        activeSearchTrackID = nil
        activeSearchRequests = []
        activeSearchSeeds = []
        activeSearchStageReceivedLyrics = false
        let canceller = searchCanceller
        searchCanceller = nil
        canceller?.cancel()
    }

    private func refilterCurrentLyrics() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.lyricsDisplay))
        guard let lyrics = currentLyrics else { return }
        lyrics.filtrate()
        currentLyrics = lyrics
    }

    private func performOnLyricsQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.lyricsQueueKey) == Self.lyricsQueueValue {
            work()
        } else {
            DispatchQueue.lyricsDisplay.async(execute: work)
        }
    }

    func persistCurrentLyricsBeforeTermination() {
        let persist = { [self] in
            if currentLyrics?.metadata.needsPersist == true {
                currentLyrics?.persist()
            }
        }
        if DispatchQueue.getSpecific(key: Self.lyricsQueueKey) == Self.lyricsQueueValue {
            persist()
        } else {
            DispatchQueue.lyricsDisplay.sync(execute: persist)
        }
    }

    func persistedCurrentLyricsURL() -> URL? {
        let persistAndRead = { [self] () -> URL? in
            if currentLyrics?.metadata.needsPersist == true {
                currentLyrics?.persist()
            }
            return currentLyrics?.metadata.localURL
        }
        if DispatchQueue.getSpecific(key: Self.lyricsQueueKey) == Self.lyricsQueueValue {
            return persistAndRead()
        }
        return DispatchQueue.lyricsDisplay.sync(execute: persistAndRead)
    }

    func useLyrics(
        _ lyrics: Lyrics,
        for track: MusicTrack,
        writeToPlayer: Bool
    ) {
        performOnLyricsQueue { [weak self] in
            guard let self, selectedPlayer.currentTrack?.id == track.id else {
                return
            }
            self.invalidateSearch()
            lyrics.associateWithTrack(track)
            lyrics.filtrate()
            lyrics.recognizeLanguage()
            lyrics.metadata.needsPersist = true
            self.currentLyricsTrack = track
            self.currentLyricsIsConfident = true
            self.currentLyrics = lyrics
            if writeToPlayer, defaults[.writeToiTunesAutomatically] {
                self.writeToiTunes(overwrite: true)
            }
        }
    }

    func markCurrentLyricsWrong() {
        guard let targetTrack = selectedPlayer.currentTrack else { return }
        performOnLyricsQueue { [weak self] in
            guard let self,
                  selectedPlayer.currentTrack?.id == targetTrack.id else {
                return
            }
            if !defaults[.noSearchingTrackIds].contains(targetTrack.id) {
                defaults[.noSearchingTrackIds].append(targetTrack.id)
            }
            if defaults[.writeToiTunesAutomatically] {
                targetTrack.setLyrics("")
            }
            self.invalidateSearch()
            if self.currentLyricsTrack?.id == targetTrack.id {
                if let url = self.currentLyrics?.metadata.localURL {
                    try? FileManager.default.removeItem(at: url)
                }
                self.currentLyrics = nil
                self.currentLyricsTrack = nil
                self.currentLyricsIsConfident = false
            }
        }
    }

    func disableSearchForCurrentAlbum() {
        guard let targetTrack = selectedPlayer.currentTrack,
              let targetAlbum = targetTrack.album else {
            return
        }
        performOnLyricsQueue { [weak self] in
            guard let self,
                  selectedPlayer.currentTrack?.id == targetTrack.id else {
                return
            }
            if !defaults[.noSearchingAlbumNames].contains(targetAlbum) {
                defaults[.noSearchingAlbumNames].append(targetAlbum)
            }
            if defaults[.writeToiTunesAutomatically] {
                targetTrack.setLyrics("")
            }
            self.invalidateSearch()
            if self.currentLyricsTrack?.id == targetTrack.id {
                if let url = self.currentLyrics?.metadata.localURL {
                    try? FileManager.default.removeItem(at: url)
                }
                self.currentLyrics = nil
                self.currentLyricsTrack = nil
                self.currentLyricsIsConfident = false
            }
        }
    }
}

extension AppController {
    
    func importLyrics(_ lyricsString: String) throws {
        guard let lrc = Lyrics(lyricsString) else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "Invalid lyric file",
                NSLocalizedRecoverySuggestionErrorKey: "Please try another one."
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        guard let track = selectedPlayer.currentTrack else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "No music playing",
                NSLocalizedRecoverySuggestionErrorKey: "Play a music and try again."
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        lrc.metadata.title = track.title
        lrc.metadata.artist = track.artist
        lrc.filtrate()
        lrc.recognizeLanguage()
        lrc.metadata.needsPersist = true
        useLyrics(lrc, for: track, writeToPlayer: false)
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
