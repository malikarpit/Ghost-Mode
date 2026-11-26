//
//  PopoverViews.swift
//  Ghost Mode
//
//  macOS 12.0+ compatible SwiftUI popover UI with adaptive Glassmorphism,
//  macOS 26+ native Liquid Glass buttons, and zero @State/@FocusState macros.
//

import AppKit
import SwiftUI

private enum DesignTokens {
    static let popoverWidth: CGFloat = 392
    static let defaultMaxBodyHeight: CGFloat = 520
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let sectionGap: CGFloat = 8
    static let cardPadding: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let cardBorder = Color.primary.opacity(0.09)

    static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Dynamic Height Measurement

private struct PopoverContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct TabContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

// MARK: - Persistent Root UI State (CLT Swift 6.4.2-safe, zero State/FocusState macros)

enum SafetyRoute: Equatable {
    case root
    case appWhitelist
    case audioRules
}

final class PopoverUIState: ObservableObject {
    @Published var safetyRoute: SafetyRoute = .root
    @Published var appSearchQuery: String = ""
    @Published var showCustomDuration: Bool = false
    @Published var customDurationText: String = ""
    @Published var showCustomBattery: Bool = false
    @Published var customBatteryText: String = ""
    @Published var showCustomDefault: Bool = false
    @Published var customDefaultText: String = ""
    @Published var confirmingSudoRevoke: Bool = false
    @Published var confirmingResetDefaults: Bool = false
    @Published var sessionNeedsScroll: Bool = false
    @Published var safetyNeedsScroll: Bool = false
    @Published var settingsNeedsScroll: Bool = false
    @Published var hostHeight: CGFloat
    var lastReportedHeight: CGFloat = 0

    init(hostHeight: CGFloat = 720) {
        self.hostHeight = hostHeight
    }
}

// MARK: - Root Popover View

struct FixedTopPopoverHost: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var uiState: PopoverUIState
    let maxBodyHeight: CGFloat
    let onPreferredHeightChange: ((CGFloat) -> Void)?

    var body: some View {
        GhostModePopoverView(
            viewModel: viewModel,
            preferences: preferences,
            uiState: uiState,
            maxBodyHeight: maxBodyHeight,
            onPreferredHeightChange: onPreferredHeightChange
        )
        .frame(width: DesignTokens.popoverWidth, height: uiState.hostHeight, alignment: .topLeading)
    }
}

public struct GhostModePopoverView: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences
    private let maxBodyHeight: CGFloat
    private let onPreferredHeightChange: ((CGFloat) -> Void)?

    @StateObject private var uiState: PopoverUIState

    public init(
        viewModel: GhostModeViewModel,
        preferences: Preferences,
        maxBodyHeight: CGFloat = 520,
        onPreferredHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.maxBodyHeight = maxBodyHeight
        self.onPreferredHeightChange = onPreferredHeightChange
        self._uiState = StateObject(wrappedValue: PopoverUIState())
    }

    init(
        viewModel: GhostModeViewModel,
        preferences: Preferences,
        uiState: PopoverUIState,
        maxBodyHeight: CGFloat = 520,
        onPreferredHeightChange: ((CGFloat) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.maxBodyHeight = maxBodyHeight
        self.onPreferredHeightChange = onPreferredHeightChange
        self._uiState = StateObject(wrappedValue: uiState)
    }

    private var bannerHeightAllowance: CGFloat {
        var allowance: CGFloat = 0
        if !viewModel.snapshot.sudoConfigured {
            allowance += 64
        }
        if viewModel.inlineBanner != nil {
            allowance += 54
        }
        return allowance
    }

    private var effectiveMaxBodyHeight: CGFloat {
        max(180, maxBodyHeight - bannerHeightAllowance)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.sectionGap) {
            HeaderBarView(
                viewModel: viewModel,
                preferences: preferences,
                uiState: uiState
            )

            if !viewModel.snapshot.sudoConfigured {
                SudoSetupBannerView(onSetup: {
                    viewModel.setupOrRevokeSudo()
                })
            }

            if let banner = viewModel.inlineBanner {
                InlineBannerCard(banner: banner, onDismiss: {
                    viewModel.dismissBanner()
                })
            }

            ZStack(alignment: .topLeading) {
                switch viewModel.selectedTab {
                case .session:
                    SessionTabView(
                        viewModel: viewModel,
                        preferences: preferences,
                        uiState: uiState,
                        maxBodyHeight: effectiveMaxBodyHeight
                    )
                case .safety:
                    SafetyTabView(
                        viewModel: viewModel,
                        preferences: preferences,
                        uiState: uiState,
                        maxBodyHeight: effectiveMaxBodyHeight
                    )
                case .prefs:
                    SettingsTabView(
                        viewModel: viewModel,
                        preferences: preferences,
                        uiState: uiState,
                        maxBodyHeight: effectiveMaxBodyHeight
                    )
                }
            }

            FooterBarView(viewModel: viewModel)
        }
        .padding(.horizontal, DesignTokens.horizontalPadding)
        .padding(.vertical, DesignTokens.verticalPadding)
        .frame(width: DesignTokens.popoverWidth, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: PopoverContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PopoverContentHeightKey.self) { height in
            let rounded = round(height)
            guard rounded > 0, abs(rounded - uiState.lastReportedHeight) > 1 else { return }
            uiState.lastReportedHeight = rounded
            onPreferredHeightChange?(rounded)
        }
        .onReceive(viewModel.$isPopoverVisible.removeDuplicates().dropFirst()) { visible in
            if !visible {
                uiState.lastReportedHeight = 0
            }
        }
        .onReceive(viewModel.$selectedTab.removeDuplicates().dropFirst()) { _ in
            uiState.safetyRoute = .root
            uiState.confirmingSudoRevoke = false
            uiState.confirmingResetDefaults = false
        }
        .onReceive(viewModel.$snapshot) { snapshot in
            if !snapshot.sudoConfigured && uiState.safetyRoute != .root {
                uiState.safetyRoute = .root
            }
        }
        .background(Color.clear)
    }
}

private struct AdaptiveTabBody<Content: View>: View {
    let maxHeight: CGFloat
    let needsScroll: Bool
    let onNeedsScrollChange: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if needsScroll {
            ScrollView(.vertical, showsIndicators: true) {
                measuredContent
            }
            .frame(height: maxHeight, alignment: .top)
            .clipped()
        } else {
            measuredContent
        }
    }

    private var measuredContent: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: TabContentHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(TabContentHeightKey.self) { measured in
                let nextNeedsScroll = needsScroll
                    ? (measured > maxHeight - 1)
                    : (measured > maxHeight + 1)
                guard nextNeedsScroll != needsScroll else { return }
                DispatchQueue.main.async {
                    onNeedsScrollChange(nextNeedsScroll)
                }
            }
    }
}

// MARK: - Focus Suppression, Liquid Glass Helpers & 3D Tactile Depth

