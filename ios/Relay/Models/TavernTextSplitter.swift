import Foundation

// MARK: - Streaming <think> / <thought> splitter

enum TavernTextSplitter {
    static func split(rawText: String, explicitReasoning: String, isStreaming: Bool) -> (reasoning: String, visible: String) {
        let closedTagRegex = #/<(think|thought|thinking)>([\s\S]*?)</\1>/#.ignoresCase()
        let openTagRegex = #/<(?:think|thought|thinking)>([\s\S]*)$/#.ignoresCase()
        let updateVarClosedRegex = #/<UpdateVariable>[\s\S]*?</UpdateVariable>/#.ignoresCase()
        let updateVarOpenRegex = #/<UpdateVariable>[\s\S]*$/#.ignoresCase()
        let statusPlaceholderRegex = #/<StatusPlaceHolderImpl[^>]*>[\s\S]*?</StatusPlaceHolderImpl>/#.ignoresCase()
        let statusPlaceholderSelfClosingRegex = #/<StatusPlaceHolderImpl\s*/?>/#.ignoresCase()
        let commentClosedRegex = #/<comment>[\s\S]*?</comment>/#.ignoresCase()
        let commentOpenRegex = #/<comment>[\s\S]*$/#.ignoresCase()

        var reasoningParts: [String] = []
        let trimmedExplicit = explicitReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExplicit.isEmpty {
            reasoningParts.append(trimmedExplicit)
        }

        var working = rawText
        let closedMatches = working.matches(of: closedTagRegex)
        if !closedMatches.isEmpty {
            for match in closedMatches {
                let inner = match.output.2.trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty && !reasoningParts.contains(inner) {
                    reasoningParts.append(inner)
                }
            }
            working.replace(closedTagRegex, with: "")
        }

        if isStreaming, let match = working.firstMatch(of: openTagRegex) {
            let inner = match.output.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty && !reasoningParts.contains(inner) {
                reasoningParts.append(inner)
            }
            working = String(working[..<match.range.lowerBound])
        }

        working.replace(updateVarClosedRegex, with: "")
        working.replace(updateVarOpenRegex, with: "")
        working.replace(statusPlaceholderRegex, with: "")
        working.replace(statusPlaceholderSelfClosingRegex, with: "")
        working.replace(commentClosedRegex, with: "")
        working.replace(commentOpenRegex, with: "")

        return (
            reasoning: reasoningParts.joined(separator: "\n\n"),
            visible: working.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
