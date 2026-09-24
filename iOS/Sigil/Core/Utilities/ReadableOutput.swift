import Foundation
import JavaScriptCore

/// Tidies a terminal snapshot for a phone: drops the idle composer and TUI framing.
///
/// This runs the web companion's own `output.mjs` rather than a Swift port, so
/// the two phone surfaces cannot drift apart. `scripts/test.sh` fails when the
/// bundled copy differs from `Sidereal/public/output.mjs`.
@MainActor
final class ReadableOutput {
    private let function: JSValue?
    private var lastInput: String?
    private var lastOutput = ""

    init(script: String) {
        let context = JSContext()
        // Module syntax is not available in a plain context; the file has no imports.
        let source = script.replacingOccurrences(of: "export function", with: "function")
        context?.evaluateScript(source)
        let function = context?.objectForKeyedSubscript("readableOutput")
        self.function = function?.isUndefined == false ? function : nil
    }

    static func bundled() -> ReadableOutput {
        let url = Bundle.main.url(forResource: "readable-output", withExtension: "js")
        return ReadableOutput(script: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }

    var isAvailable: Bool { function != nil }

    /// Falls back to the raw text if the script is missing or throws; raw is lossless.
    func format(_ snapshot: String) -> String {
        if snapshot == lastInput { return lastOutput }
        let result = function?.call(withArguments: [snapshot])
        let output = result.flatMap { $0.isString ? $0.toString() : nil } ?? snapshot
        lastInput = snapshot
        lastOutput = output
        return output
    }
}
