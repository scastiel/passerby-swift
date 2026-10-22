import XCTest
@testable import Passerby

/// The privacy manifest and what the package never touches, per docs/tracker-contracts.md
/// "Privacy manifest and logging".
final class PrivacyTests: XCTestCase {
  func testThePrivacyManifestShipsAndDeclaresNoTracking() throws {
    let url = try XCTUnwrap(
      Passerby.resources.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
      "PrivacyInfo.xcprivacy is in the package's resource bundle")
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])

    XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
    XCTAssertEqual((plist["NSPrivacyAccessedAPITypes"] as? [Any])?.count, 0, "no required-reason API")

    let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    XCTAssertEqual(
      Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }),
      ["NSPrivacyCollectedDataTypeProductInteraction", "NSPrivacyCollectedDataTypeCoarseLocation"])
    for type in collected {
      XCTAssertEqual(type["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
      XCTAssertEqual(type["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
      XCTAssertEqual(
        type["NSPrivacyCollectedDataTypePurposes"] as? [String],
        ["NSPrivacyCollectedDataTypePurposeAnalytics"])
    }
  }

  func testTheSourcesReadNoIdentifierAndWriteNothingToDisk() throws {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/Passerby")
    let files = try FileManager.default.contentsOfDirectory(
      at: sources, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    XCTAssertFalse(files.isEmpty, "found the sources at \(sources.path)")

    let forbidden = [
      "UserDefaults", "SecItem", "Keychain", "identifierForVendor", "advertisingIdentifier",
      "FileManager", "write(to", "NSUbiquitousKeyValueStore", "systemUptime", "URLCache.shared",
    ]
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      for word in forbidden {
        XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) mentions \(word)")
      }
    }
  }

  func testTheLiveSessionKeepsNothingOnDisk() {
    let configuration = Environment.live.session.configuration
    XCTAssertNil(configuration.urlCache)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.urlCredentialStorage)
  }
}
