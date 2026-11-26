// Pure JS calculation bridge entry for Relay iOS (JavaScriptCore).
// Exposes JSON-in / JSON-out functions under globalThis.WaveShelfEngine.

if (!Array.prototype.toSorted) {
  Object.defineProperty(Array.prototype, "toSorted", {
    value: function <T>(this: T[], compareFn?: (a: T, b: T) => number): T[] {
      return this.slice().sort(compareFn);
    },
    configurable: true,
    writable: true,
  });
}

import {
  getEchoScoreWeightTable,
  gradeForTotalScore,
  scoreEchoLoadout,
} from "../../../../../../Desktop/cc/oo/src/lib/echoScore";
import { buildResonatorTimeline } from "../../../../../../Desktop/cc/oo/src/lib/resonatorTimeline";
import { buildAllPools } from "../../../../../../Desktop/cc/oo/src/lib/gachaHistory";
import {
  calculateGachaPlan,
  type GachaPlannerInput,
} from "../../../../../../Desktop/cc/oo/src/lib/gachaPlanner";
import { evaluateTeamPreset } from "../../../../../../Desktop/cc/oo/src/lib/damage/engine";
import { evaluateTeamErCheckup } from "../../../../../../Desktop/cc/oo/src/lib/damage/erCheckup";
import { evaluateGraduationBenchmarks } from "../../../../../../Desktop/cc/oo/src/lib/damage/graduationBenchmarks";
import {
  evaluateMultiGoldAllocation,
  evaluateNextGoldInvestments,
} from "../../../../../../Desktop/cc/oo/src/lib/damage/nextGoldAdvisor";
import {
  getTeamPresetById,
  TEAM_PRESETS,
} from "../../../../../../Desktop/cc/oo/src/lib/damage/presets";
import {
  applyRotationTuneToPreset,
  type RotationTuneConfig,
} from "../../../../../../Desktop/cc/oo/src/lib/damage/rotationTuner";
import {
  applyTeamSlotOverrides,
  computeChainLadder,
  computeWeaponRankLadder,
  listCompatibleWeapons,
  type TeamSlotOverrides,
} from "../../../../../../Desktop/cc/oo/src/lib/damage/sandbox";
import {
  compareMainStatLoadouts,
  computeSubstatSensitivity,
  findWeakestEcho,
} from "../../../../../../Desktop/cc/oo/src/lib/damage/statSensitivity";
import { buildTeamDamageHistory } from "../../../../../../Desktop/cc/oo/src/lib/damage/teamDamageHistory";
import type {
  CalcOptions,
  RebuiltResonator,
  TeamCalcResult,
  TeamPreset,
} from "../../../../../../Desktop/cc/oo/src/lib/damage/types";
import type {
  CommunityEcho,
  CommunityResonatorDetail,
  PullRecord,
  ResonatorHistoryEntry,
} from "../../../../../../Desktop/cc/oo/src/types";

function safeJsonStringify(value: unknown): string {
  return JSON.stringify(value, (_key, v) => {
    if (typeof v === "number") {
      return Number.isFinite(v) ? v : 0;
    }
    return v;
  });
}

function summarizePreset(preset: TeamPreset) {
  return {
    id: preset.id,
    teamGroup: preset.teamGroup,
    variantLabel: preset.variantLabel ?? null,
    name: preset.name,
    subtitle: preset.subtitle,
    cycleSeconds: preset.cycleSeconds,
    loopCycleSeconds: preset.loopCycleSeconds ?? preset.cycleSeconds,
    slots: preset.slots,
    notes: preset.notes ?? [],
    stepCount: preset.steps.length,
  };
}

function summarizeMember(m: RebuiltResonator) {
  return {
    roleId: m.roleId,
    name: m.name,
    level: m.level,
    chain: m.chain,
    element: m.element,
    activeModal: m.activeModal ?? null,
    modalOverridden: Boolean(m.modalOverridden),
    sonataOverridden: m.sonataOverridden ?? null,
    erOverriddenTo: m.erOverriddenTo ?? null,
    combatPanel: {
      hp: m.combatBasePanel.hp,
      atk: m.combatBasePanel.atk,
      def: m.combatBasePanel.def,
      critRate: m.combatBasePanel.critRate,
      critDmg: m.combatBasePanel.critDmg,
      energyRegen: m.combatBasePanel.energyRegen,
    },
    weaponName: m.detail.weapon?.name ?? null,
    weaponLevel: m.detail.weapon?.level ?? null,
    weaponRank: m.detail.weapon?.resonanceLevel ?? null,
    mainEchoBonusSummary: m.mainEchoBonus?.summary ?? null,
    verification: m.verification,
  };
}

