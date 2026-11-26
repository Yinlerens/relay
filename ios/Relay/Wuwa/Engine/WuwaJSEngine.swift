import Foundation
import JavaScriptCore

enum WuwaJSError: LocalizedError {
    case scriptNotFound
    case contextInitFailed
    case exception(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "未在应用资源中找到 waveshelf-engine.js。"
        case .contextInitFailed:
            return "无法初始化 JavaScriptCore 计算引擎。"
        case .exception(let message):
            return "计算引擎异常：\(message)"
        case .emptyResult:
            return "计算引擎返回空结果。"
        }
    }
}

/// Runs WaveShelf's bundled TypeScript damage, echo scoring, timeline & gacha math natively in iOS JavaScriptCore.
actor WuwaJSEngine {
    static let shared = WuwaJSEngine()

    private let bundle: Bundle
    private var context: JSContext?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Presets & Echo Scoring

    func listTeamPresets() throws -> [WuwaTeamPresetSummary] {
        try callJSON("listTeamPresetsJSON", args: [], as: [WuwaTeamPresetSummary].self)
    }

    func scoreEchoLoadout(roleId: Int, echoes: [WuwaEcho]) throws -> WuwaEchoLoadoutScore {
        let echoesJSON = try encodeString(echoes)
        return try callJSON("scoreEchoLoadoutJSON", args: [roleId, echoesJSON], as: WuwaEchoLoadoutScore.self)
    }

    func echoWeightTable(roleId: Int, attributeName: String) throws -> WuwaEchoWeightTable {
        try callJSON("getEchoScoreWeightTableJSON", args: [roleId, attributeName], as: WuwaEchoWeightTable.self)
    }

    func buildResonatorTimeline(
        detail: WuwaResonatorDetail,
        history: [WuwaResonatorHistoryEntry]
    ) throws -> [WuwaComputedTimelineItem] {
        let detailJSON = try encodeString(detail)
        let historyJSON = try encodeString(history)
        return try callJSON(
            "buildResonatorTimelineJSON",
            args: [detailJSON, historyJSON],
            as: [WuwaComputedTimelineItem].self
        )
    }

    // MARK: - Gacha

    func buildAllPools(pulls: [WuwaPullRecord]) throws -> [WuwaPoolHistory] {
        let pullsJSON = try encodeString(pulls)
        return try callJSON("buildAllPoolsJSON", args: [pullsJSON], as: [WuwaPoolHistory].self)
    }

    func calculateGachaPlan(input: WuwaGachaPlannerInput) throws -> WuwaGachaPlanResult {
        let inputJSON = try encodeString(input)
        return try callJSON("calculateGachaPlanJSON", args: [inputJSON], as: WuwaGachaPlanResult.self)
    }

    // MARK: - Calc Lab

    func listCompatibleWeapons(weaponTypeId: Int) throws -> [WuwaCompatibleWeapon] {
        try callJSON("listCompatibleWeaponsJSON", args: [weaponTypeId], as: [WuwaCompatibleWeapon].self)
    }

    func evaluateTeam(
        presetId: String,
        detailsByRoleId: [String: WuwaResonatorDetail],
        options: WuwaCalcOptions,
        overrides: [String: WuwaSlotSandboxOverride]
    ) throws -> WuwaTeamEvalBundle {
        struct Payload: Encodable {
            var presetId: String
            var detailsByRoleId: [String: WuwaResonatorDetail]
            var options: WuwaCalcOptions
            var overrides: [String: WuwaSlotSandboxOverride]
        }
        let json = try encodeString(Payload(
            presetId: presetId,
            detailsByRoleId: detailsByRoleId,
            options: options,
            overrides: overrides
        ))
        return try callJSON("evaluateTeamJSON", args: [json], as: WuwaTeamEvalBundle.self)
    }

    func evaluateMultiGold(
        presetId: String,
        detailsByRoleId: [String: WuwaResonatorDetail],
        budgetGold: Int,
        options: WuwaCalcOptions,
        overrides: [String: WuwaSlotSandboxOverride]
    ) throws -> WuwaMultiGoldBundle {
        struct Payload: Encodable {
            var presetId: String
            var detailsByRoleId: [String: WuwaResonatorDetail]
            var budgetGold: Int
            var options: WuwaCalcOptions
            var overrides: [String: WuwaSlotSandboxOverride]
        }
        let json = try encodeString(Payload(
            presetId: presetId,
            detailsByRoleId: detailsByRoleId,
            budgetGold: budgetGold,
            options: options,
            overrides: overrides
        ))
        return try callJSON("evaluateMultiGoldJSON", args: [json], as: WuwaMultiGoldBundle.self)
    }

    func evaluateSandboxLadders(
        presetId: String,
        detailsByRoleId: [String: WuwaResonatorDetail],
        slotIndex: Int,
        options: WuwaCalcOptions,
        overrides: [String: WuwaSlotSandboxOverride]
    ) throws -> WuwaSandboxLadders {
        struct Payload: Encodable {
            var presetId: String
            var detailsByRoleId: [String: WuwaResonatorDetail]
            var slotIndex: Int
            var options: WuwaCalcOptions
            var overrides: [String: WuwaSlotSandboxOverride]
        }
        let json = try encodeString(Payload(
            presetId: presetId,
            detailsByRoleId: detailsByRoleId,
            slotIndex: slotIndex,
            options: options,
            overrides: overrides
        ))
        return try callJSON("evaluateSandboxLaddersJSON", args: [json], as: WuwaSandboxLadders.self)
    }

    func evaluateSensitivity(
        presetId: String,
        detailsByRoleId: [String: WuwaResonatorDetail],
        slotIndex: Int,
        options: WuwaCalcOptions,
        overrides: [String: WuwaSlotSandboxOverride]
    ) throws -> WuwaSensitivityBundle {
        struct Payload: Encodable {
            var presetId: String
            var detailsByRoleId: [String: WuwaResonatorDetail]
            var slotIndex: Int
            var options: WuwaCalcOptions
            var overrides: [String: WuwaSlotSandboxOverride]
        }
        let json = try encodeString(Payload(
            presetId: presetId,
            detailsByRoleId: detailsByRoleId,
            slotIndex: slotIndex,
            options: options,
            overrides: overrides
        ))
        return try callJSON("evaluateSensitivityJSON", args: [json], as: WuwaSensitivityBundle.self)
    }

    func evaluateGraduation(
        presetId: String,
        detailsByRoleId: [String: WuwaResonatorDetail],
        slotIndex: Int,
        options: WuwaCalcOptions,
        overrides: [String: WuwaSlotSandboxOverride]
    ) throws -> WuwaGraduationReport? {
        struct Payload: Encodable {
            var presetId: String
            var detailsByRoleId: [String: WuwaResonatorDetail]
            var slotIndex: Int
            var options: WuwaCalcOptions
            var overrides: [String: WuwaSlotSandboxOverride]
        }
        let json = try encodeString(Payload(
            presetId: presetId,
            detailsByRoleId: detailsByRoleId,
            slotIndex: slotIndex,
            options: options,
            overrides: overrides
        ))
        return try callOptionalJSON("evaluateGraduationJSON", args: [json], as: WuwaGraduationReport.self)
    }

    func evaluateErCheckup(
        presetId: String,
        detailsByRoleId: [String: WuwaResonatorDetail],
        options: WuwaCalcOptions,
        overrides: [String: WuwaSlotSandboxOverride]
    ) throws -> [WuwaMemberErCheckup] {
        struct Payload: Encodable {
            var presetId: String
            var detailsByRoleId: [String: WuwaResonatorDetail]
            var options: WuwaCalcOptions
            var overrides: [String: WuwaSlotSandboxOverride]
        }
        let json = try encodeString(Payload(
            presetId: presetId,
            detailsByRoleId: detailsByRoleId,
            options: options,
            overrides: overrides
        ))
        return try callJSON("evaluateErCheckupJSON", args: [json], as: [WuwaMemberErCheckup].self)
    }

    func evaluateTeamHistory(
        presetId: String,
        detailsByRoleId: [String: WuwaResonatorDetail],
        historiesByRoleId: [String: [WuwaResonatorHistoryEntry]],
        options: WuwaCalcOptions
    ) throws -> WuwaTeamDamageHistorySummary? {
        struct Payload: Encodable {
            var presetId: String
            var detailsByRoleId: [String: WuwaResonatorDetail]
            var historiesByRoleId: [String: [WuwaResonatorHistoryEntry]]
            var options: WuwaCalcOptions
        }
        let json = try encodeString(Payload(
            presetId: presetId,
            detailsByRoleId: detailsByRoleId,
            historiesByRoleId: historiesByRoleId,
            options: options
        ))
        return try callOptionalJSON("evaluateTeamHistoryJSON", args: [json], as: WuwaTeamDamageHistorySummary.self)
    }

    // MARK: - Low-level Bridge

    private func ensureContext() throws -> JSContext {
        if let context { return context }
        guard let url = bundle.url(forResource: "waveshelf-engine", withExtension: "js")
            ?? Bundle(for: BundleAnchor.self).url(forResource: "waveshelf-engine", withExtension: "js") else {
            throw WuwaJSError.scriptNotFound
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let ctx = JSContext() else {
            throw WuwaJSError.contextInitFailed
        }
        ctx.exceptionHandler = { ctxRef, value in
            ctxRef?.exception = value
        }
        ctx.evaluateScript(source, withSourceURL: url)
        if let exc = ctx.exception, !exc.isUndefined {
            throw WuwaJSError.exception(exc.toString() ?? "Unknown JS Error")
        }
        self.context = ctx
        return ctx
    }

    private func encodeString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func rawCall(_ method: String, args: [Any]) throws -> String {
        let ctx = try ensureContext()
        ctx.exception = nil
        guard let engine = ctx.objectForKeyedSubscript("WaveShelfEngine"), !engine.isUndefined else {
            throw WuwaJSError.contextInitFailed
        }
        let fn = engine.objectForKeyedSubscript(method)
        guard let fn, !fn.isUndefined else {
            throw WuwaJSError.exception("Missing WaveShelfEngine.\(method)")
        }
        let result = fn.call(withArguments: args)
        if let exc = ctx.exception, !exc.isUndefined {
            throw WuwaJSError.exception(exc.toString() ?? "Unknown JS error")
        }
        guard let str = result?.toString() else {
            throw WuwaJSError.emptyResult
        }
        return str
    }

    private func callJSON<T: Decodable>(_ method: String, args: [Any], as type: T.Type) throws -> T {
        let raw = try rawCall(method, args: args)
        guard let data = raw.data(using: .utf8) else {
            throw WuwaJSError.emptyResult
        }
        return try decoder.decode(T.self, from: data)
    }

    private func callOptionalJSON<T: Decodable>(_ method: String, args: [Any], as type: T.Type) throws -> T? {
        let raw = try rawCall(method, args: args).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == "null" || raw == "undefined" {
            return nil
        }
        guard let data = raw.data(using: .utf8) else {
            return nil
        }
        return try decoder.decode(T.self, from: data)
    }
}

private final class BundleAnchor {}
