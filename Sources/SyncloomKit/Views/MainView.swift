import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case files = "Files", shared = "Shared with me", trash = "Trash", settings = "Settings"
    var id: String { rawValue }
    var icon: String { switch self { case .files: "folder"; case .shared: "person.2"; case .trash: "trash"; case .settings: "gearshape" } }
}

/// The signed-in experience: a sidebar on the Mac, tabs on iPhone and iPad.
public struct MainView: View {
    @Bindable var model: AppModel
    @State private var section: SidebarSection? = .files
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if let session = model.session {
            #if os(macOS)
            NavigationSplitView {
                List(SidebarSection.allCases, selection: $section) { s in Label(s.rawValue, systemImage: s.icon).tag(s) }
                    .navigationSplitViewColumnWidth(min: 190, ideal: 210)
                    .safeAreaInset(edge: .bottom) { account }
            } detail: { detail(session, section ?? .files) }
            #else
            TabView {
                ForEach(SidebarSection.allCases) { s in
                    detail(session, s).tabItem { Label(s.rawValue, systemImage: s.icon) }
                }
            }
            #endif
        }
    }

    @ViewBuilder private func detail(_ session: Session, _ s: SidebarSection) -> some View {
        switch s {
        case .files: NavigationStack { FolderView(session: session, parent: nil, title: "Files") }.id(session.exportSecrets().count)
        case .shared: NavigationStack { SharedView(session: session) }
        case .trash: NavigationStack { TrashView(session: session) }
        case .settings: NavigationStack { SettingsView(model: model, session: session) }
        }
    }

    #if os(macOS)
    private var account: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.user?.username ?? model.saved?.username ?? "").font(.headline)
            if let u = model.user {
                if let q = u.quotaBytes { ProgressView(value: min(1, Double(u.usedBytes) / Double(max(q, 1)))) }
                Text("\(formatBytes(u.usedBytes))\(u.quotaBytes.map { " of \(formatBytes($0))" } ?? " used")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}

struct SharedView: View {
    let session: Session
    @State private var items: [FfiNode]?
    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("Nothing shared with you yet", systemImage: "person.2", description: Text("When someone shares a folder with you it shows up here."))
                } else {
                    List(items) { n in
                        NavigationLink(value: n) {
                            Label(n.name, systemImage: n.isFolder ? "folder.fill" : "doc.fill")
                        }
                    }
                }
            } else { ProgressView() }
        }
        .navigationTitle("Shared with me")
        .navigationDestination(for: FfiNode.self) { n in FolderView(session: session, parent: n.id, title: n.name, readOnly: n.access == "ro") }
        .task { items = (try? await offMain { try session.sharedWithMe() }) ?? [] }
    }
}

struct TrashView: View {
    let session: Session
    @State private var items: [FfiNode]?
    @State private var error: String?
    var body: some View {
        Group {
            if let items {
                if items.isEmpty { ContentUnavailableView("The trash is empty", systemImage: "trash") }
                else {
                    List(items) { n in
                        HStack {
                            Label(n.name, systemImage: n.isFolder ? "folder" : "doc")
                            Spacer()
                            Button("Restore") { Task { await act { _ = try session.restore(id: n.id) } } }.buttonStyle(.bordered)
                            Button("Delete", role: .destructive) { Task { await act { try session.purge(id: n.id) } } }.buttonStyle(.bordered)
                        }
                    }
                }
            } else { ProgressView() }
        }
        .navigationTitle("Trash")
        .task { await load() }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func load() async { items = (try? await offMain { try session.trashList() }) ?? [] }
    private func act(_ f: @escaping @Sendable () throws -> Void) async {
        do { try await offMain(f) } catch { self.error = error.friendly }
        await load()
    }
}
