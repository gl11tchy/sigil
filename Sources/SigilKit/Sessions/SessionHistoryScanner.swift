import Foundation

/// Captured history roots and readers shared by cached refresh, Reload and deliberate recovery.
struct SessionHistoryScanner: Sendable {
    enum Policy: Sendable {
        case cached, reload, rebuild

        var ignoresGrokCache: Bool { self != .cached }
        var ignoresNativeCache: Bool { self == .rebuild }
    }

    var nativeRoots: [(CLIProvider, URL)]
    var availableRoots = SessionScanner.RootAvailability()
    var titleIndexCache = CodexTitleIndexCache()
    var contentReader: SessionScanner.ContentReader = .disk
    var nativeContentReader: NativeSessionScanner.ContentReader = .disk
    var nativeRecordDecoder: NativeSessionRecordDecoder = .init()

    func scan(root: URL, cache: [String: SessionCacheEntry], policy: Policy) -> SessionScanner.Result {
        var result = SessionScanner.scan(
            root: root, cache: cache.filter { $0.value.session.provider == .grokBuild },
            ignoringCache: policy.ignoresGrokCache, contentReader: contentReader,
            rootAvailability: availableRoots)
        for (provider, nativeRoot) in nativeRoots {
            let native = NativeSessionScanner.scan(
                provider: provider, root: nativeRoot, cache: cache,
                ignoringCache: policy.ignoresNativeCache,
                rootAvailability: availableRoots, contentReader: nativeContentReader,
                recordDecoder: nativeRecordDecoder, titleIndexCache: titleIndexCache)
            result.sessions += native.sessions
            result.cache.merge(native.cache) { _, new in new }
            result.loadError =
                [result.loadError, native.loadError].compactMap { $0 }.joined(separator: "\n").nilIfBlank
            result.coverage.merge(native.coverage)
        }
        if !nativeRoots.isEmpty { result.sessions.sort(by: SessionScanner.isNewer) }
        return result
    }
}
