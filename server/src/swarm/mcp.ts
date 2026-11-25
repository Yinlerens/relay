import type { FastifyInstance } from "fastify";
import type { SwarmWorkspaceMode } from "../acp/types.js";
import type { SwarmManager } from "./manager.js";

interface McpToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

const TOOL_SWARM_STATUS: McpToolDef = {
  name: "swarm_status",
  description:
    "查看当前蜂群全员名单、状态、Agent/模型、worktree 分支、积分消耗及留言板最新 seq。",
  inputSchema: {
    type: "object",
    properties: {},
    additionalProperties: false,
  },
};

const TOOL_SWARM_MODELS: McpToolDef = {
  name: "swarm_models",
  description: "查询 Relay 已配置的可用 Agent 及其模型列表（含积分说明）。",
  inputSchema: {
    type: "object",
    properties: {
      agentId: {
        type: "string",
        description: "可选，仅查询指定 Agent（如 agy 或 codebuddy）。",
      },
    },
    additionalProperties: false,
  },
};

const TOOL_SWARM_ADD: McpToolDef = {
  name: "swarm_add",
  description:
    "在蜂群中派生一名新工人并向留言板发布任务简报。写代码任务建议 workspace='worktree' 隔离分支。",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description: "工人唯一名称，小写字母/数字/-/_，长度 1-24（不可为 all/coordinator）。",
      },
      brief: {
        type: "string",
        description: "完整任务说明：负责范围、文件边界与完成标准。",
      },
      agentId: {
        type: "string",
        description: "可选，工人使用的 Agent ID，默认跟随蜂群默认工人 Agent。",
      },
      modelId: {
        type: "string",
        description: "可选，指定工人使用的模型 ID。",
      },
      workspace: {
        type: "string",
        enum: ["inherit", "worktree"],
        description: "工作区模式：worktree（独立 Git 分支）或 inherit（共享工作目录，默认）。",
      },
    },
    required: ["name", "brief"],
    additionalProperties: false,
  },
};

const TOOL_SWARM_POST: McpToolDef = {
  name: "swarm_post",
  description: "在共享留言板发布消息。用 @成员名 唤醒特定成员，@all 广播；完成任务请以 [done] 标记。",
  inputSchema: {
    type: "object",
    properties: {
      text: {
        type: "string",
        description: "要发送的留言内容（建议带 @目标成员）。",
      },
    },
    required: ["text"],
    additionalProperties: false,
  },
};

const TOOL_SWARM_READ_BOARD: McpToolDef = {
  name: "swarm_read_board",
  description: "读取蜂群共享留言板消息。建议传 since（已读最大 seq）增量拉取。",
  inputSchema: {
    type: "object",
    properties: {
      since: {
        type: "integer",
        description: "仅返回 seq 大于该值的消息。",
      },
      seqs: {
        type: "array",
        items: { type: "integer" },
        description: "精确拉取指定 seq 列表的消息。",
      },
      limit: {
        type: "integer",
        description: "最多返回消息条数（默认 20，最大 200）。",
      },
    },
    additionalProperties: false,
  },
};

const TOOL_SWARM_WAIT: McpToolDef = {
  name: "swarm_wait",
  description:
    "阻塞等待留言板新消息或所有非 killed 工人结束当前工作。派活后调用此工具，避免轮询。",
  inputSchema: {
    type: "object",
    properties: {
      since: {
        type: "integer",
        description: "已读到的最大 seq，只关注其后的新消息。",
      },
      mentionsOnly: {
        type: "boolean",
        description: "默认 true，仅在被 @ 提及、@all 或工人 [done] 时唤醒。",
      },
      timeoutSeconds: {
        type: "integer",
        description: "等待超时秒数（默认 90，范围 5..240）。",
      },
    },
    required: ["since"],
    additionalProperties: false,
  },
};

const TOOL_SWARM_KILL: McpToolDef = {
  name: "swarm_kill",
  description: "终止指定工人进程并默认清理其 Git worktree。",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description: "要终止的工人名称。",
      },
      removeWorktree: {
        type: "boolean",
        description: "是否同步清理 worktree 目录（默认 true）。",
      },
    },
    required: ["name"],
    additionalProperties: false,
  },
};