private extension View {
    @ViewBuilder
    func noFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }

    /// Subtle top-lit specular stroke rim + grounding shadow for macOS 26+ `.glass` / `.glassProminent` buttons.
    /// Intentionally avoids white fill overlays so glass button text stays crisp and unwashed.
    func tactileGlassRim<S: InsettableShape>(
        shape: S,
        tint: Color? = nil,
        borderTint: Color? = nil,
        prominent: Bool = false
    ) -> some View {
        let topRim = prominent ? 0.36 : 0.24
        let shadowColor = tint ?? .black
        return self
            .overlay(
                Group {
                    if let borderTint = borderTint {
                        shape.strokeBorder(borderTint, lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(topRim), Color.white.opacity(0.05), Color.black.opacity(0.18)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: shadowColor.opacity(0.30), radius: 2.5, x: 0, y: 1.5)
    }

    /// Tactile bevel + specular rim + shadow for pre-macOS 26 fallback buttons.
    func tactileFallbackBevel<S: InsettableShape>(
        shape: S,
        tint: Color? = nil,
        prominent: Bool = false
    ) -> some View {
        let topSheen = prominent ? 0.24 : 0.12
        let topRim = prominent ? 0.36 : 0.26
        let shadowColor = tint ?? .black
        return self
            .overlay(
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(topSheen), Color.white.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(topRim), Color.white.opacity(0.05), Color.black.opacity(0.20)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: shadowColor.opacity(0.28), radius: 2.5, x: 0, y: 1.5)
    }
}

private struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Adaptive Glass Card (12pt concentric inside 18pt panel)

private struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
        content
            .padding(DesignTokens.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape.fill(cardFillGradient)
            )
            .overlay(
                shape.strokeBorder(cardSpecularBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }

    private var cardFillGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [Color.white.opacity(0.55), Color.white.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var cardSpecularBorder: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [Color.white.opacity(0.75), Color.black.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Shared Controls

private struct SectionHeaderLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }
}

private struct SettingToggleRow<TrailingAccessory: View>: View {
    let title: String
    var systemImage: String? = nil
    var iconColor: Color = .secondary
    @Binding var isOn: Bool
    var isEnabled: Bool = true
    var fontSize: CGFloat = 12
    @ViewBuilder let trailingAccessory: () -> TrailingAccessory

    init(
        _ title: String,
        systemImage: String? = nil,
        iconColor: Color = .secondary,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        fontSize: CGFloat = 12,
        @ViewBuilder trailingAccessory: @escaping () -> TrailingAccessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.iconColor = iconColor
        self._isOn = isOn
        self.isEnabled = isEnabled
        self.fontSize = fontSize
        self.trailingAccessory = trailingAccessory
    }

    private var displayedIsOn: Binding<Bool> {
        Binding(
            get: { SudoFeatureAvailability.effectiveLidFeatureToggle(storedValue: isOn, sudoConfigured: isEnabled) },
            set: { if isEnabled { isOn = $0 } }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage = systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor((isEnabled && isOn) ? iconColor : .secondary)
                    .frame(width: 15, alignment: .center)
            }

            Text(title)
                .font(.system(size: fontSize))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            trailingAccessory()

            Spacer(minLength: 8)

            Toggle("", isOn: displayedIsOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(height: 20)
                .noFocusRing()
        }
        .opacity(isEnabled ? 1.0 : 0.45)
        .disabled(!isEnabled)
    }
}

private extension SettingToggleRow where TrailingAccessory == EmptyView {
    init(
        _ title: String,
        systemImage: String? = nil,
        iconColor: Color = .secondary,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        fontSize: CGFloat = 12
    ) {
        self.init(
            title,
            systemImage: systemImage,
            iconColor: iconColor,
            isOn: isOn,
            isEnabled: isEnabled,
            fontSize: fontSize
        ) { EmptyView() }
    }
}

private enum FlatButtonTone {
    case accent
    case neutral
    case destructive
    case warning

    var foreground: Color {
        switch self {
        case .accent: return .accentColor
        case .neutral: return .primary
        case .destructive: return .red
        case .warning: return .orange
        }
    }

    func nonProminentGlassForeground(colorScheme: ColorScheme) -> Color {
        switch self {
        case .neutral, .accent, .warning:
            return .primary
        case .destructive:
            return colorScheme == .dark
                ? Color(red: 1.0, green: 0.48, blue: 0.44)
                : Color(red: 0.78, green: 0.10, blue: 0.10)
        }
    }

    var glassTint: Color? {
        switch self {
        case .accent: return .accentColor
        case .neutral: return nil
        case .destructive: return .red
        case .warning: return .orange
        }
    }

    var glassRimBorder: Color? {
        switch self {
        case .neutral: return nil
        case .accent: return Color.accentColor.opacity(0.45)
        case .destructive: return Color.red.opacity(0.38)
        case .warning: return Color.orange.opacity(0.42)
        }
    }

    var fill: Color {
        switch self {
        case .accent: return Color.accentColor.opacity(0.16)
        case .neutral: return Color.primary.opacity(0.06)
        case .destructive: return Color.red.opacity(0.12)
        case .warning: return Color.orange.opacity(0.15)
        }
    }

    var border: Color {
        switch self {
        case .accent: return Color.accentColor.opacity(0.45)
        case .neutral: return DesignTokens.cardBorder
        case .destructive: return Color.red.opacity(0.32)
        case .warning: return Color.orange.opacity(0.40)
        }
    }

    var prominentFill: Color {
        switch self {
        case .accent: return Color.accentColor.opacity(0.88)
        case .neutral: return Color.primary.opacity(0.18)
        case .destructive: return Color.red.opacity(0.88)
        case .warning: return Color.orange.opacity(0.88)
        }
    }

    var prominentForeground: Color {
        switch self {
        case .neutral: return .primary
        case .accent, .destructive, .warning: return .white
        }
    }
}

private struct FlatActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let tone: FlatButtonTone
    var prominent: Bool = false
    var height: CGFloat = 26
    var horizontalPadding: CGFloat = 10
    var fontSize: CGFloat = 11.5
    var fontWeight: Font.Weight = .semibold
    var expandWidth: Bool = false
    var fixedWidth: CGFloat? = nil
    var monospaced: Bool = false
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            glassButton
                .controlSize(height <= 24 ? .small : .regular)
                .buttonBorderShape(.capsule)
                .tactileGlassRim(
                    shape: Capsule(),
                    tint: prominent ? tone.glassTint : nil,
                    borderTint: prominent ? nil : tone.glassRimBorder,
                    prominent: prominent
                )
                .noFocusRing()
        } else {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
            Button(action: action) {
                labelText(foreground: prominent ? tone.prominentForeground : tone.foreground)
                    .background(
                        shape
                            .fill(prominent ? tone.prominentFill : tone.fill)
                    )
                    .overlay(
                        shape
                            .strokeBorder(tone.border, lineWidth: 1)
                    )
                    .tactileFallbackBevel(
                        shape: shape,
                        tint: prominent ? tone.glassTint : nil,
                        prominent: prominent
                    )
            }
            .buttonStyle(.plain)
            .noFocusRing()
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private var glassButton: some View {
        if prominent {
            Button(action: action) {
                labelText(foreground: tone.prominentForeground)
            }
            .buttonStyle(.glassProminent)
            .tint(tone.glassTint)
        } else {
            Button(action: action) {
                labelText(foreground: tone.nonProminentGlassForeground(colorScheme: colorScheme))
            }
            .buttonStyle(.glass)
            .tint(nil)
        }
    }

    @ViewBuilder
    private func labelText(foreground: Color) -> some View {
        let base = Text(title)
            .font(.system(size: fontSize, weight: fontWeight))
            .lineLimit(1)
        Group {
            if monospaced {
                base.monospacedDigit()
            } else {
                base
            }
        }
        .foregroundColor(foreground)
        .padding(.horizontal, fixedWidth == nil ? horizontalPadding : 0)
        .frame(width: fixedWidth)
        .frame(maxWidth: (fixedWidth == nil && expandWidth) ? .infinity : nil)
        .frame(height: height)
    }
}

private struct SelectablePillButton: View {
    let title: String
    let isSelected: Bool
    var height: CGFloat = 26
    var horizontalPadding: CGFloat = 8
    var fontSize: CGFloat = 11.5
    var expandWidth: Bool = true
    var monospaced: Bool = true
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            glassPill
                .buttonBorderShape(.capsule)
                .tactileGlassRim(
                    shape: Capsule(),
                    tint: isSelected ? .accentColor : nil,
                    prominent: isSelected
                )
                .noFocusRing()
        } else {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
            Button(action: action) {
                pillLabel(foreground: isSelected ? .white : .primary)
                    .background(
                        shape
                            .fill(isSelected ? Color.accentColor.opacity(0.88) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        shape
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.65) : DesignTokens.cardBorder, lineWidth: 1)
                    )
                    .tactileFallbackBevel(
                        shape: shape,
                        tint: isSelected ? .accentColor : nil,
                        prominent: isSelected
                    )
            }
            .buttonStyle(.plain)
            .noFocusRing()
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private var glassPill: some View {
        if isSelected {
            Button(action: action) {
                pillLabel(foreground: .white)
            }
            .buttonStyle(.glassProminent)
            .tint(.accentColor)
        } else {
            Button(action: action) {
                pillLabel(foreground: .primary)
            }
            .buttonStyle(.glass)
            .tint(nil)
        }
    }

    @ViewBuilder
    private func pillLabel(foreground: Color) -> some View {
        let text = Text(title)
            .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize(horizontal: !expandWidth, vertical: false)
        Group {
            if monospaced {
                text.monospacedDigit()
            } else {
                text
            }
        }
        .foregroundColor(foreground)
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: expandWidth ? .infinity : nil)
        .frame(height: height)
    }
}

private struct QuickActionGlassButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Button(action: action) {
                buttonLabel
            }
            .buttonStyle(.glass)
            .tint(nil)
            .buttonBorderShape(.roundedRectangle(radius: DesignTokens.controlRadius))
            .tactileGlassRim(shape: shape, prominent: false)
            .noFocusRing()
        } else {
            Button(action: action) {
                buttonLabel
                    .background(
                        shape.fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        shape.strokeBorder(DesignTokens.cardBorder, lineWidth: 1)
                    )
                    .tactileFallbackBevel(shape: shape, prominent: false)
            }
            .buttonStyle(.plain)
            .noFocusRing()
        }
    }

    private var buttonLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.primary.opacity(0.84))

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous))
    }
}

// MARK: - Two-Row Persistent Header & Drill-Down Subheader

