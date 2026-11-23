import AppKit
import CoreGraphics
import Foundation

enum MenuBarPlacement: String {
    case leftOverlay = "left_overlay"
    case rightStandard = "right_standard"
}

private final class MenuBarOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class MenuBarHoverButton: NSView {
    var iconImage: NSImage? {
        didSet { needsDisplay = true }
    }
    var tintColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var isDarkMenuBar: Bool = true {
        didSet { needsDisplay = true }
    }
    var isMenuActive: Bool = false {
        didSet { needsDisplay = true }
    }
    var onPress: (() -> Void)?
    var onCommandDragDelta: ((CGFloat) -> Void)?

    private var isHovered = false
    private var isPressed = false
    private var isCommandDragging = false
    private var lastDragScreenX: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
    }

    func refreshHoverState() {
        guard let win = window else {
            isHovered = false
            needsDisplay = true
            return
        }
        let locInWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let locInSelf = convert(locInWindow, from: nil)
        isHovered = bounds.contains(locInSelf)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            isCommandDragging = true
            lastDragScreenX = NSEvent.mouseLocation.x
            return
        }
        isPressed = true
        needsDisplay = true
        onPress?()
        isPressed = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isCommandDragging else { return }
        let currentX = NSEvent.mouseLocation.x
        let dx = currentX - lastDragScreenX
        lastDragScreenX = currentX
        if abs(dx) > 0.25 {
            onCommandDragDelta?(dx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isCommandDragging = false
        isPressed = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Ensure non-zero backing-store alpha across the entire button rect so WindowServer
        // never passes clicks through hollow interiors of outlined SF Symbols.
        NSColor(white: 0.5, alpha: 0.01).setFill()
        bounds.fill()

        if isMenuActive || isPressed || isHovered {
            let alpha: CGFloat = (isMenuActive || isPressed) ? 0.24 : 0.14
            let fill = isDarkMenuBar
                ? NSColor.white.withAlphaComponent(alpha)
                : NSColor.black.withAlphaComponent(alpha * 0.75)
            let pillRect = bounds.insetBy(dx: 1, dy: 2)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 5.5, yRadius: 5.5)
            fill.setFill()
            pillPath.fill()
        }

        guard let img = iconImage else { return }
        let drawSize = img.size
        let dest = NSRect(
            x: round((bounds.width - drawSize.width) / 2.0),
            y: round((bounds.height - drawSize.height) / 2.0),
            width: drawSize.width,
            height: drawSize.height
        )

        if let tint = tintColor, img.isTemplate {
            let tinted = img.copy() as! NSImage
            tinted.lockFocus()
            tint.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.isTemplate = false
            tinted.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private static let placementDefaultsKey = "menuBarPlacement"
    private static let customOffsetDefaultsKey = "leftOverlayCustomOffsetX"

    private let dockController: DockController
    private let audioController: AudioMuteController
    private let defaults = UserDefaults.standard

    // Left-side overlay UI
    private let panel: MenuBarOverlayPanel
    private let containerView: NSView
    private let modeButton: MenuBarHoverButton
    private let activateButton: MenuBarHoverButton

    // Optional standard right-side NSStatusItem UI (for non-notched / auto-hide / user preference)
    private var rightModeStatusItem: NSStatusItem?
    private var rightActivateStatusItem: NSStatusItem?

    private let modeMenu: NSMenu
    private var fullShowItem: NSMenuItem!
    private var hoverShowItem: NSMenuItem!
    private var activateShowItem: NSMenuItem!
    private var leftSideItem: NSMenuItem!
    private var rightSideItem: NSMenuItem!
    private var resetLeftOffsetItem: NSMenuItem!
    private var autoMuteToggleItem: NSMenuItem!
    private var lastMuteInfoItem: NSMenuItem!

    private var placement: MenuBarPlacement
    private var customLeftOffsetX: CGFloat
    private var currentMenuBarHeight: CGFloat = 38
    private var isDarkMenuBar: Bool = true
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    private let buttonWidth: CGFloat = 28
    private let buttonHeight: CGFloat = 24
    private let buttonGap: CGFloat = 4
    private let notchRightMargin: CGFloat = 96

    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    init(dockController: DockController, audioController: AudioMuteController) {
        self.dockController = dockController
        self.audioController = audioController

        if let saved = defaults.string(forKey: Self.placementDefaultsKey),
           let parsed = MenuBarPlacement(rawValue: saved) {
            self.placement = parsed
        } else {
            self.placement = .leftOverlay
        }
        self.customLeftOffsetX = CGFloat(defaults.double(forKey: Self.customOffsetDefaultsKey))

        self.panel = MenuBarOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 28, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.containerView = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        self.modeButton = MenuBarHoverButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        self.activateButton = MenuBarHoverButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        self.modeMenu = NSMenu()
        super.init()

        configurePanel()
        configureButtons()
        buildMenu()
        registerEnvironmentObservers()
        if placement == .leftOverlay {
            probeMenuBarAppearance()
        }
        syncUI()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
    }

    func syncUI() {
        switch placement {
        case .leftOverlay:
            teardownRightStatusItems()
            updateLeftOverlayAndLayout()
            panel.orderFrontRegardless()
        case .rightStandard:
            panel.orderOut(nil)
            updateRightStatusItems()
        }
        updateMenuStates()
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        // Level 27 sits above status bar / MenuBarAgent (24..26) and below NSMenu popups (101).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        // Visible on all Desktop spaces; automatically hides during native full-screen video/apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = containerView
    }

    private func configureButtons() {
        modeButton.iconImage = Self.makeDockIconImage()
        modeButton.onPress = { [weak self] in
            self?.openLeftOverlayMenu()
        }
        modeButton.onCommandDragDelta = { [weak self] dx in
            self?.nudgeLeftOffset(by: dx)
        }

        activateButton.onPress = { [weak self] in
            self?.toggleActivateDock()
        }
        activateButton.onCommandDragDelta = { [weak self] dx in
            self?.nudgeLeftOffset(by: dx)
        }

        containerView.addSubview(activateButton)
        containerView.addSubview(modeButton)

        modeMenu.delegate = self
    }

    private func buildMenu() {
        fullShowItem = makeModeMenuItem(mode: .fullShow, symbol: "dock.rectangle", action: #selector(selectFullShow))
        hoverShowItem = makeModeMenuItem(mode: .hoverShow, symbol: "cursorarrow.motionlines", action: #selector(selectHoverShow))
        activateShowItem = makeModeMenuItem(mode: .activateShow, symbol: "switch.2", action: #selector(selectActivateShow))

        modeMenu.addItem(fullShowItem)
        modeMenu.addItem(hoverShowItem)
        modeMenu.addItem(activateShowItem)

        modeMenu.addItem(.separator())

        autoMuteToggleItem = NSMenuItem(
            title: "Auto-Mute (Lid, Wake, AirPods)",
            action: #selector(toggleAutoMute),
            keyEquivalent: ""
        )
        autoMuteToggleItem.target = self
        modeMenu.addItem(autoMuteToggleItem)

        lastMuteInfoItem = NSMenuItem(title: "Auto-Mute: Listening", action: nil, keyEquivalent: "")
        lastMuteInfoItem.isEnabled = false
        modeMenu.addItem(lastMuteInfoItem)

        let muteNowItem = NSMenuItem(title: "Mute Volume Now", action: #selector(muteNow), keyEquivalent: "")
        muteNowItem.target = self
        muteNowItem.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
        modeMenu.addItem(muteNowItem)

        modeMenu.addItem(.separator())

        let positionRoot = NSMenuItem(title: "Menu Bar Position", action: nil, keyEquivalent: "")
        let positionSubmenu = NSMenu()
        leftSideItem = NSMenuItem(title: "Left Side (⌘-Drag to Adjust)", action: #selector(selectLeftOverlay), keyEquivalent: "")
        leftSideItem.target = self
        rightSideItem = NSMenuItem(title: "Right Side (Standard Menu Bar)", action: #selector(selectRightStandard), keyEquivalent: "")
        rightSideItem.target = self
        resetLeftOffsetItem = NSMenuItem(title: "Reset Left Position", action: #selector(resetLeftPosition), keyEquivalent: "")
        resetLeftOffsetItem.target = self
        positionSubmenu.addItem(leftSideItem)
        positionSubmenu.addItem(rightSideItem)
        positionSubmenu.addItem(.separator())
        positionSubmenu.addItem(resetLeftOffsetItem)
        positionRoot.submenu = positionSubmenu
        modeMenu.addItem(positionRoot)

        modeMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit DockMute", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        modeMenu.addItem(quitItem)
    }

    private func makeModeMenuItem(mode: DockMode, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(mode.title) — \(mode.subtitle)", action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: mode.title)
        return item
    }

    private func registerEnvironmentObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.placement == .leftOverlay else { return }
            self.updateLeftOverlayAndLayout()
            self.probeMenuBarAppearance()
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.placement == .leftOverlay else { return }
            self.updateLeftOverlayAndLayout()
            self.probeMenuBarAppearance()
        }

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.placement == .leftOverlay else { return }
            self.probeMenuBarAppearance()
        }
    }

    /// Briefly queries macOS's actual menu bar contrast (dark vs light wallpaper behind the bar)
    /// without keeping any permanent icon on the right side.
    private func probeMenuBarAppearance() {
        let probe = NSStatusBar.system.statusItem(withLength: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            defer { NSStatusBar.system.removeStatusItem(probe) }
            guard let self, let btn = probe.button else { return }
            let match = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            let dark = (match == .darkAqua || match == .vibrantDark)
            if self.isDarkMenuBar != dark {
                self.isDarkMenuBar = dark
                if self.placement == .leftOverlay {
                    self.updateLeftOverlayAndLayout()
                }
            }
        }
    }

    // MARK: - Left Overlay Layout

    private func updateLeftOverlayAndLayout() {
        let showActivateToggle = (dockController.mode == .activateShow)
        let totalWidth: CGFloat = showActivateToggle
            ? (buttonWidth * 2 + buttonGap)
            : buttonWidth

        containerView.frame = NSRect(x: 0, y: 0, width: totalWidth, height: buttonHeight)

        if showActivateToggle {
            activateButton.isHidden = false
            activateButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
            modeButton.frame = NSRect(x: buttonWidth + buttonGap, y: 0, width: buttonWidth, height: buttonHeight)

            let isShown = dockController.activateDockVisible
            activateButton.iconImage = Self.makeIndicatorImage(isGreen: isShown)
            activateButton.tintColor = nil
            activateButton.isDarkMenuBar = isDarkMenuBar
            activateButton.toolTip = isShown
                ? "Dock Shown (Green) — Click to hide"
                : "Dock Hidden (Red) — Click to show"
        } else {
            activateButton.isHidden = true
            modeButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        }

        modeButton.isDarkMenuBar = isDarkMenuBar
        modeButton.tintColor = isDarkMenuBar
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor.black.withAlphaComponent(0.88)
        modeButton.toolTip = "Dock Mode: \(dockController.mode.title)"

        positionPanel(width: totalWidth)
    }

    private func positionPanel(width: CGFloat) {
        guard let screen = preferredMenuBarScreen() else { return }

        let screenFrame = screen.frame
        let menuBarHeight: CGFloat
        var notchLeftEdge: CGFloat?

        if #available(macOS 12.0, *), let auxLeft = screen.auxiliaryTopLeftArea, auxLeft.width > 0, auxLeft.height > 0 {
            let fullBar = max(screenFrame.maxY - screen.visibleFrame.maxY, auxLeft.height)
            menuBarHeight = fullBar > 0 ? fullBar : auxLeft.height
            notchLeftEdge = auxLeft.maxX
        } else {
            let inferred = screenFrame.maxY - screen.visibleFrame.maxY
            menuBarHeight = (inferred >= 20 && inferred <= 60) ? inferred : NSStatusBar.system.thickness
        }
        currentMenuBarHeight = menuBarHeight

        let panelY = round(screenFrame.maxY - (menuBarHeight + buttonHeight) / 2.0)

        let baseX: CGFloat
        let maxAllowedX: CGFloat
        if let leftEdge = notchLeftEdge {
            baseX = leftEdge - notchRightMargin - width
            maxAllowedX = leftEdge - 4 - width
        } else {
            // Non-notched displays: default cleanly to the center-left open area past standard app menus.
            baseX = screenFrame.midX - (width / 2.0)
            maxAllowedX = screenFrame.maxX - width - 220
        }

        let minAllowedX = screenFrame.minX + 44
        let clampedX = min(max(baseX + customLeftOffsetX, minAllowedX), max(minAllowedX, maxAllowedX))

        panel.setFrame(NSRect(x: round(clampedX), y: panelY, width: width, height: buttonHeight), display: true)
        panel.orderFrontRegardless()
    }

    private func preferredMenuBarScreen() -> NSScreen? {
        if #available(macOS 12.0, *) {
            if let notched = NSScreen.screens.first(where: { ($0.auxiliaryTopLeftArea?.width ?? 0) > 0 }) {
                return notched
            }
        }
        return NSScreen.screens.first
    }

    private func nudgeLeftOffset(by dx: CGFloat) {
        customLeftOffsetX += dx
        defaults.set(Double(customLeftOffsetX), forKey: Self.customOffsetDefaultsKey)
        updateLeftOverlayAndLayout()
    }

    // MARK: - Standard Right-Side Status Items

    private func updateRightStatusItems() {
        if rightModeStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: 24)
            item.autosaveName = "com.zandenkane.dockmute.mode"
            if let button = item.button {
                button.image = Self.makeDockIconImage()
                button.imagePosition = .imageOnly
            }
            item.menu = modeMenu
            rightModeStatusItem = item
        }
        rightModeStatusItem?.button?.toolTip = "Dock Mode: \(dockController.mode.title)"

        if dockController.mode == .activateShow {
            if rightActivateStatusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: 22)
                item.autosaveName = "com.zandenkane.dockmute.activateToggle"
                if let button = item.button {
                    button.target = self
                    button.action = #selector(toggleActivateDock)
                    button.imagePosition = .imageOnly
                }
                rightActivateStatusItem = item
            }
            if let button = rightActivateStatusItem?.button {
                let isShown = dockController.activateDockVisible
                button.image = Self.makeIndicatorImage(isGreen: isShown)
                button.toolTip = isShown
                    ? "Dock Shown (Green) — Click to hide"
                    : "Dock Hidden (Red) — Click to show"
            }
        } else if let existing = rightActivateStatusItem {
            NSStatusBar.system.removeStatusItem(existing)
            rightActivateStatusItem = nil
        }
    }

    private func teardownRightStatusItems() {
        if let item = rightActivateStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            rightActivateStatusItem = nil
        }
        if let item = rightModeStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            rightModeStatusItem = nil
        }
    }

    // MARK: - Menu Sync & Drawing

    private func updateMenuStates() {
        fullShowItem.state = (dockController.mode == .fullShow) ? .on : .off
        hoverShowItem.state = (dockController.mode == .hoverShow) ? .on : .off
        activateShowItem.state = (dockController.mode == .activateShow) ? .on : .off

        leftSideItem.state = (placement == .leftOverlay) ? .on : .off
        rightSideItem.state = (placement == .rightStandard) ? .on : .off
        resetLeftOffsetItem.isEnabled = (placement == .leftOverlay && abs(customLeftOffsetX) > 0.5)

        autoMuteToggleItem.state = audioController.isAutoMuteEnabled ? .on : .off

        if let reason = audioController.lastMuteReason, let ts = audioController.lastMuteTimestamp {
            lastMuteInfoItem.title = "Last muted: \(reason) (\(timeFormatter.string(from: ts)))"
        } else {
            lastMuteInfoItem.title = audioController.isAutoMuteEnabled
                ? "Auto-Mute: Listening"
                : "Auto-Mute: Paused"
        }
    }

    private static func makeDockIconImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
        if let sym = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Dock Mode")?
            .withSymbolConfiguration(config) {
            sym.isTemplate = true
            return sym
        }
        let img = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { rect in
            let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2.5, yRadius: 2.5)
            outer.lineWidth = 1.5
            NSColor.black.setStroke()
            outer.stroke()
            let bar = NSBezierPath(roundedRect: NSRect(x: 4, y: 3, width: 10, height: 2.2), xRadius: 1, yRadius: 1)
            NSColor.black.setFill()
            bar.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func makeIndicatorImage(isGreen: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let diameter: CGFloat = 13.0
            let circleRect = NSRect(
                x: (rect.width - diameter) / 2.0,
                y: (rect.height - diameter) / 2.0,
                width: diameter,
                height: diameter
            )
            let path = NSBezierPath(ovalIn: circleRect)

            let topColor: NSColor
            let bottomColor: NSColor
            let strokeColor: NSColor
            if isGreen {
                topColor = NSColor(srgbRed: 0.22, green: 0.88, blue: 0.36, alpha: 1.0)
                bottomColor = NSColor(srgbRed: 0.13, green: 0.72, blue: 0.25, alpha: 1.0)
                strokeColor = NSColor(srgbRed: 0.06, green: 0.45, blue: 0.14, alpha: 0.70)
            } else {
                topColor = NSColor(srgbRed: 1.00, green: 0.32, blue: 0.28, alpha: 1.0)
                bottomColor = NSColor(srgbRed: 0.87, green: 0.16, blue: 0.13, alpha: 1.0)
                strokeColor = NSColor(srgbRed: 0.52, green: 0.06, blue: 0.05, alpha: 0.70)
            }

            if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
                gradient.draw(in: path, angle: -90)
            } else {
                topColor.setFill()
                path.fill()
            }

            strokeColor.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            let highlightRect = NSRect(
                x: circleRect.minX + 2.5,
                y: circleRect.midY + 0.5,
                width: circleRect.width - 5.0,
                height: (circleRect.height / 2.0) - 2.0
            )
            let highlightPath = NSBezierPath(ovalIn: highlightRect)
            NSColor.white.withAlphaComponent(0.28).setFill()
            highlightPath.fill()

            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu & Actions

    private func openLeftOverlayMenu() {
        updateMenuStates()
        modeButton.isMenuActive = true
        let bottomOffset = max(4.0, floor((currentMenuBarHeight - buttonHeight) / 2.0))
        let anchor = NSPoint(x: 0, y: -bottomOffset)
        modeMenu.popUp(positioning: nil, at: anchor, in: modeButton)
        modeButton.isMenuActive = false
        modeButton.refreshHoverState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuStates()
    }

    func menuDidClose(_ menu: NSMenu) {
        modeButton.isMenuActive = false
        modeButton.refreshHoverState()
    }

    @objc private func selectFullShow() {
        dockController.setMode(.fullShow)
    }

    @objc private func selectHoverShow() {
        dockController.setMode(.hoverShow)
    }

    @objc private func selectActivateShow() {
        dockController.setMode(.activateShow)
    }

    @objc private func toggleActivateDock() {
        dockController.toggleActivateVisibility()
    }

    @objc private func selectLeftOverlay() {
        placement = .leftOverlay
        defaults.set(placement.rawValue, forKey: Self.placementDefaultsKey)
        probeMenuBarAppearance()
        syncUI()
    }

    @objc private func selectRightStandard() {
        placement = .rightStandard
        defaults.set(placement.rawValue, forKey: Self.placementDefaultsKey)
        syncUI()
    }

    @objc private func resetLeftPosition() {
        customLeftOffsetX = 0
        defaults.set(0.0, forKey: Self.customOffsetDefaultsKey)
        updateLeftOverlayAndLayout()
    }

    @objc private func toggleAutoMute() {
        audioController.setAutoMuteEnabled(!audioController.isAutoMuteEnabled)
        updateMenuStates()
    }

    @objc private func muteNow() {
        audioController.muteNowManually()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
