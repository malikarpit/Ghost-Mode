//
//  StatusBarController.swift
//  Ghost Mode
//

import AppKit
import SwiftUI

@MainActor
final class GhostPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
    }
}

private final class PopoverContainerView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }

    private func configureAppearance() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateBorderColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }
}

@available(macOS 26.0, *)
private final class PopoverGlassContainerView: NSGlassEffectView {
    private let specularBorderLayer = CAGradientLayer()
    private let specularMaskLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGlass()
    }

    private func configureGlass() {
        style = .regular
        cornerRadius = 18
        wantsLayer = true

        specularBorderLayer.zPosition = 999
        specularBorderLayer.locations = [0.0, 0.35, 1.0]
        specularMaskLayer.fillColor = nil
        specularMaskLayer.strokeColor = NSColor.white.cgColor
        specularMaskLayer.lineWidth = 1.0
        specularBorderLayer.mask = specularMaskLayer
        layer?.addSublayer(specularBorderLayer)

        updateBorderColor()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        specularBorderLayer.frame = bounds
        specularMaskLayer.frame = bounds
        let insetBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        specularMaskLayer.path = CGPath(
            roundedRect: insetBounds,
            cornerWidth: 17.5,
            cornerHeight: 17.5,
            transform: nil
        )
        let isFlipped = layer?.isGeometryFlipped ?? false
        specularBorderLayer.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0.0 : 1.0)
        specularBorderLayer.endPoint = CGPoint(x: 0.5, y: isFlipped ? 1.0 : 0.0)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                specularBorderLayer.colors = [
                    NSColor.white.withAlphaComponent(0.28).cgColor,
                    NSColor.white.withAlphaComponent(0.09).cgColor,
                    NSColor.white.withAlphaComponent(0.04).cgColor
                ]
            } else {
                specularBorderLayer.colors = [
                    NSColor.white.withAlphaComponent(0.75).cgColor,
                    NSColor.black.withAlphaComponent(0.06).cgColor,
                    NSColor.black.withAlphaComponent(0.12).cgColor
                ]
            }
        }
    }
}

