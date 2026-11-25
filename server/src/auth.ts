import crypto from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";

export function verifyToken(candidate: string | undefined, expected: string): boolean {
  if (!expected) {
    return true;
  }
  if (!candidate) {
    return false;
  }
  const a = Buffer.from(candidate, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length) {
    return false;
  }
  return crypto.timingSafeEqual(a, b);
}

export function extractBearerToken(request: FastifyRequest): string | undefined {
  const auth = request.headers.authorization;
  if (typeof auth === "string" && auth.toLowerCase().startsWith("bearer ")) {
    return auth.slice(7).trim();
  }
  const query = request.query as Record<string, unknown> | undefined;
  if (query && typeof query.token === "string") {
    return query.token.trim();
  }
  return undefined;
}

export function makeAuthHook(expectedToken: string, internalMcpToken?: string) {
  return async function requireAuth(
    request: FastifyRequest,
    reply: FastifyReply
  ): Promise<void> {
    const pathname = request.url.split("?")[0];
    if (pathname === "/healthz") {
      return;
    }
    if (pathname.startsWith("/internal/mcp/")) {
      if (
        request.headers["x-forwarded-for"] !== undefined ||
        request.headers["x-real-ip"] !== undefined
      ) {
        await reply.code(403).send({ error: "Forbidden" });
        return;
      }
      const rawInternal = request.headers["x-relay-internal-token"];
      const candidateInternal = Array.isArray(rawInternal) ? rawInternal[0] : rawInternal;
      if (!internalMcpToken || !verifyToken(candidateInternal?.trim(), internalMcpToken)) {
        await reply.code(403).send({ error: "Forbidden" });
        return;
      }
      return;
    }
    const candidate = extractBearerToken(request);
    if (!verifyToken(candidate, expectedToken)) {
      await reply.code(401).send({ error: "Unauthorized" });
    }
  };
}
