import FileProvider
import UniformTypeIdentifiers

/// A Syncloom node as the system's File Provider sees it.
public final class ProviderItem: NSObject, NSFileProviderItem {
    public let node: FfiNode

    public init(_ node: FfiNode) { self.node = node }

    public var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(node.id) }
    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        node.parentId.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
    }
    public var filename: String { node.name }
    public var contentType: UTType {
        if node.isFolder || node.isNamespace { return .folder }
        return UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
    }
    public var capabilities: NSFileProviderItemCapabilities {
        let writable = node.access != "ro"
        var c: NSFileProviderItemCapabilities = [.allowsReading]
        if node.isFolder { c.insert(.allowsContentEnumerating) }
        if writable {
            c.formUnion([.allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsTrashing])
            if node.isFolder { c.insert(.allowsAddingSubItems) }
        }
        return c
    }
    public var documentSize: NSNumber? { node.isFile ? NSNumber(value: node.size) : nil }
    public var contentModificationDate: Date? { node.modified }
    public var creationDate: Date? { node.modified }
    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data((node.headVersion ?? "none").utf8), metadataVersion: Data(String(node.updatedAt).utf8))
    }
}
