import Accelerate
@preconcurrency import AVFoundation
import os

nonisolated private let logger = Logger(subsystem: "com.apoorvdarshan.calorietracker", category: "LiveAudio")

/// Output-only audio for Settings previews. This interface cannot open a microphone.
protocol LivePlaybackIO: AnyObject {
    var onPlaybackFinished: (() -> Void)? { get set }
    var onInterrupted: (() -> Void)? { get set }
    var isPlaying: Bool { get }
    func startPlayback(outputSampleRate: Double) throws
    func play(_ pcm16: Data)
    func stop()
}

/// Microphone in, assistant voice out. `VoiceAssistantController` drives it; tests use a fake.
protocol LiveAudioIO: AnyObject {
    /// Called on the main actor when everything scheduled has finished playing.
    var onPlaybackFinished: (() -> Void)? { get set }
    /// Called on the main actor when the system stops the audio (a phone call,
    /// another app taking over, or a route change it can't recover from).
    var onInterrupted: (() -> Void)? { get set }
    var isPlaying: Bool { get }
    /// Loudness of the microphone and of the reply being played, 0...1, for the orb.
    var microphoneLevel: Double { get }
    var playbackLevel: Double { get }

    /// Starts the microphone and playback. `microphone` receives microphone audio
    /// (16-bit mono PCM at the input rate) on an audio thread.
    func start(inputSampleRate: Double, outputSampleRate: Double, microphone: @escaping @Sendable (Data) -> Void) throws
    /// Schedules reply audio after anything already queued.
    func play(_ pcm16: Data)
    /// Where playback is, in seconds since this reply's audio began.
    var playbackPosition: TimeInterval { get }
    /// Where the next scheduled chunk will start, in the same timeline as `playbackPosition`.
    var scheduledEnd: TimeInterval { get }
    func stopPlayback()
    func stop()
}

enum LiveAudioError: LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: String(localized: "The microphone isn't available.")
        }
    }
}

/// AVAudioEngine with voice processing: the echo canceller removes the assistant's
/// own voice from the microphone, so it doesn't hear and interrupt itself when the
/// reply plays through the loudspeaker.
final class LiveAudioEngine: LiveAudioIO, LivePlaybackIO {
    var onPlaybackFinished: (() -> Void)?
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []
    private let player = AVAudioPlayerNode()
    private let micLevel = LiveLevelBox()
    private let voiceLevel = LiveLevelBox()
    private var playbackFormat: AVAudioFormat?
    private var outputSampleRate = 24_000.0
    private var isRunning = false
    private var usesMicrophone = false
    private var hasMicrophoneTap = false
    private var hasPlayerTap = false
    private var generation = 0
    private var pendingBuffers = 0
    private var queueEndFrame: AVAudioFramePosition = 0

    var isPlaying: Bool {
        pendingBuffers > 0
    }

    var microphoneLevel: Double { micLevel.value }
    var playbackLevel: Double { pendingBuffers > 0 ? voiceLevel.value : 0 }

    /// Intentionally never accesses inputNode, installs an input tap, or requests
    /// recording permission. Preview playback uses the system playback category.
    func startPlayback(outputSampleRate: Double) throws {
        self.outputSampleRate = outputSampleRate
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try configurePlayer(outputSampleRate: outputSampleRate)
        try startEngine()
    }

    func start(inputSampleRate: Double, outputSampleRate: Double, microphone: @escaping @Sendable (Data) -> Void) throws {
        self.outputSampleRate = outputSampleRate
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Voice processing must be on before the engine is configured and started.
        usesMicrophone = true
        try engine.inputNode.setVoiceProcessingEnabled(true)

        try configurePlayer(outputSampleRate: outputSampleRate)
        try installMicrophoneTap(sampleRate: inputSampleRate, sink: microphone)
        try startEngine()
    }

