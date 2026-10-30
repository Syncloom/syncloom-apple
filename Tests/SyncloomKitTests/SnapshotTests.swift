import SwiftUI
import XCTest
@testable import SyncloomKit

#if os(macOS)
/// Renders views off-screen (an unshown window) to PNGs in SYNCLOOM_SNAPSHOT_DIR so the design can be reviewed
/// without touching the user's display.
@MainActor
final class SnapshotTests: XCTestCase {
    func render<V: View>(_ view: V, _ name: String, size: CGSize, dark: Bool = false) throws {
        let dir = ProcessInfo.processInfo.environment["SYNCLOOM_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6)) // let SwiftUI settle
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testRenderSignInScreen() throws {
        try render(AuthView(device: "Test Mac") { _, _ in }, "auth-sign-in", size: CGSize(width: 560, height: 640))
        try render(AuthView(device: "Test Mac") { _, _ in }, "auth-sign-in-dark", size: CGSize(width: 560, height: 640), dark: true)
    }
}
#endif
