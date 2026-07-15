//
//  AppController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Foundation
import MusicPlayer
import GenericID
import CXShim

private final class AutomaticMusicPlayer: MusicPlayers.Agent {
    let players: [MusicPlayerProtocol]

    private var playerChangeObservation: AnyCancellable?
    private var activities: [PlaybackSourceActivity]

    init(players: [MusicPlayerProtocol]) {
        self.players = players
        activities = Array(repeating: .stopped, count: players.count)
        super.init()
        playerChangeObservation = Publishers.MergeMany(
            players.enumerated().map { index, player in
                player.playbackStateWillChange
                    .map { (index, Self.activity(for: $0)) }
                    .eraseToAnyPublisher()
            }
        )
        .receive(on: DispatchQueue.main.cx)
        .sink { [weak self] index, activity in
            guard let self, self.activities.indices.contains(index) else { return }
            self.activities[index] = activity
            self.selectPlayer()
        }
    }

    func updateAllPlayerStates() {
        players.forEach { $0.updatePlayerState() }
    }

    private func selectPlayer() {
        let currentIndex = designatedPlayer.flatMap { current in
            players.firstIndex { $0 === current }
        }
        let selectedIndex = AutomaticPlayerSelectionPolicy.selectedIndex(
            currentIndex: currentIndex,
            activities: activities
        )
        let newPlayer = selectedIndex.map { players[$0] }
        if newPlayer !== designatedPlayer {
            designatedPlayer = newPlayer
        }
    }

    private static func activity(for state: PlaybackState) -> PlaybackSourceActivity {
        if state.isPlaying {
            return .playing
        }
        return state == .stopped ? .stopped : .paused
    }
}

extension MusicPlayers {
    
    final class Selected: Agent {
        
        static let shared = MusicPlayers.Selected()
        
        private var defaultsObservation: DefaultsObservation?
        
        private var manualUpdateObservation: AnyCancellable?

        private let idlePollingInterval: TimeInterval = 5
        private let pausedWebPollingInterval: TimeInterval = 2
        
        var manualUpdateInterval: TimeInterval = 1.0 {
            didSet {
                scheduleManualUpdate()
            }
        }
        
        override init() {
            super.init()
            selectPlayer()
            scheduleManualUpdate()
            defaultsObservation = defaults.observe(keys: [.preferredPlayerIndex, .useSystemWideNowPlaying]) { [weak self] in
                DispatchQueue.main.async {
                    self?.selectPlayer()
                }
            }
            manualUpdateObservation = playbackStateWillChange
                .receive(on: DispatchQueue.main.cx)
                .sink { [weak self] state in
                guard let self else { return }
                if state.isPlaying || self.requiresContinuousPolling {
                    self.scheduleManualUpdate()
                } else {
                    self.cancelManualUpdate()
                }
            }
        }

        private var requiresContinuousPolling: Bool {
            guard let automaticPlayer = designatedPlayer as? AutomaticMusicPlayer else {
                return false
            }
            return automaticPlayer.players.contains { $0 is MusicPlayers.YouTubeMusic }
        }

        private var effectivePollingInterval: TimeInterval {
            guard let automaticPlayer = designatedPlayer as? AutomaticMusicPlayer,
                  let youtubeMusic = automaticPlayer.players.first(where: {
                      $0 is MusicPlayers.YouTubeMusic
                  }) else {
                return manualUpdateInterval
            }
            if automaticPlayer.playbackState.isPlaying {
                return manualUpdateInterval
            }
            if youtubeMusic.currentTrack != nil {
                return max(manualUpdateInterval, pausedWebPollingInterval)
            }
            return max(manualUpdateInterval, idlePollingInterval)
        }
        
        private func selectPlayer() {
            let selection = PlayerSelection(rawValue: defaults[.preferredPlayerIndex]) ?? .automatic
            let systemNowPlayingAvailable: Bool
            if #available(macOS 15.4, *) {
                // MediaRemote rejects ordinary applications on current macOS.
                systemNowPlayingAvailable = false
            } else {
                systemNowPlayingAvailable = MusicPlayers.SystemMedia.available
            }
            let route = selection.route(
                systemNowPlayingEnabled: defaults[.useSystemWideNowPlaying],
                systemNowPlayingAvailable: systemNowPlayingAvailable
            )
            switch route {
            case let .automatic(includeSystemNowPlaying):
                var players: [MusicPlayerProtocol] = [MusicPlayers.YouTubeMusic()]
                players.append(contentsOf: MusicPlayerName.scriptableCases.compactMap(MusicPlayers.Scriptable.init))
                if includeSystemNowPlaying, let systemPlayer = MusicPlayers.SystemMedia() {
                    players.append(systemPlayer)
                }
                designatedPlayer = AutomaticMusicPlayer(players: players)
            case let .scriptablePlayer(index):
                designatedPlayer = MusicPlayerName(index: index).flatMap(MusicPlayers.Scriptable.init)
            }
            scheduleManualUpdate()
        }
        
        private var scheduleCanceller: Cancellable?

        private func cancelManualUpdate() {
            let canceller = scheduleCanceller
            scheduleCanceller = nil
            canceller?.cancel()
        }

        func scheduleManualUpdate() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleManualUpdate()
                }
                return
            }
            guard manualUpdateInterval > 0 else {
                cancelManualUpdate()
                return
            }
            let player = designatedPlayer
            let q = DispatchQueue.global().cx
            let i: CXWrappers.DispatchQueue.SchedulerTimeType.Stride = .seconds(
                effectivePollingInterval
            )
            let newCanceller = q.schedule(after: q.now.advanced(by: i), interval: i, tolerance: i * 0.1, options: nil) {
                if let automaticPlayer = player as? AutomaticMusicPlayer {
                    automaticPlayer.updateAllPlayerStates()
                } else {
                    player?.updatePlayerState()
                }
            }
            let previousCanceller = scheduleCanceller
            scheduleCanceller = newCanceller
            previousCanceller?.cancel()
        }
    }
}
