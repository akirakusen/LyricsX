//
//  YouTubeMusicPlayer.swift
//  LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXShim
import MusicPlayer

enum YouTubeMusicSetupIssue: String {
    case automationDenied
    case chromeJavaScriptDisabled
}

extension Notification.Name {
    static let youTubeMusicSetupRequired = Notification.Name(
        "com.akirakusen.LyricsX.YouTubeMusicSetupRequired"
    )
    static let youTubeMusicSetupResolved = Notification.Name(
        "com.akirakusen.LyricsX.YouTubeMusicSetupResolved"
    )
}

final class YouTubeMusicSearchContext: NSObject {
    let searchSeeds: [LyricsSearchSeed]

    init(searchSeeds: [LyricsSearchSeed]) {
        self.searchSeeds = searchSeeds
        super.init()
    }
}

extension MusicPlayers {
    final class YouTubeMusic: ObservableObject {
        let objectWillChange = ObservableObjectPublisher()

        private let stateLock = NSLock()
        private var storedCurrentTrack: MusicTrack?
        private var storedPlaybackState: PlaybackState = .stopped
        private let currentTrackSubject = CurrentValueSubject<MusicTrack?, Never>(nil)
        private let playbackStateSubject = CurrentValueSubject<PlaybackState, Never>(.stopped)

        var currentTrack: MusicTrack? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedCurrentTrack
        }

        var playbackState: PlaybackState {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedPlaybackState
        }

