import XCTest
@testable import SyncloomKit

/// Runs against a real, freshly started server (the first registered user becomes admin):
///   cd syncloom-deploy && docker compose -f docker-compose.yml -f docker-compose.test.yml down -v && ... up -d
///   SYNCLOOM_TEST_URL=http://localhost:8088 swift test
final class SessionTests: XCTestCase {
    var server: String { ProcessInfo.processInfo.environment["SYNCLOOM_TEST_URL"] ?? "http://localhost:8088" }

    /// AppModel.restore signs out only when the server refuses the token (an `Auth` error).
    func testUnknownTokenIsRefusedAsAuthError() throws {
        XCTAssertThrowsError(try Session.fromSecrets(server: server, token: "not-a-real-token", secrets: Data(repeating: 7, count: 64))) { XCTAssertTrue("\($0)".hasPrefix("Auth("), "\($0)") }
    }

    func testFullRoundTripThroughTheUniFFIBindings() throws {
        let auth = Authenticator(server: server)
        let user = "swift\(Int.random(in: 1000...9999))"
        let password = "correct horse battery staple"

        // register -> a second factor is mandatory before any access
        let reg: FfiRegistration
        do { reg = try auth.register(username: user, password: password, invite: nil, device: "swift-test") }
        catch { return XCTFail("registration failed (is the stack fresh?): \(error)") }
        XCTAssertEqual(reg.recoveryKey.count, 71)
        guard case .enrollRequired(let enrollToken) = reg.login else { return XCTFail("expected enrollment, got \(reg.login)") }

        let setup = try auth.totpSetup(token: enrollToken, name: "test authenticator")
        let confirm = try auth.totpConfirm(token: enrollToken, id: setup.id, code: TOTP.code(secret: setup.secret), device: "swift-test")
        XCTAssertEqual(confirm.recoveryCodes.count, 10)

        let s = try Session.connect(server: server, token: confirm.token, password: password)
        XCTAssertEqual(try s.me().username, user)

        // live updates: a change must reach the listener within 1 s. The polling fallback needs 3 s, so this proves streaming.
        let recorder = Recorder()
        let watch = s.watch(listener: recorder)
        defer { watch.cancel() }
        Thread.sleep(forTimeInterval: 1.5) // let the stream open

        // encrypted files
        let folder = try s.createFolder(parent: nil, name: "Docs")
        XCTAssertEqual(recorder.seen.wait(timeout: .now() + 1), .success, "the change was not pushed within 1 s")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("big.bin")
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 7)) })
        try payload.write(to: src)
        let file = try s.uploadNewFile(parent: folder.id, name: "big.bin", path: src.path, mtimeMs: 1_700_000_000_000, executable: false)
        XCTAssertEqual(file.size, Int64(payload.count))
        XCTAssertEqual(try s.list(parent: folder.id).map(\.name), ["big.bin"])
        let out = dir.appendingPathComponent("out/copy.bin")
        try s.downloadFile(id: file.id, version: nil, dest: out.path)
        XCTAssertEqual(try Data(contentsOf: out), payload)

        // a new version, with history
        let edited = dir.appendingPathComponent("v2.bin")
        try Data("version two".utf8).write(to: edited)
        let v2 = try s.uploadVersion(id: file.id, baseVersion: file.headVersion, path: edited.path, mtimeMs: 1_700_000_100_000)
        XCTAssertNotEqual(v2.headVersion, file.headVersion)
        XCTAssertEqual(try s.versions(id: file.id).count, 2)
        // a stale base is refused instead of overwriting
        XCTAssertThrowsError(try s.uploadVersion(id: file.id, baseVersion: file.headVersion, path: edited.path, mtimeMs: 0))

        // rename, move, trash, restore
        _ = try s.rename(id: file.id, name: "renamed.bin")
        XCTAssertEqual(try s.get(id: file.id).name, "renamed.bin")
        try s.trash(id: file.id)
        XCTAssertEqual(try s.trashList().map(\.name), ["renamed.bin"])
        _ = try s.restore(id: file.id)

        // key/value with compare-and-set
        let ns = try s.kvCreateNamespace(name: "settings")
        XCTAssertEqual(try s.kvPut(ns: ns.id, key: "theme", value: Data("dark".utf8), ifVersion: nil), 1)
        XCTAssertThrowsError(try s.kvPut(ns: ns.id, key: "theme", value: Data("x".utf8), ifVersion: 0))
        XCTAssertEqual(try s.kvGet(ns: ns.id, key: "theme")?.value, Data("dark".utf8))

        try checkFolderDrop(s)

        // public links keep the key in the fragment
        let link = try s.createLink(id: folder.id, password: nil, expiresAtMs: nil, maxDownloads: nil)
        XCTAssertTrue(link.url.contains("/s/") && link.url.contains("#k="))

        // change feed
        let head = try s.changesHead()
        XCTAssertGreaterThan(head, 0)
        _ = try s.createFolder(parent: nil, name: "later")
        XCTAssertFalse(try s.changes(since: head, limit: 100).changes.isEmpty)

        // keychain round trip: the secrets restore an equivalent session without the password
        let restored = try Session.fromSecrets(server: server, token: confirm.token, secrets: s.exportSecrets())
        XCTAssertEqual(try restored.get(id: folder.id).name, "Docs")

        // a second authenticator, then sign in again with any one of them
        let second = try s.addTotp(name: "second")
        try s.confirmTotp(id: second.id, code: TOTP.code(secret: second.secret))
        XCTAssertEqual(try s.mfaMethods().count, 2)
        guard case .mfaRequired(let mfaToken, let methods) = try auth.login(username: user, password: password, device: "again") else { return XCTFail("expected an MFA step") }
        XCTAssertTrue(methods.contains("totp"))
        let t = try auth.mfaVerify(mfaToken: mfaToken, method: "totp", code: TOTP.code(secret: setup.secret, stepOffset: 1), device: "again")
        XCTAssertEqual(try Session.connect(server: server, token: t, password: password).get(id: folder.id).name, "Docs")

        // wrong password never unlocks the vault
        XCTAssertThrowsError(try Session.connect(server: server, token: t, password: "nope"))
    }


    /// Dropping a folder on the Mac app uploads the whole tree (the same code the drop handler runs).
    private func checkFolderDrop(_ s: Session) throws {
        let dest = try s.createFolder(parent: nil, name: "Drops").id
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Project")
        try fm.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("top".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("code".utf8).write(to: root.appendingPathComponent("src/main.rs"))
        try Data("deep".utf8).write(to: root.appendingPathComponent("src/deep/x.txt"))
        try Data("junk".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("README.md"))

        var failed: [String] = []
        uploadItem(s, parent: dest, url: root, failed: &failed)
        XCTAssertEqual(failed, [])
        let top = try s.list(parent: dest)
        XCTAssertEqual(top.map(\.name), ["Project"])
        let project = try s.list(parent: top[0].id)
        XCTAssertEqual(Set(project.map(\.name)), ["README.md", "src", "empty"], "ignores .DS_Store and the symlink, keeps empty folders")
        let srcId = project.first { $0.name == "src" }!.id
        XCTAssertEqual(Set(try s.list(parent: srcId).map(\.name)), ["main.rs", "deep"])

        // the same folder dropped again merges into the existing one instead of failing or duplicating it
        try Data("new".utf8).write(to: root.appendingPathComponent("src/new.txt"))
        uploadItem(s, parent: dest, url: root, failed: &failed)
        XCTAssertEqual(try s.list(parent: dest).count, 1)
        XCTAssertTrue(try s.list(parent: srcId).contains { $0.name == "new.txt" })
    }

    func testTOTPMatchesRFC6238() {
        // RFC 6238 test secret "12345678901234567890" (base32 GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ), T = 59 s
        XCTAssertEqual(TOTP.code(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", at: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(TOTP.code(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", at: Date(timeIntervalSince1970: 1111111109)), "081804")
    }
}

private final class Recorder: ChangeListener, @unchecked Sendable {
    let seen = DispatchSemaphore(value: 0)
    func changed(cursor: Int64) { seen.signal() }
}

