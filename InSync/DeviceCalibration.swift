import Foundation
import Combine
import AVFoundation
import QuartzCore
import UIKit
import Darwin

enum CalibrationIndicatorState {
    case none
    case valid
    case questionable
    case failed
}

enum CalibrationRunState {
    case idle
    case preparing
    case running
    case success
    case failure
}

protocol CalibrationFlashPresenting: AnyObject {
    func setCalibrationFlashVisible(_ visible: Bool)
}

struct FrequencyCalibration: Codable, Equatable {
    let frequency: Double
    let digitalAudioMinusVideoMilliseconds: Double?
    let speakerMinusDigitalAudioMilliseconds: Double?
    let referenceResidualMilliseconds: Double
    let sampleCount: Int
    let jitterMilliseconds: Double
}

struct DeviceCalibrationRecord: Codable, Equatable {
    let algorithmVersion: Int
    let deviceModel: String
    let systemVersion: String
    let createdAt: Date
    let quality: Double
    let factoryMeasureCorrectionMilliseconds: Double
    let frequencies: [FrequencyCalibration]
}

/// Runs the local device calibration against the same host-time mechanisms used
/// by normal Reference and Measure operation.
///
/// Earlier revisions attempted to separate ReplayKit microphone detections into
/// independent 1, 2 and 4 kHz groups. That added three fragile acceptance gates
/// even though the correction is fundamentally a single output-path residual.
/// This revision uses one repeatable dual-band signature for all 15 samples,
/// captures the built-in microphone directly from AVAudioEngine, and anchors
/// each flash to CADisplayLink.targetTimestamp. ReplayKit is deliberately not
/// part of the required path: it added format, delivery and 30 fps quantisation
/// failure modes without measuring the physical panel emission itself. Version 7
/// also survives the first-run permission transition and primes the duplex audio
/// path before any of the 15 real samples are scheduled.
final class DeviceCalibrationManager: NSObject, ObservableObject {
    static let algorithmVersion = 7

    // Universal starting point derived from the locked v26.08.04.01 direct
    // two-phone tests. It remains separately adjustable through the hidden
    // service control; device-model overrides stay empty until physical testing
    // proves they are needed.
    static let factoryMeasureCorrectionMilliseconds = 40.5
    private static let calibrationRepeatInterval: TimeInterval =
        180 * 24 * 60 * 60

    @Published private(set) var indicatorState: CalibrationIndicatorState = .none
    @Published private(set) var runState: CalibrationRunState = .idle
    @Published private(set) var progress = 0.0
    @Published private(set) var isAwaitingMicrophonePermission = false
    private(set) var flashActive = false
    @Published private(set) var headline = "Device Calibration"
    @Published private(set) var detail = "Preparing…"
    @Published private(set) var qualityText = ""
    @Published private(set) var record: DeviceCalibrationRecord?
    @Published private(set) var serviceMeasureCorrectionMilliseconds =
        DeviceCalibrationManager.factoryMeasureCorrectionMilliseconds

    private let defaults = UserDefaults.standard
    private let recordKey = "InSync.DeviceCalibration.v7"
    private let legacyRecordKeys = [
        "InSync.DeviceCalibration.v6",
        "InSync.DeviceCalibration.v5",
        "InSync.DeviceCalibration.v4",
        "InSync.DeviceCalibration.v3",
        "InSync.DeviceCalibration.v2"
    ]
    private let failureKey = "InSync.DeviceCalibration.v7.LastAttemptFailed"
    private let serviceCorrectionKey =
        "InSync.DeviceCalibration.ServiceMeasureCorrectionMilliseconds"

    private let analysisQueue = DispatchQueue(
        label: "au.h-v.in.sync.calibration.analysis",
        qos: .userInitiated
    )

    private var routeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var displayLink: CADisplayLink?
    private weak var flashPresenter: CalibrationFlashPresenting?
    private var calibrationEngine = CalibrationDuplexEngine()
    private let runIDLock = NSLock()
    private var storedRunID = UUID()
    private var currentRunID: UUID {
        get { runIDLock.withLock { storedRunID } }
        set { runIDLock.withLock { storedRunID = newValue } }
    }
    private var stopping = false
    private var finishWorkItem: DispatchWorkItem?
    private var warmupWorkItem: DispatchWorkItem?
    private var pendingActiveStartRunID: UUID?
    private var permissionReturnInProgress = false
    private var audioPreparationAttempt = 0
    private var warmupDeadline = Date.distantPast
    private var warmupStableChecks = 0

    private struct Pulse {
        let targetHostTime: CFTimeInterval
    }

    private var sequenceEstablished = false
    private var pulses: [Pulse] = []
    private var nextVisualPulseIndex = 0
    private var visualEvents: [Double] = []
    private var capturedAudio: [CapturedCalibrationAudio] = []
    private var currentDisplayInterval = 1.0 / 60.0
    private let flashDuration = 0.105

    override init() {
        super.init()
        loadSavedRecord()

        let centre = NotificationCenter.default
        routeObserver = centre.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.runState == .running, !self.strictBuiltInRouteIsActive() {
                self.fail(
                    "The audio route changed during calibration. Disconnect external audio and try again."
                )
                return
            }
            self.refreshIndicator()
        }

