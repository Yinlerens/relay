import crypto from "node:crypto";
import type { TavernMessage, TavernRenderBlock } from "./types.js";

const ALLOWED_ASSET_PREFIXES = [
  "/characters/",
  "/user/",
  "/backgrounds/",
  "/assets/",
  "/img/",
  "/User Avatars/",
  "/User%20Avatars/",
  "/default-expressions/",
  "/uploads/",
  "/api/images/",
  "/scripts/",
  "/css/",
];

const FORBIDDEN_PREFIXES = [
  "/api/secrets",
  "/api/settings",
  "/api/users",
  "/api/plugins",
  "/api/chats",
  "/api/characters",
  "/csrf-token",
];

/**
 * Strictly validates an internal SillyTavern relative asset path before proxying.
 * Returns normalized relative path starting with `/` or `null` if disallowed.
 */
export function sanitizeStAssetPath(rawPath: string): string | null {
  if (typeof rawPath !== "string") return null;
  const trimmed = rawPath.trim();
  if (!trimmed || !trimmed.startsWith("/")) return null;
  if (trimmed.startsWith("//")) return null;
  if (/[\r\n\0\\]/.test(trimmed)) return null;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed)) return null;

  let decoded: string;
  try {
    decoded = decodeURIComponent(trimmed);
  } catch {
    return null;
  }

  if (decoded.startsWith("//") || /[\r\n\0\\]/.test(decoded)) return null;

  const qIdx = trimmed.indexOf("?");
  const rawPathname = qIdx === -1 ? trimmed : trimmed.slice(0, qIdx);
  const decQIdx = decoded.indexOf("?");
  const decPathname = decQIdx === -1 ? decoded : decoded.slice(0, decQIdx);

  // Reject any path traversal sequences anywhere (pathname or query) before or after decoding
  const checkSegments = (p: string) =>
    p.split("/").some((seg) => seg === ".." || seg === ".");
  if (
    trimmed.includes("..") ||
    decoded.includes("..") ||
    checkSegments(rawPathname) ||
    checkSegments(decPathname)
  ) {
    return null;
  }

  // Reject protocol-like strings anywhere in pathname
  if (rawPathname.includes(":") || decPathname.includes(":")) {
    return null;
  }

  const lowerDec = decPathname.toLowerCase();
  for (const forbidden of FORBIDDEN_PREFIXES) {
    if (lowerDec === forbidden || lowerDec.startsWith(`${forbidden}/`)) {
      return null;
    }
  }

  if (rawPathname === "/thumbnail" && decPathname === "/thumbnail") {
    return trimmed;
  }

  const allowed = ALLOWED_ASSET_PREFIXES.some(
    (prefix) => rawPathname.startsWith(prefix) || decPathname.startsWith(prefix)
  );
  if (!allowed) {
    return null;
  }

  return trimmed;
}

export function buildTavernAssetProxyUrl(relativeStPath: string): string {
  const safe = sanitizeStAssetPath(relativeStPath);
  if (!safe) return "";
  return `/api/tavern/asset?path=${encodeURIComponent(safe)}`;
}

export function buildTavernAvatarUrl(avatar: string | null | undefined): string {
  if (!avatar || !avatar.trim()) return "";
  return buildTavernAssetProxyUrl(
    `/thumbnail?type=avatar&file=${encodeURIComponent(avatar.trim())}`
  );
}

function toRelaySchemeAssetUrl(rawUrl: string): string | null {
  const trimmed = rawUrl.trim();
  if (!trimmed) return null;
  if (
    /^(https?:|data:|blob:|mailto:|tel:|javascript:|relay-st:)/i.test(trimmed) ||
    trimmed.startsWith("#") ||
    trimmed.startsWith("//")
  ) {
    return null;
  }
  const normalized = trimmed.startsWith("/") ? trimmed : `/${trimmed.replace(/^\.\//, "")}`;
  const safe = sanitizeStAssetPath(normalized);
  if (!safe) return null;
  return `relay-st://asset?path=${encodeURIComponent(safe)}`;
}

/**
 * Rewrites intra-SillyTavern relative URLs in HTML attributes (`src`, `href`, `poster`)
 * and CSS `url(...)` into `relay-st://asset?path=...` while preserving external URLs.
 */
