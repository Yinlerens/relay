import XCTest
@testable import Relay

final class TavernTextSplitterTests: XCTestCase {
    func testSplitsClosedThinkingAndStripsInternalTags() {
        let raw = """
        <think>第一段思考</think>
        <UpdateVariable>{"hp": 90}</UpdateVariable>
        <StatusPlaceHolderImpl />
        真正的剧情回复在这里。
        <comment>内部注释</comment>
        """
        let res = TavernTextSplitter.split(rawText: raw, explicitReasoning: "", isStreaming: false)
        XCTAssertEqual(res.reasoning, "第一段思考")
        XCTAssertEqual(res.visible, "真正的剧情回复在这里。")
    }

    func testExtractsOpenThinkingAndIncompleteTagsDuringStreaming() {
        let raw = """
        可见前半段
        <thought>仍在流式思考中…
        """
        let res = TavernTextSplitter.split(rawText: raw, explicitReasoning: "", isStreaming: true)
        XCTAssertEqual(res.reasoning, "仍在流式思考中…")
        XCTAssertEqual(res.visible, "可见前半段")

        let partialVar = "你好<UpdateVariable>{\"hp\":"
        let resVar = TavernTextSplitter.split(rawText: partialVar, explicitReasoning: "独立推理", isStreaming: true)
        XCTAssertEqual(resVar.reasoning, "独立推理")
        XCTAssertEqual(resVar.visible, "你好")
    }

    func testDeduplicatesIdenticalExplicitAndTagReasoning() {
        let raw = "<thinking>相同内容</thinking>\n\n正文。"
        let res = TavernTextSplitter.split(rawText: raw, explicitReasoning: "相同内容", isStreaming: false)
        XCTAssertEqual(res.reasoning, "相同内容")
        XCTAssertEqual(res.visible, "正文。")
    }
}
