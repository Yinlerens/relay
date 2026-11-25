import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { accumulateUsageFromMeta, mergeUsageStats } from "../src/acp/manager.js";
import type { UsageStats } from "../src/acp/types.js";
import { RelayDatabase } from "../src/db.js";
import { parseJsonFromStdout, scanCodeBuddyQuotas } from "../src/routes/quotas.js";

describe("CodeBuddy credit tracking & DB aggregation", () => {
  let tmpDir: string | null = null;
  let db: RelayDatabase | null = null;

  afterEach(() => {
    db?.close();
    db = null;
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
      tmpDir = null;
    }
  });

  it("accumulates CodeBuddy _meta.usage with deduplication and rounding", () => {
    const seen = new Set<string>();
    let usage: UsageStats | null = null;

    // First call with messageId
    usage = accumulateUsageFromMeta(usage, seen, {
      "codebuddy.ai/messageId": "msg-1",
      usage: {
        prompt_tokens: 1000,
        completion_tokens: 120,
        cache_read_input_tokens: 400,
        completion_thinking_tokens: 30,
        total_tokens: 1120,
        credit: 0.1234,
        original_credit: 0.5,
      },
    });

    // Duplicate messageId should be ignored
    usage = accumulateUsageFromMeta(usage, seen, {
      "codebuddy.ai/messageId": "msg-1",
      usage: {
        prompt_tokens: 1000,
        completion_tokens: 120,
        total_tokens: 1120,
        credit: 0.1234,
        original_credit: 0.5,
      },
    });

    // Second distinct call via requestId fallback
    usage = accumulateUsageFromMeta(usage, seen, {
      "codebuddy.ai/requestId": "req-2",
      usage: {
        prompt_tokens: 500,
        completion_tokens: 80,
        cache_read_input_tokens: 100,
        completion_thinking_tokens: 10,
        total_tokens: 580,
        credit: 0.2,
        original_credit: 0.2,
      },
    });

    assert.deepEqual(usage, {
      inputTokens: 1500,
      outputTokens: 200,
      cachedReadTokens: 500,
      thoughtTokens: 40,
      totalTokens: 1700,
      credits: 0.3234,
      originalCredits: 0.7,
    });

    // Merge when res.usage is null -> preserves full CodeBuddy turn usage
    assert.deepEqual(mergeUsageStats(null, usage), usage);

    // Merge when res.usage is present -> preserves res.usage tokens and turn credits
    const merged = mergeUsageStats(
      { inputTokens: 2000, outputTokens: 300, totalTokens: 2300 },
      usage
    );
    assert.deepEqual(merged, {
      inputTokens: 2000,
      outputTokens: 300,
      cachedReadTokens: 500,
      thoughtTokens: 40,
      totalTokens: 2300,
      credits: 0.3234,
      originalCredits: 0.7,
    });
  });

  it("computes totalCredits across assistant messages in listSessions and getSession", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-db-credits-"));
    db = new RelayDatabase(path.join(tmpDir, "relay.db"));

    const now = Date.now();
    db.createSession({
      id: "sess-1",
      agentId: "codebuddy",
      acpSessionId: "acp-1",
      title: "Credits test",
      cwd: tmpDir,
      currentModelId: "m1",
      currentModeId: "bypassPermissions",
      availableModels: [],
      availableModes: [],
      configOptions: [],
      availableCommands: [],
      now,
    });

    db.createSession({
      id: "sess-empty",
      agentId: "agy",
      acpSessionId: "acp-2",
      title: "Empty session",
      cwd: tmpDir,
      currentModelId: null,
      currentModeId: null,
      availableModels: [],
      availableModes: [],
      configOptions: [],
      availableCommands: [],
      now: now - 1000,
    });

    // User message (must be ignored even if usage exists)
    db.createMessage({
      id: "u1",
      sessionId: "sess-1",
      role: "user",
      content: "hi",
      thinking: "",
      attachments: [],
      toolCalls: [],
      usage: { credits: 99 },
      status: "completed",
      createdAt: now + 1,
    });

    db.createMessage({
      id: "a1",
      sessionId: "sess-1",
      role: "assistant",
      content: "r1",
      thinking: "",
      attachments: [],
      toolCalls: [],
      usage: { inputTokens: 100, outputTokens: 20, credits: 0.1456, originalCredits: 0.44 },
      status: "completed",
      createdAt: now + 2,
    });

    db.createMessage({
      id: "a2",
      sessionId: "sess-1",
      role: "assistant",
      content: "r2",
      thinking: "",
      attachments: [],
      toolCalls: [],
      usage: { inputTokens: 200, outputTokens: 30, credits: 0.2544, originalCredits: 0.2544 },
      status: "completed",
      createdAt: now + 3,
    });

    const single = db.getSession("sess-1");
    assert.ok(single);
    assert.equal(single.totalCredits, 0.4);

    const list = db.listSessions();
    assert.equal(list.length, 2);
    assert.equal(list.find((s) => s.id === "sess-1")?.totalCredits, 0.4);
    assert.equal(list.find((s) => s.id === "sess-empty")?.totalCredits, 0);
  });

  it("scans CodeBuddy JSONL logs with UTC+8 boundaries and parses agy stdout cleanly", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-quota-scan-"));
    const projDir = path.join(tmpDir, "home-ubuntu");
    fs.mkdirSync(projDir, { recursive: true });

    // Fixed reference time: 2026-11-25 11:00:00 +08:00 (2026-11-25T03:00:00Z)
    const nowMs = Date.parse("2026-11-25T03:00:00Z");
    const todayTs = Date.parse("2026-11-24T16:05:00Z"); // 2026-11-25 00:05 +08:00 (today)
    const yesterdayMonthTs = Date.parse("2026-11-24T15:55:00Z"); // 2026-11-24 23:55 +08:00 (this month, not today)
    const prevMonthTs = Date.parse("2026-10-31T15:50:00Z"); // 2026-10-31 23:50 +08:00 (last month)

    const lines = [
      JSON.stringify({
        timestamp: todayTs,
        providerData: {
          requestModelId: "hy4flash-free",
          rawUsage: {
            total_tokens: 1000,
            credit: 0,
            original_credit: 0.44,
            quota: { model: "hy4-flash", percent: 5, reset_at: "1795618937" },
          },
        },
      }),
      JSON.stringify({
        timestamp: yesterdayMonthTs,
        providerData: {
          requestModelId: "deepseek-v4.1-flash",
          rawUsage: {
            total_tokens: 2000,
            credit: 1.5,
            original_credit: 1.5,
            quota: { model: "hy4-flash", percent: 0, reset_at: "1795500000" }, // older ts; should NOT overwrite
          },
        },
      }),
      JSON.stringify({
        timestamp: prevMonthTs,
        providerData: {
          requestModelId: "deepseek-v4.1-flash",
          rawUsage: {
            total_tokens: 3000,
            credit: 2.0,
            original_credit: 2.0,
          },
        },
      }),
      "not-valid-json",
    ];
    fs.writeFileSync(path.join(projDir, "session.jsonl"), lines.join("\n"), "utf8");

    const res = scanCodeBuddyQuotas(tmpDir, nowMs);
    assert.equal(res.available, true);
    assert.equal(res.todayCredits, 0);
    assert.equal(res.monthCredits, 1.5);
    assert.equal(res.totalCredits, 3.5);
    assert.equal(res.totalSavedCredits, 0.44);
    assert.equal(res.byModel[0].modelId, "deepseek-v4.1-flash");
    assert.equal(res.byModel[0].credits, 3.5);
    assert.equal(res.byModel[0].calls, 2);
    assert.equal(res.byModel[0].totalTokens, 5000);
    assert.equal(res.byModel[1].modelId, "hy4flash-free");
    assert.equal(res.byModel[1].savedCredits, 0.44);
    assert.deepEqual(res.rateQuotas, [
      { model: "hy4-flash", percent: 5, resetAt: 1795618937000 },
    ]);

    const parsed = parseJsonFromStdout(
      '[warn] debug line\n{"status":"SUCCESS","command":{"data":{"remaining_credits":0}}}\n[info] bye\n'
    );
    assert.equal(parsed.status, "SUCCESS");
  });
});
