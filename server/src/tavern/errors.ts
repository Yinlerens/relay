import type { TavernErrorKind } from "./types.js";

export function httpError(statusCode: number, message: string): Error {
  const err = new Error(message) as Error & { statusCode?: number };
  err.statusCode = statusCode;
  return err;
}

export function formatTavernHttpError(status: number, rawBody: string): string {
  let detail = "";
  const trimmed = String(rawBody || "").trim();
  if (trimmed) {
    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      const errField = parsed?.error;
      if (errField && typeof errField === "object") {
        const msg = (errField as Record<string, unknown>).message;
        if (typeof msg === "string" && msg.trim()) {
          detail = msg.trim();
        }
      } else if (typeof errField === "string" && errField.trim()) {
        detail = errField.trim();
      }
      if (!detail && typeof parsed?.message === "string" && parsed.message.trim()) {
        detail = parsed.message.trim();
      }
    } catch {
      // Plain text or HTML error response
    }
    if (!detail) {
      detail = trimmed.replace(/<[^>]*>/g, " ");
    }
    detail = detail.replace(/\s+/g, " ").trim().slice(0, 180);
  }

  if (status === 429) {
    return detail
      ? `上游接口限流 (429)：${detail}`
      : "上游接口限流 (429)：资源暂时耗尽，请稍后重试";
  }
  if (status === 401 || status === 403) {
    return `上游接口鉴权或权限拒绝 (${status})${detail ? `：${detail}` : ""}`;
  }
  if (status >= 500) {
    return `上游接口服务异常 (${status})${detail ? `：${detail}` : ""}`;
  }
  return `生成请求失败 (${status})${detail ? `：${detail}` : ""}`;
}

export function classifyTavernError(
  message: string,
  statusCode?: number | null
): TavernErrorKind {
  if (
    statusCode === 429 ||
    /429|RESOURCE_EXHAUSTED|rate.?limit|quota|too many requests|限流/i.test(message)
  ) {
    return "rate_limit";
  }
  if (/PROHIBITED_CONTENT|SAFETY|blockReason|blocked|content.?policy|审核|拦截|拒绝/i.test(message)) {
    return "safety";
  }
  if (
    statusCode === 401 ||
    statusCode === 403 ||
    /401|403|unauthorized|forbidden|api.?key|鉴权/i.test(message)
  ) {
    return "auth";
  }
  if (
    (statusCode !== undefined && statusCode !== null && statusCode >= 500) ||
    /500|502|503|504|bad gateway|overloaded|unavailable|服务异常/i.test(message)
  ) {
    return "server";
  }
  if (/timeout|timed out|ECONNREFUSED|ENOTFOUND|network|fetch failed|连接/i.test(message)) {
    return "network";
  }
  return "unknown";
}

export function extractTavernResponseError(
  status: number,
  contentType: string,
  rawBody: string
): { message: string; kind: TavernErrorKind; code: number | null } | null {
  if (status >= 400) {
    const message = formatTavernHttpError(status, rawBody);
    return { message, kind: classifyTavernError(message, status), code: status };
  }
  if (status < 200 || status >= 300) {
    return null;
  }

  const trimmed = String(rawBody || "").trim();
  if (!trimmed) return null;
  const ct = String(contentType || "").toLowerCase();

  if (ct.includes("json") || trimmed.startsWith("{")) {
    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      const errField = parsed?.error;
      let detail = "";
      if (errField && typeof errField === "object") {
        const msg = (errField as Record<string, unknown>).message;
        if (typeof msg === "string" && msg.trim()) detail = msg.trim();
      } else if (typeof errField === "string" && errField.trim()) {
        detail = errField.trim();
      }
      if (detail) {
        detail = detail.replace(/\s+/g, " ").trim().slice(0, 180);
        const kind = classifyTavernError(detail, null);
        const message =
          kind === "safety"
            ? `内容被上游安全审核拦截：${detail}`
            : `上游接口返回错误：${detail}`;
        return { message, kind, code: null };
      }
    } catch {
      // Ignore malformed JSON
    }
    return null;
  }

  if (ct.includes("event-stream") || trimmed.includes("data:")) {
    const lines = trimmed.split(/\r?\n/);
    let hasText = false;
    let foundError: string | null = null;
    let safetyReason: string | null = null;

    for (const line of lines) {
      const m = line.match(/^\s*data:\s*(.+)$/);
      if (!m) continue;
      const payloadStr = m[1].trim();
      if (!payloadStr || payloadStr === "[DONE]") continue;
      try {
        const chunk = JSON.parse(payloadStr) as Record<string, unknown>;
        if (chunk?.error && typeof chunk.error === "object") {
          const msg = (chunk.error as Record<string, unknown>).message;
          if (typeof msg === "string" && msg.trim()) foundError = msg.trim();
        }
        const pf = chunk?.promptFeedback as Record<string, unknown> | undefined;
        if (pf && typeof pf.blockReason === "string" && pf.blockReason) {
          safetyReason = pf.blockReason;
        }
        const cands = chunk?.candidates as Array<Record<string, unknown>> | undefined;
        if (Array.isArray(cands)) {
          for (const cand of cands) {
            const content = cand?.content as Record<string, unknown> | undefined;
            const parts = content?.parts as Array<Record<string, unknown>> | undefined;
            if (Array.isArray(parts)) {
              for (const p of parts) {
                if (typeof p?.text === "string" && p.text.trim() && !p.thought) {
                  hasText = true;
                }
              }
            }
            const fr = typeof cand?.finishReason === "string" ? cand.finishReason : "";
            if (/^(PROHIBITED_CONTENT|SAFETY|BLOCKLIST|RECITATION|SPII)$/i.test(fr)) {
              safetyReason = fr;
            }
          }
        }
      } catch {
        // Ignore non-JSON SSE lines
      }
    }

    if (foundError && !hasText) {
      const clean = foundError.replace(/\s+/g, " ").trim().slice(0, 180);
      const kind = classifyTavernError(clean, null);
      const message =
        kind === "safety" ? `内容被上游安全审核拦截：${clean}` : `上游接口返回错误：${clean}`;
      return { message, kind, code: null };
    }
    if (safetyReason && !hasText) {
      return {
        message: `内容被上游安全审核拦截 (${safetyReason})`,
        kind: "safety",
        code: null,
      };
    }
  }

  return null;
}
