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
