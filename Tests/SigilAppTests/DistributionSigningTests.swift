import Foundation
import Testing

struct DistributionSigningTests {
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent(path))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The hardened runtime denies these without asking, whatever Info.plist says.
    @Test(arguments: [
        ("NSAppleEventsUsageDescription", "com.apple.security.automation.apple-events"),
        ("NSCameraUsageDescription", "com.apple.security.device.camera"),
        ("NSMicrophoneUsageDescription", "com.apple.security.device.audio-input"),
        ("NSContactsUsageDescription", "com.apple.security.personal-information.addressbook"),
        ("NSCalendarsUsageDescription", "com.apple.security.personal-information.calendars"),
        ("NSLocationUsageDescription", "com.apple.security.personal-information.location"),
        ("NSPhotoLibraryUsageDescription", "com.apple.security.personal-information.photos-library"),
    ])
    func everyPurposeStringHasItsHardenedRuntimeEntitlement(usageKey: String, entitlement: String) throws {
        let info = try Self.plist("Resources/Info.plist")
        let entitlements = try Self.plist("Resources/Sigil.entitlements")
        #expect(info[usageKey] is String)
        #expect(entitlements[entitlement] as? Bool == true)
    }

    @Test func distributionBuildSignsTheAppWithTheEntitlements() throws {
        let script = try String(
            contentsOf: Self.repo.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        let hardened = script.components(separatedBy: "--options runtime").dropFirst()
        #expect(hardened.filter { $0.hasPrefix(" --timestamp --entitlements \"$ENTITLEMENTS\"") }.count == 2)
    }
}
