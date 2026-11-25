import crypto from "node:crypto";
import fs from "node:fs";
import type { AgentProfile, AppConfig } from "../config.js";
import type {
  MessageRecord,
  MessageStatus,
  RelayDatabase,
  SessionSummary,
} from "../db.js";
import { sendBarkNotification } from "../utils/bark.js";
import { AcpClient } from "./client.js";
import type {
  AcpConfigOption,
  AcpModeInfo,
  AcpModelInfo,
  AcpSessionLaunchOptions,
  AcpSlashCommand,
  AttachmentRef,
  ConfigValue,
  JsonRpcNotification,
  SwarmRole,
  ToolActivityItem,
  UsageStats,
} from "./types.js";

export interface WsEventEnvelope {
  type: string;
  sessionId: string;
  payload: unknown;
  ts: number;
}

export type SessionLaunchHook = (
  session: SessionSummary,
  agent: AgentProfile
) => AcpSessionLaunchOptions | undefined;

export interface BeforePromptResult {
  prefixSystemNote?: string;
}

export type BeforePromptHook = (
  session: SessionSummary,
  input: { text: string; source: "user" | "swarm" }
) => BeforePromptResult | void;

export interface TurnFinishedEvent {
  sessionId: string;
  session: SessionSummary | null;
  assistantMessageId: string;
  content: string;
  thinking: string;
  status: MessageStatus;
  stopReason: string;
  error?: string;
  userCancelled: boolean;
}

export type TurnFinishedHook = (ev: TurnFinishedEvent) => void | Promise<void>;
export type SessionDeletedHook = (session: SessionSummary) => void | Promise<void>;

interface WorkerEntry {
  sessionId: string;
  acpSessionId: string;
  agent: AgentProfile;
  client: AcpClient;
  idleTimer: NodeJS.Timeout | null;
}

interface ActiveTurn {
  sessionId: string;
  assistantMessageId: string;
  content: string;
  thinking: string;
  toolCalls: ToolActivityItem[];
  usage: UsageStats | null;
  seenUsageIds: Set<string>;
  cancelled: boolean;
  userCancelled: boolean;
  acceptingUpdates: boolean;
  sawToolSinceLastText: boolean;
  lastFlushAt: number;
}

const IDLE_TTL_MS = 30 * 60_000;
const MODEL_PROBE_TTL_MS = 10 * 60_000;

export function roundCredits(value: number): number {
  return Math.round(value * 10_000) / 10_000;
}

/** Accumulate per-call CodeBuddy usage metadata onto an active turn with deduplication. */
export function accumulateUsageFromMeta(
  usage: UsageStats | null,
  seenUsageIds: Set<string>,
  meta: Record<string, unknown>
): UsageStats | null {
  const rawUsage = meta.usage;
  if (!rawUsage || typeof rawUsage !== "object") {
    return usage;
  }

  const dedupeKey = String(meta["codebuddy.ai/messageId"] || meta["codebuddy.ai/requestId"] || "").trim();
  if (dedupeKey) {
    if (seenUsageIds.has(dedupeKey)) {
      return usage;
    }
    seenUsageIds.add(dedupeKey);
  }

  const src = rawUsage as Record<string, unknown>;
  const acc: UsageStats = usage ? { ...usage } : {};
  let touched = false;

  const addInt = (targetKey: "inputTokens" | "outputTokens" | "cachedReadTokens" | "thoughtTokens" | "totalTokens", rawVal: unknown) => {
    if (typeof rawVal === "number" && Number.isFinite(rawVal)) {
      acc[targetKey] = (acc[targetKey] ?? 0) + rawVal;
      touched = true;
    }
  };

  addInt("inputTokens", src.prompt_tokens);
  addInt("outputTokens", src.completion_tokens);
  addInt("cachedReadTokens", src.cache_read_input_tokens);
  addInt("thoughtTokens", src.completion_thinking_tokens);
  addInt("totalTokens", src.total_tokens);

  if (typeof src.credit === "number" && Number.isFinite(src.credit)) {
    acc.credits = roundCredits((acc.credits ?? 0) + src.credit);
    touched = true;
  }
  if (typeof src.original_credit === "number" && Number.isFinite(src.original_credit)) {
    acc.originalCredits = roundCredits((acc.originalCredits ?? 0) + src.original_credit);
    touched = true;
  }

  return touched ? acc : usage;
}

/** Merge ACP prompt result usage (e.g. agy) with accumulated turn usage (e.g. codebuddy credits). */
export function mergeUsageStats(
  resUsage: UsageStats | null,
  turnUsage: UsageStats | null
): UsageStats | null {
  if (!resUsage && !turnUsage) {
    return null;
  }
  const merged: UsageStats = turnUsage ? { ...turnUsage } : {};
  if (resUsage) {
    const keys: Array<keyof UsageStats> = [
      "inputTokens",
      "outputTokens",
      "cachedReadTokens",
      "thoughtTokens",
      "totalTokens",
      "credits",
      "originalCredits",
    ];
    for (const k of keys) {
      const val = resUsage[k];
      if (typeof val === "number" && Number.isFinite(val)) {
        merged[k] = val;
      }
    }
  }
  return Object.keys(merged).length > 0 ? merged : null;
}

