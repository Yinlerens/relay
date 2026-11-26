import XCTest
@testable import Relay

final class WuwaEngineTests: XCTestCase {

    // MARK: - Helpers

    private func prop(_ name: String, _ value: String) -> WuwaProp {
        WuwaProp(name: name, value: value, iconUrl: "")
    }

    private func attr(_ name: String, _ value: String, _ sort: Int) -> WuwaAttribute {
        WuwaAttribute(name: name, value: value, iconUrl: "", sort: sort)
    }

    private func echo(
        _ pid: Int,
        _ name: String,
        _ cost: Int,
        _ setName: String,
        _ mains: [WuwaProp],
        _ subs: [WuwaProp],
        _ skillDesc: String = ""
    ) -> WuwaEcho {
        WuwaEcho(
            phantomId: pid,
            name: name,
            iconUrl: "",
            cost: cost,
            level: 25,
            quality: 5,
            skillDescription: skillDesc,
            setName: setName,
            setIconUrl: "",
            setCount: 5,
            mainProps: mains,
            subProps: subs
        )
    }

    private func makeAimisiTeamDetails() -> [String: WuwaResonatorDetail] {
        let moning = WuwaResonatorDetail(
            role: WuwaResonator(roleId: 1209, name: "莫宁", level: 90, breach: 6, iconUrl: "", pictureUrl: "", rarity: 5, attributeId: 2, attributeName: "热熔", weaponTypeId: 1, weaponTypeName: "长刃", chainLevel: 1, totalSkillLevel: 39, isMainRole: false, skin: nil),
            activeBranchId: 0,
            attributes: [
                attr("生命", "24451", 1000), attr("攻击", "1126", 2000), attr("防御", "3073", 3000),
                attr("谐度破坏增幅", "10", 3500), attr("暴击", "5.0%", 5000), attr("暴击伤害", "213.6%", 6000),
                attr("共鸣效率", "241.0%", 7000), attr("偏谐值累积效率", "100.0%", 7500), attr("治疗效果加成", "22.0%", 27000),
            ],
            bonusAttributes: [prop("防御", "1511"), prop("暴击伤害", "63.6%"), prop("共鸣效率", "89.2%")],
            chains: [
                WuwaChain(name: "缄默的观测者", description: "", iconUrl: "", order: 1, unlocked: true),
                WuwaChain(name: "熵增的启明星", description: "", iconUrl: "", order: 2, unlocked: false),
            ],
            skills: [
                WuwaSkill(id: 689, skillType: "常态攻击", name: "基态校准", description: "", iconUrl: "", level: 6),
                WuwaSkill(id: 690, skillType: "共鸣技能", name: "解算", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 691, skillType: "共鸣解放", name: "临界协议", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 694, skillType: "变奏技能", name: "归敛", description: "", iconUrl: "", level: 1),
                WuwaSkill(id: 695, skillType: "共鸣回路", name: "质能等价", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 696, skillType: "延奏技能", name: "递归", description: "", iconUrl: "", level: 1),
            ],
            skillBranches: [],
            weapon: WuwaWeapon(weaponId: 21010024, name: "异响空灵", weaponType: 1, rarity: 4, iconUrl: "", effectName: "咏叹之音", effectDescription: "", level: 90, breach: 6, resonanceLevel: 5, mainProps: [prop("攻击", "337"), prop("共鸣效率", "51.8%")]),
            echoes: [
                echo(6000190, "炉芯机骸", 4, "星构寻辉之环", [prop("防御", "41.8%"), prop("攻击", "150")], [prop("防御", "10.9%"), prop("暴击伤害", "18.6%")], "在首位装配该声骸技能时，自身共鸣效率提升10.00%。"),
                echo(6000186, "隐迹铁影", 3, "星构寻辉之环", [prop("共鸣效率", "32.0%"), prop("攻击", "100")], [prop("暴击伤害", "16.2%"), prop("共鸣效率", "9.2%")], ""),
                echo(6000184, "探隧重机", 3, "星构寻辉之环", [prop("共鸣效率", "32.0%"), prop("攻击", "100")], [prop("攻击", "10.1%"), prop("暴击伤害", "12.6%")], ""),
                echo(6000177, "岩蛛S4型", 1, "星构寻辉之环", [prop("防御", "18.0%"), prop("生命", "2280")], [prop("防御", "14.7%"), prop("共鸣效率", "6.8%")], ""),
                echo(6000176, "矿岩熊蜂", 1, "星构寻辉之环", [prop("防御", "18.0%"), prop("生命", "2280")], [prop("暴击伤害", "16.2%"), prop("共鸣效率", "9.2%")], ""),
            ],
            totalEchoCost: 12
        )

        let aimisi = WuwaResonatorDetail(
            role: WuwaResonator(roleId: 1210, name: "爱弥斯", level: 90, breach: 6, iconUrl: "", pictureUrl: "", rarity: 5, attributeId: 2, attributeName: "热熔", weaponTypeId: 2, weaponTypeName: "迅刀", chainLevel: 3, totalSkillLevel: 42, isMainRole: false, skin: nil),
            activeBranchId: 121002,
            attributes: [
                attr("生命", "16884", 1000), attr("攻击", "2465", 2000), attr("防御", "1208", 3000),
                attr("谐度破坏增幅", "10", 3500), attr("暴击", "74.8%", 5000), attr("暴击伤害", "283.4%", 6000),
                attr("共鸣效率", "118.4%", 7000), attr("共鸣解放伤害加成", "25.1%", 11000), attr("热熔伤害加成", "52.0%", 14000),
            ],
            bonusAttributes: [prop("攻击", "1332"), prop("暴击", "37.5%"), prop("暴击伤害", "133.4%"), prop("热熔伤害加成", "40.0%")],
            chains: [
                WuwaChain(name: "一链", description: "", iconUrl: "", order: 1, unlocked: true),
                WuwaChain(name: "二链", description: "", iconUrl: "", order: 2, unlocked: true),
                WuwaChain(name: "三链", description: "", iconUrl: "", order: 3, unlocked: true),
            ],
            skills: [
                WuwaSkill(id: 738, skillType: "常态攻击", name: "校准无垠", description: "", iconUrl: "", level: 6),
                WuwaSkill(id: 739, skillType: "共鸣技能", name: "共赴长航", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 740, skillType: "共鸣解放", name: "飞至启明之时", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 743, skillType: "变奏技能", name: "航程伊始", description: "", iconUrl: "", level: 4),
                WuwaSkill(id: 744, skillType: "共鸣回路", name: "为寂静赋形", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 745, skillType: "延奏技能", name: "不可见的守候", description: "", iconUrl: "", level: 1),
            ],
            skillBranches: [
                WuwaSkillBranch(branchId: 121001, name: "共鸣模态·震谐", description: "", iconUrl: "", activeIconUrl: ""),
                WuwaSkillBranch(branchId: 121002, name: "共鸣模态·聚爆", description: "", iconUrl: "", activeIconUrl: ""),
            ],
            weapon: WuwaWeapon(weaponId: 21020076, name: "永远的启明星", weaponType: 2, rarity: 5, iconUrl: "", effectName: "逐星", effectDescription: "", level: 90, breach: 6, resonanceLevel: 1, mainProps: [prop("攻击", "587"), prop("暴击", "24.3%")]),
            echoes: [
                echo(6000191, "辛吉勒姆", 4, "长路启航之星", [prop("暴击伤害", "44.0%"), prop("攻击", "150")], [prop("暴击", "7.5%"), prop("攻击", "10.1%"), prop("暴击伤害", "19.8%")], "在首位装配该声骸技能时，若装配角色为爱弥斯，则自身共鸣解放伤害加成提升25.00%。"),
                echo(6000180, "双极·渊陨重锋", 3, "长路启航之星", [prop("热熔伤害加成", "30.0%"), prop("攻击", "100")], [prop("共鸣解放伤害加成", "8.6%"), prop("暴击", "8.7%"), prop("共鸣效率", "10.0%"), prop("暴击伤害", "18.6%")], ""),
                echo(6000194, "冠顶苍隼", 3, "长路启航之星", [prop("攻击", "30.0%"), prop("攻击", "100")], [prop("暴击伤害", "16.2%"), prop("暴击", "7.5%"), prop("攻击", "10.9%"), prop("共鸣解放伤害加成", "7.1%")], ""),
                echo(6000196, "冰盈舞者", 1, "长路启航之星", [prop("攻击", "18.0%"), prop("生命", "2280")], [prop("暴击", "6.9%"), prop("暴击伤害", "18.6%"), prop("共鸣效率", "8.4%"), prop("共鸣解放伤害加成", "9.4%")], ""),
                echo(6000177, "岩蛛S4型", 1, "长路启航之星", [prop("攻击", "18.0%"), prop("生命", "2280")], [prop("暴击", "6.9%"), prop("攻击", "10.1%"), prop("暴击伤害", "16.2%")], ""),
            ],
            totalEchoCost: 12
        )

        let daniya = WuwaResonatorDetail(
            role: WuwaResonator(roleId: 1211, name: "达妮娅", level: 90, breach: 6, iconUrl: "", pictureUrl: "", rarity: 5, attributeId: 2, attributeName: "热熔", weaponTypeId: 5, weaponTypeName: "音感仪", chainLevel: 0, totalSkillLevel: 44, isMainRole: false, skin: nil),
            activeBranchId: 121102,
            attributes: [
                attr("生命", "16366", 1000), attr("攻击", "2129", 2000), attr("防御", "1509", 3000),
                attr("暴击", "75.5%", 5000), attr("暴击伤害", "294.6%", 6000), attr("共鸣效率", "118.4%", 7000),
                attr("热熔伤害加成", "70.0%", 14000),
            ],
            bonusAttributes: [prop("攻击", "982"), prop("暴击", "34.5%"), prop("暴击伤害", "128.6%"), prop("热熔伤害加成", "70.0%")],
            chains: [],
            skills: [
                WuwaSkill(id: 890, skillType: "常态攻击", name: "织梦", description: "", iconUrl: "", level: 6),
                WuwaSkill(id: 891, skillType: "共鸣技能", name: "泡沫蜜饵", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 892, skillType: "共鸣解放", name: "帷幕终景", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 895, skillType: "变奏技能", name: "谨此致访", description: "", iconUrl: "", level: 6),
                WuwaSkill(id: 896, skillType: "共鸣回路", name: "天衣无缝", description: "", iconUrl: "", level: 10),
                WuwaSkill(id: 897, skillType: "延奏技能", name: "未竟的谎言", description: "", iconUrl: "", level: 1),
            ],
            skillBranches: [],
            weapon: WuwaWeapon(weaponId: 21050076, name: "赝作的矮星", weaponType: 5, rarity: 5, iconUrl: "", effectName: "寂静", effectDescription: "", level: 90, breach: 6, resonanceLevel: 1, mainProps: [prop("攻击", "500"), prop("暴击", "36.0%")]),
            echoes: [
                echo(6000200, "共鸣回响·达妮娅", 4, "斑驳粉饰之沫", [prop("暴击伤害", "44.0%"), prop("攻击", "150")], [prop("暴击", "6.9%"), prop("暴击伤害", "13.8%")], ""),
                echo(6000193, "冠顶械隼", 3, "斑驳粉饰之沫", [prop("热熔伤害加成", "30.0%"), prop("攻击", "100")], [prop("暴击", "6.9%"), prop("攻击", "10.1%"), prop("暴击伤害", "13.8%")], ""),
                echo(6000194, "冠顶苍隼", 3, "斑驳粉饰之沫", [prop("热熔伤害加成", "30.0%"), prop("攻击", "100")], [prop("暴击伤害", "21.0%"), prop("暴击", "6.9%"), prop("共鸣效率", "10.8%")], ""),
                echo(6000197, "影烁者", 1, "斑驳粉饰之沫", [prop("攻击", "18.0%"), prop("生命", "2280")], [prop("暴击伤害", "15.0%"), prop("攻击", "10.1%"), prop("暴击", "6.9%")], ""),
                echo(6000178, "噼啪啪", 1, "斑驳粉饰之沫", [prop("攻击", "18.0%"), prop("生命", "2280")], [prop("暴击伤害", "21.0%"), prop("攻击", "7.9%"), prop("暴击", "6.9%")], ""),
            ],
            totalEchoCost: 12
        )

        return ["1210": aimisi, "1211": daniya, "1209": moning]
    }

