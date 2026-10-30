import SwiftUI

/// Sign-in, registration, second factor and enrolment, in one native flow.
public struct AuthView: View {
    @State private var flow: AuthFlow
    private let finish: (SavedSession, Session) -> Void
    @State private var code = ""
    @State private var method = "totp"
    @State private var ack = false
    @State private var deviceLabel = ""

    public init(device: String, finish: @escaping (SavedSession, Session) -> Void) {
        _flow = State(initialValue: AuthFlow(device: device))
        self.finish = finish
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                BrandMark(size: 72).shadow(color: .indigo.opacity(0.35), radius: 14, y: 6)
                Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
                content
                if let e = flow.error { Text(e).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).accessibilityIdentifier("error") }
            }
            .padding(30)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .disabled(flow.busy)
        .overlay { if flow.busy { ProgressView().controlSize(.large).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
    }

    private var title: String {
        switch flow.step {
        case .credentials: "Welcome back"
        case .register: "Create your account"
        case .mfa: "Verify it’s you"
        case .recoveryKey: "Save your recovery key"
        case .enroll: "Add a second factor"
        case .totp: "Set up your authenticator"
        case .codes: "You are protected"
        }
    }

    private var subtitle: String {
        switch flow.step {
        case .credentials: "Sign in to your encrypted storage."
        case .register: "Your files are encrypted on this device before they leave it."
        case .mfa: "Use any one of your second factors."
        case .recoveryKey: "If you forget your password, this key is the only way to get your files back."
        case .enroll: "Every sign-in needs your password and a second factor. You can add more later."
        case .totp: "Scan the code with your authenticator app, then enter the 6 digits."
        case .codes: "Keep these one-time recovery codes in case you lose your devices."
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .credentials, .register: credentials
        case .mfa(let token, let methods): mfa(token, methods)
        case .recoveryKey(let key): recoveryKey(key)
        case .enroll(let token): enroll(token)
        case .totp(let token, let setup): totp(token, setup)
        case .codes(let codes): codesView(codes)
        }
    }

    private var credentials: some View {
        let registering = flow.step == .register
        return VStack(spacing: 14) {
            TextField("Server", text: $flow.server, prompt: Text("sync.example.com"))
                .textContentType(.URL).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
            TextField("Username", text: $flow.username)
                .textContentType(.username).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("Password", text: $flow.password).textContentType(registering ? .newPassword : .password)
            if registering { TextField("Invite code", text: $flow.invite).autocorrectionDisabled() }
            Button(registering ? "Create account" : "Sign in") { registering ? flow.register(finish: finish) : flow.signIn(finish: finish) }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(flow.server.isEmpty || flow.username.isEmpty || flow.password.isEmpty)
            Button(registering ? "I already have an account" : "Create an account with an invite") { flow.step = registering ? .credentials : .register }
                .linkButton()
        }
        .textFieldStyle(.roundedBorder)
    }

    private func mfa(_ token: String, _ methods: [String]) -> some View {
        VStack(spacing: 14) {
            Picker("Method", selection: $method) {
                if methods.contains("totp") { Text("App").tag("totp") }
                if methods.contains("webauthn") { Text("Security key").tag("key") }
                Text("Recovery code").tag("recovery")
            }.pickerStyle(.segmented).labelsHidden()
            if method == "key" {
                Text("Insert or tap your key. Syncloom opens a secure sign-in window for it.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { flow.verifyWithSecurityKey(token: token, finish: finish) } label: { Label("Use security key", systemImage: "key.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                TextField(method == "totp" ? "6-digit code" : "xxxx-xxxx-xxxx", text: $code)
                    .textFieldStyle(.roundedBorder).font(.system(.title2, design: .monospaced)).multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(method == "totp" ? .numberPad : .asciiCapable).textInputAutocapitalization(.never)
                    #endif
                    .textContentType(.oneTimeCode)
                    .onChange(of: code) { _, v in if method == "totp", v.filter(\.isNumber).count == 6 { flow.verify(method: method, code: v.filter(\.isNumber), token: token, finish: finish) } }
                Button("Verify") { flow.verify(method: method, code: code.trimmingCharacters(in: .whitespaces), token: token, finish: finish) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(code.isEmpty)
            }
            Button("Use a different account") { flow.step = .credentials; code = "" }.linkButton()
        }
        .onAppear { method = methods.contains("totp") ? "totp" : methods.contains("webauthn") ? "key" : "recovery" }
    }

    private func recoveryKey(_ key: String) -> some View {
        VStack(spacing: 14) {
            Text(key.chunked(17)).font(.system(.body, design: .monospaced)).multilineTextAlignment(.center).textSelection(.enabled)
                .padding().frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Button("Copy") { copyToPasteboard(key) }.buttonStyle(.bordered)
            Toggle("I have stored it somewhere safe", isOn: $ack)
            Button("Continue") { flow.continueAfterRecoveryKey(finish: finish) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!ack)
        }
    }

    private func enroll(_ token: String) -> some View {
        VStack(spacing: 14) {
            TextField("Name (optional)", text: $deviceLabel).textFieldStyle(.roundedBorder)
            Button { flow.beginTotp(token: token, name: deviceLabel.isEmpty ? "Authenticator app" : deviceLabel) } label: {
                Label("Authenticator app", systemImage: "clock.badge.checkmark").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Button { flow.beginSecurityKey(token: token, name: deviceLabel.isEmpty ? "Security key" : deviceLabel) } label: {
                Label("Security key (YubiKey, …)", systemImage: "key.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large)
            Text("Add more second factors later in Settings. Any one of them signs you in.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func totp(_ token: String, _ setup: AuthFlow.Setup) -> some View {
        VStack(spacing: 14) {
            QRCodeView(setup.url).frame(width: 190, height: 190).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
            Text(setup.secret.chunked(4, separator: " ")).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            TextField("6-digit code", text: $code).textFieldStyle(.roundedBorder).font(.system(.title2, design: .monospaced)).multilineTextAlignment(.center)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Verify and continue") { flow.confirmTotp(token: token, setup: setup, code: code.filter(\.isNumber), finish: finish) }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(code.filter(\.isNumber).count < 6)
        }
    }

    private func codesView(_ codes: [String]) -> some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(codes, id: \.self) { Text($0).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
            }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Button("Copy all") { copyToPasteboard(codes.joined(separator: "\n")) }.buttonStyle(.bordered)
            Button("Open my files") { flow.finishAfterCodes(finish: finish) }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

extension String {
    func chunked(_ n: Int, separator: Character = "\n") -> String {
        var out = "", i = 0
        for ch in self { if i > 0 && i % n == 0 { out.append(separator) }; out.append(ch); i += 1 }
        return out
    }
}

func copyToPasteboard(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}

extension View {
    /// A text-only button in the platform's idiom (`.link` exists only on macOS).
    @ViewBuilder func linkButton() -> some View {
        #if os(macOS)
        self.buttonStyle(.link)
        #else
        self.buttonStyle(.plain).foregroundStyle(.tint)
        #endif
    }
}
