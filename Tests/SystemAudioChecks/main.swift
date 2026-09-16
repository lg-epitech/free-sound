import CoreAudio
import Foundation

/// Live HAL smoke checks. This executable only reads device/process properties.
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "SystemAudioChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

do {
    let devices = try SystemAudio.devices()
    try require(Set(devices.map(\.id)).count == devices.count, "Device IDs must be unique.")
    var volumeControls = 0
    var muteControls = 0
    var validSampleRates = 0
    for device in devices {
        try require(device.id != kAudioObjectUnknown, "Discovery returned an unknown device ID.")
        try require(!device.uid.isEmpty && !device.name.isEmpty, "Discovery returned an unnamed device.")
        try require(!device.uid.lowercased().contains("freesound"), "An internal route leaked into device discovery.")
        try require(device.hasInput || device.hasOutput, "A listed device must have audio channels.")
        for input in [false, true] {
            let hasChannels = input ? device.hasInput : device.hasOutput
            if let volume = SystemAudio.volume(of: device.id, input: input) {
                try require(hasChannels, "Volume was exposed for a direction with no channels.")
                try require(volume.isFinite && (0...1).contains(volume), "Hardware volume must be a finite normalized scalar.")
                volumeControls += 1
            }
            if SystemAudio.isMuted(device.id, input: input) != nil {
                try require(hasChannels, "Mute was exposed for a direction with no channels.")
                muteControls += 1
            }
        }
        if let rate = SystemAudio.sampleRate(of: device.id) {
            try require(rate.isFinite && rate > 0, "Nominal sample rate must be positive and finite.")
            validSampleRates += 1
        }
    }

    for role in [SystemAudioRole.output, .input, .soundEffects] {
        _ = try SystemAudio.defaultDevice(for: role)
    }
    let processes = try SystemAudio.processes()
    try require(Set(processes.map(\.id)).count == processes.count, "Process object IDs must be unique.")
    try require(processes.allSatisfy { $0.id != kAudioObjectUnknown && $0.pid > 0 }, "Invalid process identifiers were returned.")
    try require(SystemAudio.volume(of: kAudioObjectUnknown) == nil, "An invalid device must not expose volume.")
    try require(SystemAudio.isMuted(kAudioObjectUnknown) == nil, "An invalid device must not expose mute.")
    try require(SystemAudio.sampleRate(of: kAudioObjectUnknown) == nil, "An invalid device must not expose a sample rate.")
    for _ in 0..<10 {
        _ = try SystemAudio.devices()
        _ = try SystemAudio.processes()
    }
    print("SystemAudio checks passed: \(devices.count) devices, \(processes.count) processes.")
    print("Readable capabilities: \(volumeControls) volume, \(muteControls) mute, \(validSampleRates) sample rates. No settings changed.")
} catch {
    fputs("SystemAudio check failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
