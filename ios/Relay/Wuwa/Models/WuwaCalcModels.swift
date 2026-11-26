import Foundation

// MARK: - Echo Scoring

struct WuwaEchoPropScore: Codable, Sendable, Equatable {
    var prop: WuwaProp
    var score: Double
    var importance: String
    var maxRoll: Bool
}

struct WuwaEchoItemScore: Codable, Sendable, Equatable {
    var echo: WuwaEcho
    var score: Double
    var grade: String
    var mainProps: [WuwaEchoPropScore]
    var subProps: [WuwaEchoPropScore]
}

struct WuwaEchoLoadoutScore: Codable, Sendable, Equatable {
    var score: Double
    var maxScore: Double
    var grade: String
    var template: String
    var fallback: Bool
    var echoes: [WuwaEchoItemScore]
}

struct WuwaEchoWeightRow: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var cost4: Double?
    var cost3: Double?
    var cost1: Double?
    var sub: Double?
    var importance: String

    var id: String { name }
}

struct WuwaEchoWeightTable: Codable, Sendable, Equatable {
    var template: String
    var rows: [WuwaEchoWeightRow]
    var scoreMax: [Double]
}

// MARK: - Resonator Growth / Echo History Timeline

struct WuwaTimelineStatItem: Codable, Sendable, Equatable, Identifiable {
    var key: String
    var label: String
    var valueText: String
    var prevValueText: String?
    var diffText: String?
    var diffDir: String?

    var id: String { key }
}

struct WuwaComputedTimelineItem: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var recordedAtLabel: String
    var level: Int
    var chainLevel: Int
    var weaponName: String
    var weaponLevel: Int
    var weaponResonanceLevel: Int
    var echoCount: Int
    var score: Double
    var grade: String
    var scoreDelta: Double?
    var milestones: [String]
    var isBaseline: Bool
    var stats: [WuwaTimelineStatItem]
}

// MARK: - Gacha History & Planner

struct WuwaFiveStarEntry: Codable, Sendable, Equatable, Identifiable {
    var record: WuwaPullRecord
    var pulls: Int
    var outcome: String?

    var id: String { record.id }
}

struct WuwaUpCharacterGoldCount: Codable, Sendable, Equatable, Identifiable {
    var resourceId: Int
    var name: String
    var count: Int

    var id: Int { resourceId }
}

struct WuwaLimitedAnalysis: Codable, Sendable, Equatable {
    var enabled: Bool
    var outcomes: [String: String]
    var upCount: Int
    var offCount: Int
    var smallPityWins: Int
    var smallPityAttempts: Int
    var smallPityWinRate: Double?
    var averagePullsPerUp: Double?
    var upCharacters: [WuwaUpCharacterGoldCount]
}

struct WuwaPoolHistory: Codable, Sendable, Equatable, Identifiable {
    var poolType: Int
    var name: String
    var shortName: String
    var total: Int
    var fourStars: Int
    var currentPity: Int
    var averagePity: Double?
    var fiveStars: [WuwaFiveStarEntry]
    var limited: WuwaLimitedAnalysis
    var guaranteed: Bool?

    var id: Int { poolType }
}

struct WuwaGachaPlannerInput: Codable, Sendable, Equatable {
    var charPity: Int = 0
    var charGuaranteed: Bool = false
    var targetCharCopies: Int = 1
    var weaponPity: Int = 0
    var targetWeaponCopies: Int = 1
    var astrite: Int = 14800
    var radiantTide: Int = 18
    var forgingTide: Int = 0
    var coralPulls: Int = 0
    var coralDirectChains: Int = 0
}

struct WuwaPercentileEstimate: Codable, Sendable, Equatable {
    var quantile: Double
    var totalPulls: Int
    var universalPullsNeeded: Int
    var missingPulls: Int
    var missingAstrite: Int
}

struct WuwaGachaPlannerResources: Codable, Sendable, Equatable {
    var astrite: Int
    var astritePulls: Int
    var astriteRemainder: Int
    var radiantTide: Int
    var forgingTide: Int
    var coralPulls: Int
    var universalPulls: Int
    var totalNominalPulls: Int
    var effectiveUsablePulls: Int
}

struct WuwaGachaPlanMilestones: Codable, Sendable, Equatable {
    var p50: WuwaPercentileEstimate
    var p80: WuwaPercentileEstimate
    var p90: WuwaPercentileEstimate
    var p95: WuwaPercentileEstimate
    var hardCap: WuwaPercentileEstimate
}

