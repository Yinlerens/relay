import XCTest
@testable import Relay

final class ModelAndCacheTests: XCTestCase {
    func testSessionSummaryDecodesPinnedAndLegacyWithoutPinned() throws {
        let legacyJSON = Data(#"{"id":"s1","agentId":"agy","title":"Test","cwd":"/tmp","isRunning":false,"createdAt":10,"updatedAt":20}"#.utf8)
        let legacy = try JSONDecoder().decode(SessionSummary.self, from: legacyJSON)
        XCTAssertEqual(legacy.pinned, false)
        XCTAssertEqual(legacy.title, "Test")

        let pinnedJSON = Data(#"{"id":"s2","agentId":"codebuddy","title":"Pinned","cwd":"/tmp","pinned":1,"createdAt":10,"updatedAt":20}"#.utf8)
        let pinned = try JSONDecoder().decode(SessionSummary.self, from: pinnedJSON)
        XCTAssertEqual(pinned.pinned, true)
    }

    func testToolActivityDecodesOptionalDetailFields() throws {
        let json = Data(#"""
        {
          "id": "t1",
          "name": "Bash",
          "title": "Run build",
          "kind": "execute",
          "status": "completed",
          "inputPreview": "swift test",
          "outputPreview": "All tests passed",
          "locations": ["/opt/relay/server/package.json:11"]
        }
        """#.utf8)
        let tool = try JSONDecoder().decode(ToolActivity.self, from: json)
        XCTAssertEqual(tool.inputPreview, "swift test")
        XCTAssertEqual(tool.outputPreview, "All tests passed")
        XCTAssertEqual(tool.locations, ["/opt/relay/server/package.json:11"])
        XCTAssertTrue(tool.hasDetails)

        let minimal = try JSONDecoder().decode(ToolActivity.self, from: Data(#"{"id":"t2","title":"Ping"}"#.utf8))
        XCTAssertFalse(minimal.hasDetails)
    }

    func testConfigValueHandlesStringBoolAndNumber() throws {
        XCTAssertEqual(try JSONDecoder().decode(ConfigValue.self, from: Data(#""high""#.utf8)).stringValue, "high")
        XCTAssertEqual(try JSONDecoder().decode(ConfigValue.self, from: Data(#"true"#.utf8)).boolValue, true)
        XCTAssertEqual(try JSONDecoder().decode(ConfigValue.self, from: Data(#"42"#.utf8)).stringValue, "42")
    }

    func testNormalizationHelpers() {
        XCTAssertEqual(
            RelayAPI.normalizedBaseURL(from: "code.apps.makima.sbs/")?.absoluteString,
            "https://code.apps.makima.sbs"
        )
        XCTAssertNil(RelayAPI.normalizedBaseURL(from: "   "))

        XCTAssertEqual(RelayDiskCache.normalizeChatFile("  Demo - 1.jsonl "), "Demo - 1")
        XCTAssertEqual(
            RelayDiskCache.normalizeAssetKey("relay-st://asset?path=%2Fcharacters%2Fa.png"),
            "st:/characters/a.png"
        )
        XCTAssertEqual(
            RelayDiskCache.normalizeAssetKey("/api/tavern/asset?path=/user/bg.jpg"),
            "st:/user/bg.jpg"
        )
    }

    func testAppStoreDraftsSetClearAndCheck() async {
        await MainActor.run {
            let store = AppStore()
            store.setAgentDraft("继续修这个 bug", for: "sess-1")
            XCTAssertEqual(store.agentDraft(for: "sess-1"), "继续修这个 bug")
            XCTAssertTrue(store.hasAgentDraft(for: "sess-1"))

            store.setAgentDraft("   \n ", for: "sess-1")
            XCTAssertFalse(store.hasAgentDraft(for: "sess-1"))

            store.setAgentDraft("", for: "sess-1")
            XCTAssertEqual(store.agentDraft(for: "sess-1"), "")

            store.setTavernDraft("下一幕台词", for: 7)
            XCTAssertTrue(store.hasTavernDraft(for: 7))
            store.clearDraftsState()
            XCTAssertFalse(store.hasTavernDraft(for: 7))
        }
    }
}
