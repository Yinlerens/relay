import { createRelayServer } from "./app.js";
import { loadAgentProfiles, loadConfig } from "./config.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const agents = loadAgentProfiles(config.agentsConfigPath);
  const server = await createRelayServer(config, agents, {
    logger: { level: process.env.RELAY_LOG_LEVEL || "warn" },
  });

  const shutdown = async () => {
    await server.close();
    process.exit(0);
  };

  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());

  const { host, port } = await server.listen();
  console.log(`Relay listening on http://${host}:${port}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
