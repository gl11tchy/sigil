#if os(iOS)
@testable import Sigil
#endif
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Expect {
    static func `true`(_ value: Bool, _ message: String) throws {
        if !value { throw TestFailure(message) }
    }

    static func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
        if lhs != rhs { throw TestFailure("\(message) (\(lhs) != \(rhs))") }
    }

    static func notNil<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message) }
        return value
    }
}
