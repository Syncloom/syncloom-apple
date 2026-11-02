import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class FolderModel {
    let session: Session
    let parent: String?
    var items: [FfiNode] = []
    var loading = true
    var error: String?

    init(session: Session, parent: String?) {
        self.session = session
        self.parent = parent
    }

    func load(quiet: Bool = false) async {
        if !quiet { loading = true }
        let (s, p) = (session, parent)
        do {
            let list = try await offMain { try s.list(parent: p) }
            items = list.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            error = nil
        } catch { self.error = error.friendly }
        loading = false
    }

    private var reloading = false
    private var again = false

    /// Reload after a server-side change; bursts of changes are folded into one more reload.
    func reload() async {
        if reloading { again = true; return }
        reloading = true
        repeat { again = false; await load(quiet: true) } while again
        reloading = false
    }

    func perform(_ work: @escaping @Sendable (Session) throws -> Void) async {
        let s = session
        do { try await offMain { try work(s) } } catch { self.error = error.friendly }
        await load(quiet: true)
    }

    func newFolder(_ name: String) async { let p = parent; await perform { _ = try $0.createFolder(parent: p, name: name) } }
    func rename(_ n: FfiNode, to name: String) async { await perform { _ = try $0.rename(id: n.id, name: name) } }
    func trash(_ n: FfiNode) async { await perform { try $0.trash(id: n.id) } }

    /// Uploads files and whole folders (recursively). One failing item does not stop the others.
    func upload(_ urls: [URL]) async {
        let (s, p) = (session, parent)
        let failed = (try? await offMain { () -> [String] in
            var failed: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                uploadItem(s, parent: p, url: url, failed: &failed)
            }
            return failed
        }) ?? []
        if !failed.isEmpty {
            error = "Could not upload \(failed.count) item\(failed.count == 1 ? "" : "s"): " + failed.prefix(5).joined(separator: ", ") + (failed.count > 5 ? ", …" : "")
        }
        await load(quiet: true)
    }

    func download(_ n: FfiNode) async -> URL? {
        let s = session
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(n.name)
        do {
            try await offMain { try s.downloadFile(id: n.id, version: nil, dest: dest.path) }
            return dest
        } catch { self.error = error.friendly; return nil }
    }

    func link(_ n: FfiNode) async -> String? {
        let s = session
        do { return try await offMain { try s.createLink(id: n.id, password: nil, expiresAtMs: nil, maxDownloads: nil).url } } catch { self.error = error.friendly; return nil }
    }
}

struct TempFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try FileWrapper(url: url) }
}

/// One folder of the encrypted tree, with the native list affordances of each platform.
public struct FolderView: View {
    @State private var model: FolderModel
    let title: String
    let readOnly: Bool
    @State private var importing = false
    @State private var exporting: URL?
    @State private var renaming: FfiNode?
    @State private var newName = ""
    @State private var creating = false
    @State private var shareURL: String?
    @State private var dropTargeted = false

    public init(session: Session, parent: String?, title: String, readOnly: Bool = false) {
        _model = State(initialValue: FolderModel(session: session, parent: parent))
        self.title = title
        self.readOnly = readOnly
    }

    public var body: some View { dropped(alerts(files(base))) }