private final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let panelWidth: CGFloat = 392
    private var currentHeight: CGFloat = 460
    private var currentHostHeight: CGFloat = 720
    private var lastMaxBodyHeight: CGFloat = 520
    private var latestPreferredHeight: CGFloat = 0
    private var isResizeCoalesced = false
    private var currentTopY: CGFloat?

    private let statusItem: NSStatusItem
    private let panel: GhostPopoverPanel
    private let containerView: NSView
    private let clipView: FlippedClipView
    private let uiState: PopoverUIState
    private let hostingController: NSHostingController<FixedTopPopoverHost>
    private var hostingHeightConstraint: NSLayoutConstraint?
    private let contextMenu: NSMenu
    private let viewModel: GhostModeViewModel
    private let onWillOpen: (() -> Void)?
    private let onPopoverVisibilityChanged: ((Bool) -> Void)?

    private var resizeGeneration: UInt64 = 0
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var spaceChangeObserver: NSObjectProtocol?

    private var lastIconCacheKey: String?
    private var lastButtonTitle: String?

    private let toggleMenuItem = NSMenuItem(title: "Turn On", action: #selector(handleToggleSessionMenu(_:)), keyEquivalent: "")
    private let extend15MenuItem = NSMenuItem(title: "+15m", action: #selector(handleExtend15Menu(_:)), keyEquivalent: "")
    private let extend30MenuItem = NSMenuItem(title: "+30m", action: #selector(handleExtend30Menu(_:)), keyEquivalent: "")
    private let extend60MenuItem = NSMenuItem(title: "+1h", action: #selector(handleExtend60Menu(_:)), keyEquivalent: "")
    private let turnOffScreenMenuItem = NSMenuItem(title: "Turn Off Screen Now", action: #selector(handleTurnOffScreenMenu(_:)), keyEquivalent: "")
    private let screenSaverMenuItem = NSMenuItem(title: "Screen Saver", action: #selector(handleScreenSaverMenu(_:)), keyEquivalent: "")
    private let unfreezeAllMenuItem = NSMenuItem(title: "Unfreeze All", action: #selector(handleUnfreezeAllMenu(_:)), keyEquivalent: "")
    private let preferencesMenuItem = NSMenuItem(title: "Settings...", action: #selector(handlePreferencesMenu(_:)), keyEquivalent: "")
    private let quitMenuItem = NSMenuItem(title: "Quit Ghost Mode", action: #selector(handleQuitMenu(_:)), keyEquivalent: "q")

    init(
        viewModel: GhostModeViewModel,
        onWillOpen: (() -> Void)? = nil,
        onPopoverVisibilityChanged: ((Bool) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onWillOpen = onWillOpen
        self.onPopoverVisibilityChanged = onPopoverVisibilityChanged

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initialRect = NSRect(x: 0, y: 0, width: panelWidth, height: currentHeight)
        self.panel = GhostPopoverPanel(contentRect: initialRect)
        if #available(macOS 26.0, *) {
            self.containerView = PopoverGlassContainerView(frame: initialRect)
        } else {
            self.containerView = PopoverContainerView(frame: initialRect)
        }
        // Flipped clip view pins hostingController.view at top so panel resizes downward only.
        self.clipView = FlippedClipView(frame: NSRect(origin: .zero, size: initialRect.size))
        let initialMaxPanel = min(720, (NSScreen.main?.visibleFrame.height ?? 760) - 36)
        let initialMaxBody = max(200, min(520, initialMaxPanel - 140))
        self.currentHostHeight = initialMaxPanel
        self.lastMaxBodyHeight = initialMaxBody
        let hostUIState = PopoverUIState(hostHeight: initialMaxPanel)
        self.uiState = hostUIState
        let initialHostView = FixedTopPopoverHost(
            viewModel: viewModel,
            preferences: viewModel.preferences,
            uiState: hostUIState,
            maxBodyHeight: initialMaxBody,
            onPreferredHeightChange: nil
        )
        self.hostingController = NSHostingController(rootView: initialHostView)
        if #available(macOS 13.0, *) {
            self.hostingController.sizingOptions = []
        }
        self.contextMenu = NSMenu()

        super.init()

        hostingController.rootView = makeRootHostView(maxBodyHeight: initialMaxBody)

        configureStatusButton()
        configurePanel()
        configureContextMenu()
        updateStatusButton(
            sessionMode: viewModel.sessionMode,
            snapshot: viewModel.snapshot,
            showCountdown: viewModel.preferences.showCountdownInMenuBar
        )
    }

    deinit {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePanel() {
        panel.contentView = containerView

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 18
        clipView.layer?.masksToBounds = true
        if #available(macOS 26.0, *), let glassView = containerView as? NSGlassEffectView {
            glassView.contentView = clipView
        } else {
            clipView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(clipView)
            NSLayoutConstraint.activate([
                clipView.topAnchor.constraint(equalTo: containerView.topAnchor),
                clipView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                clipView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                clipView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
            ])
        }

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(hostingController.view)
        let heightConstraint = hostingController.view.heightAnchor.constraint(equalToConstant: currentHostHeight)
        self.hostingHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: clipView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            hostingController.view.widthAnchor.constraint(equalToConstant: panelWidth),
            heightConstraint
        ])
    }

    private func currentPopoverScreen() -> NSScreen? {
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonRectInWindow = button.convert(button.bounds, to: nil)
            let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
            if let screen = buttonWindow.screen
                ?? NSScreen.screens.first(where: { $0.frame.intersects(buttonRectOnScreen) }) {
                return screen
            }
        }
        return panel.screen ?? NSScreen.main
    }

    private func makeRootHostView(maxBodyHeight: CGFloat) -> FixedTopPopoverHost {
        FixedTopPopoverHost(
            viewModel: viewModel,
            preferences: viewModel.preferences,
            uiState: uiState,
            maxBodyHeight: maxBodyHeight,
            onPreferredHeightChange: { [weak self] height in
                self?.updatePopoverHeight(height)
            }
        )
    }

    private func maxPanelHeightForCurrentScreen() -> CGFloat {
        min(720, (currentPopoverScreen()?.visibleFrame.height ?? 760) - 36)
    }

    private func maxBodyHeightForCurrentScreen() -> CGFloat {
        max(200, min(520, maxPanelHeightForCurrentScreen() - 140))
    }

    private func clampedPopoverHeight(_ preferredHeight: CGFloat) -> CGFloat {
        let maxAvailable = max(220, maxPanelHeightForCurrentScreen())
        return min(maxAvailable, max(220, round(preferredHeight)))
    }

    func updatePopoverHeight(_ preferredHeight: CGFloat) {
        let clamped = clampedPopoverHeight(preferredHeight)
        latestPreferredHeight = clamped
        guard panel.isVisible, !isResizeCoalesced else { return }

        isResizeCoalesced = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isResizeCoalesced = false
            guard self.panel.isVisible else { return }
            self.applyAnimatedPanelHeight(self.latestPreferredHeight)
        }
    }

    private func applyAnimatedPanelHeight(_ targetHeight: CGFloat) {
        let clamped = clampedPopoverHeight(targetHeight)
        guard abs(currentHeight - clamped) > 1 || abs(panel.frame.height - clamped) > 1 else { return }

        currentHeight = clamped
        resizeGeneration &+= 1
        let gen = resizeGeneration

        let frame = panel.frame
        let topY = currentTopY ?? frame.maxY
        let targetRect = NSRect(
            x: frame.origin.x,
            y: topY - clamped,
            width: panelWidth,
            height: clamped
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetRect, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self,
                      self.resizeGeneration == gen,
                      self.panel.isVisible else { return }
                self.panel.invalidateShadow()
            }
        })
    }

    private func configureContextMenu() {
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self

        let items: [NSMenuItem] = [
            toggleMenuItem,
            extend15MenuItem,
            extend30MenuItem,
            extend60MenuItem,
            .separator(),
            turnOffScreenMenuItem,
            screenSaverMenuItem,
            unfreezeAllMenuItem,
            .separator(),
            preferencesMenuItem,
            quitMenuItem
        ]

        for item in items {
            if !item.isSeparatorItem {
                item.target = self
            }
            contextMenu.addItem(item)
        }
    }

    // MARK: - Status Bar Updates

    func updateStatusButton(sessionMode: SessionMode, snapshot: SystemSnapshot, showCountdown: Bool) {
        guard let button = statusItem.button else { return }

        let iconStyle = GhostIconStyle.from(
            sessionMode: sessionMode,
            isLidClosed: snapshot.hasLid && snapshot.isLidClosed
        )
        let iconCacheKey = iconStyle.cacheKey
        var menuBarTitle = ""

        switch sessionMode {
        case .idle, .pendingSleepRestore:
            break
        case .activeFinite(let endDate, _):
            if showCountdown {
                let rem = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
                menuBarTitle = " \(formatDurationCompact(rem))"
            }
        case .activeIndefinite:
            if showCountdown {
                menuBarTitle = " ∞"
            }
        }

        if iconCacheKey != lastIconCacheKey {
            if let image = GhostMenuBarIcon.image(for: iconStyle) {
                image.isTemplate = true
                button.image = image
                lastIconCacheKey = iconCacheKey
            }
        }

        if menuBarTitle != lastButtonTitle {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.title = menuBarTitle
            lastButtonTitle = menuBarTitle
        }
    }

    // MARK: - Click Handling

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            showContextMenu(from: sender)
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if panel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func measureInitialPopoverHeight(maxBodyHeight: CGFloat, hostHeight: CGFloat) -> CGFloat {
        let measurementController = NSHostingController(
            rootView: GhostModePopoverView(
                viewModel: viewModel,
                preferences: viewModel.preferences,
                maxBodyHeight: maxBodyHeight
            )
        )
        if #available(macOS 13.0, *) {
            measurementController.sizingOptions = []
        }
        measurementController.view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: hostHeight)
        measurementController.view.layoutSubtreeIfNeeded()
        let fittingHeight: CGFloat
        if #available(macOS 13.0, *) {
            fittingHeight = measurementController.sizeThatFits(
                in: NSSize(width: panelWidth, height: CGFloat.greatestFiniteMagnitude)
            ).height
        } else {
            fittingHeight = measurementController.view.fittingSize.height
        }
        return fittingHeight > 0 ? clampedPopoverHeight(fittingHeight) : currentHeight
    }

    private func syncHostSizingForCurrentScreen() -> (maxPanel: CGFloat, maxBody: CGFloat) {
        let screenMaxPanel = maxPanelHeightForCurrentScreen()
        let screenMaxBody = maxBodyHeightForCurrentScreen()
        if abs(screenMaxPanel - currentHostHeight) > 1 {
            currentHostHeight = screenMaxPanel
            uiState.hostHeight = screenMaxPanel
            hostingHeightConstraint?.constant = screenMaxPanel
        }
        if abs(screenMaxBody - lastMaxBodyHeight) > 1 {
            lastMaxBodyHeight = screenMaxBody
            hostingController.rootView = makeRootHostView(maxBodyHeight: screenMaxBody)
        }
        return (screenMaxPanel, screenMaxBody)
    }

    func showPopover(tab: PopoverTab? = nil) {
        if let tab = tab {
            viewModel.selectedTab = tab
        }
        onWillOpen?()
        guard let button = statusItem.button else { return }

        let (screenMaxPanel, screenMaxBody) = syncHostSizingForCurrentScreen()

        if !panel.isVisible {
            viewModel.isPopoverVisible = true
            let useSubrouteCached = (tab == nil && uiState.safetyRoute != .root && latestPreferredHeight > 0)
            let initialHeight = useSubrouteCached
                ? clampedPopoverHeight(latestPreferredHeight)
                : measureInitialPopoverHeight(maxBodyHeight: screenMaxBody, hostHeight: screenMaxPanel)
            currentHeight = initialHeight
            latestPreferredHeight = initialHeight

            positionPanel(below: button)
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.makeFirstResponder(nil)
            installDismissMonitors()
            onPopoverVisibilityChanged?(true)
        } else {
            if tab != nil {
                let updatedHeight = measureInitialPopoverHeight(maxBodyHeight: screenMaxBody, hostHeight: screenMaxPanel)
                currentHeight = updatedHeight
                latestPreferredHeight = updatedHeight
            }
            positionPanel(below: button)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(nil)
        }
    }

    func closePopover() {
        guard panel.isVisible || viewModel.isPopoverVisible else { return }
        resizeGeneration &+= 1
        isResizeCoalesced = false
        currentTopY = nil
        panel.orderOut(nil)
        viewModel.isPopoverVisible = false
        removeDismissMonitors()
        onPopoverVisibilityChanged?(false)
    }

    func activateForTextInput() {
        guard panel.isVisible else { return }
        // Activate only in .accessory mode so typing works while preserving Full-Screen Spaces when .regular is active.
        if NSApp.activationPolicy() == .accessory {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionPanel(below button: NSStatusBarButton) {
        let topGap: CGFloat = 6
        let horizontalMargin: CGFloat = 8

        guard let buttonWindow = button.window else {
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let originX = max(visible.minX + horizontalMargin, visible.maxX - panelWidth - horizontalMargin)
                let topY = screen.frame.maxY - topGap
                let originY = topY - currentHeight
                currentTopY = topY
                panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: currentHeight), display: true)
                containerView.layoutSubtreeIfNeeded()
                panel.invalidateShadow()
            }
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)

        let screen = buttonWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(buttonRectOnScreen) })
            ?? NSScreen.main

        var originX = round(buttonRectOnScreen.midX - panelWidth / 2)
        var topY = buttonRectOnScreen.minY - topGap

        if let screen = screen {
            let bounds = screen.visibleFrame
            let minX = bounds.minX + horizontalMargin
            let maxX = max(minX, bounds.maxX - panelWidth - horizontalMargin)
            originX = min(max(originX, minX), maxX)
            topY = min(topY, screen.frame.maxY - topGap)
            let minTopY = bounds.minY + currentHeight + horizontalMargin
            if topY < minTopY {
                topY = min(screen.frame.maxY - topGap, minTopY)
            }
        }

        currentTopY = topY
        let originY = topY - currentHeight
        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: currentHeight), display: true)
        containerView.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    // MARK: - Event Monitors & Space Observer for Clean Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.panel.isVisible else { return }
                let mouseLocation = NSEvent.mouseLocation
                if self.panel.frame.contains(mouseLocation) {
                    return
                }
                if let button = self.statusItem.button,
                   let buttonWindow = button.window {
                    let buttonScreenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                    if buttonScreenRect.contains(mouseLocation) {
                        return
                    }
                }
                self.closePopover()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return event }
            if event.keyCode == 53 {
                self.closePopover()
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                self.viewModel.quitApp()
                return nil
            }
            return event
        }

        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func removeDismissMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceChangeObserver = nil
        }
    }

    // MARK: - Right-Click NSMenu

    private func showContextMenu(from button: NSStatusBarButton) {
        closePopover()
        onWillOpen?()

        let isActive = viewModel.sessionMode.isActive
        if case .pendingSleepRestore = viewModel.sessionMode {
            toggleMenuItem.title = "Restore Normal Sleep"
        } else if isActive {
            toggleMenuItem.title = "Stop"
        } else {
            let defText = formatDurationHuman(viewModel.preferences.defaultDuration)
            toggleMenuItem.title = "Turn On (\(defText))"
        }

        extend15MenuItem.isHidden = !isActive
        extend30MenuItem.isHidden = !isActive
        extend60MenuItem.isHidden = !isActive

        let frozenCount = AppFreezer.shared.frozenCount
        unfreezeAllMenuItem.isHidden = (frozenCount == 0)
        if frozenCount > 0 {
            unfreezeAllMenuItem.title = "Unfreeze All (\(frozenCount))"
        }

        statusItem.menu = contextMenu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === contextMenu {
            statusItem.menu = nil
        }
    }

    @objc private func handleToggleSessionMenu(_ sender: NSMenuItem) {
        if viewModel.sessionMode.isActive {
            viewModel.stopSession()
        } else if case .pendingSleepRestore = viewModel.sessionMode {
            viewModel.stopSession()
        } else {
            viewModel.startDefaultSession()
        }
    }

    @objc private func handleExtend15Menu(_ sender: NSMenuItem) {
        viewModel.extendSession(seconds: 15 * 60)
    }

    @objc private func handleExtend30Menu(_ sender: NSMenuItem) {
        viewModel.extendSession(seconds: 30 * 60)
    }

    @objc private func handleExtend60Menu(_ sender: NSMenuItem) {
        viewModel.extendSession(seconds: 60 * 60)
    }

    @objc private func handleTurnOffScreenMenu(_ sender: NSMenuItem) {
        viewModel.turnOffScreen()
    }

    @objc private func handleScreenSaverMenu(_ sender: NSMenuItem) {
        viewModel.startScreenSaver()
    }

    @objc private func handleUnfreezeAllMenu(_ sender: NSMenuItem) {
        viewModel.unfreezeAllNow()
    }

    @objc private func handlePreferencesMenu(_ sender: NSMenuItem) {
        showPopover(tab: .prefs)
    }

    @objc private func handleQuitMenu(_ sender: NSMenuItem) {
        viewModel.quitApp()
    }
}

