import SwiftUI

private struct SetupItem: Identifiable { let setup: FfiTotpSetup; var id: String { setup.id } }
private struct CodesItem: Identifiable { let codes: [String]; var id: String { codes.joined() } }

public struct SettingsView: View {
    @Bindable var model: AppModel
    let session: Session
    @State private var methods: [FfiMfaMethod] = []
    @State private var setup: SetupItem?
    @State private var codes: CodesItem?
    @State private var error: String?
    @State private var confirmSignOut = false
    #if os(macOS)
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    #endif

    public init(model: AppModel, session: Session) { self.model = model; self.session = session }

    public var body: some View {
        Form {
            accountSection
            #if os(macOS)
            Section {
                Toggle("Open Syncloom at login", isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
            } footer: {
                Text("Keeps Syncloom in the menu bar so Finder stays up to date even when its window is closed.")
            }
            #endif
            securitySection
            Section { Button("Sign out", role: .destructive) { confirmSignOut = true } }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await load() }
        .sheet(item: $setup) { item in AddAuthenticatorSheet(setup: item.setup) { code in await confirm(item.setup, code) } onCancel: { setup = nil } }
        .sheet(item: $codes) { item in RecoveryCodesSheet(codes: item.codes) { codes = nil } }
        .confirmationDialog("Sign out of Syncloom?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { model.signOut() }
        } message: { Text("You will need your password and a second factor to sign in again.") }
        .alert("Something went wrong", isPresented: errorBinding) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private var errorBinding: Binding<Bool> { Binding(get: { error != nil }, set: { if !$0 { error = nil } }) }

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Server", value: model.saved?.server ?? "")
            LabeledContent("User", value: model.user?.username ?? model.saved?.username ?? "")
            if let u = model.user { LabeledContent("Storage", value: storage(u)) }
        }
    }

    private func storage(_ u: FfiUser) -> String {
        let quota = u.quotaBytes.map { " of \(formatBytes($0))" } ?? ""
        return formatBytes(u.usedBytes) + quota
    }

    private var securitySection: some View {
        Section {
            ForEach(methods, id: \.id) { m in methodRow(m) }
            Button { Task { await beginAdd() } } label: { Label("Add authenticator app", systemImage: "plus") }
            Button { Task { await addSecurityKey() } } label: { Label("Add security key", systemImage: "key.fill") }
            Button { Task { await newCodes() } } label: { Label("New recovery codes", systemImage: "arrow.clockwise") }
        } header: {
            Text("Two-step verification")
        } footer: {
            Text("Add as many as you like, such as two YubiKeys. Any one of them signs you in.")
        }
    }

    private func methodRow(_ m: FfiMfaMethod) -> some View {
        HStack {
            Label(m.name, systemImage: m.kind == "webauthn" ? "key.fill" : "clock")
            Spacer()
            Text(m.kind == "webauthn" ? "Security key" : "Authenticator").font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu { Button("Remove", role: .destructive) { Task { await remove(m) } }.disabled(methods.count <= 1) }
    }

    private func load() async { methods = (try? await offMain { try session.mfaMethods() }) ?? [] }
    private func beginAdd() async {
        do { let s = try await offMain { try session.addTotp(name: "Authenticator app") }; setup = SetupItem(setup: s) } catch { self.error = error.friendly }
    }
    private func confirm(_ s: FfiTotpSetup, _ code: String) async {
        do { try await offMain { try session.confirmTotp(id: s.id, code: code) }; setup = nil; await load() } catch { self.error = error.friendly }
    }
    private func addSecurityKey() async {
        guard let saved = model.saved else { return }
        do {
            _ = try await SecurityKeyBridge.run(server: saved.server, mode: .register, token: saved.token, name: "Security key")
            await load()
        } catch SecurityKeyBridge.Failure.cancelled {
        } catch { self.error = error.friendly }
    }
    private func remove(_ m: FfiMfaMethod) async {
        do { try await offMain { try session.removeMfa(id: m.id) }; await load() } catch { self.error = error.friendly }
    }
    private func newCodes() async {
        do { codes = CodesItem(codes: try await offMain { try session.newRecoveryCodes() }) } catch { self.error = error.friendly }
    }
}

private struct AddAuthenticatorSheet: View {
    let setup: FfiTotpSetup
    let onConfirm: (String) async -> Void
    let onCancel: () -> Void
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add authenticator").font(.title2.bold())
            QRCodeView(setup.otpauthUrl).frame(width: 190, height: 190).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
            Text(setup.secret.chunked(4, separator: " ")).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            TextField("6-digit code", text: $code).textFieldStyle(.roundedBorder).multilineTextAlignment(.center).frame(maxWidth: 220)
            HStack {
                Button("Cancel", action: onCancel)
                Button("Add") { Task { await onConfirm(code.filter(\.isNumber)) } }.buttonStyle(.borderedProminent).disabled(code.filter(\.isNumber).count < 6)
            }
        }
        .padding(28).frame(minWidth: 320)
    }
}

private struct RecoveryCodesSheet: View {
    let codes: [String]
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Recovery codes").font(.title2.bold())
            Text("Each works once. Store them like a password.").foregroundStyle(.secondary)
            ForEach(codes, id: \.self) { Text($0).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            Button("Copy all") { copyToPasteboard(codes.joined(separator: "\n")) }
            Button("Done", action: onDone).buttonStyle(.borderedProminent)
        }
        .padding(28)
    }
}

/// The app's root: sign in until a session exists.
public struct RootView: View {
    @State private var model: AppModel
    private let device: String
    /// Pass the app-level model so the live connection survives closing the window.
    public init(device: String, model: AppModel? = nil) { self.device = device; _model = State(initialValue: model ?? AppModel()) }

    public var body: some View {
        Group {
            if model.session != nil { MainView(model: model) }
            else { AuthView(device: device) { saved, session in model.adopt(saved, session) } }
        }
        .task { await model.restore() }
    }
}
