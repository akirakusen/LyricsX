import XCTest
@testable import LyricsXPlayerSupport

final class PlayerSupportTests: XCTestCase {
    func testBundledDefaultsEnableWebPlaybackRoute() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let defaultsURL = repositoryURL
            .appendingPathComponent("LyricsX/Supporting Files/UserDefaults.plist")
        let data = try Data(contentsOf: defaultsURL)
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(values["PreferredPlayerIndex"] as? Int, PlayerSelection.automatic.rawValue)
        XCTAssertEqual(values["UseSystemWideNowPlaying"] as? Bool, false)
    }

    func testAutomaticSelectionIncludesAvailableSystemNowPlayingFallback() {
        XCTAssertEqual(
            PlayerSelection.automatic.route(
                systemNowPlayingEnabled: true,
                systemNowPlayingAvailable: true
            ),
            .automatic(includeSystemNowPlaying: true)
        )
    }

    func testAutomaticSelectionFallsBackWhenSystemNowPlayingIsUnavailable() {
        XCTAssertEqual(
            PlayerSelection.automatic.route(
                systemNowPlayingEnabled: true,
                systemNowPlayingAvailable: false
            ),
            .automatic(includeSystemNowPlaying: false)
        )
        XCTAssertEqual(
            PlayerSelection.automatic.route(
                systemNowPlayingEnabled: false,
                systemNowPlayingAvailable: true
            ),
            .automatic(includeSystemNowPlaying: false)
        )
    }

    func testExplicitPlayerSelectionStaysScriptable() {
        XCTAssertEqual(
            PlayerSelection.spotify.route(
                systemNowPlayingEnabled: true,
                systemNowPlayingAvailable: true
            ),
            .scriptablePlayer(index: PlayerSelection.spotify.rawValue)
        )
    }

    func testAutomaticPlayerSelectionKeepsCurrentPlayingSource() {
        XCTAssertEqual(
            AutomaticPlayerSelectionPolicy.selectedIndex(
                currentIndex: 1,
                activities: [.playing, .playing, .paused]
            ),
            1
        )
    }

    func testAutomaticPlayerSelectionLeavesPausedSourceForPlayingSource() {
        XCTAssertEqual(
            AutomaticPlayerSelectionPolicy.selectedIndex(
                currentIndex: 0,
                activities: [.paused, .playing, .stopped]
            ),
            1
        )
    }

    func testAutomaticPlayerSelectionUsesPausedSourceOnlyAsFallback() {
        XCTAssertEqual(
            AutomaticPlayerSelectionPolicy.selectedIndex(
                currentIndex: nil,
                activities: [.stopped, .paused, .paused]
            ),
            1
        )
        XCTAssertNil(
            AutomaticPlayerSelectionPolicy.selectedIndex(
                currentIndex: 0,
                activities: [.stopped, .stopped]
            )
        )
    }

    func testVerticalTwoLineLyricsAdvanceCurrentAndNextColumns() {
        let first = TwoLineLyricsDisplayState(currentLine: "A", nextLine: "B")
        let second = TwoLineLyricsDisplayState(currentLine: "B", nextLine: "C")
        let final = TwoLineLyricsDisplayState(currentLine: "C", nextLine: "")

        XCTAssertEqual(first.arrangedSlots(isVertical: true), [.next, .current])
        XCTAssertEqual(second.currentLine, first.nextLine)
        XCTAssertEqual(second.arrangedSlots(isVertical: true), [.next, .current])
        XCTAssertEqual(final.arrangedSlots(isVertical: true), [.current])
        XCTAssertEqual(first.arrangedSlots(isVertical: false), [.current, .next])
    }

    func testTwoLineLyricsEmptyCurrentLineHidesEverySlot() {
        let state = TwoLineLyricsDisplayState(currentLine: "  \n", nextLine: "stale")

        XCTAssertNil(state.currentLine)
        XCTAssertNil(state.nextLine)
        XCTAssertTrue(state.arrangedSlots(isVertical: true).isEmpty)
    }

    func testVerticalLyricsAlwaysUseTheNextSentenceAsTheSecondColumn() {
        XCTAssertEqual(
            LyricsSecondaryLinePolicy.source(
                oneLineMode: false,
                isVertical: true,
                prefersTranslation: true,
                hasTranslation: true
            ),
            .next
        )
        XCTAssertEqual(
            LyricsSecondaryLinePolicy.source(
                oneLineMode: false,
                isVertical: false,
                prefersTranslation: true,
                hasTranslation: true
            ),
            .translation
        )
        XCTAssertEqual(
            LyricsSecondaryLinePolicy.source(
                oneLineMode: true,
                isVertical: true,
                prefersTranslation: true,
                hasTranslation: true
            ),
            .hidden
        )
    }

    func testYouTubeMusicSnapshotDecodesChromePayload() throws {
        let payload = #"""
        {
          "url": "https://music.youtube.com/watch?v=abc123",
          "videoID": "abc123",
          "title": "Test Song",
          "artist": "Test Artist",
          "album": "Test Album",
          "duration": 245.5,
          "playbackTime": 17.25,
          "isPlaying": true,
          "artworkURL": "https://example.com/cover.jpg"
        }
        """#.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(YouTubeMusicSnapshot.self, from: payload)

        XCTAssertEqual(snapshot.trackID, "youtube:abc123")
        XCTAssertEqual(snapshot.title, "Test Song")
        XCTAssertEqual(snapshot.artist, "Test Artist")
        XCTAssertEqual(snapshot.clampedPlaybackTime, 17.25)
        XCTAssertTrue(snapshot.isPlaying)
    }

    func testYouTubeMusicSnapshotUsesStableFallbackIDAndClampsPosition() {
        let snapshot = YouTubeMusicSnapshot(
            url: "https://music.youtube.com/",
            videoID: nil,
            title: "Fallback Song",
            artist: "Fallback Artist",
            album: nil,
            duration: 120,
            playbackTime: 150,
            isPlaying: false,
            artworkURL: nil
        )

        XCTAssertEqual(snapshot.trackID, "youtube:Fallback Song\u{1F}Fallback Artist\u{1F}\u{1F}120")
        XCTAssertEqual(snapshot.clampedPlaybackTime, 120)
    }

    func testYouTubeMusicTabSelectionPrefersPlayingTab() throws {
        let candidates = [
            candidate(id: "previous", isPlaying: false),
            candidate(id: "front", isPlaying: false),
            candidate(id: "playing", isPlaying: true),
        ]

        let selected = try XCTUnwrap(
            YouTubeMusicTabSelector.select(
                from: candidates,
                previouslyActiveTabID: "previous",
                frontWindowActiveTabID: "front"
            )
        )

        XCTAssertEqual(selected.tabID, "playing")
    }

    func testYouTubeMusicTabSelectionPrefersPreviousTabWhenNothingIsPlaying() throws {
        let candidates = [
            candidate(id: "fallback", isPlaying: false),
            candidate(id: "front", isPlaying: false),
            candidate(id: "previous", isPlaying: false),
        ]

        let selected = try XCTUnwrap(
            YouTubeMusicTabSelector.select(
                from: candidates,
                previouslyActiveTabID: "previous",
                frontWindowActiveTabID: "front"
            )
        )

        XCTAssertEqual(selected.tabID, "previous")
    }

    func testYouTubeMusicTabSelectionUsesFrontTabBeforeFallback() throws {
        let candidates = [
            candidate(id: "fallback", isPlaying: false),
            candidate(id: "front", isPlaying: false),
        ]

        let selected = try XCTUnwrap(
            YouTubeMusicTabSelector.select(
                from: candidates,
                previouslyActiveTabID: "missing",
                frontWindowActiveTabID: "front"
            )
        )

        XCTAssertEqual(selected.tabID, "front")
    }

    func testYouTubeMusicTabSelectionFallsBackToFirstCandidate() throws {
        let candidates = [
            candidate(id: "first", isPlaying: false),
            candidate(id: "second", isPlaying: false),
        ]

        let selected = try XCTUnwrap(
            YouTubeMusicTabSelector.select(
                from: candidates,
                previouslyActiveTabID: nil,
                frontWindowActiveTabID: nil
            )
        )

        XCTAssertEqual(selected.tabID, "first")
    }

    func testYouTubeMusicTrackChangePolicyIgnoresPresentationOnlyUpdates() {
        let track = YouTubeMusicTrackDescriptor(
            id: "youtube:track",
            title: "Song",
            album: "Album",
            artist: "Artist",
            duration: 180
        )

        XCTAssertFalse(
            YouTubeMusicTrackUpdatePolicy.shouldPublishTrackChange(
                current: track,
                incoming: track
            )
        )
        XCTAssertTrue(
            YouTubeMusicTrackUpdatePolicy.shouldPublishTrackChange(
                current: track,
                incoming: YouTubeMusicTrackDescriptor(
                    id: track.id,
                    title: "Different Song",
                    album: track.album,
                    artist: track.artist,
                    duration: track.duration
                )
            )
        )
        XCTAssertTrue(
            YouTubeMusicTrackUpdatePolicy.shouldPublishTrackChange(
                current: nil,
                incoming: track
            )
        )
    }

    func testYouTubeMusicArtworkOnlyAppliesToTheMatchingCurrentTrack() {
        XCTAssertTrue(
            YouTubeMusicTrackUpdatePolicy.shouldApplyArtwork(
                downloadedTrackID: "youtube:current",
                currentTrackID: "youtube:current"
            )
        )
        XCTAssertFalse(
            YouTubeMusicTrackUpdatePolicy.shouldApplyArtwork(
                downloadedTrackID: "youtube:stale",
                currentTrackID: "youtube:current"
            )
        )
        XCTAssertFalse(
            YouTubeMusicTrackUpdatePolicy.shouldApplyArtwork(
                downloadedTrackID: "youtube:stale",
                currentTrackID: nil
            )
        )
    }

    func testTransientChromeFailuresRetainStateUntilTheThreshold() {
        var policy = YouTubeMusicObservationPolicy(transientFailureThreshold: 3)

        XCTAssertEqual(policy.register(.validSnapshot), .applySnapshot)
        XCTAssertEqual(policy.register(.transientFailure), .retainLastKnownState)
        XCTAssertEqual(policy.consecutiveTransientFailures, 1)
        XCTAssertEqual(policy.register(.transientFailure), .retainLastKnownState)
        XCTAssertEqual(policy.consecutiveTransientFailures, 2)
        XCTAssertEqual(policy.register(.transientFailure), .clearState)
        XCTAssertEqual(policy.consecutiveTransientFailures, 3)
        XCTAssertEqual(policy.register(.transientFailure), .clearState)
        XCTAssertEqual(policy.consecutiveTransientFailures, 3)
    }

    func testValidChromeSnapshotResetsTransientFailureCount() {
        var policy = YouTubeMusicObservationPolicy(transientFailureThreshold: 2)

        XCTAssertEqual(policy.register(.transientFailure), .retainLastKnownState)
        XCTAssertEqual(policy.register(.validSnapshot), .applySnapshot)
        XCTAssertEqual(policy.consecutiveTransientFailures, 0)
        XCTAssertEqual(policy.register(.transientFailure), .retainLastKnownState)
    }

    func testUnavailableChromeSourceClearsImmediately() {
        var policy = YouTubeMusicObservationPolicy(transientFailureThreshold: 3)

        XCTAssertEqual(policy.register(.transientFailure), .retainLastKnownState)
        XCTAssertEqual(policy.register(.sourceUnavailable), .clearState)
        XCTAssertEqual(policy.consecutiveTransientFailures, 0)
    }

    func testPausedPlaybackPositionUsesExactUpdates() {
        XCTAssertTrue(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: false,
                currentTime: 10,
                snapshotTime: 10.01,
                timeSinceLastPlayingSynchronization: nil
            )
        )
        XCTAssertFalse(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: false,
                currentTime: 10,
                snapshotTime: 10,
                timeSinceLastPlayingSynchronization: nil
            )
        )
    }

    func testPlayingPlaybackPositionHasTightToleranceAndPeriodicCorrection() {
        XCTAssertTrue(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: true,
                currentTime: 10,
                snapshotTime: 10.5,
                timeSinceLastPlayingSynchronization: 1
            )
        )
        XCTAssertFalse(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: true,
                currentTime: 10,
                snapshotTime: 10.1,
                timeSinceLastPlayingSynchronization: 1
            )
        )
        XCTAssertTrue(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: true,
                currentTime: 10,
                snapshotTime: 10.1,
                timeSinceLastPlayingSynchronization: 5
            )
        )
        XCTAssertTrue(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: true,
                currentTime: 10,
                snapshotTime: 10.1,
                timeSinceLastPlayingSynchronization: nil
            )
        )
    }

    func testChromeAppleScriptErrorNumbersTakePriorityOverMessages() {
        let cases: [(Int, String, ChromeAppleScriptErrorKind)] = [
            (-1743, "Allow JavaScript from Apple Events", .automationDenied),
            (12, "A localized Chrome error message", .javascriptDisabled),
            (-1712, "JavaScript through AppleScript is turned off", .timedOut),
        ]

        for (errorNumber, message, expected) in cases {
            XCTAssertEqual(
                ChromeAppleScriptErrorKind.classify(
                    errorNumber: errorNumber,
                    message: message
                ),
                expected
            )
        }
    }

    func testChromeAppleScriptErrorClassifierRetainsEnglishFallbacks() {
        XCTAssertEqual(
            ChromeAppleScriptErrorKind.classify(
                errorNumber: nil,
                message: "JavaScript through AppleScript is turned off"
            ),
            .javascriptDisabled
        )
        XCTAssertEqual(
            ChromeAppleScriptErrorKind.classify(
                errorNumber: 1,
                message: "Enable Allow JavaScript from Apple Events in Chrome"
            ),
            .javascriptDisabled
        )
    }

    func testChromeAppleScriptErrorClassifierReturnsOther() {
        XCTAssertEqual(
            ChromeAppleScriptErrorKind.classify(
                errorNumber: nil,
                message: "Chrome AppleScript failed."
            ),
            .other
        )
        XCTAssertEqual(
            ChromeAppleScriptErrorKind.classify(
                errorNumber: -1,
                message: "Unknown error"
            ),
            .other
        )
    }

    func testYouTubeMusicCommandRetryPolicyMatrix() {
        let cases: [(isIdempotent: Bool, failedBeforeExecution: Bool, expected: Bool)] = [
            (false, false, false),
            (false, true, true),
            (true, false, true),
            (true, true, true),
        ]

        for testCase in cases {
            XCTAssertEqual(
                YouTubeMusicCommandRetryPolicy.shouldRetry(
                    isIdempotent: testCase.isIdempotent,
                    failureWasDefinitelyBeforeExecution: testCase.failedBeforeExecution
                ),
                testCase.expected
            )
        }
    }

    private func candidate(id: String, isPlaying: Bool) -> YouTubeMusicTabCandidate {
        YouTubeMusicTabCandidate(
            tabID: id,
            snapshot: YouTubeMusicSnapshot(
                url: "https://music.youtube.com/watch?v=\(id)",
                videoID: id,
                title: id,
                artist: nil,
                album: nil,
                duration: 120,
                playbackTime: 10,
                isPlaying: isPlaying,
                artworkURL: nil
            )
        )
    }
}