        private let bridge = ChromeYouTubeMusicBridge()
        private let updateQueue = DispatchQueue(label: "com.akirakusen.LyricsX.YouTubeMusic")
        private let refreshLock = NSLock()
        private let artworkCache: NSCache<NSURL, NSImage> = {
            let cache = NSCache<NSURL, NSImage>()
            cache.countLimit = 32
            return cache
        }()
        private let artworkSession: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            return URLSession(configuration: configuration)
        }()
        private var activeTabID: String?
        private var lastSetupIssue: YouTubeMusicSetupIssue?
        private var lastPlayingSynchronizationDate: Date?
        private var artworkTask: URLSessionDataTask?
        private var artworkRequestKey: String?
        private var artworkRetryAfter: [URL: Date] = [:]
        private var observationPolicy = YouTubeMusicObservationPolicy()
        private var searchSeedTracker = YouTubeMusicSearchSeedTracker()
        private var refreshScheduledOrRunning = false
        private var refreshRequestedWhileBusy = false

        private func refresh() {
            do {
                _ = try readAndApplySnapshot()
            } catch ChromeYouTubeMusicBridge.BridgeError.automationDenied {
                handleSetupIssue(.automationDenied)
            } catch ChromeYouTubeMusicBridge.BridgeError.javascriptDisabled {
                handleSetupIssue(.chromeJavaScriptDisabled)
            } catch {
                log("YouTube Music update failed: \(error.localizedDescription)")
            }
        }

        @discardableResult
        private func readAndApplySnapshot() throws -> Bool {
            let result: ChromeYouTubeMusicBridge.SnapshotResult?
            do {
                result = try bridge.readSnapshot(previouslyActiveTabID: activeTabID)
            } catch ChromeYouTubeMusicBridge.BridgeError.automationDenied {
                throw ChromeYouTubeMusicBridge.BridgeError.automationDenied
            } catch ChromeYouTubeMusicBridge.BridgeError.javascriptDisabled {
                throw ChromeYouTubeMusicBridge.BridgeError.javascriptDisabled
            } catch {
                if observationPolicy.register(.transientFailure) == .clearState {
                    clearPlayerState()
                }
                throw error
            }

            guard let result else {
                _ = observationPolicy.register(.sourceUnavailable)
                clearPlayerState()
                return false
            }

            _ = observationPolicy.register(.validSnapshot)
            activeTabID = result.tabID
            let resolvedSetupIssue = lastSetupIssue != nil
            lastSetupIssue = nil
            if resolvedSetupIssue {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .youTubeMusicSetupResolved, object: nil)
                }
            }
            apply(result.snapshot)
            return true
        }

        private func apply(_ snapshot: YouTubeMusicSnapshot) {
            let currentState = publicStateSnapshot()
            let artworkURL = snapshot.artworkURL.flatMap(URL.init(string:))
            let cachedArtwork = artworkURL.flatMap {
                artworkCache.object(forKey: $0 as NSURL)
            }
            let existingArtwork = currentState.track?.id == snapshot.trackID
                ? currentState.track?.artwork
                : nil
            let existingTrack = currentState.track?.id == snapshot.trackID
                ? currentState.track
                : nil
            let rawSearchSeeds = snapshot.searchSeeds.flatMap { seeds in
                seeds.isEmpty ? nil : seeds
            } ?? [
                LyricsSearchSeed(title: snapshot.title, artist: snapshot.artist),
            ]
            let domPrimary = snapshot.domTitle.map {
                LyricsSearchSeed(title: $0, artist: snapshot.domArtist)
            }
            let searchSeeds = searchSeedTracker.update(
                trackID: snapshot.trackID,
                candidates: rawSearchSeeds,
                domPrimary: domPrimary
            )
            let primarySeed = searchSeeds.first
            let metadataIsReady = primarySeed != nil
            let track = MusicTrack(
                id: snapshot.trackID,
                title: primarySeed?.title,
                album: metadataIsReady ? snapshot.album ?? existingTrack?.album : nil,
                artist: primarySeed?.artist,
                duration: snapshot.duration ?? existingTrack?.duration,
                artwork: metadataIsReady ? cachedArtwork ?? existingArtwork : nil,
                originalTrack: YouTubeMusicSearchContext(searchSeeds: searchSeeds)
            )
            let trackChanged = tracksDiffer(currentState.track, track)
            if trackChanged {
                lastPlayingSynchronizationDate = nil
            }

            let playbackTime = snapshot.clampedPlaybackTime
            let newState: PlaybackState = snapshot.isPlaying
                ? .playing(time: playbackTime)
                : .paused(time: playbackTime)
            let now = Date()
            let shouldUpdateState: Bool
            switch (currentState.playbackState, newState) {
            case (.playing, .playing) where !trackChanged:
                shouldUpdateState = YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                    isPlaying: true,
                    currentTime: currentState.playbackState.time,
                    snapshotTime: playbackTime,
                    timeSinceLastPlayingSynchronization: lastPlayingSynchronizationDate.map {
                        now.timeIntervalSince($0)
                    },
                    snapshotPrecision: snapshot.playbackTimePrecision
                )
            case (.paused, .paused) where !trackChanged:
                shouldUpdateState = YouTubeMusicPlaybackUpdatePolicy.shouldUpdatePosition(
                    isPlaying: false,
                    currentTime: currentState.playbackState.time,
                    snapshotTime: playbackTime,
                    timeSinceLastPlayingSynchronization: nil
                )
            default:
                shouldUpdateState = true
            }

            let playbackState = shouldUpdateState ? newState : currentState.playbackState
            publishPublicState(
                track: trackChanged ? track : currentState.track,
                playbackState: playbackState
            )
            if shouldUpdateState {
                lastPlayingSynchronizationDate = snapshot.isPlaying ? now : nil
            } else if !snapshot.isPlaying {
                lastPlayingSynchronizationDate = nil
            }
            if metadataIsReady {
                requestArtwork(for: snapshot.trackID, at: artworkURL)
            } else {
                cancelArtworkRequest()
            }
        }

        private func publicStateSnapshot() -> (track: MusicTrack?, playbackState: PlaybackState) {
            stateLock.lock()
            defer { stateLock.unlock() }
            return (storedCurrentTrack, storedPlaybackState)
        }

        private func publishPublicState(track: MusicTrack?, playbackState: PlaybackState) {
            stateLock.lock()
            let trackChanged = tracksDiffer(storedCurrentTrack, track)
            let playbackStateChanged = storedPlaybackState != playbackState
            storedCurrentTrack = track
            storedPlaybackState = playbackState
            stateLock.unlock()

            guard trackChanged || playbackStateChanged else { return }
            objectWillChange.send()
            if trackChanged {
                currentTrackSubject.send(track)
            }
            if playbackStateChanged {
                playbackStateSubject.send(playbackState)
            }
        }

        private func tracksDiffer(_ lhs: MusicTrack?, _ rhs: MusicTrack?) -> Bool {
            YouTubeMusicTrackUpdatePolicy.shouldPublishTrackChange(
                current: trackDescriptor(for: lhs),
                incoming: trackDescriptor(for: rhs)
            )
        }

        private func trackDescriptor(for track: MusicTrack?) -> YouTubeMusicTrackDescriptor? {
            track.map {
                YouTubeMusicTrackDescriptor(
                    id: $0.id,
                    title: $0.title,
                    album: $0.album,
                    artist: $0.artist,
                    duration: $0.duration,
                    searchSeeds: ($0.originalTrack as? YouTubeMusicSearchContext)?
                        .searchSeeds ?? []
                )
            }
        }

        private func requestArtwork(for trackID: String, at url: URL?) {
            guard let url else {
                cancelArtworkRequest()
                return
            }
            if artworkCache.object(forKey: url as NSURL) != nil {
                cancelArtworkRequest()
                return
            }
            if let retryAfter = artworkRetryAfter[url], retryAfter > Date() {
                return
            }

            let requestKey = "\(trackID)\u{1F}\(url.absoluteString)"
            guard artworkRequestKey != requestKey else { return }
            cancelArtworkRequest()
            artworkRequestKey = requestKey

            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("LyricsX/1.7.1", forHTTPHeaderField: "User-Agent")
            let task = artworkSession.dataTask(with: request) { [weak self] data, response, error in
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let image = error == nil && statusCode.map({ 200 ..< 300 ~= $0 }) == true
                    ? data.flatMap(NSImage.init(data:))
                    : nil
                self?.updateQueue.async { [weak self] in
                    self?.completeArtworkRequest(
                        requestKey: requestKey,
                        trackID: trackID,
                        url: url,
                        image: image
                    )
                }
            }
            artworkTask = task
            task.resume()
        }

        private func completeArtworkRequest(
            requestKey: String,
            trackID: String,
            url: URL,
            image: NSImage?
        ) {
            guard artworkRequestKey == requestKey else { return }
            artworkTask = nil
            artworkRequestKey = nil

            guard let image else {
                artworkRetryAfter[url] = Date().addingTimeInterval(30)
                return
            }
            artworkRetryAfter[url] = nil
            artworkCache.setObject(image, forKey: url as NSURL)
            publishArtwork(image, forTrackID: trackID)
        }

        private func publishArtwork(_ image: NSImage, forTrackID trackID: String) {
            stateLock.lock()
            guard var track = storedCurrentTrack,
                  YouTubeMusicTrackUpdatePolicy.shouldApplyArtwork(
                      downloadedTrackID: trackID,
                      currentTrackID: track.id
                  ) else {
                stateLock.unlock()
                return
            }
            track.artwork = image
            storedCurrentTrack = track
            stateLock.unlock()

            // Artwork is a presentation-only refinement of the same track.
            // AppController observes currentTrackSubject as a lyric-search event.
            objectWillChange.send()
        }

        private func cancelArtworkRequest() {
            artworkTask?.cancel()
            artworkTask = nil
            artworkRequestKey = nil
        }

        private func clearPlayerState() {
            activeTabID = nil
            lastPlayingSynchronizationDate = nil
            searchSeedTracker.reset()
            cancelArtworkRequest()
            publishPublicState(track: nil, playbackState: .stopped)
        }

        private func handleSetupIssue(_ issue: YouTubeMusicSetupIssue) {
            _ = observationPolicy.register(.sourceUnavailable)
            clearPlayerState()
            guard issue != lastSetupIssue else { return }
            lastSetupIssue = issue
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .youTubeMusicSetupRequired,
                    object: issue
                )
            }
        }

        private func perform(_ command: ChromeYouTubeMusicBridge.Command) {
            updateQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.performCommand(command)
                } catch ChromeYouTubeMusicBridge.BridgeError.automationDenied {
                    self.handleSetupIssue(.automationDenied)
                } catch ChromeYouTubeMusicBridge.BridgeError.javascriptDisabled {
                    self.handleSetupIssue(.chromeJavaScriptDisabled)
                } catch {
                    log("YouTube Music command failed: \(error.localizedDescription)")
                }
            }
        }

        private func performCommand(_ command: ChromeYouTubeMusicBridge.Command) throws {
            for attempt in 0 ... 1 {
                if activeTabID == nil {
                    guard try readAndApplySnapshot() else { return }
                }
                guard let tabID = activeTabID else { return }

                do {
                    try bridge.execute(command, onTabID: tabID)
                    if case .seek = command {
                        lastPlayingSynchronizationDate = nil
                    }
                    refresh()
                    return
                } catch ChromeYouTubeMusicBridge.BridgeError.automationDenied {
                    throw ChromeYouTubeMusicBridge.BridgeError.automationDenied
                } catch ChromeYouTubeMusicBridge.BridgeError.javascriptDisabled {
                    throw ChromeYouTubeMusicBridge.BridgeError.javascriptDisabled
                } catch let error as ChromeYouTubeMusicBridge.BridgeError {
                    let failureWasDefinitelyBeforeExecution: Bool
                    if case .commandRejected = error {
                        failureWasDefinitelyBeforeExecution = true
                    } else {
                        failureWasDefinitelyBeforeExecution = false
                    }
                    guard attempt == 0,
                          YouTubeMusicCommandRetryPolicy.shouldRetry(
                              isIdempotent: command.isIdempotent,
                              failureWasDefinitelyBeforeExecution: failureWasDefinitelyBeforeExecution
                          ) else {
                        throw error
                    }
                    // Refresh the candidate list before the single retry. This
                    // replaces a closed/stale tab ID and rechecks player DOM.
                    guard try readAndApplySnapshot() else { return }
                } catch {
                    throw error
                }
            }
        }

        private func requestCoalescedRefresh() {
            refreshLock.lock()
            if refreshScheduledOrRunning {
                refreshRequestedWhileBusy = true
                refreshLock.unlock()
                return
            }
            refreshScheduledOrRunning = true
            refreshLock.unlock()
            enqueueRefresh()
        }

        private func enqueueRefresh() {
            updateQueue.async { [weak self] in
                guard let self else { return }
                self.refresh()

                self.refreshLock.lock()
                let shouldRefreshAgain = self.refreshRequestedWhileBusy
                self.refreshRequestedWhileBusy = false
                if !shouldRefreshAgain {
                    self.refreshScheduledOrRunning = false
                }
                self.refreshLock.unlock()

                if shouldRefreshAgain {
                    // Requeue at the tail so playback commands are not starved.
                    self.enqueueRefresh()
                }
            }
        }
    }
}

