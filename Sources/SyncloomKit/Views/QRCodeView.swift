import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders text as a QR code (used for authenticator setup).
public struct QRCodeView: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        if let cg = Self.render(text) {
            #if os(macOS)
            Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 200, height: 200))).interpolation(.none).resizable().scaledToFit()
            #else
            Image(uiImage: UIImage(cgImage: cg)).interpolation(.none).resizable().scaledToFit()
            #endif
        }
    }

    static func render(_ text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