// MARK: - Custom Ghost Mode Vector Branding

enum GhostIconStyle: Equatable {
    case resting
    case awake
    case stealth
    case pendingRestore

    static func from(sessionMode: SessionMode, isLidClosed: Bool) -> GhostIconStyle {
        switch sessionMode {
        case .idle:
            return .resting
        case .pendingSleepRestore:
            return .pendingRestore
        case .activeFinite, .activeIndefinite:
            return isLidClosed ? .stealth : .awake
        }
    }

    var cacheKey: String {
        switch self {
        case .resting: return "ghost.resting"
        case .awake: return "ghost.awake"
        case .stealth: return "ghost.stealth"
        case .pendingRestore: return "ghost.pendingRestore"
        }
    }
}

enum GhostVectorGeometry {
    static let canvasSize: CGFloat = 18.0

    static func bodyPath(stealth: Bool) -> CGPath {
        let centerX: CGFloat = 9.0
        let radius: CGFloat = stealth ? 4.9 : 5.4
        let domeY: CGFloat = stealth ? 6.4 : 7.4
        let hemY: CGFloat = stealth ? 11.8 : 14.1
        let valleyY: CGFloat = stealth ? 13.0 : 15.6
        let k = 0.55228475 * radius

        let leftX = centerX - radius
        let rightX = centerX + radius
        let topY = domeY - radius
        let lobeWidth = (rightX - leftX) / 3.0

        let path = CGMutablePath()
        path.move(to: CGPoint(x: leftX, y: hemY))
        path.addLine(to: CGPoint(x: leftX, y: domeY))
        path.addCurve(
            to: CGPoint(x: centerX, y: topY),
            control1: CGPoint(x: leftX, y: domeY - k),
            control2: CGPoint(x: centerX - k, y: topY)
        )
        path.addCurve(
            to: CGPoint(x: rightX, y: domeY),
            control1: CGPoint(x: centerX + k, y: topY),
            control2: CGPoint(x: rightX, y: domeY - k)
        )
        path.addLine(to: CGPoint(x: rightX, y: hemY))

        // Gentle symmetrical 3-wave scalloped hem using rounded cubic lobes.
        let lobeInset = 0.15 * lobeWidth
        for idx in 0..<3 {
            let x0 = rightX - CGFloat(idx) * lobeWidth
            let x1 = rightX - CGFloat(idx + 1) * lobeWidth
            path.addCurve(
                to: CGPoint(x: x1, y: hemY),
                control1: CGPoint(x: x0 - lobeInset, y: valleyY),
                control2: CGPoint(x: x1 + lobeInset, y: valleyY)
            )
        }
        path.closeSubpath()
        return path
    }

