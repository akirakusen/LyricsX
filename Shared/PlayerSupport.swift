//
//  PlayerSupport.swift
//  LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Foundation

/// Stable values persisted by LyricsX for the preferred playback source.
public enum PlayerSelection: Int, CaseIterable, Sendable {
    case automatic = -1
    case appleMusic = 0
    case spotify = 1
    case vox = 2
    case audirvana = 3
    case swinsian = 4

    public func route(
        systemNowPlayingEnabled: Bool,
        systemNowPlayingAvailable: Bool
    ) -> PlayerRoute {
        guard self == .automatic else {
            return .scriptablePlayer(index: rawValue)
        }
        return .automatic(
            includeSystemNowPlaying: systemNowPlayingEnabled && systemNowPlayingAvailable
        )
    }
}

/// The concrete playback source used by LyricsX after applying user preferences
/// and runtime availability.
public enum PlayerRoute: Equatable, Sendable {
    case automatic(includeSystemNowPlaying: Bool)
    case scriptablePlayer(index: Int)
}

/// Lightweight player state used to select among automatic playback sources
/// without depending on AppKit or the MusicPlayer package.
public enum PlaybackSourceActivity: Equatable, Sendable {
    case stopped
    case paused
    case playing
}

public enum AutomaticPlayerSelectionPolicy {
    public static func selectedIndex(
        currentIndex: Int?,
        activities: [PlaybackSourceActivity]
    ) -> Int? {
        if let currentIndex,
           activities.indices.contains(currentIndex),
           activities[currentIndex] == .playing {
            return currentIndex
        }
        if let playingIndex = activities.firstIndex(of: .playing) {
            return playingIndex
        }
        return activities.firstIndex { $0 != .stopped }
    }
}

public enum LyricsDisplaySlot: Equatable, Sendable {
    case current
    case next
}

/// Normalized current/next lyric state shared by horizontal and vertical layouts.
public struct TwoLineLyricsDisplayState: Equatable, Sendable {
    public let currentLine: String?
    public let nextLine: String?

    public init(currentLine: String, nextLine: String) {
        let current = Self.nonempty(currentLine)
        self.currentLine = current
        self.nextLine = current == nil ? nil : Self.nonempty(nextLine)
    }

    public func arrangedSlots(isVertical: Bool) -> [LyricsDisplaySlot] {
        guard currentLine != nil else { return [] }
        let logicalOrder: [LyricsDisplaySlot] = nextLine == nil
            ? [.current]
            : [.current, .next]
        return isVertical ? Array(logicalOrder.reversed()) : logicalOrder
    }

    private static func nonempty(_ line: String) -> String? {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : line
    }
}

public enum LyricsSecondaryLineSource: Equatable, Sendable {
    case hidden
    case next
    case translation
}

public enum LyricsSecondaryLinePolicy {
    public static func source(
        oneLineMode: Bool,
        isVertical: Bool,
        prefersTranslation: Bool,
        hasTranslation: Bool
    ) -> LyricsSecondaryLineSource {
        if oneLineMode {
            return .hidden
        }
        if !isVertical, prefersTranslation, hasTranslation {
            return .translation
        }
        return .next
    }
}

public struct LyricsSearchSeed: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let artist: String?

    public init(title: String, artist: String?) {
        self.title = title
        self.artist = artist
    }
}

public enum YouTubeMusicSearchSeedPolicy {
    public static func merged(
        existing: [LyricsSearchSeed],
        incoming: [LyricsSearchSeed]
    ) -> [LyricsSearchSeed] {
        var keys = Set<String>()
        return (existing + incoming).compactMap { seed in
            let title = normalized(seed.title)
            guard !title.isEmpty else { return nil }
            let artist = seed.artist.map(normalized).flatMap {
                $0.isEmpty ? nil : $0
            }
            let key = key(title: title, artist: artist)
            guard keys.insert(key).inserted else { return nil }
            return LyricsSearchSeed(title: title, artist: artist)
        }
    }

    public static func excluding(
        _ candidates: [LyricsSearchSeed],
        matching blockedSeeds: [LyricsSearchSeed]
    ) -> [LyricsSearchSeed] {
        let blockedKeys = Set(blockedSeeds.map {
            key(title: $0.title, artist: $0.artist)
        })
        return merged(existing: [], incoming: candidates).filter {
            !blockedKeys.contains(key(title: $0.title, artist: $0.artist))
        }
    }

