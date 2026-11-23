import AudioToolbox
import CoreAudio
import Foundation
import OSLog

struct AudioOutputDeviceInfo {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let outputChannels: Int

    var isBuiltIn: Bool {
        outputChannels > 0 && (
            transportType == kAudioDeviceTransportTypeBuiltIn ||
            uid == "BuiltInSpeakerDevice"
        )
    }

    var isWirelessHeadphone: Bool {
        guard outputChannels > 0 else { return false }
        if transportType == kAudioDeviceTransportTypeBluetooth ||
           transportType == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        let lower = name.lowercased()
        let keywords = ["airpod", "beats", "earbud", "headphone", "buds", "pods"]
        return keywords.contains(where: { lower.contains($0) })
    }
}

final class AudioMuteController {
    private static let enabledDefaultsKey = "autoMuteEnabled"
    // Compatible with macOS 11+ (matches both kAudioObjectPropertyElementMaster and kAudioObjectPropertyElementMain).
    private static let mainElement: AudioObjectPropertyElement = 0
    // 'vmvc' — matches both VirtualMasterVolume (macOS 11) and VirtualMainVolume (macOS 12+).
    private static let virtualMainVolumeSelector: AudioObjectPropertySelector = 0x766d7663

    private let logger = Logger(subsystem: "com.zandenkane.dockmute", category: "AudioMute")
    private let audioQueue = DispatchQueue(label: "com.zandenkane.dockmute.audio", qos: .userInteractive)
    private let defaults = UserDefaults.standard

    private var trackedWirelessByUID: [String: AudioOutputDeviceInfo] = [:]
    private var aliveListenerBlocks: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    private var lastDefaultOutput: AudioOutputDeviceInfo?
    private var lastAutoMuteDate: Date = .distantPast
    private var muteGuardUntil: Date = .distantPast

    private(set) var isAutoMuteEnabled: Bool
    private(set) var lastMuteReason: String?
    private(set) var lastMuteTimestamp: Date?

    var onMuteEvent: ((String, Date) -> Void)?

    init() {
        if defaults.object(forKey: Self.enabledDefaultsKey) != nil {
            isAutoMuteEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        } else {
            isAutoMuteEnabled = true
            defaults.set(true, forKey: Self.enabledDefaultsKey)
        }
    }

    deinit {
        stopMonitoring()
    }

