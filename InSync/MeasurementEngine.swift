import Foundation
import Combine
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

/// Captures camera frames with AVFoundation and microphone PCM with an
/// AVAudioEngine input tap, converts both streams onto the same host-time
/// timeline, detects the reference flash and tone pip, and correlates only
/// lightweight events on a third serial queue.
final class MeasurementEngine: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var offsetMilliseconds: Double?
    @Published var statusText = "Ready"
    @Published var acceptedMeasurements = 0
    struct LensOption: Identifiable {
        let id: String
        let zoom: Double?

        var title: String {
            guard let zoom else { return "Tele" }
            return String(format: "%.1fx", zoom)
        }
    }

    @Published private(set) var availableLenses: [LensOption] = []
    @Published private(set) var selectedLensID: String?
    @Published private(set) var previewCamera: AVCaptureDevice?

    // Owned by correlationQueue. Set once, after selecting the audio route.
    private var deviceCorrectionMilliseconds = 0.0

    private final class Run {
        let requestedCorrection: Double
        private let lock = NSLock()
        private var cancelled = false

        init(requestedCorrection: Double) {
            self.requestedCorrection = requestedCorrection
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private let sessionQueue = DispatchQueue(
        label: "au.h-v.in.sync.measure.session",
        qos: .userInitiated
    )

    // Keep camera and microphone processing independent. Video callbacks must
    // never wait behind the heavier tone detector or the short reference flash
    // can be discarded before it reaches the app. Only small detection events
    // cross onto the correlation queue, which owns pairing and estimation.
    private let videoQueue = DispatchQueue(
        label: "au.h-v.in.sync.measure.video",
        qos: .userInteractive
    )

    private let audioQueue = DispatchQueue(
        label: "au.h-v.in.sync.measure.audio",
        qos: .userInitiated
    )

    private let correlationQueue = DispatchQueue(
        label: "au.h-v.in.sync.measure.correlation",
        qos: .userInitiated
    )

    private let captureSession = AVCaptureSession()

    var previewSession: AVCaptureSession {
        captureSession
    }

    private var configured = false
    private var startRequested = false
    private var ownsAudioSession = false
    // Main-queue lifecycle. Capture work carries its own cancellable run.
    private var activeRun: Run?
    private var stopping = false
    private(set) var isHandlingPermissionTransition = false
    private let analysisStateLock = NSLock()
    private let microphoneStateLock = NSLock()
    private var analysisEnabled = false
    private var demoTimer: Timer?
    private var captureSessionObservers: [NSObjectProtocol] = []

    private var installedVideoOutput: AVCaptureVideoDataOutput?
    private var videoOutput: AVCaptureVideoDataOutput? {
        get { analysisStateLock.withLock { installedVideoOutput } }
        set { analysisStateLock.withLock { installedVideoOutput = newValue } }
    }
    private var cameraInput: AVCaptureDeviceInput?
    private var frameRate = 60.0
    private var actualVideoFrameRate: Double {
        get { analysisStateLock.withLock { frameRate } }
        set { analysisStateLock.withLock { frameRate = newValue } }
    }
    private var videoIgnoreUntilHostTime = 0.0
    private var rearLensDevices: [AVCaptureDevice] = []
    private var defaultWideCamera: AVCaptureDevice?

    // Use AVAudioEngine for microphone analysis. Apple uses an input-node tap
    // for real-time microphone analysis; this delivers a typed AVAudioPCMBuffer
    // and avoids the unverified manual CMSampleBuffer PCM decoder that failed to
    // recognise real iPhone speaker tones in the previous builds.
    private var microphoneEngine = AVAudioEngine()
    private var microphoneTapInstalled = false
    private var microphoneGeneration = 0
    private var microphoneBufferCount = 0
    private var lastMicrophoneBufferHostTime: Double?
    private var microphoneWatchdog: DispatchWorkItem?
    private var microphoneRestartAttempts = 0

    // MARK: - Video detector state

    private struct PendingVideoPulse {
        let onsetTime: Double
        var peakLevel: Double
        var peakBrightFraction: Double
        var peakRiseFraction: Double
        var frameCount: Int
    }

    private var videoBaseline = 0.20
    private var previousVideoLevel = 0.20
    private var previousVideoTime: Double?
    private var videoWarmupStartTime: Double?
    private var videoWarmupLevels: [Double] = []
    private var videoWarmupBrightFractions: [Double] = []
    private var previousBrightFraction = 0.0
    private var videoBaselineBrightFraction = 0.0
    private var previousLumaSamples: [UInt8] = []
    private var pendingVideoPulse: PendingVideoPulse?
    private var previousVideoDetectionTime = -10.0

    // MARK: - Audio detector state

    private var audioSamples: [Float] = []
    private var audioReadIndex = 0
    private var audioBufferStartTime = 0.0
    private var expectedNextAudioTime: Double?
    private var detectorSampleRate = 0.0
    private var detectorWindowSize = 0
    private var detectorHopSize = 0
    private var hannWindow: [Double] = []

    private let supportedToneFrequencies = [1000.0, 2000.0, 4000.0]
    private var toneNoiseFloor = [0.00005, 0.00005, 0.00005]
    private var audioNoiseRMS = 0.00005
    private var audioWarmupStartTime: Double?
    private var audioWarmupComplete = false
    private var audioWarmupRMSValues: [Double] = []
    private var toneWarmupAmplitudes = [[Double](), [Double](), [Double]()]
    private var toneArmed = true
    private var toneReleaseWindows = 0
    private var toneCandidateFrequency = 0.0
    private var toneCandidateCount = 0
    private var toneCandidateStartIndex = 0
    private var previousAudioDetectionTime = -10.0
    private var latestAudioRMS = 0.0
    private var latestToneRatio = 0.0
    private var audioStreamSeen = false

    // MARK: - Correlation and robust estimate

    private struct DetectionEvent {
        let time: Double
        let confidence: Double
    }

    private var videoEvents: [DetectionEvent] = []
    private var audioEvents: [DetectionEvent] = []
    private var acquisitionCandidates: [Double] = []
    private var acceptedValues: [Double] = []
    private var challengerValues: [Double] = []
    private var stableEstimate: Double?
    private var totalAcceptedMeasurements = 0
    private var lastVideoEventTime: Double?
    private var lastAudioEventTime: Double?
    private var unmatchedVideoEvents = 0
    private var unmatchedAudioEvents = 0

    // MARK: - Public control

    override init() {
        super.init()

        let notificationCenter = NotificationCenter.default

        captureSessionObservers.append(
            notificationCenter.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: captureSession,
                queue: .main
            ) { [weak self] notification in
                if let error = notification.userInfo?[AVCaptureSessionErrorKey]
                    as? Error {
                    print("In.Sync capture runtime error: \(error)")
                }
                self?.stop(
                    withStatus: "Capture error • press Start",
                    resetConfiguration: true
                )
            }
        )

        captureSessionObservers.append(
            notificationCenter.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: captureSession,
                queue: .main
            ) { [weak self] _ in
                self?.stop(withStatus: "Capture interrupted • press Start")
            }
        )

        captureSessionObservers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    self.isRunning,
                    let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: rawType),
                    type == .began
                else {
                    return
                }

                self.stop(withStatus: "Audio interrupted • press Start")
            }
        )

        captureSessionObservers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.stop(withStatus: "Audio route changed • press Start")
            }
        )

        captureSessionObservers.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.stop(
                    withStatus: "Audio reset • press Start",
                    resetConfiguration: true
                )
            }
        )
    }

    deinit {
        let notificationCenter = NotificationCenter.default
        for observer in captureSessionObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    func start(correctionMilliseconds: Double) {
        guard activeRun == nil, !stopping else { return }
        let run = Run(requestedCorrection: correctionMilliseconds)
        activeRun = run

        #if targetEnvironment(simulator)
        startPreviewDemo()
        #else
        requestPermissionsAndStart(for: run)
        #endif
    }

    func stop(completion: (() -> Void)? = nil) {
        stop(withStatus: "Stopped")
        guard let completion else { return }
        if stopping {
            // Wait for the camera and the shared audio session to be released
            // before the UI hands the hardware to Reference or calibration.
            sessionQueue.async { DispatchQueue.main.async { completion() } }
        } else {
            completion()
        }
    }

    private func stop(
        withStatus finalStatus: String,
        resetConfiguration: Bool = false
    ) {
        guard let run = activeRun else {
            if resetConfiguration {
                sessionQueue.async { self.clearCaptureConfiguration() }
            }
            return
        }
        run.cancel()
        activeRun = nil
        stopping = true
        isHandlingPermissionTransition = false
        demoTimer?.invalidate()
        demoTimer = nil

        sessionQueue.async {
            self.startRequested = false

            self.setAnalysisEnabled(false)

            self.stopMicrophoneCapture()

            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }

            if resetConfiguration {
                self.clearCaptureConfiguration()
            }

            self.videoQueue.sync {
                self.resetVideoState()
            }
            self.audioQueue.sync {
                self.resetAudioState()
            }
            self.correlationQueue.sync {
                self.resetCorrelationState()
            }

            self.releaseAudioSession()

            DispatchQueue.main.async {
                self.stopping = false
                self.isRunning = false
                self.previewCamera = nil
                self.statusText = finalStatus
            }
        }
    }

    // Called on sessionQueue with capture stopped.
    private func clearCaptureConfiguration() {
        captureSession.beginConfiguration()
        for input in captureSession.inputs { captureSession.removeInput(input) }
        for output in captureSession.outputs { captureSession.removeOutput(output) }
        captureSession.commitConfiguration()
        configured = false
        videoOutput = nil
        cameraInput = nil
        rearLensDevices = []
        defaultWideCamera = nil
        DispatchQueue.main.async {
            self.availableLenses = []
            self.selectedLensID = nil
        }
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("In.Sync measurement audio shutdown error: \(error)")
        }
    }

    // MARK: - Permissions and capture configuration

    private func startPreviewDemo() {
        isRunning = true
        statusText = "LIVE • PREVIEW DEMO"
        offsetMilliseconds = 84
        acceptedMeasurements = 3
        availableLenses = [LensOption(id: "demo-ultra", zoom: 0.5),
                           LensOption(id: "demo-wide", zoom: 1.0),
                           LensOption(id: "demo-tele", zoom: 3.0)]
        selectedLensID = "demo-wide"

        var phase = 0.0

        demoTimer = Timer.scheduledTimer(
            withTimeInterval: 0.12,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            phase += 0.14
            self.offsetMilliseconds = 84 + sin(phase) * 2
        }
    }

    private func requestPermissionsAndStart(for run: Run) {
        let needsCameraPrompt =
            AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        let needsMicrophonePrompt =
            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        let needsPermissionPrompt = needsCameraPrompt || needsMicrophonePrompt

        isHandlingPermissionTransition = needsPermissionPrompt
        statusText = "Requesting camera + microphone…"

        let group = DispatchGroup()

        if needsCameraPrompt {
            group.enter()
            AVCaptureDevice.requestAccess(for: .video) { _ in
                group.leave()
            }
        }

        if needsMicrophonePrompt {
            group.enter()
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard self.activeRun === run else { return }
            let cameraGranted =
                AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            let microphoneGranted =
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

            guard cameraGranted && microphoneGranted else {
                self.isHandlingPermissionTransition = false
                self.activeRun = nil
                self.statusText = "Camera + microphone access is required"
                return
            }

            self.startWhenApplicationIsActive(for: run, afterPermissionPrompt: needsPermissionPrompt)
        }
    }

    private func startWhenApplicationIsActive(
        for run: Run,
        afterPermissionPrompt: Bool,
        retryCount: Int = 0
    ) {
        guard activeRun === run else { return }

        guard UIApplication.shared.applicationState == .active else {
            guard retryCount < 40 else {
                isHandlingPermissionTransition = false
                activeRun = nil
                statusText = "Camera start interrupted • press Start"
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                self.startWhenApplicationIsActive(
                    for: run,
                    afterPermissionPrompt: afterPermissionPrompt,
                    retryCount: retryCount + 1
                )
            }
            return
        }

        let settleDelay = afterPermissionPrompt ? 0.35 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            guard self.activeRun === run else { return }
            guard UIApplication.shared.applicationState == .active else {
                self.startWhenApplicationIsActive(
                    for: run,
                    afterPermissionPrompt: afterPermissionPrompt,
                    retryCount: retryCount + 1
                )
                return
            }

            self.isHandlingPermissionTransition = false
            self.sessionQueue.async {
                guard !run.isCancelled else { return }
                self.startRequested = true
                self.configureAndStartCapture(for: run)
            }
        }
    }

    private func configureAndStartCapture(for run: Run) {
        let correction: Double
        do {
            correction = try configureMeasurementAudioSession(requestedCorrection: run.requestedCorrection)

            if !configured {
                try configureCaptureSession()
                configured = true
            }

            try resetLensToDefaultForRun()
        } catch {
            startRequested = false
            setAnalysisEnabled(false)

            releaseAudioSession()

            DispatchQueue.main.async {
                guard self.activeRun === run else { return }
                self.activeRun = nil
                self.statusText = "Unable to configure camera + microphone"
            }
            print("In.Sync measurement configuration error: \(error)")
            return
        }

        guard !run.isCancelled else { return }

        videoQueue.sync {
            resetVideoState()
        }
        audioQueue.sync {
            resetAudioState()
        }
        correlationQueue.sync {
            resetCorrelationState()
            deviceCorrectionMilliseconds = correction
        }
        setAnalysisEnabled(true)

        if !captureSession.isRunning {
            captureSession.startRunning()
        }

        guard !run.isCancelled else { return }
        microphoneRestartAttempts = 0
        do {
            try startMicrophoneCapture()
        } catch {
            startRequested = false
            setAnalysisEnabled(false)
            stopMicrophoneCapture()
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            releaseAudioSession()

            DispatchQueue.main.async {
                guard self.activeRun === run else { return }
                self.activeRun = nil
                self.statusText = "Unable to start microphone • press Start"
            }
            print("In.Sync microphone engine start error: \(error)")
            return
        }

        // stop() has enqueued teardown on this serial queue if cancelled.
        guard !run.isCancelled else { return }

        scheduleMicrophoneWatchdog()

        let device = cameraInput?.device
        DispatchQueue.main.async {
            guard self.activeRun === run else { return }
            self.previewCamera = device
            self.selectedLensID = device?.uniqueID
            self.offsetMilliseconds = nil
            self.acceptedMeasurements = 0
            self.statusText = "Listening for flash + tone"
            self.isRunning = true
        }
    }

    private func configureMeasurementAudioSession(requestedCorrection: Double) throws -> Double {
        let audioSession = AVAudioSession.sharedInstance()

        try audioSession.setCategory(
            .record,
            mode: .measurement,
            options: []
        )
        try audioSession.setPreferredSampleRate(48_000)
        try audioSession.setPreferredIOBufferDuration(0.005)
        try audioSession.setActive(true)
        ownsAudioSession = true

        // Keep measurement tests on the built-in microphone when it is
        // available. This avoids an unnoticed Bluetooth or USB input adding a
        // different latency or sitting too far from the Reference phone.
        if let builtInMicrophone = audioSession.availableInputs?.first(
            where: { $0.portType == .builtInMic }
        ) {
            do {
                try audioSession.setPreferredInput(builtInMicrophone)
            } catch {
                print("In.Sync built-in microphone preference unavailable: \(error)")
            }
        }

        if audioSession.maximumInputNumberOfChannels >= 1 {
            do {
                try audioSession.setPreferredInputNumberOfChannels(1)
            } catch {
                // The AVAudioEngine tap selects the strongest delivered channel
                // if the active route does not accept the mono preference.
                print("In.Sync mono input preference unavailable: \(error)")
            }
        }

        // The saved device correction is valid only for the built-in input.
        // Do not block Measure on an external route, but fall back to the raw
        // result so an unnoticed Bluetooth or USB microphone cannot receive a
        // correction measured for the phone's own microphone path.
        let activeInputs = audioSession.currentRoute.inputs
        if !activeInputs.isEmpty,
           !activeInputs.allSatisfy({ $0.portType == .builtInMic }) {
            return 0
        }
        return requestedCorrection
    }

    private func startMicrophoneCapture() throws {
        stopMicrophoneCapture()

        microphoneStateLock.lock()
        microphoneGeneration += 1
        let generation = microphoneGeneration
        microphoneStateLock.unlock()
        let engine = AVAudioEngine()
        microphoneEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved else {
            throw MeasurementError.microphoneFormatUnavailable
        }

        print(
            "In.Sync microphone input: "
            + "\(inputFormat.sampleRate) Hz, "
            + "\(inputFormat.channelCount) channel(s), Float32 non-interleaved"
        )

        microphoneStateLock.lock()
        microphoneBufferCount = 0
        lastMicrophoneBufferHostTime = nil
        microphoneStateLock.unlock()

        // Use the input node's native Float32 PCM format. The tap gives typed
        // channel pointers and a host-time timestamp for the first sample, so no
        // manual AudioBufferList/ASBD decoding is required.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { [weak self] buffer, when in
            guard let self,
                  self.isCurrentMicrophoneGeneration(generation),
                  self.isAnalysisEnabled() else {
                return
            }

            self.handleMicrophoneBuffer(
                buffer,
                when: when,
                generation: generation
            )
        }
        microphoneTapInstalled = true

        engine.prepare()
        try engine.start()

        guard engine.isRunning else {
            throw MeasurementError.microphoneEngineUnavailable
        }
    }

    private func stopMicrophoneCapture() {
        microphoneWatchdog?.cancel()
        microphoneWatchdog = nil
        microphoneStateLock.lock()
        microphoneGeneration += 1
        microphoneStateLock.unlock()

        if microphoneTapInstalled {
            microphoneEngine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }

        if microphoneEngine.isRunning {
            microphoneEngine.stop()
        }
        microphoneEngine.reset()

        microphoneStateLock.lock()
        microphoneBufferCount = 0
        lastMicrophoneBufferHostTime = nil
        microphoneStateLock.unlock()
    }

    private func handleMicrophoneBuffer(
        _ buffer: AVAudioPCMBuffer,
        when: AVAudioTime,
        generation: Int
    ) {
        guard isCurrentMicrophoneGeneration(generation),
              buffer.frameLength > 0,
              buffer.format.sampleRate > 0,
              let channelData = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))

        // Do not average several physical microphones together. Their phase and
        // spacing can partially cancel a narrow 1/2/4 kHz tone. Use the channel
        // with the highest RMS energy for this buffer instead.
        var selectedChannel = 0
        var selectedEnergy = -Double.infinity

        for channel in 0..<channelCount {
            var energy = 0.0
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let value = Double(samples[frame])
                energy += value * value
            }
            if energy > selectedEnergy {
                selectedEnergy = energy
                selectedChannel = channel
            }
        }

        let source = channelData[selectedChannel]
        let copiedSamples = Array(
            UnsafeBufferPointer(start: source, count: frameCount)
        )
        let sampleRate = buffer.format.sampleRate
        let duration = Double(frameCount) / sampleRate

        let startHostTime: Double
        if when.isHostTimeValid {
            startHostTime = AVAudioTime.seconds(forHostTime: when.hostTime)
        } else {
            // The normal iPhone/iPad input tap supplies valid host time. Keep a
            // conservative fallback rather than dropping all audio if a route
            // temporarily omits it.
            startHostTime = CACurrentMediaTime() - duration
        }

        microphoneStateLock.lock()
        microphoneBufferCount += 1
        lastMicrophoneBufferHostTime = CACurrentMediaTime()
        microphoneStateLock.unlock()

        audioQueue.async {
            guard self.isCurrentMicrophoneGeneration(generation),
                  self.isAnalysisEnabled() else {
                return
            }

            self.processAudioSamples(
                copiedSamples,
                sampleRate: sampleRate,
                startTime: startHostTime
            )
        }
    }

    private func isCurrentMicrophoneGeneration(_ generation: Int) -> Bool {
        microphoneStateLock.lock()
        let isCurrent = generation == microphoneGeneration
        microphoneStateLock.unlock()
        return isCurrent
    }

    private func scheduleMicrophoneWatchdog() {
        microphoneWatchdog?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.startRequested,
                  self.isAnalysisEnabled() else {
                return
            }

            self.microphoneStateLock.lock()
            let bufferCount = self.microphoneBufferCount
            let lastBufferTime = self.lastMicrophoneBufferHostTime
            self.microphoneStateLock.unlock()

            let streamIsStale = lastBufferTime.map {
                CACurrentMediaTime() - $0 > 1.25
            } ?? true

            if bufferCount == 0 || streamIsStale {
                if self.microphoneRestartAttempts < 1 {
                    self.microphoneRestartAttempts += 1
                    do {
                        try self.startMicrophoneCapture()
                        self.publishStatus("Restarting microphone • listening…")
                        self.scheduleMicrophoneWatchdog()
                    } catch {
                        self.publishStatus(
                            "Microphone unavailable • press Stop and Start"
                        )
                        print("In.Sync microphone restart error: \(error)")
                    }
                } else {
                    self.publishStatus(
                        "Microphone unavailable • press Stop and Start"
                    )
                }
                return
            }

            self.scheduleMicrophoneWatchdog()
        }

        microphoneWatchdog = workItem
        sessionQueue.asyncAfter(
            deadline: .now() + 1.5,
            execute: workItem
        )
    }

    private func configureCaptureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        // AVAudioEngine owns the microphone route throughout camera changes.
        captureSession.automaticallyConfiguresApplicationAudioSession = false

        // A failed first configuration must not leave partial inputs or outputs
        // behind for the next Start attempt.
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        videoOutput = nil
        cameraInput = nil

        if captureSession.canSetSessionPreset(.inputPriority) {
            captureSession.sessionPreset = .inputPriority
        } else {
            captureSession.sessionPreset = .high
        }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices.filter { $0.position == .back && !$0.isVirtualDevice }
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera }),
        camera.deviceType == .builtInWideAngleCamera,
        camera.position == .back, !camera.isVirtualDevice else {
            throw MeasurementError.rearCameraUnavailable
        }

        let newCameraInput = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(newCameraInput) else {
            throw MeasurementError.cameraInputUnavailable
        }
        captureSession.addInput(newCameraInput)
        cameraInput = newCameraInput

        let newVideoOutput = AVCaptureVideoDataOutput()
        newVideoOutput.alwaysDiscardsLateVideoFrames = true
        newVideoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        newVideoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard captureSession.canAddOutput(newVideoOutput) else {
            throw MeasurementError.videoOutputUnavailable
        }
        captureSession.addOutput(newVideoOutput)
        videoOutput = newVideoOutput

        try configureCameraForTiming(camera)
        configureRearLensChoices(defaultCamera: camera, discovered: devices)

        if let connection = newVideoOutput.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
    }

    private func configureCameraForTiming(
        _ camera: AVCaptureDevice
    ) throws {
        struct Candidate {
            let format: AVCaptureDevice.Format
            let frameRate: Double
            let frameDuration: CMTime
            let score: Double
        }

        var best: Candidate?

        for format in camera.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )

            // Avoid very small formats. 720p is sufficient for the preview and
            // leaves more processing headroom for a high, fixed capture rate.
            guard dimensions.width >= 1280,
                  dimensions.height >= 720 else {
                continue
            }

            for range in format.videoSupportedFrameRateRanges {
                let cappedRate = min(120.0, range.maxFrameRate)
                guard cappedRate >= 30,
                      cappedRate >= range.minFrameRate else {
                    continue
                }

                let area = Double(dimensions.width * dimensions.height)

                // Frame rate is the primary timing requirement. At an equal
                // rate prefer the smallest qualifying format, reducing camera
                // pipeline and memory pressure without weakening flash sensing.
                let score = (cappedRate * 1_000_000_000.0) - area

                let candidate = Candidate(
                    format: format,
                    frameRate: cappedRate,
                    frameDuration: range.maxFrameRate <= 120.0
                        ? range.minFrameDuration
                        : CMTime(value: 1, timescale: 120),
                    score: score
                )

                if candidate.score > (best?.score ?? -Double.infinity) {
                    best = candidate
                }
            }
        }

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        if let best {
            camera.activeFormat = best.format

            // Use the exact supported fraction at a format's high-FPS limit.
            camera.activeVideoMinFrameDuration = best.frameDuration
            camera.activeVideoMaxFrameDuration = best.frameDuration
            actualVideoFrameRate = best.frameRate
        } else {
            actualVideoFrameRate = 30
        }

        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }

        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }

        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    // MARK: - Full-screen rear lens selection

    /// Switches only between physical rear-camera devices. The capture session
    /// and microphone engine remain running, so full-screen Measure and audio
    /// acquisition are preserved. No virtual-camera zoom factor is written.
    func selectLens(_ id: String) {
        guard let run = activeRun else { return }
        #if targetEnvironment(simulator)
        if availableLenses.contains(where: { $0.id == id }) { selectedLensID = id }
        #else
        sessionQueue.async {
            guard !run.isCancelled, self.startRequested,
                  self.captureSession.isRunning,
                  self.cameraInput?.device.uniqueID != id,
                  let device = self.rearLensDevices.first(where: { $0.uniqueID == id }) else {
                return
            }

            // Stop accepting camera detections before the session input is
            // reconfigured. The microphone engine continues to run.
            self.videoQueue.sync {
                self.pendingVideoPulse = nil
                self.videoIgnoreUntilHostTime = .infinity
            }
            self.clearPendingCorrelationForLensChange()

            do {
                try self.switchToRearLens(device)
            } catch {
                self.videoQueue.sync {
                    self.resetVideoState()
                    self.videoIgnoreUntilHostTime = CACurrentMediaTime() + 0.35
                }
                print("In.Sync physical lens switch error: \(error)")
                if self.cameraInput == nil {
                    DispatchQueue.main.async {
                        guard self.activeRun === run else { return }
                        self.stop(withStatus: "Camera unavailable • press Start", resetConfiguration: true)
                    }
                }
                return
            }

            // Preserve the accepted stable result and microphone engine.
            // Relearn brightness and exposure for the new physical lens.
            self.videoQueue.sync {
                self.resetVideoState()
                self.videoIgnoreUntilHostTime = CACurrentMediaTime() + 1.10
            }
            self.clearPendingCorrelationForLensChange()

            DispatchQueue.main.async {
                guard self.activeRun === run else { return }
                self.previewCamera = device
                self.selectedLensID = id
            }
        }
        #endif
    }


    private func clearPendingCorrelationForLensChange() {
        correlationQueue.sync {
            videoEvents.removeAll(keepingCapacity: true)
            audioEvents.removeAll(keepingCapacity: true)
            acquisitionCandidates.removeAll(keepingCapacity: true)
            challengerValues.removeAll(keepingCapacity: true)
            lastVideoEventTime = nil
            lastAudioEventTime = nil
            unmatchedVideoEvents = 0
            unmatchedAudioEvents = 0
        }
    }

    private func configureRearLensChoices(defaultCamera: AVCaptureDevice, discovered: [AVCaptureDevice]) {
        var devices = discovered
        if !devices.contains(where: { $0.uniqueID == defaultCamera.uniqueID }) {
            devices.append(defaultCamera)
        }
        defaultWideCamera = defaultCamera
        rearLensDevices = devices
        let options = devices.map { device -> LensOption in
            let zoom: Double?
            switch device.deviceType {
            case .builtInUltraWideCamera: zoom = 0.5
            case .builtInWideAngleCamera: zoom = 1.0
            default: zoom = telephotoZoom(for: device, relativeTo: defaultCamera)
            }
            return LensOption(id: device.uniqueID, zoom: zoom)
        }.sorted { ($0.zoom ?? .infinity) < ($1.zoom ?? .infinity) }

        DispatchQueue.main.async {
            self.availableLenses = options
        }
    }

    private func resetLensToDefaultForRun() throws {
        guard let defaultWideCamera else { throw MeasurementError.rearCameraUnavailable }
        try switchToRearLens(defaultWideCamera)
    }

    private func switchToRearLens(_ device: AVCaptureDevice) throws {
        guard let previousInput = cameraInput else { throw MeasurementError.cameraInputUnavailable }
        guard previousInput.device.uniqueID != device.uniqueID else { return }

        let replacementInput = try AVCaptureDeviceInput(device: device)
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.removeInput(previousInput)

        do {
            guard captureSession.canAddInput(replacementInput) else {
                throw MeasurementError.cameraInputUnavailable
            }
            captureSession.addInput(replacementInput)
            try configureCameraForTiming(device)
            cameraInput = replacementInput
        } catch {
            if captureSession.inputs.contains(where: { $0 === replacementInput }) {
                captureSession.removeInput(replacementInput)
            }
            if captureSession.canAddInput(previousInput) {
                captureSession.addInput(previousInput)
            } else {
                cameraInput = nil
                configured = false
            }
            throw error
        }

        if let connection = videoOutput?.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
    }

    private func telephotoZoom(for tele: AVCaptureDevice, relativeTo wide: AVCaptureDevice) -> Double? {
        let ratio: Double
        if #available(iOS 26.0, *),
           wide.nominalFocalLengthIn35mmFilm > 0, tele.nominalFocalLengthIn35mmFilm > 0 {
            ratio = Double(tele.nominalFocalLengthIn35mmFilm) / Double(wide.nominalFocalLengthIn35mmFilm)
        } else {
            func widestHorizontalAngle(_ device: AVCaptureDevice) -> Double? {
                device.formats.compactMap { format -> Double? in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let angle = Double(format.videoFieldOfView)
                    guard dimensions.width >= 1280, dimensions.height >= 720,
                          angle > 0, angle < 180,
                          format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 })
                    else { return nil }
                    return angle
                }.max()
            }
            guard let wideAngle = widestHorizontalAngle(wide),
                  let teleAngle = widestHorizontalAngle(tele) else { return nil }
            ratio = tan(wideAngle * .pi / 360) / tan(teleAngle * .pi / 360)
        }
        guard ratio.isFinite, ratio > 1 else { return nil }
        let common = [2.0, 2.5, 3.0, 4.0, 5.0]
        if let closest = common.min(by: { abs($0 - ratio) < abs($1 - ratio) }),
           abs(closest - ratio) <= closest * 0.08 {
            return closest
        }
        return (ratio * 10).rounded() / 10
    }

    private func setAnalysisEnabled(_ enabled: Bool) {
        analysisStateLock.lock()
        analysisEnabled = enabled
        analysisStateLock.unlock()
    }

    private func isAnalysisEnabled() -> Bool {
        analysisStateLock.lock()
        let enabled = analysisEnabled
        analysisStateLock.unlock()
        return enabled
    }

    private func resetVideoState() {
        videoBaseline = 0.20
        previousVideoLevel = 0.20
        previousVideoTime = nil
        videoWarmupStartTime = nil
        videoWarmupLevels.removeAll(keepingCapacity: true)
        videoWarmupBrightFractions.removeAll(keepingCapacity: true)
        previousBrightFraction = 0
        videoBaselineBrightFraction = 0
        previousLumaSamples.removeAll(keepingCapacity: true)
        pendingVideoPulse = nil
        previousVideoDetectionTime = -10
        videoIgnoreUntilHostTime = 0
    }

    private func resetAudioState() {
        audioSamples.removeAll(keepingCapacity: true)
        audioReadIndex = 0
        audioBufferStartTime = 0
        expectedNextAudioTime = nil
        detectorSampleRate = 0
        detectorWindowSize = 0
        detectorHopSize = 0
        hannWindow.removeAll(keepingCapacity: true)
        toneNoiseFloor = [0.00005, 0.00005, 0.00005]
        audioNoiseRMS = 0.00005
        audioWarmupStartTime = nil
        audioWarmupComplete = false
        audioWarmupRMSValues.removeAll(keepingCapacity: true)
        toneWarmupAmplitudes = [[Double](), [Double](), [Double]()]
        toneArmed = true
        toneReleaseWindows = 0
        toneCandidateFrequency = 0
        toneCandidateCount = 0
        toneCandidateStartIndex = 0
        previousAudioDetectionTime = -10
        microphoneStateLock.lock()
        latestAudioRMS = 0
        latestToneRatio = 0
        audioStreamSeen = false
        microphoneStateLock.unlock()
    }

    private func updateAudioDiagnostics(
        rms: Double,
        toneRatio: Double,
        streamSeen: Bool = true
    ) {
        microphoneStateLock.lock()
        latestAudioRMS = rms
        latestToneRatio = toneRatio
        if streamSeen {
            audioStreamSeen = true
        }
        microphoneStateLock.unlock()
    }

    private func audioDiagnosticSnapshot() -> (
        streamSeen: Bool,
        rms: Double,
        toneRatio: Double
    ) {
        microphoneStateLock.lock()
        let snapshot = (audioStreamSeen, latestAudioRMS, latestToneRatio)
        microphoneStateLock.unlock()
        return snapshot
    }

    private func resetCorrelationState() {
        videoEvents.removeAll(keepingCapacity: true)
        audioEvents.removeAll(keepingCapacity: true)
        acquisitionCandidates.removeAll(keepingCapacity: true)
        acceptedValues.removeAll(keepingCapacity: true)
        challengerValues.removeAll(keepingCapacity: true)
        stableEstimate = nil
        totalAcceptedMeasurements = 0
        lastVideoEventTime = nil
        lastAudioEventTime = nil
        unmatchedVideoEvents = 0
        unmatchedAudioEvents = 0
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async {
            guard self.activeRun != nil else { return }
            self.statusText = text
        }
    }

    // MARK: - Video analysis

    private struct VideoMetrics {
        let mean: Double
        let highlightMean: Double
        let brightFraction: Double
        let riseFraction: Double
        let fallFraction: Double
    }

    private func processVideoSample(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        guard let presentationTime = videoPresentationHostTime(
            sampleBuffer
        ) else {
            return
        }

        if presentationTime < videoIgnoreUntilHostTime {
            return
        }

        let metrics = centreLumaMetrics(pixelBuffer)
        let level = metrics.highlightMean

        if videoWarmupStartTime == nil {
            videoWarmupStartTime = presentationTime
            videoWarmupLevels = [level]
            videoWarmupBrightFractions = [metrics.brightFraction]
            videoBaseline = level
            videoBaselineBrightFraction = metrics.brightFraction
            previousVideoLevel = level
            previousBrightFraction = metrics.brightFraction
            previousVideoTime = presentationTime
            return
        }

        let warmupElapsed =
            presentationTime - (videoWarmupStartTime ?? presentationTime)

        // Give auto exposure and white balance enough time to settle before
        // accepting a light event. The previous 0.35 second warm-up could
        // mistake camera start-up exposure movement for a Reference flash.
        if warmupElapsed < 0.80 {
            videoWarmupLevels.append(level)
            videoWarmupBrightFractions.append(metrics.brightFraction)

            if videoWarmupLevels.count > 240 {
                videoWarmupLevels.removeFirst(videoWarmupLevels.count - 240)
            }
            if videoWarmupBrightFractions.count > 240 {
                videoWarmupBrightFractions.removeFirst(
                    videoWarmupBrightFractions.count - 240
                )
            }

            previousVideoLevel = level
            previousBrightFraction = metrics.brightFraction
            previousVideoTime = presentationTime
            return
        }

        if !videoWarmupLevels.isEmpty {
            let sortedLevels = videoWarmupLevels.sorted()
            let baselineIndex = min(
                sortedLevels.count - 1,
                Int(Double(sortedLevels.count - 1) * 0.25)
            )
            videoBaseline = sortedLevels[baselineIndex]
            videoWarmupLevels.removeAll(keepingCapacity: true)
        }

        if !videoWarmupBrightFractions.isEmpty {
            let sortedFractions = videoWarmupBrightFractions.sorted()
            let baselineIndex = min(
                sortedFractions.count - 1,
                Int(Double(sortedFractions.count - 1) * 0.25)
            )
            videoBaselineBrightFraction = sortedFractions[baselineIndex]
            videoWarmupBrightFractions.removeAll(keepingCapacity: true)
        }

        let levelThreshold = min(
            0.985,
            max(
                0.27,
                max(
                    videoBaseline + 0.085,
                    (videoBaseline * 1.16) + 0.020
                )
            )
        )
        let brightThreshold = min(
            0.95,
            max(videoBaselineBrightFraction + 0.016, 0.022)
        )
        let levelRise = level - previousVideoLevel
        let brightRise = metrics.brightFraction - previousBrightFraction
        let pronouncedRise =
            levelRise >= 0.024
            || brightRise >= 0.010
            || metrics.riseFraction >= 0.014
            || metrics.mean - videoBaseline >= 0.11

        // A Reference flash is a short pulse, not merely a bright frame. Hold
        // the rising-edge timestamp provisionally and emit it only after the
        // image has returned to its baseline within a plausible flash duration.
        // This rejects camera auto-exposure changes, movement past a bright
        // object, and a scene that simply remains bright.
        if var pulse = pendingVideoPulse {
            pulse.peakLevel = max(pulse.peakLevel, level)
            pulse.peakBrightFraction = max(
                pulse.peakBrightFraction,
                metrics.brightFraction
            )
            pulse.peakRiseFraction = max(
                pulse.peakRiseFraction,
                metrics.riseFraction
            )
            pulse.frameCount += 1
            pendingVideoPulse = pulse

            let elapsed = presentationTime - pulse.onsetTime
            let released =
                level <= videoBaseline + 0.050
                || metrics.brightFraction
                    <= videoBaselineBrightFraction + 0.010
                || metrics.fallFraction >= 0.012

            if released {
                let minimumPulseDuration = max(
                    1.0 / max(30.0, actualVideoFrameRate) * 0.45,
                    0.004
                )
                let validDuration =
                    elapsed >= minimumPulseDuration && elapsed <= 0.24
                let validPeak =
                    pulse.peakLevel - videoBaseline >= 0.085
                    || pulse.peakBrightFraction
                        - videoBaselineBrightFraction >= 0.022
                let validEdge = pulse.peakRiseFraction >= 0.010

                pendingVideoPulse = nil

                if validDuration,
                   validPeak,
                   validEdge,
                   pulse.onsetTime - previousVideoDetectionTime >= 0.72 {
                    let levelConfidence =
                        (pulse.peakLevel - videoBaseline)
                        / max(0.10, 1.0 - videoBaseline)
                    let brightConfidence =
                        (pulse.peakBrightFraction
                         - videoBaselineBrightFraction)
                        / max(0.04, 1.0 - videoBaselineBrightFraction)
                    let edgeConfidence = min(
                        1.0,
                        pulse.peakRiseFraction / 0.08
                    )
                    let confidence = min(
                        1.0,
                        max(
                            0.20,
                            max(
                                edgeConfidence,
                                max(levelConfidence, brightConfidence)
                            )
                        )
                    )

                    previousVideoDetectionTime = pulse.onsetTime
                    registerVideoEvent(
                        DetectionEvent(
                            time: pulse.onsetTime,
                            confidence: confidence
                        )
                    )
                }
            } else if elapsed > 0.28 {
                // A long brightness change is exposure/scene movement, not the
                // one-frame-to-short-pulse Reference signal.
                pendingVideoPulse = nil
            }
        } else {
            let eligibleRise =
                level >= levelThreshold
                && metrics.brightFraction >= brightThreshold
                && pronouncedRise
                && presentationTime - previousVideoDetectionTime >= 0.72

            if eligibleRise {
                pendingVideoPulse = PendingVideoPulse(
                    onsetTime: presentationTime,
                    peakLevel: level,
                    peakBrightFraction: metrics.brightFraction,
                    peakRiseFraction: metrics.riseFraction,
                    frameCount: 1
                )
            } else if level < levelThreshold,
                      metrics.riseFraction < 0.008 {
                // Track slow scene/exposure movement only while no pulse is in
                // progress. A genuine flash must never be absorbed into baseline.
                videoBaseline =
                    (videoBaseline * 0.997) + (level * 0.003)
                videoBaselineBrightFraction =
                    (videoBaselineBrightFraction * 0.997)
                    + (metrics.brightFraction * 0.003)
            }
        }

        previousVideoLevel = level
        previousBrightFraction = metrics.brightFraction
        previousVideoTime = presentationTime
    }

    private func videoPresentationHostTime(
        _ sampleBuffer: CMSampleBuffer
    ) -> Double? {
        let presentationTime =
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard presentationTime.isFinite else { return nil }

        // AVCaptureSession timestamps use its synchronization clock. Convert
        // that clock to the system host-time timeline used by AVAudioTime. The
        // offset is sampled for every frame, avoiding drift between independent
        // camera and microphone hardware clocks during a long measurement.
        guard let captureClock = captureSession.synchronizationClock else {
            return presentationTime
        }

        let captureNow = CMClockGetTime(captureClock).seconds
        let hostNow = CACurrentMediaTime()
        guard captureNow.isFinite, hostNow.isFinite else {
            return presentationTime
        }

        return presentationTime + (hostNow - captureNow)
    }

    private func centreLumaMetrics(
        _ pixelBuffer: CVPixelBuffer
    ) -> VideoMetrics {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let baseAddress =
                CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return VideoMetrics(
                mean: 0,
                highlightMean: 0,
                brightFraction: 0,
                riseFraction: 0,
                fallFraction: 0
            )
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        let xStart = width / 10
        let xEnd = width * 9 / 10
        let yStart = height / 10
        let yEnd = height * 9 / 10
        let step = max(8, min(width, height) / 100)

        var histogram = [Int](repeating: 0, count: 256)
        var currentSamples: [UInt8] = []
        currentSamples.reserveCapacity(
            max(1, ((xEnd - xStart) / step) * ((yEnd - yStart) / step))
        )

        var total: UInt64 = 0
        var brightCount = 0
        var y = yStart

        while y < yEnd {
            var x = xStart

            while x < xEnd {
                let value = bytes[(y * rowBytes) + x]
                histogram[Int(value)] += 1
                currentSamples.append(value)
                total += UInt64(value)
                if value >= 190 {
                    brightCount += 1
                }
                x += step
            }

            y += step
        }

        let count = currentSamples.count
        guard count > 0 else {
            return VideoMetrics(
                mean: 0,
                highlightMean: 0,
                brightFraction: 0,
                riseFraction: 0,
                fallFraction: 0
            )
        }

        var riseCount = 0
        var fallCount = 0

        if previousLumaSamples.count == currentSamples.count {
            for index in currentSamples.indices {
                let current = Int(currentSamples[index])
                let previous = Int(previousLumaSamples[index])

                if current - previous >= 24, current >= 145 {
                    riseCount += 1
                }
                if previous - current >= 20 {
                    fallCount += 1
                }
            }
        }

        previousLumaSamples = currentSamples

        let highlightTarget = max(1, count / 10)
        var highlightCount = 0
        var highlightTotal = 0

        for value in stride(from: 255, through: 0, by: -1) {
            let available = histogram[value]
            guard available > 0 else { continue }
            let take = min(available, highlightTarget - highlightCount)
            highlightTotal += value * take
            highlightCount += take
            if highlightCount >= highlightTarget {
                break
            }
        }

        return VideoMetrics(
            mean: Double(total) / Double(count) / 255.0,
            highlightMean:
                Double(highlightTotal)
                / Double(max(1, highlightCount))
                / 255.0,
            brightFraction: Double(brightCount) / Double(count),
            riseFraction: Double(riseCount) / Double(count),
            fallFraction: Double(fallCount) / Double(count)
        )
    }

    // MARK: - Audio analysis

    private func processAudioSamples(
        _ samples: [Float],
        sampleRate: Double,
        startTime: Double
    ) {
        guard startTime.isFinite,
              sampleRate > 0,
              !samples.isEmpty else {
            return
        }

        if detectorSampleRate != sampleRate {
            configureToneDetector(sampleRate: sampleRate)
            audioSamples.removeAll(keepingCapacity: true)
            audioReadIndex = 0
            expectedNextAudioTime = nil
            audioWarmupStartTime = nil
            audioWarmupComplete = false
            audioWarmupRMSValues.removeAll(keepingCapacity: true)
            toneWarmupAmplitudes = [[Double](), [Double](), [Double]()]
        }

        if let expectedNextAudioTime,
           abs(startTime - expectedNextAudioTime) > 0.020 {
            // A route change, audio-engine restart or dropped tap buffer breaks a
            // sliding analysis window. Restart from this buffer rather than
            // assigning a false onset across the discontinuity.
            audioSamples.removeAll(keepingCapacity: true)
            audioReadIndex = 0
            toneCandidateCount = 0
            toneCandidateFrequency = 0
            toneCandidateStartIndex = 0
            audioWarmupStartTime = nil
            audioWarmupComplete = false
            audioWarmupRMSValues.removeAll(keepingCapacity: true)
            toneWarmupAmplitudes = [[Double](), [Double](), [Double]()]
        }

        if audioSamples.isEmpty || audioReadIndex >= audioSamples.count {
            audioSamples.removeAll(keepingCapacity: true)
            audioReadIndex = 0
            audioBufferStartTime = startTime
        }

        audioSamples.append(contentsOf: samples)
        expectedNextAudioTime = startTime
            + (Double(samples.count) / sampleRate)

        analyseAvailableAudioWindows()
    }

    private func configureToneDetector(sampleRate: Double) {
        detectorSampleRate = sampleRate
        detectorWindowSize = max(384, Int((sampleRate * 0.020).rounded()))
        detectorHopSize = max(64, Int((sampleRate * 0.002).rounded()))

        hannWindow = (0..<detectorWindowSize).map { index in
            guard detectorWindowSize > 1 else { return 1.0 }
            return 0.5 - (0.5 * cos(
                (2.0 * .pi * Double(index))
                / Double(detectorWindowSize - 1)
            ))
        }
    }

    private func analyseAvailableAudioWindows() {
        guard detectorWindowSize > 0,
              detectorHopSize > 0,
              detectorSampleRate > 0 else {
            return
        }

        while audioSamples.count - audioReadIndex >= detectorWindowSize {
            let windowStartTime = audioBufferStartTime
                + (Double(audioReadIndex) / detectorSampleRate)

            analyseToneWindow(
                startIndex: audioReadIndex,
                startTime: windowStartTime
            )

            audioReadIndex += detectorHopSize
        }

        if audioReadIndex > 8_192 {
            let removed = audioReadIndex
            audioSamples.removeFirst(removed)
            audioBufferStartTime += Double(removed) / detectorSampleRate
            audioReadIndex = 0
            toneCandidateStartIndex = max(0, toneCandidateStartIndex - removed)
        }
    }

    private func analyseToneWindow(
        startIndex: Int,
        startTime: Double
    ) {
        var mean = 0.0

        for index in 0..<detectorWindowSize {
            mean += Double(audioSamples[startIndex + index])
        }
        mean /= Double(detectorWindowSize)

        var rmsSum = 0.0
        for index in 0..<detectorWindowSize {
            let sample = Double(audioSamples[startIndex + index]) - mean
            rmsSum += sample * sample
        }
        let rms = sqrt(rmsSum / Double(detectorWindowSize))

        var targetAmplitudes: [Double] = []
        var sideAmplitudes: [Double] = []

        for frequency in supportedToneFrequencies {
            let target = goertzelAmplitude(
                startIndex: startIndex,
                frequency: frequency,
                sampleMean: mean
            )
            let lower = goertzelAmplitude(
                startIndex: startIndex,
                frequency: max(100, frequency - 300),
                sampleMean: mean
            )
            let upper = goertzelAmplitude(
                startIndex: startIndex,
                frequency: frequency + 300,
                sampleMean: mean
            )

            targetAmplitudes.append(target)
            sideAmplitudes.append(max(lower, upper))
        }

        guard let strongestIndex = targetAmplitudes.indices.max(
            by: { targetAmplitudes[$0] < targetAmplitudes[$1] }
        ) else {
            return
        }

        if audioWarmupStartTime == nil {
            audioWarmupStartTime = startTime
        }

        let warmupElapsed = startTime - (audioWarmupStartTime ?? startTime)
        if !audioWarmupComplete {
            audioWarmupRMSValues.append(rms)
            for index in toneWarmupAmplitudes.indices {
                toneWarmupAmplitudes[index].append(targetAmplitudes[index])
            }

            if audioWarmupRMSValues.count > 300 {
                audioWarmupRMSValues.removeFirst(
                    audioWarmupRMSValues.count - 300
                )
            }
            for index in toneWarmupAmplitudes.indices {
                if toneWarmupAmplitudes[index].count > 300 {
                    toneWarmupAmplitudes[index].removeFirst(
                        toneWarmupAmplitudes[index].count - 300
                    )
                }
            }

            guard warmupElapsed >= 0.45 else { return }

            // Use the lower part of the warm-up distribution. The Reference may
            // already be running when Measure starts, so one tone pip must not be
            // learned as the ambient noise floor.
            audioNoiseRMS = max(
                0.00002,
                lowerPercentile(audioWarmupRMSValues, fraction: 0.20)
            )
            for index in toneNoiseFloor.indices {
                toneNoiseFloor[index] = max(
                    0.00002,
                    lowerPercentile(
                        toneWarmupAmplitudes[index],
                        fraction: 0.20
                    )
                )
            }

            audioWarmupComplete = true
            audioWarmupRMSValues.removeAll(keepingCapacity: true)
            toneWarmupAmplitudes = [[Double](), [Double](), [Double]()]
        }

        let strongest = targetAmplitudes[strongestIndex]
        let side = sideAmplitudes[strongestIndex]
        let noise = toneNoiseFloor[strongestIndex]

        // A real phone speaker and microphone introduce harmonics and room
        // reflections, so one supported frequency may no longer dominate the
        // other two. Detect a sustained narrow spectral peak at any supported
        // frequency instead of requiring cross-frequency dominance. Repeated
        // windows, a short-pulse release, flash pairing and three consistent
        // cycles provide the false-trigger protection.
        let amplitudeThreshold = max(
            0.00004,
            max(noise * 1.55, audioNoiseRMS * 0.18)
        )
        let spectralRatio = strongest / max(0.00002, side)
        let purity = strongest / max(0.00002, rms * sqrt(2.0))

        updateAudioDiagnostics(
            rms: rms,
            toneRatio: max(spectralRatio, purity)
        )

        let strongTone =
            rms >= max(0.00003, audioNoiseRMS * 1.04)
            && strongest >= amplitudeThreshold
            && spectralRatio >= 1.15
            && purity >= 0.035

        if !strongTone,
           toneCandidateCount == 0,
           spectralRatio < 1.10 {
            audioNoiseRMS = (audioNoiseRMS * 0.997) + (rms * 0.003)
            for index in toneNoiseFloor.indices {
                let observed = targetAmplitudes[index]
                if observed < 0.12 {
                    toneNoiseFloor[index] =
                        (toneNoiseFloor[index] * 0.997)
                        + (observed * 0.003)
                }
            }
        }

        if toneArmed {
            if strongTone {
                let frequency = supportedToneFrequencies[strongestIndex]

                if abs(toneCandidateFrequency - frequency) < 1 {
                    toneCandidateCount += 1
                } else {
                    toneCandidateFrequency = frequency
                    toneCandidateCount = 1
                    toneCandidateStartIndex = startIndex
                }

                let confirmationWindows = max(
                    5,
                    Int(ceil(
                        0.010
                        / (Double(detectorHopSize) / detectorSampleRate)
                    ))
                )

                if toneCandidateCount >= confirmationWindows {
                    let refineThreshold = max(
                        0.00003,
                        max(noise * 1.25, audioNoiseRMS * 0.12)
                    )
                    let searchStart = max(
                        0,
                        toneCandidateStartIndex - (detectorWindowSize / 2)
                    )
                    let searchEnd = min(
                        audioSamples.count,
                        startIndex + detectorWindowSize
                    )
                    let onsetIndex = refinedToneOnsetIndex(
                        searchStart: searchStart,
                        searchEnd: searchEnd,
                        frequency: frequency,
                        threshold: refineThreshold
                    ) ?? toneCandidateStartIndex
                    let eventTime = audioBufferStartTime
                        + (Double(onsetIndex) / detectorSampleRate)

                    if eventTime - previousAudioDetectionTime >= 0.72 {
                        let confidence = min(
                            1.0,
                            max(
                                0.20,
                                min(
                                    spectralRatio / 2.2,
                                    purity * 2.0
                                )
                            )
                        )

                        previousAudioDetectionTime = eventTime
                        toneArmed = false
                        toneReleaseWindows = 0
                        registerAudioEvent(
                            DetectionEvent(
                                time: eventTime,
                                confidence: confidence
                            )
                        )
                    }

                    toneCandidateCount = 0
                    toneCandidateFrequency = 0
                    toneCandidateStartIndex = 0
                }
            } else {
                toneCandidateFrequency = 0
                toneCandidateCount = 0
                toneCandidateStartIndex = 0
            }
        } else {
            if strongTone {
                toneReleaseWindows = 0
            } else {
                toneReleaseWindows += 1
            }

            let releaseWindowCount = max(
                4,
                Int(
                    ceil(
                        0.030
                        / (Double(detectorHopSize) / detectorSampleRate)
                    )
                )
            )

            if toneReleaseWindows >= releaseWindowCount {
                toneArmed = true
                toneReleaseWindows = 0
                toneCandidateFrequency = 0
                toneCandidateCount = 0
                toneCandidateStartIndex = 0
            }
        }
    }

    private func lowerPercentile(
        _ values: [Double],
        fraction: Double
    ) -> Double {
        guard !values.isEmpty else { return 0.00002 }
        let sorted = values.sorted()
        let boundedFraction = min(1.0, max(0.0, fraction))
        let index = min(
            sorted.count - 1,
            Int(Double(sorted.count - 1) * boundedFraction)
        )
        return sorted[index]
    }

    private func refinedToneOnsetIndex(
        searchStart: Int,
        searchEnd: Int,
        frequency: Double,
        threshold: Double
    ) -> Int? {
        let blockLength = max(96, Int((detectorSampleRate * 0.005).rounded()))
        let step = max(32, Int((detectorSampleRate * 0.001).rounded()))
        guard searchEnd - searchStart >= blockLength else { return nil }

        var previousWasAbove = false
        var firstAboveIndex = searchStart
        var index = searchStart

        while index + blockLength <= searchEnd {
            let amplitude = quadratureAmplitude(
                startIndex: index,
                length: blockLength,
                frequency: frequency
            )
            let isAbove = amplitude >= threshold

            if isAbove && previousWasAbove {
                // Two adjacent 5 ms blocks are required. Return the first block's
                // leading edge; confirmation latency does not shift the timestamp.
                return firstAboveIndex
            }

            if isAbove {
                firstAboveIndex = index
            }
            previousWasAbove = isAbove
            index += step
        }

        return nil
    }

    private func quadratureAmplitude(
        startIndex: Int,
        length: Int,
        frequency: Double
    ) -> Double {
        guard length > 0,
              startIndex >= 0,
              startIndex + length <= audioSamples.count else {
            return 0
        }

        var mean = 0.0
        for index in 0..<length {
            mean += Double(audioSamples[startIndex + index])
        }
        mean /= Double(length)

        let phaseStep = 2.0 * .pi * frequency / detectorSampleRate
        var inPhase = 0.0
        var quadrature = 0.0

        for index in 0..<length {
            let sample = Double(audioSamples[startIndex + index]) - mean
            let phase = phaseStep * Double(index)
            inPhase += sample * cos(phase)
            quadrature += sample * sin(phase)
        }

        return 2.0 * hypot(inPhase, quadrature) / Double(length)
    }

    private func goertzelAmplitude(
        startIndex: Int,
        frequency: Double,
        sampleMean: Double
    ) -> Double {
        let omega = 2.0 * .pi * frequency / detectorSampleRate
        let coefficient = 2.0 * cos(omega)
        var previous = 0.0
        var previousPrevious = 0.0
        var windowSum = 0.0

        for index in 0..<detectorWindowSize {
            let weight = hannWindow[index]
            let sample =
                (Double(audioSamples[startIndex + index]) - sampleMean) * weight
            let current = sample
                + (coefficient * previous)
                - previousPrevious
            previousPrevious = previous
            previous = current
            windowSum += weight
        }

        let power = max(
            0.0,
            (previous * previous)
            + (previousPrevious * previousPrevious)
            - (coefficient * previous * previousPrevious)
        )

        return (2.0 * sqrt(power)) / max(1.0, windowSum)
    }

    // MARK: - Event pairing and stable result

    private func registerVideoEvent(_ event: DetectionEvent) {
        correlationQueue.async {
            self.lastVideoEventTime = event.time
            self.videoEvents.append(event)
            let paired = self.pairAvailableEvents()
            if !paired {
                self.publishAcquisitionStatus()
            }
        }
    }

    private func registerAudioEvent(_ event: DetectionEvent) {
        correlationQueue.async {
            self.lastAudioEventTime = event.time
            self.audioEvents.append(event)
            let paired = self.pairAvailableEvents()
            if !paired {
                self.publishAcquisitionStatus()
            }
        }
    }

    @discardableResult
    private func pairAvailableEvents() -> Bool {
        var pairedAny = false
        let newestTime = max(
            videoEvents.last?.time ?? -Double.infinity,
            audioEvents.last?.time ?? -Double.infinity
        )

        let expiredVideoCount = videoEvents.filter {
            newestTime - $0.time > 0.70
        }.count
        let expiredAudioCount = audioEvents.filter {
            newestTime - $0.time > 0.70
        }.count

        if expiredVideoCount > 0 {
            unmatchedVideoEvents += expiredVideoCount
        }
        if expiredAudioCount > 0 {
            unmatchedAudioEvents += expiredAudioCount
        }

        videoEvents.removeAll { newestTime - $0.time > 0.70 }
        audioEvents.removeAll { newestTime - $0.time > 0.70 }

        while !videoEvents.isEmpty && !audioEvents.isEmpty {
            var bestVideoIndex = 0
            var bestAudioIndex = 0
            var bestDistance = Double.infinity
            var bestScore = Double.infinity

            for videoIndex in videoEvents.indices {
                for audioIndex in audioEvents.indices {
                    let distance = abs(
                        videoEvents[videoIndex].time
                        - audioEvents[audioIndex].time
                    )

                    guard distance <= 0.499 else { continue }

                    let candidate = wrapMilliseconds(
                        (audioEvents[audioIndex].time
                         - videoEvents[videoIndex].time) * 1000.0
                    )

                    // Before lock, nearest-in-time is the least ambiguous match.
                    // After lock, prefer the pair that agrees with the established
                    // circular offset so a missed cycle or stray event cannot pull
                    // the result to a neighbouring one-second cycle.
                    let score: Double
                    if let stableEstimate {
                        score = circularDistance(candidate, stableEstimate)
                            + (distance * 2.0)
                    } else {
                        score = distance * 1000.0
                    }

                    if score < bestScore {
                        bestScore = score
                        bestDistance = distance
                        bestVideoIndex = videoIndex
                        bestAudioIndex = audioIndex
                    }
                }
            }

            guard bestDistance <= 0.499 else {
                // Events further apart than half a one-second cycle cannot be
                // uniquely matched on the ±500 ms dial. Discard only the older
                // side and wait for the next event on the other stream.
                if videoEvents[0].time < audioEvents[0].time {
                    videoEvents.removeFirst()
                } else {
                    audioEvents.removeFirst()
                }
                continue
            }

            let video = videoEvents.remove(at: bestVideoIndex)
            let audio = audioEvents.remove(at: bestAudioIndex)
            let confidence = min(video.confidence, audio.confidence)

            guard confidence >= 0.15 else { continue }

            // Approved dial convention: negative means audio arrived early;
            // positive means video arrived early. Therefore the signed offset is
            // audio time minus video time.
            let rawMilliseconds = wrapMilliseconds(
                (audio.time - video.time) * 1000.0
            )
            pairedAny = true
            unmatchedVideoEvents = 0
            unmatchedAudioEvents = 0
            ingestCandidate(rawMilliseconds)
        }

        return pairedAny
    }

    private func publishAcquisitionStatus() {
        guard stableEstimate == nil else { return }

        let cluster = densestCluster(
            values: acquisitionCandidates,
            tolerance: max(32.0, (1000.0 / max(30.0, actualVideoFrameRate)) * 2.5)
        )

        if !cluster.isEmpty {
            publishStatus("Acquiring \(min(cluster.count, 2))/3")
            return
        }

        if unmatchedVideoEvents >= 2,
           unmatchedAudioEvents == 0 {
            let diagnostics = audioDiagnosticSnapshot()
            if diagnostics.streamSeen {
                publishStatus("Microphone active • no matching tone")
            } else {
                publishStatus("Microphone unavailable • press Stop and Start")
            }
        } else if unmatchedAudioEvents >= 2,
                  unmatchedVideoEvents == 0 {
            publishStatus("No matching flash • aim at Reference screen")
        } else if !videoEvents.isEmpty && audioEvents.isEmpty {
            publishStatus("Waiting for matching tone")
        } else if !audioEvents.isEmpty && videoEvents.isEmpty {
            publishStatus("Waiting for matching flash")
        } else if lastVideoEventTime != nil && lastAudioEventTime != nil {
            publishStatus("Flash + tone found • matching")
        } else {
            publishStatus("Looking for flash + tone")
        }
    }

    private func ingestCandidate(_ value: Double) {
        let frameMilliseconds = 1000.0 / max(30.0, actualVideoFrameRate)
        let acquisitionTolerance = max(18.0, frameMilliseconds * 1.6)
        let trackingTolerance = max(24.0, frameMilliseconds * 2.0)

        guard let currentEstimate = stableEstimate else {
            acquisitionCandidates.append(value)
            if acquisitionCandidates.count > 9 {
                acquisitionCandidates.removeFirst(
                    acquisitionCandidates.count - 9
                )
            }

            let cluster = densestCluster(
                values: acquisitionCandidates,
                tolerance: acquisitionTolerance
            )

            if cluster.count >= 3 {
                let estimate = circularMedian(
                    cluster,
                    around: cluster[0]
                )
                stableEstimate = estimate
                acceptedValues = Array(cluster.suffix(7))
                challengerValues.removeAll(keepingCapacity: true)
                totalAcceptedMeasurements = cluster.count
                publishMeasurement(
                    estimate,
                    acceptedCount: totalAcceptedMeasurements,
                    status: "LIVE • stable"
                )
            } else {
                publishStatus("Acquiring \(cluster.count)/3")
            }

            return
        }

        if circularDistance(value, currentEstimate) <= trackingTolerance {
            acceptedValues.append(value)
            if acceptedValues.count > 7 {
                acceptedValues.removeFirst(
                    acceptedValues.count - 7
                )
            }

            let estimate = circularMedian(
                acceptedValues,
                around: currentEstimate
            )
            stableEstimate = estimate
            challengerValues.removeAll(keepingCapacity: true)
            totalAcceptedMeasurements += 1

            publishMeasurement(
                estimate,
                acceptedCount: totalAcceptedMeasurements,
                status: "LIVE • stable"
            )
        } else {
            challengerValues.append(value)
            if challengerValues.count > 5 {
                challengerValues.removeFirst(
                    challengerValues.count - 5
                )
            }

            let challengerCluster = densestCluster(
                values: challengerValues,
                tolerance: acquisitionTolerance
            )

            if challengerCluster.count >= 3 {
                let estimate = circularMedian(
                    challengerCluster,
                    around: challengerCluster[0]
                )
                stableEstimate = estimate
                acceptedValues = Array(challengerCluster.suffix(7))
                challengerValues.removeAll(keepingCapacity: true)
                totalAcceptedMeasurements += challengerCluster.count

                publishMeasurement(
                    estimate,
                    acceptedCount: totalAcceptedMeasurements,
                    status: "LIVE • stable"
                )
            } else {
                publishStatus("LIVE • rejecting outlier")
            }
        }
    }

    private func publishMeasurement(
        _ milliseconds: Double,
        acceptedCount: Int,
        status: String
    ) {
        let corrected = wrapMilliseconds(
            milliseconds - deviceCorrectionMilliseconds
        )

        DispatchQueue.main.async {
            guard self.activeRun != nil else { return }
            self.offsetMilliseconds = corrected
            self.acceptedMeasurements = acceptedCount
            self.statusText = status
        }
    }

    private func densestCluster(
        values: [Double],
        tolerance: Double
    ) -> [Double] {
        guard !values.isEmpty else { return [] }

        var best: [Double] = []

        for centre in values {
            let cluster = values.filter {
                circularDistance($0, centre) <= tolerance
            }

            if cluster.count > best.count {
                best = cluster
            }
        }

        return best
    }

    private func circularMedian(
        _ values: [Double],
        around reference: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }

        let unwrapped = values.map { value -> Double in
            var adjusted = value

            while adjusted - reference > 500 {
                adjusted -= 1000
            }

            while adjusted - reference <= -500 {
                adjusted += 1000
            }

            return adjusted
        }
        .sorted()

        let middle = unwrapped.count / 2
        let median: Double

        if unwrapped.count.isMultiple(of: 2) {
            median = (unwrapped[middle - 1] + unwrapped[middle]) / 2
        } else {
            median = unwrapped[middle]
        }

        return wrapMilliseconds(median)
    }

    private func circularDistance(
        _ first: Double,
        _ second: Double
    ) -> Double {
        abs(wrapMilliseconds(first - second))
    }

    private func wrapMilliseconds(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 1000.0)

        if wrapped > 500 {
            wrapped -= 1000
        } else if wrapped <= -500 {
            wrapped += 1000
        }

        return wrapped
    }
}

extension MeasurementEngine:
    AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isAnalysisEnabled() else { return }

        if let videoOutput, output === videoOutput {
            processVideoSample(sampleBuffer)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The output is configured to discard late frames rather than allowing
        // latency to build. Timing uses sample PTS, so a dropped frame reduces
        // confidence for that cycle but cannot shift later timestamps.
    }
}

private enum MeasurementError: Error {
    case rearCameraUnavailable
    case cameraInputUnavailable
    case videoOutputUnavailable
    case microphoneFormatUnavailable
    case microphoneEngineUnavailable
}