    public static func contains(
        _ seed: LyricsSearchSeed,
        in candidates: [LyricsSearchSeed]
    ) -> Bool {
        let candidateKeys = Set(candidates.map {
            key(title: $0.title, artist: $0.artist)
        })
        return candidateKeys.contains(key(title: seed.title, artist: seed.artist))
    }

    private static func normalized(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func canonical(_ value: String) -> String {
        normalized(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func key(title: String, artist: String?) -> String {
        canonical(title) + "\u{1F}" + canonical(artist ?? "")
    }
}

/// Keeps transient Media Session metadata from the previous video out of a
/// newly selected YouTube Music track while retaining stable bilingual aliases.
public struct YouTubeMusicSearchSeedTracker: Equatable, Sendable {
    private static let maximumBlockedSeedCount = 64
    private static let repeatedDOMConfirmationCount = 3

    private var activeTrackID: String?
    private var trustedSeeds: [LyricsSearchSeed] = []
    private var blockedRecentTrackSeeds: [LyricsSearchSeed] = []
    private var confirmedDOMPrimary: LyricsSearchSeed?
    private var pendingBlockedDOMPrimary: LyricsSearchSeed?
    private var pendingBlockedDOMObservationCount = 0

    public init() {}

    public mutating func update(
        trackID: String,
        candidates: [LyricsSearchSeed],
        domPrimary: LyricsSearchSeed?
    ) -> [LyricsSearchSeed] {
        if activeTrackID != trackID {
            if activeTrackID != nil {
                blockedRecentTrackSeeds = YouTubeMusicSearchSeedPolicy.merged(
                    existing: blockedRecentTrackSeeds,
                    incoming: trustedSeeds
                )
                if blockedRecentTrackSeeds.count > Self.maximumBlockedSeedCount {
                    blockedRecentTrackSeeds.removeFirst(
                        blockedRecentTrackSeeds.count - Self.maximumBlockedSeedCount
                    )
                }
            }
            trustedSeeds = []
            confirmedDOMPrimary = nil
            pendingBlockedDOMPrimary = nil
            pendingBlockedDOMObservationCount = 0
            activeTrackID = trackID
        }

        updateDOMPrimary(domPrimary)

        let filteredCandidates = YouTubeMusicSearchSeedPolicy.excluding(
            candidates,
            matching: blockedRecentTrackSeeds
        )
        trustedSeeds = YouTubeMusicSearchSeedPolicy.excluding(
            trustedSeeds,
            matching: blockedRecentTrackSeeds
        )
        var primary: [LyricsSearchSeed] = []
        if let confirmedDOMPrimary {
            primary = [confirmedDOMPrimary]
        }
        trustedSeeds = YouTubeMusicSearchSeedPolicy.merged(
            existing: primary,
            incoming: trustedSeeds + filteredCandidates
        )
        return trustedSeeds
    }

    private mutating func updateDOMPrimary(_ domPrimary: LyricsSearchSeed?) {
        guard let normalizedDOMPrimary = domPrimary.flatMap({
            YouTubeMusicSearchSeedPolicy.merged(existing: [], incoming: [$0]).first
        }) else {
            return
        }
        if normalizedDOMPrimary == confirmedDOMPrimary {
            pendingBlockedDOMPrimary = nil
            pendingBlockedDOMObservationCount = 0
            return
        }

        let matchesRecentTrack = YouTubeMusicSearchSeedPolicy.contains(
            normalizedDOMPrimary,
            in: blockedRecentTrackSeeds
        )
        if matchesRecentTrack {
            if pendingBlockedDOMPrimary == normalizedDOMPrimary {
                pendingBlockedDOMObservationCount += 1
            } else {
                pendingBlockedDOMPrimary = normalizedDOMPrimary
                pendingBlockedDOMObservationCount = 1
            }
            guard pendingBlockedDOMObservationCount
                    >= Self.repeatedDOMConfirmationCount else {
                return
            }
        } else {
            pendingBlockedDOMPrimary = nil
            pendingBlockedDOMObservationCount = 0
        }

        if let confirmedDOMPrimary {
            trustedSeeds = YouTubeMusicSearchSeedPolicy.excluding(
                trustedSeeds,
                matching: [confirmedDOMPrimary]
            )
        }
        confirmedDOMPrimary = normalizedDOMPrimary
    }

    public mutating func reset() {
        self = YouTubeMusicSearchSeedTracker()
    }
}

public enum LyricsSearchCandidateTier: Equatable, Hashable, Sendable {
    case paired
    case titleOnly
}

public struct LyricsSearchCandidate: Equatable, Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let tier: LyricsSearchCandidateTier

    public init(title: String, artist: String?, tier: LyricsSearchCandidateTier) {
        self.title = title
        self.artist = artist
        self.tier = tier
    }
}

public enum LyricsSearchResultSelectionPolicy {
    public static func shouldReplace(
        currentQuality: Double?,
        currentIsConfident: Bool,
        incomingQuality: Double,
        incomingIsConfident: Bool
    ) -> Bool {
        guard incomingQuality.isFinite else { return false }
        guard let currentQuality, currentQuality.isFinite else { return true }
        if currentIsConfident != incomingIsConfident {
            return incomingIsConfident
        }
        return incomingQuality > currentQuality
    }
}

public struct LyricsSearchResultMatch: Equatable, Sendable {
    public let isPlausible: Bool
    public let isConfident: Bool

    public init(isPlausible: Bool, isConfident: Bool) {
        self.isPlausible = isPlausible
        self.isConfident = isConfident
    }
}

public enum LyricsSearchResultMatchPolicy {
    public static let maximumDurationDifference: TimeInterval = 8

    public static func evaluate(
        resultTitle: String?,
        resultArtist: String?,
        resultDuration: TimeInterval?,
        trackDuration: TimeInterval?,
        searchSeeds: [LyricsSearchSeed]
    ) -> LyricsSearchResultMatch {
        guard let resultTitle = nonempty(resultTitle) else {
            return LyricsSearchResultMatch(isPlausible: false, isConfident: false)
        }
        let titleMatchedSeeds = searchSeeds.filter {
            LyricsSearchCandidatePlanner.titlesLikelyMatch(resultTitle, $0.title)
        }
        guard !titleMatchedSeeds.isEmpty else {
            return LyricsSearchResultMatch(isPlausible: false, isConfident: false)
        }

        let validResultDuration = resultDuration.flatMap(positiveFinite)
        let validTrackDuration = trackDuration.flatMap(positiveFinite)
        let hasDurationEvidence = validResultDuration != nil && validTrackDuration != nil
        let durationMatches = validResultDuration.flatMap { resultDuration in
            validTrackDuration.map {
                abs(resultDuration - $0) <= maximumDurationDifference
            }
        } ?? false
        if hasDurationEvidence, !durationMatches {
            return LyricsSearchResultMatch(isPlausible: false, isConfident: false)
        }

        let expectedArtists = titleMatchedSeeds.compactMap(\.artist).compactMap(nonempty)
        let validResultArtist = nonempty(resultArtist)
        let artistMatches: Bool
        let artistMayBeTransliterated: Bool
        if let validResultArtist {
            artistMatches = expectedArtists.contains {
                LyricsSearchCandidatePlanner.artistsLikelyMatch(validResultArtist, $0)
            }
            artistMayBeTransliterated = expectedArtists.contains {
                LyricsSearchCandidatePlanner.scriptsDiffer(validResultArtist, $0)
            }
        } else {
            artistMatches = false
            artistMayBeTransliterated = false
        }
        if validResultArtist != nil, !expectedArtists.isEmpty, !artistMatches {
            guard artistMayBeTransliterated else {
                return LyricsSearchResultMatch(isPlausible: false, isConfident: false)
            }
            return LyricsSearchResultMatch(
                isPlausible: true,
                isConfident: durationMatches
            )
        }
        return LyricsSearchResultMatch(
            isPlausible: true,
            isConfident: durationMatches || artistMatches
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positiveFinite(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite && value > 0 ? value : nil
    }
}

/// Prevents a cache file written for another YouTube Music track from being
/// trusted solely because its filename matches the current browser metadata.
public enum LyricsCacheCompatibilityPolicy {
    public static func shouldUseCachedLyrics(
        cachedTitle: String?,
        cachedArtist: String?,
        cachedDuration: TimeInterval? = nil,
        trackDuration: TimeInterval? = nil,
        searchSeeds: [LyricsSearchSeed]
    ) -> Bool {
        guard let cachedTitle = cachedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !cachedTitle.isEmpty else {
            return true
        }
        let expectedTitles = searchSeeds
            .map(\.title)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !expectedTitles.isEmpty else {
            return true
        }
        return LyricsSearchResultMatchPolicy.evaluate(
            resultTitle: cachedTitle,
            resultArtist: cachedArtist,
            resultDuration: cachedDuration,
            trackDuration: trackDuration,
            searchSeeds: searchSeeds
        ).isPlausible
    }
}

/// Builds a small, ordered search plan while preserving the original metadata.
public enum LyricsSearchCandidatePlanner {
    public static func candidates(
        from seeds: [LyricsSearchSeed],
        maximumCount: Int = 8
    ) -> [LyricsSearchCandidate] {
        guard maximumCount > 0 else { return [] }

        let normalizedSeeds = seeds.compactMap(normalizedSeed)
        var paired: [LyricsSearchCandidate] = []
        var titleOnly: [LyricsSearchCandidate] = []
        var pairedKeys = Set<String>()
        var titleOnlyKeys = Set<String>()

        func appendPaired(title: String, artist: String) {
            let key = canonical(title) + "\u{1F}" + canonical(artist)
            guard pairedKeys.insert(key).inserted else { return }
            paired.append(
                LyricsSearchCandidate(title: title, artist: artist, tier: .paired)
            )
        }

        func appendTitleOnly(_ title: String) {
            let key = canonical(title)
            guard titleOnlyKeys.insert(key).inserted else { return }
            titleOnly.append(
                LyricsSearchCandidate(title: title, artist: nil, tier: .titleOnly)
            )
        }

        // Keep the DOM and Media Session title/artist pairs intact and first.
        for seed in normalizedSeeds {
            if let artist = seed.artist {
                appendPaired(title: seed.title, artist: artist)
            }
            appendTitleOnly(seed.title)
        }

        for seed in normalizedSeeds {
            let titleVariants = safeVariants(of: seed.title)
            let artistVariants = seed.artist.map(safeVariants) ?? []
            if let artist = seed.artist {
                for title in titleVariants.dropFirst() {
                    appendPaired(title: title, artist: artist)
                }
                for artistVariant in artistVariants.dropFirst() {
                    appendPaired(title: seed.title, artist: artistVariant)
                }
            }
            for title in titleVariants.dropFirst() {
                appendTitleOnly(title)
            }
        }

        if paired.count >= maximumCount, maximumCount > 1, !titleOnly.isEmpty {
            paired = Array(paired.prefix(maximumCount - 1))
        }
        return Array((paired + titleOnly).prefix(maximumCount))
    }

    public static func titlesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = canonical(lhs)
        let rhs = canonical(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    public static func artistsLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        titlesLikelyMatch(lhs, rhs)
    }

    private static func normalizedSeed(_ seed: LyricsSearchSeed) -> LyricsSearchSeed? {
        let title = normalized(seed.title)
        guard !title.isEmpty else { return nil }
        let artist = seed.artist.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
        return LyricsSearchSeed(title: title, artist: artist)
    }

    private static func safeVariants(of value: String) -> [String] {
        let value = normalized(value)
        guard !value.isEmpty else { return [] }
        var variants = [value]

        let bracketPairs: [(Character, Character)] = [
            ("(", ")"),
            ("（", "）"),
            ("[", "]"),
            ("【", "】"),
        ]
        for (open, close) in bracketPairs where value.last == close {
            guard let openIndex = value.lastIndex(of: open), openIndex != value.startIndex else {
                continue
            }
            let outer = normalized(String(value[..<openIndex]))
            let innerStart = value.index(after: openIndex)
            let innerEnd = value.index(before: value.endIndex)
            let inner = normalized(String(value[innerStart..<innerEnd]))
            if scriptsDiffer(outer, inner) {
                if !outer.isEmpty {
                    variants.append(outer)
                }
                if !inner.isEmpty {
                    variants.append(inner)
                }
            }
        }

        let separators = [
            " - ", " / ", " ／ ", " | ", " ｜ ", "／", "｜", " • ", " · ",
        ]
        for separator in separators where value.contains(separator) {
            let parts = value.components(separatedBy: separator).map(normalized)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
                  scriptsDiffer(parts[0], parts[1]) else {
                continue
            }
            variants.append(contentsOf: parts)
        }

        var seen = Set<String>()
        return variants.filter { seen.insert(canonical($0)).inserted }
    }

    private static func normalized(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func canonical(_ value: String) -> String {
        normalized(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    public static func scriptsDiffer(_ lhs: String, _ rhs: String) -> Bool {
        let lhsScripts = scripts(in: lhs)
        let rhsScripts = scripts(in: rhs)
        return !lhsScripts.isEmpty && !rhsScripts.isEmpty && lhsScripts.isDisjoint(with: rhsScripts)
    }

    private enum Script: Hashable {
        case cjk
        case latin
    }

    private static func scripts(in value: String) -> Set<Script> {
        var result = Set<Script>()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0041 ... 0x024F:
                result.insert(.latin)
            case 0x3040 ... 0x30FF, 0x3400 ... 0x9FFF:
                result.insert(.cjk)
            default:
                continue
            }
        }
        return result
    }
}

public enum LyricsTimelineRefreshPolicy {
    public static let minimumDelay: TimeInterval = 0.05
    public static let watchdogInterval: TimeInterval = 1

    public static func nextDelay(
        isPlaying: Bool,
        playbackTime: TimeInterval,
        nextLineTime: TimeInterval?
    ) -> TimeInterval? {
        guard isPlaying, playbackTime.isFinite,
              let nextLineTime, nextLineTime.isFinite else {
            return nil
        }
        let boundaryDelay = max(nextLineTime - playbackTime, minimumDelay)
        return min(boundaryDelay, watchdogInterval)
    }
}

/// Testable mirror of the media-element ranking used by the Chrome bridge.
public struct YouTubeMusicMediaCandidate: Equatable, Sendable {
    public let hasCurrentSource: Bool
    public let isPaused: Bool
    public let isEnded: Bool
    public let isMainPlayer: Bool
    public let readyState: Int
    public let playbackTime: TimeInterval

    public init(
        hasCurrentSource: Bool,
        isPaused: Bool,
        isEnded: Bool,
        isMainPlayer: Bool,
        readyState: Int,
        playbackTime: TimeInterval
    ) {
        self.hasCurrentSource = hasCurrentSource
        self.isPaused = isPaused
        self.isEnded = isEnded
        self.isMainPlayer = isMainPlayer
        self.readyState = readyState
        self.playbackTime = playbackTime
    }
}

public enum YouTubeMusicMediaSelector {
    public static func selectedIndex(
        from candidates: [YouTubeMusicMediaCandidate]
    ) -> Int? {
        let loaded = candidates.indices.filter {
            candidates[$0].hasCurrentSource
        }
        let playing = loaded.filter {
            let candidate = candidates[$0]
            return !candidate.isPaused && !candidate.isEnded
        }
        let eligible = playing.isEmpty ? loaded : playing
        return eligible
            .max { lhs, rhs in
                rank(candidates[lhs]) < rank(candidates[rhs])
            }
    }

    private static func rank(
        _ candidate: YouTubeMusicMediaCandidate
    ) -> (Int, Int, Int, Int) {
        (
            candidate.isEnded ? 0 : 1,
            candidate.isMainPlayer ? 1 : 0,
            max(0, candidate.readyState),
            candidate.playbackTime.isFinite && candidate.playbackTime > 0 ? 1 : 0
        )
    }
}

public struct YouTubeMusicPlaybackTiming: Equatable, Sendable {
    public let playbackTime: TimeInterval
    public let duration: TimeInterval?
    public let precision: TimeInterval?

    public init(
        playbackTime: TimeInterval,
        duration: TimeInterval?,
        precision: TimeInterval? = nil
    ) {
        self.playbackTime = playbackTime
        self.duration = duration
        self.precision = precision
    }
}

/// YouTube Music can expose a playlist-wide MSE media timeline. Its progress
/// control remains track-relative, so it must win whenever it is valid.
public enum YouTubeMusicPlaybackTimingPolicy {
    public static let mediaDurationMatchTolerance: TimeInterval = 2

    public static func resolve(
        progressTime: TimeInterval?,
        progressDuration: TimeInterval?,
        mediaTime: TimeInterval,
        mediaDuration: TimeInterval?
    ) -> YouTubeMusicPlaybackTiming {
        let validProgressTime = progressTime.flatMap(nonnegativeFinite)
        let validProgressDuration = progressDuration.flatMap(positiveFinite)
        let validMediaTime = nonnegativeFinite(mediaTime) ?? 0
        let validMediaDuration = mediaDuration.flatMap(positiveFinite)

        if let validProgressTime {
            if let validProgressDuration,
               let validMediaDuration,
               abs(validMediaDuration - validProgressDuration)
                <= mediaDurationMatchTolerance,
               validMediaTime <= validProgressDuration + mediaDurationMatchTolerance {
                return YouTubeMusicPlaybackTiming(
                    playbackTime: min(validMediaTime, validProgressDuration),
                    duration: validProgressDuration
                )
            }
            let playbackTime = validProgressDuration.map {
                min(validProgressTime, $0)
            } ?? validProgressTime
            return YouTubeMusicPlaybackTiming(
                playbackTime: playbackTime,
                duration: validProgressDuration,
                precision: 1
            )
        }

        return YouTubeMusicPlaybackTiming(
            playbackTime: validMediaDuration.map {
                min(validMediaTime, $0)
            } ?? validMediaTime,
            duration: validMediaDuration
        )
    }

    private static func nonnegativeFinite(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite && value >= 0 ? value : nil
    }

    private static func positiveFinite(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite && value > 0 ? value : nil
    }
}

/// A browser-independent representation of the state read from YouTube Music.
/// Keeping this model outside AppKit makes the Chrome integration testable with
/// Swift Package Manager as well as the application target.
public struct YouTubeMusicSnapshot: Codable, Equatable, Sendable {
    public let url: String
    public let videoID: String?
    public let title: String
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?
    public let playbackTime: TimeInterval
    public let playbackTimePrecision: TimeInterval?
    public let isPlaying: Bool
    public let artworkURL: String?
    public let searchSeeds: [LyricsSearchSeed]?
    public let domTitle: String?
    public let domArtist: String?

    public init(
        url: String,
        videoID: String?,
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        playbackTime: TimeInterval,
        playbackTimePrecision: TimeInterval? = nil,
        isPlaying: Bool,
        artworkURL: String?,
        searchSeeds: [LyricsSearchSeed]? = nil,
        domTitle: String? = nil,
        domArtist: String? = nil
    ) {
        self.url = url
        self.videoID = videoID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.playbackTime = playbackTime
        self.playbackTimePrecision = playbackTimePrecision
        self.isPlaying = isPlaying
        self.artworkURL = artworkURL
        self.searchSeeds = searchSeeds
        self.domTitle = domTitle
        self.domArtist = domArtist
    }

    public var trackID: String {
        if let videoID, !videoID.isEmpty {
            return "youtube:\(videoID)"
        }
        let durationComponent = duration.map { String(Int($0.rounded())) } ?? ""
        return "youtube:\([title, artist ?? "", album ?? "", durationComponent].joined(separator: "\u{1F}"))"
    }

    public var clampedPlaybackTime: TimeInterval {
        let nonnegativeTime = max(0, playbackTime)
        guard let duration, duration.isFinite, duration > 0 else {
            return nonnegativeTime
        }
        return min(nonnegativeTime, duration)
    }
}

/// A YouTube Music tab and the playable state observed in that tab.
public struct YouTubeMusicTabCandidate: Equatable, Sendable {
    public let tabID: String
    public let snapshot: YouTubeMusicSnapshot

    public init(tabID: String, snapshot: YouTubeMusicSnapshot) {
        self.tabID = tabID
        self.snapshot = snapshot
    }
}

/// Selects a stable tab without letting an idle tab hide one that is playing.
public enum YouTubeMusicTabSelector {
    public static func select(
        from candidates: [YouTubeMusicTabCandidate],
        previouslyActiveTabID: String?,
        frontWindowActiveTabID: String?
    ) -> YouTubeMusicTabCandidate? {
        let playingCandidates = candidates.filter(\.snapshot.isPlaying)
        let eligibleCandidates = playingCandidates.isEmpty ? candidates : playingCandidates

        if let previouslyActiveTabID,
           let previous = eligibleCandidates.first(where: { $0.tabID == previouslyActiveTabID }) {
            return previous
        }
        if let frontWindowActiveTabID,
           let front = eligibleCandidates.first(where: { $0.tabID == frontWindowActiveTabID }) {
            return front
        }
        return eligibleCandidates.first
    }
}

/// Metadata that determines whether LyricsX should treat a browser update as a
/// different track. Artwork is intentionally excluded because it arrives later.
public struct YouTubeMusicTrackDescriptor: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let album: String?
    public let artist: String?
    public let duration: TimeInterval?
    public let searchSeeds: [LyricsSearchSeed]

    public init(
        id: String,
        title: String?,
        album: String?,
        artist: String?,
        duration: TimeInterval?,
        searchSeeds: [LyricsSearchSeed] = []
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.duration = duration
        self.searchSeeds = searchSeeds
    }
}

public enum YouTubeMusicTrackUpdatePolicy {
    public static func shouldPublishTrackChange(
        current: YouTubeMusicTrackDescriptor?,
        incoming: YouTubeMusicTrackDescriptor?
    ) -> Bool {
        current != incoming
    }

    public static func shouldApplyArtwork(
        downloadedTrackID: String,
        currentTrackID: String?
    ) -> Bool {
        currentTrackID == downloadedTrackID
    }
}

public enum YouTubeMusicObservation: Equatable, Sendable {
    case validSnapshot
    case sourceUnavailable
    case transientFailure
}

public enum YouTubeMusicObservationAction: Equatable, Sendable {
    case applySnapshot
    case retainLastKnownState
    case clearState
}

/// Keeps brief Chrome/Apple Event failures from looking like playback stopped,
/// while still clearing immediately after a complete scan finds no source.
public struct YouTubeMusicObservationPolicy: Equatable, Sendable {
    public let transientFailureThreshold: Int
    public private(set) var consecutiveTransientFailures = 0

    public init(transientFailureThreshold: Int = 3) {
        precondition(transientFailureThreshold > 0)
        self.transientFailureThreshold = transientFailureThreshold
    }

    public mutating func register(
        _ observation: YouTubeMusicObservation
    ) -> YouTubeMusicObservationAction {
        switch observation {
        case .validSnapshot:
            consecutiveTransientFailures = 0
            return .applySnapshot
        case .sourceUnavailable:
            consecutiveTransientFailures = 0
            return .clearState
        case .transientFailure:
            consecutiveTransientFailures = min(
                consecutiveTransientFailures + 1,
                transientFailureThreshold
            )
            return consecutiveTransientFailures >= transientFailureThreshold
                ? .clearState
                : .retainLastKnownState
        }
    }
}

/// Controls how often a running playback clock is corrected from browser state.
public enum YouTubeMusicPlaybackUpdatePolicy {
    public static let playingTimeTolerance: TimeInterval = 0.35
    public static let maximumPlayingSynchronizationInterval: TimeInterval = 5
    public static let discreteTimeTolerancePadding: TimeInterval = 0.1
    public static let discreteTimeSynchronizationInterval: TimeInterval = 30

    public static func shouldUpdatePosition(
        isPlaying: Bool,
        currentTime: TimeInterval,
        snapshotTime: TimeInterval,
        timeSinceLastPlayingSynchronization: TimeInterval?,
        snapshotPrecision: TimeInterval? = nil
    ) -> Bool {
        guard isPlaying else {
            return currentTime != snapshotTime
        }

        let validPrecision = snapshotPrecision.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        let tolerance = max(
            playingTimeTolerance,
            validPrecision + discreteTimeTolerancePadding
        )
        if abs(currentTime - snapshotTime) >= tolerance {
            return true
        }
        guard let timeSinceLastPlayingSynchronization else {
            return true
        }
        let synchronizationInterval = validPrecision >= 1
            ? discreteTimeSynchronizationInterval
            : maximumPlayingSynchronizationInterval
        return timeSinceLastPlayingSynchronization >= synchronizationInterval
    }
}

/// Normalizes Chrome AppleScript failures without depending on localized text
/// when Chrome or macOS provides a stable error number.
public enum ChromeAppleScriptErrorKind: Equatable, Sendable {
    case automationDenied
    case javascriptDisabled
    case timedOut
    case other

    public static func classify(
        errorNumber: Int?,
        message: String
    ) -> ChromeAppleScriptErrorKind {
        switch errorNumber {
        case -1743:
            return .automationDenied
        case 12:
            return .javascriptDisabled
        case -1712:
            return .timedOut
        default:
            break
        }

        if message.localizedCaseInsensitiveContains("JavaScript through AppleScript is turned off") ||
            message.localizedCaseInsensitiveContains("Allow JavaScript from Apple Events") {
            return .javascriptDisabled
        }
        return .other
    }
}

public enum YouTubeMusicCommandRetryPolicy {
    public static func shouldRetry(
        isIdempotent: Bool,
        failureWasDefinitelyBeforeExecution: Bool
    ) -> Bool {
        isIdempotent || failureWasDefinitelyBeforeExecution
    }
}