private struct TrackPillButton<Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var prominent: Bool = false
    var height: CGFloat = 24
    var horizontalPadding: CGFloat = 8
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .foregroundColor(prominent ? .white : .primary)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(
                    Capsule()
                        .fill(fillGradient)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(borderGradient, lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .shadow(color: shadowColor, radius: prominent ? 2.5 : 2.0, x: 0, y: prominent ? 1.5 : 1.0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .noFocusRing()
    }

    private var fillGradient: LinearGradient {
        if prominent {
            return LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.96),
                    Color.accentColor.opacity(0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.16), Color.white.opacity(0.07)]
                : [Color.white.opacity(0.82), Color.white.opacity(0.56)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var borderGradient: LinearGradient {
        if prominent {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.42),
                    Color.white.opacity(0.08),
                    Color.black.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.30), Color.white.opacity(0.08), Color.black.opacity(0.22)]
                : [Color.white.opacity(0.88), Color.white.opacity(0.22), Color.black.opacity(0.12)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var shadowColor: Color {
        if prominent {
            return Color.accentColor.opacity(0.30)
        }
        return Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14)
    }
}

private struct HeaderBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var uiState: PopoverUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1 (24pt): Brand + Status Pill
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    GhostEmblemView(
                        sessionMode: viewModel.sessionMode,
                        isLidClosed: viewModel.snapshot.hasLid && viewModel.snapshot.isLidClosed
                    )
                    Text(AppMetadata.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                StatusPillView(sessionMode: viewModel.sessionMode)
                    .fixedSize()
            }
            .frame(height: 24)

            // Row 2 (32pt): 3-segment tab bar or Safety drill-down subheader
            if viewModel.selectedTab == .safety && uiState.safetyRoute != .root {
                drillDownSubheader
                    .frame(height: 32)
            } else {
                tabSwitcherBar
                    .frame(height: 32)
            }
        }
    }

    private var tabSwitcherBar: some View {
        HStack(spacing: 3) {
            ForEach(PopoverTab.allCases) { tab in
                let selected = viewModel.selectedTab == tab
                Button {
                    switchToTab(tab)
                } label: {
                    tabLabel(tab, selected: selected)
                        .foregroundColor(selected ? .white : .primary.opacity(0.84))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .noFocusRing()
            }
        }
        .padding(3)
        .background(
            GeometryReader { proxy in
                let pillWidth = max(0, (proxy.size.width - 6) / CGFloat(PopoverTab.allCases.count))
                let selectedIndex = PopoverTab.allCases.firstIndex(of: viewModel.selectedTab) ?? 0
                activeTabPill
                    .frame(width: pillWidth, height: 26)
                    .offset(x: CGFloat(selectedIndex) * (pillWidth + 3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.18), value: viewModel.selectedTab)
            }
            .padding(3)
        )
        .background(tabTrackBackground)
        .overlay(tabTrackBorder)
    }

    private var activeTabPill: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.96),
                        Color.accentColor.opacity(0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.42),
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.18)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.accentColor.opacity(0.30), radius: 2.5, x: 0, y: 1.5)
            .frame(height: 26)
    }

    private func switchToTab(_ tab: PopoverTab) {
        guard viewModel.selectedTab != tab else { return }
        viewModel.selectedTab = tab
        if tab == .safety {
            uiState.safetyRoute = .root
        }
    }

    private func tabLabel(_ tab: PopoverTab, selected: Bool) -> some View {
        Text(tab.title)
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Capsule())
    }

    private var tabTrackBackground: some View {
        Capsule()
            .fill(colorScheme == .dark ? Color.primary.opacity(0.08) : Color.primary.opacity(0.08))
    }

    private var tabTrackBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.white.opacity(0.22), Color.white.opacity(0.05)]
                        : [Color.white.opacity(0.70), Color.black.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }

    private var drillDownSubheader: some View {
        HStack(spacing: 8) {
            drillDownBackButton

            Spacer(minLength: 4)

            Text(drillDownTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            drillDownRightAction
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .background(tabTrackBackground)
        .overlay(tabTrackBorder)
    }

    private var drillDownBackButton: some View {
        TrackPillButton(prominent: false, height: 24, horizontalPadding: 8) {
            uiState.safetyRoute = .root
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("Safety")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
        }
    }

    private var drillDownTitle: String {
        switch uiState.safetyRoute {
        case .root: return "Safety"
        case .appWhitelist: return "App Whitelist"
        case .audioRules: return "Audio Rules"
        }
    }

    @ViewBuilder
    private var drillDownRightAction: some View {
        switch uiState.safetyRoute {
        case .root:
            EmptyView()
        case .appWhitelist:
            Text("\(preferences.appFreezeWhitelist.count) kept")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                )
        case .audioRules:
            if !viewModel.isDefaultAllowAllAudio {
                TrackPillButton(prominent: true, height: 24, horizontalPadding: 9) {
                    viewModel.resetAudioRulesToAllowAll()
                } label: {
                    Text("Reset")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
            } else {
                Text("All allowed")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 24)
            }
        }
    }
}

private struct GhostEmblemView: View {
    let sessionMode: SessionMode
    let isLidClosed: Bool
    var size: CGFloat = 16

    private var style: GhostIconStyle {
        GhostIconStyle.from(sessionMode: sessionMode, isLidClosed: isLidClosed)
    }

    private var emblemColor: Color {
        switch style {
        case .resting:
            return .secondary
        case .pendingRestore:
            return .orange
        case .awake, .stealth:
            return .accentColor
        }
    }

    var body: some View {
        Group {
            if style == .pendingRestore {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size - 2.5, weight: .semibold))
                    .foregroundColor(emblemColor)
            } else {
                let scale = size / GhostVectorGeometry.canvasSize
                let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
                ZStack {
                    switch style {
                    case .resting:
                        scaledPath(GhostVectorGeometry.bodyPath(stealth: false), transform: scaleTransform)
                            .stroke(
                                emblemColor,
                                style: StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round, lineJoin: .round)
                            )
                        scaledPath(GhostVectorGeometry.restingClosedEyesPath(), transform: scaleTransform)
                            .stroke(
                                emblemColor,
                                style: StrokeStyle(lineWidth: 1.3 * scale, lineCap: .round)
                            )
                    case .awake:
                        scaledPath(GhostVectorGeometry.filledSilhouetteWithCutouts(stealth: false), transform: scaleTransform)
                            .fill(emblemColor, style: FillStyle(eoFill: true))
                    case .stealth:
                        scaledPath(GhostVectorGeometry.filledSilhouetteWithCutouts(stealth: true), transform: scaleTransform)
                            .fill(emblemColor, style: FillStyle(eoFill: true))
                        scaledPath(GhostVectorGeometry.stealthLidBarPath(), transform: scaleTransform)
                            .fill(emblemColor)
                    case .pendingRestore:
                        EmptyView()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func scaledPath(_ cgPath: CGPath, transform: CGAffineTransform) -> Path {
        var t = transform
        if let transformed = cgPath.copy(using: &t) {
            return Path(transformed)
        }
        return Path(cgPath)
    }
}

private struct StatusPillView: View {
    @Environment(\.colorScheme) private var colorScheme
    let sessionMode: SessionMode

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(
            Capsule()
                .fill(pillFillColor)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    dotColor.opacity(colorScheme == .dark ? 0.30 : 0.25),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
    }

    private var pillFillColor: Color {
        switch sessionMode {
        case .idle:
            return colorScheme == .dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.07)
        case .activeFinite:
            return Color.green.opacity(colorScheme == .dark ? 0.18 : 0.14)
        case .activeIndefinite, .pendingSleepRestore:
            return Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.14)
        }
    }

    private var label: String {
        switch sessionMode {
        case .idle: return "Off"
        case .activeFinite: return "Active"
        case .activeIndefinite: return "Indefinite ∞"
        case .pendingSleepRestore: return "Pending Restore"
        }
    }

    private var dotColor: Color {
        switch sessionMode {
        case .idle: return .primary.opacity(0.75)
        case .activeFinite: return .green
        case .activeIndefinite: return .orange
        case .pendingSleepRestore: return .orange
        }
    }

    private var textColor: Color {
        switch sessionMode {
        case .idle: return .primary.opacity(0.80)
        case .activeFinite: return .green
        case .activeIndefinite: return .orange
        case .pendingSleepRestore: return .orange
        }
    }
}

// MARK: - Persistent Footer Bar

private struct FooterBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: GhostModeViewModel

    private var quitButtonForeground: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.48, blue: 0.44)
            : Color(red: 0.78, green: 0.10, blue: 0.10)
    }

    var body: some View {
        VStack(spacing: 6) {
            Divider()

            HStack(spacing: 8) {
                Text("v\(AppMetadata.version) · by \(AppMetadata.author)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    viewModel.openGitHub()
                } label: {
                    Text("GitHub")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .noFocusRing()

                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.6))

                Button {
                    viewModel.openReportBug()
                } label: {
                    Text("Report")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .noFocusRing()

                GlassGroup(spacing: 4) {
                    quitButton
                }
            }
            .frame(height: 24)
        }
    }

    @ViewBuilder
    private var quitButton: some View {
        if #available(macOS 26.0, *) {
            Button {
                viewModel.quitApp()
            } label: {
                Text("Quit ⌘Q")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(quitButtonForeground)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
            }
            .buttonStyle(.glass)
            .tint(nil)
            .buttonBorderShape(.capsule)
            .tactileGlassRim(
                shape: Capsule(),
                tint: nil,
                borderTint: Color.red.opacity(0.38),
                prominent: false
            )
            .noFocusRing()
            .keyboardShortcut("q", modifiers: .command)
        } else {
            Button {
                viewModel.quitApp()
            } label: {
                Text("Quit ⌘Q")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(quitButtonForeground)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.10))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.red.opacity(0.28), lineWidth: 1)
                    )
                    .tactileFallbackBevel(shape: Capsule(), tint: .red, prominent: false)
            }
            .buttonStyle(.plain)
            .noFocusRing()
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Banners