struct WuwaGachaPlanResult: Codable, Sendable, Equatable {
    var effectiveCharCopies: Int
    var appliedCoralChains: Int
    var directCoralCost: Int
    var cdf: [Double]
    var maxPulls: Int
    var resources: WuwaGachaPlannerResources
    var successProbability: Double
    var expectedPulls: Double
    var expectedCharPulls: Double
    var expectedWeaponPulls: Double
    var p50: Int
    var p80: Int
    var p90: Int
    var p95: Int
    var milestones: WuwaGachaPlanMilestones
}

// MARK: - Damage Calc Lab

struct WuwaSlotSpec: Codable, Sendable, Equatable, Identifiable {
    var roleId: Int
    var name: String
    var roleLabel: String
    var forceModal: String?
    var forceSonata5pc: String?
    var minEnergyRegen: Double?

    var id: Int { roleId }
}

struct WuwaTeamPresetSummary: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var teamGroup: String
    var variantLabel: String?
    var name: String
    var subtitle: String
    var cycleSeconds: Double
    var loopCycleSeconds: Double
    var slots: [WuwaSlotSpec]
    var notes: [String]
    var stepCount: Int
}

struct WuwaCalcOptions: Codable, Sendable, Equatable {
    var mode: String = "loop"
    var enemyLevel: Int = 100
    var enemyBaseRes: Double = 0.1
    var stageCritDmg: Double = 0
    var stageDmgBonus: Double = 0
    var stageElement: String = "all"
}

struct WuwaSlotSandboxOverride: Codable, Sendable, Equatable {
    var chain: Int?
    var weaponId: Int?
    var weaponRank: Int?
    var allSkillsLv10: Bool?
    var customEchoes: [WuwaEcho]?

    var isEmpty: Bool {
        chain == nil && weaponId == nil && weaponRank == nil && allSkillsLv10 == nil && customEchoes == nil
    }
}

struct WuwaCompatibleWeapon: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var starLevel: Int
    var weaponType: Int
    var baseAtkLv90: Int
    var subPropName: String
    var subPropValue: String
}

struct WuwaLadderPoint: Codable, Sendable, Equatable, Identifiable {
    var stepValue: Int
    var label: String
    var totalDpr: Double
    var teamDps: Double
    var deltaDpr: Double
    var gainPct: Double
    var isCurrent: Bool

    var id: Int { stepValue }
}

struct WuwaSandboxLadders: Codable, Sendable, Equatable {
    var chainLadder: [WuwaLadderPoint]
    var weaponRankLadder: [WuwaLadderPoint]
}

struct WuwaPanelDiffItem: Codable, Sendable, Equatable, Identifiable {
    var label: String
    var kuroValue: String
    var rebuiltValue: String
    var combatValue: String
    var delta: Double
    var aligned: Bool

    var id: String { label }
}

struct WuwaPanelVerification: Codable, Sendable, Equatable {
    var allAligned: Bool
    var items: [WuwaPanelDiffItem]
}

struct WuwaCombatPanelSummary: Codable, Sendable, Equatable {
    var hp: Double
    var atk: Double
    var def: Double
    var critRate: Double
    var critDmg: Double
    var energyRegen: Double
}

struct WuwaRebuiltMemberSummary: Codable, Sendable, Equatable, Identifiable {
    var roleId: Int
    var name: String
    var level: Int
    var chain: Int
    var element: String
    var activeModal: String?
    var modalOverridden: Bool
    var sonataOverridden: String?
    var erOverriddenTo: Double?
    var combatPanel: WuwaCombatPanelSummary
    var weaponName: String?
    var weaponLevel: Int?
    var weaponRank: Int?
    var mainEchoBonusSummary: String?
    var verification: WuwaPanelVerification

    var id: Int { roleId }
}

struct WuwaMemberContribution: Codable, Sendable, Equatable, Identifiable {
    var slotIndex: Int
    var roleId: Int
    var name: String
    var totalDamage: Double
    var dps: Double
    var share: Double

    var id: Int { slotIndex }
}

struct WuwaTailHitBreakdown: Codable, Sendable, Equatable {
    var hitCount: Int
    var ratio: Double
    var nonCritDamage: Double
    var critDamage: Double
    var expectedDamage: Double
}