        mediaResetObserver = centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.runState == .preparing || self.runState == .running {
                self.fail(
                    "The iPhone audio system restarted during calibration. Try once more."
                )
                return
            }
            self.refreshIndicator()
        }

        appDidBecomeActiveObserver = centre.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeAfterPermissionIfNeeded()
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        if let mediaResetObserver {
            NotificationCenter.default.removeObserver(mediaResetObserver)
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
        }
    }

    var isHandlingPermissionTransition: Bool {
        isAwaitingMicrophonePermission
            || pendingActiveStartRunID != nil
            || permissionReturnInProgress
    }

    func attachFlashPresenter(_ presenter: CalibrationFlashPresenting) {
        flashPresenter = presenter
        presenter.setCalibrationFlashVisible(flashActive)
    }

    var referenceCalibrationAvailable: Bool {
        guard recordMatchesCurrentDeviceAndSoftware else { return false }
        return currentRouteLooksBuiltIn()
    }

    var measurementCorrectionMilliseconds: Double {
        guard recordMatchesCurrentDeviceAndSoftware else { return 0 }
        return serviceMeasureCorrectionMilliseconds
    }

    func setServiceMeasureCorrectionMilliseconds(_ value: Double) {
        let bounded = min(100.0, max(-100.0, value))
        serviceMeasureCorrectionMilliseconds = (bounded * 10.0).rounded() / 10.0
        defaults.set(
            serviceMeasureCorrectionMilliseconds,
            forKey: serviceCorrectionKey
        )

        guard let record else { return }
        let updated = DeviceCalibrationRecord(
            algorithmVersion: record.algorithmVersion,
            deviceModel: record.deviceModel,
            systemVersion: record.systemVersion,
            createdAt: record.createdAt,
            quality: record.quality,
            factoryMeasureCorrectionMilliseconds:
                serviceMeasureCorrectionMilliseconds,
            frequencies: record.frequencies
        )

        do {
            defaults.set(try JSONEncoder().encode(updated), forKey: recordKey)
            self.record = updated
            refreshIndicator()
        } catch {
            print("In.Sync service correction persistence error: \(error)")
        }
    }

    func resetServiceMeasureCorrection() {
        let value = Self.defaultFactoryMeasureCorrectionMilliseconds(
            for: Self.deviceModelIdentifier()
        )
        setServiceMeasureCorrectionMilliseconds(value)
    }

    func referenceCorrectionMilliseconds(
        for frequency: Double
    ) -> Double {
        // The local acoustic calibration observes a complete display-to-speaker-
        // to-microphone loop. It cannot separate the Reference output residual
        // from the microphone/input timestamp component. Applying that full loop
        // as a Reference advance while Measure also applies its endpoint
        // correction double-corrects the same latency and drives direct phone-to-
        // phone tests strongly negative. Keep the saved loop result as a quality
        // and route-validation record, but do not apply it to Reference timing.
        _ = frequency
        return 0
    }

    func startCalibration() {
        guard runState == .idle || runState == .success || runState == .failure else {
            return
        }

        currentRunID = UUID()
        stopping = false
        progress = 0
        isAwaitingMicrophonePermission = false
        pendingActiveStartRunID = nil
        permissionReturnInProgress = false
        audioPreparationAttempt = 0
        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        setFlashActive(false)
        qualityText = ""
        headline = "Device Calibration"
        detail = "Checking the built-in speaker and microphone…"
        runState = .preparing

        #if targetEnvironment(simulator)
        fail("Calibration requires a physical iPhone or iPad.")
        #else
        requestMicrophonePermissionAndStart(runID: currentRunID)
        #endif
    }

    func cancelCalibration() {
        guard runState == .preparing || runState == .running else { return }
        stopCalibration(markFailure: false, finalMessage: nil)
        isAwaitingMicrophonePermission = false
        pendingActiveStartRunID = nil
        permissionReturnInProgress = false
        runState = .idle
        headline = "Device Calibration"
        detail = "Calibration cancelled"
        qualityText = ""
        progress = 0
        setFlashActive(false)
    }

    func resetPresentationState() {
        guard runState == .success || runState == .failure else { return }
        runState = .idle
        progress = 0
        setFlashActive(false)
        qualityText = ""
        headline = "Device Calibration"
        detail = "Ready"
    }

    private func requestMicrophonePermissionAndStart(runID: UUID) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            startWhenApplicationIsActive(runID: runID)

        case .notDetermined:
            isAwaitingMicrophonePermission = true
            detail = "Waiting for microphone permission…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.currentRunID == runID else { return }
                    self.isAwaitingMicrophonePermission = false
                    if granted {
                        self.permissionReturnInProgress = true
                        self.startWhenApplicationIsActive(runID: runID)
                    } else {
                        self.permissionReturnInProgress = false
                        self.fail(
                            "Microphone access is required for calibration."
                        )
                    }
                }
            }

        default:
            fail("Microphone access is required for calibration.")
        }
    }

    private func startWhenApplicationIsActive(runID: UUID) {
        guard currentRunID == runID, runState == .preparing else { return }

        guard UIApplication.shared.applicationState == .active else {
            pendingActiveStartRunID = runID
            detail = "Returning to calibration…"
            return
        }

        pendingActiveStartRunID = nil
        detail = "Preparing the built-in audio path…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.currentRunID == runID,
                  self.runState == .preparing else { return }
            guard UIApplication.shared.applicationState == .active else {
                self.pendingActiveStartRunID = runID
                self.detail = "Returning to calibration…"
                return
            }
            self.permissionReturnInProgress = false
            self.configureAndStartCalibration(runID: runID)
        }
    }

    private func resumeAfterPermissionIfNeeded() {
        guard let runID = pendingActiveStartRunID,
              currentRunID == runID,
              runState == .preparing else {
            return
        }
        pendingActiveStartRunID = nil
        startWhenApplicationIsActive(runID: runID)
    }

    private func configureAndStartCalibration(runID: UUID) {
        guard currentRunID == runID else { return }

        do {
            try configureCalibrationAudioSession()
        } catch {
            print("In.Sync calibration audio setup error: \(error)")
            fail("Unable to configure the built-in speaker and microphone.")
            return
        }

        guard strictBuiltInRouteIsActive() else {
            fail("Disconnect Bluetooth, AirPlay, headphones or external audio and try again.")
            return
        }

        // The matched dual-band signature remains detectable at low listening
        // levels. Only reject a nearly muted device rather than asking the user
        // to repeatedly chase an arbitrary volume threshold.
        if AVAudioSession.sharedInstance().outputVolume < 0.08 {
            fail("Turn the device volume up from mute and try again.")
            return
        }

        audioPreparationAttempt = 0
        prepareCalibrationAudioPath(runID: runID)
    }

    private func prepareCalibrationAudioPath(runID: UUID) {
        guard currentRunID == runID, runState == .preparing else { return }

        audioPreparationAttempt += 1
        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        resetCaptureState()
        calibrationEngine.shutdown()
        calibrationEngine = CalibrationDuplexEngine()

        do {
            try calibrationEngine.prepare { [weak self] chunk in
                guard let self else { return }
                self.analysisQueue.async {
                    guard self.currentRunID == runID else { return }
                    self.capturedAudio.append(chunk)
                }
            }
            try calibrationEngine.primeOutput()
        } catch {
            print("In.Sync calibration duplex engine error: \(error)")
            retryOrFailAudioPreparation(runID: runID)
            return
        }

        warmupDeadline = Date().addingTimeInterval(2.2)
        warmupStableChecks = 0
        detail = audioPreparationAttempt == 1
            ? "Warming the built-in audio path…"
            : "Stabilising the built-in audio path…"
        checkCalibrationAudioWarmup(runID: runID)
    }

    private func checkCalibrationAudioWarmup(runID: UUID) {
        guard currentRunID == runID, runState == .preparing else { return }

        let state = analysisQueue.sync { () -> (chunkCount: Int, span: Double) in
            guard let first = capturedAudio.first,
                  let last = capturedAudio.last else {
                return (capturedAudio.count, 0)
            }
            return (capturedAudio.count, max(0, last.endTime - first.startTime))
        }

        let session = AVAudioSession.sharedInstance()
        let routeStable = strictBuiltInRouteIsActive()
            && session.sampleRate > 0
            && session.ioBufferDuration > 0
            && calibrationEngine.isRunning

        if routeStable, state.chunkCount >= 8, state.span >= 0.55 {
            warmupStableChecks += 1
        } else {
            warmupStableChecks = 0
        }

        if warmupStableChecks >= 3 {
            warmupWorkItem = nil
            calibrationEngine.refreshPresentationLatency()
            resetCaptureState()
            beginPulseSequence(runID: runID)
            return
        }

        if Date() >= warmupDeadline {
            retryOrFailAudioPreparation(runID: runID)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.checkCalibrationAudioWarmup(runID: runID)
        }
        warmupWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: item)
    }

    private func retryOrFailAudioPreparation(runID: UUID) {
        guard currentRunID == runID, runState == .preparing else { return }

        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        calibrationEngine.shutdown()

        if audioPreparationAttempt < 3 {
            detail = "Restarting the built-in audio path automatically…"
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
            } catch {
                print("In.Sync calibration warm-up reset error: \(error)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self,
                      self.currentRunID == runID,
                      self.runState == .preparing else {
                    return
                }

                do {
                    try self.configureCalibrationAudioSession()
                } catch {
                    print("In.Sync calibration retry setup error: \(error)")
                    self.fail(
                        "The built-in audio path could not be prepared."
                    )
                    return
                }
                self.prepareCalibrationAudioPath(runID: runID)
            }
            return
        }

        fail(
            "The built-in audio path did not become ready. Close other audio apps and try once more."
        )
    }

    private func configureCalibrationAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)

        if let builtInMicrophone = session.availableInputs?.first(
            where: { $0.portType == .builtInMic }
        ) {
            try session.setPreferredInput(builtInMicrophone)
        }

        try session.setActive(true)
        try session.overrideOutputAudioPort(.speaker)
    }

    private func strictBuiltInRouteIsActive() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard !route.outputs.isEmpty, !route.inputs.isEmpty else { return false }

        let outputsAreBuiltIn = route.outputs.allSatisfy {
            $0.portType == .builtInSpeaker
        }
        let inputsAreBuiltIn = route.inputs.allSatisfy {
            $0.portType == .builtInMic
        }
        return outputsAreBuiltIn && inputsAreBuiltIn
    }

    private func beginPulseSequence(runID: UUID) {
        guard currentRunID == runID else { return }

        runState = .running
        headline = "Calibrating"
        detail = "Keep the lower speaker edge unobstructed"
        sequenceEstablished = false
        pulses.removeAll(keepingCapacity: true)
        visualEvents.removeAll(keepingCapacity: true)
        nextVisualPulseIndex = 0

        let link = CADisplayLink(
            target: self,
            selector: #selector(calibrationDisplayTick)
        )
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 120
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func establishSequence(from link: CADisplayLink) {
        guard !sequenceEstablished, runState == .running else { return }

        let measuredInterval = link.targetTimestamp - link.timestamp
        currentDisplayInterval = min(
            1.0 / 30.0,
            max(1.0 / 120.0, measuredInterval)
        )

        let leadFrames = ceil(0.90 / currentDisplayInterval)
        let firstTarget = link.targetTimestamp
            + (leadFrames * currentDisplayInterval)
        let spacingFrames = max(
            1,
            Int((0.84 / currentDisplayInterval).rounded())
        )
        let spacing = Double(spacingFrames) * currentDisplayInterval

        pulses = (0..<15).map { index in
            Pulse(
                targetHostTime: firstTarget + (Double(index) * spacing)
            )
        }

        do {
            try calibrationEngine.startSequence(
                visualHostTimes: pulses.map(\.targetHostTime)
            )
        } catch {
            print("In.Sync calibration sequence schedule error: \(error)")
            fail("The calibration signal could not be scheduled.")
            return
        }

        sequenceEstablished = true

        guard let lastPulse = pulses.last else { return }
        let delay = max(
            0,
            lastPulse.targetHostTime - CACurrentMediaTime() + 0.62
        )
        let scheduledRunID = currentRunID
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentRunID == scheduledRunID,
                  self.runState == .running else {
                return
            }
            self.finishCalibration(runID: scheduledRunID)
        }
        finishWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    @objc private func calibrationDisplayTick(_ link: CADisplayLink) {
        guard runState == .running else {
            setFlashActive(false)
            return
        }

        if !sequenceEstablished {
            establishSequence(from: link)
            return
        }

        guard let first = pulses.first, let last = pulses.last else { return }
        let presentationTime = link.targetTimestamp
        let tolerance = currentDisplayInterval * 0.35

        if nextVisualPulseIndex < pulses.count,
           presentationTime + tolerance
                >= pulses[nextVisualPulseIndex].targetHostTime {
            visualEvents.append(presentationTime)
            nextVisualPulseIndex += 1
            detail = "Calibration sample \(nextVisualPulseIndex) of \(pulses.count)"
        }

        let active = pulses.contains {
            presentationTime + tolerance >= $0.targetHostTime
                && presentationTime < $0.targetHostTime + flashDuration
        }
        setFlashActive(active)

        let total = max(
            0.1,
            last.targetHostTime - first.targetHostTime + flashDuration
        )
        let elapsed = presentationTime - first.targetHostTime
        progress = min(0.98, max(0, elapsed / total))
    }

    private func setFlashActive(_ active: Bool) {
        guard flashActive != active else { return }
        flashActive = active
        flashPresenter?.setCalibrationFlashVisible(active)
    }

    private func finishCalibration(runID: UUID) {
        guard currentRunID == runID, runState == .running else { return }

        detail = "Checking the 15 calibration samples…"
        finishWorkItem?.cancel()
        finishWorkItem = nil
        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        isAwaitingMicrophonePermission = false
        pendingActiveStartRunID = nil
        permissionReturnInProgress = false
        displayLink?.invalidate()
        displayLink = nil
        setFlashActive(false)
        calibrationEngine.shutdown()

        let visualSnapshot = visualEvents
        let factoryCorrection = serviceMeasureCorrectionMilliseconds
        let systemVersion = UIDevice.current.systemVersion

        analysisQueue.async { [weak self] in
            guard let self, self.currentRunID == runID else { return }
            let audioSnapshot = self.capturedAudio
            let result = self.buildCalibrationRecord(
                visualEvents: visualSnapshot,
                audioChunks: audioSnapshot,
                systemVersion: systemVersion,
                factoryCorrectionMilliseconds: factoryCorrection
            )

            DispatchQueue.main.async {
                guard self.currentRunID == runID else { return }
                self.deactivateCalibrationAudioSession()

                switch result {
                case .success(let record):
                    guard self.save(record) else { return }
                    self.progress = 1
                    self.runState = .success
                    self.headline = "Calibration Saved"
                    self.detail = "In.Sync will apply this calibration automatically"
                    let stableSamples = record.frequencies.first?.sampleCount ?? 0
                    self.qualityText = String(
                        format: "Quality %.0f%% • %d stable samples",
                        record.quality * 100,
                        stableSamples
                    )

                case .failure(let message):
                    self.markFailure(message)
                }
            }
        }
    }

    private func resetCaptureState() {
        analysisQueue.sync {
            capturedAudio.removeAll(keepingCapacity: true)
        }
        visualEvents.removeAll(keepingCapacity: true)
        pulses.removeAll(keepingCapacity: true)
        nextVisualPulseIndex = 0
        sequenceEstablished = false
    }

    private enum CalibrationBuildResult {
        case success(DeviceCalibrationRecord)
        case failure(String)
    }

    private struct SignatureDetection {
        let time: Double
        let signalToNoiseRatio: Double
    }

    private struct MatchedSample {
        let residualMilliseconds: Double
        let signalToNoiseRatio: Double
    }

    private func buildCalibrationRecord(
        visualEvents: [Double],
        audioChunks: [CapturedCalibrationAudio],
        systemVersion: String,
        factoryCorrectionMilliseconds: Double
    ) -> CalibrationBuildResult {
        let orderedVisuals = visualEvents.filter(\.isFinite).sorted()
        guard orderedVisuals.count >= 10 else {
            return .failure("The display sequence was interrupted. Try calibration once more.")
        }

        let totalAudioDuration = audioChunks.reduce(0.0) {
            $0 + (Double($1.samples.count) / max(1.0, $1.sampleRate))
        }
        guard totalAudioDuration >= 7.0 else {
            return .failure("The built-in microphone stream was interrupted. Try calibration once more.")
        }

        var matches: [MatchedSample] = []
        for visualTime in orderedVisuals.prefix(15) {
            guard let detection = signatureDetection(
                visualTime: visualTime,
                chunks: audioChunks
            ) else {
                continue
            }

            let residual = (detection.time - visualTime) * 1000.0
            guard residual >= -60.0, residual <= 320.0 else { continue }
            matches.append(
                MatchedSample(
                    residualMilliseconds: residual,
                    signalToNoiseRatio: detection.signalToNoiseRatio
                )
            )
        }

        guard matches.count >= 5 else {
            return .failure(
                "Only \(matches.count) of 15 calibration pulses were detected. Make sure the lower speaker edge is unobstructed and try again."
            )
        }

        let initialMedian = median(matches.map(\.residualMilliseconds))
        let initialMAD = median(
            matches.map { abs($0.residualMilliseconds - initialMedian) }
        )
        let outlierLimit = max(18.0, min(55.0, initialMAD * 4.5))
        let retained = matches.filter {
            abs($0.residualMilliseconds - initialMedian) <= outlierLimit
        }

        guard retained.count >= 5 else {
            return .failure(
                "Only \(retained.count) consistent calibration pulses remained after rejecting interference. Try calibration once more."
            )
        }

        let correction = median(retained.map(\.residualMilliseconds))
        let absoluteDeviations = retained
            .map { abs($0.residualMilliseconds - correction) }
            .sorted()
        let jitter = median(absoluteDeviations)
        let tailIndex = min(
            absoluteDeviations.count - 1,
            max(0, Int(ceil(Double(absoluteDeviations.count) * 0.90)) - 1)
        )
        let tailDeviation = absoluteDeviations[tailIndex]

        // A robust median remains useful with display cadence and acoustic onset
        // variation. Reject only clearly broken runs; moderate variation lowers
        // quality and produces a yellow status rather than another needless
        // hard failure.
        guard jitter <= 45.0, tailDeviation <= 95.0 else {
            return .failure(
                "The calibration timing was interrupted. Close other active audio apps and try once more."
            )
        }

        let detectionRatio = min(1.0, Double(retained.count) / 15.0)
        let jitterScore = max(0.0, 1.0 - (jitter / 28.0))
        let tailScore = max(0.0, 1.0 - (tailDeviation / 60.0))
        let medianSNR = median(retained.map(\.signalToNoiseRatio))
        let snrScore = min(1.0, max(0.0, (medianSNR - 1.15) / 3.0))
        let quality = min(
            0.99,
            max(
                0.35,
                (detectionRatio * 0.48)
                    + (jitterScore * 0.27)
                    + (tailScore * 0.15)
                    + (snrScore * 0.10)
            )
        )

        let frequencyResults = [1000.0, 2000.0, 4000.0].map { frequency in
            FrequencyCalibration(
                frequency: frequency,
                digitalAudioMinusVideoMilliseconds: nil,
                speakerMinusDigitalAudioMilliseconds: nil,
                referenceResidualMilliseconds: correction,
                sampleCount: retained.count,
                jitterMilliseconds: jitter
            )
        }

        return .success(
            DeviceCalibrationRecord(
                algorithmVersion: Self.algorithmVersion,
                deviceModel: Self.deviceModelIdentifier(),
                systemVersion: systemVersion,
                createdAt: Date(),
                quality: quality,
                factoryMeasureCorrectionMilliseconds:
                    factoryCorrectionMilliseconds,
                frequencies: frequencyResults
            )
        )
    }

    private func signatureDetection(
        visualTime: Double,
        chunks: [CapturedCalibrationAudio]
    ) -> SignatureDetection? {
        let searchStart = visualTime - 0.080
        let searchEnd = visualTime + 0.310
        let overlapping = chunks.filter {
            $0.endTime > searchStart && $0.startTime < searchEnd
        }
        guard let first = overlapping.first, first.sampleRate > 0 else {
            return nil
        }

        let sampleRate = first.sampleRate
        let sampleCount = max(
            1,
            Int(ceil((searchEnd - searchStart) * sampleRate))
        )
        var merged = [Float](repeating: 0, count: sampleCount)
        var coverage = [UInt8](repeating: 0, count: sampleCount)

        for chunk in overlapping {
            guard abs(chunk.sampleRate - sampleRate) <= 1.0 else { continue }
            let destinationStart = Int(
                ((chunk.startTime - searchStart) * sampleRate).rounded()
            )

            for sourceIndex in chunk.samples.indices {
                let destinationIndex = destinationStart + sourceIndex
                guard destinationIndex >= 0,
                      destinationIndex < sampleCount else {
                    continue
                }
                merged[destinationIndex] = chunk.samples[sourceIndex]
                coverage[destinationIndex] = 1
            }
        }

        let coveredCount = coverage.reduce(0) { $0 + Int($1) }
        guard Double(coveredCount) / Double(sampleCount) >= 0.68 else {
            return nil
        }

        let window = max(256, Int((sampleRate * 0.010).rounded()))
        let hop = max(32, Int((sampleRate * 0.001).rounded()))
        guard window < merged.count else { return nil }

        struct EnvelopePoint {
            let time: Double
            let amplitude: Double
        }

        var envelope: [EnvelopePoint] = []
        var index = 0
        while index + window <= merged.count {
            let covered = coverage[index..<(index + window)].reduce(0) {
                $0 + Int($1)
            }
            if Double(covered) / Double(window) >= 0.82 {
                let amplitude = CalibrationSignature.frequencies
                    .map {
                        windowedToneAmplitude(
                            samples: merged,
                            startIndex: index,
                            length: window,
                            frequency: $0,
                            sampleRate: sampleRate
                        )
                    }
                    .reduce(0.0) { $0 + ($1 * $1) }
                    .squareRoot()

                envelope.append(
                    EnvelopePoint(
                        time: searchStart
                            + (Double(index + (window / 2)) / sampleRate),
                        amplitude: amplitude
                    )
                )
            }
            index += hop
        }

        let baselineValues = envelope
            .filter {
                $0.time >= visualTime - 0.070
                    && $0.time <= visualTime - 0.015
            }
            .map(\.amplitude)
        let searchValues = envelope.filter {
            $0.time >= visualTime - 0.020
                && $0.time <= visualTime + 0.255
        }

        guard baselineValues.count >= 5,
              searchValues.count >= 10,
              let peak = searchValues.max(
                by: { $0.amplitude < $1.amplitude }
              ) else {
            return nil
        }

        let baseline = median(baselineValues)
        let baselineMAD = median(
            baselineValues.map { abs($0 - baseline) }
        )
        let dynamicRange = peak.amplitude - baseline
        let noiseReference = max(
            0.00005,
            baseline + (baselineMAD * 2.5)
        )
        let signalToNoise = peak.amplitude / noiseReference

        guard dynamicRange >= max(0.00008, baselineMAD * 2.8),
              signalToNoise >= 1.30 else {
            return nil
        }

        let threshold = baseline + max(
            dynamicRange * 0.16,
            baselineMAD * 3.5,
            0.00004
        )

        for pointIndex in searchValues.indices {
            let endIndex = pointIndex + 1
            guard endIndex < searchValues.count else { break }
            guard searchValues[pointIndex].amplitude >= threshold,
                  searchValues[endIndex].amplitude >= threshold else {
                continue
            }

            let previous = pointIndex > 0
                ? searchValues[pointIndex - 1]
                : searchValues[pointIndex]
            let current = searchValues[pointIndex]
            let denominator = current.amplitude - previous.amplitude
            let fraction: Double
            if abs(denominator) > 0.0000001 {
                fraction = min(
                    1.0,
                    max(0.0, (threshold - previous.amplitude) / denominator)
                )
            } else {
                fraction = 0
            }
            let interpolatedTime = previous.time
                + ((current.time - previous.time) * fraction)

            return SignatureDetection(
                time: interpolatedTime,
                signalToNoiseRatio: signalToNoise
            )
        }

        // A gradual acoustic rise can miss the two-window rule. A lower
        // single-window crossing is safer than estimating onset backwards from
        // an arbitrary peak somewhere on the tone plateau.
        let relaxedThreshold = baseline + max(
            dynamicRange * 0.08,
            baselineMAD * 2.5,
            0.00003
        )
        if signalToNoise >= 1.8,
           let relaxed = searchValues.first(
               where: { $0.amplitude >= relaxedThreshold }
           ) {
            return SignatureDetection(
                time: relaxed.time,
                signalToNoiseRatio: signalToNoise
            )
        }

        return nil
    }

    private func windowedToneAmplitude(
        samples: [Float],
        startIndex: Int,
        length: Int,
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        guard length > 1 else { return 0 }
        var weightedMean = 0.0
        var weightTotal = 0.0

        for offset in 0..<length {
            let weight = 0.5
                - (0.5 * cos((2.0 * .pi * Double(offset)) / Double(length - 1)))
            weightedMean += Double(samples[startIndex + offset]) * weight
            weightTotal += weight
        }
        weightedMean /= max(1.0, weightTotal)

        let phaseStep = 2.0 * .pi * frequency / sampleRate
        var inPhase = 0.0
        var quadrature = 0.0

        for offset in 0..<length {
            let weight = 0.5
                - (0.5 * cos((2.0 * .pi * Double(offset)) / Double(length - 1)))
            let value = (Double(samples[startIndex + offset]) - weightedMean) * weight
            let phase = phaseStep * Double(offset)
            inPhase += value * cos(phase)
            quadrature += value * sin(phase)
        }

        return 2.0 * hypot(inPhase, quadrature) / max(1.0, weightTotal)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    @discardableResult
    private func save(_ record: DeviceCalibrationRecord) -> Bool {
        do {
            let data = try JSONEncoder().encode(record)
            defaults.set(data, forKey: recordKey)
            defaults.set(false, forKey: failureKey)
            self.record = record
            refreshIndicator()
            return true
        } catch {
            print("In.Sync calibration persistence error: \(error)")
            markFailure("Calibration completed but could not be saved.")
            return false
        }
    }

    private func loadSavedRecord() {
        let candidateKeys = [recordKey] + legacyRecordKeys
        let savedData = candidateKeys.compactMap {
            defaults.data(forKey: $0)
        }.first

        if let savedData {
            do {
                record = try JSONDecoder().decode(
                    DeviceCalibrationRecord.self,
                    from: savedData
                )
            } catch {
                print("In.Sync saved calibration decode error: \(error)")
                record = nil
            }
        }

        if defaults.object(forKey: serviceCorrectionKey) != nil {
            serviceMeasureCorrectionMilliseconds = defaults.double(
                forKey: serviceCorrectionKey
            )
        } else if let record {
            serviceMeasureCorrectionMilliseconds =
                record.factoryMeasureCorrectionMilliseconds
        } else {
            serviceMeasureCorrectionMilliseconds =
                Self.defaultFactoryMeasureCorrectionMilliseconds(
                    for: Self.deviceModelIdentifier()
                )
        }
        refreshIndicator()
    }

    private func refreshIndicator() {
        let lastFailed = defaults.bool(forKey: failureKey)
        if lastFailed {
            indicatorState = .failed
            return
        }

        guard let record else {
            indicatorState = .none
            return
        }

        let exactAlgorithm = record.algorithmVersion == Self.algorithmVersion
        let exactDevice = record.deviceModel == Self.deviceModelIdentifier()
        let sameMajorOS = Self.majorVersion(record.systemVersion)
            == Self.majorVersion(UIDevice.current.systemVersion)
        let routeLooksBuiltIn = currentRouteLooksBuiltIn()
        let recentEnough = Date().timeIntervalSince(record.createdAt)
            <= Self.calibrationRepeatInterval
        let qualityIsStrong = record.quality >= 0.55

        indicatorState = exactAlgorithm
            && exactDevice
            && sameMajorOS
            && routeLooksBuiltIn
            && recentEnough
            && qualityIsStrong
            ? .valid
            : .questionable
    }

    private var recordMatchesCurrentDeviceAndSoftware: Bool {
        guard let record else { return false }
        return record.algorithmVersion == Self.algorithmVersion
            && record.deviceModel == Self.deviceModelIdentifier()
            && Self.majorVersion(record.systemVersion)
                == Self.majorVersion(UIDevice.current.systemVersion)
            && record.quality >= 0.35
    }

    private func currentRouteLooksBuiltIn() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute

        let outputsAcceptable = route.outputs.isEmpty || route.outputs.allSatisfy {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
        let inputsAcceptable = route.inputs.isEmpty || route.inputs.allSatisfy {
            $0.portType == .builtInMic
        }
        return outputsAcceptable && inputsAcceptable
    }

    private func fail(_ message: String) {
        stopCalibration(markFailure: true, finalMessage: message)
    }

    private func markFailure(_ message: String) {
        defaults.set(true, forKey: failureKey)
        runState = .failure
        headline = "Calibration Failed"
        detail = message
        qualityText = record == nil
            ? "No calibration was saved"
            : "Previous saved calibration retained"
        progress = 0
        setFlashActive(false)
        refreshIndicator()
    }

    private func stopCalibration(
        markFailure shouldMarkFailure: Bool,
        finalMessage: String?
    ) {
        guard !stopping else { return }
        stopping = true
        currentRunID = UUID()
        finishWorkItem?.cancel()
        finishWorkItem = nil
        warmupWorkItem?.cancel()
        warmupWorkItem = nil
        isAwaitingMicrophonePermission = false
        pendingActiveStartRunID = nil
        permissionReturnInProgress = false
        displayLink?.invalidate()
        displayLink = nil
        setFlashActive(false)
        calibrationEngine.shutdown()
        deactivateCalibrationAudioSession()
        stopping = false

        if shouldMarkFailure, let finalMessage {
            self.markFailure(finalMessage)
        }
    }

    private func deactivateCalibrationAudioSession() {
        calibrationEngine.shutdown()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            print("In.Sync calibration audio shutdown error: \(error)")
        }
        refreshIndicator()
    }

    private static func majorVersion(_ value: String) -> Int {
        Int(value.split(separator: ".").first ?? "0") ?? 0
    }

    private static func defaultFactoryMeasureCorrectionMilliseconds(
        for deviceModel: String
    ) -> Double {
        let modelOverrides: [String: Double] = [:]
        return modelOverrides[deviceModel]
            ?? factoryMeasureCorrectionMilliseconds
    }

    private static func deviceModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}