private struct SudoSetupBannerView: View {
    let onSetup: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Passwordless Sudo Not Configured")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)

                Text(SudoFeatureAvailability.lackingFeaturesSummary())
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.95))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            GlassGroup(spacing: 4) {
                FlatActionButton(
                    title: "Setup",
                    tone: .warning,
                    prominent: true,
                    height: 22,
                    horizontalPadding: 10,
                    fontSize: 11
                ) {
                    onSetup()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }
}

private struct SudoWarningNoticeView: View {
    let message: String
    var boxed: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.orange)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 10.5))
                .foregroundColor(boxed ? .primary.opacity(0.88) : .orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, boxed ? 8 : 0)
        .padding(.vertical, boxed ? 6 : 0)
        .frame(maxWidth: boxed ? .infinity : nil, alignment: .leading)
        .background(
            Group {
                if boxed {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                }
            }
        )
        .overlay(
            Group {
                if boxed {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.orange.opacity(0.28), lineWidth: 1)
                }
            }
        )
    }
}

private struct SudoRequiredPill: View {
    var body: some View {
        Text("Requires Sudo")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

private struct InlineBannerCard: View {
    let banner: InlineBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tintColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                if !banner.title.isEmpty {
                    Text(banner.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Text(banner.message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(3)
            }
            .buttonStyle(.plain)
            .noFocusRing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .fill(tintColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                .stroke(tintColor.opacity(0.28), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tintColor: Color {
        switch banner.kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Tab 1: Session

private struct SessionTabView: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var uiState: PopoverUIState
    let maxBodyHeight: CGFloat

    private let presets: [(label: String, seconds: Int)] = [
        ("15m", 15 * 60),
        ("30m", 30 * 60),
        ("45m", 45 * 60),
        ("1h", 60 * 60),
        ("2h", 2 * 3600),
        ("4h", 4 * 3600),
        ("8h", 8 * 3600),
        ("∞", -1)
    ]

    var body: some View {
        AdaptiveTabBody(
            maxHeight: maxBodyHeight,
            needsScroll: uiState.sessionNeedsScroll,
            onNeedsScrollChange: { uiState.sessionNeedsScroll = $0 }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.sectionGap) {
            HeroStatusCard(viewModel: viewModel, preferences: preferences)

            // Duration Presets Card
            GlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        SectionHeaderLabel(title: "DURATION", systemImage: "timer")
                        Spacer()
                        Button(uiState.showCustomDuration ? "Hide" : "Custom…") {
                            uiState.showCustomDuration.toggle()
                            if uiState.showCustomDuration {
                                viewModel.focusPopover()
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .noFocusRing()
                    }

                    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                    GlassGroup(spacing: 6) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(presets, id: \.seconds) { preset in
                                let selected = isPresetSelected(preset.seconds)
                                SelectablePillButton(
                                    title: preset.label,
                                    isSelected: selected,
                                    height: 27,
                                    horizontalPadding: 6,
                                    fontSize: 12,
                                    expandWidth: true,
                                    monospaced: true
                                ) {
                                    viewModel.startSession(seconds: preset.seconds)
                                }
                            }
                        }
                    }

                    if uiState.showCustomDuration {
                        HStack(spacing: 6) {
                            TextField("e.g. 90m, 1.5h, 45", text: $uiState.customDurationText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5))
                                .simultaneousGesture(TapGesture().onEnded {
                                    viewModel.focusPopover()
                                })
                                .onSubmit {
                                    submitCustomDuration()
                                }

                            GlassGroup(spacing: 4) {
                                FlatActionButton(
                                    title: viewModel.sessionMode.isActive ? "Switch" : "Start",
                                    tone: .accent,
                                    prominent: true,
                                    height: 24,
                                    horizontalPadding: 10,
                                    fontSize: 11
                                ) {
                                    submitCustomDuration()
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }

            // Quick Controls Card
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    GlassGroup(spacing: 6) {
                        HStack(spacing: 6) {
                            QuickActionGlassButton(
                                title: "Turn Off Screen",
                                systemImage: "display"
                            ) {
                                viewModel.turnOffScreen()
                            }

                            QuickActionGlassButton(
                                title: "Screen Saver",
                                systemImage: "sparkles"
                            ) {
                                viewModel.startScreenSaver()
                            }
                        }
                    }

                    Divider()

                    SettingToggleRow(
                        "Keep Display Awake",
                        systemImage: "sun.max.fill",
                        iconColor: .orange,
                        isOn: Binding(
                            get: { preferences.preventDisplaySleep },
                            set: { viewModel.setPreventDisplaySleep($0) }
                        )
                    )

                    if viewModel.snapshot.hasLid {
                        SettingToggleRow(
                            "Turn Off Screen on Lid Close",
                            systemImage: "display",
                            iconColor: .accentColor,
                            isOn: Binding(
                                get: { preferences.turnOffScreenOnLidClose },
                                set: { viewModel.setTurnOffScreenOnLidClose($0) }
                            ),
                            isEnabled: viewModel.snapshot.sudoConfigured
                        ) {
                            if !viewModel.snapshot.sudoConfigured {
                                SudoRequiredPill()
                            }
                        }

                        SettingToggleRow(
                            "Freeze Apps on Lid Close",
                            systemImage: "snowflake",
                            iconColor: .cyan,
                            isOn: Binding(
                                get: { preferences.appFreezeOnLidCloseEnabled },
                                set: { viewModel.setAppFreezeEnabled($0) }
                            ),
                            isEnabled: viewModel.snapshot.sudoConfigured
                        ) {
                            freezeStatusAccessoryButton
                        }

                        if !viewModel.snapshot.sudoConfigured {
                            SudoWarningNoticeView(
                                message: "Lid-close Screen Off & App Freeze require Passwordless Sudo."
                            )
                        }
                    }

                    SettingToggleRow(
                        "AC Power Only",
                        systemImage: "bolt.fill",
                        iconColor: .green,
                        isOn: Binding(
                            get: { preferences.acOnlyModeEnabled },
                            set: { viewModel.setACOnlyMode($0) }
                        )
                    )
                }
            }
            }
        }
    }

    @ViewBuilder
    private var freezeStatusAccessoryButton: some View {
        let frozenCount = viewModel.snapshot.frozenAppCount
        if !viewModel.snapshot.sudoConfigured {
            SudoRequiredPill()
        } else {
            Button {
                viewModel.selectedTab = .safety
            } label: {
                if frozenCount > 0 {
                    Text("\(frozenCount) frozen")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.16))
                        )
                } else {
                    Text(preferences.appFreezeOnLidCloseEnabled ? "\(preferences.appFreezeWhitelist.count) kept ›" : "Configure ›")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
            }
            .buttonStyle(.plain)
            .noFocusRing()
        }
    }

    private func isPresetSelected(_ seconds: Int) -> Bool {
        switch viewModel.sessionMode {
        case .activeIndefinite:
            return seconds == -1
        case .activeFinite(_, let totalDuration):
            return seconds > 0 && totalDuration == seconds
        case .idle, .pendingSleepRestore:
            return false
        }
    }

    private func submitCustomDuration() {
        guard let seconds = parseDurationString(uiState.customDurationText), seconds > 0 else {
            viewModel.showBanner(
                .error,
                title: "Invalid Duration",
                message: "Enter a duration like '90m', '1.5h', or raw minutes such as '45'."
            )
            return
        }
        viewModel.dismissBanner()
        viewModel.startSession(seconds: seconds)
        uiState.customDurationText = ""
        uiState.showCustomDuration = false
    }
}

private struct HeroStatusCard: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.isPopoverVisible && viewModel.sessionMode.isActive && !viewModel.sessionMode.isIndefinite {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        heroReadout(at: context.date)
                    }
                } else {
                    heroReadout(at: Date())
                }

                TelemetryStripView(snapshot: viewModel.snapshot)

                primaryActionsRow
            }
        }
    }

    @ViewBuilder
    private func heroReadout(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Text(heroPrimaryText(at: now))
                    .font(.system(size: 25, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    KernelStatusBadge(isProtected: viewModel.snapshot.kernelSleepDisabled)

                    Text(heroSecondaryText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if case .activeFinite(let endDate, let totalDuration) = viewModel.sessionMode, totalDuration > 0 {
                let remaining = max(0, endDate.timeIntervalSince(now))
                let fraction = min(1.0, max(0.0, remaining / Double(totalDuration)))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(progressColor(for: fraction))
                            .frame(width: max(4, proxy.size.width * CGFloat(fraction)))
                            .animation(.linear(duration: 0.2), value: fraction)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func heroPrimaryText(at now: Date) -> String {
        switch viewModel.sessionMode {
        case .idle:
            return "Normal Sleep"
        case .activeIndefinite:
            return "Indefinite"
        case .pendingSleepRestore:
            return "Pending Restore"
        case .activeFinite(let endDate, _):
            let remaining = max(0, Int(ceil(endDate.timeIntervalSince(now))))
            return formatCountdown(remaining)
        }
    }

    private var heroSecondaryText: String {
        switch viewModel.sessionMode {
        case .idle:
            return "Default: \(formatDurationHuman(preferences.defaultDuration))"
        case .activeIndefinite:
            return "No timer limit"
        case .pendingSleepRestore:
            return "Open lid to restore"
        case .activeFinite(let endDate, _):
            return "Until \(DesignTokens.endTimeFormatter.string(from: endDate))"
        }
    }

    private func progressColor(for fraction: Double) -> Color {
        if fraction > 0.5 { return .green }
        if fraction > 0.15 { return .orange }
        return .red
    }

    @ViewBuilder
    private var primaryActionsRow: some View {
        GlassGroup(spacing: 5) {
            switch viewModel.sessionMode {
            case .idle:
                FlatActionButton(
                    title: "Turn On · \(formatDurationHuman(preferences.defaultDuration))",
                    tone: .accent,
                    prominent: true,
                    height: 32,
                    fontSize: 12.5,
                    fontWeight: .semibold,
                    expandWidth: true
                ) {
                    viewModel.startDefaultSession()
                }

            case .pendingSleepRestore:
                FlatActionButton(
                    title: "Restore Normal Sleep",
                    tone: .warning,
                    prominent: true,
                    height: 32,
                    fontSize: 12.5,
                    fontWeight: .semibold,
                    expandWidth: true
                ) {
                    viewModel.stopSession()
                }

            case .activeFinite, .activeIndefinite:
                HStack(spacing: 5) {
                    FlatActionButton(
                        title: "Stop",
                        tone: .destructive,
                        prominent: true,
                        height: 30,
                        horizontalPadding: 8,
                        fontSize: 11.5,
                        fontWeight: .semibold,
                        expandWidth: true
                    ) {
                        viewModel.stopSession()
                    }

                    FlatActionButton(
                        title: "+15m",
                        tone: .accent,
                        prominent: false,
                        height: 30,
                        horizontalPadding: 0,
                        fontSize: 11.5,
                        fontWeight: .semibold,
                        fixedWidth: 54,
                        monospaced: true
                    ) {
                        viewModel.extendSession(seconds: 15 * 60)
                    }

                    FlatActionButton(
                        title: "+30m",
                        tone: .accent,
                        prominent: false,
                        height: 30,
                        horizontalPadding: 0,
                        fontSize: 11.5,
                        fontWeight: .semibold,
                        fixedWidth: 54,
                        monospaced: true
                    ) {
                        viewModel.extendSession(seconds: 30 * 60)
                    }

                    FlatActionButton(
                        title: "+1h",
                        tone: .neutral,
                        prominent: false,
                        height: 30,
                        horizontalPadding: 0,
                        fontSize: 11.5,
                        fontWeight: .semibold,
                        fixedWidth: 46,
                        monospaced: true
                    ) {
                        viewModel.extendSession(seconds: 60 * 60)
                    }

                    FlatActionButton(
                        title: "∞",
                        tone: viewModel.sessionMode.isIndefinite ? .warning : .neutral,
                        prominent: viewModel.sessionMode.isIndefinite,
                        height: 30,
                        horizontalPadding: 0,
                        fontSize: 12.5,
                        fontWeight: .semibold,
                        fixedWidth: 38
                    ) {
                        viewModel.startSession(seconds: -1)
                    }
                }
            }
        }
    }
}

private struct KernelStatusBadge: View {
    let isProtected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isProtected ? "lock.shield.fill" : "shield")
                .font(.system(size: 9.5, weight: .semibold))
            Text(isProtected ? "Kernel: Protected" : "Kernel: Normal")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(isProtected ? .green : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(isProtected ? Color.green.opacity(0.14) : Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule()
                .strokeBorder(isProtected ? Color.green.opacity(0.28) : DesignTokens.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

private struct TelemetryStripView: View {
    let snapshot: SystemSnapshot

    var body: some View {
        HStack(spacing: 6) {
            telemetryItem(
                icon: snapshot.hasLid ? "laptopcomputer" : "desktopcomputer",
                text: lidText,
                color: .secondary
            )

            Text("·")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            telemetryItem(
                icon: powerIcon,
                text: powerText,
                color: powerColor
            )

            Text("·")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            telemetryItem(
                icon: "thermometer",
                text: thermalText,
                color: thermalColor
            )

            Spacer(minLength: 0)
        }
    }

    private func telemetryItem(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var lidText: String {
        guard snapshot.hasLid else { return "Desktop" }
        return snapshot.isLidClosed ? "Lid Closed" : "Lid Open"
    }

    private var powerIcon: String {
        guard let bat = snapshot.battery else { return "bolt.fill" }
        if bat.isCharging || bat.isAC { return "bolt.fill" }
        return bat.percent <= 20 ? "battery.25" : "battery.100"
    }

    private var powerText: String {
        guard let bat = snapshot.battery else { return "AC Power" }
        let remainingSuffix: String
        if let mins = bat.timeRemainingMinutes, mins > 0 {
            remainingSuffix = " · \(formatMinutesRemaining(mins))"
        } else {
            remainingSuffix = ""
        }

        if bat.isCharging {
            return "Charging \(bat.percent)%\(remainingSuffix)"
        }
        if bat.isAC {
            return "AC · \(bat.percent)%"
        }
        if !remainingSuffix.isEmpty {
            return "\(bat.percent)%\(remainingSuffix)"
        }
        return "Battery · \(bat.percent)%"
    }

    private func formatMinutesRemaining(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 {
            return "\(h)h \(m)m left"
        } else if h > 0 {
            return "\(h)h left"
        } else {
            return "\(m)m left"
        }
    }

    private var powerColor: Color {
        guard let bat = snapshot.battery else { return .secondary }
        if !bat.isAC && bat.percent <= 15 { return .orange }
        return .secondary
    }

    private var thermalText: String {
        switch snapshot.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Elevated"
        case .critical: return "Critical"
        @unknown default: return "Normal"
        }
    }

    private var thermalColor: Color {
        switch snapshot.thermalState {
        case .nominal, .fair: return .secondary
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}

// MARK: - Tab 2: Safety

private struct SafetyTabView: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var uiState: PopoverUIState
    let maxBodyHeight: CGFloat

    private let batteryPresets = [5, 10, 15, 20]

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch uiState.safetyRoute {
            case .root:
                AdaptiveTabBody(
                    maxHeight: maxBodyHeight,
                    needsScroll: uiState.safetyNeedsScroll,
                    onNeedsScrollChange: { uiState.safetyNeedsScroll = $0 }
                ) {
                    safetyRootView
                }
            case .appWhitelist:
                AppWhitelistDrillDownView(
                    viewModel: viewModel,
                    uiState: uiState,
                    maxBodyHeight: maxBodyHeight
                )
            case .audioRules:
                AudioRulesDrillDownView(
                    viewModel: viewModel,
                    preferences: preferences,
                    maxBodyHeight: maxBodyHeight
                )
            }
        }
    }

    private var safetyRootView: some View {
        VStack(alignment: .leading, spacing: DesignTokens.sectionGap) {
            // Card 1: Power & Thermal Guards
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeaderLabel(title: "POWER & THERMAL GUARDS", systemImage: "checkmark.shield.fill")

                    SettingToggleRow(
                        "Only Keep Awake on AC Power",
                        systemImage: "bolt.fill",
                        iconColor: .green,
                        isOn: Binding(
                            get: { preferences.acOnlyModeEnabled },
                            set: { viewModel.setACOnlyMode($0) }
                        )
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        SettingToggleRow(
                            "Low Battery Cutoff",
                            systemImage: "battery.25",
                            iconColor: .orange,
                            isOn: Binding(
                                get: { preferences.batteryCutoffEnabled },
                                set: { viewModel.setBatteryCutoffEnabled($0) }
                            )
                        ) {
                            if preferences.batteryCutoffEnabled {
                                Text("\(preferences.batteryCutoffThreshold)%")
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(Color.primary.opacity(0.06))
                                    )
                            }
                        }

                        if preferences.batteryCutoffEnabled {
                            GlassGroup(spacing: 5) {
                                HStack(spacing: 5) {
                                    ForEach(batteryPresets, id: \.self) { pct in
                                        let selected = preferences.batteryCutoffThreshold == pct && !uiState.showCustomBattery
                                        SelectablePillButton(
                                            title: "\(pct)%",
                                            isSelected: selected,
                                            height: 24,
                                            horizontalPadding: 6,
                                            fontSize: 11,
                                            expandWidth: true,
                                            monospaced: true
                                        ) {
                                            uiState.showCustomBattery = false
                                            viewModel.setBatteryCutoffThreshold(pct)
                                        }
                                    }

                                    let isCustomVal = !batteryPresets.contains(preferences.batteryCutoffThreshold)
                                    let highlighted = isCustomVal || uiState.showCustomBattery
                                    SelectablePillButton(
                                        title: isCustomVal ? "\(preferences.batteryCutoffThreshold)%" : "Custom",
                                        isSelected: highlighted,
                                        height: 24,
                                        horizontalPadding: 10,
                                        fontSize: 11,
                                        expandWidth: false,
                                        monospaced: true
                                    ) {
                                        uiState.showCustomBattery.toggle()
                                        if uiState.showCustomBattery {
                                            uiState.customBatteryText = "\(preferences.batteryCutoffThreshold)"
                                            viewModel.focusPopover()
                                        }
                                    }
                                }
                            }

                            if uiState.showCustomBattery {
                                HStack(spacing: 6) {
                                    TextField("1–50%", text: $uiState.customBatteryText)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                        .simultaneousGesture(TapGesture().onEnded {
                                            viewModel.focusPopover()
                                        })
                                        .onSubmit {
                                            submitCustomBattery()
                                        }

                                    GlassGroup(spacing: 4) {
                                        FlatActionButton(
                                            title: "Save",
                                            tone: .accent,
                                            prominent: true,
                                            height: 22,
                                            horizontalPadding: 9,
                                            fontSize: 11
                                        ) {
                                            submitCustomBattery()
                                        }
                                    }
                                }
                            }

                            if preferences.acOnlyModeEnabled {
                                Text("AC-only ends immediately on unplug; cutoff acts as fallback.")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Divider()

                    SettingToggleRow(
                        "Thermal Overheat Protection",
                        systemImage: "flame.fill",
                        iconColor: .red,
                        isOn: Binding(
                            get: { preferences.thermalGuardEnabled },
                            set: { viewModel.setThermalGuardEnabled($0) }
                        )
                    ) {
                        ThermalStatePill(state: viewModel.snapshot.thermalState)
                    }

                    if viewModel.snapshot.hasLid && !viewModel.snapshot.sudoConfigured {
                        Text("Without Passwordless Sudo, safety cutoffs wait until the lid opens to restore sleep.")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Card 2: Clamshell & App Freeze
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionHeaderLabel(title: "CLAMSHELL & APP FREEZE", systemImage: "moon.stars.fill")

                        Spacer()

                        if viewModel.snapshot.frozenAppCount > 0 {
                            GlassGroup(spacing: 4) {
                                FlatActionButton(
                                    title: "Unfreeze All (\(viewModel.snapshot.frozenAppCount))",
                                    tone: .warning,
                                    prominent: true,
                                    height: 21,
                                    horizontalPadding: 8,
                                    fontSize: 10.5
                                ) {
                                    viewModel.unfreezeAllNow()
                                }
                            }
                        }
                    }

                    if !viewModel.snapshot.hasLid {
                        Text("Desktop Mac — lid-close controls unavailable")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        let lidControlsEnabled = viewModel.snapshot.sudoConfigured

                        if !lidControlsEnabled {
                            SudoWarningNoticeView(
                                message: "Disabled without Passwordless Sudo — lacks silent behind-lid safety shutoff, closed-lid Screen Off, App Freeze, and audio rules.",
                                boxed: true
                            )
                        }

                        SettingToggleRow(
                            "Turn Off Screen on Lid Close",
                            systemImage: "display",
                            iconColor: .accentColor,
                            isOn: Binding(
                                get: { preferences.turnOffScreenOnLidClose },
                                set: { viewModel.setTurnOffScreenOnLidClose($0) }
                            ),
                            isEnabled: lidControlsEnabled
                        )

                        Divider()

                        SettingToggleRow(
                            "Freeze Apps on Lid Close",
                            systemImage: "snowflake",
                            iconColor: .cyan,
                            isOn: Binding(
                                get: { preferences.appFreezeOnLidCloseEnabled },
                                set: { viewModel.setAppFreezeEnabled($0) }
                            ),
                            isEnabled: lidControlsEnabled
                        ) {
                            if viewModel.snapshot.frozenAppCount > 0 {
                                FrozenCountPill(count: viewModel.snapshot.frozenAppCount)
                            }
                        }

                        if !preferences.appFreezeOnLidCloseEnabled {
                            if lidControlsEnabled {
                                Text("Enable App Freeze above to configure app whitelist & audio rules")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Divider()

                            Button {
                                uiState.appSearchQuery = ""
                                uiState.safetyRoute = .appWhitelist
                                viewModel.focusPopover()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checklist")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(lidControlsEnabled ? .accentColor : .secondary)
                                        .frame(width: 15, alignment: .center)

                                    Text("App Whitelist (Keep Running)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)

                                    Spacer(minLength: 4)

                                    Text("\(preferences.appFreezeWhitelist.count) kept")
                                        .font(.system(size: 11, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .frame(height: 22)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .noFocusRing()
                            .opacity(lidControlsEnabled ? 1.0 : 0.45)
                            .disabled(!lidControlsEnabled)

                            Divider()

                            SettingToggleRow(
                                "Keep Music & Audio Streaming",
                                systemImage: "speaker.wave.2.fill",
                                iconColor: .accentColor,
                                isOn: Binding(
                                    get: { preferences.keepAudioActiveOnLidClose },
                                    set: { viewModel.setKeepAudioActive($0) }
                                ),
                                isEnabled: lidControlsEnabled
                            )

                            let audioRulesEnabled = SudoFeatureAvailability.effectiveLidFeatureToggle(
                                storedValue: preferences.keepAudioActiveOnLidClose,
                                sudoConfigured: lidControlsEnabled
                            )
                            Button {
                                uiState.safetyRoute = .audioRules
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(audioRulesEnabled ? .accentColor : .secondary)
                                        .frame(width: 15, alignment: .center)

                                    Text("Audio App Rules")
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)

                                    Spacer(minLength: 4)

                                    Text(viewModel.audioSummaryLabel)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .frame(height: 22)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .noFocusRing()
                            .opacity(audioRulesEnabled ? 1.0 : 0.45)
                            .disabled(!audioRulesEnabled)
                        }
                    }
                }
            }
        }
    }

    private func submitCustomBattery() {
        let trimmed = uiState.customBatteryText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        guard let pct = Int(trimmed), (1...50).contains(pct) else {
            viewModel.showBanner(
                .error,
                title: "Invalid Battery Threshold",
                message: "Enter a percentage between 1 and 50."
            )
            return
        }
        viewModel.dismissBanner()
        viewModel.setBatteryCutoffThreshold(pct)
        uiState.showCustomBattery = false
    }
}

private struct FrozenCountPill: View {
    let count: Int

    var body: some View {
        Text("\(count) frozen")
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundColor(.orange)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(0.16))
            )
    }
}

private struct ThermalStatePill: View {
    let state: ProcessInfo.ThermalState

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
    }

    private var label: String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Elevated"
        case .critical: return "Critical"
        @unknown default: return "Normal"
        }
    }

    private var color: Color {
        switch state {
        case .nominal, .fair: return .secondary
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}

// MARK: - Safety Drill-Down 1: App Whitelist

private struct AppWhitelistDrillDownView: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var uiState: PopoverUIState
    let maxBodyHeight: CGFloat

    private var filteredApps: [AppEntry] {
        let query = uiState.appSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.runningApps }
        return viewModel.runningApps.filter { app in
            if app.name.lowercased().contains(query) { return true }
            if let bid = app.bundleIdentifier?.lowercased(), bid.contains(query) { return true }
            return false
        }
    }

    private var savedNotRunningEntries: [SavedRuleEntry] {
        let all = viewModel.savedNotRunningWhitelistEntries()
        let query = uiState.appSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.lowercased().contains(query) || $0.identifier.lowercased().contains(query)
        }
    }

    private var savedSectionHeight: CGFloat {
        guard !savedNotRunningEntries.isEmpty else { return 0 }
        let rowsHeight = min(76, max(30, CGFloat(savedNotRunningEntries.count) * 26 + 6))
        return rowsHeight + 24
    }

    private var maxChecklistHeight: CGFloat {
        let chromeHeight: CGFloat = (viewModel.snapshot.frozenAppCount > 0 ? 124 : 94) + savedSectionHeight
        return max(84, maxBodyHeight - chromeHeight)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Checked apps stay running when the lid closes.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    GlassGroup(spacing: 4) {
                        HStack(spacing: 4) {
                            FlatActionButton(
                                title: "Allow All",
                                tone: .accent,
                                height: 22,
                                horizontalPadding: 8,
                                fontSize: 10.5
                            ) {
                                viewModel.whitelistAllRunningApps()
                            }

                            FlatActionButton(
                                title: "Clear",
                                tone: .neutral,
                                height: 22,
                                horizontalPadding: 8,
                                fontSize: 10.5
                            ) {
                                viewModel.clearAppFreezeWhitelist()
                            }
                        }
                    }
                }

                if viewModel.snapshot.frozenAppCount > 0 {
                    HStack(spacing: 6) {
                        FrozenCountPill(count: viewModel.snapshot.frozenAppCount)
                        Text("Currently suspended by lid close")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                        Spacer(minLength: 4)
                        GlassGroup(spacing: 4) {
                            FlatActionButton(
                                title: "Unfreeze All",
                                tone: .warning,
                                prominent: true,
                                height: 22,
                                horizontalPadding: 8,
                                fontSize: 10.5
                            ) {
                                viewModel.unfreezeAllNow()
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    TextField("Filter running apps…", text: $uiState.appSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.focusPopover()
                        })

                    if !uiState.appSearchQuery.isEmpty {
                        Button {
                            uiState.appSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .noFocusRing()
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                        .stroke(DesignTokens.cardBorder, lineWidth: 1)
                )

                AppChecklistScroll(
                    apps: filteredApps,
                    emptyText: viewModel.runningApps.isEmpty ? "No user apps running" : "No matching apps",
                    maxScrollHeight: maxChecklistHeight,
                    isChecked: { viewModel.isAppFreezeWhitelisted($0) },
                    showAudioIndicator: false,
                    showFrozenBadge: true,
                    onToggle: { viewModel.toggleAppFreezeWhitelist($0) }
                )

                if !savedNotRunningEntries.isEmpty {
                    SavedNotRunningListSection(
                        title: "SAVED · NOT CURRENTLY RUNNING (\(savedNotRunningEntries.count))",
                        entries: savedNotRunningEntries,
                        checkedColor: .accentColor,
                        onRemove: { viewModel.removeAppFreezeWhitelistIdentifier($0) }
                    )
                }
            }
        }
    }
}

// MARK: - Safety Drill-Down 2: Audio Rules

private struct AudioRulesDrillDownView: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences
    let maxBodyHeight: CGFloat

    private var savedNotRunningEntries: [SavedRuleEntry] {
        viewModel.savedNotRunningAudioEntries()
    }

    private var savedSectionHeight: CGFloat {
        guard !savedNotRunningEntries.isEmpty else { return 0 }
        let rowsHeight = min(76, max(30, CGFloat(savedNotRunningEntries.count) * 26 + 6))
        return rowsHeight + 24
    }

    private var maxChecklistHeight: CGFloat {
        let baseChrome: CGFloat = viewModel.snapshot.frozenAppCount > 0 ? 156 : 130
        return max(84, maxBodyHeight - baseChrome - savedSectionHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.sectionGap) {
            GlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        SectionHeaderLabel(title: "FILTER MODE", systemImage: "speaker.wave.2.fill")

                        Spacer()

                        Text(viewModel.audioSummaryLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    GlassGroup(spacing: 6) {
                        HStack(spacing: 6) {
                            audioModePill(title: "All Except Blocked", mode: .allowAllExceptBlocked)
                            audioModePill(title: "Only Selected", mode: .allowOnlySelected)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(preferences.audioFilterMode == .allowAllExceptBlocked
                             ? "Checked apps can continue playing audio behind a closed lid."
                             : "Only checked apps are allowed to keep playing audio.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 4)

                        if viewModel.snapshot.frozenAppCount > 0 {
                            GlassGroup(spacing: 4) {
                                FlatActionButton(
                                    title: "Unfreeze All",
                                    tone: .warning,
                                    prominent: true,
                                    height: 21,
                                    horizontalPadding: 8,
                                    fontSize: 10.5
                                ) {
                                    viewModel.unfreezeAllNow()
                                }
                            }
                        }
                    }

                    AppChecklistScroll(
                        apps: viewModel.runningApps,
                        emptyText: "No user apps running",
                        maxScrollHeight: maxChecklistHeight,
                        isChecked: { viewModel.isAudioAppAllowed($0) },
                        showAudioIndicator: true,
                        showFrozenBadge: true,
                        onToggle: { viewModel.toggleAudioApp($0) }
                    )

                    if !savedNotRunningEntries.isEmpty {
                        let header = preferences.audioFilterMode == .allowAllExceptBlocked
                            ? "BLOCKED · NOT CURRENTLY RUNNING (\(savedNotRunningEntries.count))"
                            : "SELECTED · NOT CURRENTLY RUNNING (\(savedNotRunningEntries.count))"
                        SavedNotRunningListSection(
                            title: header,
                            entries: savedNotRunningEntries,
                            checkedColor: preferences.audioFilterMode == .allowAllExceptBlocked ? .orange : .accentColor,
                            onRemove: { viewModel.removeAudioRuleIdentifier($0) }
                        )
                    }
                }
            }
        }
    }

    private func audioModePill(title: String, mode: AudioFilterMode) -> some View {
        let selected = preferences.audioFilterMode == mode
        return SelectablePillButton(
            title: title,
            isSelected: selected,
            height: 24,
            horizontalPadding: 8,
            fontSize: 11,
            expandWidth: true,
            monospaced: false
        ) {
            viewModel.setAudioFilterMode(mode)
        }
    }
}

private struct SavedNotRunningListSection: View {
    let title: String
    let entries: [SavedRuleEntry]
    let checkedColor: Color
    let onRemove: (String) -> Void

    private var listHeight: CGFloat {
        min(76, max(30, CGFloat(entries.count) * 26 + 6))
    }

    private var needsScroll: Bool {
        CGFloat(entries.count) * 26 + 6 > 76
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.secondary)

            Group {
                if needsScroll {
                    ScrollView(.vertical, showsIndicators: true) {
                        rows
                    }
                } else {
                    rows
                }
            }
            .frame(maxWidth: .infinity, minHeight: listHeight, maxHeight: listHeight, alignment: .top)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .stroke(DesignTokens.cardBorder, lineWidth: 1)
            )
        }
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(entries) { entry in
                Button {
                    onRemove(entry.identifier)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.square.fill")
                            .font(.system(size: 12))
                            .foregroundColor(checkedColor)

                        if let icon = entry.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 15, height: 15)
                        } else {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 12))
                                .frame(width: 15, height: 15)
                                .foregroundColor(.secondary)
                        }

                        Text(entry.displayName)
                            .font(.system(size: 11.5))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if entry.displayName != entry.identifier {
                            Text(entry.identifier)
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 4)

                        Text("Not Running")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noFocusRing()
            }
        }
        .padding(3)
    }
}