    // MARK: - Tests

    func testJSEngineLoadsAndEvaluatesTeamAndLabModules() async throws {
        let presets = try await WuwaJSEngine.shared.listTeamPresets()
        XCTAssertEqual(presets.count, 11)
        XCTAssertTrue(presets.contains(where: { $0.id == "aimisi-daniya-moning" }))

        let details = makeAimisiTeamDetails()
        let evalBundle = try await WuwaJSEngine.shared.evaluateTeam(
            presetId: "aimisi-daniya-moning",
            detailsByRoleId: details,
            options: WuwaCalcOptions(),
            overrides: [:]
        )
        let result = try XCTUnwrap(evalBundle.result)
        XCTAssertGreaterThan(result.totalDpr, 1_000_000)
        XCTAssertGreaterThan(result.teamDps, 40_000)
        XCTAssertEqual(result.contributions.count, 3)
        let shareSum = result.contributions.reduce(0) { $0 + $1.share }
        XCTAssertEqual(shareSum, 1.0, accuracy: 0.001)
        XCTAssertFalse(result.steps.isEmpty)

        // Sandbox override (+3 -> 6链) must increase DPR
        let c6Bundle = try await WuwaJSEngine.shared.evaluateTeam(
            presetId: "aimisi-daniya-moning",
            detailsByRoleId: details,
            options: WuwaCalcOptions(),
            overrides: ["0": WuwaSlotSandboxOverride(chain: 6)]
        )
        let c6 = try XCTUnwrap(c6Bundle.result)
        XCTAssertGreaterThan(c6.totalDpr, result.totalDpr)

        let multi = try await WuwaJSEngine.shared.evaluateMultiGold(
            presetId: "aimisi-daniya-moning",
            detailsByRoleId: details,
            budgetGold: 2,
            options: WuwaCalcOptions(),
            overrides: [:]
        )
        XCTAssertNotNil(multi.multi?.bestPlan)
        XCTAssertGreaterThan(multi.multi?.bestPlan?.gainPct ?? 0, 0)

        let sens = try await WuwaJSEngine.shared.evaluateSensitivity(
            presetId: "aimisi-daniya-moning",
            detailsByRoleId: details,
            slotIndex: 0,
            options: WuwaCalcOptions(),
            overrides: [:]
        )
        XCTAssertFalse(sens.substats.isEmpty)
        XCTAssertTrue(sens.weakestEchoes.contains(where: \.isWeakest))

        let er = try await WuwaJSEngine.shared.evaluateErCheckup(
            presetId: "aimisi-daniya-moning",
            detailsByRoleId: details,
            options: WuwaCalcOptions(),
            overrides: [:]
        )
        XCTAssertEqual(er.count, 3)

        let grad = try await WuwaJSEngine.shared.evaluateGraduation(
            presetId: "aimisi-daniya-moning",
            detailsByRoleId: details,
            slotIndex: 0,
            options: WuwaCalcOptions(),
            overrides: [:]
        )
        XCTAssertNotNil(grad)
    }