extension MusicPlayers.YouTubeMusic: MusicPlayerProtocol {
    var name: MusicPlayerName? { nil }

    var currentTrackWillChange: AnyPublisher<MusicTrack?, Never> {
        currentTrackSubject.eraseToAnyPublisher()
    }

    var playbackStateWillChange: AnyPublisher<PlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    var playbackTime: TimeInterval {
        get { playbackState.time }
        set { perform(.seek(newValue)) }
    }

    func resume() {
        perform(.resume)
    }

    func pause() {
        perform(.pause)
    }

    func playPause() {
        perform(.playPause)
    }

    func skipToNextItem() {
        perform(.next)
    }

    func skipToPreviousItem() {
        perform(.previous)
    }

    func updatePlayerState() {
        requestCoalescedRefresh()
    }
}

private final class ChromeYouTubeMusicBridge {
    private static let snapshotResponseMarker = "LyricsXYouTubeMusicSnapshotV1"
    private static let mediaSelectionJavaScript = #"""
    const mediaElements = Array.from(document.querySelectorAll('video, audio'));
    const loadedMedia = mediaElements.filter(candidate => Boolean(candidate.currentSrc));
    const isMainPlayerMedia = candidate =>
      Boolean(candidate.closest('ytmusic-player, #movie_player'));
    const rankMedia = candidate => [
      candidate.ended ? 0 : 1,
      isMainPlayerMedia(candidate) ? 1 : 0,
      Number.isFinite(candidate.readyState) ? Math.max(0, candidate.readyState) : 0,
      Number.isFinite(candidate.currentTime) && candidate.currentTime > 0 ? 1 : 0
    ];
    const isHigherRanked = (candidate, current) => {
      const candidateRank = rankMedia(candidate);
      const currentRank = rankMedia(current);
      for (let index = 0; index < candidateRank.length; index += 1) {
        if (candidateRank[index] !== currentRank[index]) {
          return candidateRank[index] > currentRank[index];
        }
      }
      return false;
    };
    const playingMedia = loadedMedia.filter(
      candidate => !candidate.paused && !candidate.ended
    );
    const eligibleMedia = playingMedia.length ? playingMedia : loadedMedia;
    const media = eligibleMedia.reduce(
        (current, candidate) =>
          !current || isHigherRanked(candidate, current) ? candidate : current,
        null
      );
    """#
    private static let trackTimingJavaScript = #"""
    const parseClock = value => {
      if (typeof value !== 'string') return null;
      const trimmedValue = value.trim();
      if (!trimmedValue) return null;
      const rawFields = trimmedValue.split(':');
      if (rawFields.some(field => !field.trim())) return null;
      const fields = rawFields.map(Number);
      if (fields.some(field => !Number.isFinite(field) || field < 0)) {
        return null;
      }
      return fields.reduce((total, field) => total * 60 + field, 0);
    };
    const numericAttribute = (element, name, positive) => {
      const rawValue = element?.getAttribute(name);
      if (rawValue === null || rawValue === undefined || rawValue === '') return null;
      const value = Number(rawValue);
      if (!Number.isFinite(value) || (positive ? value <= 0 : value < 0)) return null;
      return value;
    };
    const progressBar = document.querySelector('ytmusic-player-bar #progress-bar');
    const progressTime = numericAttribute(progressBar, 'aria-valuenow', false);
    const progressDuration = numericAttribute(progressBar, 'aria-valuemax', true);
    const timeParts = (
      document.querySelector('ytmusic-player-bar .time-info')?.textContent || ''
    ).split('/');
    const textTime = parseClock(timeParts[0]);
    const textDuration = parseClock(timeParts[1]);
    const mediaTime = Number.isFinite(media.currentTime) ? Math.max(0, media.currentTime) : 0;
    const mediaDuration =
      Number.isFinite(media.duration) && media.duration > 0 ? media.duration : null;
    const discreteTrackTime = progressTime ?? textTime;
    const discreteTrackDuration = progressTime !== null
      ? progressDuration ?? textDuration
      : textTime !== null
        ? textDuration ?? progressDuration
        : null;
    const mediaMatchesTrack = discreteTrackTime !== null
      && discreteTrackDuration !== null
      && mediaDuration !== null
      && Math.abs(mediaDuration - discreteTrackDuration) <= 2
      && mediaTime <= discreteTrackDuration + 2;
    const rawTrackTime = mediaMatchesTrack || discreteTrackTime === null
      ? mediaTime
      : discreteTrackTime;
    const trackDuration = discreteTrackTime === null
      ? mediaDuration
      : discreteTrackDuration;
    const trackPlaybackTime =
      trackDuration === null ? rawTrackTime : Math.min(rawTrackTime, trackDuration);
    const playbackTimePrecision =
      discreteTrackTime === null || mediaMatchesTrack ? null : 1;
    """#

    struct SnapshotResult {
        let tabID: String
        let snapshot: YouTubeMusicSnapshot
    }

    enum Command {
        case resume
        case pause
        case playPause
        case next
        case previous
        case seek(TimeInterval)

        var isIdempotent: Bool {
            switch self {
            case .resume, .pause, .seek:
                return true
            case .playPause, .next, .previous:
                return false
            }
        }

        var javaScript: String {
            switch self {
            case .resume:
                return Self.mediaCommand("media.play()")
            case .pause:
                return Self.mediaCommand("media.pause()")
            case .playPause:
                return #"""
                (() => {
                  if (location.origin !== 'https://music.youtube.com') return '';
                  \#(ChromeYouTubeMusicBridge.mediaSelectionJavaScript)
                  if (!media) return '';
                  const button = document.querySelector('ytmusic-player-bar #play-pause-button');
                  if (button) button.click();
                  else if (media.paused) media.play();
                  else media.pause();
                  return 'ok';
                })()
                """#
            case .next:
                return Self.buttonCommand("next-button")
            case .previous:
                return Self.buttonCommand("previous-button")
            case let .seek(time):
                let safeTime = time.isFinite ? max(0, time) : 0
                return #"""
                (() => {
                  if (location.origin !== 'https://music.youtube.com') return '';
                  \#(ChromeYouTubeMusicBridge.mediaSelectionJavaScript)
                  if (!media) return '';
                  \#(ChromeYouTubeMusicBridge.trackTimingJavaScript)
                  const target = trackDuration === null
                    ? \#(safeTime)
                    : Math.min(\#(safeTime), trackDuration);
                  if (progressBar && trackDuration !== null) {
                    const previousValueAttribute = progressBar.getAttribute('value');
                    const previousAriaValue = progressBar.getAttribute('aria-valuenow');
                    const hadOwnValue = Object.prototype.hasOwnProperty.call(
                      progressBar,
                      'value'
                    );
                    const previousValue = progressBar.value;
                    progressBar.value = target;
                    progressBar.setAttribute('value', String(target));
                    progressBar.setAttribute('aria-valuenow', String(target));
                    progressBar.dispatchEvent(
                      new Event('change', { bubbles: true, composed: true })
                    );
                    if (hadOwnValue) progressBar.value = previousValue;
                    else delete progressBar.value;
                    if (previousValueAttribute === null) {
                      progressBar.removeAttribute('value');
                    } else {
                      progressBar.setAttribute('value', previousValueAttribute);
                    }
                    if (previousAriaValue === null) {
                      progressBar.removeAttribute('aria-valuenow');
                    } else {
                      progressBar.setAttribute('aria-valuenow', previousAriaValue);
                    }
                    return 'ok';
                  }
                  const shiftedMediaTime = Math.max(
                    0,
                    mediaTime + target - trackPlaybackTime
                  );
                  media.currentTime = mediaDuration === null
                    ? shiftedMediaTime
                    : Math.min(shiftedMediaTime, mediaDuration);
                  return 'ok';
                })()
                """#
            }
        }

        private static func mediaCommand(_ action: String) -> String {
            #"""
            (() => {
              if (location.origin !== 'https://music.youtube.com') return '';
              \#(ChromeYouTubeMusicBridge.mediaSelectionJavaScript)
              if (!media) return '';
              \#(action);
              return 'ok';
            })()
            """#
        }

        private static func buttonCommand(_ className: String) -> String {
            #"""
            (() => {
              if (location.origin !== 'https://music.youtube.com') return '';
              const button = document.querySelector('ytmusic-player-bar .\#(className)');
              if (!button) return '';
              button.click();
              return 'ok';
            })()
            """#
        }
    }

    enum BridgeError: LocalizedError {
        case automationDenied
        case javascriptDisabled
        case timedOut
        case commandRejected
        case invalidResponse
        case script(String)

        var errorDescription: String? {
            switch self {
            case .automationDenied:
                return "Chrome automation permission was denied."
            case .javascriptDisabled:
                return "Chrome JavaScript from Apple Events is disabled."
            case .timedOut:
                return "Chrome did not respond before the AppleScript timeout."
            case .commandRejected:
                return "YouTube Music did not acknowledge the playback command."
            case .invalidResponse:
                return "Chrome returned an invalid YouTube Music response."
            case let .script(message):
                return message
            }
        }
    }

    func readSnapshot(previouslyActiveTabID: String?) throws -> SnapshotResult? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        ).isEmpty else {
            return nil
        }

        guard let response = try executeAppleScript(snapshotAppleScript) else {
            throw BridgeError.invalidResponse
        }
        var lines = response.components(separatedBy: "\n")
        guard lines.first == Self.snapshotResponseMarker else {
            throw BridgeError.invalidResponse
        }
        lines.removeFirst()
        guard !lines.isEmpty else { throw BridgeError.invalidResponse }
        let frontWindowActiveTabID = lines.removeFirst()
        var candidates: [YouTubeMusicTabCandidate] = []
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: "\t") else {
                throw BridgeError.invalidResponse
            }
            let tabID = String(line[..<separator])
            let json = String(line[line.index(after: separator)...])
            guard !tabID.isEmpty,
                  tabID.allSatisfy(\.isNumber),
                  let data = json.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(
                      YouTubeMusicSnapshot.self,
                      from: data
                  ) else {
                throw BridgeError.invalidResponse
            }
            candidates.append(
                YouTubeMusicTabCandidate(tabID: tabID, snapshot: snapshot)
            )
        }

        guard let selected = YouTubeMusicTabSelector.select(
            from: candidates,
            previouslyActiveTabID: previouslyActiveTabID,
            frontWindowActiveTabID: frontWindowActiveTabID.isEmpty
                ? nil
                : frontWindowActiveTabID
        ) else { return nil }
        return SnapshotResult(tabID: selected.tabID, snapshot: selected.snapshot)
    }

    func execute(_ command: Command, onTabID tabID: String) throws {
        guard tabID.allSatisfy(\.isNumber) else {
            throw BridgeError.invalidResponse
        }
        let javaScript = Self.appleScriptLiteral(command.javaScript)
        let script = #"""
        set commandDeadline to (current date) + 2
        tell application id "com.google.Chrome"
            set chromeWindows to {}
            try
              with timeout of 1 second
                set chromeWindows to every window
              end timeout
            on error errorMessage number errorNumber
              if errorNumber is -1743 or errorNumber is 12 then
                error errorMessage number errorNumber
              end if
              if my (current date) > commandDeadline then error number -1712
            end try
            if my (current date) > commandDeadline then error number -1712
            repeat with chromeWindow in chromeWindows
              if my (current date) > commandDeadline then error number -1712
              set chromeTabs to {}
              try
                with timeout of 1 second
                  set chromeTabs to every tab of chromeWindow whose URL starts with "https://music.youtube.com/"
                end timeout
              on error errorMessage number errorNumber
                if errorNumber is -1743 or errorNumber is 12 then
                  error errorMessage number errorNumber
                end if
                if my (current date) > commandDeadline then error number -1712
              end try
              if my (current date) > commandDeadline then error number -1712
              repeat with chromeTab in chromeTabs
                if my (current date) > commandDeadline then error number -1712
                set currentTabID to ""
                try
                  with timeout of 1 second
                    set currentTabID to id of chromeTab as text
                  end timeout
                on error errorMessage number errorNumber
                  if errorNumber is -1743 or errorNumber is 12 then
                    error errorMessage number errorNumber
                  end if
                  if my (current date) > commandDeadline then error number -1712
                end try
                if my (current date) > commandDeadline then error number -1712
                if currentTabID is "\#(tabID)" then
                  set commandResponse to ""
                  try
                    with timeout of 1 second
                      set commandResponse to execute chromeTab javascript \#(javaScript)
                    end timeout
                  on error errorMessage number errorNumber
                    -- Once the target command starts, any failure has an
                    -- ambiguous outcome and must not become a safe retry.
                    error errorMessage number errorNumber
                  end try
                  if my (current date) > commandDeadline then error number -1712
                  if commandResponse is not "" then return commandResponse
                end if
              end repeat
            end repeat
            if my (current date) > commandDeadline then error number -1712
            return ""
        end tell
        """#
        let response = try executeAppleScript(script)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == "ok" else {
            throw BridgeError.commandRejected
        }
    }

    private func executeAppleScript(_ source: String) throws -> String? {
        guard let script = NSAppleScript(source: source) else {
            throw BridgeError.invalidResponse
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            let message = (errorInfo["NSAppleScriptErrorBriefMessage"] as? String) ??
                (errorInfo["NSAppleScriptErrorMessage"] as? String) ??
                "Chrome AppleScript failed."
            switch ChromeAppleScriptErrorKind.classify(
                errorNumber: number,
                message: message
            ) {
            case .automationDenied:
                throw BridgeError.automationDenied
            case .javascriptDisabled:
                throw BridgeError.javascriptDisabled
            case .timedOut:
                throw BridgeError.timedOut
            case .other:
                throw BridgeError.script(message)
            }
        }
        return result.stringValue
    }

    private var snapshotAppleScript: String {
        let javaScript = Self.appleScriptLiteral(Self.snapshotJavaScript)
        // Chrome's scripting dictionary shadows AppleScript's `tab` constant.
        return #"""
        set snapshotDeadline to (current date) + 2
        set fieldSeparator to ASCII character 9
        set responseValue to ""
        tell application id "com.google.Chrome"
            set frontWindowActiveTabID to ""
            try
              with timeout of 1 second
                set frontWindowActiveTabID to id of active tab of front window as text
              end timeout
            on error errorMessage number errorNumber
              if errorNumber is -1743 or errorNumber is 12 then
                error errorMessage number errorNumber
              end if
              if my (current date) > snapshotDeadline then error number -1712
            end try
            if my (current date) > snapshotDeadline then error number -1712
            set responseValue to frontWindowActiveTabID & linefeed
            set chromeWindows to {}
            try
              with timeout of 1 second
                set chromeWindows to every window
              end timeout
            on error errorMessage number errorNumber
              if errorNumber is -1743 or errorNumber is 12 then
                error errorMessage number errorNumber
              end if
              if my (current date) > snapshotDeadline then error number -1712
              error errorMessage number errorNumber
            end try
            if my (current date) > snapshotDeadline then error number -1712
            repeat with chromeWindow in chromeWindows
              if my (current date) > snapshotDeadline then error number -1712
              set chromeTabs to {}
              try
                with timeout of 1 second
                  set chromeTabs to every tab of chromeWindow whose URL starts with "https://music.youtube.com/"
                end timeout
              on error errorMessage number errorNumber
                  if errorNumber is -1743 or errorNumber is 12 then
                    error errorMessage number errorNumber
                  end if
                  if my (current date) > snapshotDeadline then error number -1712
                end try
              if my (current date) > snapshotDeadline then error number -1712
              repeat with chromeTab in chromeTabs
                if my (current date) > snapshotDeadline then error number -1712
                set currentTabID to ""
                try
                  with timeout of 1 second
                    set currentTabID to id of chromeTab as text
                  end timeout
                on error errorMessage number errorNumber
                    if errorNumber is -1743 or errorNumber is 12 then
                      error errorMessage number errorNumber
                    end if
                    if my (current date) > snapshotDeadline then error number -1712
                  end try
                if my (current date) > snapshotDeadline then error number -1712
                if currentTabID is not "" then
                  set candidateValue to ""
                  try
                    with timeout of 1 second
                      set candidateValue to execute chromeTab javascript \#(javaScript)
                    end timeout
                  on error errorMessage number errorNumber
                      if errorNumber is -1743 or errorNumber is 12 then
                        error errorMessage number errorNumber
                      end if
                      if my (current date) > snapshotDeadline then error number -1712
                    end try
                  if my (current date) > snapshotDeadline then error number -1712
                  if candidateValue is not "" then
                    set responseValue to responseValue & currentTabID & fieldSeparator & candidateValue & linefeed
                  end if
                end if
              end repeat
            end repeat
            return "\#(Self.snapshotResponseMarker)" & linefeed & responseValue
        end tell
        """#
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static let snapshotJavaScript = #"""
    (() => {
      if (location.origin !== 'https://music.youtube.com') return '';
      \#(mediaSelectionJavaScript)
      if (!media) return '';
      \#(trackTimingJavaScript)
      const metadata = navigator.mediaSession && navigator.mediaSession.metadata;
      const cleanText = value => {
        if (typeof value !== 'string') return null;
        const cleaned = value.replace(/\s+/g, ' ').trim();
        return cleaned || null;
      };
      const text = selector => cleanText(document.querySelector(selector)?.textContent);
      const domTitle = text('ytmusic-player-bar .title.ytmusic-player-bar');
      const domArtist = text(
        'ytmusic-player-bar .byline.ytmusic-player-bar a:nth-of-type(1)'
      );
      const mediaTitle = cleanText(metadata?.title);
      const mediaArtist = cleanText(metadata?.artist);
      const title = domTitle || mediaTitle;
      const artist = domArtist || mediaArtist;
      if (!title) return '';
      const canonicalSeedValue = value =>
        (value || '').normalize('NFKC').toLocaleLowerCase();
      const searchSeeds = [];
      const seedKeys = new Set();
      for (const seed of [
        { title: domTitle, artist: domArtist },
        { title: mediaTitle, artist: mediaArtist }
      ]) {
        if (!seed.title) continue;
        const key = canonicalSeedValue(seed.title) + '\u001f' +
          canonicalSeedValue(seed.artist);
        if (seedKeys.has(key)) continue;
        seedKeys.add(key);
        searchSeeds.push(seed);
      }
      const artwork = metadata?.artwork ? Array.from(metadata.artwork) : [];
      const payload = {
        url: location.href,
        videoID: new URL(location.href).searchParams.get('v'),
        title,
        artist,
        domTitle,
        domArtist,
        album: metadata?.album || text('ytmusic-player-bar .byline.ytmusic-player-bar a:nth-of-type(2)'),
        duration: trackDuration,
        playbackTime: trackPlaybackTime,
        playbackTimePrecision,
        isPlaying: !media.paused && !media.ended,
        artworkURL: artwork.length ? artwork[artwork.length - 1].src : null,
        searchSeeds
      };
      return JSON.stringify(payload);
    })()
    """#
}