    private var base: some View {
        Group {
            if model.loading && model.items.isEmpty {
                ProgressView().controlSize(.large)
            } else if model.items.isEmpty {
                ContentUnavailableView {
                    Label("This folder is empty", systemImage: "icloud")
                } description: { Text(readOnly ? "Nothing has been shared here." : "Add files or folders with the Upload button, or drop them here.") }
            } else {
                List(model.items) { n in
                    row(n).contextMenu { menu(n) }
                        #if os(iOS)
                        .swipeActions { if n.access != "ro" { Button(role: .destructive) { Task { await model.trash(n) } } label: { Label("Trash", systemImage: "trash") } } }
                        #endif
                }
                #if os(macOS)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                #endif
            }
        }
        .navigationTitle(title)
        .navigationDestination(for: FfiNode.self) { n in FolderView(session: model.session, parent: n.id, title: n.name, readOnly: n.access == "ro") }
        .toolbar {
            if !readOnly {
                ToolbarItemGroup {
                    Button { creating = true; newName = "Untitled folder" } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { importing = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .refreshable { await model.load(quiet: true) }
        .task { await model.load() }
        .task { // the server pushes changes (see AppModel.watch), so Finder, web and other devices show up at once
            for await _ in NotificationCenter.default.notifications(named: .syncloomChanged) { await model.reload() }
        }
    }

    private func files<V: View>(_ v: V) -> some View {
        v
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { Task { await model.upload(urls) } }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting.map(TempFileDocument.init), contentType: .data, defaultFilename: exporting?.lastPathComponent) { _ in exporting = nil }
    }

    private func alerts<V: View>(_ v: V) -> some View {
        v
        .alert("New folder", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { let n = newName; Task { await model.newFolder(n) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let n = renaming { let name = newName; Task { await model.rename(n, to: name) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Public link", isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            Button("Copy") { if let u = shareURL { copyToPasteboard(u) }; shareURL = nil }
            Button("Close", role: .cancel) { shareURL = nil }
        } message: { Text("The key after #k= stays in the link and is never sent to the server.\n\n\(shareURL ?? "")") }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private func dropped<V: View>(_ v: V) -> some View {
        #if os(macOS)
        return v
            .dropDestination(for: URL.self, action: { urls, _ in
                guard !readOnly else { return false }
                Task { await model.upload(urls) }
                return true
            }, isTargeted: { dropTargeted = $0 })
            .overlay { dropOutline }
        #else
        return v
        #endif
    }

    @ViewBuilder private var dropOutline: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(8).allowsHitTesting(false)
        }
    }

    @ViewBuilder private func row(_ n: FfiNode) -> some View {
        if n.isFolder {
            NavigationLink(value: n) { label(n) }
        } else {
            label(n)
        }
    }

    private func icon(_ n: FfiNode) -> String { n.isFolder ? "folder.fill" : (n.isNamespace ? "cylinder.split.1x2.fill" : "doc.fill") }
    private func tint(_ n: FfiNode) -> Color { n.isFolder ? .indigo : (n.isNamespace ? .teal : .secondary) }

    private func subtitle(_ n: FfiNode) -> String {
        if n.isFolder { return "Folder" }
        if n.isUploading { return "Uploading…" }
        let when = n.modified.formatted(.relative(presentation: .named))
        return "\(formatBytes(n.size)) · \(when)"
    }

    private func label(_ n: FfiNode) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(n)).font(.title2).foregroundStyle(tint(n)).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name).lineLimit(1)
                Text(subtitle(n))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if n.access != "owner" { Text(n.access == "rw" ? "Shared · edit" : "Shared · view").font(.caption2).padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func menu(_ n: FfiNode) -> some View {
        if n.isFile {
            Button { Task { exporting = await model.download(n) } } label: { Label("Download…", systemImage: "arrow.down.circle") }
        }
        if n.access == "owner" { Button { Task { shareURL = await model.link(n) } } label: { Label("Create public link", systemImage: "link") } }
        if n.access != "ro" {
            Button { renaming = n; newName = n.name } label: { Label("Rename…", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { Task { await model.trash(n) } } label: { Label("Move to Trash", systemImage: "trash") }
        }
    }
}

/// Uploads a file, or a folder with everything in it. A folder whose name already exists in the destination is merged into.
func uploadItem(_ s: Session, parent: String?, url: URL, failed: inout [String]) {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
    let values = try? url.resourceValues(forKeys: keys)
    let name = url.lastPathComponent
    if values?.isSymbolicLink == true || name == ".DS_Store" { return }
    if values?.isDirectory == true {
        do {
            let existing = try s.list(parent: parent).first { $0.isFolder && $0.name == name && $0.access != "ro" }
            let folder = try existing ?? s.createFolder(parent: parent, name: name)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) {
                uploadItem(s, parent: folder.id, url: child, failed: &failed)
            }
        } catch { failed.append(name) }
        return
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let mtime = Int64((values?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000)
    let executable = ((attrs?[.posixPermissions] as? Int) ?? 0) & 0o100 != 0
    do { _ = try s.uploadNewFile(parent: parent, name: name, path: url.path, mtimeMs: mtime, executable: executable) } catch { failed.append(name) }
}
