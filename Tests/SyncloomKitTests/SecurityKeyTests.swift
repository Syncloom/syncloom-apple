import XCTest
@testable import SyncloomKit

final class SecurityKeyTests: XCTestCase {
    func testBridgeURLKeepsSecretsInTheFragment() throws {
        let url = try XCTUnwrap(SecurityKeyBridge.url(server: "https://sync.example.com", mode: .login, token: "a+b/c=", device: "Sven’s Mac"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.path, "/native/security-key")
        XCTAssertNil(url.query, "nothing may be sent to the server")
        let frag = try XCTUnwrap(url.fragment)
        var c = URLComponents(); c.percentEncodedQuery = frag
        let v = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(v["mode"], "login")
        XCTAssertEqual(v["token"], "a+b/c=")
        XCTAssertEqual(v["device"], "Sven’s Mac")
    }

    func testParsesSuccessWithRecoveryCodes() throws {
        let r = try SecurityKeyBridge.parse(callback: URL(string: "syncloom://security-key#token=abc&codes=aaaa-bbbb%2Ccccc-dddd")!)
        XCTAssertEqual(r.token, "abc")
        XCTAssertEqual(r.recoveryCodes, ["aaaa-bbbb", "cccc-dddd"])
    }

    func testParsesCancelAndErrors() {
        XCTAssertThrowsError(try SecurityKeyBridge.parse(callback: URL(string: "syncloom://security-key#error=cancelled")!)) {
            XCTAssertEqual($0 as? SecurityKeyBridge.Failure, .cancelled)
        }
        XCTAssertThrowsError(try SecurityKeyBridge.parse(callback: URL(string: "syncloom://security-key#error=boom")!)) {
            XCTAssertEqual($0 as? SecurityKeyBridge.Failure, .failed("boom"))
        }
        XCTAssertThrowsError(try SecurityKeyBridge.parse(callback: URL(string: "https://evil.example/#token=x")!))
        XCTAssertThrowsError(try SecurityKeyBridge.parse(callback: URL(string: "syncloom://security-key")!))
    }
}
