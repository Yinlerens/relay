import type { FastifyInstance } from "fastify";
import type { RelayDatabase } from "../db.js";
import { sendBarkNotification } from "../utils/bark.js";

export function registerSettingsRoutes(app: FastifyInstance, db: RelayDatabase): void {
  app.get("/api/settings", async () => ({
    barkUrl: db.getSetting("bark_url") || "",
  }));

  app.put<{ Body: { barkUrl?: string; testBark?: boolean } }>(
    "/api/settings",
    async (req) => {
      const barkUrl = (req.body?.barkUrl ?? "").trim();
      db.setSetting("bark_url", barkUrl);
      if (req.body?.testBark && barkUrl) {
        await sendBarkNotification(barkUrl, "Relay", "Bark 通知测试成功");
      }
      return { barkUrl };
    }
  );
}
