import { execFile } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import type {
  BeforePromptResult,
  SessionManager,
  TurnFinishedEvent,
} from "../acp/manager.js";
import type {
  AcpMcpServerConfig,
  AcpModelInfo,
  AcpSessionLaunchOptions,
  SwarmBoardMessage,
  SwarmBoardMessageKind,
  SwarmMember,
  SwarmMemberState,
  SwarmRole,
  SwarmStatus,
  SwarmSummary,
  SwarmWorkspaceMode,
} from "../acp/types.js";
import type { AgentProfile, AppConfig } from "../config.js";
import type { RelayDatabase, SessionSummary } from "../db.js";

const execFileAsync = promisify(execFile);

const MAX_AUTO_COORDINATOR_TURNS = 16;
const WORKER_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,23}$/;
const RESERVED_WORKER_NAMES = new Set(["all", "coordinator", "user", "system"]);
const MENTION_RE = /(?:^|[^a-zA-Z0-9._-])@([a-z0-9][a-z0-9_-]{0,23}|all|coordinator)\b/gi;

export function parseMentions(text: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  let m: RegExpExecArray | null;
  MENTION_RE.lastIndex = 0;
  while ((m = MENTION_RE.exec(text)) !== null) {
    const name = m[1].toLowerCase();
    if (!seen.has(name)) {
      seen.add(name);
      out.push(name);
    }
  }
  return out;
}

function httpError(statusCode: number, message: string): Error {
  const err = new Error(message) as Error & { statusCode?: number };
  err.statusCode = statusCode;
  return err;
}

function buildCoordinatorSystemPrompt(
  swarmId: string,
  cwd: string,
  defaultWorkerAgentId: string,
  defaultWorkerModelId: string | null,
  availableAgents: AgentProfile[]
): string {
  const agentList = availableAgents.map((a) => `${a.id}(${a.name})`).join("、") || "无";
  return [
    `[Relay 蜂群总控规约 · swarmId=${swarmId}]`,
    `你是当前多 Agent 蜂群的总控 (coordinator)，工作目录：${cwd}。`,
    `可用 Agent：${agentList}；默认工人：${defaultWorkerAgentId}${defaultWorkerModelId ? `（默认模型：${defaultWorkerModelId}）` : ""}。`,
    `你拥有内置 MCP 工具（relay_swarm）：`,
    `- swarm_status：查看全员状态、分支、积分与留言板 headSeq`,
    `- swarm_models：查询各 Agent 的可用模型与积分说明`,
    `- swarm_add：派生工人（name 仅小写字母/数字/-/_；brief 明确目标、负责文件与完成标准；写代码优先 workspace="worktree" 隔离分支，只读分析用 "inherit"）`,
    `- swarm_post：在共享留言板发言，用 @成员名 唤醒工人或 @all 广播`,
    `- swarm_read_board：按 since 增量读取留言板`,
    `- swarm_wait：派活后阻塞等待工人汇报或全部活跃工人结束（传 since 为当前已读 seq，切勿循环轮询）`,
    `- swarm_kill：工人工作整合完成后终止并清理 worktree`,
    `工作准则：拆分可并行子任务派生多名工人并清晰划分文件所有权；派活后调用 swarm_wait 等待汇报；整合核对工人成果后再给用户清晰总结。`,
  ].join("\n");
}

function buildWorkerPromptPreamble(
  swarmId: string,
  memberName: string,
  cwd: string,
  worktreeBranch: string | null
): string {
  const branchNote = worktreeBranch ? `（独立 Git worktree 分支：${worktreeBranch}）` : "";
  return [
    `[Relay 蜂群成员规约 · swarmId=${swarmId} · @${memberName}]`,
    `你是蜂群协作工人 @${memberName}，工作目录：${cwd}${branchNote}。`,
    `你拥有共享留言板 MCP 工具：swarm_post、swarm_read_board、swarm_status。`,
    `请严格在分配的职责与文件范围内工作；完成后务必调用 swarm_post 向 @coordinator 汇报，格式以 "@coordinator [done] " 开头并附简明改动/结论摘要；遇到阻塞则调用 swarm_post 向 @coordinator 说明原因。`,
  ].join("\n");
}

interface WaiterEntry {
  memberName: string;
  check: () => void;
  abort: () => void;
}

export interface WaitBoardResult {
  reason: "message" | "all_workers_idle" | "timeout" | "closed";
  messages: SwarmBoardMessage[];
  matchedSeqs: number[];
  headSeq: number;
  workers: Array<{
    name: string;
    agentId: string;
    modelId: string | null;
    state: SwarmMemberState;
    isRunning: boolean;
    worktreeBranch: string | null;
  }>;
}

export class SwarmManager {
  private readonly waiters = new Map<string, Set<WaiterEntry>>();
  private readonly pausedByUser = new Set<string>();
  private readonly autoWakeCount = new Map<string, number>();
  private readonly pendingWakes = new Map<string, number>();
  private readonly turnStartPostSeq = new Map<string, number>();
  private readonly injectedCoordinatorPrompt = new Set<string>();
  private readonly pendingLaunchRoles = new Map<string, SwarmRole>();

  constructor(
    private readonly config: AppConfig,
    private readonly db: RelayDatabase,
    private readonly sessionManager: SessionManager,
    private readonly internalMcpToken: string,
    private readonly getBaseUrl: () => string
  ) {
    this.sessionManager.setSessionLaunchHook((session, agent) =>
      this.buildLaunchOptions(session, agent)
    );
    this.sessionManager.setBeforePromptHook((session, input) =>
      this.handleBeforePrompt(session, input)
    );
    this.sessionManager.onTurnFinished((ev) => {
      void this.handleTurnFinished(ev);
    });
    this.sessionManager.onSessionDeleted((session) => {
      void this.handleSessionDeleted(session);
    });
  }

  private wakeKey(swarmId: string, memberName: string): string {
    return `${swarmId}:${memberName}`;
  }