    static func restingClosedEyesPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6.15, y: 7.4))
        path.addQuadCurve(to: CGPoint(x: 7.95, y: 7.4), control: CGPoint(x: 7.05, y: 8.5))
        path.move(to: CGPoint(x: 10.05, y: 7.4))
        path.addQuadCurve(to: CGPoint(x: 11.85, y: 7.4), control: CGPoint(x: 10.95, y: 8.5))
        return path
    }

    static func filledSilhouetteWithCutouts(stealth: Bool) -> CGPath {
        let path = CGMutablePath()
        path.addPath(bodyPath(stealth: stealth))
        if stealth {
            path.addRoundedRect(
                in: CGRect(x: 6.45, y: 5.2, width: 1.7, height: 2.6),
                cornerWidth: 0.85,
                cornerHeight: 0.85
            )
            path.addRoundedRect(
                in: CGRect(x: 9.85, y: 5.2, width: 1.7, height: 2.6),
                cornerWidth: 0.85,
                cornerHeight: 0.85
            )
        } else {
            path.addRoundedRect(
                in: CGRect(x: 6.1, y: 6.0, width: 1.9, height: 3.0),
                cornerWidth: 0.95,
                cornerHeight: 0.95
            )
            path.addRoundedRect(
                in: CGRect(x: 10.0, y: 6.0, width: 1.9, height: 3.0),
                cornerWidth: 0.95,
                cornerHeight: 0.95
            )
        }
        return path
    }

    static func stealthLidBarPath() -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(
            in: CGRect(x: 2.5, y: 14.4, width: 13.0, height: 1.8),
            cornerWidth: 0.9,
            cornerHeight: 0.9
        )
        return path
    }
}

