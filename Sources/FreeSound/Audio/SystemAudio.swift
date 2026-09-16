import AudioToolbox
import CoreAudio
import Foundation

private protocol HALScalarValue {}
extension UInt32: HALScalarValue {}
extension Int32: HALScalarValue {}
extension Float: HALScalarValue {}
extension Double: HALScalarValue {}

struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
    let transportType: UInt32

    var symbolName: String {
        if !hasOutput { return "mic.fill" }
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform.path"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

struct AudioProcessInfo: Identifiable, Equatable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
}

enum SystemAudioRole {
    case output, input, soundEffects

    fileprivate var selector: AudioObjectPropertySelector {
        switch self {
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        case .soundEffects: return kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }
}

enum SystemAudioError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(message): return message
        case let .coreAudio(operation, status):
            let bits = UInt32(bitPattern: status)
            let bytes = (0..<4).reversed().map { UInt8((bits >> ($0 * 8)) & 0xff) }
            let code = bytes.allSatisfy { (32...126).contains($0) }
                ? "'\(String(bytes: bytes, encoding: .ascii) ?? "")' (\(status))"
                : String(status)
            return "\(operation) failed (Core Audio \(code))."
        }
    }
}

/// HAL queries are deliberately short-lived: device and process IDs can disappear at any time.
enum SystemAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func devices() throws -> [AudioDevice] {
        let ids = try objectIDs(system, selector: kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard let alive: UInt32 = try? scalar(id, selector: kAudioDevicePropertyDeviceIsAlive),
                  alive != 0,
                  let uid = try? string(id, selector: kAudioDevicePropertyDeviceUID),
                  !uid.lowercased().contains("freesound"),
                  let name = try? string(id, selector: kAudioObjectPropertyName) else { return nil }

            let transport: UInt32 = (try? scalar(id, selector: kAudioDevicePropertyTransportType)) ?? 0
            if transport == kAudioDeviceTransportTypeAggregate,
               let composition = try? dictionary(id, selector: kAudioAggregateDevicePropertyComposition),
               (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true {
                return nil
            }

            let outputs = channelCount(id, input: false)
            let inputs = channelCount(id, input: true)
            guard outputs > 0 || inputs > 0 else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, hasOutput: outputs > 0,
                               hasInput: inputs > 0, transportType: transport)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func processes() throws -> [AudioProcessInfo] {
        let ids = try objectIDs(system, selector: kAudioHardwarePropertyProcessObjectList)
        return ids.compactMap { id in
            guard let pid: pid_t = try? scalar(id, selector: kAudioProcessPropertyPID), pid > 0 else {
                return nil // A process may exit between listing and reading its properties.
            }
            let bundleID = (try? string(id, selector: kAudioProcessPropertyBundleID)) ?? ""
            let running: UInt32 = (try? scalar(id, selector: kAudioProcessPropertyIsRunningOutput)) ?? 0
            return AudioProcessInfo(id: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    static func defaultDevice(for role: SystemAudioRole) throws -> AudioObjectID {
        try scalar(system, selector: role.selector)
    }

    static func sampleRate(of device: AudioObjectID) -> Double? {
        guard let rate: Float64 = try? scalar(device, selector: kAudioDevicePropertyNominalSampleRate),
              rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// Whether the hardware allows this device to be the system default for the role.
    static func canBeDefault(_ device: AudioObjectID, for role: SystemAudioRole) -> Bool {
        let scope = role == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        let selector = role == .soundEffects
            ? kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
            : kAudioDevicePropertyDeviceCanBeDefaultDevice
        let eligible: UInt32 = (try? scalar(device, selector: selector, scope: scope)) ?? 0
        return eligible != 0
    }

    static func setDefaultDevice(_ device: AudioObjectID, for role: SystemAudioRole) throws {
        guard canBeDefault(device, for: role) else {
            throw SystemAudioError.unsupported("This device cannot be selected for that audio output or input.")
        }
        try setScalar(device, on: system, address: address(role.selector), operation: "Changing audio device")
    }

    /// Nil means the hardware has no writable volume control (common for HDMI and virtual devices).
    static func volume(of device: AudioObjectID, input: Bool = false) -> Float? {
        let controls = volumeControls(device, input: input)
        let values: [Float32] = controls.compactMap { try? scalar(device, address: $0) }
        guard values.count == controls.count, let maximum = values.max(), maximum.isFinite else { return nil }
        return min(1, max(0, maximum))
    }

    static func setVolume(_ value: Float, of device: AudioObjectID, input: Bool = false) throws {
        guard value.isFinite else { throw SystemAudioError.unsupported("Volume must be a finite number.") }
        let controls = volumeControls(device, input: input)
        guard !controls.isEmpty else { throw SystemAudioError.unsupported("This device has no adjustable volume.") }
        let target = min(1, max(0, value))
        let previous: [Float32] = try controls.map { try scalar(device, address: $0) }
        let peak = previous.max() ?? 0
        // A channel-only device must change every controlled channel. Preserve its existing balance.
        for (index, control) in controls.enumerated() {
            let adjusted = controls.count > 1 && peak > 0 ? target * previous[index] / peak : target
            do {
                try setScalar(adjusted, on: device, address: control, operation: "Changing volume")
            } catch {
                // A disconnect or driver failure can happen mid-write; restore channels already changed.
                for restored in 0..<index {
                    try? setScalar(previous[restored], on: device, address: controls[restored], operation: "Restoring volume")
                }
                throw error
            }
        }
    }

    static func isMuted(_ device: AudioObjectID, input: Bool = false) -> Bool? {
        let controls = muteControls(device, input: input)
        guard !controls.isEmpty else { return nil }
        let values: [UInt32] = controls.compactMap { try? scalar(device, address: $0) }
        guard values.count == controls.count else { return nil }
        return values.allSatisfy { $0 != 0 }
    }

    static func setMuted(_ muted: Bool, of device: AudioObjectID, input: Bool = false) throws {
        let controls = muteControls(device, input: input)
        guard !controls.isEmpty else { throw SystemAudioError.unsupported("This device has no hardware mute control.") }
        let previous: [UInt32] = try controls.map { try scalar(device, address: $0) }
        for (index, control) in controls.enumerated() {
            do {
                try setScalar(UInt32(muted ? 1 : 0), on: device, address: control, operation: "Changing mute")
            } catch {
                for restored in 0..<index {
                    try? setScalar(previous[restored], on: device, address: controls[restored], operation: "Restoring mute")
                }
                throw error
            }
        }
    }

    private static func volumeControls(_ device: AudioObjectID, input: Bool) -> [AudioObjectPropertyAddress] {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        // The virtual main control preserves balance across the preferred channels when provided.
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            let control = address(selector, scope: scope)
            if isSettable(device, address: control) { return [control] }
        }
        return channelControls(device, selector: kAudioDevicePropertyVolumeScalar, input: input)
    }

    private static func muteControls(_ device: AudioObjectID, input: Bool) -> [AudioObjectPropertyAddress] {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        let main = address(kAudioDevicePropertyMute, scope: scope)
        if isSettable(device, address: main) { return [main] }
        return channelControls(device, selector: kAudioDevicePropertyMute, input: input)
    }

    private static func channelControls(_ device: AudioObjectID, selector: AudioObjectPropertySelector,
                                        input: Bool) -> [AudioObjectPropertyAddress] {
        let count = channelCount(device, input: input)
        guard count > 0 else { return [] }
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        let controls = (1...count).map { address(selector, scope: scope, element: UInt32($0)) }
        // A partial mute/volume is misleading: every active channel must be controllable.
        return controls.allSatisfy { isSettable(device, address: $0) } ? controls : []
    }

    private static func channelCount(_ device: AudioObjectID, input: Bool) -> Int {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage) == noErr else { return 0 }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isSettable(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var property = address
        guard AudioObjectHasProperty(object, &property) else { return false }
        var writable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &property, &writable) == noErr && writable.boolValue
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func scalar<T: HALScalarValue>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        try scalar(object, address: address(selector, scope: scope))
    }

    /// Used only for fixed-size HAL numeric values, never Swift reference types.
    private static func scalar<T: HALScalarValue>(_ object: AudioObjectID, address: AudioObjectPropertyAddress) throws -> T {
        var property = address
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, storage)
        try check(status, "Reading audio property")
        guard size == MemoryLayout<T>.size else { throw SystemAudioError.unsupported("The audio driver returned an unexpected property size.") }
        return storage.load(as: T.self)
    }

    private static func setScalar<T: HALScalarValue>(_ value: T, on object: AudioObjectID,
                                     address: AudioObjectPropertyAddress, operation: String) throws {
        var property = address
        var copy = value
        let status = withUnsafeBytes(of: &copy) {
            AudioObjectSetPropertyData(object, &property, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
        try check(status, operation)
    }

    private static func objectIDs(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var property = address(selector)
        for attempt in 0..<3 {
            var size: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Listing audio objects")
            guard size > 0 else { return [] }
            var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            let status = result.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
            }
            if status == kAudioHardwareBadPropertySizeError && attempt < 2 { continue }
            try check(status, "Listing audio objects")
            return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }
        return []
    }

    private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        let value: CFString = try retainedObject(object, selector: selector)
        return value as String
    }

    private static func dictionary(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> [String: Any] {
        let value: CFDictionary = try retainedObject(object, selector: selector)
        return value as NSDictionary as? [String: Any] ?? [:]
    }

    /// Core Audio documents these CF properties as owned by the caller.
    private static func retainedObject<T: AnyObject>(_ object: AudioObjectID,
                                                     selector: AudioObjectPropertySelector) throws -> T {
        var property = address(selector)
        var value: Unmanaged<T>?
        var size = UInt32(MemoryLayout<Unmanaged<T>?>.size)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        try check(status, "Reading audio name")
        guard let value else { throw SystemAudioError.unsupported("The audio driver returned an empty property.") }
        return value.takeRetainedValue()
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw SystemAudioError.coreAudio(operation: operation, status: status) }
    }
}
