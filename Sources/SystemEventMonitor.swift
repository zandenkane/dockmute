import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

final class SystemEventMonitor {
    // 0 matches both kIOMasterPortDefault (macOS 11) and kIOMainPortDefault (macOS 12+).
    private static let ioMainPort: mach_port_t = 0

    private let logger = Logger(subsystem: "com.zandenkane.dockmute", category: "SystemEvents")
    private let onTrigger: (String, Bool) -> Void

    private var workspaceObservers: [NSObjectProtocol] = []

    // IOKit system power
    private var rootPowerConnection: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0

    // IOKit clamshell (lid open/close on MacBooks; safely no-ops on desktop Macs)
    private var clamshellNotifyPort: IONotificationPortRef?
    private var clamshellNotifier: io_object_t = 0
    private var rootDomainService: io_service_t = 0
    private var lastClamshellClosed: Bool = false

    // Built-in display state (catches lid open even when clamshell sleep is disabled)
    private var hasBuiltInDisplay: Bool = false
    private var builtInDisplayWasInactive: Bool = false
    private var displayCallbackRegistered: Bool = false

    private var selfPointer: UnsafeMutableRawPointer?

    init(onTrigger: @escaping (String, Bool) -> Void) {
        self.onTrigger = onTrigger
    }

    deinit {
        stop()
    }

    func start() {
        selfPointer = Unmanaged.passUnretained(self).toOpaque()
        lastClamshellClosed = readClamshellClosed()
        let displayState = inspectBuiltInDisplay()
        hasBuiltInDisplay = displayState.present
        builtInDisplayWasInactive = displayState.present && !displayState.awakeAndOnline

        setupWorkspaceNotifications()
        setupSystemPowerNotifications()
        setupClamshellNotification()
        setupDisplayReconfigurationCallback()

        logger.notice("System event monitor started (clamshellClosed=\(self.lastClamshellClosed), builtInPresent=\(self.hasBuiltInDisplay), builtInInactive=\(self.builtInDisplayWasInactive))")
    }

    func stop() {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        if displayCallbackRegistered, let ptr = selfPointer {
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigCallback, ptr)
            displayCallbackRegistered = false
        }

        if clamshellNotifier != 0 {
            IOObjectRelease(clamshellNotifier)
            clamshellNotifier = 0
        }
        if let port = clamshellNotifyPort {
            IONotificationPortDestroy(port)
            clamshellNotifyPort = nil
        }
        if rootDomainService != 0 {
            IOObjectRelease(rootDomainService)
            rootDomainService = 0
        }

        if powerNotifier != 0 {
            IODeregisterForSystemPower(&powerNotifier)
            powerNotifier = 0
        }
        if let port = powerNotifyPort {
            IONotificationPortDestroy(port)
            powerNotifyPort = nil
        }
        if rootPowerConnection != 0 {
            IOServiceClose(rootPowerConnection)
            rootPowerConnection = 0
        }

