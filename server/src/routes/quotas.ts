import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import type { FastifyInstance } from "fastify";
import type { AppConfig } from "../config.js";

const execFileAsync = promisify(execFile);

const CACHE_TTL_MS = 30_000;
const AGY_TIMEOUT_MS = 15_000;
const UTC8_OFFSET_MS = 8 * 60 * 60 * 1000;
const CODEBUDDY_CONSOLE_URL = "https://copilot.tencent.com/console";
const CODEBUDDY_NOTE =
  "CodeBuddy CLI 不直接返回账户剩余总额度；此处精确统计本机累计/当月/今日消耗，可点下方前往控制台查看剩余总积分。";

export interface AntigravityQuotaBucket {
  id: string;
  name: string;
  description: string;
  window: string;
  remainingFraction: number;
  resetTime: string | null;
}

export interface AntigravityQuotaGroup {
  name: string;
  description: string;
  buckets: AntigravityQuotaBucket[];
}

export interface AntigravityQuotaInfo {
  available: boolean;
  error: string | null;
  description: string;
  remainingCredits: number;
  upgradeUri: string | null;
  groups: AntigravityQuotaGroup[];
}

export interface CodeBuddyModelSummary {
  modelId: string;
  credits: number;
  savedCredits: number;
  calls: number;
  totalTokens: number;
}

export interface CodeBuddyRateQuota {
  model: string;
  percent: number;
  resetAt: number;
}

export interface CodeBuddyQuotaInfo {
  available: boolean;
  error: string | null;
  todayCredits: number;
  monthCredits: number;
  totalCredits: number;
  totalSavedCredits: number;
  byModel: CodeBuddyModelSummary[];
  rateQuotas: CodeBuddyRateQuota[];
  consoleUrl: string;
  note: string;
}

export interface QuotaOverview {
  updatedAt: number;
  antigravity: AntigravityQuotaInfo;
  codebuddy: CodeBuddyQuotaInfo;
}

function round4(n: number): number {
  return Math.round(n * 10_000) / 10_000;
}

/** Parse JSON from CLI stdout even if leading or trailing log lines are present. */
export function parseJsonFromStdout(stdout: string): Record<string, unknown> {
  const trimmed = stdout.trim();
  if (!trimmed) {
    throw new Error("Empty CLI output");
  }
  try {
    return JSON.parse(trimmed) as Record<string, unknown>;
  } catch {
    // Fallback: inspect lines starting with '{' or slice first '{' to last '}'
  }
  for (const line of trimmed.split(/\r?\n/)) {
    const candidate = line.trim();
    if (candidate.startsWith("{") && candidate.endsWith("}")) {
      try {
        return JSON.parse(candidate) as Record<string, unknown>;
      } catch {
        // continue
      }
    }
  }
  const firstBrace = trimmed.indexOf("{");
  const lastBrace = trimmed.lastIndexOf("}");
  if (firstBrace !== -1 && lastBrace > firstBrace) {
    return JSON.parse(trimmed.slice(firstBrace, lastBrace + 1)) as Record<string, unknown>;
  }
  throw new Error("Unable to locate JSON object in CLI output");
}

function resolveAgyBinary(homeDir: string): string {
  const candidate = path.join(homeDir, ".local", "bin", "agy");
  return fs.existsSync(candidate) ? candidate : "agy";
}

function buildExecEnv(homeDir: string): NodeJS.ProcessEnv {
  const localBin = path.join(homeDir, ".local", "bin");
  const currentPath = process.env.PATH || "";
  const sep = path.delimiter;
  const nextPath = currentPath.includes(localBin) ? currentPath : `${localBin}${sep}${currentPath}`;
  return { ...process.env, PATH: nextPath };
}

