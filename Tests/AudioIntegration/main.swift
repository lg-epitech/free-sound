import CoreAudio
import Foundation

private struct SmokeFailure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Optional live check: capture permission must be granted by the user through
// macOS. This never changes defaults, hardware volume, or taps another app.
private func runCheck() throws {
    let source = Process()
    source.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let sourceOutput = Pipe()
    source.standardOutput = sourceOutput
    try source.run()
    defer {
        if source.isRunning { source.terminate() }
        source.waitUntilExit()
    }
    guard !sourceOutput.fileHandleForReading.availableData.isEmpty else {
        throw SmokeFailure("Synthetic audio source did not start")
    }
    let process = try SystemAudio.processes().first { $0.pid == source.processIdentifier }
    guard let process else { throw SmokeFailure("Synthetic source was not registered in the audio HAL") }
    let defaultID = try SystemAudio.defaultDevice(for: .output)
    let devices = try SystemAudio.devices()
    let useBuiltIn = CommandLine.arguments.contains("--built-in")
    let selectedOutput = useBuiltIn
        ? devices.first { $0.hasOutput && $0.transportType == kAudioDeviceTransportTypeBuiltIn }
        : devices.first { $0.id == defaultID }
    guard let output = selectedOutput else { throw SmokeFailure("The requested output is not available") }
    let engine = ProcessAudioEngine(processIDs: [process.id], outputDeviceID: output.id, outputUID: output.uid)
    engine.setGain(0.5)
    defer {
        engine.stop()
        if let cleanupError = engine.cleanupError { print("CLEANUP ERROR: \(cleanupError)") }
    }
    try engine.start()
    var maximumPeak: Float = 0
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.05)
        maximumPeak = max(maximumPeak, engine.peakLevel)
    }
    print("Source device: \(devices.first(where: { $0.id == defaultID })?.name ?? "default output")")
    print("Routed output: \(output.name), \(engine.sampleRate) Hz")
    print("IO callback received: \(engine.hasReceivedAudio); captured output peak: \(maximumPeak)")
    guard maximumPeak > 0.000001 else {
        throw SmokeFailure("No synthetic signal captured. Grant the test app audio capture permission in macOS, then rerun. Callback success alone is not proof of permission.")
    }
    guard abs(maximumPeak - 0.000005) < 0.0000005 else {
        throw SmokeFailure("The captured synthetic signal did not match half gain")
    }
    engine.setMuted(true)
    Thread.sleep(forTimeInterval: 0.15)
    guard engine.peakLevel < 0.0000001 else {
        throw SmokeFailure("Mute did not silence the routed synthetic source")
    }
    engine.stop()
    if let cleanupError = engine.cleanupError { throw SmokeFailure(cleanupError) }
    guard try SystemAudio.defaultDevice(for: .output) == defaultID else {
        throw SmokeFailure("The default output changed during the check")
    }
    print("PASS: Captured only the synthetic process, applied gain and mute, and released the route cleanly.")
}

do {
    try runCheck()
} catch {
    print("INCOMPLETE: \(error.localizedDescription)")
    exit(2)
}