    func setAutoMuteEnabled(_ enabled: Bool) {
        isAutoMuteEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    func startMonitoring() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.refreshTrackedDevices(triggerOnRemoval: false)
            if let defID = Self.defaultOutputDeviceID() {
                self.lastDefaultOutput = Self.deviceInfo(for: defID)
            }
            self.installSystemListeners()
            self.logger.notice("Audio monitor started. Wireless devices tracked: \(self.trackedWirelessByUID.count)")
        }
    }

    func stopMonitoring() {
        audioQueue.sync {
            let sysObj = AudioObjectID(kAudioObjectSystemObject)
            if let block = devicesListenerBlock {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: Self.mainElement
                )
                AudioObjectRemovePropertyListenerBlock(sysObj, &addr, audioQueue, block)
                devicesListenerBlock = nil
            }
            if let block = defaultOutputListenerBlock {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: Self.mainElement
                )
                AudioObjectRemovePropertyListenerBlock(sysObj, &addr, audioQueue, block)
                defaultOutputListenerBlock = nil
            }
            for (deviceID, block) in aliveListenerBlocks {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: Self.mainElement
                )
                AudioObjectRemovePropertyListenerBlock(deviceID, &addr, audioQueue, block)
            }
            aliveListenerBlocks.removeAll()
        }
    }

    func triggerAutoMute(reason: String, scheduleWakeRecheck: Bool = false) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self.isAutoMuteEnabled else {
                self.logger.notice("Auto-mute disabled; skipping trigger: \(reason)")
                return
            }
            self.performMute(reason: reason, scheduleWakeRecheck: scheduleWakeRecheck)
        }
    }

    func muteNowManually() {
        audioQueue.async { [weak self] in
            self?.performMute(reason: "Manual mute", scheduleWakeRecheck: false)
        }
    }

    func isDefaultOutputMuted() -> Bool {
        guard let id = Self.defaultOutputDeviceID() else { return false }
        return Self.isDeviceMuted(id)
    }

    // MARK: - CoreAudio Listeners

    private func installSystemListeners() {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: Self.mainElement
        )
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshTrackedDevices(triggerOnRemoval: true)
        }
        devicesListenerBlock = devBlock
        AudioObjectAddPropertyListenerBlock(sysObj, &devicesAddr, audioQueue, devBlock)

        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: Self.mainElement
        )
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChanged()
        }
        defaultOutputListenerBlock = defBlock
        AudioObjectAddPropertyListenerBlock(sysObj, &defaultAddr, audioQueue, defBlock)
    }

    private func refreshTrackedDevices(triggerOnRemoval: Bool) {
        let allOutputDevices = Self.allDevices().compactMap { Self.deviceInfo(for: $0) }.filter { $0.outputChannels > 0 }
        var currentWirelessByUID: [String: AudioOutputDeviceInfo] = [:]
        for dev in allOutputDevices where dev.isWirelessHeadphone {
            currentWirelessByUID[dev.uid] = dev
        }

        if triggerOnRemoval {
            var disconnectedNames: [String] = []
            for (uid, oldDev) in trackedWirelessByUID where currentWirelessByUID[uid] == nil {
                disconnectedNames.append(oldDev.name)
            }
            if !disconnectedNames.isEmpty && isAutoMuteEnabled {
                let joined = disconnectedNames.joined(separator: ", ")
                performMute(reason: "AirPods/Bluetooth disconnected (\(joined))", scheduleWakeRecheck: true)
            }
        }

        let currentWirelessIDs = Set(currentWirelessByUID.values.map { $0.id })
        for (deviceID, block) in aliveListenerBlocks where !currentWirelessIDs.contains(deviceID) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: Self.mainElement
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &addr, audioQueue, block)
            aliveListenerBlocks.removeValue(forKey: deviceID)
        }

        for dev in currentWirelessByUID.values where aliveListenerBlocks[dev.id] == nil {
            let devName = dev.name
            let devID = dev.id
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: Self.mainElement
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                if !Self.isDeviceAlive(devID) && self.isAutoMuteEnabled {
                    self.performMute(reason: "AirPods/Bluetooth disconnected (\(devName))", scheduleWakeRecheck: true)
                }
            }
            if AudioObjectAddPropertyListenerBlock(devID, &addr, audioQueue, block) == noErr {
                aliveListenerBlocks[devID] = block
            }
        }

        trackedWirelessByUID = currentWirelessByUID
    }

    private func handleDefaultOutputChanged() {
        let previous = lastDefaultOutput
        let newID = Self.defaultOutputDeviceID()
        let current = newID.flatMap { Self.deviceInfo(for: $0) }
        lastDefaultOutput = current

        guard isAutoMuteEnabled else { return }

        if let prev = previous, prev.isWirelessHeadphone {
            let stillPresentAndAlive = Self.isDeviceAlive(prev.id) && Self.allDevices().contains(prev.id)
            if !stillPresentAndAlive {
                performMute(reason: "AirPods/Bluetooth disconnected (\(prev.name))", scheduleWakeRecheck: true)
                return
            }
        }

        if Date() < muteGuardUntil, let cur = current, cur.isBuiltIn {
            _ = Self.muteDevice(cur.id)
            logger.notice("Re-asserted mute after audio route switch to \(cur.name)")
        }
    }

    // MARK: - Muting Execution

    private func performMute(reason: String, scheduleWakeRecheck: Bool) {
        let now = Date()
        let isBurstDuplicate = now.timeIntervalSince(lastAutoMuteDate) < 0.35
        lastAutoMuteDate = now
        muteGuardUntil = now.addingTimeInterval(3.0)

        let mutedTargets = muteDefaultAndBuiltInSpeakers()

        if !isBurstDuplicate {
            logger.notice("Auto-muted (\(reason)). Targets muted: \(mutedTargets.joined(separator: ", "))")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastMuteReason = reason
                self.lastMuteTimestamp = now
                self.onMuteEvent?(reason, now)
            }
        }

        if scheduleWakeRecheck {
            audioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.isAutoMuteEnabled else { return }
                _ = self.muteDefaultAndBuiltInSpeakers()
            }
        }
    }

    @discardableResult
    private func muteDefaultAndBuiltInSpeakers() -> [String] {
        var targetIDs = Set<AudioDeviceID>()
        if let defID = Self.defaultOutputDeviceID(), defID != kAudioObjectUnknown {
            targetIDs.insert(defID)
        }
        for devID in Self.allDevices() {
            if let info = Self.deviceInfo(for: devID), info.isBuiltIn {
                targetIDs.insert(devID)
            }
        }

        var mutedNames: [String] = []
        for id in targetIDs {
            if Self.muteDevice(id) {
                let name = Self.deviceInfo(for: id)?.name ?? "Device \(id)"
                mutedNames.append(name)
            }
        }
        return mutedNames
    }

    // MARK: - CoreAudio Helpers

    private static func allDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: Self.mainElement
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: Self.mainElement
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func copyStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: Self.mainElement
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = unmanaged?.takeRetainedValue() else {
            return nil
        }
        return cfStr as String
    }

    private static func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: Self.mainElement
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let buf = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(buf)
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: Self.mainElement
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    private static func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: Self.mainElement
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }

    private static func deviceInfo(for deviceID: AudioDeviceID) -> AudioOutputDeviceInfo? {
        guard let name = copyStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName),
              let uid = copyStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        return AudioOutputDeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            transportType: transportType(deviceID: deviceID),
            outputChannels: outputChannelCount(deviceID: deviceID)
        )
    }

    private static func isDeviceMuted(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: Self.mainElement
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return false
    }

    private static func muteDevice(_ deviceID: AudioDeviceID) -> Bool {
        if setMuteFlag(deviceID: deviceID, element: Self.mainElement) {
            return true
        }

        let ch1 = setMuteFlag(deviceID: deviceID, element: 1)
        let ch2 = setMuteFlag(deviceID: deviceID, element: 2)
        if ch1 || ch2 {
            return true
        }

        var volAddr = AudioObjectPropertyAddress(
            mSelector: Self.virtualMainVolumeSelector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: Self.mainElement
        )
        if AudioObjectHasProperty(deviceID, &volAddr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &volAddr, &settable) == noErr, settable.boolValue {
                var zero: Float32 = 0.0
                if AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero) == noErr {
                    return true
                }
            }
        }
        return false
    }

    private static func setMuteFlag(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr, settable.boolValue else {
            return false
        }
        var muted: UInt32 = 1
        return AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted) == noErr
    }
}