  private buildMcpServer(swarmId: string, memberName: string): AcpMcpServerConfig {
    const baseUrl = this.getBaseUrl().replace(/\/+$/, "");
    return {
      type: "http",
      name: "relay_swarm",
      url: `${baseUrl}/internal/mcp/swarms/${encodeURIComponent(swarmId)}/members/${encodeURIComponent(memberName)}`,
      headers: [{ name: "x-relay-internal-token", value: this.internalMcpToken }],
    };
  }

  private buildLaunchOptions(
    session: SessionSummary,
    agent: AgentProfile
  ): AcpSessionLaunchOptions | undefined {
    if (!session.swarmId || !session.swarmRole || !session.swarmMemberName) {
      return undefined;
    }

    const mcpServers = [this.buildMcpServer(session.swarmId, session.swarmMemberName)];
    if (agent.id === "agy") {
      if (session.swarmRole === "coordinator") {
        const swarm = this.db.getSwarmSummary(session.swarmId);
        const prompt = buildCoordinatorSystemPrompt(
          session.swarmId,
          swarm?.cwd || session.cwd,
          swarm?.defaultWorkerAgentId || "codebuddy",
          swarm?.defaultWorkerModelId ?? null,
          this.sessionManager.getAgents()
        );
        return {
          mcpServers,
          meta: {
            antigravity: {
              systemPrompt: { append: prompt },
            },
          },
        };
      }
      const prompt = buildWorkerPromptPreamble(
        session.swarmId,
        session.swarmMemberName,
        session.cwd,
        session.worktreeBranch
      );
      return {
        mcpServers,
        meta: {
          antigravity: {
            systemPrompt: { append: prompt },
          },
        },
      };
    }

    return { mcpServers };
  }

  private handleBeforePrompt(
    session: SessionSummary,
    input: { text: string; source: "user" | "swarm" }
  ): BeforePromptResult | void {
    if (!session.swarmId || !session.swarmMemberName) {
      return;
    }

    const member = this.db.getSwarmMember(session.swarmId, session.swarmMemberName);
    if (!member || member.state === "killed") {
      return;
    }

    this.turnStartPostSeq.set(session.id, member.lastPostSeq);
    this.db.updateSwarmMember(session.swarmId, session.swarmMemberName, {
      state: "working",
    });

    let result: BeforePromptResult | undefined;

    if (session.swarmRole === "coordinator") {
      if (input.source === "user") {
        this.pausedByUser.delete(session.swarmId);
        this.autoWakeCount.set(session.swarmId, 0);
      }

      if (
        session.agentId !== "agy" &&
        !this.injectedCoordinatorPrompt.has(session.id) &&
        this.db.listMessages(session.id).length === 0
      ) {
        this.injectedCoordinatorPrompt.add(session.id);
        const swarm = this.db.getSwarmSummary(session.swarmId);
        result = {
          prefixSystemNote: buildCoordinatorSystemPrompt(
            session.swarmId,
            swarm?.cwd || session.cwd,
            swarm?.defaultWorkerAgentId || "codebuddy",
            swarm?.defaultWorkerModelId ?? null,
            this.sessionManager.getAgents()
          ),
        };
      }
    }

    this.emitSwarmUpdated(session.swarmId);
    return result;
  }

  private emitSwarmUpdated(swarmId: string): SwarmSummary | null {
    const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
    if (swarm) {
      this.sessionManager.emitExternal("swarm_updated", swarm.coordinatorSessionId, { swarm });
    }
    return swarm;
  }

  listSwarms(): SwarmSummary[] {
    return this.db.listSwarms(this.sessionManager.getRunningSessionIds());
  }

  getSwarm(id: string): { swarm: SwarmSummary; messages: SwarmBoardMessage[] } | null {
    const swarm = this.db.getSwarmSummary(id, this.sessionManager.getRunningSessionIds());
    if (!swarm) return null;
    const messages = this.db.listSwarmMessages(id);
    return { swarm, messages };
  }

  getSwarmSummary(id: string): SwarmSummary | null {
    return this.db.getSwarmSummary(id, this.sessionManager.getRunningSessionIds());
  }

  getSwarmMember(swarmId: string, name: string): SwarmMember | null {
    return this.db.getSwarmMember(swarmId, name, this.sessionManager.getRunningSessionIds());
  }

  resolveMemberRole(swarmId: string, memberName: string): SwarmRole | null {
    const member = this.db.getSwarmMember(swarmId, memberName);
    if (member) {
      return member.state === "killed" ? null : member.role;
    }
    return this.pendingLaunchRoles.get(this.wakeKey(swarmId, memberName)) ?? null;
  }