export function rewriteHtmlAssetUrls(html: string): string {
  if (!html) return html;

  // 1. Rewrite HTML attributes: src, href, poster (double-quoted, single-quoted, or unquoted)
  let out = html.replace(
    /(\b(?:src|href|poster)\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi,
    (full, prefix: string, dq?: string, sq?: string, uq?: string) => {
      const val = dq ?? sq ?? uq ?? "";
      const rewritten = toRelaySchemeAssetUrl(val);
      if (!rewritten) return full;
      const quote = sq !== undefined ? "'" : '"';
      return `${prefix}${quote}${rewritten}${quote}`;
    }
  );

  // 2. Rewrite CSS url(...)
  out = out.replace(
    /(\burl\(\s*)(?:"([^"]*)"|'([^']*)'|([^)'"\s]+))(\s*\))/gi,
    (full, open: string, dq?: string, sq?: string, uq?: string, close?: string) => {
      const val = dq ?? sq ?? uq ?? "";
      const rewritten = toRelaySchemeAssetUrl(val);
      if (!rewritten) return full;
      const quote = sq !== undefined ? "'" : '"';
      return `${open}${quote}${rewritten}${quote}${close ?? ")"}`;
    }
  );

  return out;
}

/**
 * Cleans an extracted iframe document HTML (e.g. from JS-Slash-Runner `TH-render`):
 * removes dead `blob:` script tags (which cannot load outside the source Chromium origin),
 * preserves `https://` and `/scripts/...` scripts, and rewrites all intra-ST relative URLs
 * to `relay-st://asset?path=...`.
 */
export function cleanIframeDocumentHtml(html: string): string {
  if (!html) return "";
  const withoutBlobScripts = html.replace(
    /<script\b[^>]*\bsrc\s*=\s*(?:"blob:[^"]*"|'blob:[^']*')[^>]*>[\s\S]*?<\/script>/gi,
    ""
  );
  return rewriteHtmlAssetUrls(withoutBlobScripts);
}

export function computeRenderedHash(blocks: TavernRenderBlock[]): string {
  return crypto.createHash("sha1").update(JSON.stringify(blocks)).digest("hex").slice(0, 12);
}

/** Strip hidden SillyTavern MVU / helper XML control tags from fallback markdown text. */
export function stripHiddenTavernXml(text: string): string {
  if (!text) return "";
  return text
    .replace(/<UpdateVariable\b[^>]*>[\s\S]*?<\/UpdateVariable>/gi, "")
    .replace(/<UpdateVariable\b[^>]*>[\s\S]*$/gi, "")
    .replace(/<StatusPlaceHolderImpl\b[^>]*\/?>/gi, "")
    .replace(/<comment\b[^>]*>[\s\S]*?<\/comment>/gi, "")
    .replace(/<comment\b[^>]*>[\s\S]*$/gi, "")
    .trim();
}

/** Extract `<think>...</think>` or `<thought>...</thought>` from raw text when reasoning isn't provided separately. */
export function splitReasoningFromRawText(rawText: string): {
  reasoning: string;
  cleanedText: string;
} {
  if (!rawText) return { reasoning: "", cleanedText: "" };
  const thoughts: string[] = [];
  const cleaned = rawText
    .replace(/<(think|thought|thinking)\b[^>]*>([\s\S]*?)<\/\1>/gi, (_m, _tag, body: string) => {
      const t = body.trim();
      if (t) thoughts.push(t);
      return "";
    })
    .trim();
  return {
    reasoning: thoughts.join("\n\n"),
    cleanedText: cleaned,
  };
}

export interface FallbackMessageInput {
  mesId: number;
  name: string;
  avatarUrl?: string | null;
  isUser: boolean;
  isSystem: boolean;
  sendDate?: string;
  rawText: string;
  reasoning?: string;
  swipeId?: number;
  swipeCount?: number;
  isStreaming?: boolean;
  mvuData?: Record<string, unknown> | null;
}