struct WuwaStepBreakdown: Codable, Sendable, Equatable {
    var statUsed: String
    var effectiveStat: Double
    var rawMultiplier: Double
    var multBonus: Double
    var flatMultAdd: Double
    var dmgBonus: Double
    var deepen: Double
    var critRate: Double
    var critDmg: Double
    var critExpectedMult: Double
    var vuln: Double
    var unisonFinalDmg: Double
    var tuneBreakBoost: Double?
    var tuneStrainFinalDmg: Double?
    var defMult: Double
    var defIgnoreTotal: Double
    var resMult: Double
    var effectiveRes: Double
    var sources: [String]
}

struct WuwaStepDamageResult: Codable, Sendable, Equatable, Identifiable {
    var stepId: String
    var phase: String
    var actorSlot: Int
    var label: String
    var kind: String
    var actorName: String
    var actorRoleId: Int
    var element: String
    var damageTag: String
    var nonCritDamage: Double
    var critDamage: Double
    var expectedDamage: Double
    var share: Double
    var tailHit: WuwaTailHitBreakdown?
    var breakdown: WuwaStepBreakdown

    var id: String { "\(stepId)-\(actorSlot)-\(label)" }
}

struct WuwaTeamCalcResult: Codable, Sendable, Equatable {
    var preset: WuwaTeamPresetSummary
    var mode: String
    var cycleSeconds: Double
    var enemyLevel: Int
    var enemyBaseRes: Double
    var stageCritDmg: Double
    var stageDmgBonus: Double
    var stageElement: String
    var members: [WuwaRebuiltMemberSummary]
    var totalDpr: Double
    var teamDps: Double
    var contributions: [WuwaMemberContribution]
    var steps: [WuwaStepDamageResult]
}

struct WuwaTeamEvalBundle: Codable, Sendable, Equatable {
    var baseResult: WuwaTeamCalcResult?
    var result: WuwaTeamCalcResult?
}

struct WuwaSlotInvestmentAction: Codable, Sendable, Equatable, Identifiable {
    var slotIndex: Int
    var roleId: Int
    var roleName: String
    var roleLabel: String
    var costGold: Int
    var chainFrom: Int
    var chainTo: Int
    var weaponFromLabel: String
    var weaponToLabel: String
    var actionSummary: String

    var id: String { "\(slotIndex)-\(actionSummary)" }
}

struct WuwaMultiGoldPlan: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var totalGold: Int
    var actions: [WuwaSlotInvestmentAction]
    var summaryTitle: String
    var newDpr: Double
    var newDps: Double
    var deltaDpr: Double
    var deltaDps: Double
    var gainPct: Double
    var gainPctPerGold: Double
    var teamOverrides: [String: WuwaSlotSandboxOverride]
}

struct WuwaGreedyTrapWarning: Codable, Sendable, Equatable {
    var greedyPlan: WuwaMultiGoldPlan
    var optimalPlan: WuwaMultiGoldPlan
    var extraDpr: Double
    var extraGainPct: Double
    var message: String
}

struct WuwaFrontierStep: Codable, Sendable, Equatable, Identifiable {
    var gold: Int
    var bestPlan: WuwaMultiGoldPlan
    var marginalGainPct: Double
    var isSweetSpot: Bool
    var sweetSpotReason: String?

    var id: Int { gold }
}

struct WuwaMultiGoldAllocationReport: Codable, Sendable, Equatable {
    var baseDpr: Double
    var baseDps: Double
    var budgetGold: Int
    var maxAvailableGold: Int
    var topPlansForBudget: [WuwaMultiGoldPlan]
    var bestPlan: WuwaMultiGoldPlan?
    var greedyTrap: WuwaGreedyTrapWarning?
    var frontier: [WuwaFrontierStep]
}

struct WuwaNextGoldCandidate: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var slotIndex: Int
    var roleId: Int
    var roleName: String
    var roleLabel: String
    var kind: String
    var costGold: Int
    var title: String
    var fromLabel: String
    var toLabel: String
    var newDpr: Double
    var newDps: Double
    var deltaDpr: Double
    var deltaDps: Double
    var gainPct: Double
    var gainPctPerGold: Double
    var sandboxOverride: WuwaSlotSandboxOverride
    var note: String?
}

struct WuwaNextGoldReport: Codable, Sendable, Equatable {
    var baseDpr: Double
    var baseDps: Double
    var bestSingleGold: WuwaNextGoldCandidate?
    var singleGoldCandidates: [WuwaNextGoldCandidate]
    var milestoneCandidates: [WuwaNextGoldCandidate]
}

struct WuwaMultiGoldBundle: Codable, Sendable, Equatable {
    var multi: WuwaMultiGoldAllocationReport?
    var nextSingle: WuwaNextGoldReport?
}

