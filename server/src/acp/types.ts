export type ConfigValue = string | boolean;

export interface AcpModelInfo {
  modelId: string;
  name: string;
  description?: string;
}

export interface AcpModeInfo {
  id: string;
  name: string;
  description?: string;
}

export interface AcpConfigOptionChoice {
  value: string;
  name: string;
  description?: string;
}

export interface AcpConfigOption {
  id: string;
  name: string;
  description?: string;
  category?: string;
  type: "select" | "boolean";
  currentValue: ConfigValue;
  options?: AcpConfigOptionChoice[];
}

export interface AcpSlashCommand {
  name: string;
  description: string;
  hint?: string;
}

export interface ToolActivityItem {
  id: string;
  name: string;
  title: string;
  kind: string;
  status: string;
  inputPreview?: string;
  outputPreview?: string;
  locations?: string[];
}

export interface AttachmentRef {
  id: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  isImage: boolean;
}

export interface UsageStats {
  inputTokens?: number;
  outputTokens?: number;
  cachedReadTokens?: number;
  thoughtTokens?: number;
  totalTokens?: number;
  credits?: number;
  originalCredits?: number;
}

export interface AcpMcpServerHeader {
  name: string;
  value: string;
}

export interface AcpMcpServerConfig {
  type: "http";
  name: string;
  url: string;
  headers: AcpMcpServerHeader[];
}

export interface AcpSessionLaunchOptions {
  mcpServers?: AcpMcpServerConfig[];
  meta?: Record<string, unknown>;
}

export type SwarmRole = "coordinator" | "worker";
export type SwarmMemberState = "waiting" | "working" | "done" | "error" | "killed";
export type SwarmWorkspaceMode = "inherit" | "worktree";
export type SwarmBoardMessageKind = "brief" | "post" | "done" | "status" | "system";
export type SwarmStatus = "active" | "completed" | "archived";

export interface SwarmMember {
  swarmId: string;
  name: string;
  role: SwarmRole;
  sessionId: string;
  agentId: string;
  modelId: string | null;
  state: SwarmMemberState;
  workspaceMode: SwarmWorkspaceMode;
  worktreePath: string | null;
  worktreeBranch: string | null;
  brief: string;
  totalCredits: number;
  isRunning: boolean;
  lastReadSeq: number;
  lastPostSeq: number;
  createdAt: number;
  updatedAt: number;
}

export interface SwarmBoardMessage {
  id: number;
  swarmId: string;
  seq: number;
  sender: string;
  mentions: string[];
  text: string;
  kind: SwarmBoardMessageKind;
  createdAt: number;
}

export interface SwarmSummary {
  id: string;
  title: string;
  cwd: string;
  coordinatorSessionId: string;
  coordinatorAgentId: string;
  defaultWorkerAgentId: string;
  defaultWorkerModelId: string | null;
  status: SwarmStatus;
  headSeq: number;
  totalCredits: number;
  activeWorkerCount: number;
  members: SwarmMember[];
  createdAt: number;
  updatedAt: number;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: string | number;
  result?: unknown;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: string | number;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: Record<string, unknown>;
}
