//
//  RNAudioRecorderPlayer.swift
//  RNAudioRecorderPlayer
//
//  Created by hyochan on 2021/05/05.
//

import Foundation
import AVFoundation
import lame

@objc(RNAudioRecorderPlayer)
class RNAudioRecorderPlayer: RCTEventEmitter, AVAudioRecorderDelegate {
    var subscriptionDuration: Double = 0.5
    var audioFileURL: URL?

    // Recorder
    var audioRecorder: AVAudioRecorder!
    var audioSession: AVAudioSession!
    var recordTimer: Timer?
    var _meteringEnabled: Bool = false
    
    // mp3
    var isMP3Active = false
    var filePathMP3: String? = nil
    var outref: ExtAudioFileRef?
    var audioEngine: AVAudioEngine!
    var mixer: AVAudioMixerNode!
    var meterLevel: Float = 0
    var startTime: Date?

    // Player
    var pausedPlayTime: CMTime?
    var audioPlayerAsset: AVURLAsset!
    var audioPlayerItem: AVPlayerItem!
    var audioPlayer: AVPlayer!
    var playTimer: Timer?
    var timeObserverToken: Any?

    override static func requiresMainQueueSetup() -> Bool {
      return true
    }

    override func supportedEvents() -> [String]! {
        return ["rn-playback", "rn-recordback"]
    }

    func setAudioFileURL(path: String, isMp3: Bool) {
        if (path == "DEFAULT") {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            audioFileURL = isMp3 ? cachesDirectory.appendingPathComponent("sound.mp3") : cachesDirectory.appendingPathComponent("sound.m4a")
        } else if (path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("file://")) {
            audioFileURL = URL(string: path)
        } else {
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            audioFileURL = cachesDirectory.appendingPathComponent(path)
        }
    }

    /**********               Recorder               **********/

    @objc(updateRecorderProgress:)
    public func updateRecorderProgress(timer: Timer) -> Void {
        if (audioRecorder != nil || self.isMP3Active) {
            var currentMetering: Float = 0

            if (_meteringEnabled) {
                if (self.isMP3Active) {
                    currentMetering = self.meterLevel
                } else {
                    audioRecorder.updateMeters()
                    currentMetering = audioRecorder.averagePower(forChannel: 0)
                }
            }

            let status = [
                "isRecording": self.isMP3Active || audioRecorder.isRecording,
                "currentPosition": (self.isMP3Active ? currentTime() : audioRecorder.currentTime) * 1000,
                "currentMetering": currentMetering,
            ] as [String : Any];

            sendEvent(withName: "rn-recordback", body: status)
        }
    }

    @objc(startRecorderTimer)
    func startRecorderTimer() -> Void {
        DispatchQueue.main.async {
            self.recordTimer = Timer.scheduledTimer(
                timeInterval: self.subscriptionDuration,
                target: self,
                selector: #selector(self.updateRecorderProgress),
                userInfo: nil,
                repeats: true
            )
        }
    }

    @objc(pauseRecorder:rejecter:)
    public func pauseRecorder(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioRecorder == nil) {
            return reject("RNAudioPlayerRecorder", "Recorder is not recording", nil)
        }

        recordTimer?.invalidate()
        recordTimer = nil;