async function fetchAntigravityQuotas(homeDir: string): Promise<AntigravityQuotaInfo> {
  const bin = resolveAgyBinary(homeDir);
  const env = buildExecEnv(homeDir);

  try {
    const [usageResult, creditsResult] = await Promise.allSettled([
      execFileAsync(bin, ["-p", "/usage", "--output-format", "json"], {
        timeout: AGY_TIMEOUT_MS,
        env,
        maxBuffer: 2 * 1024 * 1024,
      }),
      execFileAsync(bin, ["-p", "/credits", "--output-format", "json"], {
        timeout: AGY_TIMEOUT_MS,
        env,
        maxBuffer: 2 * 1024 * 1024,
      }),
    ]);

    if (usageResult.status === "rejected") {
      throw usageResult.reason;
    }

    const usageJson = parseJsonFromStdout(usageResult.value.stdout);
    const usageData = ((usageJson.command as Record<string, unknown> | undefined)?.data ??
      {}) as Record<string, unknown>;

    const rawGroups = Array.isArray(usageData.groups)
      ? (usageData.groups as Array<Record<string, unknown>>)
      : [];

    const groups: AntigravityQuotaGroup[] = rawGroups.map((g) => {
      const rawBuckets = Array.isArray(g.buckets)
        ? (g.buckets as Array<Record<string, unknown>>)
        : [];
      const buckets: AntigravityQuotaBucket[] = rawBuckets.map((b) => ({
        id: String(b.id ?? ""),
        name: String(b.name ?? ""),
        description: String(b.description ?? ""),
        window: String(b.window ?? ""),
        remainingFraction:
          typeof b.remaining_fraction === "number" && Number.isFinite(b.remaining_fraction)
            ? b.remaining_fraction
            : typeof b.remainingFraction === "number" && Number.isFinite(b.remainingFraction)
              ? b.remainingFraction
              : 0,
        resetTime:
          typeof b.reset_time === "string"
            ? b.reset_time
            : typeof b.resetTime === "string"
              ? b.resetTime
              : null,
      }));

      return {
        name: String(g.name ?? ""),
        description: String(g.description ?? ""),
        buckets,
      };
    });

    let remainingCredits = 0;
    let upgradeUri: string | null = null;
    if (creditsResult.status === "fulfilled") {
      try {
        const creditsJson = parseJsonFromStdout(creditsResult.value.stdout);
        const creditsData = ((creditsJson.command as Record<string, unknown> | undefined)?.data ??
          {}) as Record<string, unknown>;
        if (
          typeof creditsData.remaining_credits === "number" &&
          Number.isFinite(creditsData.remaining_credits)
        ) {
          remainingCredits = creditsData.remaining_credits;
        }
        if (typeof creditsData.upgrade_uri === "string" && creditsData.upgrade_uri) {
          upgradeUri = creditsData.upgrade_uri;
        }
      } catch {
        // Non-fatal: keep defaults if /credits output could not be parsed
      }
    }

    return {
      available: true,
      error: null,
      description: String(usageData.description ?? ""),
      remainingCredits,
      upgradeUri,
      groups,
    };
  } catch (err) {
    return {
      available: false,
      error: err instanceof Error ? err.message : String(err),
      description: "",
      remainingCredits: 0,
      upgradeUri: null,
      groups: [],
    };
  }
}

function parseTimestampMs(raw: unknown): number {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return raw < 1e12 ? raw * 1000 : raw;
  }
  if (typeof raw === "string" && raw.trim()) {
    const asNum = Number(raw);
    if (Number.isFinite(asNum)) {
      return asNum < 1e12 ? asNum * 1000 : asNum;
    }
    const parsed = Date.parse(raw);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return 0;
}

