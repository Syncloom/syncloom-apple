#if os(macOS)
import ServiceManagement

/// Keeps the app running in the menu bar after login, so changes keep arriving and Finder stays current
/// even when no window is open.
public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
    }

    /// Turned on once, the first time someone signs in. Afterwards the choice in Settings wins.
    static func enableOnce() {
        let key = "world.syncloom.launchAtLoginOffered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }

    /// True when macOS started the app by itself at login (no window wanted).
    public static var launchedAtLogin: Bool {
        let e = NSAppleEventManager.shared().currentAppleEvent
        return e?.eventID == AEEventID(kAEOpenApplication)
            && e?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
#endif