private struct AppChecklistScroll: View {
    let apps: [AppEntry]
    let emptyText: String
    var maxScrollHeight: CGFloat = 260
    let isChecked: (AppEntry) -> Bool
    let showAudioIndicator: Bool
    var showFrozenBadge: Bool = false
    let onToggle: (AppEntry) -> Void

    private var naturalListHeight: CGFloat {
        max(64, CGFloat(apps.count) * 28 + 8)
    }

    private var listHeight: CGFloat {
        min(maxScrollHeight, naturalListHeight)
    }

    private var needsScroll: Bool {
        naturalListHeight > maxScrollHeight
    }

    var body: some View {
        if apps.isEmpty {
            Text(emptyText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .center)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                        .stroke(DesignTokens.cardBorder, lineWidth: 1)
                )
        } else {
            Group {
                if needsScroll {
                    ScrollView(.vertical, showsIndicators: true) {
                        checklistRows
                    }
                } else {
                    checklistRows
                }
            }
            .frame(maxWidth: .infinity, minHeight: listHeight, maxHeight: listHeight, alignment: .top)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.controlRadius, style: .continuous)
                    .stroke(DesignTokens.cardBorder, lineWidth: 1)
            )
        }
    }

    private var checklistRows: some View {
        VStack(spacing: 2) {
            ForEach(apps) { app in
                let checked = isChecked(app)
                Button {
                    onToggle(app)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12.5))
                            .foregroundColor(checked ? .accentColor : .secondary)

                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app")
                                .font(.system(size: 13))
                                .frame(width: 16, height: 16)
                                .foregroundColor(.secondary)
                        }

                        Text(app.name)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if showFrozenBadge && app.isFrozen {
                            Text("Frozen")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.opacity(0.16))
                                )
                        }

                        if showAudioIndicator && app.isPlayingAudio {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                Text("Playing")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noFocusRing()
            }
        }
        .padding(4)
    }
}

