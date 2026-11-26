import { DatabaseSync } from "node:sqlite";
import type {
  AcpConfigOption,
  AcpModeInfo,
  AcpModelInfo,
  AcpSlashCommand,
  AttachmentRef,
  SwarmBoardMessage,
  SwarmBoardMessageKind,
  SwarmMember,
  SwarmMemberState,
  SwarmRole,
  SwarmStatus,
  SwarmSummary,
  SwarmWorkspaceMode,
  ToolActivityItem,
  UsageStats,
} from "./acp/types.js";

export interface SessionSummary {
  id: string;
  agentId: string;
  acpSessionId: string | null;
  title: string;
  cwd: string;
  currentModelId: string | null;
  currentModeId: string | null;
  availableModels: AcpModelInfo[];
  availableModes: AcpModeInfo[];
  configOptions: AcpConfigOption[];
  availableCommands: AcpSlashCommand[];
  contextUsed: number;
  contextSize: number;
  totalCredits: number;
  isRunning: boolean;
  swarmId: string | null;
  swarmRole: SwarmRole | null;
  swarmMemberName: string | null;
  worktreeBranch: string | null;
  pinned: boolean;
  createdAt: number;
  updatedAt: number;
}

export type MessageStatus = "completed" | "streaming" | "cancelled" | "error";

export interface MessageRecord {
  id: string;
  sessionId: string;
  role: "user" | "assistant";
  content: string;
  thinking: string;
  attachments: AttachmentRef[];
  toolCalls: ToolActivityItem[];
  usage: UsageStats | null;
  status: MessageStatus;
  createdAt: number;
}

export interface UploadRecord {
  id: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  diskPath: string;
  createdAt: number;
}