  async createSwarm(input: {
    title?: string;
    cwd?: string;
    coordinatorAgentId?: string;
    coordinatorModelId?: string | null;
    defaultWorkerAgentId?: string;
    defaultWorkerModelId?: string | null;
  }): Promise<{ swarm: SwarmSummary; session: SessionSummary }> {
    const coordinatorAgentId = (input.coordinatorAgentId || "agy").trim() || "agy";
    const defaultWorkerAgentId = (input.defaultWorkerAgentId || "codebuddy").trim() || "codebuddy";

    if (!this.sessionManager.hasAgent(coordinatorAgentId)) {
      throw httpError(400, `Unknown coordinator agent: ${coordinatorAgentId}`);
    }
    if (!this.sessionManager.hasAgent(defaultWorkerAgentId)) {
      throw httpError(400, `Unknown default worker agent: ${defaultWorkerAgentId}`);
    }

    const cwd = (input.cwd || this.config.defaultCwd).trim() || this.config.defaultCwd;
    fs.mkdirSync(cwd, { recursive: true });

    const title = (input.title || "蜂群协作").trim().slice(0, 80) || "蜂群协作";
    const swarmId = crypto.randomUUID();
    const now = Date.now();
    const defaultWorkerModelId =
      typeof input.defaultWorkerModelId === "string" && input.defaultWorkerModelId.trim()
        ? input.defaultWorkerModelId.trim()
        : null;
    const coordinatorModelId =
      typeof input.coordinatorModelId === "string" && input.coordinatorModelId.trim()
        ? input.coordinatorModelId.trim()
        : null;

    const mcpServers = [this.buildMcpServer(swarmId, "coordinator")];
    const launchOptions: AcpSessionLaunchOptions =
      coordinatorAgentId === "agy"
        ? {
            mcpServers,
            meta: {
              antigravity: {
                systemPrompt: {
                  append: buildCoordinatorSystemPrompt(
                    swarmId,
                    cwd,
                    defaultWorkerAgentId,
                    defaultWorkerModelId,
                    this.sessionManager.getAgents()
                  ),
                },
              },
            },
          }
        : { mcpServers };

    const launchKey = this.wakeKey(swarmId, "coordinator");
    this.pendingLaunchRoles.set(launchKey, "coordinator");
    let session: SessionSummary;
    try {
      session = await this.sessionManager.createSession({
        agentId: coordinatorAgentId,
        cwd,
        title,
        swarmId,
        swarmRole: "coordinator",
        swarmMemberName: "coordinator",
        initialModelId: coordinatorModelId,
        launchOptions,
      });

      this.db.createSwarm({
        id: swarmId,
        title,
        cwd,
        coordinatorSessionId: session.id,
        coordinatorAgentId,
        defaultWorkerAgentId,
        defaultWorkerModelId,
        status: "active",
        now,
      });

      this.db.addSwarmMember({
        swarmId,
        name: "coordinator",
        role: "coordinator",
        sessionId: session.id,
        agentId: coordinatorAgentId,
        modelId: session.currentModelId ?? coordinatorModelId,
        state: "waiting",
        workspaceMode: "inherit",
        brief: "蜂群总控",
        now,
      });
    } finally {
      this.pendingLaunchRoles.delete(launchKey);
    }

    const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds())!;
    this.sessionManager.emitExternal("swarm_created", session.id, { swarm });
    return { swarm, session };
  }

  updateSwarm(
    id: string,
    patch: {
      title?: string;
      status?: SwarmStatus;
      defaultWorkerAgentId?: string;
      defaultWorkerModelId?: string | null;
    }
  ): SwarmSummary {
    const existing = this.db.getSwarmSummary(id, this.sessionManager.getRunningSessionIds());
    if (!existing) {
      throw httpError(404, "Swarm not found");
    }

    const dbPatch: Parameters<RelayDatabase["updateSwarm"]>[1] = {};
    if (patch.title !== undefined) {
      const clean = patch.title.trim().slice(0, 80);
      if (!clean) throw httpError(400, "title cannot be empty");
      dbPatch.title = clean;
      this.db.updateSession(existing.coordinatorSessionId, { title: clean });
    }
    if (patch.status !== undefined) {
      if (!["active", "completed", "archived"].includes(patch.status)) {
        throw httpError(400, `Invalid swarm status: ${patch.status}`);
      }
      dbPatch.status = patch.status;
    }
    if (patch.defaultWorkerAgentId !== undefined) {
      const cleanAgent = patch.defaultWorkerAgentId.trim();
      if (!this.sessionManager.hasAgent(cleanAgent)) {
        throw httpError(400, `Unknown worker agent: ${cleanAgent}`);
      }
      dbPatch.defaultWorkerAgentId = cleanAgent;
    }
    if (patch.defaultWorkerModelId !== undefined) {
      dbPatch.defaultWorkerModelId =
        typeof patch.defaultWorkerModelId === "string" && patch.defaultWorkerModelId.trim()
          ? patch.defaultWorkerModelId.trim()
          : null;
    }

    this.db.updateSwarm(id, dbPatch);
    return this.emitSwarmUpdated(id)!;
  }

  private async prepareGitWorktree(
    swarmId: string,
    swarmCwd: string,
    workerName: string
  ): Promise<{
    workspaceMode: SwarmWorkspaceMode;
    workerCwd: string;
    worktreePath: string | null;
    worktreeBranch: string | null;
    workspaceNote?: string;
  }> {
    let repoRoot = "";
    try {
      const { stdout } = await execFileAsync(
        "git",
        ["-C", swarmCwd, "rev-parse", "--show-toplevel"],
        { timeout: 10_000 }
      );
      repoRoot = stdout.trim();
    } catch {
      return {
        workspaceMode: "inherit",
        workerCwd: swarmCwd,
        worktreePath: null,
        worktreeBranch: null,
        workspaceNote: "工作目录不是 Git 仓库，已优雅降级为 inherit 共享目录模式。",
      };
    }

    if (!repoRoot) {
      return {
        workspaceMode: "inherit",
        workerCwd: swarmCwd,
        worktreePath: null,
        worktreeBranch: null,
        workspaceNote: "无法定位 Git 仓库根目录，已优雅降级为 inherit 共享目录模式。",
      };
    }

    try {
      await execFileAsync("git", ["-C", repoRoot, "rev-parse", "--verify", "HEAD"], {
        timeout: 10_000,
      });
    } catch {
      return {
        workspaceMode: "inherit",
        workerCwd: swarmCwd,
        worktreePath: null,
        worktreeBranch: null,
        workspaceNote: "Git 仓库尚无提交 (HEAD 不存在)，已优雅降级为 inherit 共享目录模式。",
      };
    }

    const shortId = swarmId.replace(/[^a-z0-9]/gi, "").slice(0, 8) || "swarm";
    const branch = `relay-swarm/${shortId}/${workerName}`;
    const worktreePath = path.join(this.config.dataDir, "worktrees", swarmId, workerName);
    fs.mkdirSync(path.dirname(worktreePath), { recursive: true });

    try {
      if (fs.existsSync(worktreePath)) {
        await execFileAsync("git", ["-C", repoRoot, "worktree", "remove", "--force", worktreePath], {
          timeout: 15_000,
        }).catch(() => {});
        fs.rmSync(worktreePath, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
      }
      try {
        await execFileAsync(
          "git",
          ["-C", repoRoot, "worktree", "add", "-b", branch, worktreePath, "HEAD"],
          { timeout: 20_000 }
        );
      } catch {
        // Retry with -B if the branch name already exists
        await execFileAsync(
          "git",
          ["-C", repoRoot, "worktree", "add", "-B", branch, worktreePath, "HEAD"],
          { timeout: 20_000 }
        );
      }

      const relSubdir = path.relative(repoRoot, swarmCwd);
      const candidateCwd =
        relSubdir && !relSubdir.startsWith("..") && !path.isAbsolute(relSubdir)
          ? path.join(worktreePath, relSubdir)
          : worktreePath;
      const workerCwd = fs.existsSync(candidateCwd) ? candidateCwd : worktreePath;

      return {
        workspaceMode: "worktree",
        workerCwd,
        worktreePath,
        worktreeBranch: branch,
      };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return {
        workspaceMode: "inherit",
        workerCwd: swarmCwd,
        worktreePath: null,
        worktreeBranch: null,
        workspaceNote: `创建 Git worktree 失败（${msg.slice(0, 120)}），已优雅降级为 inherit 共享目录模式。`,
      };
    }
  }

  private async cleanupGitWorktree(swarmCwd: string, worktreePath: string | null): Promise<void> {
    if (!worktreePath) return;
    try {
      const { stdout } = await execFileAsync(
        "git",
        ["-C", swarmCwd, "rev-parse", "--show-toplevel"],
        { timeout: 10_000 }
      );
      const repoRoot = stdout.trim();
      if (repoRoot) {
        await execFileAsync(
          "git",
          ["-C", repoRoot, "worktree", "remove", "--force", worktreePath],
          { timeout: 15_000 }
        ).catch(() => {});
        await execFileAsync("git", ["-C", repoRoot, "worktree", "prune"], {
          timeout: 10_000,
        }).catch(() => {});
      }
    } catch {
      // Ignore git errors and fall back to fs.rmSync
    }
    try {
      if (fs.existsSync(worktreePath)) {
        fs.rmSync(worktreePath, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
      }
    } catch {
      // ignore cleanup failure
    }
  }

  async addWorker(
    swarmId: string,
    input: {
      name: string;
      brief: string;
      agentId?: string;
      modelId?: string | null;
      workspace?: SwarmWorkspaceMode;
      sender?: string;
    }
  ): Promise<{
    member: SwarmMember;
    swarm: SwarmSummary;
    boardSeq: number;
    workspaceNote?: string;
  }> {
    const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
    if (!swarm) {
      throw httpError(404, "Swarm not found");
    }

    const name = String(input.name || "")
      .trim()
      .toLowerCase();
    if (
      !WORKER_NAME_RE.test(name) ||
      RESERVED_WORKER_NAMES.has(name) ||
      name.startsWith("coordinator-")
    ) {
      throw httpError(
        400,
        "Invalid worker name: must match ^[a-z0-9][a-z0-9_-]{0,23}$ and not be reserved"
      );
    }

    const brief = String(input.brief || "").trim();
    if (!brief) {
      throw httpError(400, "brief is required");
    }

    const existingMember = this.db.getSwarmMember(swarmId, name);
    if (existingMember) {
      throw httpError(409, `Worker @${name} already exists in this swarm`);
    }

    const agentId = (input.agentId || swarm.defaultWorkerAgentId).trim();
    if (!this.sessionManager.hasAgent(agentId)) {
      throw httpError(400, `Unknown worker agent: ${agentId}`);
    }

    const modelId =
      input.modelId !== undefined
        ? typeof input.modelId === "string" && input.modelId.trim()
          ? input.modelId.trim()
          : null
        : swarm.defaultWorkerModelId;

    const requestedWorkspace: SwarmWorkspaceMode =
      input.workspace === "worktree" ? "worktree" : "inherit";

    const wsInfo =
      requestedWorkspace === "worktree"
        ? await this.prepareGitWorktree(swarmId, swarm.cwd, name)
        : {
            workspaceMode: "inherit" as SwarmWorkspaceMode,
            workerCwd: swarm.cwd,
            worktreePath: null,
            worktreeBranch: null,
          };

    const mcpServers = [this.buildMcpServer(swarmId, name)];
    const preamble = buildWorkerPromptPreamble(swarmId, name, wsInfo.workerCwd, wsInfo.worktreeBranch);
    const launchOptions: AcpSessionLaunchOptions =
      agentId === "agy"
        ? {
            mcpServers,
            meta: {
              antigravity: {
                systemPrompt: { append: preamble },
              },
            },
          }
        : { mcpServers };

    const launchKey = this.wakeKey(swarmId, name);
    this.pendingLaunchRoles.set(launchKey, "worker");
    let workerSession: SessionSummary;
    const now = Date.now();
    try {
      workerSession = await this.sessionManager.createSession({
        agentId,
        cwd: wsInfo.workerCwd,
        title: `@${name} · ${swarm.title}`.slice(0, 80),
        swarmId,
        swarmRole: "worker",
        swarmMemberName: name,
        worktreeBranch: wsInfo.worktreeBranch,
        initialModelId: modelId,
        launchOptions,
      });

      this.db.addSwarmMember({
        swarmId,
        name,
        role: "worker",
        sessionId: workerSession.id,
        agentId,
        modelId: workerSession.currentModelId ?? modelId,
        state: "working",
        workspaceMode: wsInfo.workspaceMode,
        worktreePath: wsInfo.worktreePath,
        worktreeBranch: wsInfo.worktreeBranch,
        brief,
        now,
      });
    } catch (err) {
      await this.cleanupGitWorktree(swarm.cwd, wsInfo.worktreePath);
      throw err;
    } finally {
      this.pendingLaunchRoles.delete(launchKey);
    }

    const briefText = `@${name} ${brief}`;
    const boardMsg = this.db.appendSwarmMessage({
      swarmId,
      sender: input.sender || "coordinator",
      mentions: parseMentions(briefText),
      text: briefText,
      kind: "brief",
      createdAt: now,
    });
    this.db.updateSwarmMember(swarmId, name, { lastReadSeq: boardMsg.seq });

    try {
      await this.sessionManager.startPrompt(workerSession.id, {
        text: `[留言板 #${boardMsg.seq}] ${brief}`,
        prefixSystemNote: agentId === "agy" ? undefined : preamble,
        source: "swarm",
      });
    } catch {
      this.db.updateSwarmMember(swarmId, name, { state: "error" });
    }

    const updatedSwarm = this.db.getSwarmSummary(
      swarmId,
      this.sessionManager.getRunningSessionIds()
    )!;
    const member = updatedSwarm.members.find((m) => m.name === name)!;

    this.sessionManager.emitExternal("swarm_board_post", updatedSwarm.coordinatorSessionId, {
      swarmId,
      message: boardMsg,
      swarm: updatedSwarm,
    });
    this.sessionManager.emitExternal("swarm_updated", updatedSwarm.coordinatorSessionId, {
      swarm: updatedSwarm,
    });
    this.notifyWaiters(swarmId);

    return {
      member,
      swarm: updatedSwarm,
      boardSeq: boardMsg.seq,
      ...(wsInfo.workspaceNote ? { workspaceNote: wsInfo.workspaceNote } : {}),
    };
  }

  private isWaitingInTool(swarmId: string, memberName: string): boolean {
    const set = this.waiters.get(swarmId);
    if (!set) return false;
    for (const w of set) {
      if (w.memberName === memberName) return true;
    }
    return false;
  }

  private notifyWaiters(swarmId: string): void {
    const set = this.waiters.get(swarmId);
    if (!set || set.size === 0) return;
    for (const waiter of Array.from(set)) {
      try {
        waiter.check();
      } catch {
        // ignore waiter check failure
      }
    }
  }

  private abortWaiters(swarmId: string): void {
    const set = this.waiters.get(swarmId);
    if (!set) return;
    for (const waiter of Array.from(set)) {
      try {
        waiter.abort();
      } catch {
        // ignore
      }
    }
    this.waiters.delete(swarmId);
  }

  private async wakeIdleMember(
    swarm: SwarmSummary,
    member: SwarmMember,
    triggerMessage: SwarmBoardMessage
  ): Promise<boolean> {
    if (member.state === "killed") return false;
    if (this.sessionManager.isSessionRunning(member.sessionId)) return false;

    const unread = this.db.listSwarmMessages(swarm.id, {
      since: member.lastReadSeq,
      limit: 20,
    });
    const feed = unread.length > 0 ? unread : [triggerMessage];
    const formatted = feed
      .map((m) => `#${m.seq} [${m.sender}]: ${m.text}`)
      .join("\n");

    const maxSeq = feed[feed.length - 1]?.seq ?? triggerMessage.seq;
    this.db.updateSwarmMember(swarm.id, member.name, {
      lastReadSeq: Math.max(member.lastReadSeq, maxSeq),
      state: "working",
    });

    const promptText =
      member.role === "coordinator"
        ? `[蜂群留言板新动态]\n${formatted}\n\n请根据最新汇报推进协调、整合成果或回复用户。`
        : `[蜂群留言板 @${member.name} 新消息]\n${formatted}\n\n请处理上述消息，完成后使用 swarm_post 向 @coordinator 汇报。`;

    try {
      await this.sessionManager.startPrompt(member.sessionId, {
        text: promptText,
        source: "swarm",
      });
      return true;
    } catch {
      this.db.updateSwarmMember(swarm.id, member.name, { state: "waiting" });
      return false;
    }
  }

  async postBoard(
    swarmId: string,
    input: {
      sender: string;
      text: string;
      kind?: SwarmBoardMessageKind;
    }
  ): Promise<{ message: SwarmBoardMessage; woke: string[]; swarm: SwarmSummary }> {
    const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
    if (!swarm) {
      throw httpError(404, "Swarm not found");
    }

    const text = String(input.text || "").trim();
    if (!text) {
      throw httpError(400, "text is required");
    }

    const sender = String(input.sender || "user").trim() || "user";
    const mentions = parseMentions(text);
    const kind: SwarmBoardMessageKind =
      input.kind ?? (/\[done\]/i.test(text) ? "done" : "post");

    const message = this.db.appendSwarmMessage({
      swarmId,
      sender,
      mentions,
      text,
      kind,
    });

    if (sender === "user") {
      this.pausedByUser.delete(swarmId);
      this.autoWakeCount.set(swarmId, 0);
    }

    // If a worker explicitly posts [done], reflect done status once its turn ends (or immediately if idle)
    const senderMember = swarm.members.find((m) => m.name === sender);
    if (
      senderMember &&
      senderMember.role === "worker" &&
      kind === "done" &&
      !this.sessionManager.isSessionRunning(senderMember.sessionId)
    ) {
      this.db.updateSwarmMember(swarmId, senderMember.name, { state: "done" });
    }

    const afterPostSwarm = this.db.getSwarmSummary(
      swarmId,
      this.sessionManager.getRunningSessionIds()
    )!;
    this.sessionManager.emitExternal("swarm_board_post", afterPostSwarm.coordinatorSessionId, {
      swarmId,
      message,
      swarm: afterPostSwarm,
    });

    // Determine target members to wake
    const targetNames = new Set<string>();
    const nonKilled = afterPostSwarm.members.filter(
      (m) => m.state !== "killed" && m.name !== sender
    );
    if (mentions.includes("all")) {
      for (const m of nonKilled) targetNames.add(m.name);
    } else {
      for (const m of nonKilled) {
        if (mentions.includes(m.name)) {
          targetNames.add(m.name);
        }
      }
    }
    // Worker [done] reports always notify coordinator even if worker forgot @coordinator
    if (
      sender !== "coordinator" &&
      sender !== "user" &&
      sender !== "system" &&
      kind === "done"
    ) {
      targetNames.add("coordinator");
    }

    const woke: string[] = [];
    const waitingBeforeNotify = new Set<string>();
    for (const targetName of targetNames) {
      if (this.isWaitingInTool(swarmId, targetName)) {
        waitingBeforeNotify.add(targetName);
      }
    }

    // Wake any blocked swarm_wait calls first
    this.notifyWaiters(swarmId);

    for (const targetName of targetNames) {
      const target = afterPostSwarm.members.find(
        (m) => m.name === targetName && m.state !== "killed"
      );
      if (!target) continue;

      if (waitingBeforeNotify.has(target.name)) {
        woke.push(target.name);
        continue;
      }

      if (this.sessionManager.isSessionRunning(target.sessionId)) {
        this.pendingWakes.set(this.wakeKey(swarmId, target.name), message.seq);
        continue;
      }

      if (target.role === "coordinator") {
        if (sender !== "user") {
          if (this.pausedByUser.has(swarmId)) {
            continue;
          }
          const count = this.autoWakeCount.get(swarmId) ?? 0;
          if (count >= MAX_AUTO_COORDINATOR_TURNS) {
            continue;
          }
          this.autoWakeCount.set(swarmId, count + 1);
        }
        const ok = await this.wakeIdleMember(afterPostSwarm, target, message);
        if (ok) woke.push(target.name);
      } else {
        const ok = await this.wakeIdleMember(afterPostSwarm, target, message);
        if (ok) woke.push(target.name);
      }
    }

    const latestSwarm = this.db.getSwarmSummary(
      swarmId,
      this.sessionManager.getRunningSessionIds()
    )!;
    if (woke.length > 0) {
      this.sessionManager.emitExternal("swarm_updated", latestSwarm.coordinatorSessionId, {
        swarm: latestSwarm,
      });
    }

    return { message, woke, swarm: latestSwarm };
  }

  readBoard(
    swarmId: string,
    memberName: string,
    opts?: { since?: number; seqs?: number[]; limit?: number }
  ): { messages: SwarmBoardMessage[]; headSeq: number } {
    const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
    if (!swarm) {
      throw httpError(404, "Swarm not found");
    }

    const messages = this.db.listSwarmMessages(swarmId, opts);
    const headSeq = this.db.getSwarmHeadSeq(swarmId);

    const member = this.db.getSwarmMember(swarmId, memberName);
    if (member) {
      const highestRead = messages.reduce((acc, m) => Math.max(acc, m.seq), member.lastReadSeq);
      const nextRead = opts?.seqs ? highestRead : Math.max(highestRead, headSeq);
      if (nextRead > member.lastReadSeq) {
        this.db.updateSwarmMember(swarmId, memberName, { lastReadSeq: nextRead });
      }
    }

    return { messages, headSeq };
  }

  waitBoard(
    swarmId: string,
    memberName: string,
    opts?: { since?: number; mentionsOnly?: boolean; timeoutSeconds?: number }
  ): Promise<WaitBoardResult> {
    const member = this.db.getSwarmMember(swarmId, memberName);
    if (!member) {
      return Promise.reject(httpError(404, `Swarm member not found: ${memberName}`));
    }

    const since = Math.max(0, Math.trunc(Number(opts?.since ?? 0) || 0));
    const mentionsOnly = opts?.mentionsOnly !== undefined ? Boolean(opts.mentionsOnly) : true;
    const rawTimeout = Number(opts?.timeoutSeconds ?? 90);
    const clampedSeconds = Math.min(
      240,
      Math.max(5, Number.isFinite(rawTimeout) ? rawTimeout : 90)
    );

    const buildSnapshot = (
      reason: WaitBoardResult["reason"],
      messages: SwarmBoardMessage[],
      matchedSeqs: number[],
      headSeq: number,
      swarm: SwarmSummary
    ): WaitBoardResult => {
      if (headSeq > member.lastReadSeq) {
        this.db.updateSwarmMember(swarmId, memberName, { lastReadSeq: headSeq });
      }
      const workers = swarm.members
        .filter((m) => m.role === "worker")
        .map((w) => ({
          name: w.name,
          agentId: w.agentId,
          modelId: w.modelId,
          state: w.state,
          isRunning: w.isRunning,
          worktreeBranch: w.worktreeBranch,
        }));
      return { reason, messages, matchedSeqs, headSeq, workers };
    };

    const evaluate = (): WaitBoardResult | null => {
      const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
      if (!swarm) {
        return { reason: "closed", messages: [], matchedSeqs: [], headSeq: since, workers: [] };
      }

      const newMessages = this.db.listSwarmMessages(swarmId, { since, limit: 100 });
      const headSeq = swarm.headSeq;
      const matched = newMessages.filter((m) => {
        if (m.sender === memberName) return false;
        if (!mentionsOnly) return true;
        return (
          m.mentions.includes(memberName) ||
          m.mentions.includes("all") ||
          (member.role === "coordinator" && m.kind === "done")
        );
      });

      if (matched.length > 0) {
        return buildSnapshot(
          "message",
          newMessages,
          matched.map((m) => m.seq),
          headSeq,
          swarm
        );
      }

      const nonKilledWorkers = swarm.members.filter(
        (m) => m.role === "worker" && m.state !== "killed"
      );
      const anyWorking = nonKilledWorkers.some(
        (w) => w.state === "working" || w.isRunning
      );
      if (nonKilledWorkers.length > 0 && !anyWorking) {
        return buildSnapshot("all_workers_idle", newMessages, [], headSeq, swarm);
      }

      return null;
    };

    const immediate = evaluate();
    if (immediate) {
      return Promise.resolve(immediate);
    }

    return new Promise<WaitBoardResult>((resolve) => {
      let settled = false;
      const cleanup = () => {
        clearTimeout(timer);
        const set = this.waiters.get(swarmId);
        if (set) {
          set.delete(entry);
          if (set.size === 0) this.waiters.delete(swarmId);
        }
      };

      const finish = (res: WaitBoardResult) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(res);
      };

      const entry: WaiterEntry = {
        memberName,
        check: () => {
          const hit = evaluate();
          if (hit) finish(hit);
        },
        abort: () => {
          finish({
            reason: "closed",
            messages: [],
            matchedSeqs: [],
            headSeq: this.db.getSwarmHeadSeq(swarmId),
            workers: [],
          });
        },
      };

      const timer = setTimeout(() => {
        const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
        if (!swarm) {
          finish({ reason: "closed", messages: [], matchedSeqs: [], headSeq: since, workers: [] });
          return;
        }
        const newMessages = this.db.listSwarmMessages(swarmId, { since, limit: 100 });
        finish(buildSnapshot("timeout", newMessages, [], swarm.headSeq, swarm));
      }, clampedSeconds * 1000);
      timer.unref();

      let set = this.waiters.get(swarmId);
      if (!set) {
        set = new Set<WaiterEntry>();
        this.waiters.set(swarmId, set);
      }
      set.add(entry);
    });
  }

  async killWorker(
    swarmId: string,
    name: string,
    opts?: { removeWorktree?: boolean }
  ): Promise<{ ok: true; swarm: SwarmSummary }> {
    const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
    if (!swarm) {
      throw httpError(404, "Swarm not found");
    }

    const member = this.db.getSwarmMember(swarmId, name);
    if (!member) {
      throw httpError(404, `Worker not found: ${name}`);
    }
    if (member.role !== "worker") {
      throw httpError(400, "Cannot kill coordinator; delete the swarm instead");
    }

    this.pendingWakes.delete(this.wakeKey(swarmId, name));
    this.turnStartPostSeq.delete(member.sessionId);

    // Mark killed first so turn-finished hooks ignore the forced disposal
    this.db.updateSwarmMember(swarmId, name, { state: "killed" });
    await this.sessionManager.disposeSessionWorker(member.sessionId);

    const removeWorktree = opts?.removeWorktree !== false;
    if (removeWorktree && member.worktreePath) {
      await this.cleanupGitWorktree(swarm.cwd, member.worktreePath);
      this.db.updateSwarmMember(swarmId, name, { worktreePath: null });
    }

    const updated = this.emitSwarmUpdated(swarmId)!;
    this.notifyWaiters(swarmId);
    return { ok: true, swarm: updated };
  }

  async deleteSwarm(
    swarmId: string,
    opts?: { skipSessionId?: string }
  ): Promise<boolean> {
    const swarm = this.db.getSwarmSummary(swarmId, this.sessionManager.getRunningSessionIds());
    if (!swarm) {
      return false;
    }

    this.pausedByUser.delete(swarmId);
    this.autoWakeCount.delete(swarmId);
    for (const m of swarm.members) {
      this.pendingWakes.delete(this.wakeKey(swarmId, m.name));
      this.turnStartPostSeq.delete(m.sessionId);
      this.injectedCoordinatorPrompt.delete(m.sessionId);
    }
    this.abortWaiters(swarmId);

    // Dispose all ACP child processes before cleaning worktrees (critical on Windows)
    await Promise.all(
      swarm.members.map((m) => this.sessionManager.disposeSessionWorker(m.sessionId))
    );

    for (const m of swarm.members) {
      if (m.worktreePath) {
        await this.cleanupGitWorktree(swarm.cwd, m.worktreePath);
      }
    }
    const swarmWorktreeDir = path.join(this.config.dataDir, "worktrees", swarmId);
    try {
      if (fs.existsSync(swarmWorktreeDir)) {
        fs.rmSync(swarmWorktreeDir, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
      }
    } catch {
      // ignore
    }

    for (const m of swarm.members) {
      if (m.sessionId !== opts?.skipSessionId) {
        this.sessionManager.deleteSession(m.sessionId, { skipDeletedHooks: true });
      }
    }

    const deleted = this.db.deleteSwarm(swarmId);
    if (deleted) {
      this.sessionManager.emitExternal("swarm_deleted", swarm.coordinatorSessionId, { swarmId });
    }
    return deleted;
  }

  async getModelsOverview(agentId?: string): Promise<{
    agents: Array<{
      agentId: string;
      name: string;
      defaultModelId: string | null;
      models: AcpModelInfo[];
      error?: string;
    }>;
  }> {
    const targets = agentId
      ? this.sessionManager.getAgents().filter((a) => a.id === agentId)
      : this.sessionManager.getAgents();
    if (agentId && targets.length === 0) {
      throw httpError(404, `Unknown agent: ${agentId}`);
    }

    const results = await Promise.all(
      targets.map(async (agent) => {
        try {
          const info = await this.sessionManager.probeAgentModels(agent.id);
          return {
            agentId: agent.id,
            name: agent.name,
            defaultModelId: info.defaultModelId,
            models: info.models,
          };
        } catch (err) {
          return {
            agentId: agent.id,
            name: agent.name,
            defaultModelId: null,
            models: [] as AcpModelInfo[],
            error: err instanceof Error ? err.message : String(err),
          };
        }
      })
    );

    return { agents: results };
  }

  private async handleTurnFinished(ev: TurnFinishedEvent): Promise<void> {
    const runningIds = this.sessionManager.getRunningSessionIds();
    const member = this.db.getSwarmMemberBySessionId(ev.sessionId, runningIds);
    if (!member || member.state === "killed") return;

    const swarm = this.db.getSwarmSummary(member.swarmId, runningIds);
    if (!swarm) return;

    const startPostSeq = this.turnStartPostSeq.get(ev.sessionId) ?? 0;
    this.turnStartPostSeq.delete(ev.sessionId);

    if (member.role === "worker") {
      const postedDuringTurn = member.lastPostSeq > startPostSeq;
      let nextState: SwarmMemberState;
      if (ev.status === "error") {
        nextState = "error";
      } else if (ev.status === "cancelled") {
        nextState = "waiting";
      } else if (!postedDuringTurn) {
        nextState = "done";
      } else {
        const lastMsgs = this.db.listSwarmMessages(member.swarmId, {
          seqs: [member.lastPostSeq],
        });
        nextState = lastMsgs[0]?.kind === "done" ? "done" : "waiting";
      }

      this.db.updateSwarmMember(member.swarmId, member.name, { state: nextState });

      if (!postedDuringTurn && ev.status !== "cancelled") {
        // Fallback auto-bridge so coordinator never deadlocks if worker forgets swarm_post
        const summary = ev.content.replace(/\s+/g, " ").trim().slice(0, 1000);
        const fallbackText =
          ev.status === "error"
            ? `@coordinator [error] ${ev.error || summary || "工人执行出错"}`
            : `@coordinator [done] ${summary || "已完成当前轮次（无文本输出）"}`;
        await this.postBoard(member.swarmId, {
          sender: member.name,
          text: fallbackText,
          kind: ev.status === "error" ? "status" : "done",
        });
      } else {
        this.emitSwarmUpdated(member.swarmId);
        this.notifyWaiters(member.swarmId);

        // If worker posted a non-mention note while coordinator is idle, wake coordinator cleanly
        const latestSwarm = this.db.getSwarmSummary(
          member.swarmId,
          this.sessionManager.getRunningSessionIds()
        );
        const coord = latestSwarm?.members.find((m) => m.role === "coordinator");
        if (
          latestSwarm &&
          coord &&
          member.lastPostSeq > coord.lastReadSeq &&
          !this.sessionManager.isSessionRunning(coord.sessionId) &&
          !this.isWaitingInTool(member.swarmId, coord.name) &&
          !this.pausedByUser.has(member.swarmId) &&
          (this.autoWakeCount.get(member.swarmId) ?? 0) < MAX_AUTO_COORDINATOR_TURNS
        ) {
          const trigger = this.db.listSwarmMessages(member.swarmId, {
            seqs: [member.lastPostSeq],
          })[0];
          if (trigger) {
            this.autoWakeCount.set(
              member.swarmId,
              (this.autoWakeCount.get(member.swarmId) ?? 0) + 1
            );
            await this.wakeIdleMember(latestSwarm, coord, trigger);
            this.emitSwarmUpdated(member.swarmId);
          }
        }
      }

      // Drain any queued mention for this worker that arrived mid-turn
      const pKey = this.wakeKey(member.swarmId, member.name);
      const pendingSeq = this.pendingWakes.get(pKey);
      if (pendingSeq !== undefined) {
        this.pendingWakes.delete(pKey);
        const latestSwarm = this.db.getSwarmSummary(
          member.swarmId,
          this.sessionManager.getRunningSessionIds()
        );
        const freshWorker = latestSwarm?.members.find((m) => m.name === member.name);
        if (latestSwarm && freshWorker && freshWorker.state !== "killed" && pendingSeq > freshWorker.lastReadSeq) {
          const msg = this.db.listSwarmMessages(member.swarmId, { seqs: [pendingSeq] })[0];
          if (msg) {
            await this.wakeIdleMember(latestSwarm, freshWorker, msg);
            this.emitSwarmUpdated(member.swarmId);
          }
        }
      }
      return;
    }

    // Coordinator turn finished
    if (ev.userCancelled) {
      this.pausedByUser.add(member.swarmId);
    }
    this.db.updateSwarmMember(member.swarmId, member.name, {
      state: ev.status === "error" ? "error" : "waiting",
    });
    this.emitSwarmUpdated(member.swarmId);

    const pKey = this.wakeKey(member.swarmId, member.name);
    const pendingSeq = this.pendingWakes.get(pKey);
    if (pendingSeq !== undefined) {
      this.pendingWakes.delete(pKey);
      if (
        !this.pausedByUser.has(member.swarmId) &&
        (this.autoWakeCount.get(member.swarmId) ?? 0) < MAX_AUTO_COORDINATOR_TURNS
      ) {
        const latestSwarm = this.db.getSwarmSummary(
          member.swarmId,
          this.sessionManager.getRunningSessionIds()
        );
        const coord = latestSwarm?.members.find((m) => m.role === "coordinator");
        if (latestSwarm && coord && pendingSeq > coord.lastReadSeq) {
          const msg = this.db.listSwarmMessages(member.swarmId, { seqs: [pendingSeq] })[0];
          if (msg) {
            this.autoWakeCount.set(
              member.swarmId,
              (this.autoWakeCount.get(member.swarmId) ?? 0) + 1
            );
            await this.wakeIdleMember(latestSwarm, coord, msg);
            this.emitSwarmUpdated(member.swarmId);
          }
        }
      }
    }
  }

  private async handleSessionDeleted(session: SessionSummary): Promise<void> {
    if (!session.swarmId || !session.swarmRole) return;
    if (session.swarmRole === "coordinator") {
      await this.deleteSwarm(session.swarmId, { skipSessionId: session.id });
      return;
    }
    if (session.swarmRole === "worker" && session.swarmMemberName) {
      const swarm = this.db.getSwarmSummary(session.swarmId);
      const member = this.db.getSwarmMember(session.swarmId, session.swarmMemberName);
      if (swarm && member && member.state !== "killed") {
        this.db.updateSwarmMember(session.swarmId, member.name, {
          state: "killed",
          worktreePath: null,
        });
        await this.cleanupGitWorktree(swarm.cwd, member.worktreePath);
        this.emitSwarmUpdated(session.swarmId);
        this.notifyWaiters(session.swarmId);
      }
    }
  }

  disposeAll(): void {
    for (const swarmId of Array.from(this.waiters.keys())) {
      this.abortWaiters(swarmId);
    }
    this.pausedByUser.clear();
    this.autoWakeCount.clear();
    this.pendingWakes.clear();
    this.turnStartPostSeq.clear();
    this.injectedCoordinatorPrompt.clear();
    this.pendingLaunchRoles.clear();
  }
}