    func testJSEngineScoresEchoesAndBuildsGachaPlan() async throws {
        let details = makeAimisiTeamDetails()
        let aimisi = try XCTUnwrap(details["1210"])

        let scored = try await WuwaJSEngine.shared.scoreEchoLoadout(roleId: 1210, echoes: aimisi.echoes)
        XCTAssertGreaterThan(scored.score, 150)
        XCTAssertEqual(scored.echoes.count, 5)

        let timeline = try await WuwaJSEngine.shared.buildResonatorTimeline(detail: aimisi, history: [])
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline[0].echoCount, 5)

        let plan = try await WuwaJSEngine.shared.calculateGachaPlan(
            input: WuwaGachaPlannerInput(
                charPity: 54,
                charGuaranteed: true,
                targetCharCopies: 1,
                weaponPity: 0,
                targetWeaponCopies: 1,
                astrite: 14800,
                radiantTide: 18
            )
        )
        XCTAssertEqual(plan.successProbability, 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(plan.p80, 0)
    }

    func testConveneURLParserAndFormEncoding() throws {
        let valid = "https://aki-gm-resources.aki-game.com/aki/gacha/index.html#/record?svr_id=s1&player_id=104829316&lang=zh-Hans&svr_area=cn&record_id=rec1&resources_id=res1"
        let cred = try WuwaKuroAPI.parseConveneURL(valid)
        XCTAssertEqual(cred.playerId, "104829316")
        XCTAssertEqual(cred.cardPoolId, "res1")
        XCTAssertEqual(cred.serverId, "s1")

        let oversea = valid
            .replacingOccurrences(of: "aki-gm-resources.aki-game.com", with: "aki-gm-resources-oversea.aki-game.net")
            .replacingOccurrences(of: "svr_area=cn", with: "svr_area=global")
        XCTAssertThrowsError(try WuwaKuroAPI.parseConveneURL(oversea))
        XCTAssertThrowsError(try WuwaKuroAPI.parseConveneURL(valid.replacingOccurrences(of: "https://", with: "http://")))

        let encoded = String(data: WuwaKuroAPI.formURLEncoded(["k": "a+b=c&d"]), encoding: .utf8)
        XCTAssertEqual(encoded, "k=a%2Bb%3Dc%26d")
    }