function safeJson<T>(raw: unknown, fallback: T): T {
  if (typeof raw !== "string" || !raw) {
    return fallback;
  }
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export class RelayDatabase {
  private readonly db: DatabaseSync;

  constructor(dbPath: string) {
    this.db = new DatabaseSync(dbPath);
    this.db.exec("PRAGMA journal_mode = WAL;");
    this.db.exec("PRAGMA foreign_keys = ON;");
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        acp_session_id TEXT,
        title TEXT NOT NULL,
        cwd TEXT NOT NULL,
        current_model_id TEXT,
        current_mode_id TEXT,
        available_models_json TEXT NOT NULL DEFAULT '[]',
        available_modes_json TEXT NOT NULL DEFAULT '[]',
        config_options_json TEXT NOT NULL DEFAULT '[]',
        available_commands_json TEXT NOT NULL DEFAULT '[]',
        context_used INTEGER NOT NULL DEFAULT 0,
        context_size INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(updated_at DESC);

      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        thinking TEXT NOT NULL DEFAULT '',
        attachments_json TEXT NOT NULL DEFAULT '[]',
        tool_calls_json TEXT NOT NULL DEFAULT '[]',
        usage_json TEXT,
        status TEXT NOT NULL DEFAULT 'completed',
        created_at INTEGER NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, created_at ASC);

      CREATE TABLE IF NOT EXISTS uploads (
        id TEXT PRIMARY KEY,
        filename TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        disk_path TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS swarms (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        cwd TEXT NOT NULL,
        coordinator_session_id TEXT NOT NULL,
        coordinator_agent_id TEXT NOT NULL,
        default_worker_agent_id TEXT NOT NULL,
        default_worker_model_id TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_swarms_updated ON swarms(updated_at DESC);

      CREATE TABLE IF NOT EXISTS swarm_members (
        swarm_id TEXT NOT NULL REFERENCES swarms(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        role TEXT NOT NULL,
        session_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        model_id TEXT,
        state TEXT NOT NULL DEFAULT 'waiting',
        workspace_mode TEXT NOT NULL DEFAULT 'inherit',
        worktree_path TEXT,
        worktree_branch TEXT,
        brief TEXT NOT NULL DEFAULT '',
        last_read_seq INTEGER NOT NULL DEFAULT 0,
        last_post_seq INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (swarm_id, name)
      );

      CREATE INDEX IF NOT EXISTS idx_swarm_members_session ON swarm_members(session_id);

      CREATE TABLE IF NOT EXISTS swarm_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        swarm_id TEXT NOT NULL REFERENCES swarms(id) ON DELETE CASCADE,
        seq INTEGER NOT NULL,
        sender TEXT NOT NULL,
        mentions_json TEXT NOT NULL DEFAULT '[]',
        text TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'post',
        created_at INTEGER NOT NULL,
        UNIQUE(swarm_id, seq)
      );

      CREATE INDEX IF NOT EXISTS idx_swarm_messages_swarm_seq ON swarm_messages(swarm_id, seq ASC);
    `);

    // Idempotent column migration on existing sessions table
    const sessionCols = new Set(
      (
        this.db.prepare("PRAGMA table_info(sessions)").all() as Array<{ name?: string }>
      ).map((c) => String(c.name || ""))
    );
    const addSessionCol = (name: string, ddl: string) => {
      if (!sessionCols.has(name)) {
        this.db.exec(`ALTER TABLE sessions ADD COLUMN ${name} ${ddl}`);
      }
    };
    addSessionCol("swarm_id", "TEXT");
    addSessionCol("swarm_role", "TEXT");
    addSessionCol("swarm_member_name", "TEXT");
    addSessionCol("worktree_branch", "TEXT");
    addSessionCol("pinned", "INTEGER NOT NULL DEFAULT 0");
    this.db.exec("CREATE INDEX IF NOT EXISTS idx_sessions_swarm ON sessions(swarm_id);");

    // Recover cleanly if a previous server restart interrupted in-flight turns or workers
    this.db
      .prepare("UPDATE messages SET status = 'error' WHERE status = 'streaming'")
      .run();
    this.db
      .prepare("UPDATE swarm_members SET state = 'waiting' WHERE state = 'working'")
      .run();
  }

  private mapSession(row: Record<string, unknown>, runningIds?: Set<string>): SessionSummary {
    const id = String(row.id);
    return {
      id,
      agentId: String(row.agent_id),
      acpSessionId: row.acp_session_id ? String(row.acp_session_id) : null,
      title: String(row.title),
      cwd: String(row.cwd),
      currentModelId: row.current_model_id ? String(row.current_model_id) : null,
      currentModeId: row.current_mode_id ? String(row.current_mode_id) : null,
      availableModels: safeJson<AcpModelInfo[]>(row.available_models_json, []),
      availableModes: safeJson<AcpModeInfo[]>(row.available_modes_json, []),
      configOptions: safeJson<AcpConfigOption[]>(row.config_options_json, []),
      availableCommands: safeJson<AcpSlashCommand[]>(row.available_commands_json, []),
      contextUsed: Number(row.context_used || 0),
      contextSize: Number(row.context_size || 0),
      totalCredits: Math.round(Number(row.total_credits || 0) * 10000) / 10000,
      isRunning: runningIds ? runningIds.has(id) : false,
      swarmId: row.swarm_id ? String(row.swarm_id) : null,
      swarmRole:
        row.swarm_role === "coordinator" || row.swarm_role === "worker"
          ? row.swarm_role
          : null,
      swarmMemberName: row.swarm_member_name ? String(row.swarm_member_name) : null,
      worktreeBranch: row.worktree_branch ? String(row.worktree_branch) : null,
      pinned: Boolean(row.pinned),
      createdAt: Number(row.created_at),
      updatedAt: Number(row.updated_at),
    };
  }

  private mapMessage(row: Record<string, unknown>): MessageRecord {
    return {
      id: String(row.id),
      sessionId: String(row.session_id),
      role: row.role === "user" ? "user" : "assistant",
      content: String(row.content || ""),
      thinking: String(row.thinking || ""),
      attachments: safeJson<AttachmentRef[]>(row.attachments_json, []),
      toolCalls: safeJson<ToolActivityItem[]>(row.tool_calls_json, []),
      usage: safeJson<UsageStats | null>(row.usage_json, null),
      status: (row.status as MessageStatus) || "completed",
      createdAt: Number(row.created_at),
    };
  }

  listSessions(runningIds?: Set<string>): SessionSummary[] {
    const rows = this.db
      .prepare(
        `SELECT s.*, COALESCE(c.total_credits, 0) AS total_credits
         FROM sessions s
         LEFT JOIN (
           SELECT session_id,
                  SUM(CAST(json_extract(usage_json, '$.credits') AS REAL)) AS total_credits
           FROM messages
           WHERE role = 'assistant'
             AND usage_json IS NOT NULL
             AND json_valid(usage_json) = 1
             AND typeof(json_extract(usage_json, '$.credits')) IN ('integer', 'real')
           GROUP BY session_id
         ) c ON c.session_id = s.id
         ORDER BY s.pinned DESC, s.updated_at DESC`
      )
      .all() as Record<string, unknown>[];
    return rows.map((row) => this.mapSession(row, runningIds));
  }

  getSession(id: string, runningIds?: Set<string>): SessionSummary | null {
    const row = this.db
      .prepare(
        `SELECT s.*,
                COALESCE(
                  (
                    SELECT SUM(CAST(json_extract(m.usage_json, '$.credits') AS REAL))
                    FROM messages m
                    WHERE m.session_id = s.id
                      AND m.role = 'assistant'
                      AND m.usage_json IS NOT NULL
                      AND json_valid(m.usage_json) = 1
                      AND typeof(json_extract(m.usage_json, '$.credits')) IN ('integer', 'real')
                  ),
                  0
                ) AS total_credits
         FROM sessions s
         WHERE s.id = ?`
      )
      .get(id) as Record<string, unknown> | undefined;
    return row ? this.mapSession(row, runningIds) : null;
  }

  createSession(input: {
    id: string;
    agentId: string;
    acpSessionId: string | null;
    title: string;
    cwd: string;
    currentModelId: string | null;
    currentModeId: string | null;
    availableModels: AcpModelInfo[];
    availableModes: AcpModeInfo[];
    configOptions: AcpConfigOption[];
    availableCommands: AcpSlashCommand[];
    swarmId?: string | null;
    swarmRole?: SwarmRole | null;
    swarmMemberName?: string | null;
    worktreeBranch?: string | null;
    now: number;
  }): SessionSummary {
    this.db
      .prepare(
        `INSERT INTO sessions (
          id, agent_id, acp_session_id, title, cwd,
          current_model_id, current_mode_id,
          available_models_json, available_modes_json,
          config_options_json, available_commands_json,
          context_used, context_size,
          swarm_id, swarm_role, swarm_member_name, worktree_branch,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        input.id,
        input.agentId,
        input.acpSessionId,
        input.title,
        input.cwd,
        input.currentModelId,
        input.currentModeId,
        JSON.stringify(input.availableModels),
        JSON.stringify(input.availableModes),
        JSON.stringify(input.configOptions),
        JSON.stringify(input.availableCommands),
        input.swarmId ?? null,
        input.swarmRole ?? null,
        input.swarmMemberName ?? null,
        input.worktreeBranch ?? null,
        input.now,
        input.now
      );
    return this.getSession(input.id)!;
  }

  updateSession(
    id: string,
    patch: Partial<{
      acpSessionId: string | null;
      title: string;
      currentModelId: string | null;
      currentModeId: string | null;
      availableModels: AcpModelInfo[];
      availableModes: AcpModeInfo[];
      configOptions: AcpConfigOption[];
      availableCommands: AcpSlashCommand[];
      contextUsed: number;
      contextSize: number;
      swarmId: string | null;
      swarmRole: SwarmRole | null;
      swarmMemberName: string | null;
      worktreeBranch: string | null;
      pinned: boolean;
      updatedAt: number;
      touchUpdatedAt: boolean;
    }>
  ): void {
    const sets: string[] = [];
    const values: unknown[] = [];

    const add = (col: string, val: unknown) => {
      sets.push(`${col} = ?`);
      values.push(val);
    };

    if (patch.acpSessionId !== undefined) add("acp_session_id", patch.acpSessionId);
    if (patch.title !== undefined) add("title", patch.title);
    if (patch.currentModelId !== undefined) add("current_model_id", patch.currentModelId);
    if (patch.currentModeId !== undefined) add("current_mode_id", patch.currentModeId);
    if (patch.availableModels !== undefined)
      add("available_models_json", JSON.stringify(patch.availableModels));
    if (patch.availableModes !== undefined)
      add("available_modes_json", JSON.stringify(patch.availableModes));
    if (patch.configOptions !== undefined)
      add("config_options_json", JSON.stringify(patch.configOptions));
    if (patch.availableCommands !== undefined)
      add("available_commands_json", JSON.stringify(patch.availableCommands));
    if (patch.contextUsed !== undefined) add("context_used", patch.contextUsed);
    if (patch.contextSize !== undefined) add("context_size", patch.contextSize);
    if (patch.swarmId !== undefined) add("swarm_id", patch.swarmId);
    if (patch.swarmRole !== undefined) add("swarm_role", patch.swarmRole);
    if (patch.swarmMemberName !== undefined) add("swarm_member_name", patch.swarmMemberName);
    if (patch.worktreeBranch !== undefined) add("worktree_branch", patch.worktreeBranch);
    if (patch.pinned !== undefined) add("pinned", patch.pinned ? 1 : 0);
    if (patch.updatedAt !== undefined) {
      add("updated_at", patch.updatedAt);
    } else if (patch.touchUpdatedAt !== false) {
      add("updated_at", Date.now());
    }

    if (sets.length === 0) return;
    values.push(id);
    this.db.prepare(`UPDATE sessions SET ${sets.join(", ")} WHERE id = ?`).run(...(values as never[]));
  }

  getLatestAgentModels(
    agentId: string
  ): { models: AcpModelInfo[]; defaultModelId: string | null } | null {
    const rows = this.db
      .prepare(
        `SELECT current_model_id, available_models_json
         FROM sessions
         WHERE agent_id = ?
           AND available_models_json IS NOT NULL
           AND available_models_json != '[]'
         ORDER BY updated_at DESC
         LIMIT 5`
      )
      .all(agentId) as Record<string, unknown>[];

    for (const row of rows) {
      const models = safeJson<AcpModelInfo[]>(row.available_models_json, []);
      if (models.length > 0) {
        return {
          models,
          defaultModelId: row.current_model_id
            ? String(row.current_model_id)
            : models[0]?.modelId ?? null,
        };
      }
    }
    return null;
  }

  deleteSession(id: string): boolean {
    const res = this.db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
    return Number(res.changes) > 0;
  }

  listMessages(sessionId: string): MessageRecord[] {
    const rows = this.db
      .prepare("SELECT * FROM messages WHERE session_id = ? ORDER BY created_at ASC")
      .all(sessionId) as Record<string, unknown>[];
    return rows.map((row) => this.mapMessage(row));
  }

  createMessage(msg: MessageRecord): MessageRecord {
    this.db
      .prepare(
        `INSERT INTO messages (
          id, session_id, role, content, thinking,
          attachments_json, tool_calls_json, usage_json, status, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        msg.id,
        msg.sessionId,
        msg.role,
        msg.content,
        msg.thinking,
        JSON.stringify(msg.attachments),
        JSON.stringify(msg.toolCalls),
        msg.usage ? JSON.stringify(msg.usage) : null,
        msg.status,
        msg.createdAt
      );
    return msg;
  }

  updateMessage(
    id: string,
    patch: Partial<{
      content: string;
      thinking: string;
      toolCalls: ToolActivityItem[];
      usage: UsageStats | null;
      status: MessageStatus;
    }>
  ): void {
    const sets: string[] = [];
    const values: unknown[] = [];

    if (patch.content !== undefined) {
      sets.push("content = ?");
      values.push(patch.content);
    }
    if (patch.thinking !== undefined) {
      sets.push("thinking = ?");
      values.push(patch.thinking);
    }
    if (patch.toolCalls !== undefined) {
      sets.push("tool_calls_json = ?");
      values.push(JSON.stringify(patch.toolCalls));
    }
    if (patch.usage !== undefined) {
      sets.push("usage_json = ?");
      values.push(patch.usage ? JSON.stringify(patch.usage) : null);
    }
    if (patch.status !== undefined) {
      sets.push("status = ?");
      values.push(patch.status);
    }
    if (sets.length === 0) return;

    values.push(id);
    this.db.prepare(`UPDATE messages SET ${sets.join(", ")} WHERE id = ?`).run(...(values as never[]));
  }

  createUpload(upload: UploadRecord): UploadRecord {
    this.db
      .prepare(
        `INSERT INTO uploads (id, filename, mime_type, size_bytes, disk_path, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(
        upload.id,
        upload.filename,
        upload.mimeType,
        upload.sizeBytes,
        upload.diskPath,
        upload.createdAt
      );
    return upload;
  }

  getUpload(id: string): UploadRecord | null {
    const row = this.db
      .prepare("SELECT * FROM uploads WHERE id = ?")
      .get(id) as Record<string, unknown> | undefined;
    if (!row) return null;
    return {
      id: String(row.id),
      filename: String(row.filename),
      mimeType: String(row.mime_type),
      sizeBytes: Number(row.size_bytes),
      diskPath: String(row.disk_path),
      createdAt: Number(row.created_at),
    };
  }

  listUploads(): UploadRecord[] {
    const rows = this.db
      .prepare("SELECT * FROM uploads ORDER BY created_at ASC")
      .all() as Record<string, unknown>[];
    return rows.map((row) => ({
      id: String(row.id),
      filename: String(row.filename),
      mimeType: String(row.mime_type),
      sizeBytes: Number(row.size_bytes),
      diskPath: String(row.disk_path),
      createdAt: Number(row.created_at),
    }));
  }

  deleteUpload(id: string): boolean {
    const res = this.db.prepare("DELETE FROM uploads WHERE id = ?").run(id);
    return Number(res.changes) > 0;
  }

  listSessionAttachmentIds(sessionId: string): string[] {
    const rows = this.db
      .prepare(
        "SELECT attachments_json FROM messages WHERE session_id = ? AND attachments_json IS NOT NULL AND attachments_json != '[]'"
      )
      .all(sessionId) as Array<{ attachments_json?: string }>;
    const ids = new Set<string>();
    for (const row of rows) {
      for (const att of safeJson<AttachmentRef[]>(row.attachments_json, [])) {
        if (att?.id) ids.add(att.id);
      }
    }
    return Array.from(ids);
  }

  listAllReferencedAttachmentIds(): Set<string> {
    const rows = this.db
      .prepare(
        "SELECT attachments_json FROM messages WHERE attachments_json IS NOT NULL AND attachments_json != '[]'"
      )
      .all() as Array<{ attachments_json?: string }>;
    const ids = new Set<string>();
    for (const row of rows) {
      for (const att of safeJson<AttachmentRef[]>(row.attachments_json, [])) {
        if (att?.id) ids.add(att.id);
      }
    }
    return ids;
  }

  getSetting(key: string): string | null {
    const row = this.db
      .prepare("SELECT value FROM settings WHERE key = ?")
      .get(key) as Record<string, unknown> | undefined;
    return row ? String(row.value) : null;
  }

  setSetting(key: string, value: string): void {
    this.db
      .prepare(
        `INSERT INTO settings (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`
      )
      .run(key, value);
  }

  private mapSwarmMember(row: Record<string, unknown>, runningIds?: Set<string>): SwarmMember {
    const sessionId = String(row.session_id);
    const state = (String(row.state || "waiting") as SwarmMemberState) || "waiting";
    const isRunning = state !== "killed" && (runningIds ? runningIds.has(sessionId) : false);
    const rawCredits = Number(row.total_credits || 0);
    return {
      swarmId: String(row.swarm_id),
      name: String(row.name),
      role: row.role === "coordinator" ? "coordinator" : "worker",
      sessionId,
      agentId: String(row.agent_id),
      modelId: row.resolved_model_id
        ? String(row.resolved_model_id)
        : row.model_id
          ? String(row.model_id)
          : null,
      state,
      workspaceMode: row.workspace_mode === "worktree" ? "worktree" : "inherit",
      worktreePath: row.worktree_path ? String(row.worktree_path) : null,
      worktreeBranch: row.worktree_branch ? String(row.worktree_branch) : null,
      brief: String(row.brief || ""),
      totalCredits: Number.isFinite(rawCredits) ? Math.round(rawCredits * 10000) / 10000 : 0,
      isRunning,
      lastReadSeq: Number(row.last_read_seq || 0),
      lastPostSeq: Number(row.last_post_seq || 0),
      createdAt: Number(row.created_at),
      updatedAt: Number(row.updated_at),
    };
  }

  private mapSwarmMessage(row: Record<string, unknown>): SwarmBoardMessage {
    return {
      id: Number(row.id),
      swarmId: String(row.swarm_id),
      seq: Number(row.seq),
      sender: String(row.sender),
      mentions: safeJson<string[]>(row.mentions_json, []),
      text: String(row.text || ""),
      kind: (String(row.kind || "post") as SwarmBoardMessageKind) || "post",
      createdAt: Number(row.created_at),
    };
  }

  createSwarm(input: {
    id: string;
    title: string;
    cwd: string;
    coordinatorSessionId: string;
    coordinatorAgentId: string;
    defaultWorkerAgentId: string;
    defaultWorkerModelId: string | null;
    status?: SwarmStatus;
    now: number;
  }): void {
    this.db
      .prepare(
        `INSERT INTO swarms (
          id, title, cwd, coordinator_session_id, coordinator_agent_id,
          default_worker_agent_id, default_worker_model_id, status,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        input.id,
        input.title,
        input.cwd,
        input.coordinatorSessionId,
        input.coordinatorAgentId,
        input.defaultWorkerAgentId,
        input.defaultWorkerModelId,
        input.status ?? "active",
        input.now,
        input.now
      );
  }

  updateSwarm(
    id: string,
    patch: Partial<{
      title: string;
      status: SwarmStatus;
      defaultWorkerAgentId: string;
      defaultWorkerModelId: string | null;
      updatedAt: number;
    }>
  ): void {
    const sets: string[] = [];
    const values: unknown[] = [];

    const add = (col: string, val: unknown) => {
      sets.push(`${col} = ?`);
      values.push(val);
    };

    if (patch.title !== undefined) add("title", patch.title);
    if (patch.status !== undefined) add("status", patch.status);
    if (patch.defaultWorkerAgentId !== undefined)
      add("default_worker_agent_id", patch.defaultWorkerAgentId);
    if (patch.defaultWorkerModelId !== undefined)
      add("default_worker_model_id", patch.defaultWorkerModelId);
    add("updated_at", patch.updatedAt ?? Date.now());

    values.push(id);
    this.db.prepare(`UPDATE swarms SET ${sets.join(", ")} WHERE id = ?`).run(...(values as never[]));
  }

  deleteSwarm(id: string): boolean {
    const res = this.db.prepare("DELETE FROM swarms WHERE id = ?").run(id);
    return Number(res.changes) > 0;
  }

  addSwarmMember(input: {
    swarmId: string;
    name: string;
    role: SwarmRole;
    sessionId: string;
    agentId: string;
    modelId: string | null;
    state?: SwarmMemberState;
    workspaceMode?: SwarmWorkspaceMode;
    worktreePath?: string | null;
    worktreeBranch?: string | null;
    brief?: string;
    now: number;
  }): void {
    this.db
      .prepare(
        `INSERT INTO swarm_members (
          swarm_id, name, role, session_id, agent_id, model_id,
          state, workspace_mode, worktree_path, worktree_branch,
          brief, last_read_seq, last_post_seq, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)`
      )
      .run(
        input.swarmId,
        input.name,
        input.role,
        input.sessionId,
        input.agentId,
        input.modelId,
        input.state ?? "waiting",
        input.workspaceMode ?? "inherit",
        input.worktreePath ?? null,
        input.worktreeBranch ?? null,
        input.brief ?? "",
        input.now,
        input.now
      );
  }

  updateSwarmMember(
    swarmId: string,
    name: string,
    patch: Partial<{
      modelId: string | null;
      state: SwarmMemberState;
      workspaceMode: SwarmWorkspaceMode;
      worktreePath: string | null;
      worktreeBranch: string | null;
      brief: string;
      lastReadSeq: number;
      lastPostSeq: number;
      updatedAt: number;
    }>
  ): void {
    const sets: string[] = [];
    const values: unknown[] = [];

    const add = (col: string, val: unknown) => {
      sets.push(`${col} = ?`);
      values.push(val);
    };

    if (patch.modelId !== undefined) add("model_id", patch.modelId);
    if (patch.state !== undefined) add("state", patch.state);
    if (patch.workspaceMode !== undefined) add("workspace_mode", patch.workspaceMode);
    if (patch.worktreePath !== undefined) add("worktree_path", patch.worktreePath);
    if (patch.worktreeBranch !== undefined) add("worktree_branch", patch.worktreeBranch);
    if (patch.brief !== undefined) add("brief", patch.brief);
    if (patch.lastReadSeq !== undefined) add("last_read_seq", patch.lastReadSeq);
    if (patch.lastPostSeq !== undefined) add("last_post_seq", patch.lastPostSeq);
    add("updated_at", patch.updatedAt ?? Date.now());

    values.push(swarmId, name);
    this.db
      .prepare(`UPDATE swarm_members SET ${sets.join(", ")} WHERE swarm_id = ? AND name = ?`)
      .run(...(values as never[]));
  }

  listSwarmMembers(swarmId: string, runningIds?: Set<string>): SwarmMember[] {
    const rows = this.db
      .prepare(
        `SELECT sm.*,
                COALESCE(s.current_model_id, sm.model_id) AS resolved_model_id,
                COALESCE(c.total_credits, 0) AS total_credits
         FROM swarm_members sm
         LEFT JOIN sessions s ON s.id = sm.session_id
         LEFT JOIN (
           SELECT session_id,
                  SUM(CAST(json_extract(usage_json, '$.credits') AS REAL)) AS total_credits
           FROM messages
           WHERE role = 'assistant'
             AND usage_json IS NOT NULL
             AND json_valid(usage_json) = 1
             AND typeof(json_extract(usage_json, '$.credits')) IN ('integer', 'real')
           GROUP BY session_id
         ) c ON c.session_id = sm.session_id
         WHERE sm.swarm_id = ?
         ORDER BY CASE WHEN sm.role = 'coordinator' THEN 0 ELSE 1 END, sm.created_at ASC`
      )
      .all(swarmId) as Record<string, unknown>[];
    return rows.map((row) => this.mapSwarmMember(row, runningIds));
  }

  getSwarmMember(
    swarmId: string,
    name: string,
    runningIds?: Set<string>
  ): SwarmMember | null {
    const row = this.db
      .prepare(
        `SELECT sm.*,
                COALESCE(s.current_model_id, sm.model_id) AS resolved_model_id,
                COALESCE(
                  (
                    SELECT SUM(CAST(json_extract(m.usage_json, '$.credits') AS REAL))
                    FROM messages m
                    WHERE m.session_id = sm.session_id
                      AND m.role = 'assistant'
                      AND m.usage_json IS NOT NULL
                      AND json_valid(m.usage_json) = 1
                      AND typeof(json_extract(m.usage_json, '$.credits')) IN ('integer', 'real')
                  ),
                  0
                ) AS total_credits
         FROM swarm_members sm
         LEFT JOIN sessions s ON s.id = sm.session_id
         WHERE sm.swarm_id = ? AND sm.name = ?`
      )
      .get(swarmId, name) as Record<string, unknown> | undefined;
    return row ? this.mapSwarmMember(row, runningIds) : null;
  }

  getSwarmMemberBySessionId(
    sessionId: string,
    runningIds?: Set<string>
  ): SwarmMember | null {
    const row = this.db
      .prepare(
        `SELECT sm.*,
                COALESCE(s.current_model_id, sm.model_id) AS resolved_model_id,
                COALESCE(
                  (
                    SELECT SUM(CAST(json_extract(m.usage_json, '$.credits') AS REAL))
                    FROM messages m
                    WHERE m.session_id = sm.session_id
                      AND m.role = 'assistant'
                      AND m.usage_json IS NOT NULL
                      AND json_valid(m.usage_json) = 1
                      AND typeof(json_extract(m.usage_json, '$.credits')) IN ('integer', 'real')
                  ),
                  0
                ) AS total_credits
         FROM swarm_members sm
         LEFT JOIN sessions s ON s.id = sm.session_id
         WHERE sm.session_id = ?`
      )
      .get(sessionId) as Record<string, unknown> | undefined;
    return row ? this.mapSwarmMember(row, runningIds) : null;
  }

  getSwarmHeadSeq(swarmId: string): number {
    const row = this.db
      .prepare("SELECT COALESCE(MAX(seq), 0) AS head_seq FROM swarm_messages WHERE swarm_id = ?")
      .get(swarmId) as { head_seq?: number } | undefined;
    return Number(row?.head_seq || 0);
  }

  getSwarmSummary(id: string, runningIds?: Set<string>): SwarmSummary | null {
    const row = this.db.prepare("SELECT * FROM swarms WHERE id = ?").get(id) as
      | Record<string, unknown>
      | undefined;
    if (!row) return null;

    const members = this.listSwarmMembers(id, runningIds);
    const headSeq = this.getSwarmHeadSeq(id);
    const totalCredits =
      Math.round(members.reduce((sum, m) => sum + m.totalCredits, 0) * 10000) / 10000;
    const activeWorkerCount = members.filter(
      (m) => m.role === "worker" && m.state !== "killed" && (m.isRunning || m.state === "working")
    ).length;

    return {
      id: String(row.id),
      title: String(row.title),
      cwd: String(row.cwd),
      coordinatorSessionId: String(row.coordinator_session_id),
      coordinatorAgentId: String(row.coordinator_agent_id),
      defaultWorkerAgentId: String(row.default_worker_agent_id),
      defaultWorkerModelId: row.default_worker_model_id
        ? String(row.default_worker_model_id)
        : null,
      status: (String(row.status || "active") as SwarmStatus) || "active",
      headSeq,
      totalCredits,
      activeWorkerCount,
      members,
      createdAt: Number(row.created_at),
      updatedAt: Number(row.updated_at),
    };
  }

  listSwarms(runningIds?: Set<string>): SwarmSummary[] {
    const rows = this.db
      .prepare("SELECT id FROM swarms ORDER BY updated_at DESC")
      .all() as Array<{ id: string }>;
    const out: SwarmSummary[] = [];
    for (const r of rows) {
      const summary = this.getSwarmSummary(String(r.id), runningIds);
      if (summary) out.push(summary);
    }
    return out;
  }

  appendSwarmMessage(input: {
    swarmId: string;
    sender: string;
    mentions: string[];
    text: string;
    kind: SwarmBoardMessageKind;
    createdAt?: number;
  }): SwarmBoardMessage {
    const now = input.createdAt ?? Date.now();
    const seq = this.getSwarmHeadSeq(input.swarmId) + 1;
    const res = this.db
      .prepare(
        `INSERT INTO swarm_messages (swarm_id, seq, sender, mentions_json, text, kind, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        input.swarmId,
        seq,
        input.sender,
        JSON.stringify(input.mentions),
        input.text,
        input.kind,
        now
      );

    this.db.prepare("UPDATE swarms SET updated_at = ? WHERE id = ?").run(now, input.swarmId);
    this.db
      .prepare(
        "UPDATE swarm_members SET last_post_seq = ?, updated_at = ? WHERE swarm_id = ? AND name = ?"
      )
      .run(seq, now, input.swarmId, input.sender);

    return {
      id: Number(res.lastInsertRowid),
      swarmId: input.swarmId,
      seq,
      sender: input.sender,
      mentions: input.mentions,
      text: input.text,
      kind: input.kind,
      createdAt: now,
    };
  }

  listSwarmMessages(
    swarmId: string,
    opts?: { since?: number; seqs?: number[]; limit?: number }
  ): SwarmBoardMessage[] {
    if (opts?.seqs && opts.seqs.length > 0) {
      const cleanSeqs = opts.seqs
        .map((n) => Math.trunc(Number(n)))
        .filter((n) => Number.isFinite(n) && n > 0);
      if (cleanSeqs.length === 0) return [];
      const placeholders = cleanSeqs.map(() => "?").join(", ");
      const rows = this.db
        .prepare(
          `SELECT * FROM swarm_messages WHERE swarm_id = ? AND seq IN (${placeholders}) ORDER BY seq ASC`
        )
        .all(swarmId, ...cleanSeqs) as Record<string, unknown>[];
      return rows.map((row) => this.mapSwarmMessage(row));
    }

    if (opts?.since !== undefined) {
      const since = Math.max(0, Math.trunc(Number(opts.since) || 0));
      const limit = Math.min(200, Math.max(1, Math.trunc(Number(opts.limit ?? 50) || 50)));
      const rows = this.db
        .prepare(
          `SELECT * FROM swarm_messages WHERE swarm_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?`
        )
        .all(swarmId, since, limit) as Record<string, unknown>[];
      return rows.map((row) => this.mapSwarmMessage(row));
    }

    if (opts?.limit !== undefined) {
      const limit = Math.min(200, Math.max(1, Math.trunc(Number(opts.limit) || 20)));
      const rows = this.db
        .prepare(
          `SELECT * FROM (
             SELECT * FROM swarm_messages WHERE swarm_id = ? ORDER BY seq DESC LIMIT ?
           ) ORDER BY seq ASC`
        )
        .all(swarmId, limit) as Record<string, unknown>[];
      return rows.map((row) => this.mapSwarmMessage(row));
    }

    const rows = this.db
      .prepare("SELECT * FROM swarm_messages WHERE swarm_id = ? ORDER BY seq ASC")
      .all(swarmId) as Record<string, unknown>[];
    return rows.map((row) => this.mapSwarmMessage(row));
  }

  close(): void {
    this.db.close();
  }
}