function serializeTeamResult(res: TeamCalcResult | null) {
  if (!res) return null;
  return {
    preset: summarizePreset(res.preset),
    mode: res.mode,
    cycleSeconds: res.cycleSeconds,
    enemyLevel: res.enemyLevel,
    enemyBaseRes: res.enemyBaseRes,
    stageCritDmg: res.stageCritDmg,
    stageDmgBonus: res.stageDmgBonus,
    stageElement: res.stageElement,
    members: res.members.map(summarizeMember),
    totalDpr: res.totalDpr,
    teamDps: res.teamDps,
    contributions: res.contributions,
    steps: res.steps.map((s) => ({
      stepId: s.step.id,
      phase: s.step.phase,
      actorSlot: s.actorSlot,
      label: s.step.label,
      kind: s.step.kind,
      actorName: s.actorName,
      actorRoleId: s.actorRoleId,
      element: s.element,
      damageTag: s.damageTag,
      nonCritDamage: s.nonCritDamage,
      critDamage: s.critDamage,
      expectedDamage: s.expectedDamage,
      share: s.share,
      tailHit: s.tailHit ?? null,
      breakdown: s.breakdown,
    })),
  };
}

function normalizeOverrides(
  raw?: Record<string, unknown> | null,
): TeamSlotOverrides | undefined {
  if (!raw) return undefined;
  const out: TeamSlotOverrides = {};
  for (const idx of [0, 1, 2] as const) {
    const val = (raw[String(idx)] ?? (raw as Record<number, unknown>)[idx]) as
      | TeamSlotOverrides[0]
      | undefined;
    if (val) out[idx] = val;
  }
  return Object.keys(out).length ? out : undefined;
}

