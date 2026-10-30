import FileProvider
import Foundation

/// Files On-Demand: the base class of the File Provider extensions on macOS and iOS.
/// Subclass it in the extension target (`final class FileProviderExtension: SyncloomProviderExtension {}`).
/// The unlocked vault is read from the shared Keychain item that the app saved at sign-in.
open class SyncloomProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    public let domain: NSFileProviderDomain

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    public func invalidate() {}

    private func session() throws -> Session {
        guard let s = Credentials.load() else { throw NSFileProviderError(.notAuthenticated) }
        do { return try Session.fromSecrets(server: s.server, token: s.token, secrets: s.secrets) } catch { throw NSFileProviderError(.notAuthenticated) }
    }

    /// Runs `work` off the calling thread and maps any failure to a File Provider error.
    private func async(_ work: @escaping () throws -> Void, fail: @escaping (Swift.Error) -> Void) -> Progress {
        async(1, work, fail: fail)
    }

    private func async(_ total: Int64, _ work: @escaping () throws -> Void, fail: @escaping (Swift.Error) -> Void) -> Progress {
        let p = Progress(totalUnitCount: total)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try work() } catch { fail(Self.map(error)) }
            p.completedUnitCount = total
        }
        return p
    }

    static func map(_ e: Swift.Error) -> Swift.Error {
        if e is NSFileProviderError { return e }
        let text = String(describing: e)
        if text.contains("NotFound") || text.contains("not found") { return NSFileProviderError(.noSuchItem) }
        if text.contains("Auth") { return NSFileProviderError(.notAuthenticated) }
        if text.contains("Conflict") { return NSFileProviderError(.cannotSynchronize) }
        return NSFileProviderError(.serverUnreachable)
    }

    private func nodeId(_ id: NSFileProviderItemIdentifier) -> String? {
        id == .rootContainer ? nil : id.rawValue
    }

    // MARK: items

    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Swift.Error?) -> Void) -> Progress {
        async({
            if identifier == .rootContainer { return completionHandler(RootItem(), nil) }
            let node = try self.session().get(id: identifier.rawValue)
            completionHandler(ProviderItem(node), nil)
        }, fail: { completionHandler(nil, $0) })
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Swift.Error?) -> Void) -> Progress {
        async(100, {
            let s = try self.session()
            let node = try s.get(id: itemIdentifier.rawValue)
            let dir = try NSFileProviderManager(for: self.domain)?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
            let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathComponent(node.name)
            try s.downloadFile(id: node.id, version: nil, dest: dest.path)
            completionHandler(dest, ProviderItem(node), nil)
        }, fail: { completionHandler(nil, nil, $0) })
    }

    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Swift.Error?) -> Void) -> Progress {
        let parent = nodeId(itemTemplate.parentItemIdentifier)
        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        let mtime = Int64((itemTemplate.contentModificationDate??.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000)
        return async(100, {
            let s = try self.session()
            let node: FfiNode
            if isFolder {
                node = try s.createFolder(parent: parent, name: name)
            } else if let url {
                node = try s.uploadNewFile(parent: parent, name: name, path: url.path, mtimeMs: mtime, executable: false)
            } else {
                // an empty file
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: tmp) }
                node = try s.uploadNewFile(parent: parent, name: name, path: tmp.path, mtimeMs: mtime, executable: false)
            }
            completionHandler(ProviderItem(node), [], false, nil)
        }, fail: { completionHandler(nil, [], false, $0) })
    }

    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Swift.Error?) -> Void) -> Progress {
        let id = item.itemIdentifier.rawValue
        let newName = item.filename
        let newParent = nodeId(item.parentItemIdentifier)
        let base = String(data: version.contentVersion, encoding: .utf8)
        let mtime = Int64((item.contentModificationDate??.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000)
        return async(100, {
            let s = try self.session()
            var node = try s.get(id: id)
            if changedFields.contains(.parentItemIdentifier) { node = try s.moveTo(id: id, newParent: newParent) }
            if changedFields.contains(.filename) { node = try s.rename(id: id, name: newName) }
            if changedFields.contains(.contents), let url = newContents {
                node = try s.uploadVersion(id: id, baseVersion: base == "none" ? nil : base, path: url.path, mtimeMs: mtime)
            }
            completionHandler(ProviderItem(node), [], false, nil)
        }, fail: { completionHandler(nil, [], false, $0) })
    }

    public func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Swift.Error?) -> Void) -> Progress {
        async({
            try self.session().trash(id: identifier.rawValue)
            completionHandler(nil)
        }, fail: { completionHandler($0) })
    }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard Credentials.load() != nil else { throw NSFileProviderError(.notAuthenticated) }
        return SyncloomEnumerator(container: containerItemIdentifier, session: { try self.session() })
    }
}

/// The synthetic root folder.
final class RootItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Syncloom" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
    var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8)) }
}

import UniformTypeIdentifiers

final class SyncloomEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let session: () throws -> Session

    init(container: NSFileProviderItemIdentifier, session: @escaping () throws -> Session) {
        self.container = container
        self.session = session
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if self.container == .workingSet { return observer.finishEnumerating(upTo: nil) } // reported through changes
                let s = try self.session()
                let nodes = self.container == .trashContainer ? try s.trashList() : try s.list(parent: self.container == .rootContainer ? nil : self.container.rawValue)
                observer.didEnumerate(nodes.map { ProviderItem($0) })
                observer.finishEnumerating(upTo: nil)
            } catch { observer.finishEnumeratingWithError(SyncloomProviderExtension.map(error)) }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let s = try self.session()
                let since = Int64(String(data: anchor.rawValue, encoding: .utf8) ?? "0") ?? 0
                let r = try s.changes(since: since, limit: 500)
                var updated: [NSFileProviderItem] = []
                var deleted: [NSFileProviderItemIdentifier] = []
                var seen = Set<String>()
                for c in r.changes where seen.insert(c.nodeId).inserted && c.kind != "kv" && c.kind != "share" {
                    if c.kind == "purge" { deleted.append(.init(c.nodeId)); continue }
                    if let n = try? s.get(id: c.nodeId) {
                        if n.deleted { deleted.append(.init(c.nodeId)) } else if n.kind != "kv" { updated.append(ProviderItem(n)) }
                    } else { deleted.append(.init(c.nodeId)) }
                }
                if !updated.isEmpty { observer.didUpdate(updated) }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(String(r.nextCursor).utf8)), moreComing: r.changes.count >= 500)
            } catch { observer.finishEnumeratingWithError(SyncloomProviderExtension.map(error)) }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let head = (try? self.session().changesHead()) ?? 0
            completionHandler(NSFileProviderSyncAnchor(Data(String(head).utf8)))
        }
    }
}

/// Registers the "Syncloom" location in Finder / the Files app, and tells the system when the server changed.
public enum FileProviderRegistration {
    public static let domainId = NSFileProviderDomainIdentifier("world.syncloom.default")

    public static func register() async {
        let domain = NSFileProviderDomain(identifier: domainId, displayName: "Syncloom")
        do { try await NSFileProviderManager.add(domain) } catch { /* already registered, or not permitted in this build */ }
    }

    /// Removes the location and everything cached or downloaded for it (after sign-out or a reset server).
    public static func unregister() async {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        for d in domains where d.identifier == domainId { try? await NSFileProviderManager.remove(d, mode: .removeAll) }
    }

    public static func signalChanged() {
        let domain = NSFileProviderDomain(identifier: domainId, displayName: "Syncloom")
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }
}