const COORDINATOR_TOOLS: McpToolDef[] = [
  TOOL_SWARM_STATUS,
  TOOL_SWARM_MODELS,
  TOOL_SWARM_ADD,
  TOOL_SWARM_POST,
  TOOL_SWARM_READ_BOARD,
  TOOL_SWARM_WAIT,
  TOOL_SWARM_KILL,
];

const WORKER_TOOLS: McpToolDef[] = [
  TOOL_SWARM_POST,
  TOOL_SWARM_READ_BOARD,
  TOOL_SWARM_STATUS,
];

const WORKER_ALLOWED_TOOL_NAMES = new Set(WORKER_TOOLS.map((t) => t.name));

interface JsonRpcPayload {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
}

export function registerSwarmMcpRoutes(app: FastifyInstance, swarmManager: SwarmManager): void {
  const pathPattern = "/internal/mcp/swarms/:swarmId/members/:memberName";

  app.get(pathPattern, async (_req, reply) => {
    return reply.code(405).send({ error: "Method Not Allowed" });
  });

  app.delete(pathPattern, async (_req, reply) => {
    return reply.code(204).send();
  });

  app.post<{
    Params: { swarmId: string; memberName: string };
    Body: JsonRpcPayload;
  }>(pathPattern, async (req, reply) => {
    const { swarmId, memberName } = req.params;
    const body = req.body;

    if (!body || typeof body !== "object") {
      return reply.code(400).send({
        jsonrpc: "2.0",
        id: null,
        error: { code: -32600, message: "Invalid JSON-RPC request" },
      });
    }

    const hasId =
      Object.prototype.hasOwnProperty.call(body, "id") &&
      body.id !== undefined &&
      body.id !== null;

    // JSON-RPC notifications (no id) always receive 202 Accepted
    if (!hasId) {
      return reply.code(202).send();
    }

    const id = body.id!;
    const method = typeof body.method === "string" ? body.method : "";
    const params = (body.params && typeof body.params === "object"
      ? body.params
      : {}) as Record<string, unknown>;

    if (method === "server/discover") {
      return { jsonrpc: "2.0", id, result: {} };
    }

    if (method === "initialize") {
      const protocolVersion =
        typeof params.protocolVersion === "string" && params.protocolVersion
          ? params.protocolVersion
          : "2024-11-05";
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion,
          capabilities: { tools: {} },
          serverInfo: { name: "relay-swarm", version: "1.0.0" },
        },
      };
    }

    if (method === "ping") {
      return { jsonrpc: "2.0", id, result: {} };
    }

    if (method === "tools/list") {
      const role = swarmManager.resolveMemberRole(swarmId, memberName);
      if (!role) {
        return {
          jsonrpc: "2.0",
          id,
          error: { code: -32004, message: `Swarm member not found: ${swarmId}/${memberName}` },
        };
      }
      const tools = role === "coordinator" ? COORDINATOR_TOOLS : WORKER_TOOLS;
      return {
        jsonrpc: "2.0",
        id,
        result: { tools },
      };
    }

    const member = swarmManager.getSwarmMember(swarmId, memberName);
    if (!member || member.state === "killed") {
      return {
        jsonrpc: "2.0",
        id,
        error: { code: -32004, message: `Swarm member not found: ${swarmId}/${memberName}` },
      };
    }

    if (method === "tools/call") {
      const toolName = typeof params.name === "string" ? params.name : "";
      const args = (params.arguments && typeof params.arguments === "object"
        ? params.arguments
        : {}) as Record<string, unknown>;

      if (member.role !== "coordinator" && !WORKER_ALLOWED_TOOL_NAMES.has(toolName)) {
        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [
              { type: "text", text: `Permission denied: worker cannot call ${toolName}` },
            ],
            isError: true,
          },
        };
      }

      try {
        let output: unknown;
        switch (toolName) {
          case "swarm_status": {
            const swarm = swarmManager.getSwarmSummary(swarmId);
            if (!swarm) throw new Error("Swarm not found");
            output = {
              swarmId: swarm.id,
              title: swarm.title,
              cwd: swarm.cwd,
              status: swarm.status,
              headSeq: swarm.headSeq,
              totalCredits: swarm.totalCredits,
              activeWorkerCount: swarm.activeWorkerCount,
              members: swarm.members.map((m) => ({
                name: m.name,
                role: m.role,
                agentId: m.agentId,
                modelId: m.modelId,
                state: m.state,
                isRunning: m.isRunning,
                workspaceMode: m.workspaceMode,
                worktreeBranch: m.worktreeBranch,
                totalCredits: m.totalCredits,
                lastReadSeq: m.lastReadSeq,
                lastPostSeq: m.lastPostSeq,
              })),
            };
            break;
          }

          case "swarm_models": {
            const agentId = typeof args.agentId === "string" ? args.agentId.trim() : undefined;
            output = await swarmManager.getModelsOverview(agentId || undefined);
            break;
          }

          case "swarm_add": {
            const name = String(args.name ?? "");
            const brief = String(args.brief ?? "");
            const agentId = typeof args.agentId === "string" ? args.agentId : undefined;
            const modelId = typeof args.modelId === "string" ? args.modelId : undefined;
            const workspace: SwarmWorkspaceMode | undefined =
              args.workspace === "worktree" || args.workspace === "inherit"
                ? args.workspace
                : undefined;
            const added = await swarmManager.addWorker(swarmId, {
              name,
              brief,
              agentId,
              modelId,
              workspace,
              sender: member.name,
            });
            output = {
              member: added.member,
              boardSeq: added.boardSeq,
              headSeq: added.swarm.headSeq,
              ...(added.workspaceNote ? { workspaceNote: added.workspaceNote } : {}),
            };
            break;
          }

          case "swarm_post": {
            const text = String(args.text ?? "");
            const posted = await swarmManager.postBoard(swarmId, {
              sender: member.name,
              text,
            });
            output = {
              seq: posted.message.seq,
              kind: posted.message.kind,
              mentions: posted.message.mentions,
              woke: posted.woke,
              headSeq: posted.swarm.headSeq,
            };
            break;
          }

          case "swarm_read_board": {
            const since =
              typeof args.since === "number" && Number.isFinite(args.since)
                ? args.since
                : undefined;
            const seqs = Array.isArray(args.seqs)
              ? args.seqs.filter((n): n is number => typeof n === "number")
              : undefined;
            const limit =
              typeof args.limit === "number" && Number.isFinite(args.limit)
                ? args.limit
                : undefined;
            output = swarmManager.readBoard(swarmId, member.name, { since, seqs, limit });
            break;
          }

          case "swarm_wait": {
            const since = Number(args.since ?? 0);
            const mentionsOnly =
              args.mentionsOnly !== undefined ? Boolean(args.mentionsOnly) : true;
            const timeoutSeconds =
              typeof args.timeoutSeconds === "number" ? args.timeoutSeconds : undefined;
            output = await swarmManager.waitBoard(swarmId, member.name, {
              since,
              mentionsOnly,
              timeoutSeconds,
            });
            break;
          }

          case "swarm_kill": {
            const targetName = String(args.name ?? "");
            const removeWorktree =
              args.removeWorktree !== undefined ? Boolean(args.removeWorktree) : true;
            const killed = await swarmManager.killWorker(swarmId, targetName, {
              removeWorktree,
            });
            output = {
              ok: killed.ok,
              killed: targetName,
              activeWorkerCount: killed.swarm.activeWorkerCount,
              headSeq: killed.swarm.headSeq,
            };
            break;
          }

          default:
            return {
              jsonrpc: "2.0",
              id,
              result: {
                content: [{ type: "text", text: `Unknown tool: ${toolName}` }],
                isError: true,
              },
            };
        }

        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [
              {
                type: "text",
                text: typeof output === "string" ? output : JSON.stringify(output, null, 2),
              },
            ],
            isError: false,
          },
        };
      } catch (err) {
        return {
          jsonrpc: "2.0",
          id,
          result: {
            content: [
              {
                type: "text",
                text: err instanceof Error ? err.message : String(err),
              },
            ],
            isError: true,
          },
        };
      }
    }

    return {
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: `Method not found: ${method}` },
    };
  });
}
