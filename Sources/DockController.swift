import AppKit
import Foundation
import OSLog

enum DockMode: String, CaseIterable {
    case fullShow = "full_show"
    case hoverShow = "hover_show"
    case activateShow = "activate_show"

    var title: String {
        switch self {
        case .fullShow: return "Full Show"
        case .hoverShow: return "Hover Show"
        case .activateShow: return "Activate Show"
        }
    }

    var subtitle: String {
        switch self {
        case .fullShow: return "Always visible"
        case .hoverShow: return "Auto-hide, 1s hover"
        case .activateShow: return "Top green/red toggle"
        }
    }
}

final class DockController {
    private static let dockDomain = "com.apple.dock" as CFString
    private static let hoverDelay: Double = 1.0
    private static let hiddenSuppressDelay: Double = 100_000.0

    private static let modeDefaultsKey = "dockMode"
    private static let activateVisibleDefaultsKey = "activateDockVisible"
    private static let originalDelayDefaultsKey = "originalAutohideDelay"
    private static let originalDelayExistedDefaultsKey = "originalAutohideDelayExisted"

    private typealias CoreDockGetAutoHideFunc = @convention(c) () -> DarwinBoolean
    private typealias CoreDockSetAutoHideFunc = @convention(c) (DarwinBoolean) -> Void

    private let logger = Logger(subsystem: "com.zandenkane.dockmute", category: "Dock")
    private let dockQueue = DispatchQueue(label: "com.zandenkane.dockmute.dock", qos: .userInteractive)
    private let defaults = UserDefaults.standard

    private var getAutoHideFn: CoreDockGetAutoHideFunc?
    private var setAutoHideFn: CoreDockSetAutoHideFunc?
    private var loadedDockDelay: Double?
    private var dockLaunchObserver: NSObjectProtocol?

    private(set) var mode: DockMode
    private(set) var activateDockVisible: Bool

    var onStateChanged: (() -> Void)?

    init() {
        if let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY) {
            if let getSym = dlsym(handle, "CoreDockGetAutoHideEnabled") {
                getAutoHideFn = unsafeBitCast(getSym, to: CoreDockGetAutoHideFunc.self)
            }
            if let setSym = dlsym(handle, "CoreDockSetAutoHideEnabled") {
                setAutoHideFn = unsafeBitCast(setSym, to: CoreDockSetAutoHideFunc.self)
            }
        }

        let currentDiskDelay = Self.readDockAutohideDelay()
        self.loadedDockDelay = currentDiskDelay

        // Capture the user's pre-existing autohide-delay once (ignoring our own sentinel values).
        if defaults.object(forKey: Self.originalDelayExistedDefaultsKey) == nil {
            if let delay = currentDiskDelay,
               abs(delay - Self.hiddenSuppressDelay) >= 1.0,
               abs(delay - Self.hoverDelay) >= 0.001 {
                defaults.set(true, forKey: Self.originalDelayExistedDefaultsKey)
                defaults.set(delay, forKey: Self.originalDelayDefaultsKey)
            } else {
                defaults.set(false, forKey: Self.originalDelayExistedDefaultsKey)
                defaults.removeObject(forKey: Self.originalDelayDefaultsKey)
            }
        }

        if let savedRaw = defaults.string(forKey: Self.modeDefaultsKey),
           let savedMode = DockMode(rawValue: savedRaw) {
            self.mode = savedMode
        } else {
            self.mode = .fullShow
            defaults.set(DockMode.fullShow.rawValue, forKey: Self.modeDefaultsKey)
        }

        if defaults.object(forKey: Self.activateVisibleDefaultsKey) != nil {
            self.activateDockVisible = defaults.bool(forKey: Self.activateVisibleDefaultsKey)
        } else {
            self.activateDockVisible = false
            defaults.set(false, forKey: Self.activateVisibleDefaultsKey)
        }

        dockLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            self.dockQueue.async {
                self.loadedDockDelay = Self.readDockAutohideDelay()
            }
        }
    }

    deinit {
        if let observer = dockLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func applyCurrentState() {
        apply(mode: mode, activateVisible: activateDockVisible)
    }

    func setMode(_ newMode: DockMode) {
        let changedFromOtherMode = (mode != newMode)
        mode = newMode
        defaults.set(newMode.rawValue, forKey: Self.modeDefaultsKey)

        // When entering Activate Show from another mode, start Red (hidden) so clicking activates it.
        if newMode == .activateShow && changedFromOtherMode {
            activateDockVisible = false
            defaults.set(false, forKey: Self.activateVisibleDefaultsKey)
        }

        apply(mode: mode, activateVisible: activateDockVisible)
        notifyStateChanged()
    }

    func toggleActivateVisibility() {
        guard mode == .activateShow else { return }
        activateDockVisible.toggle()
        defaults.set(activateDockVisible, forKey: Self.activateVisibleDefaultsKey)

        let shouldHide = !activateDockVisible
        dockQueue.async { [weak self] in
            guard let self else { return }
            Self.writeDockPref(key: "autohide-delay", value: NSNumber(value: Self.hiddenSuppressDelay))
            let needsReload = (self.loadedDockDelay.map { abs($0 - Self.hiddenSuppressDelay) > 1.0 } ?? true)
            if needsReload {
                Self.writeDockPref(key: "autohide", value: shouldHide as CFBoolean)
                self.restartDockAndVerify(expectedAutoHide: shouldHide, newLoadedDelay: Self.hiddenSuppressDelay)
            } else {
                self.setAutoHideLive(shouldHide)
            }
        }
        notifyStateChanged()
    }

    func currentSystemAutoHide() -> Bool {
        if let fn = getAutoHideFn {
            return fn().boolValue
        }
        return (CFPreferencesCopyAppValue("autohide" as CFString, Self.dockDomain) as? Bool) ?? false
    }

    // MARK: - Internal Dock Control

    private func apply(mode targetMode: DockMode, activateVisible: Bool) {
        let hadOriginalDelay = defaults.bool(forKey: Self.originalDelayExistedDefaultsKey)
        let originalDelay = defaults.object(forKey: Self.originalDelayDefaultsKey) as? Double

        dockQueue.async { [weak self] in
            guard let self else { return }
            switch targetMode {
            case .fullShow:
                if hadOriginalDelay, let delay = originalDelay {
                    Self.writeDockPref(key: "autohide-delay", value: NSNumber(value: delay))
                } else {
                    Self.writeDockPref(key: "autohide-delay", value: nil)
                }
                self.setAutoHideLive(false)
                self.logger.notice("Applied Dock mode: Full Show")

            case .hoverShow:
                Self.writeDockPref(key: "autohide-delay", value: NSNumber(value: Self.hoverDelay))
                let needsReload = (self.loadedDockDelay.map { abs($0 - Self.hoverDelay) > 0.001 } ?? true)
                if needsReload {
                    Self.writeDockPref(key: "autohide", value: true as CFBoolean)
                    self.restartDockAndVerify(expectedAutoHide: true, newLoadedDelay: Self.hoverDelay)
                } else {
                    self.setAutoHideLive(true)
                }
                self.logger.notice("Applied Dock mode: Hover Show (delay=1.0s)")

            case .activateShow:
                let shouldHide = !activateVisible
                Self.writeDockPref(key: "autohide-delay", value: NSNumber(value: Self.hiddenSuppressDelay))
                let needsReload = (self.loadedDockDelay.map { abs($0 - Self.hiddenSuppressDelay) > 1.0 } ?? true)
                if needsReload {
                    Self.writeDockPref(key: "autohide", value: shouldHide as CFBoolean)
                    self.restartDockAndVerify(expectedAutoHide: shouldHide, newLoadedDelay: Self.hiddenSuppressDelay)
                } else {
                    self.setAutoHideLive(shouldHide)
                }
                self.logger.notice("Applied Dock mode: Activate Show (visible=\(activateVisible))")
            }
        }
    }

    private func setAutoHideLive(_ hidden: Bool) {
        if let fn = setAutoHideFn {
            fn(DarwinBoolean(hidden))
        } else {
            Self.writeDockPref(key: "autohide", value: hidden as CFBoolean)
            restartDockAndVerify(expectedAutoHide: hidden, newLoadedDelay: Self.readDockAutohideDelay())
        }
    }

    private func restartDockAndVerify(expectedAutoHide: Bool, newLoadedDelay: Double?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["Dock"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            loadedDockDelay = newLoadedDelay
            Thread.sleep(forTimeInterval: 0.45)
            if let fn = setAutoHideFn, currentSystemAutoHide() != expectedAutoHide {
                fn(DarwinBoolean(expectedAutoHide))
            }
        } catch {
            logger.error("Failed to restart Dock: \(error.localizedDescription)")
            if let fn = setAutoHideFn {
                fn(DarwinBoolean(expectedAutoHide))
            }
        }
    }

    private static func readDockAutohideDelay() -> Double? {
        CFPreferencesAppSynchronize(dockDomain)
        guard let raw = CFPreferencesCopyAppValue("autohide-delay" as CFString, dockDomain) else {
            return nil
        }
        return (raw as? NSNumber)?.doubleValue
    }

    private static func writeDockPref(key: String, value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, dockDomain)
        CFPreferencesAppSynchronize(dockDomain)
    }

    private func notifyStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?()
        }
    }
}