export function buildFallbackMarkdownMessage(input: FallbackMessageInput): TavernMessage {
  let reasoning = (input.reasoning || "").trim();
  let body = input.rawText || "";
  if (!reasoning && body) {
    const split = splitReasoningFromRawText(body);
    if (split.reasoning) {
      reasoning = split.reasoning;
      body = split.cleanedText;
    }
  }
  const visibleBody = stripHiddenTavernXml(body);

  const blocks: TavernRenderBlock[] = visibleBody
    ? [{ id: `m-${input.mesId}-0`, kind: "markdown", markdown: visibleBody }]
    : [];

  return {
    mesId: input.mesId,
    name: input.name || "",
    avatarUrl: input.avatarUrl ?? null,
    isUser: Boolean(input.isUser),
    isSystem: Boolean(input.isSystem),
    sendDate: input.sendDate || "",
    rawText: input.rawText || "",
    reasoning,
    swipeId: Math.max(0, Math.trunc(input.swipeId ?? 0)),
    swipeCount: Math.max(1, Math.trunc(input.swipeCount ?? 1)),
    blocks,
    renderedHash: computeRenderedHash(blocks),
    isStreaming: Boolean(input.isStreaming),
    ...(input.mvuData !== undefined ? { mvuData: input.mvuData } : {}),
  };
}

export interface RawExtractedBlock {
  kind: "markdown" | "html" | "iframe" | "image" | "details";
  markdown?: string;
  summary?: string;
  html?: string;
  imageUrl?: string;
  imageAlt?: string;
  estimatedHeight?: number;
}

export interface RawExtractedMessage {
  mesId: number;
  name: string;
  avatarPath: string | null;
  isUser: boolean;
  isSystem: boolean;
  sendDate: string;
  rawText: string;
  reasoning: string;
  swipeId: number;
  swipeCount: number;
  hasDom: boolean;
  rawBlocks: RawExtractedBlock[];
  isStreaming: boolean;
  mvuData?: Record<string, unknown> | null;
}

export function finalizeExtractedMessages(rawList: RawExtractedMessage[]): TavernMessage[] {
  return rawList.map((raw) => {
    const avatarUrl = raw.avatarPath ? buildTavernAssetProxyUrl(raw.avatarPath) || null : null;
    const mvuData =
      raw.mvuData && typeof raw.mvuData === "object" ? raw.mvuData : null;

    if (!raw.hasDom || raw.rawBlocks.length === 0) {
      return buildFallbackMarkdownMessage({
        mesId: raw.mesId,
        name: raw.name,
        avatarUrl,
        isUser: raw.isUser,
        isSystem: raw.isSystem,
        sendDate: raw.sendDate,
        rawText: raw.rawText,
        reasoning: raw.reasoning,
        swipeId: raw.swipeId,
        swipeCount: raw.swipeCount,
        isStreaming: raw.isStreaming,
        mvuData,
      });
    }

    const blocks: TavernRenderBlock[] = [];
    for (let i = 0; i < raw.rawBlocks.length; i++) {
      const b = raw.rawBlocks[i];
      const id = `m-${raw.mesId}-${i}`;
      if (b.kind === "iframe") {
        blocks.push({
          id,
          kind: "iframe",
          html: cleanIframeDocumentHtml(b.html || ""),
          ...(typeof b.estimatedHeight === "number" && b.estimatedHeight > 0
            ? { estimatedHeight: Math.round(b.estimatedHeight) }
            : {}),
        });
      } else if (b.kind === "html") {
        blocks.push({
          id,
          kind: "html",
          html: rewriteHtmlAssetUrls(b.html || ""),
          ...(typeof b.estimatedHeight === "number" && b.estimatedHeight > 0
            ? { estimatedHeight: Math.round(b.estimatedHeight) }
            : {}),
        });
      } else if (b.kind === "details") {
        blocks.push({
          id,
          kind: "details",
          summary: (b.summary || "详情").trim(),
          markdown: (b.markdown || "").trim(),
        });
      } else if (b.kind === "image") {
        const src = (b.imageUrl || "").trim();
        let resolvedUrl = src;
        if (src && !/^(https?:|data:|relay-st:)/i.test(src)) {
          const rewritten = toRelaySchemeAssetUrl(src);
          resolvedUrl = rewritten || "";
        }
        if (resolvedUrl) {
          blocks.push({
            id,
            kind: "image",
            imageUrl: resolvedUrl,
            ...(b.imageAlt ? { imageAlt: b.imageAlt } : {}),
          });
        }
      } else {
        const md = (b.markdown || "").trim();
        if (md) {
          blocks.push({ id, kind: "markdown", markdown: md });
        }
      }
    }

    if (blocks.length === 0 && raw.rawText) {
      return buildFallbackMarkdownMessage({
        mesId: raw.mesId,
        name: raw.name,
        avatarUrl,
        isUser: raw.isUser,
        isSystem: raw.isSystem,
        sendDate: raw.sendDate,
        rawText: raw.rawText,
        reasoning: raw.reasoning,
        swipeId: raw.swipeId,
        swipeCount: raw.swipeCount,
        isStreaming: raw.isStreaming,
        mvuData,
      });
    }

    let reasoning = (raw.reasoning || "").trim();
    if (!reasoning && raw.rawText) {
      const split = splitReasoningFromRawText(raw.rawText);
      if (split.reasoning) reasoning = split.reasoning;
    }

    return {
      mesId: raw.mesId,
      name: raw.name || "",
      avatarUrl,
      isUser: Boolean(raw.isUser),
      isSystem: Boolean(raw.isSystem),
      sendDate: raw.sendDate || "",
      rawText: raw.rawText || "",
      reasoning,
      swipeId: Math.max(0, Math.trunc(raw.swipeId ?? 0)),
      swipeCount: Math.max(1, Math.trunc(raw.swipeCount ?? 1)),
      blocks,
      renderedHash: computeRenderedHash(blocks),
      isStreaming: Boolean(raw.isStreaming),
      mvuData,
    };
  });
}

