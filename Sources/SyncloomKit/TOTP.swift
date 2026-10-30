import CryptoKit
import Foundation

/// RFC 6238 codes (SHA-1, 6 digits, 30 s). Used by tests and the "show current code" helper.
public enum TOTP {
    public static func decodeBase32(_ s: String) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased().filter({ $0 != " " && $0 != "=" }) {
            guard let idx = alphabet.firstIndex(of: ch) else { continue }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }

    public static func code(secret: String, stepOffset: Int = 0, at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / 30) &+ UInt64(bitPattern: Int64(stepOffset))
        var msg = Data()
        for _ in 0..<8 { msg.insert(UInt8(counter & 0xff), at: 0); counter >>= 8 }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: decodeBase32(secret)))
        let h = Array(mac)
        let o = Int(h[19] & 0xf)
        let n = (UInt32(h[o] & 0x7f) << 24) | (UInt32(h[o + 1]) << 16) | (UInt32(h[o + 2]) << 8) | UInt32(h[o + 3])
        return String(format: "%06d", n % 1_000_000)
    }
}
