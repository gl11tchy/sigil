import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The chrome under the output, as Beautiful UI's prompt bar: the approval card and the
/// terminal keys above, then one card with attachments, the message field, and a row of
/// controls ending in the round send button.
struct ComposerBar: View {
    @Environment(RemoteStore.self) private var store
    /// The most the approval card and the keys may take; past it they scroll.
    var upperLimit: CGFloat = .infinity
    @State private var showingKeys = false
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var preparing = false
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var status: TabStatus? { store.selectedTab?.status }
    private var ended: Bool { store.selectedTab?.acceptsInput == false }

    var body: some View {
        @Bindable var store = store
        ComposerStack(spacing: Theme.Space.small, cap: upperLimit) {
            let prompt = ended ? nil : store.prompt
            if prompt != nil || showingKeys {
                // The approval card and the keys take at most part of the page and scroll
                // there, so the message field, Stop and Send always stay on screen.
                ViewThatFits(in: .vertical) {
                    upperStack(prompt)
                    ScrollView { upperStack(prompt) }
                }
                .layoutValue(key: ComposerStack.Capped.self, value: true)
            }
            if ended, store.canRestart {
                Button {
                    store.restart()
                } label: {
                    Label("Restart session", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .disabled(!store.isConnected || store.busy)
            }
            VStack(spacing: 0) {
                if !store.selectedAttachments.isEmpty { attachmentRow }
                TextField(
                    ended ? "Session ended" : "Message", text: $store.draft,
                    prompt: Text(ended ? "Session ended" : "Message").foregroundStyle(Theme.ink2),
                    axis: .vertical
                )
                .typeStep(.field)
                .foregroundStyle(Theme.ink)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.return)
                .disabled(ended || store.selectedTab == nil)
                .padding(.horizontal, 14)
                .padding(.top, Theme.Space.medium)
                .padding(.bottom, Theme.Space.tight)
                .frame(minHeight: 38)
                .privacySensitive()

                HStack(spacing: 0) {
                    attachMenu
                    Spacer(minLength: 0)
                    if store.selectedTab?.canInterrupt == true { stopButton }
                    sendButton
                }
                .padding(Theme.Space.s2)
            }
            .surface(Theme.surface, radius: Theme.Radius.card, elevation: .card)
            // Focus draws a 1px accent ring over the card's own, as the web prompt bar does.
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .themeAnimation(Theme.Motion.fade, value: focused)
        }
        .padding(.horizontal, Theme.Space.s8)
        .padding(.top, Theme.Space.small)
        .padding(.bottom, Theme.Space.small)
        // The output runs on under the bar; the page fill hides it beside and below the cards,
        // after a short fade so a line scrolling under does not end on a hard edge.
        .background {
            Theme.page
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Theme.page.opacity(0), Theme.page], startPoint: .top, endPoint: .bottom)
                        .frame(height: Theme.Space.s12)
                        .offset(y: -Theme.Space.s12)
                        .allowsHitTesting(false)
                }
        }
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

    private func upperStack(_ prompt: RemotePrompt?) -> some View {
        VStack(spacing: Theme.Space.small) {
            if let prompt { answerBar(prompt) }
            if showingKeys { keysRow }
        }
    }

    /// A quiet icon control at the leading edge of the controls row. The menu stays native.
    private var attachMenu: some View {
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
                .font(Theme.glyph)
                .foregroundStyle(showingKeys ? Theme.ink : Theme.ink3)
                .frame(width: 32, height: 32)
                // Keys showing reads as an expanded toggle: the pressed fill stays.
                .background(
                    showingKeys ? Theme.hover2 : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                )
                .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach or show keys")
        .disabled(ended || preparing)
    }

    /// While a turn runs, the web companion's Stop: the word in `redInk` on the red tint,
    /// beside the send button rather than in its place.
    private var stopButton: some View {
        Button("Stop") {
            store.interrupt()
        }
        .buttonStyle(SigilButtonStyle(kind: .destructive, height: 34))
        .frame(minHeight: Theme.tapTarget)
        .contentShape(Rectangle())
        .padding(.trailing, Theme.Space.s4)
        .accessibilityLabel("Stop")
        .disabled(!store.isConnected)
    }

    /// The round accent button at the trailing edge.
    private var sendButton: some View {
        Button {
            store.sendDraft()
        } label: {
            Image(systemName: store.busy ? "ellipsis" : "arrow.up")
        }
        .buttonStyle(SendButtonStyle())
        .accessibilityLabel(store.busy ? "Sending" : "Send")
        .disabled(!store.canSend)
    }

    /// Attachments sit inside the card above the text, as chips on the `hover` fill.
    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s6) {
                ForEach(store.selectedAttachments) { item in
                    let image = item.preview.flatMap { UIImage(data: $0) }
                    HStack(spacing: Theme.Space.small) {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 32, height: 32)
                                .background(Theme.inset)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "doc")
                                .font(Theme.glyph)
                                .foregroundStyle(Theme.ink3)
                                .accessibilityHidden(true)
                        }
                        Text(item.name)
                            .typeStep(.small)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .frame(maxWidth: 140)
                        Button {
                            store.removeAttachment(item)
                        } label: {
                            Image(systemName: "xmark")
                                .font(Theme.glyph)
                        }
                        .buttonStyle(.icon)
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(.leading, image == nil ? Theme.Space.medium : Theme.Space.s6)
                    .frame(minHeight: Theme.tapTarget)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .privacySensitive()
                }
            }
            .padding([.horizontal, .top], Theme.Space.s8)
        }
    }

    /// Beautiful UI's approval card: the question, then one button per answer. Yes is the
    /// primary button; No and each numbered row of the question on screen are secondary.
    private func answerBar(_ prompt: RemotePrompt) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text(prompt.verified ? "Approval" : "Terminal controls")
                .typeStep(.small, weight: .medium)
                .foregroundStyle(Theme.ink2)
            if !prompt.verified {
                Text("Unverified. Check the terminal before typing.")
                    .typeStep(.small)
                    .foregroundStyle(Theme.ink2)
            }
            if let operation = prompt.operation, !operation.isEmpty {
                Text(operation)
                    .typeStep(.mono)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !prompt.question.isEmpty {
                Text(prompt.question)
                    .typeStep(.body, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.tight)
            }
            // The answers wrap onto more lines, so a long one is never cut at the card's edge.
            FlowLayout(spacing: Theme.Space.s6) {
                if prompt.choices.isEmpty {
                    if let yes = prompt.yes { answerButton("Yes", key: yes, primary: prompt.verified) }
                    if let no = prompt.no { answerButton("No", key: no) }
                }
                ForEach(prompt.choices) { choice in
                    answerButton(
                        "\(choice.key)  \(choice.label)", key: choice.key,
                        number: choice.key, text: choice.label)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(padding: Theme.Space.s8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.verified ? "Approval" : "Unverified terminal controls")
    }

    /// `number` draws a menu row's key in mono before its text; `title` stays the spoken label.
    private func answerButton(
        _ title: String, key: String, primary: Bool = false, number: String? = nil, text: String? = nil
    ) -> some View {
        Button {
            store.answer(key)
        } label: {
            if let number, let text {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s6) {
                    Text(number)
                        .font(Theme.font(.mono, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                    // An answer wider than the card wraps inside its button, never ending in "…".
                    Text(text)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, Theme.Space.s8)
            } else {
                Text(title)
            }
        }
        .buttonStyle(SigilButtonStyle(kind: primary ? .primary : .secondary))
        .disabled(!store.isConnected || store.busy)
        .accessibilityLabel(title)
    }

    /// The terminal keys, four to a row like the web companion's narrow grid;
    /// two to a row at accessibility sizes, so each word keeps its width.
    private var keysRow: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Theme.Space.s6),
                count: dynamicTypeSize.isAccessibilitySize ? 2 : 4),
            spacing: Theme.Space.s6
        ) {
            ForEach(
                [RemoteKey.escape, .tab, .up, .down, .left, .right, .backspace, .enter]
            ) { key in
                Button {
                    store.send(key: key)
                } label: {
                    Text(Self.label(key))
                }
                .buttonStyle(TerminalKeyStyle())
                .accessibilityLabel(Self.spoken(key))
                .disabled(!store.isConnected || ended)
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

/// The web companion's send button: a 34pt `accentFill` circle under a white arrow, in a
/// 44pt hit area, 6% darker while pressed. Disabled, it is `hover2` under an `ink2` arrow,
/// which stays legible on either page where the accent at 40% would not.
private struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SendButtonBody(configuration: configuration)
    }
}

