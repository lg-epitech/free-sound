import Foundation

/// A device the user has seen at least once. Kept after it is unplugged so it can keep its place in line.
struct RememberedDevice: Codable, Equatable, Identifiable {
    var uid: String
    var name: String
    var symbol: String

    var id: String { uid }
}

/// An ordered list of devices for one role. The first connected device in the list is the one to use.
struct DevicePriority: Codable, Equatable {
    var devices: [RememberedDevice] = []

    /// Records the devices that are connected right now. Devices seen for the first time go to the
    /// front of the list, with the current system default first, so a newly plugged device is used
    /// until the user decides otherwise. Names and symbols of known devices are refreshed.
    mutating func learn(connected: [RememberedDevice], current: String?) {
        for device in connected {
            if let index = devices.firstIndex(where: { $0.uid == device.uid }) {
                devices[index].name = device.name
                devices[index].symbol = device.symbol
            }
        }
        let known = Set(devices.map(\.uid))
        var fresh = connected.filter { !known.contains($0.uid) }
        guard !fresh.isEmpty else { return }
        fresh.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let current, let index = fresh.firstIndex(where: { $0.uid == current }) {
            fresh.insert(fresh.remove(at: index), at: 0)
        }
        devices.insert(contentsOf: fresh, at: 0)
    }

    /// The device that should be in use given what is connected.
    func preferred(connected: Set<String>) -> String? {
        devices.first { connected.contains($0.uid) }?.uid
    }

    func name(of uid: String) -> String? {
        devices.first { $0.uid == uid }?.name
    }

    /// Same semantics as SwiftUI's `onMove`: `destination` is an index in the list before removal.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.compactMap { devices.indices.contains($0) ? devices[$0] : nil }
        guard !moving.isEmpty else { return }
        let removedBefore = source.filter { $0 < destination }.count
        devices.removeAll { device in moving.contains { $0.uid == device.uid } }
        let target = min(max(destination - removedBefore, 0), devices.count)
        devices.insert(contentsOf: moving, at: target)
    }

    mutating func move(_ uid: String, by offset: Int) {
        guard let index = devices.firstIndex(where: { $0.uid == uid }) else { return }
        let target = min(max(index + offset, 0), devices.count - 1)
        guard target != index else { return }
        devices.insert(devices.remove(at: index), at: target)
    }

    mutating func moveToTop(_ uid: String) {
        guard let index = devices.firstIndex(where: { $0.uid == uid }), index > 0 else { return }
        devices.insert(devices.remove(at: index), at: 0)
    }

    mutating func forget(_ uid: String) {
        devices.removeAll { $0.uid == uid }
    }
}