// MARK: - Tab 3: Settings (PopoverTab.prefs)

private struct SettingsTabView: View {
    @ObservedObject var viewModel: GhostModeViewModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var uiState: PopoverUIState
    let maxBodyHeight: CGFloat

    private let defaultDurationPresets: [(label: String, seconds: Int)] = [
        ("15m", 15 * 60),
        ("30m", 30 * 60),
        ("1h", 3600),
        ("2h", 7200),
        ("4h", 14400)
    ]

    var body: some View {
        AdaptiveTabBody(
            maxHeight: maxBodyHeight,
            needsScroll: uiState.settingsNeedsScroll,
            onNeedsScrollChange: { uiState.settingsNeedsScroll = $0 }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.sectionGap) {
            // Card 1: Default 1-Click Duration
            GlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        SectionHeaderLabel(title: "DEFAULT 1-CLICK DURATION", systemImage: "timer")
                        Spacer()
                        Text(formatDurationHuman(preferences.defaultDuration))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                    }

                    GlassGroup(spacing: 5) {
                        HStack(spacing: 5) {
                            ForEach(defaultDurationPresets, id: \.seconds) { preset in
                                let selected = preferences.defaultDuration == preset.seconds && !uiState.showCustomDefault
                                SelectablePillButton(
                                    title: preset.label,
                                    isSelected: selected,
                                    height: 25,
                                    horizontalPadding: 6,
                                    fontSize: 11,
                                    expandWidth: true,
                                    monospaced: true
                                ) {
                                    uiState.showCustomDefault = false
                                    viewModel.setDefaultDuration(preset.seconds)
                                }
                            }

                            let isCustomDefault = !defaultDurationPresets.contains(where: { $0.seconds == preferences.defaultDuration })
                            let customSelected = uiState.showCustomDefault || isCustomDefault
                            SelectablePillButton(
                                title: "Custom",
                                isSelected: customSelected,
                                height: 25,
                                horizontalPadding: 10,
                                fontSize: 11,
                                expandWidth: false,
                                monospaced: false
                            ) {
                                uiState.showCustomDefault.toggle()
                                if uiState.showCustomDefault {
                                    uiState.customDefaultText = formatDurationHuman(preferences.defaultDuration)
                                    viewModel.focusPopover()
                                }
                            }
                        }
                    }

                    if uiState.showCustomDefault {
                        HStack(spacing: 6) {
                            TextField("e.g. 90m, 1.5h, 45", text: $uiState.customDefaultText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .simultaneousGesture(TapGesture().onEnded {
                                    viewModel.focusPopover()
                                })
                                .onSubmit {
                                    submitCustomDefaultDuration()
                                }

                            GlassGroup(spacing: 4) {
                                FlatActionButton(
                                    title: "Save",
                                    tone: .accent,
                                    prominent: true,
                                    height: 22,
                                    horizontalPadding: 9,
                                    fontSize: 11
                                ) {
                                    submitCustomDefaultDuration()
                                }
                            }
                        }
                    }
                }
            }

