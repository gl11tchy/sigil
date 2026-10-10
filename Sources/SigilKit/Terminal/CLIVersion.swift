import Foundation

/// Semantic CLI versions, including the two-component versions in legacy history.
/// History supplies a bare version; --version output may also contain a CLI name.
struct CLIVersion: Equatable, Comparable {
    let text: String
    let major: Int
    let minor: Int
    private let numbers: [Int]
    private let prerelease: [Substring]

    init?(_ text: String) {
        let build = text.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2, build.count == 1 || Self.validIdentifiers(build[1]) else { return nil }
        let release = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = release[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(core.count), core.allSatisfy(Self.validNumber) else { return nil }
        let values = core.compactMap { Int($0) }
        guard values.count == core.count else { return nil }
        let suffix = release.count == 2 ? release[1].split(separator: ".", omittingEmptySubsequences: false) : []
        if release.count == 2 {
            guard Self.validIdentifiers(release[1]),
                suffix.allSatisfy({ !$0.allSatisfy(\.isNumber) || Self.validNumber($0) })
            else { return nil }
        }
        self.text = text
        major = values[0]
        minor = values[1]
        numbers = values.count == 2 ? values + [0] : values
        prerelease = suffix
    }

    static func reported(in output: String) -> CLIVersion? {
        output.split(whereSeparator: \.isWhitespace).lazy.compactMap { CLIVersion(String($0)) }.first
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber)
            let rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func validNumber(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
            && (value.count == 1 || value.first != "0")
    }

    private static func validIdentifiers(_ value: Substring) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty
                && part.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                }
        }
    }
}
