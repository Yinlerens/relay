import type { FastifyInstance } from "fastify";
import type {
  RelayDatabase,
  WuwaPullRecord,
  WuwaResonatorHistoryEntry,
} from "../db.js";

export function registerWuwaRoutes(app: FastifyInstance, db: RelayDatabase): void {
  app.get<{ Querystring: { gameRoleId?: string } }>("/api/wuwa/sync", async (req) => {
    const pulls = db.listWuwaPulls();
    const histories = db.listWuwaResonatorHistory(req.query?.gameRoleId);
    return {
      pulls,
      histories,
      stats: {
        pullCount: pulls.length,
        historyCount: histories.length,
      },
    };
  });

  app.post<{ Body: { pulls?: WuwaPullRecord[] } }>(
    "/api/wuwa/sync/pulls",
    { bodyLimit: 15 * 1024 * 1024 },
    async (req, reply) => {
      const pulls = req.body?.pulls;
      if (!Array.isArray(pulls)) {
        return reply.code(400).send({ error: "pulls must be an array" });
      }
      const { added, total } = db.mergeWuwaPulls(pulls);
      return { ok: true, added, total };
    }
  );

  app.post<{ Body: { histories?: WuwaResonatorHistoryEntry[] } }>(
    "/api/wuwa/sync/history",
    { bodyLimit: 25 * 1024 * 1024 },
    async (req, reply) => {
      const histories = req.body?.histories;
      if (!Array.isArray(histories)) {
        return reply.code(400).send({ error: "histories must be an array" });
      }
      const { added, total } = db.mergeWuwaResonatorHistory(histories);
      return { ok: true, added, total };
    }
  );

  app.post<{ Body: { pulls?: WuwaPullRecord[]; histories?: WuwaResonatorHistoryEntry[] } }>(
    "/api/wuwa/sync",
    { bodyLimit: 30 * 1024 * 1024 },
    async (req, reply) => {
      const pulls = req.body?.pulls;
      const histories = req.body?.histories;
      if (pulls !== undefined && !Array.isArray(pulls)) {
        return reply.code(400).send({ error: "pulls must be an array" });
      }
      if (histories !== undefined && !Array.isArray(histories)) {
        return reply.code(400).send({ error: "histories must be an array" });
      }
      const pullsResult = pulls ? db.mergeWuwaPulls(pulls) : { added: 0, total: db.listWuwaPulls().length };
      const historiesResult = histories
        ? db.mergeWuwaResonatorHistory(histories)
        : { added: 0, total: db.listWuwaResonatorHistory().length };
      return {
        ok: true,
        pullsAdded: pullsResult.added,
        pullsTotal: pullsResult.total,
        historiesAdded: historiesResult.added,
        historiesTotal: historiesResult.total,
      };
    }
  );
}
