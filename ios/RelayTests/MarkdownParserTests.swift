import XCTest
@testable import Relay

final class MarkdownParserTests: XCTestCase {
    func testHeadingsListsQuotesTablesAndRules() {
        let md = """
        # 标题一
        ## 标题二 ##

        正文段落第一行
        正文段落第二行

        - 项目一
          续行内容
        - [ ] 待办
        - [x] 已完成
        1. 有序项

        > 引用行一
        > 引用行二

        | 列A | 列B |
        | --- | --- |
        | 1 | 2 |

        ---
        """

        let nodes = MarkdownParser.parse(md)
        XCTAssertEqual(nodes.count, 7)

        guard case .heading(1, "标题一") = nodes[0].block else { return XCTFail("Expected h1") }
        guard case .heading(2, "标题二") = nodes[1].block else { return XCTFail("Expected h2") }
        guard case .paragraph("正文段落第一行\n正文段落第二行") = nodes[2].block else { return XCTFail("Expected paragraph") }
        guard case .list(let items) = nodes[3].block else { return XCTFail("Expected list") }
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].text, "项目一\n续行内容")
        XCTAssertEqual(items[1].marker, .task(false))
        XCTAssertEqual(items[2].marker, .task(true))
        XCTAssertEqual(items[3].marker, .number("1"))
        guard case .quote("引用行一\n引用行二") = nodes[4].block else { return XCTFail("Expected quote") }
        guard case .table(let rows) = nodes[5].block else { return XCTFail("Expected table") }
        XCTAssertEqual(rows, [["列A", "列B"], ["1", "2"]])
        guard case .rule = nodes[6].block else { return XCTFail("Expected rule") }
    }

    func testFencedCodeBlockAndGluedClosingFenceRecovery() {
        let md = """
        ```swift
        let x = 1
        ```这是粘连的正文
        """
        let nodes = MarkdownParser.parse(md)
        XCTAssertEqual(nodes.count, 2)
        guard case .code("swift", "let x = 1", true) = nodes[0].block else {
            return XCTFail("Expected closed swift code block, got \(nodes)")
        }
        guard case .paragraph("这是粘连的正文") = nodes[1].block else {
            return XCTFail("Expected recovered trailing prose, got \(nodes)")
        }
    }

    func testTrailingInlineFenceSplitsAndNonAsciiStrayFenceStrips() {
        let md = """
        这是前缀```python
        print("ok")
        ```

        ```这里是误开的围栏正文
        """
        let nodes = MarkdownParser.parse(md)
        XCTAssertEqual(nodes.count, 3)
        guard case .paragraph("这是前缀") = nodes[0].block else {
            return XCTFail("Expected split prefix, got \(nodes)")
        }
        guard case .code("python", "print(\"ok\")", true) = nodes[1].block else {
            return XCTFail("Expected python code block, got \(nodes)")
        }
        guard case .paragraph("这里是误开的围栏正文") = nodes[2].block else {
            return XCTFail("Expected stripped non-ASCII stray fence, got \(nodes)")
        }
    }

    func testInlineTripleBackticksRemainParagraph() {
        let md = "你可以运行 ```npm test``` 来验证结果。"
        let nodes = MarkdownParser.parse(md)
        XCTAssertEqual(nodes.count, 1)
        guard case .paragraph(md) = nodes[0].block else {
            return XCTFail("Expected single paragraph, got \(nodes)")
        }
    }

    func testMermaidTopologyBlockParsingAndBundleResource() {
        let md = """
        ### 一、全景架构拓扑

        ```mermaid
        flowchart TB
            subgraph Clients["终端与外部调用方"]
                IOS["Relay 原生 iOS App (SwiftUI / SideStore)"]
            end
            subgraph Apps["业务应用层 (127.0.0.1 内网回环)"]
                RELAY["Relay Control Plane (:18660)"]
            end
            IOS -->|"code.apps.makima.sbs (HTTPS/WSS)"| RELAY
        ```
        """
        let nodes = MarkdownParser.parse(md)
        XCTAssertEqual(nodes.count, 2)
        guard case .heading(3, "一、全景架构拓扑") = nodes[0].block else {
            return XCTFail("Expected heading, got \(nodes)")
        }
        guard case .code(let lang, let body, let closed) = nodes[1].block else {
            return XCTFail("Expected mermaid code block, got \(nodes)")
        }
        XCTAssertEqual(lang, "mermaid")
        XCTAssertTrue(closed)
        XCTAssertTrue(body.contains("flowchart TB"))
        XCTAssertTrue(body.contains("subgraph Clients"))
        XCTAssertTrue(MarkdownParser.isMermaidLanguage(lang))
        XCTAssertTrue(MarkdownParser.isMermaidLanguage("MERMAID"))
        XCTAssertTrue(MarkdownParser.isMermaidLanguage("mmd"))
        XCTAssertFalse(MarkdownParser.isMermaidLanguage("swift"))
        let mermaidBundleURL =
            Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            ?? Bundle(for: MermaidAssetSchemeHandler.self).url(forResource: "mermaid.min", withExtension: "js")
        XCTAssertNotNil(mermaidBundleURL)
    }
}