struct WuwaSubstatGainItem: Codable, Sendable, Equatable, Identifiable {
    var propName: String
    var rollValueText: String
    var newDpr: Double
    var deltaDpr: Double
    var gainPct: Double
    var relativeWeight: Double

    var id: String { "\(propName)-\(rollValueText)" }
}

struct WuwaMainStatComparisonItem: Codable, Sendable, Equatable, Identifiable {
    var group: String
    var label: String
    var totalDpr: Double
    var deltaDpr: Double
    var gainPct: Double
    var isCurrentApprox: Bool

    var id: String { "\(group)-\(label)" }
}

struct WuwaEchoWeaknessItem: Codable, Sendable, Equatable, Identifiable {
    var echoIndex: Int
    var echoName: String
    var cost: Int
    var setName: String
    var echoScore: Double
    var grade: String
    var dprWithoutSubstats: Double
    var substatDprGain: Double
    var substatGainPct: Double
    var isWeakest: Bool

    var id: Int { echoIndex }
}

struct WuwaSensitivityBundle: Codable, Sendable, Equatable {
    var substats: [WuwaSubstatGainItem]
    var mainStats: [WuwaMainStatComparisonItem]
    var weakestEchoes: [WuwaEchoWeaknessItem]
}

struct WuwaBenchmarkTierResult: Codable, Sendable, Equatable {
    var tierId: String
    var title: String
    var badge: String
    var rollTierDesc: String
    var substatFormula: String
    var bestMainStatSummary: String
    var echoScore: Double
    var echoGrade: String
    var teamDpr: Double
    var teamDps: Double
    var actorDamage: Double
    var currentVsTierTeamRatio: Double
    var currentVsTierActorRatio: Double
    var gapTeamPct: Double
    var gapActorPct: Double
    var templateEchoes: [WuwaEcho]
}

struct WuwaGraduationReport: Codable, Sendable, Equatable {
    var slotIndex: Int
    var roleId: Int
    var roleName: String
    var bestSkillPropName: String?
    var currentTeamDpr: Double
    var currentActorDamage: Double
    var currentEchoScore: Double
    var currentEchoGrade: String
    var smallGrad: WuwaBenchmarkTierResult
    var bigGrad: WuwaBenchmarkTierResult
    var maxCeiling: WuwaBenchmarkTierResult
    var progressOnScale: Double
    var verdictTitle: String
    var verdictDetail: String
}

struct WuwaMemberErCheckup: Codable, Sendable, Equatable, Identifiable {
    var slotIndex: Int
    var roleId: Int
    var roleName: String
    var roleLabel: String
    var standingEr: Double
    var combatPanelEr: Double
    var effectiveCombatEr: Double
    var cycleTargetEr: Double
    var capTargetEr: Double?
    var capNote: String?
    var deficitToCycle: Double
    var deficitToCap: Double
    var status: String
    var statusLabel: String
    var advice: String

    var id: Int { slotIndex }
}

struct WuwaTeamHistoryMemberChange: Codable, Sendable, Equatable, Identifiable {
    var slotIndex: Int
    var roleId: Int
    var name: String
    var element: String
    var milestones: [String]
    var statDiffs: [WuwaTimelineStatItem]

    var id: Int { slotIndex }
}

struct WuwaTeamHistoryMemberDamage: Codable, Sendable, Equatable, Identifiable {
    var slotIndex: Int
    var roleId: Int
    var name: String
    var element: String
    var totalDamage: Double
    var dps: Double
    var share: Double
    var damageDelta: Double?

    var id: Int { slotIndex }
}

struct WuwaTeamDamageHistoryPoint: Codable, Sendable, Equatable, Identifiable {
    var key: String
    var recordedAt: String
    var recordedAtLabel: String
    var isBaseline: Bool
    var dpr: Double
    var dps: Double
    var cycleSeconds: Double
    var dprDelta: Double?
    var dprDeltaPct: Double?
    var dpsDelta: Double?
    var members: [WuwaTeamHistoryMemberDamage]
    var changes: [WuwaTeamHistoryMemberChange]

    var id: String { key }
}

struct WuwaTeamDamageHistorySummary: Codable, Sendable, Equatable {
    var points: [WuwaTeamDamageHistoryPoint]
    var chronological: [WuwaTeamDamageHistoryPoint]
    var netDprDelta: Double?
    var netDprDeltaPct: Double?
    var netDpsDelta: Double?
    var peakDpr: Double
    var minDpr: Double
}