/** Aggregate CodeBuddy credit usage & rate quotas from local project JSONL logs. */
export function scanCodeBuddyQuotas(projectsDir: string, nowMs = Date.now()): CodeBuddyQuotaInfo {
  try {
    const nowSh = new Date(nowMs + UTC8_OFFSET_MS);
    const todayStartMs =
      Date.UTC(nowSh.getUTCFullYear(), nowSh.getUTCMonth(), nowSh.getUTCDate()) - UTC8_OFFSET_MS;
    const monthStartMs =
      Date.UTC(nowSh.getUTCFullYear(), nowSh.getUTCMonth(), 1) - UTC8_OFFSET_MS;

    let todayCredits = 0;
    let monthCredits = 0;
    let totalCredits = 0;
    let totalSavedCredits = 0;

    const modelMap = new Map<string, CodeBuddyModelSummary>();
    const quotaLatestMap = new Map<string, { tsMs: number; quota: CodeBuddyRateQuota }>();

    if (fs.existsSync(projectsDir)) {
      const projEntries = fs.readdirSync(projectsDir, { withFileTypes: true });
      for (const entry of projEntries) {
        if (!entry.isDirectory()) continue;
        const projPath = path.join(projectsDir, entry.name);
        const files = fs.readdirSync(projPath, { withFileTypes: true });
        for (const file of files) {
          if (!file.isFile() || !file.name.endsWith(".jsonl")) continue;
          const filePath = path.join(projPath, file.name);
          const content = fs.readFileSync(filePath, "utf8");
          for (const line of content.split(/\r?\n/)) {
            if (!line.trim()) continue;
            let obj: Record<string, unknown>;
            try {
              obj = JSON.parse(line) as Record<string, unknown>;
            } catch {
              continue;
            }
            const pd = obj.providerData as Record<string, unknown> | undefined;
            const rawUsage = pd?.rawUsage as Record<string, unknown> | undefined;
            if (!rawUsage || typeof rawUsage !== "object") continue;

            const tsMs = parseTimestampMs(obj.timestamp);
            const rawCredit =
              typeof rawUsage.credit === "number" && Number.isFinite(rawUsage.credit)
                ? rawUsage.credit
                : 0;
            const origCredit =
              typeof rawUsage.original_credit === "number" &&
              Number.isFinite(rawUsage.original_credit)
                ? rawUsage.original_credit
                : null;
            const saved = origCredit !== null ? Math.max(0, origCredit - rawCredit) : 0;
            const tokens =
              typeof rawUsage.total_tokens === "number" && Number.isFinite(rawUsage.total_tokens)
                ? rawUsage.total_tokens
                : 0;

            totalCredits += rawCredit;
            totalSavedCredits += saved;
            if (tsMs >= monthStartMs) {
              monthCredits += rawCredit;
            }
            if (tsMs >= todayStartMs) {
              todayCredits += rawCredit;
            }

            const firstCall = Array.isArray(rawUsage.model_calls)
              ? (rawUsage.model_calls[0] as Record<string, unknown> | undefined)
              : undefined;
            const modelId = String(pd?.requestModelId || firstCall?.model || "unknown");

            const prev = modelMap.get(modelId) || {
              modelId,
              credits: 0,
              savedCredits: 0,
              calls: 0,
              totalTokens: 0,
            };
            prev.credits = round4(prev.credits + rawCredit);
            prev.savedCredits = round4(prev.savedCredits + saved);
            prev.calls += 1;
            prev.totalTokens += tokens;
            modelMap.set(modelId, prev);

            const q = rawUsage.quota as Record<string, unknown> | undefined;
            if (q && typeof q === "object" && typeof q.model === "string" && q.model) {
              const resetAt = parseTimestampMs(q.reset_at ?? q.resetAt);
              const percent =
                typeof q.percent === "number" && Number.isFinite(q.percent) ? q.percent : 0;
              const existing = quotaLatestMap.get(q.model);
              if (!existing || tsMs >= existing.tsMs) {
                quotaLatestMap.set(q.model, {
                  tsMs,
                  quota: { model: q.model, percent, resetAt },
                });
              }
            }
          }
        }
      }
    }

    const byModel = Array.from(modelMap.values()).sort(
      (a, b) => b.credits - a.credits || b.calls - a.calls || b.totalTokens - a.totalTokens
    );
    const rateQuotas = Array.from(quotaLatestMap.values())
      .map((entry) => entry.quota)
      .sort((a, b) => a.model.localeCompare(b.model));

    return {
      available: true,
      error: null,
      todayCredits: round4(todayCredits),
      monthCredits: round4(monthCredits),
      totalCredits: round4(totalCredits),
      totalSavedCredits: round4(totalSavedCredits),
      byModel,
      rateQuotas,
      consoleUrl: CODEBUDDY_CONSOLE_URL,
      note: CODEBUDDY_NOTE,
    };
  } catch (err) {
    return {
      available: false,
      error: err instanceof Error ? err.message : String(err),
      todayCredits: 0,
      monthCredits: 0,
      totalCredits: 0,
      totalSavedCredits: 0,
      byModel: [],
      rateQuotas: [],
      consoleUrl: CODEBUDDY_CONSOLE_URL,
      note: CODEBUDDY_NOTE,
    };
  }
}

export function registerQuotaRoutes(app: FastifyInstance, config: AppConfig): void {
  let cachedOverview: QuotaOverview | null = null;
  let cachedAt = 0;

  app.get<{ Querystring: { refresh?: string } }>("/api/quotas", async (req) => {
    const forceRefresh = req.query?.refresh === "1" || req.query?.refresh === "true";
    const now = Date.now();
    if (!forceRefresh && cachedOverview && now - cachedAt < CACHE_TTL_MS) {
      return cachedOverview;
    }

    const codebuddyProjectsDir = path.join(config.homeDir, ".codebuddy", "projects");
    const [antigravity, codebuddy] = await Promise.all([
      fetchAntigravityQuotas(config.homeDir),
      Promise.resolve(scanCodeBuddyQuotas(codebuddyProjectsDir, now)),
    ]);

    const overview: QuotaOverview = {
      updatedAt: Date.now(),
      antigravity,
      codebuddy,
    };
    cachedOverview = overview;
    cachedAt = overview.updatedAt;
    return overview;
  });
}
