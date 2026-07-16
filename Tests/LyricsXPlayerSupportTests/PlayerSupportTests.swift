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

    func testSearchPlannerKeepsOriginalAndMediaSessionPairs() {
        let candidates = LyricsSearchCandidatePlanner.candidates(from: [
            LyricsSearchSeed(title: "アイドル (Idol)", artist: "YOASOBI"),
            LyricsSearchSeed(title: "Idol", artist: "Yoasobi"),
        ])

        XCTAssertEqual(
            Array(candidates.prefix(2)),
            [
                LyricsSearchCandidate(
                    title: "アイドル (Idol)",
                    artist: "YOASOBI",
                    tier: .paired
                ),
                LyricsSearchCandidate(title: "Idol", artist: "Yoasobi", tier: .paired),
            ]
        )
        XCTAssertTrue(candidates.contains {
            $0.title == "アイドル" && $0.artist == "YOASOBI" && $0.tier == .paired
        })
        XCTAssertTrue(candidates.contains {
            $0.title == "Idol" && $0.artist == nil && $0.tier == .titleOnly
        })
        XCTAssertEqual(
            Array(candidates.filter { $0.tier == .titleOnly }.prefix(2)),
            [
                LyricsSearchCandidate(
                    title: "アイドル (Idol)",
                    artist: nil,
                    tier: .titleOnly
                ),
                LyricsSearchCandidate(title: "Idol", artist: nil, tier: .titleOnly),
            ]
        )
    }

    func testSearchPlannerHandlesJapaneseEnglishPresentationVariants() {
        let cases: [(String, String)] = [
            ("廻廻奇譚 (Kaikai Kitan)", "廻廻奇譚"),
            ("勇者（The Brave）", "勇者"),
            ("夏色 - Natsuiro", "夏色"),
            ("祝福 / The Blessing", "祝福"),
            ("残響散歌｜Zankyosanka", "残響散歌"),
            ("ヨルシカ (Yorushika)", "ヨルシカ"),
        ]

        for (input, expected) in cases {
            let candidates = LyricsSearchCandidatePlanner.candidates(
                from: [LyricsSearchSeed(title: input, artist: "Artist")]
            )
            XCTAssertTrue(
                candidates.contains { $0.title == expected },
                "Expected \(input) to include \(expected)"
            )
        }
    }

    func testSearchPlannerDoesNotSplitOrdinaryNames() {
        let titles = [
            "Bling-Bang-Bang-Born",
            "AC/DC",
            "SawanoHiroyuki[nZk]:mizuki",
            "Song - Live",
            "Song (Live)",
            "Song (Remastered 2024)",
        ]

        for title in titles {
            let candidates = LyricsSearchCandidatePlanner.candidates(
                from: [LyricsSearchSeed(title: title, artist: "Artist")]
            )
            XCTAssertEqual(Set(candidates.map(\.title)), [title])
        }
    }

    func testSearchPlannerNormalizesAndDeduplicatesSeeds() {
        let candidates = LyricsSearchCandidatePlanner.candidates(from: [
            LyricsSearchSeed(title: "  Idol\n", artist: " YOASOBI "),
            LyricsSearchSeed(title: "idol", artist: "yoasobi"),
            LyricsSearchSeed(title: " ", artist: "Ignored"),
        ])

        XCTAssertEqual(
            candidates.filter { $0.tier == .paired },
            [LyricsSearchCandidate(title: "Idol", artist: "YOASOBI", tier: .paired)]
        )
        XCTAssertEqual(
            candidates.filter { $0.tier == .titleOnly },
            [LyricsSearchCandidate(title: "Idol", artist: nil, tier: .titleOnly)]
        )
    }

    func testSearchPlannerReservesTitleOnlyFallbackWithinLimit() {
        let candidates = LyricsSearchCandidatePlanner.candidates(
            from: [
                LyricsSearchSeed(
                    title: "アイドル (Idol)",
                    artist: "夜遊び (YOASOBI)"
                ),
                LyricsSearchSeed(
                    title: "勇者 (The Brave)",
                    artist: "ヨアソビ (Yoasobi)"
                ),
            ],
            maximumCount: 4
        )

        XCTAssertEqual(candidates.count, 4)
        XCTAssertEqual(candidates.last?.tier, .titleOnly)
    }

    func testSearchPlannerPutsJapaneseHyphenVariantInPairedStage() {
        let candidates = LyricsSearchCandidatePlanner.candidates(from: [
            LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU"),
            LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
        ])

        XCTAssertTrue(
            candidates.filter { $0.tier == .paired }.prefix(4).contains {
                $0.title == "夏色" && $0.artist == "YUZU"
            }
        )
    }

    func testConfidentFallbackReplacesHigherQualityFuzzyResult() {
        XCTAssertTrue(
            LyricsSearchResultSelectionPolicy.shouldReplace(
                currentQuality: 0.9,
                currentIsConfident: false,
                incomingQuality: 0.6,
                incomingIsConfident: true
            )
        )
        XCTAssertFalse(
            LyricsSearchResultSelectionPolicy.shouldReplace(
                currentQuality: 0.9,
                currentIsConfident: true,
                incomingQuality: 0.95,
                incomingIsConfident: false
            )
        )
    }

    func testYouTubeMusicCacheRejectsClearlyUnrelatedStoredLyrics() {
        let seeds = [
            LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU"),
            LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
        ]

        XCTAssertFalse(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "負けないで",
                cachedArtist: "ZARD",
                searchSeeds: seeds
            )
        )
    }

    func testYouTubeMusicCacheAcceptsEitherMetadataTitleAlias() {
        let seeds = [
            LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU"),
            LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
        ]

        XCTAssertTrue(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "夏色",
                cachedArtist: "YUZU",
                searchSeeds: seeds
            )
        )
        XCTAssertTrue(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "Natsuiro (Live)",
                cachedArtist: "YUZU",
                searchSeeds: seeds
            )
        )
    }

    func testYouTubeMusicCacheKeepsUntaggedLyrics() {
        let seeds = [
            LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
        ]

        XCTAssertTrue(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: nil,
                cachedArtist: "Wrong Artist",
                searchSeeds: seeds
            )
        )
        XCTAssertTrue(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "  ",
                cachedArtist: "Wrong Artist",
                searchSeeds: seeds
            )
        )
    }

    func testYouTubeMusicCacheRejectsSameTitleFromDifferentArtist() {
        let seeds = [
            LyricsSearchSeed(title: "Hello", artist: "Adele"),
        ]

        XCTAssertFalse(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "Hello",
                cachedArtist: "Lionel Richie",
                searchSeeds: seeds
            )
        )
        XCTAssertTrue(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "Hello",
                cachedArtist: nil,
                searchSeeds: seeds
            )
        )
    }

    func testYouTubeMusicCacheUsesDurationForTransliteratedArtist() {
        let seeds = [
            LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU"),
            LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
        ]

        XCTAssertTrue(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "夏色",
                cachedArtist: "柚子 (ゆず)",
                cachedDuration: 201,
                trackDuration: 203,
                searchSeeds: seeds
            )
        )
        XCTAssertFalse(
            LyricsCacheCompatibilityPolicy.shouldUseCachedLyrics(
                cachedTitle: "夏色の服 (Natsuiro no Fuku)",
                cachedArtist: "大貫妙子",
                cachedDuration: 222,
                trackDuration: 203,
                searchSeeds: seeds
            )
        )
    }

    func testYouTubeSearchSeedTrackerDropsPreviousTrackMediaDuringTransition() {
        let old = LyricsSearchSeed(title: "負けないで", artist: "ZARD")
        let dom = LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU")
        let media = LyricsSearchSeed(title: "Natsuiro", artist: "YUZU")
        var tracker = YouTubeMusicSearchSeedTracker()

        XCTAssertEqual(
            tracker.update(trackID: "old", candidates: [old], domPrimary: old),
            [old]
        )
        XCTAssertEqual(
            tracker.update(
                trackID: "new",
                candidates: [dom, old],
                domPrimary: dom
            ),
            [dom]
        )
        XCTAssertEqual(
            tracker.update(
                trackID: "new",
                candidates: [dom, media],
                domPrimary: dom
            ),
            [dom, media]
        )
    }

    func testYouTubeSearchSeedTrackerKeepsTwoNewBilingualAliases() {
        let old = LyricsSearchSeed(title: "Old Song", artist: "Old Artist")
        let dom = LyricsSearchSeed(title: "アイドル", artist: "夜遊び")
        let media = LyricsSearchSeed(title: "Idol", artist: "YOASOBI")
        var tracker = YouTubeMusicSearchSeedTracker()
        _ = tracker.update(trackID: "old", candidates: [old], domPrimary: old)

        XCTAssertEqual(
            tracker.update(
                trackID: "new",
                candidates: [dom, media],
                domPrimary: dom
            ),
            [dom, media]
        )
    }

    func testYouTubeSearchSeedTrackerWaitsWhenOnlyOldMediaIsAvailable() {
        let old = LyricsSearchSeed(title: "Automatic", artist: "Hikaru Utada")
        let new = LyricsSearchSeed(title: "Natsuiro", artist: "YUZU")
        var tracker = YouTubeMusicSearchSeedTracker()
        _ = tracker.update(trackID: "old", candidates: [old], domPrimary: old)

        XCTAssertEqual(
            tracker.update(trackID: "new", candidates: [old], domPrimary: nil),
            []
        )
        XCTAssertEqual(
            tracker.update(trackID: "new", candidates: [new], domPrimary: nil),
            [new]
        )
    }

    func testYouTubeSearchSeedTrackerBlocksOlderAliasAcrossRapidTrackChanges() {
        let first = LyricsSearchSeed(title: "Song A", artist: "Artist A")
        let second = LyricsSearchSeed(title: "Song B", artist: "Artist B")
        let third = LyricsSearchSeed(title: "Song C", artist: "Artist C")
        var tracker = YouTubeMusicSearchSeedTracker()

        _ = tracker.update(trackID: "a", candidates: [first], domPrimary: first)
        XCTAssertEqual(
            tracker.update(
                trackID: "b",
                candidates: [second, first],
                domPrimary: second
            ),
            [second]
        )
        XCTAssertEqual(
            tracker.update(
                trackID: "c",
                candidates: [third, first],
                domPrimary: third
            ),
            [third]
        )
    }

    func testYouTubeSearchSeedTrackerReplacesStaleDOMOnNewTrack() {
        let first = LyricsSearchSeed(title: "Song A", artist: "Artist A")
        let second = LyricsSearchSeed(title: "Song B", artist: "Artist B")
        var tracker = YouTubeMusicSearchSeedTracker()

        _ = tracker.update(trackID: "a", candidates: [first], domPrimary: first)
        XCTAssertEqual(
            tracker.update(trackID: "b", candidates: [first], domPrimary: first),
            []
        )
        XCTAssertEqual(
            tracker.update(trackID: "b", candidates: [second], domPrimary: second),
            [second]
        )
    }

    func testYouTubeSearchSeedTrackerConfirmsRepeatedDOMOnNewVideo() {
        let repeated = LyricsSearchSeed(title: "Same Song", artist: "Artist")
        var tracker = YouTubeMusicSearchSeedTracker()

        _ = tracker.update(
            trackID: "first-video",
            candidates: [repeated],
            domPrimary: repeated
        )
        XCTAssertEqual(
            tracker.update(
                trackID: "second-video",
                candidates: [repeated],
                domPrimary: repeated
            ),
            []
        )
        XCTAssertEqual(
            tracker.update(
                trackID: "second-video",
                candidates: [repeated],
                domPrimary: repeated
            ),
            []
        )
        XCTAssertEqual(
            tracker.update(
                trackID: "second-video",
                candidates: [repeated],
                domPrimary: repeated
            ),
            [repeated]
        )
    }

    func testSearchSelectionUsesQualityWithinSameConfidenceTier() {
        XCTAssertTrue(
            LyricsSearchResultSelectionPolicy.shouldReplace(
                currentQuality: 0.7,
                currentIsConfident: true,
                incomingQuality: 0.8,
                incomingIsConfident: true
            )
        )
        XCTAssertFalse(
            LyricsSearchResultSelectionPolicy.shouldReplace(
                currentQuality: 0.8,
                currentIsConfident: true,
                incomingQuality: 0.8,
                incomingIsConfident: true
            )
        )
        XCTAssertFalse(
            LyricsSearchResultSelectionPolicy.shouldReplace(
                currentQuality: nil,
                currentIsConfident: false,
                incomingQuality: .nan,
                incomingIsConfident: true
            )
        )
    }

    func testSearchResultMatchRejectsSameTitleWithWrongDuration() {
        let match = LyricsSearchResultMatchPolicy.evaluate(
            resultTitle: "Natsuiro",
            resultArtist: "Mic Musicbox",
            resultDuration: 193,
            trackDuration: 203,
            searchSeeds: [
                LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU"),
                LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
            ]
        )

        XCTAssertEqual(
            match,
            LyricsSearchResultMatch(isPlausible: false, isConfident: false)
        )
    }

    func testSearchResultMatchUsesDurationForTransliteratedArtist() {
        let match = LyricsSearchResultMatchPolicy.evaluate(
            resultTitle: "夏色",
            resultArtist: "柚子 (ゆず)",
            resultDuration: 201,
            trackDuration: 203,
            searchSeeds: [
                LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU"),
                LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
            ]
        )

        XCTAssertEqual(
            match,
            LyricsSearchResultMatch(isPlausible: true, isConfident: true)
        )
    }

    func testSearchResultMatchRejectsUnrelatedTitleEvenAtMatchingDuration() {
        let match = LyricsSearchResultMatchPolicy.evaluate(
            resultTitle: "負けないで",
            resultArtist: "ZARD",
            resultDuration: 203,
            trackDuration: 203,
            searchSeeds: [
                LyricsSearchSeed(title: "夏色 - Natsuiro", artist: "YUZU"),
            ]
        )

        XCTAssertEqual(
            match,
            LyricsSearchResultMatch(isPlausible: false, isConfident: false)
        )
    }

    func testSearchResultMatchRejectsWrongArtistWithoutDurationEvidence() {
        let match = LyricsSearchResultMatchPolicy.evaluate(
            resultTitle: "Natsuiro no Fuku",
            resultArtist: "Taeko Onuki",
            resultDuration: nil,
            trackDuration: 203,
            searchSeeds: [
                LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
            ]
        )

        XCTAssertEqual(
            match,
            LyricsSearchResultMatch(isPlausible: false, isConfident: false)
        )
    }

    func testSearchResultMatchAcceptsArtistMatchWithoutDuration() {
        let match = LyricsSearchResultMatchPolicy.evaluate(
            resultTitle: "Natsuiro",
            resultArtist: "YUZU",
            resultDuration: nil,
            trackDuration: 203,
            searchSeeds: [
                LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
            ]
        )

        XCTAssertEqual(
            match,
            LyricsSearchResultMatch(isPlausible: true, isConfident: true)
        )
    }

    func testSearchResultMatchRejectsSameScriptCoverAtMatchingDuration() {
        let seeds = [
            LyricsSearchSeed(title: "Hello", artist: "Adele"),
            LyricsSearchSeed(title: "Natsuiro", artist: "YUZU"),
        ]

        for (title, artist) in [
            ("Hello", "Lionel Richie"),
            ("Natsuiro", "Mic Musicbox"),
        ] {
            XCTAssertEqual(
                LyricsSearchResultMatchPolicy.evaluate(
                    resultTitle: title,
                    resultArtist: artist,
                    resultDuration: 203,
                    trackDuration: 203,
                    searchSeeds: seeds
                ),
                LyricsSearchResultMatch(isPlausible: false, isConfident: false)
            )
        }
    }

    func testSearchResultMatchKeepsCrossScriptArtistPlausibleWithoutDuration() {
        let match = LyricsSearchResultMatchPolicy.evaluate(
            resultTitle: "夏色",
            resultArtist: "柚子 (ゆず)",
            resultDuration: nil,
            trackDuration: 203,
            searchSeeds: [
                LyricsSearchSeed(title: "夏色", artist: "YUZU"),
            ]
        )

        XCTAssertEqual(
            match,
            LyricsSearchResultMatch(isPlausible: true, isConfident: false)
        )
    }

    func testSearchResultMatchDurationToleranceBoundary() {
        let seeds = [
            LyricsSearchSeed(title: "Song", artist: nil),
        ]

        XCTAssertTrue(
            LyricsSearchResultMatchPolicy.evaluate(
                resultTitle: "Song",
                resultArtist: nil,
                resultDuration: 192,
                trackDuration: 200,
                searchSeeds: seeds
            ).isConfident
        )
        XCTAssertFalse(
            LyricsSearchResultMatchPolicy.evaluate(
                resultTitle: "Song",
                resultArtist: nil,
                resultDuration: 191.99,
                trackDuration: 200,
                searchSeeds: seeds
            ).isPlausible
        )
    }

    func testYouTubeSearchSeedsIgnoreTemporaryAliasLoss() {
        let dom = LyricsSearchSeed(title: "アイドル", artist: "YOASOBI")
        let media = LyricsSearchSeed(title: "Idol", artist: "Yoasobi")

        XCTAssertEqual(
            YouTubeMusicSearchSeedPolicy.merged(
                existing: [dom, media],
                incoming: [dom]
            ),
            [dom, media]
        )
        XCTAssertEqual(
            YouTubeMusicSearchSeedPolicy.merged(
                existing: [dom, media],
                incoming: [media]
            ),
            [dom, media]
        )
    }

    func testYouTubeSearchSeedsPublishNewAliasesOnce() {
        let dom = LyricsSearchSeed(title: "アイドル", artist: "YOASOBI")
        let media = LyricsSearchSeed(title: "Idol", artist: "Yoasobi")

        let expanded = YouTubeMusicSearchSeedPolicy.merged(
            existing: [dom],
            incoming: [dom, media]
        )
        XCTAssertEqual(expanded, [dom, media])
        XCTAssertEqual(
            YouTubeMusicSearchSeedPolicy.merged(
                existing: expanded,
                incoming: [dom, media]
            ),
            expanded
        )
    }

    func testTimelineRefreshUsesBoundaryOrOneSecondWatchdog() {
        XCTAssertEqual(
            LyricsTimelineRefreshPolicy.nextDelay(
                isPlaying: true,
                playbackTime: 10,
                nextLineTime: 10.01
            ),
            LyricsTimelineRefreshPolicy.minimumDelay
        )
        XCTAssertEqual(
            LyricsTimelineRefreshPolicy.nextDelay(
                isPlaying: true,
                playbackTime: 10,
                nextLineTime: 30
            ),
            LyricsTimelineRefreshPolicy.watchdogInterval
        )
        XCTAssertNil(
            LyricsTimelineRefreshPolicy.nextDelay(
                isPlaying: false,
                playbackTime: 10,
                nextLineTime: 11
            )
        )
    }

    func testMediaSelectionSkipsStalePausedElementBeforeActiveElement() {
        let candidates = [
            mediaCandidate(isPaused: true, playbackTime: 0),
            mediaCandidate(isPaused: false, playbackTime: 42),
        ]

        XCTAssertEqual(YouTubeMusicMediaSelector.selectedIndex(from: candidates), 1)
    }

    func testMediaSelectionRanksTwoPlayingElementsByMainPlayer() {
        let candidates = [
            mediaCandidate(isPaused: false, readyState: 4, playbackTime: 200),
            mediaCandidate(
                isPaused: false,
                isMainPlayer: true,
                readyState: 2,
                playbackTime: 10
            ),
        ]

        XCTAssertEqual(YouTubeMusicMediaSelector.selectedIndex(from: candidates), 1)
    }

    func testMediaSelectionPrefersMainPlayerWhenEverythingIsPaused() {
        let candidates = [
            mediaCandidate(isPaused: true, readyState: 4, playbackTime: 90),
            mediaCandidate(
                isPaused: true,
                isMainPlayer: true,
                readyState: 2,
                playbackTime: 10
            ),
        ]

        XCTAssertEqual(YouTubeMusicMediaSelector.selectedIndex(from: candidates), 1)
    }

    func testMediaSelectionRequiresLoadedSource() {
        let candidates = [
            mediaCandidate(hasCurrentSource: false, isPaused: false, playbackTime: 15),
            mediaCandidate(isPaused: true, playbackTime: 5),
        ]

        XCTAssertEqual(YouTubeMusicMediaSelector.selectedIndex(from: candidates), 1)
    }

    func testTrackProgressWinsOverPlaylistWideMediaTimeline() {
        let timing = YouTubeMusicPlaybackTimingPolicy.resolve(
            progressTime: 227,
            progressDuration: 357,
            mediaTime: 2_442.8,
            mediaDuration: 2_562.1
        )

        XCTAssertEqual(timing.playbackTime, 227, accuracy: 0.000_001)
        XCTAssertEqual(timing.duration, 357)
        XCTAssertEqual(timing.precision, 1)
    }

    func testTrackProgressKeepsPreciseMediaClockWhenDurationsMatch() {
        let timing = YouTubeMusicPlaybackTimingPolicy.resolve(
            progressTime: 196,
            progressDuration: 271,
            mediaTime: 196.056,
            mediaDuration: 270.093
        )

        XCTAssertEqual(timing.playbackTime, 196.056, accuracy: 0.000_001)
        XCTAssertEqual(timing.duration, 271)
        XCTAssertNil(timing.precision)
    }

    func testTrackDurationDoesNotClampMediaTimeWithoutTrackProgress() {
        let timing = YouTubeMusicPlaybackTimingPolicy.resolve(
            progressTime: nil,
            progressDuration: 357,
            mediaTime: 2_442.8,
            mediaDuration: 2_562.1
        )

        XCTAssertEqual(timing.playbackTime, 2_442.8, accuracy: 0.000_001)
        XCTAssertEqual(timing.duration, 2_562.1)
        XCTAssertNil(timing.precision)
    }

    func testMediaTimingRemainsFallbackWithoutTrackProgress() {
        let timing = YouTubeMusicPlaybackTimingPolicy.resolve(
            progressTime: nil,
            progressDuration: nil,
            mediaTime: 42,
            mediaDuration: 180
        )

        XCTAssertEqual(
            timing,
            YouTubeMusicPlaybackTiming(playbackTime: 42, duration: 180)
        )
    }

    func testPlaybackTimingRejectsNonfiniteAndClampsToDuration() {
        let timing = YouTubeMusicPlaybackTimingPolicy.resolve(
            progressTime: 200,
            progressDuration: 180,
            mediaTime: .nan,
            mediaDuration: .infinity
        )

        XCTAssertEqual(
            timing,
            YouTubeMusicPlaybackTiming(
                playbackTime: 180,
                duration: 180,
                precision: 1
            )
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
        XCTAssertNil(snapshot.playbackTimePrecision)
        XCTAssertNil(snapshot.searchSeeds)
        XCTAssertTrue(snapshot.isPlaying)
    }

    func testYouTubeMusicSnapshotDecodesPairedSearchSeeds() throws {
        let payload = #"""
        {
          "url": "https://music.youtube.com/watch?v=abc123",
          "videoID": "abc123",
          "title": "アイドル",
          "artist": "YOASOBI",
          "domTitle": "アイドル",
          "domArtist": "夜遊び",
          "album": null,
          "duration": 213,
          "playbackTime": 12,
          "isPlaying": true,
          "artworkURL": null,
          "searchSeeds": [
            {"title": "アイドル", "artist": "YOASOBI"},
            {"title": "Idol", "artist": "Yoasobi"}
          ]
        }
        """#.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(YouTubeMusicSnapshot.self, from: payload)

        XCTAssertEqual(snapshot.title, "アイドル")
        XCTAssertEqual(snapshot.domTitle, "アイドル")
        XCTAssertEqual(snapshot.domArtist, "夜遊び")
        XCTAssertEqual(snapshot.searchSeeds, [
            LyricsSearchSeed(title: "アイドル", artist: "YOASOBI"),
            LyricsSearchSeed(title: "Idol", artist: "Yoasobi"),
        ])
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

    func testDiscreteTrackClockAvoidsSubsecondBackwardCorrections() {
        XCTAssertFalse(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: true,
                currentTime: 100.9,
                snapshotTime: 100,
                timeSinceLastPlayingSynchronization: 5,
                snapshotPrecision: 1
            )
        )
        XCTAssertTrue(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: true,
                currentTime: 101.2,
                snapshotTime: 100,
                timeSinceLastPlayingSynchronization: 5,
                snapshotPrecision: 1
            )
        )
        XCTAssertTrue(
            YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                isPlaying: true,
                currentTime: 100.2,
                snapshotTime: 100,
                timeSinceLastPlayingSynchronization: 30,
                snapshotPrecision: 1
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

    private func mediaCandidate(
        hasCurrentSource: Bool = true,
        isPaused: Bool,
        isEnded: Bool = false,
        isMainPlayer: Bool = false,
        readyState: Int = 4,
        playbackTime: TimeInterval
    ) -> YouTubeMusicMediaCandidate {
        YouTubeMusicMediaCandidate(
            hasCurrentSource: hasCurrentSource,
            isPaused: isPaused,
            isEnded: isEnded,
            isMainPlayer: isMainPlayer,
            readyState: readyState,
            playbackTime: playbackTime
        )
    }
}