            // Card 2: Behavior & System
            GlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    SectionHeaderLabel(title: "BEHAVIOR & SYSTEM", systemImage: "slider.horizontal.3")

                    SettingToggleRow(
                        "Show Countdown in Menu Bar",
                        systemImage: "timer",
                        iconColor: .accentColor,
                        isOn: Binding(
                            get: { preferences.showCountdownInMenuBar },
                            set: { viewModel.setShowCountdown($0) }
                        )
                    )

                    SettingToggleRow(
                        "Auto-Close Panel on Start",
                        systemImage: "rectangle.compress.vertical",
                        iconColor: .accentColor,
                        isOn: Binding(
                            get: { preferences.autoClosePopoverOnStart },
                            set: { viewModel.setAutoClosePopover($0) }
                        )
                    )

                    SettingToggleRow(
                        "Auto-Start at Launch",
                        systemImage: "play.circle.fill",
                        iconColor: .green,
                        isOn: Binding(
                            get: { preferences.autoStartOnLaunch },
                            set: { viewModel.setAutoStartOnLaunch($0) }
                        )
                    )

                    SettingToggleRow(
                        "Sound Notifications",
                        systemImage: "bell.fill",
                        iconColor: .orange,
                        isOn: Binding(
                            get: { preferences.soundNotificationsEnabled },
                            set: { viewModel.setSoundNotifications($0) }
                        )
                    )

