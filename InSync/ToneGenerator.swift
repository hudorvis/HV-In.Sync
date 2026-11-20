import Foundation
import AVFoundation

/// Generates a sample-locked one-second reference cycle.
///
/// The first 120 ms of each cycle contains the selected sine tone and the
/// remainder is silence. AVAudioPlayerNode loops an exact one-second buffer
/// at the active hardware sample rate, so successive pips cannot drift.
final class ToneGenerator {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var format: AVAudioFormat?
    private var playerAttached = false

    /// Best available estimate of render-to-speaker presentation latency.
    private(set) var presentationLatencySeconds: TimeInterval = 0

    /// True only after the active playback route resolves to the device's own
    /// speaker/receiver. Saved local calibration must not be applied to
    /// Bluetooth, AirPlay, headphones or external audio hardware.
    private(set) var usesBuiltInOutput = false

    func prepare() throws {
        let audioSession = AVAudioSession.sharedInstance()

        try audioSession.setCategory(
            .playback,
            mode: .default,
            options: []
        )
        try audioSession.setPreferredSampleRate(48_000)
        try audioSession.setPreferredIOBufferDuration(0.005)
        try audioSession.setActive(true)

        let activeOutputs = audioSession.currentRoute.outputs
        usesBuiltInOutput = !activeOutputs.isEmpty
            && activeOutputs.allSatisfy {
                $0.portType == .builtInSpeaker
                    || $0.portType == .builtInReceiver
            }

        // Preferred sample rates are requests, not guarantees. Build the
        // one-second cycle at the route's actual active rate so the loop remains
        // exactly one second even when a device or route uses 44.1 kHz.
        let activeSampleRate = audioSession.sampleRate > 0
            ? audioSession.sampleRate
            : 48_000

        let graphNeedsRebuild = format.map {
            abs($0.sampleRate - activeSampleRate) > 0.5
        } ?? true

        if graphNeedsRebuild {
            player.stop()

            if engine.isRunning {
                engine.stop()
            }

            guard let newFormat = AVAudioFormat(
                standardFormatWithSampleRate: activeSampleRate,
                channels: 1
            ) else {
                throw ToneGeneratorError.unavailableFormat
            }

            if !playerAttached {
                engine.attach(player)
                playerAttached = true
            } else {
                engine.disconnectNodeOutput(player)
            }

            engine.connect(
                player,
                to: engine.mainMixerNode,
                format: newFormat
            )
            format = newFormat
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        // presentationLatency is the hardware/presentation delay reported by
        // the output node. Some routes report zero while settling, so retain a
        // conservative AVAudioSession fallback.
        let playerPathLatency = player.outputPresentationLatency
        let outputNodeLatency = engine.outputNode.presentationLatency
        let sessionLatency = audioSession.outputLatency
        presentationLatencySeconds = max(
            playerPathLatency,
            outputNodeLatency,
            sessionLatency + (audioSession.ioBufferDuration * 0.5)
        )
    }

    /// Starts a one-second looping tone cycle whose acoustic onset is targeted
    /// at the supplied visual host time. The render start is advanced by the
    /// output presentation-latency estimate so the speaker and display targets
    /// share one master host-time epoch.
    func startLoop(
        frequency: Double,
        visualHostTimeSeconds: CFTimeInterval,
        calibrationAdvanceSeconds: TimeInterval = 0
    ) throws {
        guard frequency > 0 else {
            stop()
            return
        }

        try prepare()

        guard
            let format,
            let cycleBuffer = makeCycleBuffer(
                frequency: frequency,
                format: format
            )
        else {
            throw ToneGeneratorError.unavailableBuffer
        }

        player.stop()
        player.volume = 1.0
        player.scheduleBuffer(
            cycleBuffer,
            at: nil,
            options: [.loops],
            completionHandler: nil
        )

        let renderStartSeconds =
            visualHostTimeSeconds
            - presentationLatencySeconds
            - calibrationAdvanceSeconds
        let renderStartHostTime = AVAudioTime.hostTime(
            forSeconds: renderStartSeconds
        )

        player.play(
            at: AVAudioTime(hostTime: renderStartHostTime)
        )
    }

    func stop() {
        player.stop()
    }

    func shutdown() {
        player.stop()
        engine.stop()
        usesBuiltInOutput = false

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            print("In.Sync audio shutdown error: \(error)")
        }
    }

    private func makeCycleBuffer(
        frequency: Double,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let cycleFrames = AVAudioFrameCount(sampleRate.rounded())
        let pipDuration = 0.120
        let pipFrames = min(
            Int(cycleFrames),
            Int((sampleRate * pipDuration).rounded())
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: cycleFrames
        ) else {
            return nil
        }

        buffer.frameLength = cycleFrames

        guard let samples = buffer.floatChannelData?[0] else {
            return nil
        }

        for frame in 0..<Int(cycleFrames) {
            samples[frame] = 0
        }

        let fadeSeconds = 0.0035

        for frame in 0..<pipFrames {
            let time = Double(frame) / sampleRate
            let remaining = pipDuration - time

            // Raised-cosine edges avoid broadband clicks that could confuse a
            // frequency-selective detector while preserving a clear onset.
            let attackPhase = min(1.0, max(0.0, time / fadeSeconds))
            let releasePhase = min(
                1.0,
                max(0.0, remaining / fadeSeconds)
            )
            let attack = 0.5 - (0.5 * cos(.pi * attackPhase))
            let release = 0.5 - (0.5 * cos(.pi * releasePhase))
            let envelope = min(attack, release)

            samples[frame] = Float(
                sin(2.0 * .pi * frequency * time)
                * 0.95
                * envelope
            )
        }

        return buffer
    }
}

private enum ToneGeneratorError: Error {
    case unavailableFormat
    case unavailableBuffer
}
