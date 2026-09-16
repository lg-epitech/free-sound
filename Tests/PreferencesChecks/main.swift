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

// Preferences written before device priorities existed must keep their app mix.
let legacy = Data(#"{"apps":{"org.test.legacy":{"volume":0.5,"muted":false,"balance":0,"favorite":true,"boost":false}},"controlsEnabled":true,"pinned":true,"onlyFavorites":false}"#.utf8)
defaults.set(legacy, forKey: AudioPreferences.storageKey)
let migrated = AudioPreferences.load(from: defaults)
expect(migrated.apps["org.test.legacy"]?.volume == 0.5 && migrated.pinned, "Older preferences load without device priorities")
expect(migrated.outputPriority.devices.isEmpty && migrated.inputPriority.devices.isEmpty, "Missing priorities start empty")

// Device priority: first learn puts the current default first, then the rest by name.
let speakers = RememberedDevice(uid: "speakers", name: "MacBook Pro Speakers", symbol: "speaker.wave.2.fill")
let headphones = RememberedDevice(uid: "headphones", name: "WH-1000XM4", symbol: "headphones")
let display = RememberedDevice(uid: "display", name: "Studio Display", symbol: "display")
var priority = DevicePriority()
priority.learn(connected: [headphones, speakers, display], current: "speakers")
expect(priority.devices.map(\.uid) == ["speakers", "display", "headphones"], "First learn starts with the current default, then by name")
expect(priority.preferred(connected: ["speakers", "display", "headphones"]) == "speakers", "Preferred device is the first connected one")

// Unplugging keeps the device in line and falls through to the next connected one.
expect(priority.preferred(connected: ["display", "headphones"]) == "display", "Unplugged device falls through to the next in line")
expect(priority.devices.count == 3, "Unplugged devices are remembered")
priority.learn(connected: [display, headphones], current: "display")
expect(priority.devices.map(\.uid) == ["speakers", "display", "headphones"], "Learning connected devices does not reorder known ones")

// A never-seen device goes to the front so it is used until the user says otherwise.
let usb = RememberedDevice(uid: "usb", name: "USB Audio", symbol: "hifispeaker.fill")
priority.learn(connected: [display, headphones, usb], current: "usb")
expect(priority.devices.first?.uid == "usb", "A new device is preferred immediately")
expect(priority.preferred(connected: ["speakers", "usb"]) == "usb", "New device outranks older ones")

// Names refresh; reordering and forgetting work by identity.
priority.learn(connected: [RememberedDevice(uid: "usb", name: "USB Audio Interface", symbol: "hifispeaker.fill")], current: nil)
expect(priority.name(of: "usb") == "USB Audio Interface", "Known device names refresh")
priority.moveToTop("headphones")
expect(priority.devices.first?.uid == "headphones", "Move to top")
priority.move("headphones", by: 1)
expect(priority.devices.map(\.uid) == ["usb", "headphones", "speakers", "display"], "Move down by one")
priority.move("display", by: 5)
expect(priority.devices.last?.uid == "display", "Moving past the end clamps")
priority.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
expect(priority.devices.map(\.uid) == ["display", "usb", "headphones", "speakers"], "Drag to the top uses collection offsets")
priority.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
expect(priority.devices.map(\.uid) == ["usb", "headphones", "speakers", "display"], "Drag to the end")
priority.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
expect(priority.devices.map(\.uid) == ["headphones", "usb", "speakers", "display"], "Drag down one place")
priority.forget("speakers")
expect(priority.devices.map(\.uid) == ["headphones", "usb", "display"], "Forgetting removes a device")
expect(priority.preferred(connected: []) == nil, "No connected device means no preference")

var stored = AudioPreferences()
stored.outputPriority = priority
stored.save(to: defaults)
expect(AudioPreferences.load(from: defaults).outputPriority == priority, "Device priorities survive relaunch")
print("PASS: 31 preference, priority, and safe-default checks")
