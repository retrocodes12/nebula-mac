import Foundation
import NebulaCore

/// The profile PIN (10-23; brief `pin-2026-10-23.md`). The stored state lives in AppModel (`unlocked`, `pinWrong`,
/// `pinHoldUntil`); the PIN screen is `Views/WhoPin.swift`.
extension AppModel {
    func needsPin(_ id: String) -> Bool {
        guard let v = viewerList.first(where: { $0.id == id }), v.locked else { return false }
        return !unlocked.contains(id)
    }
    /// The profile this device is on — or the first, while a removed second profile's switch is still under way.
    var viewerOn: String { viewerList.contains { $0.id == viewerId } ? viewerId : "a" }
    /// The right PIN for a locked profile.
    func pinRight(_ id: String) { unlocked.insert(id); pinWrong = 0 }
    /// Add/Change: saved at once (stamped, synced); the profile counts as unlocked.
    func setPin(_ id: String, pin: String) {
        guard let lock = PinLock.make(pin: pin) else { return }
        viewers.setList(viewerList.map { $0.id == id ? Viewer(id: $0.id, name: $0.name, av: $0.av, lock: lock) : $0 })
        Task { await cloud.noteChanged("viewers") }
        unlocked.insert(id)
        refreshViewers()
        if let v = viewerList.first(where: { $0.id == id }) { say("PIN set for \(viewerName(v)).") }
    }
    /// Remove PIN (the editor), or Forgot PIN? once the account's password was right.
    func removePin(_ id: String, forgot: Bool = false) {
        viewers.setList(viewerList.map { $0.id == id ? Viewer(id: $0.id, name: $0.name, av: $0.av) : $0 })
        Task { await cloud.noteChanged("viewers") }
        unlocked.insert(id)
        pinWrong = 0
        refreshViewers()
        say(forgot ? "PIN removed — add a new one from Manage Profiles." : "PIN removed.")
    }
    /// Forgot PIN? needs this device signed in to an account with a password (a profile).
    var canResetPin: Bool { profile != nil }
    func checkAccountPassword(_ password: String) async -> String? { await cloud.checkPassword(password) }
}
