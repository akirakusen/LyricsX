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
    public let isPlaying: Bool
    public let artworkURL: String?

    public init(
        url: String,
        videoID: String?,
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        playbackTime: TimeInterval,
        isPlaying: Bool,
        artworkURL: String?
    ) {
        self.url = url
        self.videoID = videoID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.playbackTime = playbackTime
        self.isPlaying = isPlaying
        self.artworkURL = artworkURL
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

    public init(
        id: String,
        title: String?,
        album: String?,
        artist: String?,
        duration: TimeInterval?
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.duration = duration
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

    public static func shouldUpdatePosition(
        isPlaying: Bool,
        currentTime: TimeInterval,
        snapshotTime: TimeInterval,
        timeSinceLastPlayingSynchronization: TimeInterval?
    ) -> Bool {
        guard isPlaying else {
            return currentTime != snapshotTime
        }

        if abs(currentTime - snapshotTime) >= playingTimeTolerance {
            return true
        }
        guard let timeSinceLastPlayingSynchronization else {
            return true
        }
        return timeSinceLastPlayingSynchronization >= maximumPlayingSynchronizationInterval
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
