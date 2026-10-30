import Foundation

// The generated bindings live in Generated/syncloom_core.swift (regenerate with syncloom-core/build-apple.sh).

extension FfiNode: Identifiable {
    public var isFolder: Bool { kind == "folder" }
    public var isFile: Bool { kind == "file" }
    public var isNamespace: Bool { kind == "kv" }
    public var modified: Date { Date(timeIntervalSince1970: Double(mtimeMs > 0 ? mtimeMs : updatedAt) / 1000) }
    public var isUploading: Bool { isFile && headVersion == nil }
}

public enum SyncloomError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

extension Swift.Error {
    /// A short sentence for display. UniFFI flattens Rust errors to their message.
    public var friendly: String {
        let text = String(describing: self)
        if let r = text.range(of: "message: \"") { // Server(status:, message:) etc.
            return String(text[r.upperBound...].prefix { $0 != "\"" })
        }
        let ns = (self as NSError).localizedDescription
        return ns.isEmpty ? text : ns
    }
}

/// Runs blocking FFI work off the main actor.
public func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

public func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
