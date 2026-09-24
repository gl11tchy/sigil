import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The chrome under the output: attachments, terminal keys, the message field and send.
struct ComposerBar: View {
    @Environment(RemoteStore.self) private var store
    @State private var showingKeys = false
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var preparing = false
    @FocusState private var focused: Bool

    private var status: TabStatus? { store.selectedTab?.status }
    private var ended: Bool { status == .exited }
    private var isEmpty: Bool {
        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.selectedAttachments.isEmpty
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: Theme.Space.small) {
            if !store.selectedAttachments.isEmpty { attachmentRow }
            if showingKeys { keysRow }
            if ended, store.canRestart {
                Button {
                    store.restart()
                } label: {
                    Label("Restart session", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.floatingGlass(tint: Theme.accentDeep, prominent: true))
                .disabled(!store.isConnected || store.busy)
            }
            HStack(alignment: .bottom, spacing: Theme.Space.small) {
                Menu {
                    Button {
                        showingPhotos = true
                    } label: {
                        Label("Photo library", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showingFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    Divider()
                    Button {
                        Theme.withMotion { showingKeys.toggle() }
                    } label: {
                        Label(showingKeys ? "Hide keys" : "Show keys", systemImage: "keyboard")
                    }
                } label: {
                    Image(systemName: preparing ? "hourglass" : "plus")
                        .font(.body.weight(Theme.emphasis(.semibold)))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 40, height: 40)
                        .chromeGlass(.regular.interactive(), in: Circle())
                }
                .minTappableArea()
                .accessibilityLabel("Attach or show keys")
                .disabled(ended || preparing)

                TextField(
                    ended ? "Session ended" : "Message", text: $store.draft, axis: .vertical
                )
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.return)
                .disabled(ended || store.selectedTab == nil)
                .padding(.horizontal, Theme.Space.medium)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .chromeGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .privacySensitive()

                if status == .working, isEmpty {
                    Button {
                        store.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(Theme.emphasis(.semibold)))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .chromeGlass(.regular.tint(Theme.danger).interactive(), in: Circle(), fallback: Theme.danger)
                    }
                    .buttonStyle(.icon)
                    .accessibilityLabel("Stop")
                    .disabled(!store.isConnected)
                } else {
                    Button {
                        store.sendDraft()
                    } label: {
                        Image(systemName: store.busy ? "ellipsis" : "arrow.up")
                            .font(.body.weight(Theme.emphasis(.bold)))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .chromeGlass(
                                .regular.tint(store.canSend ? Theme.accentDeep : Theme.controlBackground).interactive(),
                                in: Circle(), fallback: store.canSend ? Theme.accentDeep : Theme.controlBackground)
                    }
                    .buttonStyle(.icon)
                    .accessibilityLabel(store.busy ? "Sending" : "Send")
                    .disabled(!store.canSend)
                }
            }
        }
        .padding(.horizontal, Theme.Space.medium)
        .padding(.top, Theme.Space.small)
        .padding(.bottom, Theme.Space.small)
        .photosPicker(
            isPresented: $showingPhotos, selection: $photoItems, maxSelectionCount: RemoteFile.maxAttachments,
            matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            if case .success(let urls) = result { attachFiles(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            attachPhotos(items)
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.tight) {
                ForEach(store.selectedAttachments) { item in
                    HStack(spacing: Theme.Space.tight) {
                        if let preview = item.preview, let image = UIImage(data: preview) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "doc")
                                .foregroundStyle(Theme.secondaryText)
                                .accessibilityHidden(true)
                        }
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 140)
                        Button {
                            store.removeAttachment(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(.leading, Theme.Space.tight)
                    .chromeGlass(.regular, in: Capsule())
                    .privacySensitive()
                }
            }
        }
    }

    private var keysRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.tight) {
                ForEach(
                    [RemoteKey.escape, .tab, .up, .down, .left, .right, .backspace, .enter]
                ) { key in
                    Button {
                        store.send(key: key)
                    } label: {
                        Text(Self.label(key))
                            .font(Theme.mono.weight(Theme.emphasis(.medium)))
                            .foregroundStyle(Theme.primaryText)
                            .padding(.horizontal, Theme.Space.small)
                            .frame(minWidth: 44, minHeight: 36)
                            .chromeGlass(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.icon)
                    .accessibilityLabel(Self.spoken(key))
                    .disabled(!store.isConnected || ended)
                }
            }
        }
    }

    static func label(_ key: RemoteKey) -> String {
        switch key {
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .backspace: return "⌫"
        case .enter: return "Enter"
        case .interrupt: return "⌃C"
        }
    }

    static func spoken(_ key: RemoteKey) -> String {
        switch key {
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .up: return "Up arrow"
        case .down: return "Down arrow"
        case .left: return "Left arrow"
        case .right: return "Right arrow"
        case .backspace: return "Backspace"
        case .enter: return "Enter"
        case .interrupt: return "Interrupt"
        }
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) {
        preparing = true
        Task {
            var prepared: [Attachment] = []
            for (offset, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let name = items.count == 1 ? "photo.jpg" : "photo-\(offset + 1).jpg"
                if let attachment = await PhotoPrep.attachment(data: data, name: name, forceJPEG: true) {
                    prepared.append(attachment)
                }
            }
            preparing = false
            if let problem = store.attach(prepared) { store.errorMessage = problem }
            if prepared.count < items.count, store.errorMessage == nil {
                store.errorMessage = "Some photos could not be read."
            }
        }
    }

    private func attachFiles(_ urls: [URL]) {
        preparing = true
        Task {
            var prepared: [Attachment] = []
            var tooBig = false
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                // Photos are compressed before upload; other files must already fit.
                if !isImage, size > RemoteFile.maxBytes {
                    tooBig = true
                    continue
                }
                guard let data = try? Data(contentsOf: url) else { continue }
                if let attachment = await PhotoPrep.attachment(
                    data: data, name: url.lastPathComponent, forceJPEG: false, isImage: isImage)
                {
                    prepared.append(attachment)
                }
            }
            preparing = false
            let problem = store.attach(prepared)
            store.errorMessage = [tooBig ? "Keep files under 4 MB." : nil, problem].compactMap { $0 }.first
        }
    }
}

/// Shrinks photos the way the web companion does: 1920 px on the long edge, JPEG at 0.82.
enum PhotoPrep {
    static func attachment(data: Data, name: String, forceJPEG: Bool, isImage: Bool = true) async -> Attachment? {
        await Task.detached(priority: .userInitiated) { () -> Attachment? in
            guard isImage, let image = UIImage(data: data) else {
                return Attachment(name: name, data: data, preview: nil)
            }
            let scale = min(1, 1920 / max(image.size.width, image.size.height))
            let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            let thumbSize = CGSize(width: 56, height: 56 * size.height / max(size.width, 1))
            let thumb = UIGraphicsImageRenderer(size: thumbSize).image { _ in
                resized.draw(in: CGRect(origin: .zero, size: thumbSize))
            }.jpegData(compressionQuality: 0.7)
            if let jpeg = resized.jpegData(compressionQuality: 0.82) {
                let stem = (name as NSString).deletingPathExtension
                return Attachment(name: "\(stem.isEmpty ? "photo" : stem).jpg", data: jpeg, preview: thumb)
            }
            // Send the original if it still fits.
            return forceJPEG ? nil : Attachment(name: name, data: data, preview: thumb)
        }.value
    }
}