    private func configurePlayer(outputSampleRate: Double) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false) else {
            throw LiveAudioError.microphoneUnavailable
        }
        playbackFormat = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.levelTap(voiceLevel))
        hasPlayerTap = true

    }

    private func startEngine() throws {
        engine.prepare()
        try engine.start()
        isRunning = true
        observeInterruptions()
        logger.info("[LiveAudio] Started")
    }

    func play(_ pcm16: Data) {
        // The player throws (an Objective-C exception) if the engine has stopped.
        guard isRunning, engine.isRunning, let format = playbackFormat else { return }
        let frameCount = pcm16.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm16.withUnsafeBytes { raw in
            for index in 0..<frameCount {
                let value = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                samples[index] = Float(Int16(littleEndian: value)) / 32_768
            }
        }

        let now = currentFrame()
        let start = max(now, queueEndFrame)
        queueEndFrame = start + AVAudioFramePosition(frameCount)
        pendingBuffers += 1

        let scheduledGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.bufferFinished(generation: scheduledGeneration)
                }
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    var playbackPosition: TimeInterval {
        Double(currentFrame()) / outputSampleRate
    }

    var scheduledEnd: TimeInterval {
        Double(max(currentFrame(), queueEndFrame)) / outputSampleRate
    }

    func stopPlayback() {
        generation += 1
        pendingBuffers = 0
        queueEndFrame = 0
        voiceLevel.value = 0
        player.stop()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if engine.isRunning {
            stopPlayback()
        } else {
            generation += 1
            pendingBuffers = 0
            queueEndFrame = 0
        }
        if hasPlayerTap {
            player.removeTap(onBus: 0)
            hasPlayerTap = false
        }
        // The input node is only touched if this engine used the microphone:
        // creating it would start microphone use.
        if hasMicrophoneTap {
            engine.inputNode.removeTap(onBus: 0)
            hasMicrophoneTap = false
        }
        if engine.isRunning {
            engine.stop()
        }
        if usesMicrophone {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            usesMicrophone = false
        }
        isRunning = false
        micLevel.value = 0
        voiceLevel.value = 0
        onPlaybackFinished = nil
        onInterrupted = nil
        // Hand the audio back so music or podcasts the user paused can resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        logger.info("[LiveAudio] Stopped")
    }

    // MARK: - Internals

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard rawType.flatMap(AVAudioSession.InterruptionType.init) == .began else { return }
            MainActor.assumeIsolated {
                self?.onInterrupted?()
            }
        })
        // A route change (headphones, Bluetooth) stops the engine; restart it.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartAfterConfigurationChange()
            }
        })
    }

    private func restartAfterConfigurationChange() {
        guard isRunning, !engine.isRunning else { return }
        // A preview has no input stream to resume. Queued playback is lost on a
        // route change, so end it instead of waiting for buffers that cannot drain.
        guard usesMicrophone else {
            onInterrupted?()
            return
        }
        generation += 1
        pendingBuffers = 0
        queueEndFrame = 0
        do {
            engine.prepare()
            try engine.start()
            logger.info("[LiveAudio] Restarted after an audio route change")
        } catch {
            logger.error("[LiveAudio] Couldn't restart: \(error.localizedDescription, privacy: .public)")
            onInterrupted?()
        }
    }

    private func bufferFinished(generation finishedGeneration: Int) {
        guard finishedGeneration == generation, pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        if pendingBuffers == 0 {
            voiceLevel.value = 0
            onPlaybackFinished?()
        }
    }

    /// The player's position in frames since it last started; 0 before it renders.
    private func currentFrame() -> AVAudioFramePosition {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, playerTime.sampleTime)
    }

    private func installMicrophoneTap(sampleRate: Double, sink: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw LiveAudioError.microphoneUnavailable
        }
        // Voice processing can deliver more than one channel; the provider wants mono.
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: Self.microphoneTap(
            converter: converter,
            targetFormat: targetFormat,
            level: micLevel,
            sink: sink
        ))
        hasMicrophoneTap = true
    }

    /// Built outside the main actor: the tap runs on an audio thread.
    nonisolated private static func microphoneTap(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        level: LiveLevelBox,
        sink: @escaping @Sendable (Data) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            level.value = loudness(of: buffer)
            guard let data = convert(buffer, with: converter, to: targetFormat) else { return }
            sink(data)
        }
    }

    /// Measures the reply as it plays, for the orb. Built outside the main actor too.
    nonisolated private static func levelTap(_ level: LiveLevelBox) -> AVAudioNodeTapBlock {
        { buffer, _ in
            level.value = loudness(of: buffer)
        }
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> Data? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Maps -55 dBFS (room noise) ... -15 dBFS (talking close) onto 0...1.
    nonisolated static func loudness(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        return loudness(rms: Double(rms))
    }

    nonisolated static func loudness(rms: Double) -> Double {
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 55) / 40, 0), 1)
    }
}

/// The latest level, written on an audio thread and read on the main one.
nonisolated final class LiveLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
