import AppKit
import Foundation
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.zandenkane.dockmute", category: "App")
    private var dockController: DockController!
    private var audioController: AudioMuteController!
    private var systemEventMonitor: SystemEventMonitor!
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate menu bar icons if launched while already running.
        if let bundleID = Bundle.main.bundleIdentifier {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != myPID }
            if !others.isEmpty {
                logger.notice("Another instance of DockMute is already running; exiting.")
                NSApp.terminate(nil)
                return
            }
        }

        dockController = DockController()
        audioController = AudioMuteController()
        statusBarController = StatusBarController(
            dockController: dockController,
            audioController: audioController
        )

        dockController.onStateChanged = { [weak self] in
            self?.statusBarController.syncUI()
        }
        audioController.onMuteEvent = { [weak self] _, _ in
            self?.statusBarController.syncUI()
        }

        systemEventMonitor = SystemEventMonitor { [weak self] reason, recheck in
            self?.audioController.triggerAutoMute(reason: reason, scheduleWakeRecheck: recheck)
        }

        dockController.applyCurrentState()
        audioController.startMonitoring()
        systemEventMonitor.start()

        logger.notice("DockMute started in mode: \(self.dockController.mode.rawValue, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemEventMonitor?.stop()
        audioController?.stopMonitoring()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