private struct CapturedCalibrationAudio {
    let samples: [Float]
    let sampleRate: Double
    let startTime: Double

    var endTime: Double {
        startTime + (Double(samples.count) / max(1.0, sampleRate))
    }
}

private enum CalibrationSignature {
    static let frequencies = [1600.0, 2800.0]
    static let duration = 0.145
    static let fadeDuration = 0.006
}

private final class CalibrationDuplexEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerAttached = false
    private var inputTapped = false
    private var outputFormat: AVAudioFormat?
    private var presentationLatency = 0.0

    var isRunning: Bool {
        engine.isRunning
    }

    func prepare(
        captureHandler: @escaping (CapturedCalibrationAudio) -> Void
    ) throws {
        let session = AVAudioSession.sharedInstance()
        let sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000

        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw CalibrationDuplexError.formatUnavailable
        }
        self.outputFormat = outputFormat

        if playerAttached {
            engine.disconnectNodeOutput(player)
        } else {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CalibrationDuplexError.inputUnavailable
        }

        if inputTapped {
            input.removeTap(onBus: 0)
            inputTapped = false
        }

        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { buffer, when in
            guard when.isHostTimeValid, when.hostTime != 0,
                  let samples = Self.copyMonoSamples(from: buffer) else {
                return
            }

            let startTime = AVAudioTime.seconds(forHostTime: when.hostTime)
            guard startTime.isFinite else { return }
            captureHandler(
                CapturedCalibrationAudio(
                    samples: samples,
                    sampleRate: buffer.format.sampleRate,
                    startTime: startTime
                )
            )
        }
        inputTapped = true

        engine.prepare()
        try engine.start()

        refreshPresentationLatency()
    }

    func primeOutput() throws {
        guard let outputFormat else {
            throw CalibrationDuplexError.bufferUnavailable
        }

        let frames = AVAudioFrameCount(
            max(256, Int((outputFormat.sampleRate * 0.24).rounded()))
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frames
        ), let samples = buffer.floatChannelData?[0] else {
            throw CalibrationDuplexError.bufferUnavailable
        }

        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            samples[frame] = 0
        }

        player.stop()
        player.volume = 1.0
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    func refreshPresentationLatency() {
        let session = AVAudioSession.sharedInstance()
        presentationLatency = max(
            player.outputPresentationLatency,
            engine.outputNode.presentationLatency,
            session.outputLatency + (session.ioBufferDuration * 0.5)
        )
    }

    func startSequence(visualHostTimes: [Double]) throws {
        guard let outputFormat,
              let first = visualHostTimes.first,
              let last = visualHostTimes.last,
              !visualHostTimes.isEmpty else {
            throw CalibrationDuplexError.bufferUnavailable
        }

        let totalDuration = max(
            CalibrationSignature.duration,
            (last - first) + CalibrationSignature.duration
        )
        let totalFrames = AVAudioFrameCount(
            ceil(totalDuration * outputFormat.sampleRate)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: totalFrames
        ),
        let samples = buffer.floatChannelData?[0] else {
            throw CalibrationDuplexError.bufferUnavailable
        }

        buffer.frameLength = totalFrames
        for frame in 0..<Int(totalFrames) {
            samples[frame] = 0
        }

        let signatureFrames = Int(
            (CalibrationSignature.duration * outputFormat.sampleRate).rounded()
        )
        let fade = CalibrationSignature.fadeDuration

        for visualTime in visualHostTimes {
            let startFrame = Int(
                ((visualTime - first) * outputFormat.sampleRate).rounded()
            )

            for localFrame in 0..<signatureFrames {
                let destination = startFrame + localFrame
                guard destination >= 0, destination < Int(totalFrames) else {
                    continue
                }

                let time = Double(localFrame) / outputFormat.sampleRate
                let remaining = CalibrationSignature.duration - time
                let attackPhase = min(1.0, max(0.0, time / fade))
                let releasePhase = min(1.0, max(0.0, remaining / fade))
                let attack = 0.5 - (0.5 * cos(.pi * attackPhase))
                let release = 0.5 - (0.5 * cos(.pi * releasePhase))
                let envelope = min(attack, release)

                let tone = CalibrationSignature.frequencies.reduce(0.0) {
                    $0 + sin(2.0 * .pi * $1 * time)
                } / Double(CalibrationSignature.frequencies.count)
                samples[destination] += Float(tone * 0.82 * envelope)
            }
        }

        player.stop()
        player.volume = 1.0
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)

        let renderStart = first - presentationLatency
        player.play(
            at: AVAudioTime(
                hostTime: AVAudioTime.hostTime(forSeconds: renderStart)
            )
        )
    }

    func shutdown() {
        player.stop()
        if inputTapped {
            engine.inputNode.removeTap(onBus: 0)
            inputTapped = false
        }
        engine.stop()
    }

    private static func copyMonoSamples(
        from buffer: AVAudioPCMBuffer
    ) -> [Float]? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        let stride = Int(buffer.stride)
        var result = [Float](repeating: 0, count: frames)

        if let channelData = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let data = channelData[0]
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += data[(frame * stride) + channel]
                    }
                    result[frame] = sum / Float(channels)
                }
            } else {
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += channelData[channel][frame * stride]
                    }
                    result[frame] = sum / Float(channels)
                }
            }
            return result
        }

        if let channelData = buffer.int16ChannelData {
            if buffer.format.isInterleaved {
                let data = channelData[0]
                for frame in 0..<frames {
                    var sum = 0.0
                    for channel in 0..<channels {
                        sum += Double(data[(frame * stride) + channel]) / 32_768.0
                    }
                    result[frame] = Float(sum / Double(channels))
                }
            } else {
                for frame in 0..<frames {
                    var sum = 0.0
                    for channel in 0..<channels {
                        sum += Double(channelData[channel][frame * stride]) / 32_768.0
                    }
                    result[frame] = Float(sum / Double(channels))
                }
            }
            return result
        }

        if let channelData = buffer.int32ChannelData {
            if buffer.format.isInterleaved {
                let data = channelData[0]
                for frame in 0..<frames {
                    var sum = 0.0
                    for channel in 0..<channels {
                        sum += Double(data[(frame * stride) + channel])
                            / 2_147_483_648.0
                    }
                    result[frame] = Float(sum / Double(channels))
                }
            } else {
                for frame in 0..<frames {
                    var sum = 0.0
                    for channel in 0..<channels {
                        sum += Double(channelData[channel][frame * stride])
                            / 2_147_483_648.0
                    }
                    result[frame] = Float(sum / Double(channels))
                }
            }
            return result
        }

        return nil
    }
}

private enum CalibrationDuplexError: Error {
    case formatUnavailable
    case inputUnavailable
    case bufferUnavailable
}
