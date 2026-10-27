import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var store: HostStore
    @State private var editing: HostProfile?
    @State private var connecting: HostProfile?
    @State private var showingHelp = false

    var body: some View {
        NavigationStack {
            Group {
                if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Computers Yet", systemImage: "display")
                    } description: {
                        Text("Add your PiKVM to control the computer it's plugged into.")
                    } actions: {
                        Button("Add PiKVM") { editing = HostProfile() }
                            .buttonStyle(.borderedProminent)
                        Button("PiKVM Setup Help") { showingHelp = true }
                    }
                } else {
                    List {
                        ForEach(store.hosts) { host in
                            Button { connecting = host } label: { row(host) }
                                .swipeActions {
                                    Button(role: .destructive) { store.delete(host) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button { editing = host } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.orange)
                                }
                                .contextMenu {
                                    Button { connecting = host } label: { Label("Connect", systemImage: "play") }
                                    Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                                    Button(role: .destructive) { store.delete(host) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onMove(perform: store.move)
                    }
                }
            }
            .navigationTitle("KVM Remote")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = HostProfile() } label: { Label("Add", systemImage: "plus") }
                }
            }
        }
        .sheet(item: $editing) { profile in
            HostEditorView(profile: profile)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .fullScreenCover(item: $connecting) { profile in
            SessionView(profile: profile)
                .environmentObject(store)
        }
    }

    private func row(_ host: HostProfile) -> some View {
        HStack(spacing: 14) {
            Image(systemName: host.serverKind == .pikvm ? "pc" : "display")
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.headline).foregroundStyle(.primary)
                Text(verbatim: "\(host.host):\(host.port) · \(host.serverKind.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if host.security == .tls {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("Encrypted")
            }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