        selfPointer = nil
    }

    // MARK: - NSWorkspace Notifications

    private func setupWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastClamshellClosed = self.readClamshellClosed()
            self.syncBuiltInDisplayState()
            self.onTrigger("Mac woke from sleep", true)
        })

        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastClamshellClosed = self.readClamshellClosed()
            self.syncBuiltInDisplayState()
            self.onTrigger("Display woke up", true)
        })

        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastClamshellClosed = self.readClamshellClosed()
        })

        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastClamshellClosed = self.readClamshellClosed()
            if self.hasBuiltInDisplay {
                self.builtInDisplayWasInactive = true
            }
        })
    }

    // MARK: - IOKit System Power

    private func setupSystemPowerNotifications() {
        guard let ptr = selfPointer else { return }
        rootPowerConnection = IORegisterForSystemPower(
            ptr,
            &powerNotifyPort,
            Self.systemPowerCallback,
            &powerNotifier
        )
        if rootPowerConnection != 0, let port = powerNotifyPort {
            let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        } else {
            logger.error("Failed to register for IOKit system power notifications")
        }
    }

    private static let systemPowerCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
        guard let refcon else { return }
        let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleSystemPower(messageType: messageType, messageArgument: messageArgument)
    }

    private func handleSystemPower(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        let msgCanSystemSleep: UInt32 = 0xe0000270
        let msgSystemWillSleep: UInt32 = 0xe0000280
        let msgSystemWillPowerOn: UInt32 = 0xe0000320
        let msgSystemHasPoweredOn: UInt32 = 0xe0000300

        switch messageType {
        case msgCanSystemSleep, msgSystemWillSleep:
            if rootPowerConnection != 0 {
                IOAllowPowerChange(rootPowerConnection, Int(bitPattern: messageArgument))
            }
            lastClamshellClosed = readClamshellClosed()
        case msgSystemWillPowerOn, msgSystemHasPoweredOn:
            lastClamshellClosed = readClamshellClosed()
            onTrigger("Mac woke up", true)
        default:
            break
        }
    }

    // MARK: - IOKit Clamshell (Lid Sensor)

    private func setupClamshellNotification() {
        guard let ptr = selfPointer else { return }
        let matching = IOServiceMatching("IOPMrootDomain")
        rootDomainService = IOServiceGetMatchingService(Self.ioMainPort, matching)
        guard rootDomainService != 0 else {
            logger.error("IOPMrootDomain not found")
            return
        }

        clamshellNotifyPort = IONotificationPortCreate(Self.ioMainPort)
        guard let port = clamshellNotifyPort else { return }
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let kr = IOServiceAddInterestNotification(
            port,
            rootDomainService,
            kIOGeneralInterest,
            Self.clamshellCallback,
            ptr,
            &clamshellNotifier
        )
        if kr != KERN_SUCCESS {
            logger.error("IOServiceAddInterestNotification failed with \(kr)")
        }
    }

    private static let clamshellCallback: IOServiceInterestCallback = { refcon, _, _, _ in
        guard let refcon else { return }
        let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.checkClamshellTransition()
    }

    private func checkClamshellTransition() {
        let nowClosed = readClamshellClosed()
        if lastClamshellClosed && !nowClosed {
            logger.notice("Clamshell transitioned closed -> open")
            onTrigger("Laptop lid opened", true)
        }
        lastClamshellClosed = nowClosed
    }

    private func readClamshellClosed() -> Bool {
        let service: io_service_t
        var shouldRelease = false
        if rootDomainService != 0 {
            service = rootDomainService
        } else {
            service = IOServiceGetMatchingService(Self.ioMainPort, IOServiceMatching("IOPMrootDomain"))
            shouldRelease = (service != 0)
        }
        defer {
            if shouldRelease { IOObjectRelease(service) }
        }
        guard service != 0,
              let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return false
        }
        return (prop as? Bool) ?? false
    }

    // MARK: - Built-in Display Reconfiguration

    private func setupDisplayReconfigurationCallback() {
        guard let ptr = selfPointer else { return }
        if CGDisplayRegisterReconfigurationCallback(Self.displayReconfigCallback, ptr) == .success {
            displayCallbackRegistered = true
        }
    }

    private static let displayReconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        if flags.contains(.beginConfigurationFlag) { return }
        let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            monitor.handleDisplayReconfiguration()
        }
    }

    private func handleDisplayReconfiguration() {
        checkClamshellTransition()
        let state = inspectBuiltInDisplay()
        if state.present {
            hasBuiltInDisplay = true
        }
        if builtInDisplayWasInactive && state.awakeAndOnline {
            logger.notice("Built-in display transitioned inactive -> active")
            onTrigger("Laptop screen opened", true)
        }
        if hasBuiltInDisplay {
            builtInDisplayWasInactive = !state.awakeAndOnline
        }
    }

    private func syncBuiltInDisplayState() {
        let state = inspectBuiltInDisplay()
        if state.present {
            hasBuiltInDisplay = true
        }
        if hasBuiltInDisplay {
            builtInDisplayWasInactive = !state.awakeAndOnline
        }
    }

    private func inspectBuiltInDisplay() -> (present: Bool, awakeAndOnline: Bool) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return (false, false)
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return (false, false)
        }
        for id in displays where CGDisplayIsBuiltin(id) != 0 {
            let awake = (CGDisplayIsAsleep(id) == 0 && CGDisplayIsOnline(id) != 0)
            return (true, awake)
        }
        return (false, false)
    }
}
