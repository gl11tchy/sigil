import Foundation
import SigilKit

/// What the New Session sheet offers for one CLI: its models, and for each
/// model the efforts it takes and whether it has a fast mode.
struct ProviderModelMenu: Equatable, Sendable {
    struct Variant: Hashable, Sendable {
        let effort: String
        let fast: Bool
    }

    struct Model: Equatable, Sendable {
        /// The menu value. Empty is the CLI's own default.
        let id: String
        /// Effort values in menu order. Empty is the CLI's own default.
        let efforts: [String]
        let hasFastMode: Bool
        /// Cursor and Devin name effort and speed inside the model id, so each
        /// pair maps to one listed id. Empty for CLIs that take flags.
        var variants: [Variant: String] = [:]
    }

    /// What the sheet holds for one CLI.
    struct Choice: Equatable, Sendable {
        var model = ""
        var effort = ""
        var fast = false
    }

    var models: [Model]

    var hasEffort: Bool { models.contains { $0.efforts.count > 1 } }
    var hasFastMode: Bool { models.contains(where: \.hasFastMode) }

    func model(_ id: String) -> Model? { models.first { $0.id == id } }

    /// Keeps a choice inside what its model offers. An unlisted model becomes
    /// the CLI default; a missing effort becomes the default, else medium.
    func normalized(_ choice: Choice) -> Choice {
        guard let model = model(choice.model) ?? model("") else { return Choice() }
        var result = choice
        result.model = model.id
        if !model.efforts.contains(result.effort) {
            result.effort = ["", "medium"].first(where: model.efforts.contains) ?? model.efforts.first ?? ""
        }
        if !model.hasFastMode { result.fast = false }
        return result
    }

    /// The model, effort and fast mode a tab starts with. Cursor and Devin get
    /// the one listed id that carries all three.
    func launch(_ choice: Choice) -> (model: String, effort: String, fastMode: Bool) {
        let choice = normalized(choice)
        guard let model = model(choice.model), !model.variants.isEmpty else {
            return (choice.model, choice.effort, choice.fast)
        }
        let id =
            model.variants[Variant(effort: choice.effort, fast: choice.fast)]
            ?? model.variants[Variant(effort: choice.effort, fast: !choice.fast)]
            ?? model.variants[Variant(effort: "", fast: false)]
            ?? model.id
        return (id, "", false)
    }
}

extension ProviderModelMenu {
    /// Grok's rows: the listed models, plus a saved name the CLI no longer lists.
    static func grok(listed: [String], saved: String, efforts: [String]) -> ProviderModelMenu {
        ProviderModelMenu(
            models: ([""] + GrokModelCatalog.choices(listed: listed, saved: saved)).map {
                .init(id: $0, efforts: efforts, hasFastMode: false)
            })
    }
}

/// Model lists for the CLIs other than Grok, which has `GrokModelCatalog`.
enum ProviderModelCatalog {
    /// Effort words Cursor and Devin end a model id with, in menu order.
    static let effortWords = ["none", "minimal", "low", "medium", "high", "xhigh", "extra-high", "max", "ultra"]

    /// Claude Code takes these aliases. Fast mode runs Opus.
    static let claude = ProviderModelMenu(
        models: ["", "fable", "opus", "sonnet", "haiku"].map {
            .init(id: $0, efforts: ["", "low", "medium", "high", "xhigh", "max"], hasFastMode: $0.isEmpty || $0 == "opus")
        })

    /// The menu before the CLI's list arrives, or when it cannot be read. Nil
    /// for Kimi, whose model comes from its own config.
    static func fallback(_ provider: CLIProvider) -> ProviderModelMenu? {
        switch provider {
        case .claudeCode: claude
        case .codex:
            ProviderModelMenu(models: [.init(id: "", efforts: ["", "low", "medium", "high", "xhigh"], hasFastMode: true)])
        case .cursor, .devin: ProviderModelMenu(models: [.init(id: "", efforts: [""], hasFastMode: false)])
        case .kimi, .grokBuild: nil
        }
    }

    /// Reads the CLI's own list through the login shell its tabs use. Nil
    /// when the CLI has no list or the read fails.
    static func load(_ provider: CLIProvider) async -> ProviderModelMenu? {
        let arguments: [String]
        switch provider {
        case .codex: arguments = ["debug", "models"]
        case .cursor: arguments = ["models"]
        case .devin: arguments = ["models", "list", "--format", "json"]
        case .claudeCode, .kimi, .grokBuild: return nil
        }
        let command = GrokLaunchSpec(
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser, mode: .continueLatest,
            extraArguments: arguments, provider: provider
        ).hostCommand()
        guard let output = await GrokModelCatalog.output(of: command.executable.path, arguments: command.arguments)
        else { return nil }
        switch provider {
        case .codex: return codexMenu(output)
        case .cursor: return cursorMenu(output)
        case .devin: return devinMenu(output)
        case .claudeCode, .kimi, .grokBuild: return nil
        }
    }

