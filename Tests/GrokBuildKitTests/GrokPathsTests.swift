import Foundation
import Testing

@testable import GrokBuildKit

@Test func encodesWorkingDirectoryLikeTheCLI() {
    #expect(GrokPaths.encode(path: "/Users/exec") == "%2FUsers%2Fexec")
}
