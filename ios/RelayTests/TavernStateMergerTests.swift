import XCTest
@testable import Relay

final class TavernStateMergerTests: XCTestCase {
    private func makeState(
        charId: Int = 1,
        chatFile: String = "Story - 1.jsonl",
        messages: [TavernMessage],
        unchanged: [Int]? = nil,
        total: Int? = nil,
        hasMore: Bool? = nil
    ) -> TavernChatState {
        TavernChatState(
            status: TavernStatus(enabled: true, ready: true, currentCharacterId: charId, currentChatFile: chatFile),
            character: TavernCharacter(id: charId, name: "Seraphina", chat: chatFile),
            chatFile: chatFile,
            userName: "You",
            messages: messages,
            totalMessageCount: total,
            hasMore: hasMore,
            unchangedMesIds: unchanged
        )
    }

    func testPreservesOlderHistoryAndUnchangedMessagesDuringIncrementalUpdate() {
        let old0 = TavernMessage(mesId: 0, name: "Seraphina", rawText: "0楼开场", renderedHash: "h0")
        let old1 = TavernMessage(mesId: 1, name: "You", isUser: true, rawText: "1楼", renderedHash: "h1")
        let old2 = TavernMessage(
            mesId: 2,
            name: "Seraphina",
            rawText: "2楼完整卡片",
            blocks: [TavernRenderBlock(id: "b2", kind: "markdown", markdown: "2楼完整卡片")],
            renderedHash: "h2"
        )
        let cached = CachedTavernConversation(
            characterId: 1,
            chatFile: "Story - 1.jsonl",
            character: TavernCharacter(id: 1, name: "Seraphina", chat: "Story - 1.jsonl"),
            userName: "You",
            messages: [old0, old1, old2],
            variablesJSON: "{}",
            totalMessageCount: 3,
            hasMore: false,
            updatedAt: 1000
        )

        let new3 = TavernMessage(mesId: 3, name: "You", isUser: true, rawText: "3楼新消息", renderedHash: "h3")
        let new4 = TavernMessage(mesId: 4, name: "Seraphina", rawText: "4楼新回复", renderedHash: "h4")
        let incoming = makeState(
            chatFile: "Story - 1",
            messages: [new3, new4],
            unchanged: [1, 2],
            total: 5,
            hasMore: true
        )

        let merged = TavernStateMerger.merge(incoming: incoming, existing: cached, isReset: false)
        XCTAssertNil(merged.unchangedMesIds)
        XCTAssertEqual(merged.messages.map(\.mesId), [0, 1, 2, 3, 4])
        XCTAssertEqual(merged.messages[2].blocks.count, 1)
        XCTAssertEqual(merged.hasMore, false)
    }

    func testDropsTrimmedTrailingMessagesAndRespectsReset() {
        let old0 = TavernMessage(mesId: 0, name: "Seraphina", rawText: "0楼")
        let old1 = TavernMessage(mesId: 1, name: "You", isUser: true, rawText: "被删楼层")
        let cached = CachedTavernConversation(
            characterId: 1,
            chatFile: "Story - 1.jsonl",
            character: TavernCharacter(id: 1, name: "Seraphina"),
            userName: "You",
            messages: [old0, old1],
            variablesJSON: "{}",
            totalMessageCount: 2,
            hasMore: false,
            updatedAt: 1000
        )

        let fresh0 = TavernMessage(mesId: 0, name: "Seraphina", rawText: "0楼")
        let incomingTrimmed = makeState(messages: [fresh0], total: 1, hasMore: false)
        let mergedTrimmed = TavernStateMerger.merge(incoming: incomingTrimmed, existing: cached, isReset: false)
        XCTAssertEqual(mergedTrimmed.messages.map(\.mesId), [0])

        let resetIncoming = makeState(messages: [TavernMessage(mesId: 5, name: "Seraphina", rawText: "窗口")], hasMore: true)
        let mergedReset = TavernStateMerger.merge(incoming: resetIncoming, existing: cached, isReset: true)
        XCTAssertEqual(mergedReset.messages.map(\.mesId), [5])
        XCTAssertEqual(mergedReset.hasMore, true)
    }
}