function extractModels(raw: unknown): {
  currentModelId: string | null;
  availableModels: AcpModelInfo[];
} {
  const modelsObj = raw as Record<string, unknown> | undefined;
  const currentModelId =
    typeof modelsObj?.currentModelId === "string" ? modelsObj.currentModelId : null;
  const list = Array.isArray(modelsObj?.availableModels)
    ? (modelsObj!.availableModels as Array<Record<string, unknown>>)
    : [];
  const availableModels: AcpModelInfo[] = [];
  for (const item of list) {
    if (typeof item.modelId !== "string" || typeof item.name !== "string") continue;
    const desc =
      typeof item.description === "string"
        ? item.description
        : typeof (item._meta as Record<string, unknown> | undefined)?.credits === "string"
          ? String((item._meta as Record<string, unknown>).credits)
          : undefined;
    availableModels.push({
      modelId: item.modelId,
      name: item.name,
      ...(desc ? { description: desc } : {}),
    });
  }
  return { currentModelId, availableModels };
}

function extractModes(raw: unknown): {
  currentModeId: string | null;
  availableModes: AcpModeInfo[];
} {
  const modesObj = raw as Record<string, unknown> | undefined;
  const currentModeId =
    typeof modesObj?.currentModeId === "string" ? modesObj.currentModeId : null;
  const list = Array.isArray(modesObj?.availableModes)
    ? (modesObj!.availableModes as Array<Record<string, unknown>>)
    : [];
  const availableModes: AcpModeInfo[] = [];
  for (const item of list) {
    if (typeof item.id !== "string" || typeof item.name !== "string") continue;
    availableModes.push({
      id: item.id,
      name: item.name,
      ...(typeof item.description === "string" ? { description: item.description } : {}),
    });
  }
  return { currentModeId, availableModes };
}

function extractConfigOptions(raw: unknown): AcpConfigOption[] {
  if (!Array.isArray(raw)) return [];
  const result: AcpConfigOption[] = [];
  for (const item of raw as Array<Record<string, unknown>>) {
    if (typeof item.id !== "string" || typeof item.name !== "string") continue;
    const type = item.type === "boolean" ? "boolean" : "select";
    const val = item.currentValue;
    const currentValue: ConfigValue =
      typeof val === "boolean" ? val : typeof val === "string" ? val : "";
    const options = Array.isArray(item.options)
      ? (item.options as Array<Record<string, unknown>>)
          .filter((o) => typeof o.value === "string" && typeof o.name === "string")
          .map((o) => ({
            value: String(o.value),
            name: String(o.name),
            ...(typeof o.description === "string" ? { description: o.description } : {}),
          }))
      : undefined;

    result.push({
      id: item.id,
      name: item.name,
      ...(typeof item.description === "string" ? { description: item.description } : {}),
      ...(typeof item.category === "string" ? { category: item.category } : {}),
      type,
      currentValue,
      ...(options ? { options } : {}),
    });
  }
  return result;
}

function extractCommands(raw: unknown): AcpSlashCommand[] {
  if (!Array.isArray(raw)) return [];
  const out: AcpSlashCommand[] = [];
  for (const item of raw as Array<Record<string, unknown>>) {
    if (typeof item.name !== "string") continue;
    const input = item.input as Record<string, unknown> | undefined;
    const hint =
      typeof input?.hint === "string"
        ? input.hint
        : typeof item.hint === "string"
          ? item.hint
          : undefined;
    out.push({
      name: item.name,
      description: typeof item.description === "string" ? item.description : "",
      ...(hint ? { hint } : {}),
    });
  }
  return out;
}

export class SessionManager {
  private readonly workers = new Map<string, WorkerEntry>();
  private readonly activeTurns = new Map<string, ActiveTurn>();
  private readonly listeners = new Set<(ev: WsEventEnvelope) => void>();
  private sessionLaunchHook: SessionLaunchHook | null = null;
  private beforePromptHook: BeforePromptHook | null = null;
  private readonly turnFinishedListeners = new Set<TurnFinishedHook>();
  private readonly sessionDeletedListeners = new Set<SessionDeletedHook>();
  private readonly modelProbeCache = new Map<
    string,
    { models: AcpModelInfo[]; defaultModelId: string | null; fetchedAt: number }
  >();
  private disposed = false;

  constructor(
    private readonly config: AppConfig,
    private readonly db: RelayDatabase,
    private agents: AgentProfile[]
  ) {}

  setAgents(agents: AgentProfile[]): void {
    this.agents = agents;
  }

  getAgents(): AgentProfile[] {
    return this.agents;
  }

  hasAgent(agentId: string): boolean {
    return this.agents.some((a) => a.id === agentId);
  }

  getRunningSessionIds(): Set<string> {
    return new Set(this.activeTurns.keys());
  }

  isSessionRunning(sessionId: string): boolean {
    return this.activeTurns.has(sessionId);
  }