        audioRecorder.pause()
        resolve("Recorder paused!")
    }

    @objc(resumeRecorder:rejecter:)
    public func resumeRecorder(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioRecorder == nil) {
            return reject("RNAudioPlayerRecorder", "Recorder is nil", nil)
        }

        audioRecorder.record()

        if (recordTimer == nil) {
            startRecorderTimer()
        }

        resolve("Recorder paused!")
    }

    @objc
    func construct() {
        self.subscriptionDuration = 0.1
    }

    @objc(audioPlayerDidFinishPlaying:)
    public static func audioPlayerDidFinishPlaying(player: AVAudioRecorder) -> Bool {
        return true
    }

    @objc(setSubscriptionDuration:)
    func setSubscriptionDuration(duration: Double) -> Void {
        subscriptionDuration = duration
    }

    /**********               Player               **********/

    @objc(startRecorder:audioSets:meteringEnabled:resolve:reject:)
    func startRecorder(path: String,  audioSets: [String: Any], meteringEnabled: Bool, resolve: @escaping RCTPromiseResolveBlock,
       rejecter reject: @escaping RCTPromiseRejectBlock) -> Void {

        _meteringEnabled = meteringEnabled

        let encoding = audioSets["AVFormatIDKeyIOS"] as? String ?? "mp3"
        let mode = audioSets["AVModeIOS"] as? String
        let avLPCMBitDepth = audioSets["AVLinearPCMBitDepthKeyIOS"] as? Int
        let avLPCMIsBigEndian = audioSets["AVLinearPCMIsBigEndianKeyIOS"] as? Bool
        let avLPCMIsFloatKey = audioSets["AVLinearPCMIsFloatKeyIOS"] as? Bool
        let avLPCMIsNonInterleaved = audioSets["AVLinearPCMIsNonInterleavedIOS"] as? Bool

        var avFormat: Int? = nil
        var avMode: AVAudioSession.Mode = AVAudioSession.Mode.default
        var sampleRate = audioSets["AVSampleRateKeyIOS"] as? Int
        var numberOfChannel = audioSets["AVNumberOfChannelsKeyIOS"] as? Int
        var audioQuality = audioSets["AVEncoderAudioQualityKeyIOS"] as? Int

        setAudioFileURL(path: path, isMp3: encoding == "mp3")

        if (sampleRate == nil) {
            sampleRate = 44100
        }

        if (encoding == nil) {
            avFormat = Int(kAudioFormatAppleLossless)
        } else {
            if (encoding == "lpcm") {
                avFormat = Int(kAudioFormatAppleIMA4)
            } else if (encoding == "ima4") {
                avFormat = Int(kAudioFormatAppleIMA4)
            } else if (encoding == "aac") {
                avFormat = Int(kAudioFormatMPEG4AAC)
            } else if (encoding == "MAC3") {
                avFormat = Int(kAudioFormatMACE3)
            } else if (encoding == "MAC6") {
                avFormat = Int(kAudioFormatMACE6)
            } else if (encoding == "ulaw") {
                avFormat = Int(kAudioFormatULaw)
            } else if (encoding == "alaw") {
                avFormat = Int(kAudioFormatALaw)
            } else if (encoding == "mp1") {
                avFormat = Int(kAudioFormatMPEGLayer1)
            } else if (encoding == "mp2") {
                avFormat = Int(kAudioFormatMPEGLayer2)
            } else if (encoding == "mp4") {
                avFormat = Int(kAudioFormatMPEG4AAC)
            } else if (encoding == "alac") {
                avFormat = Int(kAudioFormatAppleLossless)
            } else if (encoding == "amr") {
                avFormat = Int(kAudioFormatAMR)
            } else if (encoding == "flac") {
                if #available(iOS 11.0, *) {
                    avFormat = Int(kAudioFormatFLAC)
                }
            } else if (encoding == "opus") {
                avFormat = Int(kAudioFormatOpus)
            }
        }

        if (mode == "measurement") {
            avMode = AVAudioSession.Mode.measurement
        } else if (mode == "gamechat") {
            avMode = AVAudioSession.Mode.gameChat
        } else if (mode == "movieplayback") {
            avMode = AVAudioSession.Mode.moviePlayback
        } else if (mode == "spokenaudio") {
            avMode = AVAudioSession.Mode.spokenAudio
        } else if (mode == "videochat") {
            avMode = AVAudioSession.Mode.videoChat
        } else if (mode == "videorecording") {
            avMode = AVAudioSession.Mode.videoRecording
        } else if (mode == "voicechat") {
            avMode = AVAudioSession.Mode.voiceChat
        } else if (mode == "voiceprompt") {
            if #available(iOS 12.0, *) {
                avMode = AVAudioSession.Mode.voicePrompt
            } else {
                // Fallback on earlier versions
            }
        }


        if (numberOfChannel == nil) {
            numberOfChannel = 2
        }
        
        if encoding == "mp3" {
            numberOfChannel = 1
        }

        if (audioQuality == nil) {
            audioQuality = AVAudioQuality.medium.rawValue
        }
        
        func startRecording() {
            let settings = [
                AVSampleRateKey: sampleRate!,
                AVFormatIDKey: avFormat!,
                AVNumberOfChannelsKey: numberOfChannel!,
                AVEncoderAudioQualityKey: audioQuality!,
                AVLinearPCMBitDepthKey: avLPCMBitDepth ?? AVLinearPCMBitDepthKey.count,
                AVLinearPCMIsBigEndianKey: avLPCMIsBigEndian ?? true,
                AVLinearPCMIsFloatKey: avLPCMIsFloatKey ?? false,
                AVLinearPCMIsNonInterleaved: avLPCMIsNonInterleaved ?? false
            ] as [String : Any]

            do {
                audioRecorder = try AVAudioRecorder(url: audioFileURL!, settings: settings)

                if (audioRecorder != nil) {
                    audioRecorder.prepareToRecord()
                    audioRecorder.delegate = self
                    audioRecorder.isMeteringEnabled = _meteringEnabled
                    let isRecordStarted = audioRecorder.record()

                    if !isRecordStarted {
                        reject("RNAudioPlayerRecorder", "Error occured during initiating recorder", nil)
                        return
                    }

                    startRecorderTimer()

                    resolve(audioFileURL?.absoluteString)
                    return
                }

                reject("RNAudioPlayerRecorder", "Error occured during initiating recorder", nil)
            } catch {
                reject("RNAudioPlayerRecorder", "Error occured during recording", nil)
            }
        }
        
        func startRecordingMp3() {
            self.audioEngine = AVAudioEngine()
            self.mixer = AVAudioMixerNode()
            self.audioEngine.attach(mixer)
            
            let inputFormat = self.audioEngine.inputNode.outputFormat(forBus: 0)
            let outputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16,
                                       sampleRate: Double(sampleRate ?? 44100),
                                       channels: UInt32(numberOfChannel ?? 1),
                                       interleaved: true)!
            let converter = AVAudioConverter(from:  inputFormat, to: outputFormat)!
            
            self.audioEngine.connect(self.audioEngine.inputNode, to: self.mixer, format: inputFormat)
            self.mixer.volume = 0
            self.audioEngine.connect(self.mixer, to: self.audioEngine.mainMixerNode, format: inputFormat)
            let wavPath = audioFileURL!.absoluteString.replacingOccurrences(of: "mp3", with: "wav").replacingOccurrences(of: "file://", with: "")
            
            _ = ExtAudioFileCreateWithURL(URL(fileURLWithPath: wavPath) as CFURL, kAudioFileWAVEType, (inputFormat.streamDescription), nil, AudioFileFlags.eraseFile.rawValue, &outref)

            self.mixer.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: { (buffer: AVAudioPCMBuffer!, time: AVAudioTime!) -> Void in
                let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputFormat.sampleRate) * buffer.frameLength / AVAudioFrameCount(buffer.format.sampleRate))!
                try? converter.convert(to: convertedBuffer, from: buffer)
                
                
                _ = ExtAudioFileWrite(self.outref!, convertedBuffer.frameLength, convertedBuffer.audioBufferList)
                if self._meteringEnabled {
                    self.updateMeters(buffer)
                }
            })
            
            do {
                self.audioEngine.prepare()
                try self.audioEngine.start()
                startTime = Date()
                
                mp3Rec(wavPath: wavPath, sampleRate: sampleRate ?? 44100, rate: Int32(audioQuality ?? 128))
                startRecorderTimer()
                resolve(audioFileURL?.absoluteString)
                return
            } catch {
                reject("RNAudioPlayerRecorder", "Error occured during recording", nil)
            }
        }

        audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord, mode: avMode, options: [AVAudioSession.CategoryOptions.defaultToSpeaker, AVAudioSession.CategoryOptions.allowBluetooth])
            try audioSession.setActive(true)

            audioSession.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        if encoding == "mp3" {
                            startRecordingMp3()
                        } else {
                            startRecording()
                        }
                    } else {
                        reject("RNAudioPlayerRecorder", "Record permission not granted", nil)
                    }
                }
            }
        } catch {
            reject("RNAudioPlayerRecorder", "Failed to record", nil)
        }
    }

    @objc(stopRecorder:rejecter:)
    public func stopRecorder(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioRecorder == nil && !self.isMP3Active) {
            reject("RNAudioPlayerRecorder", "Failed to stop recorder. It is already nil.", nil)
            return
        }

        if audioRecorder != nil {
            audioRecorder.stop()
        }
        
        if self.isMP3Active {
            self.audioEngine.stop()
            self.mixer.removeTap(onBus: 0)
            self.stopMP3Rec()
            ExtAudioFileDispose(self.outref!)
            let wavPath = self.audioFileURL!.absoluteString.replacingOccurrences(of: "mp3", with: "wav").replacingOccurrences(of: "file://", with: "")
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: wavPath))
        }

        if (recordTimer != nil) {
            recordTimer!.invalidate()
            recordTimer = nil
        }
        
        try? audioSession.setActive(false)

        resolve(audioFileURL?.absoluteString)
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Failed to stop recorder")
        }
    }

    /**********               Player               **********/

    func addPeriodicTimeObserver() {
        let timeScale = CMTimeScale(NSEC_PER_SEC)
        let time = CMTime(seconds: subscriptionDuration, preferredTimescale: timeScale)

        timeObserverToken = audioPlayer.addPeriodicTimeObserver(forInterval: time,
                                                                queue: .main) {_ in
            if (self.audioPlayer != nil) {
                self.sendEvent(withName: "rn-playback", body: [
                    "isMuted": self.audioPlayer.isMuted,
                    "currentPosition": self.audioPlayerItem.currentTime().seconds * 1000,
                    "duration": self.audioPlayerItem.asset.duration.seconds * 1000,
                ])
            }
        }
    }

    func removePeriodicTimeObserver() {
        if let timeObserverToken = timeObserverToken {
            audioPlayer.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
    }


    @objc(startPlayer:httpHeaders:resolve:rejecter:)
    public func startPlayer(
        path: String,
        httpHeaders: [String: String],
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [AVAudioSession.CategoryOptions.defaultToSpeaker, AVAudioSession.CategoryOptions.allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            reject("RNAudioPlayerRecorder", "Failed to play", nil)
        }

        setAudioFileURL(path: path, isMp3: true)
        audioPlayerAsset = AVURLAsset(url: audioFileURL!, options:["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
        audioPlayerItem = AVPlayerItem(asset: audioPlayerAsset!)

        if (audioPlayer == nil) {
            audioPlayer = AVPlayer(playerItem: audioPlayerItem)
        } else {
            audioPlayer.replaceCurrentItem(with: audioPlayerItem)
        }

        addPeriodicTimeObserver()
        audioPlayer.play()
        resolve(audioFileURL?.absoluteString)
    }

    @objc(stopPlayer:rejecter:)
    public func stopPlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is already stopped.", nil)
        }

        audioPlayer.pause()
        self.removePeriodicTimeObserver()
        self.audioPlayer = nil;

        resolve(audioFileURL?.absoluteString)
    }

    @objc(pausePlayer:rejecter:)
    public func pausePlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is not playing", nil)
        }

        audioPlayer.pause()
        resolve("Player paused!")
    }

    @objc(resumePlayer:rejecter:)
    public func resumePlayer(
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is null", nil)
        }

        audioPlayer.play()
        resolve("Resumed!")
    }

    @objc(seekToPlayer:resolve:rejecter:)
    public func seekToPlayer(
        time: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        if (audioPlayer == nil) {
            return reject("RNAudioPlayerRecorder", "Player is null", nil)
        }

        audioPlayer.seek(to: CMTime(seconds: time / 1000, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        resolve("Resumed!")
    }

    @objc(setVolume:resolve:rejecter:)
    public func setVolume(
        volume: Float,
        resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) -> Void {
        audioPlayer.volume = volume
        resolve(volume)
    }
    
    private func currentTime() -> TimeInterval {
        if let start = startTime {
            return Date().timeIntervalSince(start)
        }
        return 0
    }
    
    private func updateMeters(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }
        
        let rms = sqrt(channelDataValueArray.map {
            return $0 * $0
        }
            .reduce(0, +) / Float(buffer.frameLength))
        
        let avgPower = 20 * log10(rms)
        DispatchQueue.main.async {
            self.meterLevel = avgPower
        }
    }
    
    private func mp3Rec(wavPath: String, sampleRate: Int, rate: Int32) {
        self.isMP3Active = true
        var total = 0
        var read = 0
        var write: Int32 = 0
        
        var pcm: UnsafeMutablePointer<FILE> = fopen(wavPath, "rb")
        fseek(pcm, 4*1024, SEEK_CUR)
        
        let mp3Path = wavPath.replacingOccurrences(of: "wav", with: "mp3")
        let mp3: UnsafeMutablePointer<FILE> = fopen(mp3Path, "wb")
        let PCM_SIZE: Int = 8192
        let MP3_SIZE: Int32 = 8192
        let pcmbuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(PCM_SIZE*2))
        let mp3buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MP3_SIZE))
        
        let lame = lame_init()
        lame_set_num_channels(lame, 1)
        lame_set_mode(lame, MONO)
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_out_samplerate(lame, 0) // which means LAME picks best value
        lame_set_quality(lame, 4); // normal quality, quite fast encoding
        lame_set_brate(lame, rate)
        lame_set_VBR(lame, vbr_off)
        lame_init_params(lame)
        
        DispatchQueue.global(qos: .default).async {
            while true {
                pcm = fopen(wavPath, "rb")
                fseek(pcm, 4*1024 + total, SEEK_CUR)
                read = fread(pcmbuffer, MemoryLayout<Int16>.size, PCM_SIZE, pcm)
                if read != 0 {
                    write = lame_encode_buffer(lame, pcmbuffer, nil, Int32(read), mp3buffer, MP3_SIZE)
                    fwrite(mp3buffer, Int(write), 1, mp3)
                    total += read * MemoryLayout<Int16>.size
                    fclose(pcm)
                } else if !self.isMP3Active {
                    _ = lame_encode_flush(lame, mp3buffer, MP3_SIZE)
                    _ = fwrite(mp3buffer, Int(write), 1, mp3)
                    break
                } else {
                    fclose(pcm)
                    usleep(50)
                }
            }
            lame_close(lame)
            fclose(mp3)
            fclose(pcm)
        }
    }
    
    private func stopMP3Rec() {
        self.isMP3Active = false
    }
}