const api = {
  version(): string {
    return "3.8-ios-bridge-1";
  },

  listTeamPresetsJSON(): string {
    return safeJsonStringify(TEAM_PRESETS.map(summarizePreset));
  },

  scoreEchoLoadoutJSON(roleId: number, echoesJson: string): string {
    const echoes = JSON.parse(echoesJson) as CommunityEcho[];
    return safeJsonStringify(scoreEchoLoadout(roleId, echoes));
  },

  gradeForTotalScore(score: number): string {
    return gradeForTotalScore(score);
  },

  getEchoScoreWeightTableJSON(roleId: number, attributeName: string): string {
    return safeJsonStringify(getEchoScoreWeightTable(roleId, attributeName));
  },

  buildResonatorTimelineJSON(detailJson: string, historyEntriesJson: string): string {
    const detail = JSON.parse(detailJson) as CommunityResonatorDetail | null;
    const entries = JSON.parse(historyEntriesJson) as ResonatorHistoryEntry[];
    return safeJsonStringify(buildResonatorTimeline(detail, entries));
  },

  buildAllPoolsJSON(pullsJson: string): string {
    const pulls = JSON.parse(pullsJson) as PullRecord[];
    return safeJsonStringify(buildAllPools(pulls));
  },

  calculateGachaPlanJSON(inputJson: string): string {
    const input = JSON.parse(inputJson) as GachaPlannerInput;
    const res = calculateGachaPlan(input);
    return safeJsonStringify({
      normalizedInput: res.normalizedInput,
      effectiveCharCopies: res.effectiveCharCopies,
      appliedCoralChains: res.appliedCoralChains,
      directCoralCost: res.directCoralCost,
      cdf: res.cdf,
      maxPulls: res.maxPulls,
      resources: res.resources,
      successProbability: res.successProbability,
      expectedPulls: res.expectedPulls,
      expectedCharPulls: res.expectedCharPulls,
      expectedWeaponPulls: res.expectedWeaponPulls,
      p50: res.p50,
      p80: res.p80,
      p90: res.p90,
      p95: res.p95,
      milestones: res.milestones,
    });
  },

  listCompatibleWeaponsJSON(weaponTypeId: number): string {
    return safeJsonStringify(listCompatibleWeapons(weaponTypeId));
  },

  evaluateTeamJSON(payloadJson: string): string {
    const payload = JSON.parse(payloadJson) as {
      presetId: string;
      detailsByRoleId: Record<string, CommunityResonatorDetail>;
      options?: CalcOptions;
      overrides?: Record<string, unknown>;
      rotationTune?: RotationTuneConfig;
    };
    const basePreset = getTeamPresetById(payload.presetId);
    if (!basePreset) {
      return safeJsonStringify({ baseResult: null, result: null });
    }
    const details = payload.detailsByRoleId as unknown as Record<number, CommunityResonatorDetail>;
    const overrides = normalizeOverrides(payload.overrides);
    const effectiveDetails = applyTeamSlotOverrides(basePreset, details, overrides);
    const tunedPreset = payload.rotationTune
      ? applyRotationTuneToPreset(basePreset, payload.rotationTune)
      : basePreset;

    const baseResult = evaluateTeamPreset(basePreset, details, payload.options);
    const currentResult = evaluateTeamPreset(tunedPreset, effectiveDetails, payload.options);

    return safeJsonStringify({
      baseResult: serializeTeamResult(baseResult),
      result: serializeTeamResult(currentResult),
    });
  },

  evaluateMultiGoldJSON(payloadJson: string): string {
    const payload = JSON.parse(payloadJson) as {
      presetId: string;
      detailsByRoleId: Record<string, CommunityResonatorDetail>;
      budgetGold: number;
      options?: CalcOptions;
      overrides?: Record<string, unknown>;
    };
    const preset = getTeamPresetById(payload.presetId);
    if (!preset) return "null";
    const details = payload.detailsByRoleId as unknown as Record<number, CommunityResonatorDetail>;
    const overrides = normalizeOverrides(payload.overrides);
    const multi = evaluateMultiGoldAllocation(
      preset,
      details,
      payload.budgetGold,
      payload.options,
      overrides,
    );
    const nextSingle = evaluateNextGoldInvestments(
      preset,
      details,
      payload.options,
      overrides,
    );
    return safeJsonStringify({ multi, nextSingle });
  },

  evaluateSandboxLaddersJSON(payloadJson: string): string {
    const payload = JSON.parse(payloadJson) as {
      presetId: string;
      detailsByRoleId: Record<string, CommunityResonatorDetail>;
      slotIndex: 0 | 1 | 2;
      options?: CalcOptions;
      overrides?: Record<string, unknown>;
    };
    const preset = getTeamPresetById(payload.presetId);
    if (!preset) return safeJsonStringify({ chainLadder: [], weaponRankLadder: [] });
    const details = payload.detailsByRoleId as unknown as Record<number, CommunityResonatorDetail>;
    const overrides = normalizeOverrides(payload.overrides);
    return safeJsonStringify({
      chainLadder: computeChainLadder(preset, details, payload.slotIndex, payload.options, overrides),
      weaponRankLadder: computeWeaponRankLadder(preset, details, payload.slotIndex, payload.options, overrides),
    });
  },

  evaluateSensitivityJSON(payloadJson: string): string {
    const payload = JSON.parse(payloadJson) as {
      presetId: string;
      detailsByRoleId: Record<string, CommunityResonatorDetail>;
      slotIndex: 0 | 1 | 2;
      options?: CalcOptions;
      overrides?: Record<string, unknown>;
    };
    const preset = getTeamPresetById(payload.presetId);
    if (!preset) return safeJsonStringify({ substats: [], mainStats: [], weakestEchoes: [] });
    const details = applyTeamSlotOverrides(
      preset,
      payload.detailsByRoleId as unknown as Record<number, CommunityResonatorDetail>,
      normalizeOverrides(payload.overrides),
    );
    return safeJsonStringify({
      substats: computeSubstatSensitivity(preset, details, payload.slotIndex, payload.options),
      mainStats: compareMainStatLoadouts(preset, details, payload.slotIndex, payload.options),
      weakestEchoes: findWeakestEcho(preset, details, payload.slotIndex, payload.options),
    });
  },

  evaluateGraduationJSON(payloadJson: string): string {
    const payload = JSON.parse(payloadJson) as {
      presetId: string;
      detailsByRoleId: Record<string, CommunityResonatorDetail>;
      slotIndex: 0 | 1 | 2;
      options?: CalcOptions;
      overrides?: Record<string, unknown>;
    };
    const preset = getTeamPresetById(payload.presetId);
    if (!preset) return "null";
    const details = payload.detailsByRoleId as unknown as Record<number, CommunityResonatorDetail>;
    return safeJsonStringify(
      evaluateGraduationBenchmarks(
        preset,
        details,
        payload.slotIndex,
        payload.options,
        normalizeOverrides(payload.overrides),
      ),
    );
  },

  evaluateErCheckupJSON(payloadJson: string): string {
    const payload = JSON.parse(payloadJson) as {
      presetId: string;
      detailsByRoleId: Record<string, CommunityResonatorDetail>;
      options?: CalcOptions;
      overrides?: Record<string, unknown>;
    };
    const preset = getTeamPresetById(payload.presetId);
    if (!preset) return "[]";
    const details = applyTeamSlotOverrides(
      preset,
      payload.detailsByRoleId as unknown as Record<number, CommunityResonatorDetail>,
      normalizeOverrides(payload.overrides),
    );
    const evalRes = evaluateTeamPreset(preset, details, payload.options);
    if (!evalRes) return "[]";
    return safeJsonStringify(evaluateTeamErCheckup(evalRes));
  },

  evaluateTeamHistoryJSON(payloadJson: string): string {
    const payload = JSON.parse(payloadJson) as {
      presetId: string;
      detailsByRoleId: Record<string, CommunityResonatorDetail>;
      historiesByRoleId: Record<string, ResonatorHistoryEntry[]>;
      options?: CalcOptions;
    };
    const preset = getTeamPresetById(payload.presetId);
    if (!preset) return "null";
    const currentDetails = payload.detailsByRoleId as unknown as Record<
      number,
      CommunityResonatorDetail
    >;
    const historiesByRoleId = payload.historiesByRoleId as unknown as Record<
      number,
      ResonatorHistoryEntry[]
    >;
    return safeJsonStringify(
      buildTeamDamageHistory({
        preset,
        currentDetails,
        historiesByRoleId,
        calcOptions: payload.options ?? {},
      }),
    );
  },
};

(globalThis as unknown as { WaveShelfEngine: typeof api }).WaveShelfEngine = api;
