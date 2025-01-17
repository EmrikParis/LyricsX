//
//  AppController.swift
//
//  This file is part of LyricsX
//  Copyright (C) 2017 Xander Deng - https://github.com/ddddxxx/LyricsX
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AppKit
import CombineX
import Crashlytics
import LyricsService
import MusicPlayer
import OpenCC
import Regex

class AppController: NSObject {
    
    static let shared = AppController()
    
    let lyricsManager = LyricsProviderManager()
    let playerManager = MusicPlayerControllerManager()
    
    @CombineX.Published
    var currentLyrics: Lyrics? {
        willSet {
            willChangeValue(forKey: "lyricsOffset")
            currentLineIndex = nil
        }
        didSet {
            didChangeValue(forKey: "lyricsOffset")
            scheduleCurrentLineCheck()
        }
    }
    
    @CombineX.Published
    var currentLineIndex: Int?
    
    var searchRequest: LyricsSearchRequest?
    var searchCanceller: Cancellable?
    
    private var cancelBag = Set<AnyCancellable>()
    
    @objc dynamic var lyricsOffset: Int {
        get {
            return currentLyrics?.offset ?? 0
        }
        set {
            currentLyrics?.offset = newValue
            currentLyrics?.metadata.needsPersist = true
            scheduleCurrentLineCheck()
        }
    }
    
    private override init() {
        super.init()
        playerManager.preferredPlayerName = MusicPlayerName(index: defaults[.PreferredPlayerIndex])
        
        defaultNC.cx.publisher(for: MusicPlayerController.currentTrackDidChangeNotification, object: playerManager)
            .sink { [unowned self] _ in
                self.currentTrackChanged()
            }.store(in: &cancelBag)
        defaultNC.cx.publisher(for: MusicPlayerController.playbackStateDidChangeNotification, object: playerManager)
            .sink { [unowned self] _ in
                self.scheduleCurrentLineCheck()
            }.store(in: &cancelBag)
        defaultNC.cx.publisher(for: MusicPlayerController.runningStateDidChangeNotification, object: playerManager)
            .sink { [unowned self] _ in
                if self.playerManager.player?.isRunning == false, defaults[.LaunchAndQuitWithPlayer] {
                    NSApplication.shared.terminate(nil)
                }
            }.store(in: &cancelBag)
        currentTrackChanged()
    }
    
    var currentLineCheckSchedule: Cancellable?
    func scheduleCurrentLineCheck() {
        currentLineCheckSchedule?.cancel()
        guard let lyrics = currentLyrics, let playbackTime = self.playerManager.player?.playbackTime else {
            return
        }
        
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        if currentLineIndex != index {
            currentLineIndex = index
        }
        if let next = next {
            let dt = lyrics.lines[next].position - playbackTime - lyrics.adjustedTimeDelay
            let q = DispatchQueue.global().cx
            currentLineCheckSchedule = q.schedule(after: q.now.advanced(by: .seconds(dt)), interval: .seconds(42), tolerance: .milliseconds(20)) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        }
    }
    
    func writeToiTunes(overwrite: Bool) {
        guard let player = playerManager.player as? iTunes,
            let currentLyrics = currentLyrics,
            overwrite || player.currentTrack?.lyrics?.isEmpty != false else {
            return
        }
        let content = currentLyrics.lines.map { line -> String in
            var content = line.content
            if let converter = ChineseConverter.shared {
                content = converter.convert(content)
            }
            if defaults[.WriteiTunesWithTranslation] {
                // TODO: tagged translation
                let code = currentLyrics.metadata.translationLanguages.first
                if var translation = line.attachments.translation(languageCode: code) {
                    if let converter = ChineseConverter.shared {
                        translation = converter.convert(translation)
                    }
                    content += "\n" + translation
                }
            }
            return content
        }.joined(separator: "\n")
        // swiftlint:disable:next force_try
        let regex = try! Regex(#"\n{3,}"#)
        let replaced = content.replacingMatches(of: regex, with: "\n\n")
        player.currentTrack?.setLyrics(replaced)
    }
    
    func currentTrackChanged() {
        if currentLyrics?.metadata.needsPersist == true {
            currentLyrics?.persist()
        }
        currentLyrics = nil
        currentLineIndex = nil
        searchCanceller?.cancel()
        guard let track = playerManager.player?.currentTrack else {
            return
        }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        
        guard !defaults[.NoSearchingTrackIds].contains(track.id) else {
            return
        }
        
        var candidateLyricsURL: [(URL, Bool, Bool)] = []  // (fileURL, isSecurityScoped, needsSearching)
        
        if defaults[.LoadLyricsBesideTrack] {
            if let fileName = track.fileURL?.deletingPathExtension() {
                candidateLyricsURL += [
                    (fileName.appendingPathExtension("lrcx"), false, false),
                    (fileName.appendingPathExtension("lrc"), false, false)
                ]
            }
        }
        let (url, security) = defaults.lyricsSavingPath()
        let titleForReading = title.replacingOccurrences(of: "/", with: "&")
        let artistForReading = artist.replacingOccurrences(of: "/", with: "&")
        let fileName = url.appendingPathComponent("\(titleForReading) - \(artistForReading)")
        candidateLyricsURL += [
            (fileName.appendingPathExtension("lrcx"), security, false),
            (fileName.appendingPathExtension("lrc"), security, true)
        ]
        
        for (url, security, needsSearching) in candidateLyricsURL {
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
                let lyrics = Lyrics(lrcContents) {
                lyrics.metadata.localURL = url
                lyrics.metadata.title = title
                lyrics.metadata.artist = artist
                lyrics.filtrate()
                lyrics.recognizeLanguage()
                currentLyrics = lyrics
                Answers.logCustomEvent(withName: "Load Local Lyrics")
                if needsSearching {
                    break
                } else {
                    return
                }
            }
        }
        
        #if IS_FOR_MAS
            guard defaults[.isInMASReview] == false else {
                return
            }
            checkForMASReview()
        #endif
        
        if let album = track.album, defaults[.NoSearchingAlbumNames].contains(album) {
            return
        }
        
        let duration = track.duration ?? 0
        let req = LyricsSearchRequest(searchTerm: .info(title: title, artist: artist),
                                      title: title,
                                      artist: artist,
                                      duration: duration,
                                      limit: 5,
                                      timeout: 10)
        searchRequest = req
        searchCanceller = lyricsManager.lyricsPublisher(request: req)
            .sink(receiveCompletion: { [unowned self] _ in
                if defaults[.WriteToiTunesAutomatically] {
                    self.writeToiTunes(overwrite: true)
                }
            }, receiveValue: { [unowned self] lyrics in
                self.lyricsReceived(lyrics: lyrics)
            }).cancel(after: .seconds(10), scheduler: DispatchQueue.global().cx)
        Answers.logCustomEvent(withName: "Search Lyrics Automatically", customAttributes: ["override": currentLyrics == nil ? 0 : 1])
    }
    
    // MARK: LyricsSourceDelegate
    
    func lyricsReceived(lyrics: Lyrics) {
        guard let req = searchRequest,
            lyrics.metadata.request == req else {
            return
        }
        if defaults[.StrictSearchEnabled] && !lyrics.isMatched() {
            return
        }
        if let current = currentLyrics, current.quality >= lyrics.quality {
            return
        }
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
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
        guard let track = playerManager.player?.currentTrack else {
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
        currentLyrics = lrc
        if let index = defaults[.NoSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.NoSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.NoSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.NoSearchingAlbumNames].remove(at: index)
        }
    }
}
