import AuthenticationServices
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hardware security keys (YubiKey and other FIDO2 keys) through the system browser.
///
/// Apple's native passkey API ties an app to one domain by an entitlement, which cannot work for a
/// self-hosted server on any domain. Instead the app opens the server's own bridge page
/// (`/native/security-key`) in an `ASWebAuthenticationSession`. Safari does the WebAuthn dance with the
/// key (USB, NFC, Lightning/USB-C) and hands the result back through the `syncloom://` callback.
/// Parameters and results travel in URL fragments, which are never sent to a server.
public enum SecurityKeyBridge {
    public static let scheme = "syncloom"

    public struct Outcome: Equatable, Sendable {
        public let token: String
        public let recoveryCodes: [String]
    }

    public enum Failure: LocalizedError, Equatable {
        case cancelled
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .cancelled: "The security key sign-in was cancelled."
            case .failed(let m): m
            }
        }
    }

    public enum Mode: String { case login, register }

    /// `https://server/native/security-key#mode=…&token=…`
    public static func url(server: String, mode: Mode, token: String, name: String = "", device: String = "") -> URL? {
        var items = [URLQueryItem(name: "mode", value: mode.rawValue), URLQueryItem(name: "token", value: token)]
        if !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        if !device.isEmpty { items.append(URLQueryItem(name: "device", value: device)) }
        var tmp = URLComponents()
        tmp.queryItems = items
        guard var c = URLComponents(string: server + "/native/security-key") else { return nil }
        c.percentEncodedFragment = tmp.percentEncodedQuery
        return c.url
    }

    /// Reads the `syncloom://security-key#token=…&codes=a,b` hand-back.
    public static func parse(callback: URL) throws -> Outcome {
        guard callback.scheme == scheme, let fragment = callback.fragment else { throw Failure.failed("Unexpected response from the security key page.") }
        var tmp = URLComponents()
        tmp.percentEncodedQuery = fragment
        let values = Dictionary((tmp.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let e = values["error"] { throw e == "cancelled" ? Failure.cancelled : Failure.failed(e) }
        guard let token = values["token"], !token.isEmpty else { throw Failure.failed("The security key page returned no session.") }
        let codes = (values["codes"] ?? "").split(separator: ",").map(String.init)
        return Outcome(token: token, recoveryCodes: codes)
    }

    /// Opens the bridge page and waits for the hand-back.
    @MainActor
    public static func run(server: String, mode: Mode, token: String, name: String = "", device: String = "") async throws -> Outcome {
        guard let url = url(server: server, mode: mode, token: token, name: name, device: device) else { throw Failure.failed("The server address is not valid.") }
        let anchor = Anchor()
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { cont.resume(returning: callback); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: Failure.cancelled) }
                else { cont.resume(throwing: Failure.failed(error?.localizedDescription ?? "The security key sign-in failed.")) }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = true // no stored Safari cookies, no leftovers
            current = session
            if !session.start() { cont.resume(throwing: Failure.failed("The system could not open the security key sign-in.")) }
        }
        current = nil
        return try parse(callback: callback)
    }

    @MainActor private static var current: ASWebAuthenticationSession?

    @MainActor
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