                    SettingToggleRow(
                        "Show App Icon in Dock",
                        systemImage: "dock.rectangle",
                        iconColor: .accentColor,
                        isOn: Binding(
                            get: { preferences.showInDock },
                            set: { viewModel.setShowInDock($0) }
                        )
                    )

                    SettingToggleRow(
                        "Launch at Login",
                        systemImage: "power",
                        iconColor: .accentColor,
                        isOn: Binding(
                            get: { LoginItemManager.isEnabled() },
                            set: { _ in viewModel.toggleLoginItem() }
                        )
                    )

                    if viewModel.needsLoginApproval {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Text("Approval needed in System Settings → Login Items")
                                .font(.system(size: 10.5))
                                .foregroundColor(.orange)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            GlassGroup(spacing: 4) {
                                FlatActionButton(
                                    title: "Open",
                                    tone: .neutral,
                                    height: 20,
                                    horizontalPadding: 8,
                                    fontSize: 10.5
                                ) {
                                    viewModel.openLoginItemsSettings()
                                }
                            }
                        }
                    }
                }
            }

            // Card 3: Passwordless Sudo
            GlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(viewModel.snapshot.sudoConfigured ? .green : .orange)
                            .frame(width: 16, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Passwordless Sudo")
                                .font(.system(size: 12, weight: .medium))
                            Text(viewModel.snapshot.sudoConfigured ? "Configured" : "Not Configured")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(viewModel.snapshot.sudoConfigured ? .green : .orange)
                        }

                        Spacer(minLength: 4)

                        if viewModel.snapshot.sudoConfigured {
                            if !uiState.confirmingSudoRevoke {
                                GlassGroup(spacing: 4) {
                                    FlatActionButton(
                                        title: "Revoke...",
                                        tone: .neutral,
                                        height: 24,
                                        horizontalPadding: 10,
                                        fontSize: 11
                                    ) {
                                        uiState.confirmingSudoRevoke = true
                                    }
                                }
                            }
                        } else {
                            GlassGroup(spacing: 4) {
                                FlatActionButton(
                                    title: "Setup...",
                                    tone: .accent,
                                    prominent: true,
                                    height: 24,
                                    horizontalPadding: 10,
                                    fontSize: 11
                                ) {
                                    viewModel.setupOrRevokeSudo()
                                }
                            }
                        }
                    }

                    if !viewModel.snapshot.sudoConfigured {
                        SudoWarningNoticeView(
                            message: SudoFeatureAvailability.lackingFeaturesSummary()
                        )
                    }

                    if uiState.confirmingSudoRevoke && viewModel.snapshot.sudoConfigured {
                        HStack(spacing: 6) {
                            Text("Remove passwordless sudo access for Ghost Mode?")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            GlassGroup(spacing: 6) {
                                HStack(spacing: 6) {
                                    FlatActionButton(
                                        title: "Cancel",
                                        tone: .neutral,
                                        height: 22,
                                        horizontalPadding: 8,
                                        fontSize: 10.5
                                    ) {
                                        uiState.confirmingSudoRevoke = false
                                    }

                                    FlatActionButton(
                                        title: "Revoke",
                                        tone: .destructive,
                                        prominent: true,
                                        height: 22,
                                        horizontalPadding: 8,
                                        fontSize: 10.5
                                    ) {
                                        uiState.confirmingSudoRevoke = false
                                        viewModel.setupOrRevokeSudo()
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Card 4: Diagnostics & Maintenance
            GlassCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 15, alignment: .center)
                        Text("Ghost Mode Footprint")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "CPU %.1f%% · %.0f MB", viewModel.ghostCPU, viewModel.ghostMemMB))
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    HStack(spacing: 6) {
                        GlassGroup(spacing: 6) {
                            HStack(spacing: 6) {
                                FlatActionButton(
                                    title: "Copy Diagnostics",
                                    tone: .neutral,
                                    height: 24,
                                    horizontalPadding: 10,
                                    fontSize: 11,
                                    expandWidth: true
                                ) {
                                    viewModel.copyDiagnostics()
                                }

                                if !uiState.confirmingResetDefaults {
                                    FlatActionButton(
                                        title: "Reset Defaults",
                                        tone: .destructive,
                                        height: 24,
                                        horizontalPadding: 10,
                                        fontSize: 11,
                                        expandWidth: true
                                    ) {
                                        uiState.confirmingResetDefaults = true
                                    }
                                }
                            }
                        }
                    }

                    if uiState.confirmingResetDefaults {
                        HStack(spacing: 6) {
                            Text("Reset all preferences to defaults?")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            GlassGroup(spacing: 6) {
                                HStack(spacing: 6) {
                                    FlatActionButton(
                                        title: "Cancel",
                                        tone: .neutral,
                                        height: 22,
                                        horizontalPadding: 8,
                                        fontSize: 10.5
                                    ) {
                                        uiState.confirmingResetDefaults = false
                                    }

                                    FlatActionButton(
                                        title: "Reset",
                                        tone: .destructive,
                                        prominent: true,
                                        height: 22,
                                        horizontalPadding: 8,
                                        fontSize: 10.5
                                    ) {
                                        uiState.confirmingResetDefaults = false
                                        viewModel.resetDefaults()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            }
        }
    }

    private func submitCustomDefaultDuration() {
        guard let seconds = parseDurationString(uiState.customDefaultText), seconds > 0 else {
            viewModel.showBanner(
                .error,
                title: "Invalid Default Duration",
                message: "Enter a duration like '1h', '45m', or raw minutes."
            )
            return
        }
        viewModel.dismissBanner()
        viewModel.setDefaultDuration(seconds)
        uiState.showCustomDefault = false
    }
}
