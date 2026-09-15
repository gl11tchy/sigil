import SigilKit
import SwiftUI

/// Starts a session somewhere other than the current tab's folder.
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

                LabeledContent("Model") {
                    ModelNameField(text: $modelName)
                }

                Picker("Effort", selection: $effort) {
                    ForEach(AppSettings.effortOptions, id: \.self) { option in
                        Text(option.isEmpty ? "CLI default" : option.capitalized).tag(option)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    if model.newTab(in: directory, model: modelName, effort: effort) != nil {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!directoryIsAvailable || !model.settings.executableExists)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            directory = model.newSessionDirectory
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
