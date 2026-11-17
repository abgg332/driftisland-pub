import Combine
import MCEmojiPicker
import SwiftUI

struct TVZRootView: View {

    @AppStorage("isEnabled", store: TVZUserDefaults.standard)
    var isEnabled = false

    @AppStorage("isRecordingOnly", store: TVZUserDefaults.standard)
    var isRecordingOnly = false

    @AppStorage("useTrackingEffect", store: TVZUserDefaults.standard)
    var useTrackingEffect = false

    @AppStorage("useMorphEffect", store: TVZUserDefaults.standard)
    var useMorphEffect = false

    @AppStorage("useImageEffect", store: TVZUserDefaults.standard)
    var useImageEffect = false

    @AppStorage("useQuickPathEffect", store: TVZUserDefaults.standard)
    var useQuickPathEffect = false

    @AppStorage("fillColorString", store: TVZUserDefaults.standard)
    var fillColorString: String = "235,59,90,0.5"
    @State var fillColor: Color = .clear

    @AppStorage("borderColorString", store: TVZUserDefaults.standard)
    var borderColorString: String = "235,59,90"
    @State var borderColor: Color = .clear

    @AppStorage("quickPathFillColorString", store: TVZUserDefaults.standard)
    var quickPathFillColorString: String = "235,59,90,0.5"
    @State var quickPathFillColor: Color = .clear

    @AppStorage("trackingFillColorString", store: TVZUserDefaults.standard)
    var trackingFillColorString: String = "235,59,90,0.5"
    @State var trackingFillColor: Color = .clear

    @AppStorage("trackingBorderColorString", store: TVZUserDefaults.standard)
    var trackingBorderColorString: String = "235,59,90"
    @State var trackingBorderColor: Color = .clear

    @AppStorage("imageShouldAutoRotate", store: TVZUserDefaults.standard)
    var imageShouldAutoRotate = false

    @AppStorage("imageFillName", store: TVZUserDefaults.standard)
    var imageFillName: String = Self.defaultFillImageName
    static let defaultFillImageName = "default.png"

    @AppStorage("alpha", store: TVZUserDefaults.standard)
    var alpha: Double = 0.5
    let minimumAlpha: Double = 0.0
    let maximumAlpha: Double = 1.0
    let alphaStep: Double = 0.01

    @AppStorage("fillSize", store: TVZUserDefaults.standard)
    var fillSize: Double = 40.0
    let minimumFillSize: Double = 20.0
    let maximumFillSize: Double = 60.0
    let fillSizeStep: Double = 0.1

    @AppStorage("borderWidth", store: TVZUserDefaults.standard)
    var borderWidth: Double = 3.0
    let minimumBorderWidth: Double = 0.0
    let maximumBorderWidth: Double = 10.0
    let borderWidthStep: Double = 0.1

    @AppStorage("cornerRadius", store: TVZUserDefaults.standard)
    var cornerRadius: Double = 30.0
    let minimumCornerRadius: Double = 0.0
    let maximumCornerRadius: Double = 30.0
    let cornerRadiusStep: Double = 0.1

    @AppStorage("animationDuration", store: TVZUserDefaults.standard)
    var animationDuration: TimeInterval = 0.3
    let minimumAnimationDuration: TimeInterval = 0.0
    let maximumAnimationDuration: TimeInterval = 3.0
    let animationDurationStep: TimeInterval = 0.1

    @AppStorage("liftScale", store: TVZUserDefaults.standard)
    var liftScale: Double = 2.0
    let minimumLiftScale: Double = 1.0
    let maximumLiftScale: Double = 5.0
    let liftScaleStep: Double = 0.1

    @AppStorage("enableOverride", store: TVZUserDefaults.standard)
    var enableOverride: Bool = false

    @AppStorage("disableOverride", store: TVZUserDefaults.standard)
    var disableOverride: Bool = false

    @State var isPresentingResetPrompt = false
    @State var isShowingEnableOverrideHint = false
    @State var isShowingDisableOverrideHint = false

    @AppStorage("selectedEmoji", store: TVZUserDefaults.standard)
    var selectedEmoji: String = ""
    @State var isPresentingEmojiPicker = false

    @State var isPresentingFillImagePicker = false
    @State var hasFillImage = false
    @State var fillImage: UIImage?

