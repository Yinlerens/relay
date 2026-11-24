import multipart from "@fastify/multipart";
import websocket from "@fastify/websocket";
import Fastify from "fastify";
import { SessionManager } from "./acp/manager.js";
import { makeAuthHook } from "./auth.js";
import { loadAgentProfiles, loadConfig } from "./config.js";
import { RelayDatabase } from "./db.js";
import { registerSessionRoutes } from "./routes/sessions.js";
import { registerSettingsRoutes } from "./routes/settings.js";
import { registerUploadRoutes } from "./routes/uploads.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const agents = loadAgentProfiles(config.agentsConfigPath);
  const db = new RelayDatabase(config.dbPath);
  const manager = new SessionManager(config, db, agents);

  const app = Fastify({ logger: false });

  await app.register(multipart, {
    limits: {
      fileSize: 25 * 1024 * 1024,
      files: 1,
    },
  });
  await app.register(websocket);

  app.addHook("onRequest", makeAuthHook(config.relayToken));

  app.get("/healthz", async () => ({
    ok: true,
    service: "relay",
    agents: manager.getAgents().map((a) => a.id),
  }));

  registerSessionRoutes(app, config, db, manager);
  registerUploadRoutes(app, config, db);
  registerSettingsRoutes(app, db);

  app.get("/ws", { websocket: true }, (socket) => {
    const unsubscribe = manager.subscribe((ev) => {
      if (socket.readyState === 1) {
        socket.send(JSON.stringify(ev));
      }
    });

    socket.on("message", (raw: Buffer | string) => {
      try {
        const msg = JSON.parse(raw.toString()) as { type?: string };
        if (msg.type === "ping" && socket.readyState === 1) {
          socket.send(JSON.stringify({ type: "pong", ts: Date.now() }));
        }
      } catch {
        // ignore malformed frames
      }
    });

    socket.on("close", () => {
      unsubscribe();
    });
  });

  const shutdown = async () => {
    manager.disposeAll();
    db.close();
    await app.close();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  await app.listen({ host: config.host, port: config.port });
  console.log(`Relay listening on http://${config.host}:${config.port}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
