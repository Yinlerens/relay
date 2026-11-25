import { DatabaseSync } from "node:sqlite";
import type {
  AcpConfigOption,
  AcpModeInfo,
  AcpModelInfo,
  AcpSlashCommand,
  AttachmentRef,
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
    `);

    // Recover cleanly if a previous server restart interrupted an in-flight turn
    this.db
      .prepare("UPDATE messages SET status = 'error' WHERE status = 'streaming'")
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
         ORDER BY s.updated_at DESC`
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
    now: number;
  }): SessionSummary {
    this.db
      .prepare(
        `INSERT INTO sessions (
          id, agent_id, acp_session_id, title, cwd,
          current_model_id, current_mode_id,
          available_models_json, available_modes_json,
          config_options_json, available_commands_json,
          context_used, context_size, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)`
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
      updatedAt: number;
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
    add("updated_at", patch.updatedAt ?? Date.now());

    values.push(id);
    this.db.prepare(`UPDATE sessions SET ${sets.join(", ")} WHERE id = ?`).run(...(values as never[]));
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

  close(): void {
    this.db.close();
  }
}