    private let scrollViewSubject: CurrentValueSubject<UIScrollView?, Never>
    private let timer = Timer.publish(every: 1, on: .main, in: .default).autoconnect()
    private let feedbackGenerator: UINotificationFeedbackGenerator = UINotificationFeedbackGenerator()

    init(scrollViewSubject: CurrentValueSubject<UIScrollView?, Never>) {
        self.scrollViewSubject = scrollViewSubject
    }

    func reload() {
        let fillColorString = TVZUserDefaults.standard.string(forKey: "fillColorString") ?? "235,59,90,0.5"
        fillColor = Color(rgbString: fillColorString)

        let borderColorString = TVZUserDefaults.standard.string(forKey: "borderColorString") ?? "235,59,90"
        borderColor = Color(rgbString: borderColorString)

        let quickPathFillColorString = TVZUserDefaults.standard.string(forKey: "quickPathFillColorString") ?? "235,59,90,0.3"
        quickPathFillColor = Color(rgbString: quickPathFillColorString)

        let trackingFillColorString = TVZUserDefaults.standard.string(forKey: "trackingFillColorString") ?? "235,59,90,0.2"
        trackingFillColor = Color(rgbString: trackingFillColorString)

        let trackingBorderColorString = TVZUserDefaults.standard.string(forKey: "trackingBorderColorString") ?? "235,59,90,0.4"
        trackingBorderColor = Color(rgbString: trackingBorderColorString)

        fillImage = Bundle.tvz_fillImageNamed(imageFillName)
        hasFillImage = fillImage != nil && imageFillName != Self.defaultFillImageName
    }

    func reloadOverrides() {
        isShowingEnableOverrideHint = isEnabled && isRecordingOnly && enableOverride
        isShowingDisableOverrideHint = isEnabled && !isRecordingOnly && disableOverride
    }

    var body: some View {
        mainBody
    }

    var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Touch-Viz", bundle: Bundle.tvz_support, comment: ""))
                    .font(.system(size: 42))
                    .fontWeight(.bold)
                    .foregroundColor(TVZ_COLOR)

