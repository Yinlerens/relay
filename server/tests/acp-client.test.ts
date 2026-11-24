import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { AcpClient, pickAutoApproveOption } from "../src/acp/client.js";
import type { JsonRpcNotification } from "../src/acp/types.js";

const mockAgentScript = `
const readline = require("node:readline");
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
let pendingTurnTimer = null;

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\\n");
}

rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);

  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: 1 } });
    return;
  }

  if (msg.method === "session/new") {
    send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        sessionId: "mock-sess-1",
        models: { currentModelId: "m1", availableModels: [{ modelId: "m1", name: "Model 1" }] },
        modes: { currentModeId: "bypassPermissions", availableModes: [{ id: "bypassPermissions", name: "Bypass" }] },
        configOptions: [{ id: "multitask", name: "Multitask", type: "boolean", currentValue: false }]
      }
    });
    return;
  }

  if (msg.method === "session/set_config_option") {
    send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        configOptions: [{ id: msg.params.configId, name: "Opt", type: typeof msg.params.value === "boolean" ? "boolean" : "select", currentValue: msg.params.value }]
      }
    });
    return;
  }

  if (msg.method === "session/prompt") {
    // Emit permission request with integer id = 0 (like codebuddy)
    send({
      jsonrpc: "2.0",
      id: 0,
      method: "session/request_permission",
      params: {
        sessionId: msg.params.sessionId,
        options: [
          { optionId: "reject", name: "Reject", kind: "reject_once" },
          { optionId: "allow", name: "Allow", kind: "allow_once" }
        ]
      }
    });

    // Store prompt id to reply after permission approval arrives
    globalThis.__promptId = msg.id;
    return;
  }

  if (msg.method === "session/cancel") {
    if (pendingTurnTimer) {
      clearTimeout(pendingTurnTimer);
      pendingTurnTimer = null;
    }
    if (globalThis.__promptId !== undefined) {
      const pid = globalThis.__promptId;
      globalThis.__promptId = undefined;
      send({ jsonrpc: "2.0", id: pid, result: { stopReason: "cancelled" } });
    }
    return;
  }

  // Response to our permission request
  if (msg.id === 0 && msg.result) {
    // Also test string permission id = "perm-str"
    send({
      jsonrpc: "2.0",
      id: "perm-str",
      method: "session/request_permission",
      params: {
        sessionId: "mock-sess-1",
        options: [
          { optionId: "allow_always", name: "Always", kind: "allow_always" },
          { optionId: "allow", name: "Allow", kind: "allow_once" }
        ]
      }
    });
    return;
  }

  if (msg.id === "perm-str" && msg.result) {
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: { sessionId: "mock-sess-1", update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "thinking..." } } }
    });
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: { sessionId: "mock-sess-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hello " } } }
    });
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: { sessionId: "mock-sess-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "world" } } }
    });
    const pid = globalThis.__promptId;
    pendingTurnTimer = setTimeout(() => {
      send({ jsonrpc: "2.0", id: pid, result: { stopReason: "end_turn" } });
    }, 30);
  }
});
`;

describe("AcpClient", () => {
  let tmpDir: string | null = null;
  let client: AcpClient | null = null;

  afterEach(async () => {
    await client?.dispose();
    client = null;
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
      tmpDir = null;
    }
  });

  it("picks allow_always before allow_once", () => {
    const picked = pickAutoApproveOption([
      { optionId: "deny", kind: "reject_once" },
      { optionId: "allow", kind: "allow_once" },
      { optionId: "allow_always", kind: "allow_always" },
    ]);
    assert.equal(picked, "allow_always");
  });

  it("handles initialize, config booleans, numeric & string permission IDs, and streaming", async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-acp-test-"));
    const scriptPath = path.join(tmpDir, "mock-acp.cjs");
    fs.writeFileSync(scriptPath, mockAgentScript, "utf8");

    const notifications: JsonRpcNotification[] = [];
    client = new AcpClient(process.execPath, [scriptPath], undefined, {
      onNotification: (n) => notifications.push(n),
    });
    client.start(tmpDir);

    const init = (await client.initialize()) as { protocolVersion: number };
    assert.equal(init.protocolVersion, 1);

    const sess = await client.newSession(tmpDir);
    assert.equal(sess.sessionId, "mock-sess-1");

    const cfgRes = await client.setConfigOption("mock-sess-1", "multitask", true);
    const opts = cfgRes.configOptions as Array<{ currentValue: unknown }>;
    assert.equal(opts[0].currentValue, true);

    const promptRes = await client.prompt("mock-sess-1", [{ type: "text", text: "hi" }]);
    assert.equal(promptRes.stopReason, "end_turn");

    const updates = notifications.map((n) => (n.params?.update as { sessionUpdate?: string })?.sessionUpdate);
    assert.deepEqual(updates, [
      "agent_thought_chunk",
      "agent_message_chunk",
      "agent_message_chunk",
    ]);
  });
});
