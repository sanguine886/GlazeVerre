import GlassKit
import Persistence
import SwiftUI

/// Terminal tab (tab2): hosts the CLI terminal (reached from each server) and
/// the snippet command panel (spec §4.3). The CLI that used to open from
/// Servers (tab1) now lives here; tab1 opens the server detail screen instead.
struct TerminalSessionsView: View {
    @Environment(HostManager.self) private var manager
    @State private var path: [UUID] = []
    /// Whether to show the snippet panel (pushed from the list).
    @State private var showSnippets = false

    var body: some View {
        NavigationStack {
            List {
                Section("terminal.hosts") {
                    if manager.allHosts.isEmpty {
                        Text("terminal.hosts.empty")
                            .font(.subheadline)
                            .foregroundStyle(Color.glassSecondaryText)
                    } else {
                        ForEach(manager.allHosts) { host in
                            NavigationLink(value: host.id) {
                                hostRow(host)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        showSnippets = true
                    } label: {
                        Label("terminal.snippets", systemImage: "square.and.pencil")
                    }
                }
            }
            .navigationTitle(Text("tab.terminal"))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.glassBackground.ignoresSafeArea())
            .accessibilityIdentifier("screen.terminal.heading")
            .navigationDestination(for: UUID.self) { hostID in
                if let host = manager.allHosts.first(where: { $0.id == hostID }) {
                    TerminalScreenView(record: host)
                }
            }
            .sheet(isPresented: $showSnippets) {
                NavigationStack {
                    SnippetsListView()
                }
            }
            .task { manager.refresh() }
        }
    }

    private func hostRow(_ host: HostRecord) -> some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(Color.glassAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.body)
                    .foregroundStyle(Color.glassPrimaryText)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(Color.glassSecondaryText)
            }
            Spacer()
            Image(systemName: "terminal")
                .foregroundStyle(Color.glassSecondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("terminal.host.\(host.name)")
    }
}
