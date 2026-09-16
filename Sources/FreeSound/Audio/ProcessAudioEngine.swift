import AudioDSP
import CoreAudio
import Foundation

/// Routes exactly the supplied HAL process objects through a private, stereo tap.
/// Ownership and HAL setup/teardown stay on the main thread. The IOProc is C and
/// only touches preallocated state and lock-free controls.
@available(macOS 14.2, *)
final class ProcessAudioEngine {
    let processIDs: [AudioObjectID]
    let outputDeviceID: AudioObjectID
    let outputUID: String
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    private(set) var cleanupError: String?

    var peakLevel: Float { isRunning ? dsp.map(FSAudioDSPGetPeak) ?? 0 : 0 }
    /// This confirms IO callbacks, not that a playing source or capture permission exists.
    var hasReceivedAudio: Bool { dsp.map { FSAudioDSPGetCallbackCount($0) > 0 } ?? false }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var dsp: OpaquePointer? = FSAudioDSPCreate()
    private var gain: Float = 1
    private var muted = false
    private var balance: Float = 0

    init(processIDs: [AudioObjectID], outputDeviceID: AudioObjectID, outputUID: String) {
        self.processIDs = Array(Set(processIDs)).sorted()
        self.outputDeviceID = outputDeviceID
        self.outputUID = outputUID
    }

    deinit {
        stop()
        // If a broken/disconnected driver refused both IOProc and aggregate
        // destruction, retain its context rather than free memory it can access.
        if ioProc == nil, let dsp { FSAudioDSPDestroy(dsp) }
    }

    func setGain(_ gain: Float) {
        self.gain = gain.isFinite ? min(4, max(0, gain)) : 1
        if let dsp { FSAudioDSPSetGain(dsp, self.gain) }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        if let dsp { FSAudioDSPSetMuted(dsp, muted) }
    }

    func setBalance(_ balance: Float) {
        self.balance = balance.isFinite ? min(1, max(-1, balance)) : 0
        if let dsp { FSAudioDSPSetBalance(dsp, self.balance) }
    }