    /// `codex debug models`: listed models with their reasoning levels and speed tiers.
    static func codexMenu(_ output: String) -> ProviderModelMenu? {
        struct Listing: Decodable { let models: [Entry] }
        struct Entry: Decodable {
            struct Level: Decodable { let effort: String }
            let slug: String
            let visibility: String?
            let supportedReasoningLevels: [Level]?
            let additionalSpeedTiers: [String]?
        }
        guard let data = json(in: output) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard
            let entries = (try? decoder.decode(Listing.self, from: data))?.models
                ?? (try? decoder.decode([Entry].self, from: data))
        else { return nil }
        let models: [ProviderModelMenu.Model] = entries.filter { $0.visibility == "list" }.map {
            .init(
                id: $0.slug, efforts: [""] + ($0.supportedReasoningLevels ?? []).map(\.effort),
                hasFastMode: $0.additionalSpeedTiers?.contains("fast") == true)
        }
        guard let first = models.first else { return nil }
        // The CLI default can be any of them, so it offers only the efforts all share.
        let shared = models.reduce(first.efforts) { common, model in common.filter(model.efforts.contains) }
        return ProviderModelMenu(
            models: [.init(id: "", efforts: shared, hasFastMode: models.contains(where: \.hasFastMode))] + models)
    }

    /// `cursor-agent models`: `id - Label` rows. Effort and speed are part of each id.
    static func cursorMenu(_ output: String) -> ProviderModelMenu? {
        var bases: [String] = []
        var ids: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let dash = line.range(of: " - ") else { continue }
            let id = line[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(where: { $0.isWhitespace || $0 == ":" }) else { continue }
            let base = split(id).base
            if ids[base] == nil { bases.append(base) }
            ids[base, default: []].append(id)
        }
        guard !bases.isEmpty else { return nil }
        return ProviderModelMenu(
            models: [.init(id: "", efforts: [""], hasFastMode: false)]
                + bases.map { variantModel(id: $0, ids: ids[$0] ?? []) })
    }

    /// `devin models list --format json`: families of variant ids. `--model`
    /// takes the family slug for its default variant.
    static func devinMenu(_ output: String) -> ProviderModelMenu? {
        struct Listing: Decodable { let families: [Family] }
        struct Family: Decodable {
            struct Variant: Decodable { let modelUid: String }
            let slug: String
            let variants: [Variant]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json(in: output), let listing = try? decoder.decode(Listing.self, from: data),
            !listing.families.isEmpty
        else { return nil }
        let models = listing.families.map { family in
            let uids = family.variants.map(\.modelUid)
            let bases = uids.map { split($0).base }
            var counts: [String: Int] = [:]
            for base in bases { counts[base, default: 0] += 1 }
            // Effort and speed read only from the ids named like the family, or
            // shared by most of it. Fusion pairs and legacy ids stay default-only.
            let named = family.slug.replacingOccurrences(of: ".", with: "-")
            let common = bases.max { counts[$0, default: 0] < counts[$1, default: 0] }
            let main =
                counts[named] != nil
                ? named : common.flatMap { counts[$0, default: 0] * 2 >= uids.count ? $0 : nil }
            let listed = zip(uids, bases).filter { $0.1 == main }.map(\.0)
            return variantModel(id: family.slug, ids: listed, bare: family.slug)
        }
        return ProviderModelMenu(models: [.init(id: "", efforts: [""], hasFastMode: false)] + models)
    }

    /// Splits `claude-opus-5-5-high-fast` into its base, effort and speed.
    static func split(_ id: String) -> (base: String, variant: ProviderModelMenu.Variant) {
        var rest = Substring(id)
        var fast = false
        if let suffix = ["-fast", "-priority"].first(where: { rest.hasSuffix($0) }) {
            rest = rest.dropLast(suffix.count)
            fast = true
        }
        // Longest first, so "extra-high" is not read as "high".
        for word in effortWords.sorted(by: { $0.count > $1.count }) where rest.hasSuffix("-" + word) {
            return (String(rest.dropLast(word.count + 1)), .init(effort: word, fast: fast))
        }
        return (String(rest), .init(effort: "", fast: fast))
    }

    /// One menu row for ids that share a base. `bare` launches the CLI's own
    /// default effort; with fast on, the default is the effort listed first.
    static func variantModel(id: String, ids: [String], bare: String? = nil) -> ProviderModelMenu.Model {
        typealias Variant = ProviderModelMenu.Variant
        var variants: [Variant: String] = [:]
        for listed in ids {
            let variant = split(listed).variant
            if variants[variant] == nil { variants[variant] = listed }
        }
        if let bare { variants[Variant(effort: "", fast: false)] = bare }
        if variants[Variant(effort: "", fast: true)] == nil, variants[Variant(effort: "", fast: false)] != nil,
            let first = ids.first.map({ split($0).variant.effort }),
            let twin = variants[Variant(effort: first, fast: true)]
        {
            variants[Variant(effort: "", fast: true)] = twin
        }
        let order = [""] + effortWords
        let efforts = Set(variants.keys.map(\.effort)).sorted {
            (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count)
        }
        return .init(
            id: id, efforts: efforts, hasFastMode: Set(variants.keys.map(\.fast)).count == 2, variants: variants)
    }

    /// The JSON value in a command's output, past anything a login shell printed first.
    private static func json(in output: String) -> Data? {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return Data(output[start...].utf8)
    }
}