    func testStorageEchoHistoryDeduplicatesAndTracksChanges() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("wuwa-storage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storage = WuwaStorage(directory: tmpDir)

        let details = makeAimisiTeamDetails()
        var aimisi = try XCTUnwrap(details["1210"])

        let h1 = await storage.saveDetail(gameRoleId: "104829316", detail: aimisi, recordedAt: "2026-11-20T10:00:00Z")
        XCTAssertEqual(h1.count, 1)

        // Saving identical echoes + stats must not create duplicate history entry
        let h2 = await storage.saveDetail(gameRoleId: "104829316", detail: aimisi, recordedAt: "2026-11-21T10:00:00Z")
        XCTAssertEqual(h2.count, 1)

        // Changing echo substat creates a second snapshot cleanly
        aimisi.echoes[0].subProps.append(prop("暴击伤害", "12.6%"))
        let h3 = await storage.saveDetail(gameRoleId: "104829316", detail: aimisi, recordedAt: "2026-11-22T10:00:00Z")
        XCTAssertEqual(h3.count, 2)
        XCTAssertEqual(h3[0].recordedAt, "2026-11-22T10:00:00Z")
    }

    func testStorageMergesPCHistoryWithNanosecondTimestampsAndDeduplicates() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("wuwa-merge-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storage = WuwaStorage(directory: tmpDir)

        let details = makeAimisiTeamDetails()
        let baseAimisi = try XCTUnwrap(details["1210"])
        var upgradedAimisi = baseAimisi
        upgradedAimisi.echoes[0].subProps.append(prop("暴击伤害", "12.6%"))

        let fpA = WuwaStorage.computeFingerprint(for: baseAimisi)
        let fpB = WuwaStorage.computeFingerprint(for: upgradedAimisi)
        XCTAssertNotEqual(fpA, fpB)

        // Seed an iOS snapshot matching fpB at a later ISO timestamp
        _ = await storage.saveDetail(gameRoleId: "100385406", detail: upgradedAimisi, recordedAt: "2026-11-26T09:00:00Z")

        // Verify 9-digit Rust Chrono timestamp parses cleanly
        XCTAssertNotNil(WuwaStorage.parseISO8601Timestamp("2026-11-13T20:00:26.978519300+00:00"))

        // Import PC history containing earlier fpA -> fpB (nanosecond timestamps) + returning to fpA later
        let pcEntries: [WuwaResonatorHistoryEntry] = [
            WuwaResonatorHistoryEntry(
                id: 1,
                gameRoleId: "100385406",
                resonatorId: 1210,
                fingerprint: fpA,
                recordedAt: "2026-11-13T20:00:26.978519300+00:00",
                level: 90,
                chainLevel: 3,
                weaponName: "永远的启明星",
                weaponLevel: 90,
                weaponResonanceLevel: 1,
                attributes: baseAimisi.attributes,
                echoes: baseAimisi.echoes,
                detail: baseAimisi
            ),
            WuwaResonatorHistoryEntry(
                id: 2,
                gameRoleId: "100385406",
                resonatorId: 1210,
                fingerprint: fpB,
                recordedAt: "2026-11-22T18:33:39.123456700+00:00",
                level: 90,
                chainLevel: 3,
                weaponName: "永远的启明星",
                weaponLevel: 90,
                weaponResonanceLevel: 1,
                attributes: upgradedAimisi.attributes,
                echoes: upgradedAimisi.echoes,
                detail: upgradedAimisi
            ),
            WuwaResonatorHistoryEntry(
                id: 3,
                gameRoleId: "100385406",
                resonatorId: 1210,
                fingerprint: fpA,
                recordedAt: "2026-11-27T01:00:00Z",
                level: 90,
                chainLevel: 3,
                weaponName: "永远的启明星",
                weaponLevel: 90,
                weaponResonanceLevel: 1,
                attributes: baseAimisi.attributes,
                echoes: baseAimisi.echoes,
                detail: baseAimisi
            ),
        ]

        let merged = await storage.mergeHistories(gameRoleId: "100385406", incoming: pcEntries)
        let list = try XCTUnwrap(merged.byRoleId[1210])
        // fpB from PC (11-22) and local fpB (11-26) fold into 1 entry keeping earlier timestamp (11-22); A->B->A retains 3 entries
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].fingerprint, fpA)
        XCTAssertEqual(list[0].recordedAt, "2026-11-27T01:00:00Z")
        XCTAssertEqual(list[1].fingerprint, fpB)
        XCTAssertEqual(list[1].recordedAt, "2026-11-22T18:33:39.123456700+00:00")
        XCTAssertEqual(list[2].fingerprint, fpA)
        XCTAssertEqual(list[2].recordedAt, "2026-11-13T20:00:26.978519300+00:00")

        // Verify JS engine timeline calculation works on the merged multi-snapshot history
        let timeline = try await WuwaJSEngine.shared.buildResonatorTimeline(detail: baseAimisi, history: list)
        XCTAssertEqual(timeline.count, 3)
        XCTAssertTrue(timeline.last?.isBaseline == true)
        XCTAssertNotNil(timeline[0].scoreDelta)
        XCTAssertGreaterThan(timeline[1].score, timeline[2].score)
    }
}
