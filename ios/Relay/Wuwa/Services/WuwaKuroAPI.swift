import CryptoKit
import Foundation

enum WuwaAPIError: LocalizedError {
    case invalidInput(String)
    case httpStatus(Int)
    case serverError(String)
    case decodeError(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg), .serverError(let msg), .decodeError(let msg):
            return msg
        case .httpStatus(let code):
            return "库街区接口返回 HTTP \(code)。"
        }
    }
}

struct WuwaConveneCredential: Sendable, Equatable {
    var playerId: String
    var cardPoolId: String
    var serverId: String
    var recordId: String
    var languageCode: String
}

/// Native KuroBBS + CN Convene HTTP client matching WaveShelf's Rust implementation (`community.rs` & `gacha.rs`).
enum WuwaKuroAPI {
    private static let kuroBase = "https://api.kurobbs.com"
    private static let kuroIpUrl = URL(string: "https://event.kurobbs.com/event/ip")!
    private static let kuroVersion = "3.1.3"
    private static let iosUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)  KuroGameBox/3.1.3"
    private static let cnGachaEndpoint = URL(string: "https://gmserver-api.aki-game2.com/gacha/record/query")!
    private static let cnPoolTypes = Array(1...11)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 35
        return URLSession(configuration: config)
    }()

    // MARK: - Auth & Token Verification

    static func validateMobile(_ mobile: String) throws -> String {
        let trimmed = mobile.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard bytes.count == 11,
              bytes[0] == UInt8(ascii: "1"),
              (UInt8(ascii: "3")...UInt8(ascii: "9")).contains(bytes[1]),
              bytes.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            throw WuwaAPIError.invalidInput("请输入有效的中国大陆手机号。")
        }
        return trimmed
    }

    static func maskMobile(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("*") { return trimmed }
        let digits = trimmed.filter(\.isASCII).filter(\.isNumber)
        if digits.count == 11 {
            return "\(digits.prefix(3))****\(digits.suffix(4))"
        }
        return "已绑定手机号"
    }

    static func requestSmsCode(mobile rawMobile: String, captcha: WuwaCaptchaPayload, deviceId: String) async throws {
        let mobile = try validateMobile(rawMobile)
        let geetestObj: [String: String] = [
            "captcha_id": captcha.captchaId,
            "lot_number": captcha.lotNumber,
            "pass_token": captcha.passToken,
            "gen_time": captcha.genTime,
            "captcha_output": captcha.captchaOutput,
        ]
        let geetestData = try JSONSerialization.data(withJSONObject: geetestObj)
        let geetestStr = String(data: geetestData, encoding: .utf8) ?? "{}"

        let headers = loginHeaders(deviceId: deviceId, model: "23127PN0CC", version: "2.5.3", versionCode: nil)
        let payload = try await postForm(
            urlString: "\(kuroBase)/user/getSmsCode",
            headers: headers,
            form: ["mobile": mobile, "geeTestData": geetestStr]
        )
        _ = try apiData(payload, action: "发送验证码")
    }

    static func loginWithSms(mobile rawMobile: String, code rawCode: String, deviceId: String) async throws -> WuwaSecureSession {
        let mobile = try validateMobile(rawMobile)
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...8).contains(code.count), code.allSatisfy(\.isNumber) else {
            throw WuwaAPIError.invalidInput("请输入短信中的数字验证码。")
        }
        let headers = loginHeaders(deviceId: deviceId, model: "android", version: "2.2.0", versionCode: "2200")
        let payload = try await postForm(
            urlString: "\(kuroBase)/user/sdkLogin",
            headers: headers,
            form: ["mobile": mobile, "devCode": deviceId, "code": code]
        )
        let data = try apiData(payload, action: "手机号登录")
        guard let dict = data as? [String: Any] else {
            throw WuwaAPIError.decodeError("库街区登录返回格式异常。")
        }
        let token = jsonString(dict["token"])
        let userId = jsonString(dict["userId"])
        guard !token.isEmpty, !userId.isEmpty else {
            throw WuwaAPIError.decodeError("库街区登录成功，但响应中缺少会话令牌。")
        }
        return WuwaSecureSession(
            token: token,
            deviceId: deviceId,
            mobileMasked: maskMobile(mobile),
            userId: userId,
            userName: jsonString(dict["userName"]),
            signature: jsonString(dict["signature"])
        )
    }

    // MARK: - Community Snapshot & Details

    static func fetchSnapshot(
        session currentSession: WuwaSecureSession,
        requestedRoleId: String? = nil
    ) async throws -> (snapshot: WuwaCommunitySnapshot, resolvedSession: WuwaSecureSession) {
        let headers = authenticatedHeaders(session: currentSession)
        let rolePayload = try await postForm(
            urlString: "\(kuroBase)/gamer/role/list",
            headers: headers,
            form: ["gameId": "3"]
        )
        let roleData = try apiData(rolePayload, action: "读取绑定角色")
        let roles = parseRoles(roleData)

        var notices: [String] = []
        var updatedSession = currentSession
        let profile: WuwaCommunityProfile
        do {
            let fetched = try await fetchProfile(headers: headers, session: currentSession)
            profile = fetched
            if !fetched.userId.isEmpty { updatedSession.userId = fetched.userId }
            if !fetched.userName.isEmpty { updatedSession.userName = fetched.userName }
            if !fetched.mobileMasked.isEmpty { updatedSession.mobileMasked = fetched.mobileMasked }
            if !fetched.signature.isEmpty { updatedSession.signature = fetched.signature }
        } catch {
            notices.append("账号主页暂未更新：\(error.localizedDescription)")
            profile = WuwaCommunityProfile(
                userId: currentSession.userId,
                userName: currentSession.userName,
                mobileMasked: currentSession.mobileMasked,
                signature: currentSession.signature,
                level: 0,
                goldNum: 0
            )
        }

        let selected = roles.first(where: { $0.roleId == requestedRoleId })
            ?? roles.first(where: \.isDefault)
            ?? roles.first
        let selectedRoleId = selected?.roleId

        var resonators: [WuwaResonator] = []
        if let selected {
            do {
                resonators = try await fetchResonators(session: updatedSession, role: selected)
            } catch {
                notices.append("已有角色暂未更新：\(error.localizedDescription)")
            }
        } else {
            notices.append("库街区账号暂未绑定鸣潮国服角色。")
        }

        let snapshot = WuwaCommunitySnapshot(
            loggedIn: true,
            profile: profile,
            roles: roles,
            selectedRoleId: selectedRoleId,
            resonators: resonators,
            lastSyncedAt: ISO8601DateFormatter().string(from: Date()),
            notice: notices.isEmpty ? nil : notices.joined(separator: "；")
        )
        return (snapshot, updatedSession)
    }

    static func fetchResonatorDetail(
        session currentSession: WuwaSecureSession,
        role: WuwaCommunityRole,
        resonatorId: Int
    ) async throws -> WuwaResonatorDetail {
        let headers = try await dataSessionHeaders(session: currentSession, role: role)
        return try await fetchSingleDetail(headers: headers, role: role, resonatorId: resonatorId)
    }

    static func fetchResonatorDetails(
        session currentSession: WuwaSecureSession,
        role: WuwaCommunityRole,
        resonatorIds: [Int]
    ) async throws -> [WuwaResonatorDetail] {
        var seen = Set<Int>()
        let uniqueIds = resonatorIds.filter { $0 > 0 && seen.insert($0).inserted }
        guard !uniqueIds.isEmpty else { return [] }

        let headers = try await dataSessionHeaders(session: currentSession, role: role)
        var results: [WuwaResonatorDetail] = []
        var lastError: Error?

        // Throttle concurrency to 4 matching Rust's buffer_unordered(4)
        var index = 0
        while index < uniqueIds.count {
            let chunk = Array(uniqueIds[index..<min(index + 4, uniqueIds.count)])
            index += 4
            await withTaskGroup(of: Result<WuwaResonatorDetail, Error>.self) { group in
                for rid in chunk {
                    group.addTask {
                        do {
                            return .success(try await fetchSingleDetail(headers: headers, role: role, resonatorId: rid))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await item in group {
                    switch item {
                    case .success(let detail):
                        results.append(detail)
                    case .failure(let error):
                        lastError = error
                    }
                }
            }
        }

        if results.isEmpty, let lastError {
            throw lastError
        }
        return results
    }

    private static func fetchProfile(headers: [String: String], session currentSession: WuwaSecureSession) async throws -> WuwaCommunityProfile {
        let payload = try await postForm(
            urlString: "\(kuroBase)/user/mineV2",
            headers: headers,
            form: ["otherUserId": currentSession.userId.isEmpty ? "0" : currentSession.userId]
        )
        let data = try apiData(payload, action: "读取账号主页")
        let root = (data as? [String: Any]) ?? [:]
        let mine = (root["mine"] as? [String: Any]) ?? root
        let respMobile = jsonString(mine["mobile"])
        return WuwaCommunityProfile(
            userId: fallback(jsonString(mine["userId"]), currentSession.userId),
            userName: fallback(jsonString(mine["userName"]), currentSession.userName),
            mobileMasked: respMobile.isEmpty ? currentSession.mobileMasked : maskMobile(respMobile),
            signature: fallback(jsonString(mine["signature"]), currentSession.signature),
            level: jsonInt(mine["levelTotal"]),
            goldNum: jsonInt(mine["goldNum"])
        )
    }

    private static func fetchResonators(session currentSession: WuwaSecureSession, role: WuwaCommunityRole) async throws -> [WuwaResonator] {
        let headers = try await dataSessionHeaders(session: currentSession, role: role)
        let form = ["gameId": "3", "serverId": role.serverId, "roleId": role.roleId]
        _ = try? await postForm(urlString: "\(kuroBase)/aki/roleBox/akiBox/refreshData", headers: headers, form: form)
        let payload = try await postForm(urlString: "\(kuroBase)/aki/roleBox/akiBox/roleData", headers: headers, form: form)
        let data = try nestedApiData(payload, action: "读取已有角色")
        return parseResonators(data)
    }

    private static func fetchSingleDetail(
        headers: [String: String],
        role: WuwaCommunityRole,
        resonatorId: Int
    ) async throws -> WuwaResonatorDetail {
        let payload = try await postForm(
            urlString: "\(kuroBase)/aki/roleBox/akiBox/getRoleDetail",
            headers: headers,
            form: [
                "gameId": "3",
                "serverId": role.serverId,
                "roleId": role.roleId,
                "channelId": "19",
                "countryCode": "1",
                "id": String(resonatorId),
            ]
        )
        let data = try nestedApiData(payload, action: "读取角色完整面板")
        return try parseResonatorDetail(data)
    }

    private static func dataSessionHeaders(session currentSession: WuwaSecureSession, role: WuwaCommunityRole) async throws -> [String: String] {
        var devCode = iosUserAgent
        if let ip = try? await fetchPublicIP(), !ip.isEmpty {
            devCode = "\(ip), \(iosUserAgent)"
        }
        var tokenHeaders = dataBaseHeaders(devCode: devCode)
        tokenHeaders["token"] = currentSession.token
        tokenHeaders["did"] = currentSession.deviceId
        tokenHeaders["b-at"] = ""

        let payload = try await postForm(
            urlString: "\(kuroBase)/aki/roleBox/requestToken",
            headers: tokenHeaders,
            form: ["serverId": role.serverId, "roleId": role.roleId]
        )
        let data = try nestedApiData(payload, action: "获取角色数据令牌")
        guard let dict = data as? [String: Any], !jsonString(dict["accessToken"]).isEmpty else {
            throw WuwaAPIError.serverError("库街区没有返回角色数据令牌，请重新登录后再试。")
        }
        var headers = dataBaseHeaders(devCode: devCode)
        headers["did"] = currentSession.deviceId
        headers["b-at"] = jsonString(dict["accessToken"])
        return headers
    }

    private static func fetchPublicIP() async throws -> String {
        var req = URLRequest(url: kuroIpUrl)
        req.timeoutInterval = 5
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - CN Convene Gacha Importer

    static func parseConveneURL(_ rawURL: String) throws -> WuwaConveneCredential {
        let sanitized = rawURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .replacingOccurrences(of: "&amp;", with: "&")

        guard let parsed = URL(string: sanitized),
              parsed.scheme?.lowercased() == "https",
              let host = parsed.host?.lowercased() else {
            throw WuwaAPIError.invalidInput("唤取链接必须使用 HTTPS 且格式有效。")
        }

        let belongsTo = { (domain: String) in host == domain || host.hasSuffix(".\(domain)") }
        guard (belongsTo("aki-game.com") || belongsTo("aki-game.net")) && !host.contains("oversea") else {
            throw WuwaAPIError.invalidInput("仅支持鸣潮国服唤取记录链接。")
        }
        guard parsed.path.hasSuffix("/aki/gacha/index.html") else {
            throw WuwaAPIError.invalidInput("这不是鸣潮唤取记录链接。")
        }
        guard let fragment = parsed.fragment,
              let qIndex = fragment.firstIndex(of: "?") else {
            throw WuwaAPIError.invalidInput("链接中缺少唤取参数，请先在游戏内打开“唤取记录”。")
        }
        let queryString = String(fragment[fragment.index(after: qIndex)...])
        var params: [String: String] = [:]
        for item in URLComponents(string: "https://dummy?\(queryString)")?.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }

        if let area = params["svr_area"], !area.isEmpty, area != "cn" {
            throw WuwaAPIError.invalidInput("检测到非国服账号，本版本仅支持国服。")
        }
        func req(_ key: String) throws -> String {
            guard let v = params[key], !v.isEmpty else {
                throw WuwaAPIError.invalidInput("链接缺少必要参数：\(key)")
            }
            return v
        }
        return WuwaConveneCredential(
            playerId: try req("player_id"),
            cardPoolId: try req("resources_id"),
            serverId: try req("svr_id"),
            recordId: try req("record_id"),
            languageCode: params["lang"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-Hans"
        )
    }

    static func fetchConvenePulls(from rawURL: String) async throws -> (playerId: String, records: [WuwaPullRecord], warnings: [String]) {
        let cred = try parseConveneURL(rawURL)
        let importedAt = ISO8601DateFormatter().string(from: Date())
        var allRecords: [WuwaPullRecord] = []
        var warnings: [String] = []
        var successfulPools = 0

        for poolType in cnPoolTypes {
            struct ReqBody: Encodable {
                var playerId: String
                var cardPoolId: String
                var cardPoolType: Int
                var serverId: String
                var recordId: String
                var languageCode: String
            }
            struct RespBody: Decodable {
                var code: Int
                var message: String?
                var data: [ApiPull]?
            }
            struct ApiPull: Decodable {
                var resourceId: Int?
                var qualityLevel: Int
                var resourceType: String?
                var name: String
                var count: Int?
                var time: String
            }

            var req = URLRequest(url: cnGachaEndpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 18
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Waveshelf-iOS/1.0", forHTTPHeaderField: "User-Agent")
            req.httpBody = try JSONEncoder().encode(ReqBody(
                playerId: cred.playerId,
                cardPoolId: cred.cardPoolId,
                cardPoolType: poolType,
                serverId: cred.serverId,
                recordId: cred.recordId,
                languageCode: cred.languageCode
            ))

            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                warnings.append("卡池 \(poolType) 返回 HTTP \(status)")
                continue
            }
            let decoded = try JSONDecoder().decode(RespBody.self, from: data)
            guard decoded.code == 0 else {
                warnings.append("卡池 \(poolType) 获取失败（代码 \(decoded.code)：\(decoded.message ?? "未知错误")）")
                continue
            }
            successfulPools += 1
            var occMap: [String: Int] = [:]
            for pull in decoded.data ?? [] {
                let resourceId = pull.resourceId ?? syntheticResourceId(name: pull.name)
                let occKey = "\(pull.time)|\(resourceId)|\(pull.name)"
                let occ = (occMap[occKey] ?? 0) + 1
                occMap[occKey] = occ
                let id = stablePullId(
                    playerId: cred.playerId,
                    poolType: poolType,
                    pulledAt: pull.time,
                    resourceId: resourceId,
                    name: pull.name,
                    occurrence: occ
                )
                allRecords.append(WuwaPullRecord(
                    id: id,
                    playerId: cred.playerId,
                    poolType: poolType,
                    resourceId: resourceId,
                    qualityLevel: pull.qualityLevel,
                    resourceType: (pull.resourceType?.isEmpty == false) ? pull.resourceType! : "未知",
                    name: pull.name,
                    count: pull.count ?? 1,
                    pulledAt: pull.time,
                    languageCode: cred.languageCode,
                    occurrence: occ,
                    importedAt: importedAt
                ))
            }
            try? await Task.sleep(for: .milliseconds(140))
        }

        guard successfulPools > 0 else {
            throw WuwaAPIError.serverError("没有成功读取任何卡池。临时链接可能已过期，请回到游戏重新打开“唤取记录”后再试。")
        }
        return (cred.playerId, allRecords, warnings)
    }

    private static func syntheticResourceId(name: String) -> Int {
        let digest = Array(SHA256.hash(data: Data(name.utf8)))
        var val: UInt64 = 0
        for i in 0..<8 {
            val = (val << 8) | UInt64(digest[i])
        }
        return -Int(val & 0x7FFF_FFFF_FFFF_FFFF) - 1
    }

    private static func stablePullId(
        playerId: String,
        poolType: Int,
        pulledAt: String,
        resourceId: Int,
        name: String,
        occurrence: Int
    ) -> String {
        let material = "\(playerId)|\(poolType)|\(pulledAt)|\(resourceId)|\(name)|\(occurrence)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTP & Form Encoding

    static func formURLEncoded(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = form.keys.sorted().map { key -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = (form[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func postForm(
        urlString: String,
        headers: [String: String],
        form: [String: String]
    ) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else {
            throw WuwaAPIError.invalidInput("无效的接口地址。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = formURLEncoded(form)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw WuwaAPIError.httpStatus(status)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WuwaAPIError.decodeError("库街区接口返回了无法识别的数据。")
        }
        return obj
    }

    private static func loginHeaders(deviceId: String, model: String, version: String, versionCode: String?) -> [String: String] {
        var h: [String: String] = [
            "osversion": "Android",
            "devcode": deviceId,
            "distinct_id": deviceId,
            "countrycode": "CN",
            "model": model,
            "source": "android",
            "lang": "zh-Hans",
            "version": version,
            "channelid": "2",
            "User-Agent": "okhttp/3.11.0",
        ]
        if let versionCode { h["versioncode"] = versionCode }
        return h
    }

    private static func authenticatedHeaders(session: WuwaSecureSession) -> [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7",
            "User-Agent": "okhttp/3.11.0",
            "source": "android",
            "devcode": session.deviceId,
            "version": "2.5.3",
            "lang": "zh-Hans",
            "countrycode": "CN",
            "token": session.token,
        ]
    }

    private static func dataBaseHeaders(devCode: String) -> [String: String] {
        [
            "User-Agent": iosUserAgent,
            "source": "ios",
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "version": kuroVersion,
            "devcode": devCode,
        ]
    }

    private static func apiData(_ payload: [String: Any], action: String) throws -> Any {
        let code = jsonInt(payload["code"], default: -1)
        if code == 0 || code == 200 {
            return payload["data"] ?? NSNull()
        }
        let msg = fallback(fallback(jsonString(payload["msg"]), jsonString(payload["message"])), "未知错误")
        throw WuwaAPIError.serverError("\(action)失败：\(msg)（代码 \(code)）")
    }

    private static func nestedApiData(_ payload: [String: Any], action: String) throws -> Any {
        let data = try apiData(payload, action: action)
        if let encoded = data as? String,
           let raw = encoded.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: raw) {
            return decoded
        }
        return data
    }

    // MARK: - Parsers (preserving KuroBBS gallery order)

    private static func parseRoles(_ data: Any) -> [WuwaCommunityRole] {
        guard let arr = data as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            let roleId = jsonString(item["roleId"])
            guard !roleId.isEmpty else { return nil }
            return WuwaCommunityRole(
                id: jsonString(item["id"]),
                userId: jsonString(item["userId"]),
                serverId: jsonString(item["serverId"]),
                serverName: jsonString(item["serverName"]),
                roleId: roleId,
                roleName: jsonString(item["roleName"]),
                isDefault: jsonBool(item["isDefault"]),
                gameLevel: jsonString(item["gameLevel"]),
                roleNum: jsonInt(item["roleNum"]),
                phantomPercent: jsonDouble(item["phantomPercent"]),
                achievementCount: jsonInt(item["achievementCount"])
            )
        }
    }

    /// Preserves the native gallery order returned by KuroBBS `roleList` (no sorting by level or pinyin name).
    private static func parseResonators(_ data: Any) -> [WuwaResonator] {
        guard let dict = data as? [String: Any],
              let list = dict["roleList"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let r = parseResonator(item)
            return (r.roleId > 0 && !r.name.isEmpty) ? r : nil
        }
    }

    private static func parseResonator(_ item: [String: Any]) -> WuwaResonator {
        let skin = (item["roleSkin"] as? [String: Any]).flatMap(parseRoleSkin)
        let defaultPic = jsonString(item["rolePicUrl"])
        let pictureUrl = (skin?.pictureUrl.isEmpty == false) ? skin!.pictureUrl : defaultPic
        return WuwaResonator(
            roleId: jsonInt(item["roleId"]),
            name: jsonString(item["roleName"]),
            level: jsonInt(item["level"]),
            breach: jsonInt(item["breach"]),
            iconUrl: jsonString(item["roleIconUrl"]),
            pictureUrl: pictureUrl,
            rarity: jsonInt(item["starLevel"]),
            attributeId: jsonInt(item["attributeId"]),
            attributeName: jsonString(item["attributeName"]),
            weaponTypeId: jsonInt(item["weaponTypeId"]),
            weaponTypeName: jsonString(item["weaponTypeName"]),
            chainLevel: jsonInt(item["chainUnlockNum"]),
            totalSkillLevel: jsonInt(item["totalSkillLevel"]),
            isMainRole: jsonBool(item["isMainRole"]),
            skin: skin
        )
    }

    private static func parseRoleSkin(_ item: [String: Any]) -> WuwaRoleSkin? {
        let pic = jsonString(item["picUrl"])
        let icon = jsonString(item["skinIcon"])
        let name = jsonString(item["skinName"])
        guard !(pic.isEmpty && icon.isEmpty && name.isEmpty) else { return nil }
        return WuwaRoleSkin(
            id: jsonInt(item["skinId"]),
            name: name,
            iconUrl: icon,
            pictureUrl: pic,
            quality: jsonInt(item["quality"]),
            qualityName: jsonString(item["qualityName"]),
            isAddition: jsonBool(item["isAddition"])
        )
    }

    private static func parseResonatorDetail(_ data: Any) throws -> WuwaResonatorDetail {
        guard let dict = data as? [String: Any] else {
            throw WuwaAPIError.decodeError("库街区返回的角色详情为空。")
        }
        var role = parseResonator((dict["role"] as? [String: Any]) ?? [:])
        if role.level == 0 {
            role.level = jsonInt(dict["level"])
        }
        guard role.roleId > 0, !role.name.isEmpty else {
            throw WuwaAPIError.decodeError("库街区返回的角色详情不完整，请稍后重试。")
        }

        let attributes = ((dict["roleAttributeList"] as? [[String: Any]]) ?? [])
            .compactMap { item -> WuwaAttribute? in
                let name = jsonString(item["attributeName"])
                guard !name.isEmpty else { return nil }
                return WuwaAttribute(
                    name: name,
                    value: jsonString(item["attributeValue"]),
                    iconUrl: jsonString(item["iconUrl"]),
                    sort: jsonInt(item["sort"])
                )
            }
            .sorted { $0.sort < $1.sort }

        let bonusRaw = (dict["equipPhantomAddPropList"] as? [[String: Any]])
            ?? (dict["equipPhantomAttributeList"] as? [[String: Any]])
            ?? []
        let bonusAttributes = parseProps(bonusRaw)

        let chains = ((dict["chainList"] as? [[String: Any]]) ?? [])
            .map { item in
                WuwaChain(
                    name: jsonString(item["name"]),
                    description: stripMarkup(jsonString(item["description"])),
                    iconUrl: jsonString(item["iconUrl"]),
                    order: jsonInt(item["order"]),
                    unlocked: jsonBool(item["unlocked"])
                )
            }
            .sorted { $0.order < $1.order }
        role.chainLevel = chains.filter(\.unlocked).count

        let skills = ((dict["skillList"] as? [[String: Any]]) ?? []).compactMap { item -> WuwaSkill? in
            guard let skill = item["skill"] as? [String: Any] else { return nil }
            let name = jsonString(skill["name"])
            guard !name.isEmpty else { return nil }
            return WuwaSkill(
                id: jsonInt(skill["id"]),
                skillType: jsonString(skill["type"]),
                name: name,
                description: stripMarkup(jsonString(skill["description"])),
                iconUrl: jsonString(skill["iconUrl"]),
                level: jsonInt(item["level"])
            )
        }

        let skillBranches = ((dict["skillBranchList"] as? [[String: Any]]) ?? []).compactMap { item -> WuwaSkillBranch? in
            let branchId = jsonInt(item["branchId"])
            let name = jsonString(item["branchName"])
            guard branchId > 0 || !name.isEmpty else { return nil }
            return WuwaSkillBranch(
                branchId: branchId,
                name: name,
                description: stripMarkup(jsonString(item["desc"])),
                iconUrl: fallback(jsonString(item["pic"]), jsonString(item["skillIcon"])),
                activeIconUrl: jsonString(item["activePic"])
            )
        }

        let weapon = (dict["weaponData"] as? [String: Any]).flatMap(parseWeapon)
        let phantomData = (dict["phantomData"] as? [String: Any]) ?? [:]
        let echoes = parseEchoes(phantomData["equipPhantomList"])

        return WuwaResonatorDetail(
            role: role,
            activeBranchId: jsonInt(dict["activeBranchId"]),
            attributes: attributes,
            bonusAttributes: bonusAttributes,
            chains: chains,
            skills: skills,
            skillBranches: skillBranches,
            weapon: weapon,
            echoes: echoes,
            totalEchoCost: jsonInt(phantomData["cost"])
        )
    }

    private static func parseProps(_ raw: Any?) -> [WuwaProp] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            let name = jsonString(item["attributeName"])
            guard !name.isEmpty else { return nil }
            return WuwaProp(
                name: name,
                value: jsonString(item["attributeValue"]),
                iconUrl: jsonString(item["iconUrl"])
            )
        }
    }

    private static func parseWeapon(_ data: [String: Any]) -> WuwaWeapon? {
        guard let w = data["weapon"] as? [String: Any] else { return nil }
        let weaponId = jsonInt(w["weaponId"])
        let name = jsonString(w["weaponName"])
        guard weaponId > 0 || !name.isEmpty else { return nil }
        return WuwaWeapon(
            weaponId: weaponId,
            name: name,
            weaponType: jsonInt(w["weaponType"]),
            rarity: jsonInt(w["weaponStarLevel"]),
            iconUrl: jsonString(w["weaponIcon"]),
            effectName: jsonString(w["weaponEffectName"]),
            effectDescription: stripMarkup(jsonString(w["effectDescription"])),
            level: jsonInt(data["level"]),
            breach: jsonInt(data["breach"]),
            resonanceLevel: jsonInt(data["resonLevel"]),
            mainProps: parseProps(data["mainPropList"])
        )
    }

    private static func parseEchoes(_ raw: Any?) -> [WuwaEcho] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { entry -> WuwaEcho? in
            guard let item = entry as? [String: Any],
                  let phantom = item["phantomProp"] as? [String: Any] else { return nil }
            let name = jsonString(phantom["name"])
            guard !name.isEmpty else { return nil }
            let fetter = (item["fetterDetail"] as? [String: Any]) ?? [:]
            return WuwaEcho(
                phantomId: jsonInt(phantom["phantomId"]),
                name: name,
                iconUrl: jsonString(phantom["iconUrl"]),
                cost: jsonInt(item["cost"]),
                level: jsonInt(item["level"]),
                quality: jsonInt(item["quality"]),
                skillDescription: stripMarkup(jsonString(phantom["skillDescription"])),
                setName: jsonString(fetter["name"]),
                setIconUrl: jsonString(fetter["iconUrl"]),
                setCount: jsonInt(fetter["num"]),
                mainProps: parseProps(item["mainProps"]),
                subProps: parseProps(item["subProps"])
            )
        }
    }

    private static func stripMarkup(_ input: String) -> String {
        let normalized = input
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        var out = ""
        var insideTag = false
        for ch in normalized {
            if ch == "<" { insideTag = true }
            else if ch == ">" { insideTag = false }
            else if !insideTag { out.append(ch) }
        }
        return out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON Primitive Helpers

    private static func fallback(_ primary: String, _ alt: String) -> String {
        primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? alt : primary
    }

    private static func jsonString(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return ""
        }
    }

    private static func jsonInt(_ v: Any?, default def: Int = 0) -> Int {
        switch v {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? def
        default: return def
        }
    }

    private static func jsonDouble(_ v: Any?, default def: Double = 0) -> Double {
        switch v {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? def
        default: return def
        }
    }

    private static func jsonBool(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let i as Int: return i != 0
        case let s as String: return s == "true" || s == "1"
        default: return false
        }
    }
}
