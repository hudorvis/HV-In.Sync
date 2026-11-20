import Foundation
import SwiftUI
import Combine
import QuartzCore
import AVFoundation

protocol ReferenceFlashPresenting: AnyObject {
    func setReferenceFlashVisible(_ visible: Bool)
}

/// Drives the visual marker, full-screen flash and tone from one host-time
/// epoch. The audio cycle is sample-locked; the display state is selected using
/// CADisplayLink.targetTimestamp for the frame that is about to be presented.
final class ReferenceTimingEngine: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var currentMilliseconds: Double = 0
    @Published var flashActive = false

    var flashEnabled = true
    var toneFrequency: Double = 2000

    /// Residual acoustic tone delay measured by the local device calibration.
    /// Positive values advance the tone render so physical speaker onset moves
    /// toward the rendered flash frame.
    var referenceCalibrationMilliseconds: Double = 0

    // Flash duration follows the selected broadcast frame rate.
    var flashDurationSeconds: Double = 1.0 / 25.0

    private var displayLink: CADisplayLink?
    private var zeroHostTimeSeconds: CFTimeInterval = 0
    private var scheduleEstablished = false
    private var toneGenerator = ToneGenerator()
    private weak var flashPresenter: ReferenceFlashPresenting?
    private var audioInterruptionObserver: NSObjectProtocol?

    override init() {
        super.init()

        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                    as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType),
                type == .began
            else {
                return
            }

            // A newly scheduled host-time epoch is required after an audio
            // interruption. Stop rather than letting a silent/stale Reference
            // session continue to appear valid.
            self?.stop()
        }
    }

    deinit {
        if let audioInterruptionObserver {
            NotificationCenter.default.removeObserver(audioInterruptionObserver)
        }
    }

    func attachFlashPresenter(_ presenter: ReferenceFlashPresenting) {
        flashPresenter = presenter
        presenter.setReferenceFlashVisible(flashActive)
    }


    func start() {
        guard !isRunning else { return }

        // Use a fresh audio graph for every run. This prevents a prior route
        // change or media-services reset from leaving stale render state behind.
        toneGenerator = ToneGenerator()

        // Prepare the output path before choosing the shared zero. The first
        // CADisplayLink callback then anchors zero to an actual future display
        // target and gives the audio node ample time to schedule against it.
        do {
            if toneFrequency > 0 {
                try toneGenerator.prepare()
            }
        } catch {
            print("In.Sync reference tone preparation error: \(error)")
            toneGenerator.shutdown()
            return
        }

        scheduleEstablished = false
        zeroHostTimeSeconds = 0
        isRunning = true
        currentMilliseconds = 0
        setFlashActive(false)

        let link = CADisplayLink(
            target: self,
            selector: #selector(displayTick)
        )

        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        guard isRunning || displayLink != nil else { return }

        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        toneGenerator.shutdown()
        scheduleEstablished = false

        setFlashActive(false)
        currentMilliseconds = 0
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard isRunning else { return }

        // targetTimestamp represents the upcoming display presentation rather
        // than the callback's earlier CPU time. Establish the first shared zero
        // on that display cadence, rather than at an arbitrary CPU timestamp.
        let presentationTime = link.targetTimestamp

        if !scheduleEstablished {
            let frameInterval = max(
                1.0 / 120.0,
                link.targetTimestamp - link.timestamp
            )
            let scheduleLead = max(
                0.60,
                toneGenerator.presentationLatencySeconds + 0.25
            )
            let leadFrames = ceil(scheduleLead / frameInterval)
            zeroHostTimeSeconds =
                link.targetTimestamp + (leadFrames * frameInterval)
            scheduleEstablished = true

            do {
                if toneFrequency > 0 {
                    try toneGenerator.startLoop(
                        frequency: toneFrequency,
                        visualHostTimeSeconds: zeroHostTimeSeconds,
                        calibrationAdvanceSeconds:
                            toneGenerator.usesBuiltInOutput
                            ? referenceCalibrationMilliseconds / 1000.0
                            : 0
                    )
                }
            } catch {
                print("In.Sync reference tone schedule error: \(error)")
                stop()
                return
            }
        }

        let relative = presentationTime - zeroHostTimeSeconds
        let wrappedSeconds = wrapToHalfSecond(relative)

        currentMilliseconds = wrappedSeconds * 1000.0

        guard flashEnabled else {
            setFlashActive(false)
            return
        }

        // Cycle phase in [0, 1). A frame is white only when its intended
        // presentation lies within the selected flash interval after zero.
        let cyclePhase = positiveRemainder(relative, divisor: 1.0)
        let duration = min(
            0.20,
            max(1.0 / 120.0, flashDurationSeconds)
        )

        setFlashActive(relative >= 0 && cyclePhase < duration)
    }

    private func setFlashActive(_ active: Bool) {
        guard flashActive != active else { return }
        flashActive = active

        // Update the UIKit layer synchronously inside the display-link callback.
        // This avoids depending on a deferred SwiftUI render pass for the
        // timing-critical white reference flash.
        flashPresenter?.setReferenceFlashVisible(active)
    }

    private func wrapToHalfSecond(_ seconds: Double) -> Double {
        var value = seconds.truncatingRemainder(dividingBy: 1.0)

        if value > 0.5 {
            value -= 1.0
        } else if value <= -0.5 {
            value += 1.0
        }

        return value
    }

    private func positiveRemainder(
        _ value: Double,
        divisor: Double
    ) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