enum GhostMenuBarIcon {
    static func image(for style: GhostIconStyle) -> NSImage? {
        if style == .pendingRestore {
            let symbol = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: AppMetadata.name
            )
            let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
            let configured = symbol?.withSymbolConfiguration(config) ?? symbol
            configured?.isTemplate = true
            return configured
        }

        let size = NSSize(width: GhostVectorGeometry.canvasSize, height: GhostVectorGeometry.canvasSize)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            let ink = NSColor.black.cgColor
            ctx.setFillColor(ink)
            ctx.setStrokeColor(ink)

            switch style {
            case .resting:
                ctx.setLineWidth(1.4)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(GhostVectorGeometry.bodyPath(stealth: false))
                ctx.strokePath()

                ctx.setLineWidth(1.3)
                ctx.setLineCap(.round)
                ctx.addPath(GhostVectorGeometry.restingClosedEyesPath())
                ctx.strokePath()

            case .awake:
                ctx.addPath(GhostVectorGeometry.filledSilhouetteWithCutouts(stealth: false))
                ctx.fillPath(using: .evenOdd)

            case .stealth:
                ctx.addPath(GhostVectorGeometry.filledSilhouetteWithCutouts(stealth: true))
                ctx.fillPath(using: .evenOdd)

                ctx.addPath(GhostVectorGeometry.stealthLidBarPath())
                ctx.fillPath(using: .winding)

            case .pendingRestore:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
