import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let suite = "FreeSoundTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var preferences = AudioPreferences()
preferences.controlsEnabled = true
preferences.apps["org.test.player"] = AppAudioSettings(volume: 1.6, muted: true, balance: -0.4, outputUID: "headphones", favorite: true, boost: true)
preferences.save(to: defaults)
let loaded = AudioPreferences.load(from: defaults)
expect(loaded.apps == preferences.apps, "Saved app mix, routes, and favorites survive relaunch")
expect(loaded.controlsEnabled, "Saved control state survives relaunch")

var settings = AppAudioSettings(volume: .infinity, balance: .nan)
settings.normalize()
expect(settings.volume == 1 && settings.balance == 0, "Non-finite controls cannot enter audio engine")
settings.volume = 1.8
settings.normalize()
expect(settings.volume == 1, "Boost requires opt-in")
settings.boost = true
settings.volume = 9
settings.balance = -4
settings.normalize()
expect(settings.volume == 2 && settings.balance == -1, "Control limits are enforced")

expect(!AppAudioSettings().needsProcessing, "Unity mix requires no tap")
expect(!AppAudioSettings(favorite: true, boost: true).needsProcessing, "UI preferences alone require no tap")
expect(AppAudioSettings(muted: true).needsProcessing, "Mute requires processing")
expect(AppAudioSettings(outputUID: "speaker").needsProcessing, "Explicit route requires processing")
expect(AppAudioSettings(balance: 0.2).needsProcessing, "Balance requires processing")

defaults.set(Data("broken".utf8), forKey: AudioPreferences.storageKey)
expect(!AudioPreferences.load(from: defaults).controlsEnabled, "Corrupt preferences fall back to disabled controls")
expect(AudioPreferences.load(from: defaults).apps.isEmpty, "Corrupt preferences fall back to an empty mix")
print("PASS: 12 preference and safe-default checks")
