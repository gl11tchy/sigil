import SigilKit
import SwiftUI

/// Chooses a provider and starts its CLI in the requested folder.
struct NewSessionSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var directory: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var modelName = ""
    @State private var effort = ""

    /// Folders the user has recently worked in, newest first.
    private var recents: [URL] {
        var seen = Set<String>()
        return model.store.sessions.compactMap { session in
            let url = URL(fileURLWithPath: GrokPaths.canonicalPath(session.cwd))
            guard seen.insert(url.path).inserted else { return nil }
            return isDirectory(url) ? url : nil
        }
        .prefix(8)
        .map { $0 }
    }

    private var recentChoices: [URL] {
        recents.contains(directory) ? recents : [directory] + recents
    }

    private var directoryIsAvailable: Bool { isDirectory(directory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                ForEach(CLIProvider.allCases) { provider in
                    Button {
                        if model.newTab(
                            in: directory, model: modelName, effort: effort, provider: provider
                        ) != nil {
                            dismiss()
                        }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: provider.symbolName)
                                .font(.system(size: 42, weight: .medium))
                                .frame(width: 76, height: 76)
                            Text(provider.name)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(!directoryIsAvailable)
                    .accessibilityLabel("Start \(provider.name)")
                    .accessibilityIdentifier("new-session-\(provider.rawValue)")
                    .help("Start \(provider.name)")
                }
            }

            Form {
                LabeledContent("Folder") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(directory.abbreviatedPath)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Choose…") {
                                if let picked = model.pickDirectory(startingAt: directory) {
                                    directory = picked
                                }
                            }
                        }
                        if !directoryIsAvailable {
                            Text("Folder unavailable.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if !recents.isEmpty {
                    Picker("Recent", selection: $directory) {
                        ForEach(recentChoices, id: \.self) { url in
                            Text(url.abbreviatedPath).tag(url)
                        }
                    }
                }

                DisclosureGroup("Grok Build options") {
                    LabeledContent("Model") {
                        ModelNameField(text: $modelName)
                    }
                    Picker("Effort", selection: $effort) {
                        ForEach(AppSettings.effortOptions, id: \.self) { option in
                            Text(option.isEmpty ? "CLI default" : option.capitalized).tag(option)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            directory = model.pendingSessionDirectory ?? model.newSessionDirectory
            modelName = model.settings.model
            effort = model.settings.effort
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

extension CLIProvider {
    fileprivate var symbolName: String {
        switch self {
        case .claudeCode: "sun.max.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .devin: "cpu"
        case .cursor: "cursorarrow"
        case .grokBuild: "g.circle"
        }
    }
}
