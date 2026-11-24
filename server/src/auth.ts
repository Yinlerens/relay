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

export function makeAuthHook(expectedToken: string) {
  return async function requireAuth(
    request: FastifyRequest,
    reply: FastifyReply
  ): Promise<void> {
    if (request.url === "/healthz") {
      return;
    }
    const candidate = extractBearerToken(request);
    if (!verifyToken(candidate, expectedToken)) {
      await reply.code(401).send({ error: "Unauthorized" });
    }
  };
}
