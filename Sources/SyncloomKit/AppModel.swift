import Foundation
import Observation

/// Sign-in state machine shared by the macOS and iOS apps.
@Observable
@MainActor
public final class AuthFlow {
    public enum Step: Equatable {
        case credentials
        case register
        case mfa(token: String, methods: [String])
        case recoveryKey(String)
        case enroll(token: String)
        case totp(token: String, setup: Setup)
        case codes([String])
    }
    public struct Setup: Equatable { public let id: String; public let secret: String; public let url: String }

    public var step: Step = .credentials
    public var server = ""
    public var username = ""
    public var password = ""
    public var invite = ""
    public var busy = false
    public var error: String?
    public var pendingToken: String?
    private let device: String
    private var recovery: String?

    public init(device: String) {
        self.device = device
        if let s = Credentials.load() { server = s.server; username = s.username }
    }

    private var auth: Authenticator { Authenticator(server: normalizedServer) }
    public var normalizedServer: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty && !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.friendly }
            self.busy = false
        }
    }

    public func signIn(finish: @escaping (SavedSession, Session) -> Void) {
        let (u, p, d, a) = (username.trimmingCharacters(in: .whitespaces), password, device, auth)
        run {
            let outcome = try await offMain { try a.login(username: u, password: p, device: d) }
            try await self.handle(outcome, finish: finish)
        }
    }

    public func register(finish: @escaping (SavedSession, Session) -> Void) {
        let (u, p, inv, d, a) = (username.trimmingCharacters(in: .whitespaces), password, invite, device, auth)
        run {
            let reg = try await offMain { try a.register(username: u, password: p, invite: inv.isEmpty ? nil : inv, device: d) }
            self.recovery = reg.recoveryKey
            self.pendingLogin = reg.login
            self.step = .recoveryKey(reg.recoveryKey)
        }
    }
    private var pendingLogin: FfiLogin?

    /// After the user confirmed they saved the recovery key.
    public func continueAfterRecoveryKey(finish: @escaping (SavedSession, Session) -> Void) {
        guard let login = pendingLogin else { return }
        run { try await self.handle(login, finish: finish) }
    }

    private func handle(_ outcome: FfiLogin, finish: @escaping (SavedSession, Session) -> Void) async throws {
        switch outcome {
        case .ok(let token): try await open(token: token, finish: finish)
        case .mfaRequired(let token, let methods): step = .mfa(token: token, methods: methods)
        case .enrollRequired(let token): step = .enroll(token: token)
        }
    }

    public func verify(method: String, code: String, token: String, finish: @escaping (SavedSession, Session) -> Void) {
        let (d, a) = (device, auth)
        run {
            let t = try await offMain { try a.mfaVerify(mfaToken: token, method: method, code: code, device: d) }
            try await self.open(token: t, finish: finish)
        }
    }

    /// Second step of a login with a hardware security key (opens the system browser).
    public func verifyWithSecurityKey(token: String, finish: @escaping (SavedSession, Session) -> Void) {
        let (server, d) = (normalizedServer, device)
        run {
            let r = try await SecurityKeyBridge.run(server: server, mode: .login, token: token, device: d)
            try await self.open(token: r.token, finish: finish)
        }
    }

    /// Enroll a first security key as the account's second factor.
    public func beginSecurityKey(token: String, name: String) {
        let (server, d) = (normalizedServer, device)
        run {
            let r = try await SecurityKeyBridge.run(server: server, mode: .register, token: token, name: name, device: d)
            self.pendingToken = r.token
            self.step = .codes(r.recoveryCodes)
        }
    }

    public func beginTotp(token: String, name: String) {
        let a = auth
        run {
            let s = try await offMain { try a.totpSetup(token: token, name: name) }
            self.step = .totp(token: token, setup: Setup(id: s.id, secret: s.secret, url: s.otpauthUrl))
        }
    }

    public func confirmTotp(token: String, setup: Setup, code: String, finish: @escaping (SavedSession, Session) -> Void) {
        let (d, a) = (device, auth)
        run {
            let r = try await offMain { try a.totpConfirm(token: token, id: setup.id, code: code, device: d) }
            self.pendingToken = r.token
            self.step = .codes(r.recoveryCodes)
        }
    }

    public func finishAfterCodes(finish: @escaping (SavedSession, Session) -> Void) {
        guard let t = pendingToken else { return }
        run { try await self.open(token: t, finish: finish) }
    }

    private func open(token: String, finish: @escaping (SavedSession, Session) -> Void) async throws {
        let (s, p) = (normalizedServer, password)
        let session = try await offMain { try Session.connect(server: s, token: token, password: p) }
        let secrets = session.exportSecrets()
        let saved = SavedSession(server: s, username: username.lowercased(), token: token, secrets: secrets)
        password = ""
        finish(saved, session)
    }
}

/// The signed-in app state: the session and the folder being browsed.
@Observable
@MainActor
public final class AppModel {
    public var session: Session?
    public var saved: SavedSession?
    public var user: FfiUser?

    private var watcher: Watch?

    public init() {}

    /// Restore a session from the Keychain on launch.
    public func restore() async {
        guard session == nil, let s = Credentials.load() else { return }
        do {
            let sess = try await offMain { try Session.fromSecrets(server: s.server, token: s.token, secrets: s.secrets) }
            user = try? await offMain { try sess.me() }
            session = sess
            saved = s
            watch(sess)
            await FileProviderRegistration.register()
        } catch {
            // being offline must not sign anyone out: only a token the server refuses does
            guard "\(error)".hasPrefix("Auth(") else { return }
            // an expired or revoked token: drop the Finder location with its cache and show the sign-in screen
            await FileProviderRegistration.unregister()
            Credentials.clear()
        }
    }

    public func adopt(_ s: SavedSession, _ sess: Session) {
        Credentials.save(s)
        saved = s
        session = sess
        watch(sess)
        Task { user = try? await offMain { try sess.me() } }
        Task { await FileProviderRegistration.register() }
        #if os(macOS)
        LaunchAtLogin.enableOnce()
        #endif
    }

    public func signOut() {
        watcher?.cancel()
        Task { await FileProviderRegistration.unregister() }
        if let sess = session { Task.detached { try? sess.logout() } }
        Credentials.clear()
        session = nil
        saved = nil
        user = nil
    }

    /// Subscribes to the server's change feed. Every change refreshes the open folders and tells Finder / Files.
    private func watch(_ sess: Session) {
        watcher?.cancel()
        watcher = sess.watch(listener: ChangeRelay())
    }
}

public extension Notification.Name {
    /// Posted (from a background thread) whenever the server reported a change.
    static let syncloomChanged = Notification.Name("world.syncloom.changed")
}

private final class ChangeRelay: ChangeListener, @unchecked Sendable {
    func changed(cursor: Int64) {
        FileProviderRegistration.signalChanged()
        NotificationCenter.default.post(name: .syncloomChanged, object: nil)
    }
}