    func start() throws {
        precondition(Thread.isMainThread, "Start audio routing on the main thread")
        if isRunning { return }
        guard !processIDs.isEmpty, !processIDs.contains(kAudioObjectUnknown) else {
            throw EngineFailure("This app has no audio process to control yet.")
        }
        guard let dsp else { throw EngineFailure("Couldn't allocate the audio processor.") }
        guard tapID == kAudioObjectUnknown, aggregateID == kAudioObjectUnknown, ioProc == nil else {
            throw EngineFailure("The previous audio route could not be released. Quit and reopen FreeSound.")
        }
        cleanupError = nil

        do {
            let outputStreams = try streams(of: outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
            let sourceInputStreams = try streams(of: outputDeviceID, scope: kAudioObjectPropertyScopeInput)
            guard !outputStreams.isEmpty else { throw EngineFailure("The selected output is no longer available.") }
            sampleRate = try read(outputDeviceID, selector: kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
            guard sampleRate > 0 else { throw EngineFailure("The selected output has no valid sample rate.") }

            let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
            description.name = "FreeSound application audio"
            description.isPrivate = true
            description.isExclusive = false
            // The original output remains audible until our IOProc actually reads the tap.
            description.muteBehavior = .mutedWhenTapped
            tapDescription = description
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Create app audio tap")
            let tapUID = try stringProperty(tapID, selector: kAudioTapPropertyUID)

            var composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "FreeSound private route",
                kAudioAggregateDeviceUIDKey: "dev.freesound.route.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                // Do not wait for a silent application to start playing during AudioDeviceStart.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]]
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Create private audio route")

            try waitForConfiguration("The output did not finish connecting.") {
                try self.streams(of: self.aggregateID, scope: kAudioObjectPropertyScopeOutput).count == outputStreams.count
                    && self.streams(of: self.aggregateID, scope: kAudioObjectPropertyScopeInput).count == sourceInputStreams.count
            }

            // Identify the input streams BEFORE attaching the tap. Duplex devices
            // may contain microphones; none of these physical streams are enabled.
            let physicalInputs = Set(try streams(of: aggregateID, scope: kAudioObjectPropertyScopeInput))
            composition[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
            var updatedComposition = composition as CFDictionary
            try write(aggregateID, selector: kAudioAggregateDevicePropertyComposition, value: &updatedComposition)
            try waitForConfiguration("The app audio tap did not finish connecting.") {
                try self.streams(of: self.aggregateID, scope: kAudioObjectPropertyScopeInput).count > physicalInputs.count
            }


            let inputStreams = try streams(of: aggregateID, scope: kAudioObjectPropertyScopeInput)
            guard physicalInputs.isSubset(of: Set(inputStreams)) else {
                throw EngineFailure("The output changed its input layout while connecting. Try again.")
            }
            let tapStreams = inputStreams.filter { !physicalInputs.contains($0) }
            guard !tapStreams.isEmpty else { throw EngineFailure("The app audio tap did not expose an input stream.") }

            let requiresRateChange = try tapStreams.contains { stream in
                let format = try read(stream, selector: kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
                return abs(format.mSampleRate - sampleRate) >= 1
            }
            if requiresRateChange {
                var rate = sampleRate
                try write(aggregateID, selector: kAudioDevicePropertyNominalSampleRate, value: &rate)
            }
            try waitForConfiguration("The private audio device did not become ready.") {
                try self.read(self.aggregateID, selector: kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0
            }

            // HAL property writes complete before stream formats have propagated.
            // In particular a stereo tap starts at 48 kHz even on a 44.1 kHz output.
            try waitForConfiguration("Core Audio could not synchronize this output's sample rate.") {
                for stream in tapStreams {
                    let format = try self.read(stream, selector: kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
                    if abs(format.mSampleRate - self.sampleRate) >= 1 { return false }
                }
                return true
            }

            var tapChannels: [UInt32] = []
            var inputChannelOffset: UInt32 = 0
            for stream in inputStreams {
                let format = try read(stream, selector: kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
                if !physicalInputs.contains(stream) {
                    _ = try floatFormat(stream)
                    tapChannels += (0..<format.mChannelsPerFrame).map { inputChannelOffset + $0 }
                }
                // IO buffer order follows the aggregate's stream list. A tap's
                // StartingChannel can refer to its source hardware (e.g. 7 on
                // built-in speakers), even when its IO buffer starts at zero.
                inputChannelOffset += format.mChannelsPerFrame
            }
            guard tapChannels.count == 2 else { throw EngineFailure("The app audio tap did not provide stereo audio.") }

            let aggregateOutputs = try streams(of: aggregateID, scope: kAudioObjectPropertyScopeOutput)
            var outputChannelCount: UInt32 = 0
            for stream in aggregateOutputs {
                let format = try floatFormat(stream)
                outputChannelCount += format.mChannelsPerFrame
            }
            guard outputChannelCount > 0 else { throw EngineFailure("The selected output disconnected while connecting.") }
            var stereo: [UInt32] = [1, min(2, outputChannelCount)]
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
                                                      mScope: kAudioObjectPropertyScopeOutput,
                                                      mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<UInt32>.stride * 2)
            let status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &stereo)
            if status != noErr || stereo.contains(where: { $0 == 0 || $0 > outputChannelCount }) {
                stereo = [1, min(2, outputChannelCount)]
            }
            FSAudioDSPConfigure(dsp, tapChannels[0], tapChannels[1], stereo[0] - 1, stereo[1] - 1,
                                outputChannelCount == 1, sampleRate)
            FSAudioDSPSetGain(dsp, gain)
            FSAudioDSPSetBalance(dsp, balance)
            FSAudioDSPSetMuted(dsp, muted)
            try check(AudioDeviceCreateIOProcID(aggregateID, FSAudioDSPIOProc, UnsafeMutableRawPointer(dsp), &ioProc), "Connect audio processor")
            if let ioProc {
                let enabled: [UInt32] = inputStreams.map { physicalInputs.contains($0) ? 0 : 1 }
                try check(FSAudioDSPSelectInputStreams(aggregateID, ioProc, UInt32(enabled.count), enabled), "Select app audio streams")
                try check(AudioDeviceStart(aggregateID, ioProc), "Start app audio (check System Settings → Privacy & Security → Screen & System Audio Recording)")
            } else {
                throw EngineFailure("Core Audio did not create an audio callback.")
            }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    /// Stops reading before destroying the tap, which restores the app's original
    /// audio path. Private devices also disappear if this process exits/crashes.
    func stop() {
        isRunning = false
        if let dsp { FSAudioDSPSetMuted(dsp, true) }
        var errors: [String] = []
        if let ioProc, aggregateID != kAudioObjectUnknown {
            let status = AudioDeviceStop(aggregateID, ioProc)
            if status != noErr { errors.append("Stop audio: \(status)") }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            if destroyStatus == noErr { self.ioProc = nil }
            else { errors.append("Release audio callback: \(destroyStatus)") }
        }
        // Also explicitly remove muting if a driver refused to stop its IOProc.
        if tapID != kAudioObjectUnknown, let tapDescription {
            tapDescription.muteBehavior = .unmuted
            var description = tapDescription
            try? write(tapID, selector: kAudioTapPropertyDescription, value: &description)
        }
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status == noErr { aggregateID = kAudioObjectUnknown; ioProc = nil }
            else { errors.append("Release private route: \(status)") }
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr { tapID = kAudioObjectUnknown; tapDescription = nil }
            else { errors.append("Release app audio tap: \(status)") }
        }
        cleanupError = errors.isEmpty ? nil : errors.joined(separator: ". ")
    }

    private func floatFormat(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription {
        let format = try read(stream, selector: kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0,
              format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame) else {
            throw EngineFailure("This output uses an unsupported audio format. Select a 32-bit float PCM output in Audio MIDI Setup.")
        }
        guard abs(format.mSampleRate - sampleRate) < 1 else {
            throw EngineFailure("Core Audio could not synchronize this output's sample rate. Choose another output.")
        }
        return format
    }

    private func streams(of device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        try objectList(device, selector: kAudioDevicePropertyStreams, scope: scope)
    }

    private func objectList(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Read audio stream list")
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        try values.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!), "Read audio streams")
        }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    private func read<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!), "Read audio format")
        }
        return value
    }

    private func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        let value: Unmanaged<CFString>? = try read(object, selector: selector, initial: Optional<Unmanaged<CFString>>.none)
        guard let value else { throw EngineFailure("Core Audio returned no tap identifier.") }
        return value.takeRetainedValue() as String
    }

    private func write<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try withUnsafeBytes(of: &value) { bytes in
            try check(AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!), "Configure audio route")
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw EngineFailure("\(operation) failed (Core Audio \(status)).") }
    }

    private func waitForConfiguration(_ failure: String, condition: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        repeat {
            if try condition() { return }
            // Aggregate graph updates run asynchronously in HAL. Brief bounded
            // polling avoids starting with a stale graph or pumping a reentrant UI.
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw EngineFailure(failure)
    }
}

private struct EngineFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