  subscribe(fn: (ev: WsEventEnvelope) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  setSessionLaunchHook(hook: SessionLaunchHook | null): void {
    this.sessionLaunchHook = hook;
  }

  setBeforePromptHook(hook: BeforePromptHook | null): void {
    this.beforePromptHook = hook;
  }

  onTurnFinished(hook: TurnFinishedHook): () => void {
    this.turnFinishedListeners.add(hook);
    return () => this.turnFinishedListeners.delete(hook);
  }

  onSessionDeleted(hook: SessionDeletedHook): () => void {
    this.sessionDeletedListeners.add(hook);
    return () => this.sessionDeletedListeners.delete(hook);
  }

  emitExternal(type: string, sessionId: string, payload: unknown): void {
    this.emit(type, sessionId, payload);
  }

  private emit(type: string, sessionId: string, payload: unknown): void {
    const ev: WsEventEnvelope = { type, sessionId, payload, ts: Date.now() };
    for (const fn of this.listeners) {
      try {
        fn(ev);
      } catch {
        // ignore listener failure
      }
    }
  }

  private notifyTurnFinished(ev: TurnFinishedEvent): void {
    for (const hook of this.turnFinishedListeners) {
      try {
        const res = hook(ev);
        if (res && typeof (res as Promise<void>).catch === "function") {
          (res as Promise<void>).catch(() => {
            // ignore hook failure
          });
        }
      } catch {
        // ignore hook failure
      }
    }
  }

  private notifySessionDeleted(session: SessionSummary): void {
    for (const hook of this.sessionDeletedListeners) {
      try {
        const res = hook(session);
        if (res && typeof (res as Promise<void>).catch === "function") {
          (res as Promise<void>).catch(() => {
            // ignore hook failure
          });
        }
      } catch {
        // ignore hook failure
      }
    }
  }

  private findAgent(agentId: string): AgentProfile {
    const found = this.agents.find((a) => a.id === agentId);
    if (!found) {
      const err = new Error(`Unknown agent: ${agentId}`) as Error & { statusCode?: number };
      err.statusCode = 404;
      throw err;
    }
    return found;
  }

  async probeAgentModels(agentId: string): Promise<{
    agentId: string;
    models: AcpModelInfo[];
    defaultModelId: string | null;
  }> {
    const agent = this.findAgent(agentId);
    const now = Date.now();

    const fromDb = this.db.getLatestAgentModels(agent.id);
    if (fromDb && fromDb.models.length > 0) {
      this.modelProbeCache.set(agent.id, {
        models: fromDb.models,
        defaultModelId: fromDb.defaultModelId,
        fetchedAt: now,
      });
      return {
        agentId: agent.id,
        models: fromDb.models,
        defaultModelId: fromDb.defaultModelId,
      };
    }

    const cached = this.modelProbeCache.get(agent.id);
    if (cached && now - cached.fetchedAt < MODEL_PROBE_TTL_MS) {
      return {
        agentId: agent.id,
        models: cached.models,
        defaultModelId: cached.defaultModelId,
      };
    }

    const client = new AcpClient(agent.command, agent.args, agent.env);
    client.start(this.config.defaultCwd);
    try {
      await client.initialize();
      const res = await client.newSession(this.config.defaultCwd);
      const extracted = extractModels(res.models);
      const defaultModelId =
        extracted.currentModelId ?? extracted.availableModels[0]?.modelId ?? null;
      this.modelProbeCache.set(agent.id, {
        models: extracted.availableModels,
        defaultModelId,
        fetchedAt: Date.now(),
      });
      return {
        agentId: agent.id,
        models: extracted.availableModels,
        defaultModelId,
      };
    } finally {
      await client.dispose();
    }
  }

  private refreshIdleTimer(entry: WorkerEntry): void {
    if (entry.idleTimer) clearTimeout(entry.idleTimer);
    entry.idleTimer = setTimeout(() => {
      if (!this.activeTurns.has(entry.sessionId)) {
        entry.client.dispose();
        this.workers.delete(entry.sessionId);
      }
    }, IDLE_TTL_MS);
    entry.idleTimer.unref();
  }

  private spawnClient(sessionId: string, agent: AgentProfile, cwd: string): AcpClient {
    const client = new AcpClient(agent.command, agent.args, agent.env, {
      onNotification: (msg) => this.handleNotification(sessionId, msg),
      onExit: () => {
        const w = this.workers.get(sessionId);
        if (w?.client === client) {
          if (w.idleTimer) clearTimeout(w.idleTimer);
          this.workers.delete(sessionId);
        }
      },
    });
    client.start(cwd);
    return client;
  }

  private applySessionInitMetadata(
    sessionId: string,
    result: Record<string, unknown>
  ): void {
    const models = extractModels(result.models);
    const modes = extractModes(result.modes);
    const configOptions = extractConfigOptions(result.configOptions);

    const modeFromConfig = configOptions.find((c) => c.id === "mode")?.currentValue;
    const modelFromConfig = configOptions.find((c) => c.id === "model")?.currentValue;

    const patch: Parameters<RelayDatabase["updateSession"]>[1] = {};
    if (models.availableModels.length > 0) patch.availableModels = models.availableModels;
    if (models.currentModelId) {
      patch.currentModelId = models.currentModelId;
    } else if (typeof modelFromConfig === "string" && modelFromConfig) {
      patch.currentModelId = modelFromConfig;
    }

    if (modes.availableModes.length > 0) patch.availableModes = modes.availableModes;
    if (modes.currentModeId) {
      patch.currentModeId = modes.currentModeId;
    } else if (typeof modeFromConfig === "string" && modeFromConfig) {
      patch.currentModeId = modeFromConfig;
    }

    if (configOptions.length > 0) patch.configOptions = configOptions;
    this.db.updateSession(sessionId, patch);
  }

  private async ensureWorker(session: SessionSummary): Promise<WorkerEntry> {
    const existing = this.workers.get(session.id);
    if (existing && existing.client.isAlive) {
      this.refreshIdleTimer(existing);
      return existing;
    }

    const agent = this.findAgent(session.agentId);
    const cwd = fs.existsSync(session.cwd) ? session.cwd : this.config.defaultCwd;
    const launchOptions = this.sessionLaunchHook?.(session, agent);
    const client = this.spawnClient(session.id, agent, cwd);

    try {
      await client.initialize();

      let acpSessionId = session.acpSessionId;
      let initRes: Record<string, unknown> | null = null;
      let createdFresh = false;

      if (acpSessionId) {
        try {
          initRes = await client.loadSession(acpSessionId, cwd, launchOptions);
        } catch {
          initRes = null;
          acpSessionId = null;
        }
      }

      if (!initRes || !acpSessionId) {
        initRes = await client.newSession(cwd, launchOptions);
        createdFresh = true;
        acpSessionId = String(initRes.sessionId || "");
        if (!acpSessionId) {
          throw new Error("ACP session/new did not return sessionId");
        }
        this.db.updateSession(session.id, { acpSessionId });
      }

      this.applySessionInitMetadata(session.id, initRes);

      // Re-apply user's saved model when re-hydrating a fresh fallback session
      if (createdFresh && session.currentModelId) {
        const initModels = extractModels(initRes.models);
        if (initModels.currentModelId !== session.currentModelId) {
          try {
            const setRes = await client.setModel(acpSessionId, session.currentModelId);
            const patch: Parameters<RelayDatabase["updateSession"]>[1] = {
              currentModelId: session.currentModelId,
            };
            const cfg = extractConfigOptions(setRes?.configOptions);
            if (cfg.length > 0) patch.configOptions = cfg;
            this.db.updateSession(session.id, patch);
          } catch {
            // ignore if model is no longer selectable
          }
        }
      }

      const entry: WorkerEntry = {
        sessionId: session.id,
        acpSessionId,
        agent,
        client,
        idleTimer: null,
      };
      this.workers.set(session.id, entry);
      this.refreshIdleTimer(entry);
      return entry;
    } catch (err) {
      await client.dispose();
      throw err;
    }
  }

  async createSession(input: {
    agentId: string;
    cwd?: string;
    title?: string;
    swarmId?: string | null;
    swarmRole?: SwarmRole | null;
    swarmMemberName?: string | null;
    worktreeBranch?: string | null;
    initialModelId?: string | null;
    launchOptions?: AcpSessionLaunchOptions;
  }): Promise<SessionSummary> {
    const agent = this.findAgent(input.agentId);
    const cwd = (input.cwd || this.config.defaultCwd).trim() || this.config.defaultCwd;
    fs.mkdirSync(cwd, { recursive: true });

    const id = crypto.randomUUID();
    const now = Date.now();
    const title = (input.title || "新对话").trim() || "新对话";

    const client = this.spawnClient(id, agent, cwd);
    try {
      await client.initialize();
      const res = await client.newSession(cwd, input.launchOptions);
      const acpSessionId = String(res.sessionId || "");
      if (!acpSessionId) {
        throw new Error("ACP session/new missing sessionId");
      }

      const models = extractModels(res.models);
      const modes = extractModes(res.modes);
      let configOptions = extractConfigOptions(res.configOptions);
      let currentModelId = models.currentModelId;

      if (
        input.initialModelId &&
        input.initialModelId.trim() &&
        input.initialModelId !== currentModelId
      ) {
        try {
          const setRes = await client.setModel(acpSessionId, input.initialModelId.trim());
          currentModelId = input.initialModelId.trim();
          const updatedCfg = extractConfigOptions(setRes?.configOptions);
          if (updatedCfg.length > 0) {
            configOptions = updatedCfg;
          }
        } catch {
          // Keep agent default model if initialModelId is rejected
        }
      }

      const created = this.db.createSession({
        id,
        agentId: agent.id,
        acpSessionId,
        title,
        cwd,
        currentModelId,
        currentModeId: modes.currentModeId,
        availableModels: models.availableModels,
        availableModes: modes.availableModes,
        configOptions,
        availableCommands: [],
        swarmId: input.swarmId ?? null,
        swarmRole: input.swarmRole ?? null,
        swarmMemberName: input.swarmMemberName ?? null,
        worktreeBranch: input.worktreeBranch ?? null,
        now,
      });

      const entry: WorkerEntry = {
        sessionId: id,
        acpSessionId,
        agent,
        client,
        idleTimer: null,
      };
      this.workers.set(id, entry);
      this.refreshIdleTimer(entry);

      // Some CLIs send initial config_option_update right after session/new
      await new Promise((r) => setTimeout(r, 80));
      const latest = this.db.getSession(id, this.getRunningSessionIds()) || created;
      this.emit("session_created", id, { session: latest });
      return latest;
    } catch (err) {
      await client.dispose();
      throw err;
    }
  }

  async disposeSessionWorker(sessionId: string): Promise<void> {
    const turn = this.activeTurns.get(sessionId);
    if (turn) {
      turn.cancelled = true;
      turn.acceptingUpdates = false;
      this.activeTurns.delete(sessionId);
    }
    const worker = this.workers.get(sessionId);
    if (worker) {
      if (worker.idleTimer) clearTimeout(worker.idleTimer);
      this.workers.delete(sessionId);
      await worker.client.dispose();
    }
  }

  deleteSession(sessionId: string, opts?: { skipDeletedHooks?: boolean }): boolean {
    const existing = this.db.getSession(sessionId, this.getRunningSessionIds());
    const turn = this.activeTurns.get(sessionId);
    if (turn) {
      turn.cancelled = true;
      turn.acceptingUpdates = false;
      this.activeTurns.delete(sessionId);
    }
    const worker = this.workers.get(sessionId);
    if (worker) {
      if (worker.idleTimer) clearTimeout(worker.idleTimer);
      void worker.client.dispose();
      this.workers.delete(sessionId);
    }
    const deleted = this.db.deleteSession(sessionId);
    if (deleted) {
      this.emit("session_deleted", sessionId, { sessionId });
      if (!opts?.skipDeletedHooks && existing) {
        this.notifySessionDeleted(existing);
      }
    }
    return deleted;
  }

  async updateSessionConfig(
    sessionId: string,
    input: { kind: "model" | "mode" | "config"; configId?: string; value: ConfigValue }
  ): Promise<SessionSummary> {
    const session = this.db.getSession(sessionId, this.getRunningSessionIds());
    if (!session) {
      throw new Error("Session not found");
    }
    const worker = await this.ensureWorker(session);

    if (input.kind === "model") {
      if (typeof input.value !== "string") throw new Error("Model ID must be a string");
      const res = await worker.client.setModel(worker.acpSessionId, input.value);
      const patch: Parameters<RelayDatabase["updateSession"]>[1] = {
        currentModelId: input.value,
      };
      const cfg = extractConfigOptions(res.configOptions);
      if (cfg.length > 0) patch.configOptions = cfg;
      this.db.updateSession(sessionId, patch);
    } else if (input.kind === "mode") {
      if (typeof input.value !== "string") throw new Error("Mode ID must be a string");
      const res = await worker.client.setMode(worker.acpSessionId, input.value);
      const patch: Parameters<RelayDatabase["updateSession"]>[1] = {
        currentModeId: input.value,
      };
      const cfg = extractConfigOptions(res.configOptions);
      if (cfg.length > 0) patch.configOptions = cfg;
      this.db.updateSession(sessionId, patch);
    } else if (input.kind === "config") {
      if (!input.configId) throw new Error("configId is required");
      const res = await worker.client.setConfigOption(
        worker.acpSessionId,
        input.configId,
        input.value
      );
      const cfg = extractConfigOptions(res.configOptions);
      if (cfg.length > 0) {
        const patch: Parameters<RelayDatabase["updateSession"]>[1] = { configOptions: cfg };
        const modeOpt = cfg.find((c) => c.id === "mode");
        if (modeOpt && typeof modeOpt.currentValue === "string") {
          patch.currentModeId = modeOpt.currentValue;
        }
        this.db.updateSession(sessionId, patch);
      } else {
        const updatedOpts = session.configOptions.map((opt) =>
          opt.id === input.configId ? { ...opt, currentValue: input.value } : opt
        );
        this.db.updateSession(sessionId, { configOptions: updatedOpts });
      }
    }

    const updated = this.db.getSession(sessionId, this.getRunningSessionIds())!;
    this.emit("config_updated", sessionId, { session: updated });
    return updated;
  }

  async startPrompt(
    sessionId: string,
    input: {
      text: string;
      attachmentIds?: string[];
      prefixSystemNote?: string;
      source?: "user" | "swarm";
    }
  ): Promise<{ userMessage: MessageRecord; assistantMessage: MessageRecord }> {
    const session = this.db.getSession(sessionId, this.getRunningSessionIds());
    if (!session) {
      const err = new Error("Session not found") as Error & { statusCode?: number };
      err.statusCode = 404;
      throw err;
    }
    if (this.activeTurns.has(sessionId)) {
      const err = new Error("Session already has an active turn");
      (err as Error & { statusCode?: number }).statusCode = 409;
      throw err;
    }

    const attachmentRefs: AttachmentRef[] = [];
    const promptBlocks: Array<Record<string, unknown>> = [];
    const fileNotes: string[] = [];

    for (const uploadId of input.attachmentIds || []) {
      const rec = this.db.getUpload(uploadId);
      if (!rec || !fs.existsSync(rec.diskPath)) continue;
      const isImage = rec.mimeType.startsWith("image/");
      attachmentRefs.push({
        id: rec.id,
        filename: rec.filename,
        mimeType: rec.mimeType,
        sizeBytes: rec.sizeBytes,
        isImage,
      });

      if (isImage) {
        const b64 = fs.readFileSync(rec.diskPath).toString("base64");
        promptBlocks.push({
          type: "image",
          data: b64,
          mimeType: rec.mimeType,
        });
      } else {
        let snippet = "";
        const isTextLike =
          rec.mimeType.startsWith("text/") ||
          rec.mimeType.includes("json") ||
          rec.mimeType.includes("xml") ||
          rec.mimeType.includes("yaml") ||
          /\.(txt|md|json|yaml|yml|py|ts|tsx|js|jsx|swift|sh|csv|log)$/i.test(rec.filename);
        if (isTextLike && rec.sizeBytes <= 32 * 1024) {
          snippet = `\n\`\`\`\n${fs.readFileSync(rec.diskPath, "utf8")}\n\`\`\``;
        }
        fileNotes.push(`[已上传附件: ${rec.filename} (${rec.mimeType}) -> ${rec.diskPath}]${snippet}`);
      }
    }

    const rawText = input.text.trim();
    const hookResult = this.beforePromptHook?.(session, {
      text: rawText,
      source: input.source ?? "user",
    });
    const prefixNote = [hookResult?.prefixSystemNote, input.prefixSystemNote]
      .filter((s): s is string => typeof s === "string" && s.trim().length > 0)
      .join("\n\n");

    const combinedText = [prefixNote, rawText, ...fileNotes].filter(Boolean).join("\n\n");
    if (combinedText) {
      promptBlocks.unshift({ type: "text", text: combinedText });
    }
    if (promptBlocks.length === 0) {
      throw new Error("Prompt cannot be empty");
    }

    // Auto-title standalone session from first user message if still default
    if (!session.swarmId && session.title === "新对话" && rawText) {
      const autoTitle = rawText.replace(/\s+/g, " ").slice(0, 28);
      this.db.updateSession(sessionId, { title: autoTitle });
    }

    const now = Date.now();
    const userMessage = this.db.createMessage({
      id: crypto.randomUUID(),
      sessionId,
      role: "user",
      content: rawText || (attachmentRefs.length > 0 ? "[附件]" : ""),
      thinking: "",
      attachments: attachmentRefs,
      toolCalls: [],
      usage: null,
      status: "completed",
      createdAt: now,
    });

    const assistantMessage = this.db.createMessage({
      id: crypto.randomUUID(),
      sessionId,
      role: "assistant",
      content: "",
      thinking: "",
      attachments: [],
      toolCalls: [],
      usage: null,
      status: "streaming",
      createdAt: now + 1,
    });

    const turn: ActiveTurn = {
      sessionId,
      assistantMessageId: assistantMessage.id,
      content: "",
      thinking: "",
      toolCalls: [],
      usage: null,
      seenUsageIds: new Set<string>(),
      cancelled: false,
      userCancelled: false,
      acceptingUpdates: false,
      sawToolSinceLastText: false,
      lastFlushAt: Date.now(),
    };
    this.activeTurns.set(sessionId, turn);

    this.emit("turn_started", sessionId, {
      userMessage,
      assistantMessage,
      session: this.db.getSession(sessionId, this.getRunningSessionIds()),
    });

    void this.runTurn(session, turn, promptBlocks);

    return { userMessage, assistantMessage };
  }

  private async runTurn(
    session: SessionSummary,
    turn: ActiveTurn,
    promptBlocks: Array<Record<string, unknown>>
  ): Promise<void> {
    try {
      const worker = await this.ensureWorker(session);
      if (this.disposed) return;
      if (turn.cancelled) {
        this.db.updateMessage(turn.assistantMessageId, {
          content: turn.content,
          thinking: turn.thinking,
          toolCalls: turn.toolCalls,
          usage: turn.usage,
          status: "cancelled",
        });
        this.db.updateSession(session.id, { updatedAt: Date.now() });
        this.activeTurns.delete(session.id);

        const latestSession = this.db.getSession(session.id, this.getRunningSessionIds());
        this.emit("turn_completed", session.id, {
          messageId: turn.assistantMessageId,
          stopReason: "cancelled",
          status: "cancelled",
          usage: turn.usage,
          session: latestSession,
        });
        this.notifyTurnFinished({
          sessionId: session.id,
          session: latestSession,
          assistantMessageId: turn.assistantMessageId,
          content: turn.content,
          thinking: turn.thinking,
          status: "cancelled",
          stopReason: "cancelled",
          userCancelled: turn.userCancelled,
        });
        return;
      }

      turn.acceptingUpdates = true;
      const res = await worker.client.prompt(worker.acpSessionId, promptBlocks);
      turn.acceptingUpdates = false;
      this.refreshIdleTimer(worker);

      const stopReason = typeof res.stopReason === "string" ? res.stopReason : "end_turn";
      if (this.disposed) return;
      const resUsage =
        res.usage && typeof res.usage === "object" ? (res.usage as UsageStats) : null;
      const usage = mergeUsageStats(resUsage, turn.usage);
      const finalStatus =
        turn.cancelled || stopReason === "cancelled" ? "cancelled" : "completed";

      this.db.updateMessage(turn.assistantMessageId, {
        content: turn.content,
        thinking: turn.thinking,
        toolCalls: turn.toolCalls,
        usage,
        status: finalStatus,
      });
      this.db.updateSession(session.id, { updatedAt: Date.now() });

      this.activeTurns.delete(session.id);

      const latestSession = this.db.getSession(session.id, this.getRunningSessionIds());
      this.emit("turn_completed", session.id, {
        messageId: turn.assistantMessageId,
        stopReason,
        status: finalStatus,
        usage,
        session: latestSession,
      });

      this.notifyTurnFinished({
        sessionId: session.id,
        session: latestSession,
        assistantMessageId: turn.assistantMessageId,
        content: turn.content,
        thinking: turn.thinking,
        status: finalStatus,
        stopReason,
        userCancelled: turn.userCancelled,
      });

      const barkUrl = this.db.getSetting("bark_url");
      if (barkUrl && finalStatus === "completed" && session.swarmRole !== "worker") {
        const preview = turn.content.replace(/\s+/g, " ").trim().slice(0, 90) || "任务已完成";
        void sendBarkNotification(
          barkUrl,
          `Relay · ${latestSession?.title || "会话"}`,
          preview
        );
      }
    } catch (err) {
      turn.acceptingUpdates = false;
      if (this.disposed) return;
      const errMsg = err instanceof Error ? err.message : String(err);
      const finalContent = turn.content
        ? `${turn.content}\n\n> 请求出错: ${errMsg}`
        : `请求出错: ${errMsg}`;
      const finalStatus: MessageStatus = turn.cancelled ? "cancelled" : "error";
      this.db.updateMessage(turn.assistantMessageId, {
        content: finalContent,
        thinking: turn.thinking,
        toolCalls: turn.toolCalls,
        status: finalStatus,
      });
      this.db.updateSession(session.id, { updatedAt: Date.now() });
      this.activeTurns.delete(session.id);

      const latestSession = this.db.getSession(session.id, this.getRunningSessionIds());
      this.emit("turn_error", session.id, {
        messageId: turn.assistantMessageId,
        error: errMsg,
        session: latestSession,
      });

      this.notifyTurnFinished({
        sessionId: session.id,
        session: latestSession,
        assistantMessageId: turn.assistantMessageId,
        content: turn.content,
        thinking: turn.thinking,
        status: finalStatus,
        stopReason: finalStatus,
        error: errMsg,
        userCancelled: turn.userCancelled,
      });

      const barkUrl = this.db.getSetting("bark_url");
      if (barkUrl && !turn.cancelled && session.swarmRole !== "worker") {
        void sendBarkNotification(
          barkUrl,
          `Relay · ${latestSession?.title || "会话出错"}`,
          errMsg.slice(0, 90)
        );
      }
    }
  }

  cancelTurn(sessionId: string): boolean {
    const turn = this.activeTurns.get(sessionId);
    if (!turn) return false;
    turn.cancelled = true;
    turn.userCancelled = true;
    const worker = this.workers.get(sessionId);
    if (worker?.client.isAlive) {
      worker.client.cancel(worker.acpSessionId);
    }
    return true;
  }

  private flushTurnIfNeeded(turn: ActiveTurn): void {
    const now = Date.now();
    if (now - turn.lastFlushAt >= 250) {
      turn.lastFlushAt = now;
      this.db.updateMessage(turn.assistantMessageId, {
        content: turn.content,
        thinking: turn.thinking,
        toolCalls: turn.toolCalls,
      });
    }
  }

  private handleNotification(sessionId: string, msg: JsonRpcNotification): void {
    if (msg.method !== "session/update") {
      return;
    }
    const params = msg.params || {};
    const update = params.update as Record<string, unknown> | undefined;
    if (!update || typeof update !== "object") return;

    const kind = typeof update.sessionUpdate === "string" ? update.sessionUpdate : "";
    const activeTurn = this.activeTurns.get(sessionId);
    const turn = activeTurn?.acceptingUpdates ? activeTurn : undefined;

    switch (kind) {
      case "agent_thought_chunk": {
        const text = extractChunkText(update.content);
        if (!text || !turn) return;
        turn.thinking += text;
        this.flushTurnIfNeeded(turn);
        this.emit("thought_delta", sessionId, {
          messageId: turn.assistantMessageId,
          delta: text,
        });
        break;
      }

      case "agent_message_chunk": {
        const text = extractChunkText(update.content);
        if (!text || !turn) return;
        let delta = text;
        if (turn.sawToolSinceLastText) {
          turn.sawToolSinceLastText = false;
          if (turn.content.length > 0 && !text.startsWith("\n")) {
            if (!turn.content.endsWith("\n")) {
              delta = `\n\n${text}`;
            } else if (!turn.content.endsWith("\n\n")) {
              delta = `\n${text}`;
            }
          }
        }
        turn.content += delta;
        this.flushTurnIfNeeded(turn);
        this.emit("text_delta", sessionId, {
          messageId: turn.assistantMessageId,
          delta,
        });
        break;
      }

      case "tool_call":
      case "tool_call_update": {
        if (!turn) return;
        const toolCallId =
          typeof update.toolCallId === "string" ? update.toolCallId : crypto.randomUUID();
        const meta = (update._meta as Record<string, unknown> | undefined) || {};
        const name =
          typeof update.name === "string"
            ? update.name
            : typeof meta["codebuddy.ai/toolName"] === "string"
              ? String(meta["codebuddy.ai/toolName"])
              : "tool";
        const rawTitle = typeof update.title === "string" ? update.title : "";
        const cleanTitle = rawTitle.replace(/^`|`$/g, "").slice(0, 120);
        const toolKind = typeof update.kind === "string" ? update.kind : "other";
        const status = typeof update.status === "string" ? update.status : "";

        const idx = turn.toolCalls.findIndex((t) => t.id === toolCallId);
        if (idx === -1) {
          if (turn.content.length > 0) {
            turn.sawToolSinceLastText = true;
          }
          turn.toolCalls.push({
            id: toolCallId,
            name,
            title: cleanTitle || name,
            kind: toolKind,
            status: status || "in_progress",
          });
        } else {
          const prev = turn.toolCalls[idx];
          turn.toolCalls[idx] = {
            id: toolCallId,
            name: name !== "tool" ? name : prev.name,
            title: cleanTitle || prev.title,
            kind: toolKind !== "other" ? toolKind : prev.kind,
            status: status || prev.status,
          };
        }

        this.flushTurnIfNeeded(turn);
        this.emit("tool_activity", sessionId, {
          messageId: turn.assistantMessageId,
          toolCalls: turn.toolCalls,
        });
        break;
      }

      case "usage_update": {
        const used = typeof update.used === "number" ? update.used : undefined;
        const size = typeof update.size === "number" ? update.size : undefined;
        if (used !== undefined || size !== undefined) {
          this.db.updateSession(sessionId, {
            ...(used !== undefined ? { contextUsed: used } : {}),
            ...(size !== undefined ? { contextSize: size } : {}),
          });
          this.emit("usage_updated", sessionId, {
            contextUsed: used ?? 0,
            contextSize: size ?? 0,
          });
        }
        if (turn && update._meta && typeof update._meta === "object") {
          turn.usage = accumulateUsageFromMeta(
            turn.usage,
            turn.seenUsageIds,
            update._meta as Record<string, unknown>
          );
        }
        break;
      }

      case "available_commands_update": {
        const commands = extractCommands(update.availableCommands);
        this.db.updateSession(sessionId, { availableCommands: commands });
        this.emit("commands_updated", sessionId, { commands });
        break;
      }

      case "config_option_update": {
        const cfg = extractConfigOptions(update.configOptions);
        if (cfg.length > 0) {
          const patch: Parameters<RelayDatabase["updateSession"]>[1] = { configOptions: cfg };
          const modeOpt = cfg.find((c) => c.id === "mode");
          if (modeOpt && typeof modeOpt.currentValue === "string") {
            patch.currentModeId = modeOpt.currentValue;
          }
          const modelOpt = cfg.find((c) => c.id === "model");
          if (modelOpt && typeof modelOpt.currentValue === "string") {
            const current = this.db.getSession(sessionId);
            if (!current?.currentModelId) {
              patch.currentModelId = modelOpt.currentValue;
            }
          }
          this.db.updateSession(sessionId, patch);
          const latest = this.db.getSession(sessionId, this.getRunningSessionIds());
          this.emit("config_updated", sessionId, { session: latest });
        }
        break;
      }

      case "session_info_update": {
        const title = typeof update.title === "string" ? update.title.trim() : "";
        if (title) {
          const existing = this.db.getSession(sessionId);
          if (
            existing &&
            !existing.swarmId &&
            (existing.title === "新对话" || existing.title.length <= 28)
          ) {
            this.db.updateSession(sessionId, { title: title.slice(0, 60) });
            const latest = this.db.getSession(sessionId, this.getRunningSessionIds());
            this.emit("session_updated", sessionId, { session: latest });
          }
        }
        break;
      }
    }
  }

  async disposeAll(): Promise<void> {
    this.disposed = true;
    const disposals: Promise<void>[] = [];
    for (const [, worker] of this.workers) {
      if (worker.idleTimer) clearTimeout(worker.idleTimer);
      disposals.push(worker.client.dispose());
    }
    this.workers.clear();
    this.activeTurns.clear();
    await Promise.all(disposals);
  }
}

function extractChunkText(content: unknown): string {
  if (!content || typeof content !== "object") return "";
  const obj = content as Record<string, unknown>;
  if (obj.type === "text" && typeof obj.text === "string") {
    return obj.text;
  }
  return "";
}