                Text(String(format: NSLocalizedString("v%@ - @Lessica", bundle: Bundle.tvz_support, comment: ""), Bundle.tvz_packageVersion))
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    var generalSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                LabelWithImageIcon(NSLocalizedString("Enable Touch-Viz", bundle: Bundle.tvz_support, comment: ""), systemImage: "power")
                    .foregroundColor(TVZ_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: TVZ_COLOR))

            Toggle(isOn: $isRecordingOnly) {
                LabelWithSubtitle(
                    NSLocalizedString("Only for Recording", bundle: Bundle.tvz_support, comment: ""),
                    subtitle: NSLocalizedString("Displays touch indicators only during screen recording.", bundle: Bundle.tvz_support, comment: ""),
                    systemImage: "dot.circle.and.hand.point.up.left.fill"
                )
                .foregroundColor(TVZ_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: TVZ_COLOR))
        } header: {
            Text(NSLocalizedString("General", bundle: Bundle.tvz_support, comment: ""))
        } footer: {
            if isShowingEnableOverrideHint {
                Text(NSLocalizedString("Touch-Viz has been turned on from Control Center.", bundle: Bundle.tvz_support, comment: ""))
            } else if isShowingDisableOverrideHint {
                Text(NSLocalizedString("Touch-Viz has been turned off from Control Center.", bundle: Bundle.tvz_support, comment: ""))
            }
        }
    }

    var colorsSection: some View {
        Section {
            ColorPicker(selection: $fillColor) {
                LabelWithImageIcon(NSLocalizedString("Fill Color", bundle: Bundle.tvz_support, comment: ""), systemImage: "paintpalette")
                    .foregroundColor(TVZ_COLOR)
            }
            .onChange(of: fillColor) { color in
                fillColorString = color.toRGBString()
            }

            ColorPicker(selection: $borderColor) {
                LabelWithImageIcon(NSLocalizedString("Border Color", bundle: Bundle.tvz_support, comment: ""), systemImage: "paintbrush.pointed")
                    .foregroundColor(TVZ_COLOR)
            }
            .onChange(of: borderColor) { color in
                borderColorString = color.toRGBString()
            }
        } header: {
            Text(NSLocalizedString("Touch Colors", bundle: Bundle.tvz_support, comment: ""))
        }
    }

    var alphaSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    alpha = max(minimumAlpha, alpha - alphaStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $alpha, in: minimumAlpha...maximumAlpha, step: alphaStep)
                Button {
                    alpha = min(maximumAlpha, alpha + alphaStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Opacity", bundle: Bundle.tvz_support, comment: ""))
                Spacer()
                Text(String(format: "%.0f%%", alpha * 100))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var fillSizeSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    fillSize = max(minimumFillSize, fillSize - fillSizeStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $fillSize, in: minimumFillSize...maximumFillSize, step: fillSizeStep)
                Button {
                    fillSize = min(maximumFillSize, fillSize + fillSizeStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Fill Size", bundle: Bundle.tvz_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f pt", fillSize))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var borderWidthSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    borderWidth = max(minimumBorderWidth, borderWidth - borderWidthStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $borderWidth, in: minimumBorderWidth...maximumBorderWidth, step: borderWidthStep)
                Button {
                    borderWidth = min(maximumBorderWidth, borderWidth + borderWidthStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Border Width", bundle: Bundle.tvz_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f pt", borderWidth))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var cornerRadiusSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    cornerRadius = max(minimumCornerRadius, cornerRadius - cornerRadiusStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $cornerRadius, in: minimumCornerRadius...maximumCornerRadius, step: cornerRadiusStep)
                Button {
                    cornerRadius = min(maximumCornerRadius, cornerRadius + cornerRadiusStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Corner Radius", bundle: Bundle.tvz_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f pt", cornerRadius))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var animationDurationSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    animationDuration = max(minimumAnimationDuration, animationDuration - animationDurationStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $animationDuration, in: minimumAnimationDuration...maximumAnimationDuration, step: animationDurationStep)
                Button {
                    animationDuration = min(maximumAnimationDuration, animationDuration + animationDurationStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Animation Duration", bundle: Bundle.tvz_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f s", animationDuration))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var liftScaleSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    liftScale = max(minimumLiftScale, liftScale - liftScaleStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
                Slider(value: $liftScale, in: minimumLiftScale...maximumLiftScale, step: liftScaleStep)
                Button {
                    liftScale = min(maximumLiftScale, liftScale + liftScaleStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(TVZ_COLOR)
                }
                .buttonStyle(PlainButtonStyle())
            }
        } header: {
            HStack(alignment: .lastTextBaseline) {
                Text(NSLocalizedString("Lift Scale", bundle: Bundle.tvz_support, comment: ""))
                Spacer()
                Text(String(format: "%.1f x", liftScale))
                    .font(.footnote.monospacedDigit())
                    .textCase(nil)
            }
        }
    }

    var effectsSection: some View {
        Section {
            Toggle(isOn: $useTrackingEffect) {
                LabelWithImageIcon(NSLocalizedString("Tracking Effect", bundle: Bundle.tvz_support, comment: ""), systemImage: "circle.hexagonpath")
                    .foregroundColor(TVZ_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: TVZ_COLOR))

            Toggle(isOn: $useQuickPathEffect) {
                LabelWithImageIcon(NSLocalizedString("Quick Path Effect", bundle: Bundle.tvz_support, comment: ""), systemImage: "scribble.variable")
                    .foregroundColor(TVZ_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: TVZ_COLOR))

            Toggle(isOn: $useMorphEffect) {
                LabelWithImageIcon(NSLocalizedString("Morph Effect", bundle: Bundle.tvz_support, comment: ""), systemImage: "lasso")
                    .foregroundColor(TVZ_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: TVZ_COLOR))

            Toggle(isOn: $useImageEffect) {
                LabelWithImageIcon(NSLocalizedString("Image Effect", bundle: Bundle.tvz_support, comment: ""), systemImage: "photo.on.rectangle.angled")
                    .foregroundColor(TVZ_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: TVZ_COLOR))
        } header: {
            Text(NSLocalizedString("Effects", bundle: Bundle.tvz_support, comment: ""))
        }
    }

    var quickPathEffectSection: some View {
        Section {
            ColorPicker(selection: $quickPathFillColor) {
                LabelWithImageIcon(NSLocalizedString("Fill Color", bundle: Bundle.tvz_support, comment: ""), systemImage: "paintpalette")
                    .foregroundColor(TVZ_COLOR)
            }
            .onChange(of: quickPathFillColor) { color in
                quickPathFillColorString = color.toRGBString()
            }

            Button {
                if useImageEffect, let fillImage, let primaryColor = fillImage.averageColor {
                    quickPathFillColor = Color(uiColor: primaryColor)
                } else {
                    quickPathFillColor = fillColor
                }
                feedbackGenerator.notificationOccurred(.success)
            } label: {
                Label(NSLocalizedString("Use Suggested Colors", bundle: Bundle.tvz_support, comment: ""), systemImage: "doc.on.doc")
                    .foregroundColor(TVZ_COLOR)
            }
        } header: {
            Text(NSLocalizedString("Quick Path Effect", bundle: Bundle.tvz_support, comment: ""))
        }
    }

    var trackingEffectSection: some View {
        Section {
            ColorPicker(selection: $trackingFillColor) {
                LabelWithImageIcon(NSLocalizedString("Fill Color", bundle: Bundle.tvz_support, comment: ""), systemImage: "paintpalette")
                    .foregroundColor(TVZ_COLOR)
            }
            .onChange(of: trackingFillColor) { color in
                trackingFillColorString = color.toRGBString()
            }

            ColorPicker(selection: $trackingBorderColor) {
                LabelWithImageIcon(NSLocalizedString("Border Color", bundle: Bundle.tvz_support, comment: ""), systemImage: "paintbrush.pointed")
                    .foregroundColor(TVZ_COLOR)
            }
            .onChange(of: trackingBorderColor) { color in
                trackingBorderColorString = color.toRGBString()
            }

            Button {
                trackingFillColor = fillColor.opacity(0.4)
                trackingBorderColor = borderColor.opacity(0.4)
                feedbackGenerator.notificationOccurred(.success)
            } label: {
                Label(NSLocalizedString("Use Suggested Colors", bundle: Bundle.tvz_support, comment: ""), systemImage: "doc.on.doc")
                    .foregroundColor(TVZ_COLOR)
            }
        } header: {
            Text(NSLocalizedString("Tracking Effect", bundle: Bundle.tvz_support, comment: ""))
        }
    }

    var imageEffectOptionSection: some View {
        Section {
            Toggle(isOn: $imageShouldAutoRotate) {
                LabelWithSubtitle(
                    NSLocalizedString("Auto Rotate", bundle: Bundle.tvz_support, comment: ""),
                    subtitle: NSLocalizedString("Automatically rotates the image to match the path direction.", bundle: Bundle.tvz_support, comment: ""),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .foregroundColor(TVZ_COLOR)
            }
            .toggleStyle(SwitchToggleStyle(tint: TVZ_COLOR))

            Button {
                fillColor = .clear
                borderColor = .clear
                trackingFillColor = .clear
                trackingBorderColor = .clear
                feedbackGenerator.notificationOccurred(.success)
            } label: {
                Label(NSLocalizedString("Use Clear Colors", bundle: Bundle.tvz_support, comment: ""), systemImage: "circle.dashed")
                    .foregroundColor(TVZ_COLOR)
            }
        } header: {
            Text(NSLocalizedString("Image Effect", bundle: Bundle.tvz_support, comment: ""))
        }
    }

    var imageEffectPreview: some View {
        VStack(alignment: .center) {
            if let fillImage {
                Image(uiImage: fillImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeIn, value: fillImage)
    }

    var imageEffectSection: some View {
        Section {
            Group {
                if #available(iOS 16.0, *) {
                    imageEffectPreview
                } else {
                    imageEffectPreview
                        .padding(.vertical, 8)
                }
            }
            .emojiPicker(
                isPresented: $isPresentingEmojiPicker,
                selectedEmoji: $selectedEmoji,
                arrowDirection: .down
            )

            Button {
                isPresentingEmojiPicker.toggle()
            } label: {
                Label(NSLocalizedString("Select Emoji", bundle: Bundle.tvz_support, comment: ""), systemImage: "face.smiling")
                    .foregroundColor(TVZ_COLOR)
            }

            Button {
                isPresentingFillImagePicker.toggle()
            } label: {
                Label(NSLocalizedString("Select Image", bundle: Bundle.tvz_support, comment: ""), systemImage: "doc.badge.plus")
                    .foregroundColor(TVZ_COLOR)
            }
        } header: {
            Text(NSLocalizedString("Custom Image", bundle: Bundle.tvz_support, comment: ""))
        }
        .onChange(of: selectedEmoji) { emoji in
            guard !emoji.isEmpty else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation {
                    imageFillName = Bundle.tvz_saveFillImage(with: emoji.render(size: String.nativeEmojiSize)) ?? Self.defaultFillImageName
                    TVZUserDefaults.standard.darwinNotify()
                    reload()
                }
            }
        }
    }

    var resetSection: some View {
        Section {
            Button(role: .destructive) {
                isPresentingResetPrompt = true
            } label: {
                Label(NSLocalizedString("Reset to Default", bundle: Bundle.tvz_support, comment: ""), systemImage: "arrow.counterclockwise")
                    .foregroundColor(TVZ_COLOR)
            }
        } footer: {
            Text(String(format: "%@\n\n%@",
                NSLocalizedString("Copyright © 2024-2025 OwnGoal Studio.", bundle: Bundle.tvz_support, comment: ""),
                NSLocalizedString("Credits:\n@LeoNatan: LNTouchVisualizer (MIT License)\nIvan Izyumkin: MCEmojiPicker (MIT License)", bundle: Bundle.tvz_support, comment: "")))
                .padding(.bottom, 8)
        }
    }

    var resetPrompt: Alert {
        Alert(
            title: Text(NSLocalizedString("Reset to Default", bundle: Bundle.tvz_support, comment: "")),
            message: Text(NSLocalizedString("Are you sure you want to reset all settings to their default values?", bundle: Bundle.tvz_support, comment: "")),
            primaryButton: .cancel(),
            secondaryButton: .destructive(Text(NSLocalizedString("Reset", bundle: Bundle.tvz_support, comment: ""))) {
                withAnimation {
                    if Bundle.tvz_removeAllFillImages() {
                        imageFillName = Self.defaultFillImageName
                        selectedEmoji = ""
                    }
                    TVZUserDefaults.standard.resetToDefaultValues()
                    reload()
                }
            }
        )
    }

    var mainBody: some View {
        Form {
            header
            generalSection
            colorsSection
            alphaSection
            fillSizeSection
            borderWidthSection
            cornerRadiusSection
            animationDurationSection
            liftScaleSection
            effectsSection

            if useTrackingEffect {
                trackingEffectSection
            }

            if useQuickPathEffect {
                quickPathEffectSection
            }

            if useImageEffect {
                imageEffectOptionSection
                imageEffectSection
            }

            resetSection
        }
        .tint(TVZ_COLOR)
        .transition(.opacity)
        .listStyle(.insetGrouped)
        .animation(.easeIn, value: useQuickPathEffect)
        .animation(.easeIn, value: useTrackingEffect)
        .animation(.easeIn, value: useImageEffect)
        .animation(.easeIn, value: hasFillImage)
        .alert(isPresented: $isPresentingResetPrompt) { resetPrompt }
        .fileImporter(
            isPresented: $isPresentingFillImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: fileImporterResultHandler
        )
        .onAppear {
            reload()
            reloadOverrides()
        }
        .onReceive(timer) { _ in
            withAnimation {
                reloadOverrides()
            }
        }
        .introspect(.list, on: .iOS(.v13, .v14, .v15)) {
            scrollViewSubject.send($0)
        }
        .introspect(.list, on: .iOS(.v16, .v17, .v18)) {
            scrollViewSubject.send($0)
        }
    }

    private func fileImporterResultHandler(result: Result<[URL], Error>) {
        do {
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation {
                        imageFillName = Bundle.tvz_saveFillImage(withPath: url.path) ?? Self.defaultFillImageName
                        TVZUserDefaults.standard.darwinNotify()
                        reload()
                    }
                }
            case .failure(let error):
                throw error
            }
        } catch {
            feedbackGenerator.notificationOccurred(.error)
        }
    }
}