/**
 * Browser-side extractor function source passed to `page.evaluate(...)`.
 * Accepts `{ limit, beforeMesId }` for windowed pagination so large chats stay lightweight.
 */
export const EXTRACT_CHAT_MESSAGES_FN_SOURCE = `((opts) => {
  const st = window.SillyTavern;
  const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
  if (!ctx || !Array.isArray(ctx.chat)) {
    return {
      userName: "User",
      messages: [],
      variables: {},
      totalMessageCount: 0,
      hasMore: false,
      isLiveGenerating: false,
    };
  }

  const COMPLEX_STYLE_RE = /(?:background|border|grid|flex|padding|margin|position|gradient|box-shadow|border-radius|width|height|display\\s*:\\s*(?:grid|flex|inline-flex)|transform|overflow)/i;

  function computeIsLiveGenerating() {
    const stopEl = document.querySelector("#mes_stop");
    let stopVisible = false;
    if (stopEl) {
      const style = window.getComputedStyle ? window.getComputedStyle(stopEl) : stopEl.style;
      stopVisible = Boolean(
        style &&
        style.display !== "none" &&
        style.visibility !== "hidden"
      );
    }
    return Boolean(
      stopVisible ||
      ctx.streamingProcessor ||
      document.body?.dataset?.generating === "true"
    );
  }

  function inlineToMd(node) {
    if (!node) return "";
    if (node.nodeType === 3) return node.nodeValue || "";
    if (node.nodeType !== 1) return "";
    const el = node;
    const tag = el.tagName.toLowerCase();
    if (tag === "br") return "\\n";
    if (tag === "style" || tag === "script") return "";
    if (tag === "img") {
      const src = el.getAttribute("src") || "";
      const alt = el.getAttribute("alt") || "";
      return src ? "![" + alt + "](" + src + ")" : "";
    }
    const inner = Array.from(el.childNodes).map(inlineToMd).join("");
    if (tag === "strong" || tag === "b") return inner ? "**" + inner + "**" : "";
    if (tag === "em" || tag === "i") return inner ? "*" + inner + "*" : "";
    if (tag === "del" || tag === "s") return inner ? "~~" + inner + "~~" : "";
    if (tag === "code") return inner ? "\`" + inner.replace(/\`/g, "\\\\\`") + "\`" : "";
    if (tag === "q") return inner ? "“" + inner + "”" : "";
    if (tag === "a") {
      const href = el.getAttribute("href") || "";
      return href ? "[" + (inner || href) + "](" + href + ")" : inner;
    }
    return inner;
  }

  function blockToMd(node) {
    if (!node) return "";
    if (node.nodeType === 3) return (node.nodeValue || "").trim();
    if (node.nodeType !== 1) return "";
    const el = node;
    const tag = el.tagName.toLowerCase();
    if (tag === "style" || tag === "script") return "";
    if (tag === "hr") return "---";
    if (tag === "pre") {
      const codeEl = el.querySelector("code");
      const langMatch = (codeEl && codeEl.className || "").match(/language-([\\w-]+)/i);
      const lang = langMatch ? langMatch[1] : "";
      const text = (codeEl ? codeEl.textContent : el.textContent) || "";
      return "\`\`\`" + lang + "\\n" + text.replace(/\\n$/, "") + "\\n\`\`\`";
    }
    if (/^h[1-6]$/.test(tag)) {
      const level = Number(tag.slice(1));
      return "#".repeat(level) + " " + Array.from(el.childNodes).map(inlineToMd).join("").trim();
    }
    if (tag === "blockquote") {
      const text = Array.from(el.childNodes).map(blockToMd).filter(Boolean).join("\\n");
      return text.split("\\n").map((l) => "> " + l).join("\\n");
    }
    if (tag === "ul" || tag === "ol") {
      const items = Array.from(el.children).filter((c) => c.tagName.toLowerCase() === "li");
      return items
        .map((li, idx) => (tag === "ol" ? (idx + 1) + ". " : "- ") + Array.from(li.childNodes).map(inlineToMd).join("").trim())
        .join("\\n");
    }
    if (tag === "p") {
      return Array.from(el.childNodes).map(inlineToMd).join("").trim();
    }
    const childEls = Array.from(el.children);
    if (childEls.length > 0 && childEls.some((c) => /^(p|div|ul|ol|pre|blockquote|h[1-6]|hr)$/i.test(c.tagName))) {
      return Array.from(el.childNodes).map(blockToMd).filter(Boolean).join("\\n\\n");
    }
    return Array.from(el.childNodes).map(inlineToMd).join("").trim();
  }

  function findDirectIframe(el) {
    if (!el || el.nodeType !== 1) return null;
    const tag = el.tagName.toLowerCase();
    if (tag === "iframe") return el;
    const preferred = el.querySelector("iframe[id^='TH-message'], iframe[srcdoc]");
    const iframes = el.querySelectorAll("iframe");
    const targetIframe = preferred || (iframes.length === 1 ? iframes[0] : null);
    if (!targetIframe) return null;
    if (el.classList && el.classList.contains("TH-render")) {
      return targetIframe;
    }
    const clone = el.cloneNode(true);
    clone
      .querySelectorAll('iframe, pre, style, script, .TH-collapse-code-block-button, [class*="hidden"]')
      .forEach((n) => n.remove());
    if (!(clone.textContent || "").trim()) {
      return targetIframe;
    }
    return null;
  }

  function readIframeHtml(iframe) {
    const srcdoc = iframe.getAttribute("srcdoc");
    if (srcdoc && srcdoc.trim()) return srcdoc;
    try {
      const doc = iframe.contentDocument;
      if (doc && doc.documentElement) {
        return doc.documentElement.outerHTML;
      }
    } catch {}
    return iframe.outerHTML;
  }

  function isComplexHtmlEl(el) {
    if (!el || el.nodeType !== 1) return false;
    const tag = el.tagName.toLowerCase();
    if (tag === "style" || tag === "script" || tag === "svg" || tag === "iframe") return true;
    if (el.querySelector("style, script, iframe, svg")) return true;
    const styleAttr = el.getAttribute("style") || "";
    if (styleAttr && COMPLEX_STYLE_RE.test(styleAttr)) return true;
    if (el.querySelector("[style]")) {
      const styled = Array.from(el.querySelectorAll("[style]"));
      if (styled.some((n) => COMPLEX_STYLE_RE.test(n.getAttribute("style") || ""))) return true;
    }
    if (tag === "table" && el.querySelectorAll("td, th").length > 0) {
      if (styleAttr || el.className) return true;
    }
    return false;
  }

  function findStandaloneImage(el) {
    if (!el || el.nodeType !== 1) return null;
    const tag = el.tagName.toLowerCase();
    if (tag === "img") return el;
    if (tag === "p" || tag === "div" || tag === "figure") {
      const imgs = el.querySelectorAll("img");
      if (imgs.length === 1) {
        const clone = el.cloneNode(true);
        clone.querySelectorAll("img").forEach((n) => n.remove());
        if (!(clone.textContent || "").trim()) {
          return imgs[0];
        }
      }
    }
    return null;
  }

  function extractBlocksFromMesText(mesText) {
    const blocks = [];
    let mdBuffer = [];
    let pendingAssetHtml = [];

    const flushMd = () => {
      const joined = mdBuffer.map((s) => s.trim()).filter(Boolean).join("\\n\\n");
      mdBuffer = [];
      if (joined) blocks.push({ kind: "markdown", markdown: joined });
    };

    const nodes = Array.from(mesText.childNodes);
    for (let i = 0; i < nodes.length; i++) {
      const node = nodes[i];
      if (node.nodeType === 3) {
        const txt = (node.nodeValue || "").trim();
        if (txt) mdBuffer.push(txt);
        continue;
      }
      if (node.nodeType !== 1) continue;
      const el = node;
      const tag = el.tagName.toLowerCase();

      if (tag === "style" || tag === "script") {
        pendingAssetHtml.push(el.outerHTML);
        continue;
      }

      const iframe = findDirectIframe(el);
      if (iframe) {
        flushMd();
        const rect = iframe.getBoundingClientRect ? iframe.getBoundingClientRect() : null;
        const elRect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
        const h = rect && rect.height > 0 ? rect.height : (elRect && elRect.height > 0 ? elRect.height : 0);
        const prefix = pendingAssetHtml.length > 0 ? pendingAssetHtml.join("\\n") + "\\n" : "";
        pendingAssetHtml = [];
        blocks.push({
          kind: "iframe",
          html: prefix + readIframeHtml(iframe),
          estimatedHeight: h > 0 ? Math.round(h) : undefined,
        });
        continue;
      }

      if (tag === "details" && !isComplexHtmlEl(el)) {
        flushMd();
        const sumEl = el.querySelector(":scope > summary") || el.querySelector("summary");
        const summary = sumEl ? (sumEl.textContent || "").trim() : "详情";
        const bodyParts = [];
        for (const child of Array.from(el.childNodes)) {
          if (child === sumEl) continue;
          const md = blockToMd(child);
          if (md) bodyParts.push(md);
        }
        blocks.push({
          kind: "details",
          summary,
          markdown: bodyParts.join("\\n\\n"),
        });
        continue;
      }

      const standaloneImg = findStandaloneImage(el);
      if (standaloneImg && !isComplexHtmlEl(el)) {
        flushMd();
        blocks.push({
          kind: "image",
          imageUrl: standaloneImg.getAttribute("src") || "",
          imageAlt: standaloneImg.getAttribute("alt") || "",
        });
        continue;
      }

      if (isComplexHtmlEl(el) || pendingAssetHtml.length > 0) {
        flushMd();
        const prefix = pendingAssetHtml.length > 0 ? pendingAssetHtml.join("\\n") + "\\n" : "";
        pendingAssetHtml = [];
        const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
        const htmlStr = prefix + el.outerHTML;
        const prev = blocks[blocks.length - 1];
        if (prev && prev.kind === "html" && prefix) {
          prev.html = prev.html + "\\n" + htmlStr;
          if (rect && rect.height > 0) {
            prev.estimatedHeight = Math.round((prev.estimatedHeight || 0) + rect.height);
          }
        } else {
          blocks.push({
            kind: "html",
            html: htmlStr,
            estimatedHeight: rect && rect.height > 0 ? Math.round(rect.height) : undefined,
          });
        }
        continue;
      }

      const md = blockToMd(el);
      if (md) mdBuffer.push(md);
    }

    if (pendingAssetHtml.length > 0) {
      const prev = blocks[blocks.length - 1];
      if (prev && prev.kind === "html") {
        prev.html = prev.html + "\\n" + pendingAssetHtml.join("\\n");
      } else {
        flushMd();
        blocks.push({ kind: "html", html: pendingAssetHtml.join("\\n") });
      }
      pendingAssetHtml = [];
    }

    flushMd();
    return blocks;
  }

  function readMvuForMessage(idx, msgObj, swipeId) {
    try {
      if (window.Mvu && typeof window.Mvu.getMvuData === "function") {
        const d = window.Mvu.getMvuData({ type: "message", message_id: idx });
        if (d && typeof d === "object" && Object.keys(d).length > 0) {
          return JSON.parse(JSON.stringify(d));
        }
      }
    } catch {}
    if (msgObj && Array.isArray(msgObj.variables)) {
      const cand = msgObj.variables[swipeId] || msgObj.variables[0];
      if (cand && typeof cand === "object" && Object.keys(cand).length > 0) {
        try {
          return JSON.parse(JSON.stringify(cand));
        } catch {}
      }
    }
    return null;
  }

  const isLiveGenerating = computeIsLiveGenerating();
  const totalMessageCount = ctx.chat.length;
  const limit = opts && typeof opts.limit === "number" && opts.limit > 0 ? Math.trunc(opts.limit) : 25;
  const endIndex =
    opts && typeof opts.beforeMesId === "number" && opts.beforeMesId >= 0
      ? Math.min(totalMessageCount, Math.trunc(opts.beforeMesId))
      : totalMessageCount;
  const startIndex = Math.max(0, endIndex - limit);
  const hasMore = startIndex > 0;

  const messages = [];
  for (let idx = startIndex; idx < endIndex; idx++) {
    const m = ctx.chat[idx];
    const mesEl = document.querySelector('.mes[mesid="' + idx + '"]');
    const mesText = mesEl ? mesEl.querySelector(".mes_text") : null;
    const domReasoningEl = mesEl ? mesEl.querySelector(".mes_reasoning") : null;
    const domAvatarEl = mesEl ? mesEl.querySelector(".avatar img") : null;

    let avatarPath = null;
    const rawAvatarSrc = domAvatarEl ? domAvatarEl.getAttribute("src") : null;
    if (rawAvatarSrc && rawAvatarSrc.startsWith("/")) {
      avatarPath = rawAvatarSrc;
    } else if (!m.is_user && ctx.characters && ctx.characterId !== undefined && ctx.characters[ctx.characterId]?.avatar) {
      avatarPath = "/thumbnail?type=avatar&file=" + encodeURIComponent(ctx.characters[ctx.characterId].avatar);
    }

    const swipeId = typeof m.swipe_id === "number" ? m.swipe_id : 0;
    const swipeCount = Array.isArray(m.swipes) && m.swipes.length > 0 ? m.swipes.length : 1;
    const extraReasoning = m.extra && typeof m.extra.reasoning === "string" ? m.extra.reasoning : "";
    const domReasoning = domReasoningEl ? (domReasoningEl.textContent || "").trim() : "";
    const isLast = idx === totalMessageCount - 1;
    const mvuData = readMvuForMessage(idx, m, swipeId);

    messages.push({
      mesId: idx,
      name: String(m.name || ""),
      avatarPath,
      isUser: Boolean(m.is_user),
      isSystem: Boolean(m.is_system),
      sendDate: String(m.send_date || ""),
      rawText: String(m.mes || ""),
      reasoning: extraReasoning || domReasoning || "",
      swipeId,
      swipeCount,
      hasDom: Boolean(mesText),
      rawBlocks: mesText ? extractBlocksFromMesText(mesText) : [],
      isStreaming: Boolean(isLiveGenerating && isLast && !m.is_user),
      mvuData,
    });
  }

  const globalVars =
    ctx.extensionSettings &&
    ctx.extensionSettings.variables &&
    typeof ctx.extensionSettings.variables.global === "object"
      ? ctx.extensionSettings.variables.global
      : {};
  const localVars =
    ctx.chatMetadata && typeof ctx.chatMetadata.variables === "object"
      ? ctx.chatMetadata.variables
      : {};
  let variables = {};
  try {
    variables = JSON.parse(JSON.stringify({ ...globalVars, ...localVars }));
  } catch {
    variables = {};
  }

  let latestMvu = null;
  for (let i = totalMessageCount - 1; i >= 0; i--) {
    const msgObj = ctx.chat[i];
    const sIdx = msgObj && typeof msgObj.swipe_id === "number" ? msgObj.swipe_id : 0;
    const found = readMvuForMessage(i, msgObj, sIdx);
    if (found) {
      latestMvu = found;
      break;
    }
  }
  if (latestMvu) {
    variables.__mvu_latest = latestMvu;
  }

  return {
    userName: String(ctx.name1 || "User"),
    messages,
    variables,
    totalMessageCount,
    hasMore,
    isLiveGenerating,
  };
})`;

export function buildExtractChatMessagesScript(opts?: {
  limit?: number;
  beforeMesId?: number;
}): string {
  const payload = {
    limit: typeof opts?.limit === "number" && opts.limit > 0 ? Math.trunc(opts.limit) : 25,
    beforeMesId:
      typeof opts?.beforeMesId === "number" && opts.beforeMesId >= 0
        ? Math.trunc(opts.beforeMesId)
        : null,
  };
  return `(${EXTRACT_CHAT_MESSAGES_FN_SOURCE})(${JSON.stringify(payload)})`;
}

export const EXTRACT_CHAT_MESSAGES_PAGE_SCRIPT = buildExtractChatMessagesScript({ limit: 25 });
