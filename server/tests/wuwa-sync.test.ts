import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it } from "node:test";
import { createRelayServer, type RelayServerInstance } from "../src/app.js";
import type { AppConfig } from "../src/config.js";
import type { WuwaPullRecord, WuwaResonatorHistoryEntry } from "../src/db.js";

function makeTempConfig(token: string): AppConfig {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "relay-wuwa-test-"));
  const uploadsDir = path.join(dir, "uploads");
  const defaultCwd = path.join(dir, "cwd");
  fs.mkdirSync(uploadsDir, { recursive: true });
  fs.mkdirSync(defaultCwd, { recursive: true });
  return {
    host: "127.0.0.1",
    port: 0,
    relayToken: token,
    dataDir: dir,
    uploadsDir,
    dbPath: path.join(dir, "relay.db"),
    agentsConfigPath: path.join(dir, "agents.json"),
    defaultCwd,
    homeDir: dir,
    stUrl: "http://127.0.0.1:8000",
    stPublicUrl: "https://st.example.com",
    tavernProfileDir: path.join(dir, "tavern-profile"),
    tavernAuthPath: path.join(dir, "tavern-auth.json"),
    tavernEnabled: false,
    stDataDir: null,
  };
}

function samplePull(id: string, name: string, pulledAt: string, quality = 5): WuwaPullRecord {
  return {
    id,
    playerId: "100385406",
    poolType: 1,
    resourceId: 1108,
    qualityLevel: quality,
    resourceType: "共鸣者",
    name,
    count: 1,
    pulledAt,
    languageCode: "zh-Hans",
    occurrence: 1,
    importedAt: "2026-11-27T00:00:00Z",
  };
}

function sampleHistory(
  resonatorId: number,
  fp: string,
  recordedAt: string,
  withDetail = true
): WuwaResonatorHistoryEntry {
  return {
    id: 1,
    gameRoleId: "100385406",
    resonatorId,
    fingerprint: fp,
    recordedAt,
    level: 90,
    chainLevel: 3,
    weaponName: "灼霜",
    weaponLevel: 90,
    weaponResonanceLevel: withDetail ? 1 : 0,
    attributes: [{ name: "暴击", value: "75.0%", iconUrl: "", sort: 5000 }],
    echoes: [],
    detail: withDetail
      ? {
          role: { roleId: resonatorId, name: "绯雪", level: 90, chainLevel: 3 },
          weapon: { weaponId: 21010016, name: "灼霜", level: 90, resonanceLevel: 1 },
          echoes: [],
          attributes: [],
        }
      : null,
  };
}

describe("wuwa sync routes and deduplication", () => {
  const servers: RelayServerInstance[] = [];
  const tempDirs: string[] = [];

  afterEach(async () => {
    while (servers.length > 0) {
      await servers.pop()!.close();
    }
    while (tempDirs.length > 0) {
      fs.rmSync(tempDirs.pop()!, { recursive: true, force: true });
    }
  });

  it("enforces bearer auth and merges pulls + resonator history with A->B->A preservation", async () => {
    const token = "secret-wuwa-token";
    const config = makeTempConfig(token);
    tempDirs.push(config.dataDir);
    const server = await createRelayServer(config, []);
    servers.push(server);
    const { baseUrl } = await server.listen();

    // Unauthenticated request rejected with 401
    const unauth = await fetch(`${baseUrl}/api/wuwa/sync`);
    assert.equal(unauth.status, 401);

    const headers = {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    };

    // Push pulls + nanosecond PC histories
    const res1 = await fetch(`${baseUrl}/api/wuwa/sync`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        pulls: [
          samplePull("p1", "绯雪", "2026-11-12 19:35:38"),
          samplePull("p2", "白芷", "2026-11-12 19:35:39", 4),
        ],
        histories: [
          sampleHistory(1108, "fp-a", "2026-11-13T20:00:27.149363700+00:00", true),
          sampleHistory(1108, "fp-b", "2026-11-22T18:33:39.100000000+00:00", true),
          sampleHistory(1307, "fp-buling", "2026-11-14T10:00:00.000000000+00:00", true),
        ],
      }),
    });
    assert.equal(res1.status, 200);
    const body1 = (await res1.json()) as {
      ok: boolean;
      pullsAdded: number;
      pullsTotal: number;
      historiesAdded: number;
      historiesTotal: number;
    };
    assert.equal(body1.ok, true);
    assert.equal(body1.pullsAdded, 2);
    assert.equal(body1.pullsTotal, 2);
    assert.equal(body1.historiesAdded, 3);
    assert.equal(body1.historiesTotal, 3);

    // Push duplicate pull, same-fingerprint iOS snapshot at later timestamp (folds with earlier),
    // and A->B->A return to fp-a (preserved as distinct transition!)
    const res2 = await fetch(`${baseUrl}/api/wuwa/sync`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        pulls: [samplePull("p1", "绯雪", "2026-11-12 19:35:38")],
        histories: [
          sampleHistory(1108, "fp-b", "2026-11-26T09:00:00Z", false),
          sampleHistory(1108, "fp-a", "2026-11-27T01:00:00Z", true),
        ],
      }),
    });
    assert.equal(res2.status, 200);
    const body2 = (await res2.json()) as {
      pullsAdded: number;
      pullsTotal: number;
      historiesAdded: number;
      historiesTotal: number;
    };
    assert.equal(body2.pullsAdded, 0);
    assert.equal(body2.pullsTotal, 2);
    assert.equal(body2.historiesAdded, 1);
    assert.equal(body2.historiesTotal, 4);

    // Verify GET /api/wuwa/sync ordering & gameRoleId filter
    const getRes = await fetch(`${baseUrl}/api/wuwa/sync?gameRoleId=100385406`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    assert.equal(getRes.status, 200);
    const payload = (await getRes.json()) as {
      pulls: WuwaPullRecord[];
      histories: WuwaResonatorHistoryEntry[];
      stats: { pullCount: number; historyCount: number };
    };
    assert.equal(payload.stats.pullCount, 2);
    assert.equal(payload.stats.historyCount, 4);

    const feixueHist = payload.histories.filter((h) => h.resonatorId === 1108);
    assert.equal(feixueHist.length, 3);
    assert.equal(feixueHist[0].fingerprint, "fp-a");
    assert.equal(feixueHist[0].recordedAt, "2026-11-27T01:00:00Z");
    assert.equal(feixueHist[1].fingerprint, "fp-b");
    // Folded fp-b preserves earlier PC recordedAt and non-null detail
    assert.equal(feixueHist[1].recordedAt, "2026-11-22T18:33:39.100000000+00:00");
    assert.ok(feixueHist[1].detail);
    assert.equal(feixueHist[2].fingerprint, "fp-a");
    assert.equal(feixueHist[2].recordedAt, "2026-11-13T20:00:27.149363700+00:00");

    // Non-matching gameRoleId returns 0 histories
    const otherRes = await fetch(`${baseUrl}/api/wuwa/sync?gameRoleId=999999999`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const otherPayload = (await otherRes.json()) as {
      histories: WuwaResonatorHistoryEntry[];
      stats: { historyCount: number };
    };
    assert.equal(otherPayload.histories.length, 0);
    assert.equal(otherPayload.stats.historyCount, 0);
  });
});
