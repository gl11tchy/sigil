import SigilKit
import SwiftUI

/// Starts a session somewhere other than the current tab's folder.
struct NewSessionSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var directory: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var model_ = ""
    @State private var effort = ""

    /// Folders the user has recently worked in, newest first.
    private var recents: [URL] {
        var seen = Set<String>()
        return model.store.sessions.compactMap { session in
            guard seen.insert(session.cwd).inserted else { return nil }
            return URL(fileURLWithPath: session.cwd)
        }
        .prefix(8)
        .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(.headline)

            Form {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(directory.abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") {
                            if let picked = model.pickDirectory() { directory = picked }
                        }
                    }
                }

                if !recents.isEmpty {
                    Picker("Recent", selection: $directory) {
                        ForEach(recents, id: \.self) { url in
                            Text(url.abbreviatedPath).tag(url)
                        }
                    }
                }

                Picker("Model", selection: $model_) {
                    ForEach(AppSettings.modelOptions, id: \.self) { option in
                        Text(option.isEmpty ? "Default" : option).tag(option)
                    }
                }

                Picker("Effort", selection: $effort) {
                    ForEach(AppSettings.effortOptions, id: \.self) { option in
                        Text(option.isEmpty ? "Default" : option.capitalized).tag(option)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    model.newTab(in: directory, model: model_, effort: effort)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            directory = model.currentDirectory
            model_ = model.settings.model
            effort = model.settings.effort
        }
    }
}