private struct SendButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .font(Theme.glyph)
            .fontWeight(Theme.emphasis(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Theme.ink2)
            .frame(width: 34, height: 34)
            .background(isEnabled ? Theme.accentFill : Theme.hover2, in: Circle())
            .overlay(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.06 : 0)))
            .minTappableArea()
            .contentShape(Rectangle())
            .animation(Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Lays its views out in rows, left to right, starting a new row when the next
/// one would not fit. A view wider than the row gets the row to itself.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: bounds.width, subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// A vertical stack, centred, whose `Capped` view is at most `cap` tall and never taller
/// than the other views leave; it scrolls past that. The other views keep their own height.
private struct ComposerStack: Layout {
    var spacing: CGFloat
    var cap: CGFloat

    struct Capped: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(width: proposal.width, total: .infinity, subviews)
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, size) in zip(subviews, sizes(width: bounds.width, total: bounds.height, subviews)) {
            subview.place(
                at: CGPoint(x: bounds.midX, y: y), anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
    }

    private func sizes(width: CGFloat?, total: CGFloat, _ subviews: Subviews) -> [CGSize] {
        var sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let others = subviews.indices.filter { !subviews[$0][Capped.self] }.map { sizes[$0].height }.reduce(0, +)
        let left = total - others - spacing * CGFloat(max(0, subviews.count - 1))
        for index in subviews.indices where subviews[index][Capped.self] {
            sizes[index].height = max(0, min(sizes[index].height, cap, left))
        }
        return sizes
    }
}

/// A terminal key: mono 500 on a `surface` key lifted by the `button` ring, `hover2` while pressed.
private struct TerminalKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TerminalKey(configuration: configuration)
    }
}

private struct TerminalKey: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .font(Theme.jetBrainsMono(13, Theme.emphasis(.medium), relativeTo: .footnote))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, Theme.Space.s8)
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget)
            .surface(
                configuration.isPressed ? Theme.hover2 : Theme.surface,
                radius: Theme.Radius.control, elevation: .button
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Theme.animation(Theme.Motion.fade, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
