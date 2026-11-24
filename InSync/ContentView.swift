import SwiftUI
import AVFoundation
import UIKit
import QuartzCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    enum Page: String, CaseIterable {
        case reference = "Reference"
        case measure = "Measure"
    }

    enum Units: String, CaseIterable {
        case ms = "ms"
        case frames = "frames"
    }

    enum ControlMode: String, CaseIterable {
        case ms = "Time"
        case frames = "Frames"
        case colour = "Colours"
    }

    enum ColourTheme: String, CaseIterable {
        case yellowGreen = "Yellow/Green"
        case orangeBlue = "Orange/Blue"
        case magentaCyan = "Magenta/Cyan"

        var negativeColour: Color {
            switch self {
            case .yellowGreen:
                return Color(
                    red: 0.95,
                    green: 0.76,
                    blue: 0.02
                )

            case .orangeBlue:
                return Color(
                    red: 1.00,
                    green: 0.47,
                    blue: 0.05
                )

            case .magentaCyan:
                return Color(
                    red: 0.95,
                    green: 0.20,
                    blue: 0.72
                )
            }
        }

        var positiveColour: Color {
            switch self {
            case .yellowGreen:
                return Color(
                    red: 0.15,
                    green: 0.78,
                    blue: 0.32
                )

            case .orangeBlue:
                return Color(
                    red: 0.12,
                    green: 0.55,
                    blue: 1.00
                )

            case .magentaCyan:
                return Color(
                    red: 0.05,
                    green: 0.84,
                    blue: 0.92
                )
            }
        }
    }

    @State private var page: Page = .reference
    @State private var units: Units = .ms
    @State private var controlMode: ControlMode = .ms
    @State private var colourTheme: ColourTheme = .yellowGreen
    @State private var frameRate: Double = 25.0

    @StateObject private var referenceEngine =
        ReferenceTimingEngine()

    @StateObject private var measureEngine =
        MeasurementEngine()

    @StateObject private var calibration =
        DeviceCalibrationManager()

    @State private var calibrationPresented = false
    @State private var calibrationConfirmDeadline: Date?

    @State private var flashEnabled = true
    @State private var toneFrequency: Double = 2000

    private var focusMode: Bool {
        switch page {
        case .reference:
            return referenceEngine.isRunning

        case .measure:
            return measureEngine.isRunning
        }
    }

    var body: some View {
        GeometryReader { proxy in
            // Use a split layout only when the current window is wide enough,
            // rather than assuming every physically-landscape iPad window has
            // room for a sidebar. This keeps Stage Manager and Split View
            // windows usable while preserving the approved iPhone layout.
            let landscape = AdaptiveLayout.useSplitLayout(
                for: proxy.size
            )
            let expandedCanvas = AdaptiveLayout.isExpandedCanvas(
                proxy.size
            )

            let responsiveLayout =
                landscape
                ? AnyLayout(
                    HStackLayout(spacing: 0)
                )
                : AnyLayout(
                    VStackLayout(spacing: 0)
                )

            let sidebarWidth = AdaptiveLayout.sidebarWidth(
                for: proxy.size
            )

            let headerWidth: CGFloat? =
                landscape
                ? (focusMode ? 0 : sidebarWidth)
                : nil

            let headerHeight: CGFloat? =
                landscape
                ? nil
                : (focusMode ? 0 : nil)

            let dividerWidth: CGFloat? =
                landscape
                ? (focusMode ? 0 : 1)
                : nil

            let dividerHeight: CGFloat? =
                landscape
                ? nil
                : 0

            ZStack {
                LinearGradient(
                    colors: [
                        Color(
                            red: 0.055,
                            green: 0.062,
                            blue: 0.060
                        ),
                        .black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if page == .measure && measureEngine.isRunning {
                    CameraPreview(
                        session: measureEngine.previewSession,
                        device: measureEngine.previewCamera
                    )
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .transition(.opacity)

                    // The live rear-camera picture remains visible for aiming,
                    // while the 50% scrim preserves the approved clock contrast.
                    Color.black
                        .opacity(0.50)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // AnyLayout changes between a vertical and horizontal layout
                // without replacing the child views. Together with engines
                // owned by ContentView, this keeps an active sync session and
                // all results alive through repeated device rotations.
                responsiveLayout {
                    setupHeader(
                        isLandscape: landscape,
                        isExpandedCanvas: expandedCanvas
                    )
                        .frame(width: headerWidth)
                        .frame(height: headerHeight)
                        .frame(
                            maxHeight:
                                landscape
                                ? .infinity
                                : nil,
                            alignment: .top
                        )
                        .padding(
                            .top,
                            landscape && !focusMode
                            ? 4
                            : 0
                        )
                        .opacity(focusMode ? 0 : 1)
                        .clipped()
                        .allowsHitTesting(!focusMode)

                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(
                            width: dividerWidth,
                            height: dividerHeight
                        )
                        .frame(
                            maxHeight:
                                landscape
                                ? .infinity
                                : nil
                        )
                        .padding(
                            .vertical,
                            landscape && !focusMode
                            ? 18
                            : 0
                        )
                        .opacity(
                            landscape && !focusMode
                            ? 1
                            : 0
                        )

                    currentScreen(
                        isLandscape: landscape,
                        isExpandedCanvas: expandedCanvas
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                }
                .padding(
                    .leading,
                    landscape
                    ? max(
                        proxy.safeAreaInsets.leading,
                        focusMode ? 10 : 8
                    )
                    : 0
                )
                .padding(
                    .trailing,
                    landscape
                    ? max(
                        proxy.safeAreaInsets.trailing,
                        focusMode ? 10 : 8
                    )
                    : 0
                )
            }
        }
#if DEBUG && targetEnvironment(simulator)
        .task {
            switch ProcessInfo.processInfo.environment["INSYNC_SCREENSHOT"] {
            case "reference-frames":
                units = .frames
                controlMode = .frames
            case "reference-colours":
                colourTheme = .magentaCyan
                controlMode = .colour
            case "measure":
                page = .measure
            case "calibration":
                calibrationPresented = true
            default:
                break
            }
        }
#endif
        .fullScreenCover(isPresented: $calibrationPresented) {
            DeviceCalibrationView(
                manager: calibration,
                colourTheme: colourTheme
            ) {
                calibration.resetPresentationState()
                calibrationPresented = false
            }
            .interactiveDismissDisabled(
                calibration.runState == .preparing
                    || calibration.runState == .running
            )
        }
        .animation(
            .easeInOut(duration: 0.20),
            value: focusMode
        )
        .animation(
            .easeInOut(duration: 0.16),
            value: controlMode
        )
        .onChange(of: focusMode) { _, running in
            // Reference and Measure are display-critical modes. Keep the screen
            // awake only while one of them is actively running, then restore the
            // normal system idle timer immediately after Stop.
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }

            // Capture/audio clocks are no longer trustworthy after the app is
            // interrupted or backgrounded. Stop cleanly instead of returning to
            // a stale session that still appears to be running.
            if referenceEngine.isRunning {
                referenceEngine.stop()
            }
            if phase == .background || !measureEngine.isHandlingPermissionTransition {
                measureEngine.stop()
            }
            let calibrationShouldStop = calibration.runState == .running
                || (
                    calibration.runState == .preparing
                        && (phase == .background || !calibration.isHandlingPermissionTransition)
                )
            if calibrationShouldStop {
                calibration.cancelCalibration()
                calibrationPresented = false
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onDisappear {
            referenceEngine.stop()
            measureEngine.stop()
            if !calibrationPresented {
                calibration.cancelCalibration()
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @ViewBuilder
    private func currentScreen(
        isLandscape: Bool,
        isExpandedCanvas: Bool
    ) -> some View {
        switch page {
        case .reference:
            ReferenceScreen(
                units: units,
                frameRate: frameRate,
                colourTheme: colourTheme,
                isLandscape: isLandscape,
                isExpandedCanvas: isExpandedCanvas,
                engine: referenceEngine,
                calibration: calibration,
                flashEnabled: $flashEnabled,
                toneFrequency: $toneFrequency
            )

        case .measure:
            MeasureScreen(
                units: units,
                frameRate: frameRate,
                colourTheme: colourTheme,
                isLandscape: isLandscape,
                isExpandedCanvas: isExpandedCanvas,
                engine: measureEngine,
                calibration: calibration
            )
        }
    }

    private func setupHeader(
        isLandscape: Bool,
        isExpandedCanvas: Bool
    ) -> some View {
        VStack(spacing: 0) {
            brandHeading

            topNavigation
                .frame(
                    maxWidth:
                        isExpandedCanvas && !isLandscape
                        ? 620
                        : .infinity
                )
                .padding(.horizontal, 24)

            controlSelector
                .frame(
                    maxWidth:
                        isExpandedCanvas
                        ? (isLandscape ? 430 : 600)
                        : 370
                )
                .padding(.top, 14)

            if controlMode == .frames {
                frameRateSelector
                    .frame(
                        maxWidth:
                            isExpandedCanvas
                            ? (isLandscape ? 380 : 620)
                            : .infinity
                    )
                    .padding(.top, 9)
                    .transition(
                        .opacity
                        .combined(
                            with: .move(edge: .top)
                        )
                    )
            }

            if controlMode == .colour {
                colourSelector
                    .frame(
                        maxWidth:
                            isExpandedCanvas
                            ? (isLandscape ? 380 : 620)
                            : .infinity
                    )
                    .padding(.top, 9)
                    .transition(
                        .opacity
                        .combined(
                            with: .move(edge: .top)
                        )
                    )
            }

            if isLandscape {
                Spacer(minLength: 8)

                landscapeBottomControls
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var landscapeBottomControls: some View {
        switch page {
        case .reference:
            landscapeReferenceControls

        case .measure:
            bottomPill(
                left: (
                    "bolt.fill",
                    "Flash Detect",
                    colourTheme.negativeColour
                ),
                right: (
                    "waveform",
                    "Tone Detect",
                    Color.white
                ),
                compact: true
            )
        }
    }

    private var landscapeReferenceControls: some View {
        HStack(spacing: 0) {
            Button {
                flashEnabled.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(
                            flashEnabled
                            ? colourTheme.negativeColour
                            : Color.white.opacity(0.35)
                        )

                    Text(
                        flashEnabled
                        ? "Flash On"
                        : "Flash Off"
                    )
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(width: 1, height: 26)

            Menu {
                headerToneButton(
                    "Tone Off",
                    value: 0
                )
                headerToneButton(
                    "1 kHz",
                    value: 1000
                )
                headerToneButton(
                    "2 kHz",
                    value: 2000
                )
                headerToneButton(
                    "4 kHz",
                    value: 4000
                )
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "waveform")
                        .foregroundStyle(
                            toneFrequency > 0
                            ? Color.white
                            : Color.white.opacity(0.35)
                        )

                    Text(headerToneLabel)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(
            .system(
                size: 13,
                weight: .medium
            )
        )
        .foregroundStyle(.white.opacity(0.88))
        .frame(height: 48)
        .padding(.horizontal, 8)
        .background(
            Capsule()
                .fill(.white.opacity(0.055))
        )
        .overlay(
            Capsule()
                .stroke(
                    .white.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func headerToneButton(
        _ title: String,
        value: Double
    ) -> some View {
        Button {
            toneFrequency = value
        } label: {
            if toneFrequency == value {
                Label(
                    title,
                    systemImage: "checkmark"
                )
            } else {
                Text(title)
            }
        }
    }

    private var headerToneLabel: String {
        switch toneFrequency {
        case 0:
            return "Tone Off"

        case 1000:
            return "1 kHz"

        case 4000:
            return "4 kHz"

        default:
            return "2 kHz"
        }
    }

    private var brandHeading: some View {
        VStack(spacing: 4) {
            HStack(
                alignment: .firstTextBaseline,
                spacing: -1
            ) {
                Text("In")
                    .font(
                        .system(
                            size: 35,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .tracking(-0.8)

                Text(".")
                    .font(
                        .system(
                            size: 35,
                            weight: .heavy,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(
                        colourTheme.negativeColour
                    )
                    .shadow(
                        color:
                            colourTheme
                                .negativeColour
                                .opacity(0.72),
                        radius: 5
                    )

                Text("Sync")
                    .font(
                        .system(
                            size: 35,
                            weight: .light,
                            design: .rounded
                        )
                    )
                    .tracking(-0.9)
            }
            .foregroundStyle(.white)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            colourTheme.negativeColour,
                            colourTheme.positiveColour
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(
                    width: 56,
                    height: 2
                )
                .opacity(0.88)
                .shadow(
                    color:
                        colourTheme
                            .positiveColour
                            .opacity(0.30),
                    radius: 3
                )
        }
        .accessibilityElement(
            children: .ignore
        )
        .accessibilityLabel("In.Sync")
        .padding(.top, 7)
        .padding(.bottom, 11)
    }

    private var topNavigation: some View {
        HStack(spacing: 0) {
            ForEach(Page.allCases, id: \.self) { item in
                Button {
                    selectPage(item)
                } label: {
                    Text(item.rawValue)
                        .font(
                            .system(
                                size: 15,
                                weight:
                                    page == item
                                    ? .semibold
                                    : .regular
                            )
                        )
                        .foregroundStyle(
                            page == item
                            ? .white
                            : .white.opacity(0.62)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if page == item {
                                Capsule()
                                    .fill(
                                        .white.opacity(0.14)
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(.white.opacity(0.05))
        )
        .overlay(
            Capsule()
                .stroke(
                    .white.opacity(0.12),
                    lineWidth: 1
                )
        )
    }

    private func selectPage(
        _ newPage: Page
    ) {
        guard newPage != page else { return }

        if referenceEngine.isRunning {
            referenceEngine.stop()
        }

        measureEngine.stop { page = newPage }
    }

    private var controlSelector: some View {
        HStack(spacing: 0) {
            ForEach(
                ControlMode.allCases,
                id: \.self
            ) { item in
                Button {
                    selectControlMode(item)
                } label: {
                    Text(item.rawValue.uppercased())
                        .font(
                            .system(
                                size: 12,
                                weight:
                                    controlMode == item
                                    ? .semibold
                                    : .regular
                            )
                        )
                        .foregroundStyle(
                            controlMode == item
                            ? .white
                            : .white.opacity(0.60)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity)
                        .frame(height: 35)
                        .background {
                            if controlMode == item {
                                Capsule()
                                    .fill(.white.opacity(0.14))
                            }
                        }
                }
                .buttonStyle(.plain)
            }

            Button {
                handleCalibrationTap()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(calibrationIndicatorColour)
                        .frame(width: 6, height: 6)

                    Text(calibrationButtonTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
                .font(
                    .system(
                        size: 11,
                        weight:
                            calibrationConfirmDeadline == nil
                            ? .regular
                            : .semibold
                    )
                )
                .foregroundStyle(
                    calibrationConfirmDeadline == nil
                    ? .white.opacity(0.68)
                    : .white
                )
                .frame(maxWidth: .infinity)
                .frame(height: 35)
                .background {
                    if calibrationConfirmDeadline != nil {
                        Capsule()
                            .fill(.white.opacity(0.14))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                calibrationConfirmDeadline == nil
                ? "Calibrate device"
                : "Confirm device calibration"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(3)
        .background(
            Capsule()
                .fill(.white.opacity(0.045))
        )
        .overlay(
            Capsule()
                .stroke(
                    .white.opacity(0.12),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 18)
    }

    private var calibrationButtonTitle: String {
        calibrationConfirmDeadline == nil
            ? "CALIBRATE"
            : "CONFIRM?"
    }

    private var calibrationIndicatorColour: Color {
        switch calibration.indicatorState {
        case .none:
            return Color.white.opacity(0.30)
        case .valid:
            return Color(red: 0.15, green: 0.78, blue: 0.32)
        case .questionable:
            return Color(red: 0.95, green: 0.76, blue: 0.02)
        case .failed:
            return Color(red: 0.92, green: 0.20, blue: 0.18)
        }
    }

    private func handleCalibrationTap() {
        let now = Date()

        if let deadline = calibrationConfirmDeadline,
           now <= deadline {
            calibrationConfirmDeadline = nil

            if referenceEngine.isRunning {
                referenceEngine.stop()
            }
            measureEngine.stop {
                guard scenePhase == .active else { return }
                calibrationPresented = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    guard calibrationPresented else { return }
                    guard scenePhase == .active else {
                        calibrationPresented = false
                        return
                    }
                    calibration.startCalibration()
                }
            }
            return
        }

        let deadline = now.addingTimeInterval(4.0)
        calibrationConfirmDeadline = deadline

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            guard calibrationConfirmDeadline == deadline else { return }
            calibrationConfirmDeadline = nil
        }
    }

    private func selectControlMode(
        _ mode: ControlMode
    ) {
        controlMode = mode

        switch mode {
        case .ms:
            units = .ms

        case .frames:
            units = .frames

        case .colour:
            break
        }
    }

    private var colourSelector: some View {
        HStack(spacing: 4) {
            ForEach(
                ColourTheme.allCases,
                id: \.self
            ) { theme in
                Button {
                    colourTheme = theme
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(theme.negativeColour)
                            .frame(
                                width: 7,
                                height: 7
                            )

                        Circle()
                            .fill(theme.positiveColour)
                            .frame(
                                width: 7,
                                height: 7
                            )

                        Text(theme.rawValue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .font(
                        .system(
                            size: 11,
                            weight:
                                colourTheme == theme
                                ? .semibold
                                : .regular
                        )
                    )
                    .foregroundStyle(
                        colourTheme == theme
                        ? .white
                        : .white.opacity(0.62)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        if colourTheme == theme {
                            Capsule()
                                .fill(
                                    .white.opacity(0.14)
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(.white.opacity(0.04))
        )
        .overlay(
            Capsule()
                .stroke(
                    .white.opacity(0.10),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 18)
    }

    private var frameRateSelector: some View {
        let rates: [Double] = [
            25,
            29.97,
            30,
            50,
            59.94,
            60
        ]

        return HStack(spacing: 4) {
            ForEach(rates, id: \.self) { rate in
                Button {
                    frameRate = rate
                } label: {
                    Text(formatRate(rate))
                        .font(
                            .system(
                                size: 11,
                                weight:
                                    frameRate == rate
                                    ? .semibold
                                    : .regular
                            )
                        )
                        .foregroundStyle(
                            frameRate == rate
                            ? .white
                            : .white.opacity(0.58)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if frameRate == rate {
                                Capsule()
                                    .fill(
                                        .white.opacity(0.14)
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(.white.opacity(0.04))
        )
        .overlay(
            Capsule()
                .stroke(
                    .white.opacity(0.10),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 18)
    }

    private func formatRate(
        _ rate: Double
    ) -> String {
        if rate == 29.97 || rate == 59.94 {
            return String(
                format: "%.2f",
                rate
            )
        }

        return String(
            format: "%.0f",
            rate
        )
    }
}


private enum AdaptiveLayout {
    /// The approved left-menu/right-clock split is retained on iPhone
    /// landscape and on sufficiently wide iPad windows. Narrow resizable iPad
    /// windows automatically fall back to the existing stacked arrangement.
    static func useSplitLayout(for size: CGSize) -> Bool {
        size.width > size.height &&
        size.width >= 500 &&
        size.height >= 300
    }

    /// Expanded metrics are based on the current app window, not the device
    /// model. An iPad in a narrow window therefore behaves like a compact app,
    /// while a full-size iPad gets appropriately larger instruments.
    static func isExpandedCanvas(_ size: CGSize) -> Bool {
        min(size.width, size.height) >= 600
    }

    static func sidebarWidth(for size: CGSize) -> CGFloat {
        guard useSplitLayout(for: size) else { return 0 }

        if size.width >= 1_000 && size.height >= 650 {
            return min(
                max(size.width * 0.28, 330),
                420
            )
        }

        return min(
            max(size.width * 0.30, 250),
            292
        )
    }
}

private enum SharedClockLayout {
    private static func expanded(_ size: CGSize) -> Bool {
        min(size.width, size.height) >= 600
    }

    static func statusSlotHeight(
        availableSize: CGSize,
        focusMode: Bool,
        isLandscape: Bool
    ) -> CGFloat {
        let isExpanded = expanded(availableSize)

        if isLandscape {
            return isExpanded ? 20 : 12
        }

        if isExpanded {
            return focusMode ? 40 : 35
        }

        return focusMode ? 33 : 29
    }

    static func clockSide(
        availableSize: CGSize,
        focusMode: Bool,
        isLandscape: Bool
    ) -> CGFloat {
        let isExpanded = expanded(availableSize)

        if isLandscape {
            // The lower reserve is based on the larger Measure result area, so
            // Reference and Measure keep identical clock geometry. Full-size
            // iPads can use almost all of the available height; iPhone values
            // remain unchanged from the approved visual baseline.
            let verticalReserve: CGFloat = isExpanded ? 110 : 60
            let maximumSide: CGFloat = isExpanded ? 1_000 : 420

            return max(
                180,
                min(
                    maximumSide,
                    availableSize.width - 12,
                    availableSize.height - verticalReserve
                )
            )
        }

        // Portrait reserves the larger page-specific lower section. Expanded
        // windows receive a larger instrument while compact iPhone dimensions
        // retain the existing sizing path.
        let verticalReserve: CGFloat
        let maximumSide: CGFloat

        if isExpanded {
            verticalReserve = focusMode ? 150 : 245
            maximumSide = focusMode ? 1_000 : 760
        } else {
            // Preserve the locked modern-iPhone geometry exactly. Only the
            // shortest compact portrait windows use a little extra reserve so
            // the result/legend and lower controls cannot be clipped.
            verticalReserve = focusMode
                ? 96
                : (availableSize.height < 520 ? 211 : 176)
            maximumSide = focusMode ? 720 : 430
        }

        let horizontalInset =
            horizontalPadding(
                availableSize: availableSize,
                focusMode: focusMode,
                isLandscape: false
            ) * 2

        return max(
            180,
            min(
                maximumSide,
                availableSize.width - horizontalInset,
                availableSize.height - verticalReserve
            )
        )
    }

    static func horizontalPadding(
        availableSize: CGSize,
        focusMode: Bool,
        isLandscape: Bool
    ) -> CGFloat {
        if isLandscape {
            return expanded(availableSize) ? 4 : 2
        }

        if expanded(availableSize) {
            return focusMode ? 18 : 20
        }

        return focusMode ? 14 : 12
    }

    static func topPadding(
        availableSize: CGSize,
        focusMode: Bool,
        isLandscape: Bool
    ) -> CGFloat {
        if isLandscape {
            return 0
        }

        if expanded(availableSize) {
            return focusMode ? 8 : 12
        }

        return focusMode ? 5 : 9
    }
}

private struct ClockStage<StatusContent: View>: View {
    let availableSize: CGSize
    let focusMode: Bool
    let isLandscape: Bool
    let milliseconds: Double
    let units: ContentView.Units
    let frameRate: Double
    let colourTheme: ContentView.ColourTheme
    let running: Bool
    let buttonAction: () -> Void
    let statusContent: StatusContent

    init(
        availableSize: CGSize,
        focusMode: Bool,
        isLandscape: Bool,
        milliseconds: Double,
        units: ContentView.Units,
        frameRate: Double,
        colourTheme: ContentView.ColourTheme,
        running: Bool,
        buttonAction: @escaping () -> Void,
        @ViewBuilder statusContent: () -> StatusContent
    ) {
        self.availableSize = availableSize
        self.focusMode = focusMode
        self.isLandscape = isLandscape
        self.milliseconds = milliseconds
        self.units = units
        self.frameRate = frameRate
        self.colourTheme = colourTheme
        self.running = running
        self.buttonAction = buttonAction
        self.statusContent = statusContent()
    }

    var body: some View {
        let clockSide =
            SharedClockLayout.clockSide(
                availableSize: availableSize,
                focusMode: focusMode,
                isLandscape: isLandscape
            )

        VStack(spacing: 0) {
            statusContent
                .frame(
                    height:
                        SharedClockLayout
                            .statusSlotHeight(
                                availableSize: availableSize,
                                focusMode: focusMode,
                                isLandscape: isLandscape
                            )
                )
                .frame(maxWidth: 760)

            SyncClock(
                milliseconds: milliseconds,
                units: units,
                frameRate: frameRate,
                colourTheme: colourTheme,
                running: running,
                buttonAction: buttonAction
            )
            .frame(
                width: clockSide,
                height: clockSide
            )
            .padding(
                .horizontal,
                SharedClockLayout
                    .horizontalPadding(
                        availableSize: availableSize,
                        focusMode: focusMode,
                        isLandscape: isLandscape
                    )
            )
            .padding(
                .top,
                SharedClockLayout
                    .topPadding(
                        availableSize: availableSize,
                        focusMode: focusMode,
                        isLandscape: isLandscape
                    )
            )
            .layoutPriority(1)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .top
        )
    }
}

private struct ReferenceScreen: View {
    let units: ContentView.Units
    let frameRate: Double
    let colourTheme: ContentView.ColourTheme
    let isLandscape: Bool
    let isExpandedCanvas: Bool

    @ObservedObject var engine: ReferenceTimingEngine
    @ObservedObject var calibration: DeviceCalibrationManager

    @Binding var flashEnabled: Bool
    @Binding var toneFrequency: Double

    private var focusMode: Bool {
        engine.isRunning
    }

    var body: some View {
        GeometryReader { proxy in
            referenceContent(
                availableSize: proxy.size
            )
        }
        .onAppear {
            syncSettingsToEngine()
        }
        .onChange(of: flashEnabled) { _, _ in
            syncSettingsToEngine()
        }
        .onChange(of: toneFrequency) { _, _ in
            syncSettingsToEngine()
        }
        .onChange(of: frameRate) { _, _ in
            syncSettingsToEngine()
        }
    }

    private func referenceContent(
        availableSize: CGSize
    ) -> some View {
        ZStack {
            if focusMode && !isLandscape {
                centredPortraitReference(
                    availableSize: availableSize
                )
            } else {
                VStack(spacing: 0) {
                    ClockStage(
                        availableSize: availableSize,
                        focusMode: focusMode,
                        isLandscape: isLandscape,
                        milliseconds:
                            engine.currentMilliseconds,
                        units: units,
                        frameRate: frameRate,
                        colourTheme: colourTheme,
                        running: engine.isRunning,
                        buttonAction: toggleRun
                    ) {
                        Color.clear
                            .accessibilityHidden(true)
                    }

                    timingLegend
                        .padding(
                            .top,
                            isLandscape
                            ? 0
                            : (focusMode ? 2 : 0)
                        )

                    Spacer(
                        minLength:
                            isLandscape
                            ? 2
                            : (focusMode ? 6 : 14)
                    )

                    if !focusMode && !isLandscape {
                        referenceControls
                            .padding(.horizontal, 24)
                            .padding(.bottom, 22)
                            .transition(
                                .move(edge: .bottom)
                                .combined(with: .opacity)
                            )
                    }
                }
            }

            ReferenceFlashOverlay(engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func centredPortraitReference(
        availableSize: CGSize
    ) -> some View {
        let clockSide =
            SharedClockLayout.clockSide(
                availableSize: availableSize,
                focusMode: true,
                isLandscape: false
            )

        let centreY = availableSize.height / 2
        let legendY = min(
            availableSize.height - 22,
            centreY + clockSide / 2 + 24
        )

        return ZStack {
            SyncClock(
                milliseconds: engine.currentMilliseconds,
                units: units,
                frameRate: frameRate,
                colourTheme: colourTheme,
                running: engine.isRunning,
                buttonAction: toggleRun
            )
            .frame(
                width: clockSide,
                height: clockSide
            )
            .position(
                x: availableSize.width / 2,
                y: centreY
            )

            timingLegend
                .frame(maxWidth: isExpandedCanvas ? 760 : 620)
                .position(
                    x: availableSize.width / 2,
                    y: legendY
                )
        }
    }

    private func toggleRun() {
        syncSettingsToEngine()

        if engine.isRunning {
            engine.stop()
        } else {
            engine.start()
        }
    }

    private func syncSettingsToEngine() {
        engine.flashEnabled = flashEnabled
        engine.toneFrequency = toneFrequency
        engine.referenceCalibrationMilliseconds =
            calibration.referenceCorrectionMilliseconds(
                for: toneFrequency
            )
        engine.flashDurationSeconds =
            1.0 / max(frameRate, 1.0)
    }

    private var timingLegend: some View {
        HStack {
            Label(
                "AUDIO EARLY",
                systemImage: "chevron.left"
            )
            .foregroundStyle(
                colourTheme.negativeColour
            )

            Spacer()

            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(
                    width: 1,
                    height:
                        isExpandedCanvas
                        ? (isLandscape ? 30 : 34)
                        : (isLandscape ? 22 : 28)
                )

            Spacer()

            HStack(spacing: 5) {
                Text("VIDEO EARLY")
                Image(
                    systemName: "chevron.right"
                )
            }
            .foregroundStyle(
                colourTheme.positiveColour
            )
        }
        .font(
            .system(
                size:
                    isExpandedCanvas
                    ? (isLandscape ? 14 : 15)
                    : (isLandscape ? 10 : 12),
                weight: .semibold
            )
        )
        .padding(
            .horizontal,
            isExpandedCanvas
            ? (isLandscape ? 28 : 46)
            : (isLandscape ? 18 : 34)
        )
        .frame(maxWidth: isExpandedCanvas ? 760 : 620)
    }

    private var referenceControls: some View {
        HStack(spacing: 0) {
            Button {
                flashEnabled.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(
                        systemName: "bolt.fill"
                    )
                    .foregroundStyle(
                        flashEnabled
                        ? colourTheme.negativeColour
                        : Color.white.opacity(0.35)
                    )

                    Text(
                        flashEnabled
                        ? "Flash On"
                        : "Flash Off"
                    )
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(
                    width: 1,
                    height: isLandscape ? 26 : 34
                )

            Menu {
                toneButton(
                    "Tone Off",
                    value: 0
                )
                toneButton(
                    "1 kHz",
                    value: 1000
                )
                toneButton(
                    "2 kHz",
                    value: 2000
                )
                toneButton(
                    "4 kHz",
                    value: 4000
                )
            } label: {
                HStack(spacing: 9) {
                    Image(
                        systemName: "waveform"
                    )
                    .foregroundStyle(
                        toneFrequency > 0
                        ? Color.white
                        : Color.white.opacity(0.35)
                    )

                    Text(toneLabel)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(
            .system(
                size:
                    isExpandedCanvas
                    ? (isLandscape ? 15 : 17)
                    : (isLandscape ? 13 : 15),
                weight: .medium
            )
        )
        .foregroundStyle(
            .white.opacity(0.88)
        )
        .frame(
            height:
                isExpandedCanvas
                ? (isLandscape ? 56 : 72)
                : (isLandscape ? 48 : 65)
        )
        .padding(.horizontal, 10)
        .background(
            Capsule()
                .fill(.white.opacity(0.055))
        )
        .overlay(
            Capsule()
                .stroke(
                    .white.opacity(0.12),
                    lineWidth: 1
                )
        )
        .frame(maxWidth: isExpandedCanvas ? 720 : 620)
    }

    @ViewBuilder
    private func toneButton(
        _ title: String,
        value: Double
    ) -> some View {
        Button {
            toneFrequency = value
        } label: {
            if toneFrequency == value {
                Label(
                    title,
                    systemImage: "checkmark"
                )
            } else {
                Text(title)
            }
        }
    }

    private var toneLabel: String {
        switch toneFrequency {
        case 0:
            return "Tone Off"

        case 1000:
            return "1 kHz"

        case 4000:
            return "4 kHz"

        default:
            return "2 kHz"
        }
    }
}

private struct MeasureScreen: View {
    let units: ContentView.Units
    let frameRate: Double
    let colourTheme: ContentView.ColourTheme
    let isLandscape: Bool
    let isExpandedCanvas: Bool

    @ObservedObject var engine: MeasurementEngine
    @ObservedObject var calibration: DeviceCalibrationManager

    private var focusMode: Bool {
        engine.isRunning
    }

    var body: some View {
        GeometryReader { proxy in
            measureContent(
                availableSize: proxy.size
            )
        }
    }

    private func measureContent(
        availableSize: CGSize
    ) -> some View {
        Group {
            if focusMode && !isLandscape {
                centredPortraitMeasure(
                    availableSize: availableSize
                )
            } else {
                VStack(spacing: 0) {
                    ClockStage(
                        availableSize: availableSize,
                        focusMode: focusMode,
                        isLandscape: isLandscape,
                        milliseconds:
                            engine.offsetMilliseconds ?? 0,
                        units: units,
                        frameRate: frameRate,
                        colourTheme: colourTheme,
                        running: engine.isRunning,
                        buttonAction: toggleRun
                    ) {
                        measurementStatus
                    }

                    measurementResult

                    Spacer(
                        minLength:
                            isLandscape
                            ? 0
                            : 8
                    )

                    if !focusMode && !isLandscape {
                        bottomPill(
                            left: (
                                "bolt.fill",
                                "Flash Detect",
                                colourTheme.negativeColour
                            ),
                            right: (
                                "waveform",
                                "Tone Detect",
                                Color.white
                            )
                        )
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)
                        .frame(maxWidth: isExpandedCanvas ? 720 : 660)
                        .transition(
                            .move(edge: .bottom)
                            .combined(with: .opacity)
                        )
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if focusMode && engine.availableLenses.count > 1 {
                measureLensSelector
                    .padding(.horizontal, isExpandedCanvas ? 30 : 18)
                    .padding(.bottom, isLandscape ? 8 : 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func centredPortraitMeasure(
        availableSize: CGSize
    ) -> some View {
        let clockSide =
            SharedClockLayout.clockSide(
                availableSize: availableSize,
                focusMode: true,
                isLandscape: false
            )

        let centreY = availableSize.height / 2
        let resultHeight: CGFloat = isExpandedCanvas ? 94 : 78
        let lensReserve: CGFloat =
            focusMode && engine.availableLenses.count > 1 ? 48 : 0
        let resultY = min(
            availableSize.height - resultHeight / 2 - 8 - lensReserve,
            centreY + clockSide / 2 + resultHeight / 2 + 10
        )

        return ZStack {
            SyncClock(
                milliseconds:
                    engine.offsetMilliseconds ?? 0,
                units: units,
                frameRate: frameRate,
                colourTheme: colourTheme,
                running: engine.isRunning,
                buttonAction: toggleRun
            )
            .frame(
                width: clockSide,
                height: clockSide
            )
            .position(
                x: availableSize.width / 2,
                y: centreY
            )

            measurementStatus
                .frame(maxWidth: isExpandedCanvas ? 760 : 660)
                .position(
                    x: availableSize.width / 2,
                    y: 16
                )

            measurementResult
                .frame(maxWidth: isExpandedCanvas ? 760 : 660)
                .position(
                    x: availableSize.width / 2,
                    y: resultY
                )
        }
    }

    private var measureLensSelector: some View {
        HStack(spacing: 0) {
            ForEach(engine.availableLenses) { lens in
                Button {
                    engine.selectLens(lens.id)
                } label: {
                    Text(lens.title)
                        .font(
                            .system(
                                size: isExpandedCanvas ? 13 : 11,
                                weight:
                                    engine.selectedLensID == lens.id
                                    ? .semibold
                                    : .regular
                            )
                        )
                        .foregroundStyle(
                            engine.selectedLensID == lens.id
                            ? .white
                            : .white.opacity(0.58)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: isExpandedCanvas ? 34 : 30)
                        .background {
                            if engine.selectedLensID == lens.id {
                                Capsule()
                                    .fill(.white.opacity(0.16))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(
            maxWidth: min(
                isExpandedCanvas ? 420 : 330,
                CGFloat(max(1, engine.availableLenses.count))
                    * (isExpandedCanvas ? 72 : 58)
            )
        )
        .background(
            Capsule()
                .fill(Color.black.opacity(0.58))
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private var measurementStatus: some View {
        let statusFontSize: CGFloat =
            isExpandedCanvas
            ? (isLandscape ? 13 : 12)
            : (isLandscape ? 9 : 10)

        let indicatorSide: CGFloat =
            isExpandedCanvas
            ? 8
            : (isLandscape ? 6 : 7)

        return HStack {
            if engine.isRunning {
                HStack(spacing: isExpandedCanvas ? 8 : 6) {
                    Circle()
                        .fill(
                            colourTheme
                                .positiveColour
                        )
                        .frame(
                            width: indicatorSide,
                            height: indicatorSide
                        )

                    Text(engine.statusText)
                }
                .font(
                    .system(
                        size: statusFontSize,
                        weight: .bold
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.78)
                )
                .lineLimit(1)
            } else {
                Text(engine.statusText)
                    .font(
                        .system(
                            size: statusFontSize,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        .white.opacity(0.48)
                    )
                    .lineLimit(1)
            }

            Spacer()

            if engine.acceptedMeasurements > 0 {
                Text(
                    "\(engine.acceptedMeasurements) readings"
                )
                .font(
                    .system(
                        size: statusFontSize
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.45)
                )
            }
        }
        .padding(
            .horizontal,
            isExpandedCanvas
            ? (isLandscape ? 24 : 36)
            : (isLandscape ? 16 : 28)
        )
    }

    private func toggleRun() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.start(correctionMilliseconds: calibration.measurementCorrectionMilliseconds)
        }
    }

    private var resultPrimaryFontSize: CGFloat {
        if isExpandedCanvas {
            return isLandscape
                ? (focusMode ? 40 : 36)
                : (focusMode ? 52 : 46)
        }

        return isLandscape
            ? (focusMode ? 24 : 23)
            : (focusMode ? 39 : 34)
    }

    private var resultLabelFontSize: CGFloat {
        if isExpandedCanvas {
            return isLandscape ? 11 : 14
        }

        return isLandscape ? 8 : 12
    }

    private var resultSecondaryFontSize: CGFloat {
        if isExpandedCanvas {
            return isLandscape ? 10 : 13
        }

        return isLandscape ? 7 : 11
    }

    private var resultHeight: CGFloat {
        if isExpandedCanvas {
            return isLandscape ? 72 : 94
        }

        return isLandscape ? 48 : 78
    }

    @ViewBuilder
    private var measurementResult: some View {
        if let milliseconds =
            engine.offsetMilliseconds {

            VStack(spacing: isLandscape ? 0 : 2) {
                Text(primaryText(milliseconds))
                    .font(
                        .system(
                            size: resultPrimaryFontSize,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        milliseconds >= 0
                        ? colourTheme.positiveColour
                        : colourTheme.negativeColour
                    )

                Text(
                    milliseconds >= 0
                    ? "VIDEO EARLY"
                    : "AUDIO EARLY"
                )
                .font(
                    .system(
                        size: resultLabelFontSize,
                        weight: .bold
                    )
                )
                .foregroundStyle(
                    milliseconds >= 0
                    ? colourTheme.positiveColour
                    : colourTheme.negativeColour
                )

                Text(secondaryText(milliseconds))
                    .font(
                        .system(
                            size: resultSecondaryFontSize
                        )
                    )
                    .foregroundStyle(
                        .white.opacity(0.56)
                    )
            }
            .frame(
                height: resultHeight
            )

        } else {
            VStack(spacing: isLandscape ? 0 : 3) {
                Text("—")
                    .font(
                        .system(
                            size: resultPrimaryFontSize,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        .white.opacity(0.40)
                    )

                Text(
                    engine.isRunning
                    ? "WAITING FOR FLASH + TONE"
                    : "PRESS START TO MEASURE"
                )
                .font(
                    .system(
                        size: resultSecondaryFontSize,
                        weight: .semibold
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.52)
                )
            }
            .frame(
                height: resultHeight
            )
        }
    }

    private func primaryText(
        _ milliseconds: Double
    ) -> String {
        switch units {
        case .ms:
            return String(
                format: "%+.0f ms",
                milliseconds
            )

        case .frames:
            return String(
                format: "%+.2f fr",
                milliseconds
                    / 1000.0
                    * frameRate
            )
        }
    }

    private func secondaryText(
        _ milliseconds: Double
    ) -> String {
        switch units {
        case .ms:
            return String(
                format:
                    "%+.2f frames @ %@ fps",
                milliseconds
                    / 1000.0
                    * frameRate,
                frameRateText
            )

        case .frames:
            return String(
                format: "%+.0f ms",
                milliseconds
            )
        }
    }

    private var frameRateText: String {
        if frameRate == 29.97 ||
            frameRate == 59.94 {

            return String(
                format: "%.2f",
                frameRate
            )
        }

        return String(
            format: "%.0f",
            frameRate
        )
    }
}


private struct DeviceCalibrationView: View {
    @ObservedObject var manager: DeviceCalibrationManager
    let colourTheme: ContentView.ColourTheme
    let dismiss: () -> Void

    @State private var servicePanelVisible = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.062, blue: 0.060),
                        .black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    calibrationBrand
                        .padding(.top, max(10, proxy.safeAreaInsets.top + 4))
                        .onLongPressGesture(minimumDuration: 2.0) {
                            guard manager.runState != .preparing,
                                  manager.runState != .running else {
                                return
                            }
                            servicePanelVisible = true
                        }

                    Spacer(minLength: 18)

                    calibrationInstrument

                    Spacer(minLength: 18)

                    VStack(spacing: 8) {
                        Text(manager.headline)
                            .font(
                                .system(
                                    size: proxy.size.width > 700 ? 30 : 24,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(.white)

                        Text(manager.detail)
                            .font(
                                .system(
                                    size: proxy.size.width > 700 ? 16 : 13,
                                    weight: .medium
                                )
                            )
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)

                        if !manager.qualityText.isEmpty {
                            Text(manager.qualityText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.46))
                        }
                    }
                    .padding(.horizontal, 28)

                    Spacer(minLength: 20)

                    Button {
                        if manager.runState == .preparing
                            || manager.runState == .running {
                            manager.cancelCalibration()
                        }
                        dismiss()
                    } label: {
                        Text(
                            manager.runState == .preparing
                                || manager.runState == .running
                            ? "CANCEL"
                            : "DONE"
                        )
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.90))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.075))
                        )
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 26)
                    .padding(.bottom, max(14, proxy.safeAreaInsets.bottom + 8))
                }

                if servicePanelVisible {
                    serviceCalibrationPanel
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                CalibrationFlashOverlay(manager: manager)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .statusBarHidden(manager.runState == .running)
    }

    private var calibrationBrand: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: -1) {
                Text("In")
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                Text(".")
                    .font(.system(size: 31, weight: .heavy, design: .rounded))
                    .foregroundStyle(colourTheme.negativeColour)
                Text("Sync")
                    .font(.system(size: 31, weight: .light, design: .rounded))
            }
            .foregroundStyle(.white)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            colourTheme.negativeColour,
                            colourTheme.positiveColour
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 52, height: 2)
        }
    }


    private var serviceCalibrationPanel: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    servicePanelVisible = false
                }

            VStack(spacing: 18) {
                Text("SERVICE ZERO TRIM")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.58))

                Text(
                    String(
                        format: "%.1f ms",
                        manager.serviceMeasureCorrectionMilliseconds
                    )
                )
                .font(.system(size: 38, weight: .light, design: .rounded))
                .foregroundStyle(.white)

                HStack(spacing: 10) {
                    serviceTrimButton(title: "− 0.5") {
                        manager.setServiceMeasureCorrectionMilliseconds(
                            manager.serviceMeasureCorrectionMilliseconds - 0.5
                        )
                    }

                    serviceTrimButton(title: "+ 0.5") {
                        manager.setServiceMeasureCorrectionMilliseconds(
                            manager.serviceMeasureCorrectionMilliseconds + 0.5
                        )
                    }
                }

                HStack(spacing: 10) {
                    serviceTrimButton(title: "RESET") {
                        manager.resetServiceMeasureCorrection()
                    }

                    serviceTrimButton(title: "DONE") {
                        servicePanelVisible = false
                    }
                }

                Text("Hidden service adjustment • saved on this device")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))

                Text(installedBuildLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.vertical, 26)
            .padding(.horizontal, 22)
            .frame(maxWidth: 430)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.055, green: 0.062, blue: 0.060))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
        }
    }

    private var installedBuildLabel: String {
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "In.Sync \(InSyncBuildInfo.internalRevision) • Build \(build)"
    }

    private func serviceTrimButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.075))
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var calibrationInstrument: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: 10)

            Circle()
                .trim(from: 0, to: max(0.002, manager.progress))
                .stroke(
                    LinearGradient(
                        colors: [
                            colourTheme.negativeColour,
                            colourTheme.positiveColour
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 7) {
                Circle()
                    .fill(resultColour)
                    .frame(width: 11, height: 11)
                    .shadow(color: resultColour.opacity(0.65), radius: 5)

                Text(progressText)
                    .font(.system(size: 36, weight: .light, design: .rounded))
                    .foregroundStyle(.white)

                Text(stageText)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .frame(width: 220, height: 220)
    }

    private var progressText: String {
        switch manager.runState {
        case .success:
            return "✓"
        case .failure:
            return "×"
        default:
            return String(format: "%.0f%%", manager.progress * 100)
        }
    }

    private var stageText: String {
        switch manager.runState {
        case .preparing:
            return "PREPARING"
        case .running:
            return "CALIBRATING"
        case .success:
            return "SAVED"
        case .failure:
            return "FAILED"
        case .idle:
            return "READY"
        }
    }

    private var resultColour: Color {
        switch manager.runState {
        case .success:
            return colourTheme.positiveColour
        case .failure:
            return Color(red: 0.92, green: 0.20, blue: 0.18)
        case .preparing, .running, .idle:
            return colourTheme.negativeColour
        }
    }
}

private struct CalibrationFlashOverlay: UIViewRepresentable {
    let manager: DeviceCalibrationManager

    func makeUIView(context: Context) -> CalibrationFlashView {
        let view = CalibrationFlashView()
        manager.attachFlashPresenter(view)
        return view
    }

    func updateUIView(
        _ uiView: CalibrationFlashView,
        context: Context
    ) {
        manager.attachFlashPresenter(uiView)
    }
}

private final class CalibrationFlashView:
    UIView,
    CalibrationFlashPresenting {

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setCalibrationFlashVisible(_ visible: Bool) {
        let update = { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.backgroundColor = (visible
                ? UIColor.white
                : UIColor.clear).cgColor
            CATransaction.commit()
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}

private struct ReferenceFlashOverlay: UIViewRepresentable {
    let engine: ReferenceTimingEngine

    func makeUIView(context: Context) -> ReferenceFlashView {
        let view = ReferenceFlashView()
        engine.attachFlashPresenter(view)
        return view
    }

    func updateUIView(
        _ uiView: ReferenceFlashView,
        context: Context
    ) {
        engine.attachFlashPresenter(uiView)
    }
}

private final class ReferenceFlashView:
    UIView,
    ReferenceFlashPresenting {

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setReferenceFlashVisible(_ visible: Bool) {
        let update = { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.backgroundColor = (visible
                ? UIColor.white
                : UIColor.clear).cgColor
            CATransaction.commit()
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?

    func makeUIView(
        context: Context
    ) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.previewLayer?.videoGravity = .resizeAspectFill
        view.setSession(session, device: device)
        return view
    }

    func updateUIView(
        _ uiView: CapturePreviewView,
        context: Context
    ) {
        uiView.setSession(session, device: device)
        uiView.applyCurrentVideoRotation()
    }
}

private final class CapturePreviewView: UIView {
    private var rotationCoordinator:
        AVCaptureDevice.RotationCoordinator?

    private var rotationObservation: NSKeyValueObservation?
    private var rotationDeviceUniqueID: String?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    func setSession(_ session: AVCaptureSession, device: AVCaptureDevice?) {
        guard let previewLayer else { return }
        let sessionChanged = previewLayer.session !== session
        if sessionChanged {
            previewLayer.session = session
        }
        if sessionChanged || rotationDeviceUniqueID != device?.uniqueID {
            configureRotationCoordinator(for: device)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCurrentVideoRotation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyCurrentVideoRotation()
    }

    private func configureRotationCoordinator(
        for device: AVCaptureDevice?
    ) {
        rotationObservation = nil
        rotationCoordinator = nil
        rotationDeviceUniqueID = nil

        guard let device, let previewLayer else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: previewLayer
        )

        rotationCoordinator = coordinator
        rotationDeviceUniqueID = device.uniqueID
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            let update: () -> Void = { [weak self] in
                guard let self, self.rotationCoordinator === coordinator else { return }
                self.applyVideoRotation(angle)
            }
            if Thread.isMainThread {
                update()
            } else {
                DispatchQueue.main.async(execute: update)
            }
        }
    }

    func applyCurrentVideoRotation() {
        guard let rotationCoordinator else {
            return
        }

        applyVideoRotation(
            rotationCoordinator.videoRotationAngleForHorizonLevelPreview
        )
    }

    private func applyVideoRotation(_ rotationAngle: CGFloat) {
        guard let connection = previewLayer?.connection else {
            return
        }

        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }
}

private struct SyncClock: View {
    let milliseconds: Double
    let units: ContentView.Units
    let frameRate: Double
    let colourTheme: ContentView.ColourTheme
    let running: Bool
    let buttonAction: () -> Void

    // One hundred dots place a larger dot exactly on every 50 ms division.
    private let dotCount = 100
    private let scaleValues = Array(
        stride(
            from: -450,
            through: 450,
            by: 50
        )
    )

    var body: some View {
        GeometryReader { proxy in
            let side = min(
                proxy.size.width,
                proxy.size.height
            )

            let centre = CGPoint(
                x: proxy.size.width / 2,
                y: proxy.size.height / 2
            )

            let radius = side * 0.405

            // Keep the approved iPhone instrument exactly as-is, but scale the
            // fixed-size dots, marker and centre control on larger iPad clocks.
            let instrumentScale =
                side >= 600
                ? min(1.8, side / 420.0)
                : 1.0
            let divisionDotSide = 8.5 * instrumentScale
            let minorDotSide = 5.2 * instrumentScale
            let markerSide = 16.0 * instrumentScale
            let markerShadowRadius = 9.0 * instrumentScale
            let centreButtonSide: CGFloat =
                side >= 650
                ? min(max(side * 0.24, 176), 230)
                : min(max(side * 0.30, 124), 176)
            let centreLabelSize: CGFloat =
                side >= 760
                ? 38
                : (side > 520 ? 31 : 25)

            ZStack {
                ForEach(
                    0..<dotCount,
                    id: \.self
                ) { index in
                    let angle =
                        Double(index)
                        / Double(dotCount)
                        * 2
                        * Double.pi

                    let neutral =
                        index == 0 ||
                        index == dotCount / 2

                    let positive =
                        index > 0 &&
                        index < dotCount / 2

                    let scaleDivision =
                        index % 5 == 0

                    Circle()
                        .fill(
                            neutral
                            ? Color.white.opacity(0.62)
                            : (
                                positive
                                ? colourTheme.positiveColour
                                : colourTheme.negativeColour
                            )
                        )
                        .frame(
                            width:
                                scaleDivision
                                ? divisionDotSide
                                : minorDotSide,
                            height:
                                scaleDivision
                                ? divisionDotSide
                                : minorDotSide
                        )
                        .position(
                            x:
                                centre.x
                                + CGFloat(sin(angle))
                                * radius,
                            y:
                                centre.y
                                - CGFloat(cos(angle))
                                * radius
                        )
                }

                ForEach(
                    scaleValues,
                    id: \.self
                ) { value in
                    let milliseconds = Double(value)
                    let angle =
                        milliseconds
                        / 1000
                        * 2
                        * Double.pi

                    clockLabel(
                        scaleText(value),
                        milliseconds: milliseconds,
                        angle: angle,
                        centre: centre,
                        radius: radius,
                        side: side,
                        major:
                            value == 0 ||
                            abs(value) == 250
                    )
                }

                clockLabel(
                    "±500",
                    milliseconds: 500,
                    angle: .pi,
                    centre: centre,
                    radius: radius,
                    side: side,
                    major: true
                )

                let markerAngle =
                    milliseconds
                    / 1000
                    * 2
                    * Double.pi

                Circle()
                    .fill(.white)
                    .frame(
                        width: markerSide,
                        height: markerSide
                    )
                    .shadow(
                        color:
                            (
                                milliseconds >= 0
                                ? colourTheme
                                    .positiveColour
                                : colourTheme
                                    .negativeColour
                            )
                            .opacity(0.80),
                        radius: markerShadowRadius
                    )
                    .position(
                        x:
                            centre.x
                            + CGFloat(
                                sin(markerAngle)
                            )
                            * radius,
                        y:
                            centre.y
                            - CGFloat(
                                cos(markerAngle)
                            )
                            * radius
                    )

                Button(action: buttonAction) {
                    ZStack {
                        Circle()
                            .fill(
                                .white.opacity(0.075)
                            )

                        Circle()
                            .stroke(
                                running
                                ? colourTheme
                                    .positiveColour
                                    .opacity(0.72)
                                : .white.opacity(0.28),
                                lineWidth: 1.2 * min(instrumentScale, 1.5)
                            )
                            .padding(3 * min(instrumentScale, 1.5))

                        Text(
                            running
                            ? "STOP"
                            : "START"
                        )
                        .font(
                            .system(
                                size: centreLabelSize,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.white)
                    }
                    .frame(
                        width: centreButtonSide,
                        height: centreButtonSide
                    )
                }
                .buttonStyle(.plain)
                .position(centre)
            }
        }
        .aspectRatio(
            1,
            contentMode: .fit
        )
    }

    private func scaleText(
        _ value: Int
    ) -> String {
        if value > 0 {
            return "+\(value)"
        }

        return "\(value)"
    }

    @ViewBuilder
    private func clockLabel(
        _ msText: String,
        milliseconds: Double,
        angle: Double,
        centre: CGPoint,
        radius: CGFloat,
        side: CGFloat,
        major: Bool
    ) -> some View {
        let labelRadius =
            radius
            + side
            * (
                major
                ? 0.076
                : 0.055
            )

        VStack(spacing: 0) {
            Text(
                displayText(
                    msText,
                    milliseconds: milliseconds
                )
            )
            .font(
                .system(
                    size:
                        major
                        ? max(12, side * 0.028)
                        : max(8, side * 0.019),
                    weight: .medium
                )
            )
            .lineLimit(1)
            .minimumScaleFactor(0.72)

            if major {
                Text(
                    units == .ms
                    ? "ms"
                    : "fr"
                )
                .font(
                    .system(
                        size:
                            max(
                                8,
                                side * 0.017
                            )
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.58)
                )
            }
        }
        .foregroundStyle(
            .white.opacity(
                major
                ? 0.88
                : 0.70
            )
        )
        .position(
            x:
                centre.x
                + CGFloat(sin(angle))
                * labelRadius,
            y:
                centre.y
                - CGFloat(cos(angle))
                * labelRadius
        )
    }

    private func displayText(
        _ msText: String,
        milliseconds: Double
    ) -> String {
        guard units == .frames else {
            return msText
        }

        let frames =
            milliseconds
            / 1000.0
            * frameRate

        if msText == "±500" {
            return "±"
                + formatFrames(abs(frames))
        }

        if frames > 0 {
            return "+"
                + formatFrames(frames)
        }

        return formatFrames(frames)
    }

    private func formatFrames(
        _ value: Double
    ) -> String {
        if abs(
            value.rounded() - value
        ) < 0.001 {
            return String(
                format: "%.0f",
                value
            )
        }

        if abs(
            value * 10
            - (value * 10).rounded()
        ) < 0.001 {
            return String(
                format: "%.1f",
                value
            )
        }

        return String(
            format: "%.2f",
            value
        )
    }
}

private func bottomPill(
    left: (String, String, Color),
    right: (String, String, Color),
    compact: Bool = false
) -> some View {
    HStack(spacing: 0) {
        HStack(spacing: 9) {
            Image(
                systemName: left.0
            )
            .foregroundStyle(left.2)

            Text(left.1)
        }
        .frame(maxWidth: .infinity)

        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(
                width: 1,
                height: compact ? 26 : 34
            )

        HStack(spacing: 9) {
            Image(
                systemName: right.0
            )
            .foregroundStyle(right.2)

            Text(right.1)
        }
        .frame(maxWidth: .infinity)
    }
    .font(
        .system(
            size: compact ? 13 : 15,
            weight: .medium
        )
    )
    .foregroundStyle(
        .white.opacity(0.88)
    )
    .frame(
        height: compact ? 48 : 65
    )
    .padding(.horizontal, 10)
    .background(
        Capsule()
            .fill(.white.opacity(0.055))
    )
    .overlay(
        Capsule()
            .stroke(
                .white.opacity(0.12),
                lineWidth: 1
            )
    )
}
