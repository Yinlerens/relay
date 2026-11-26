export const TAVERN_UI_PROBE_SCRIPT = `(() => {
  const pathname = window.location.pathname || "";
  const isLogin =
    pathname.startsWith("/login") ||
    Boolean(document.querySelector("#userList, #userHandle, #loginButton"));
  const st = window.SillyTavern;
  const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
  const hasContext = Boolean(ctx && Array.isArray(ctx.characters));
  const preloader = document.querySelector("#preloader");
  let preloaderVisible = false;
  if (preloader) {
    const style = window.getComputedStyle(preloader);
    preloaderVisible =
      style.display !== "none" &&
      style.visibility !== "hidden" &&
      Number(style.opacity || "1") > 0.05;
  }
  return {
    isLogin,
    hasContext,
    charCount: hasContext ? ctx.characters.length : 0,
    preloaderVisible,
  };
})()`;

export const TAVERN_FETCH_LOGIN_USERS_SCRIPT = `(async () => {
  try {
    const csrfRes = await fetch("/csrf-token");
    const csrfData = await csrfRes.json();
    const res = await fetch("/api/users/list", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfData.token || "",
      },
    });
    if (!res.ok || res.status === 204) return [];
    const list = await res.json();
    if (!Array.isArray(list)) return [];
    return list
      .filter((u) => u && typeof u.handle === "string")
      .map((u) => ({
        handle: String(u.handle),
        name: String(u.name || u.handle),
      }));
  } catch {
    return [];
  }
})()`;

export const TAVERN_BIND_PAGE_EVENTS_SCRIPT = `(() => {
  if (window.__relayTavernBound) return;
  const st = window.SillyTavern;
  const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
  if (!ctx || !ctx.eventSource) return;
  window.__relayTavernBound = true;
  const es = ctx.eventSource;
  const et = ctx.eventTypes || ctx.event_types || {};
  const isLiveGen = () => {
    const stopEl = document.querySelector("#mes_stop");
    let stopVisible = false;
    if (stopEl) {
      const style = window.getComputedStyle(stopEl);
      stopVisible = style.display !== "none" && style.visibility !== "hidden";
    }
    return Boolean(
      stopVisible ||
      ctx.streamingProcessor ||
      document.body?.dataset?.generating === "true"
    );
  };
  const emit = (name, payload) => {
    if (typeof window.__relayTavernEvent === "function") {
      window.__relayTavernEvent(name, payload);
    }
  };
  const bind = (eventKey, fallbackName, tag) => {
    const evName = et[eventKey] || fallbackName;
    if (evName && typeof es.on === "function") {
      es.on(evName, (data) => {
        try {
          emit(tag, {
            value: typeof data === "string" || typeof data === "number" ? data : null,
            isLiveGenerating: isLiveGen(),
          });
        } catch {}
      });
    }
  };
  bind("GENERATION_STARTED", "generation_started", "GENERATION_STARTED");
  bind("STREAM_TOKEN_RECEIVED", "stream_token_received", "STREAM_TOKEN_RECEIVED");
  bind("GENERATION_ENDED", "generation_ended", "GENERATION_ENDED");
  bind("GENERATION_STOPPED", "generation_stopped", "GENERATION_STOPPED");
  bind("MESSAGE_RECEIVED", "message_received", "MESSAGE_RECEIVED");
  bind("CHARACTER_MESSAGE_RENDERED", "character_message_rendered", "CHARACTER_MESSAGE_RENDERED");
  bind("MESSAGE_SWIPED", "message_swiped", "MESSAGE_SWIPED");
  bind("CHAT_CHANGED", "chat_changed", "CHAT_CHANGED");

  const reportToastNode = (node) => {
    if (!node || node.nodeType !== 1) return;
    const targets = [];
    if (node.matches && node.matches(".toast-error, .toast-warning")) targets.push(node);
    if (node.querySelectorAll) {
      node.querySelectorAll(".toast-error, .toast-warning").forEach((el) => targets.push(el));
    }
    for (const toast of targets) {
      const title = (toast.querySelector(".toast-title")?.textContent || "").trim();
      const body = (toast.querySelector(".toast-message")?.textContent || "").trim();
      const combined = [title, body].filter(Boolean).join("：") || (toast.textContent || "").trim();
      const level = toast.classList && toast.classList.contains("toast-warning") ? "warning" : "error";
      if (combined) emit("TOAST_ERROR", { message: combined, level });
    }
  };
  if (typeof MutationObserver !== "undefined" && document.body) {
    const toastObserver = new MutationObserver((mutations) => {
      for (const m of mutations) {
        for (const added of m.addedNodes) {
          if (added && added.nodeType === 1) {
            const inToast =
              (added.closest && added.closest("#toast-container")) ||
              (added.id === "toast-container") ||
              (added.classList &&
                (added.classList.contains("toast-error") || added.classList.contains("toast-warning"))) ||
              (added.querySelector && added.querySelector(".toast-error, .toast-warning"));
            if (inToast) reportToastNode(added);
          }
        }
      }
    });
    toastObserver.observe(document.body, { childList: true, subtree: true });
  }
})()`;

export const TAVERN_CURRENT_META_SCRIPT = `(() => {
  const st = window.SillyTavern;
  const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
  if (!ctx) return { characterId: null, characterName: null, characterAvatar: null, chatFile: null, isLiveGenerating: false };
  const rawId = ctx.characterId;
  const idNum = rawId !== undefined && rawId !== null && rawId !== "" ? Number(rawId) : NaN;
  const ch = Number.isFinite(idNum) && Array.isArray(ctx.characters) ? ctx.characters[idNum] : null;
  const chatId = typeof ctx.getCurrentChatId === "function" ? ctx.getCurrentChatId() : ctx.chatId;
  const stopEl = document.querySelector("#mes_stop");
  let stopVisible = false;
  if (stopEl) {
    const style = window.getComputedStyle(stopEl);
    stopVisible = style.display !== "none" && style.visibility !== "hidden";
  }
  const isLiveGenerating = Boolean(
    stopVisible ||
    ctx.streamingProcessor ||
    document.body?.dataset?.generating === "true"
  );
  return {
    characterId: ch ? idNum : null,
    characterName: ch ? String(ch.name || "") : null,
    characterAvatar: ch && ch.avatar ? String(ch.avatar) : null,
    chatFile: chatId ? String(chatId) : (ch && ch.chat ? String(ch.chat) : null),
    isLiveGenerating,
  };
})()`;

export const TAVERN_STREAM_DELTA_SCRIPT = `(() => {
  const st = window.SillyTavern;
  const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
  if (!ctx || !Array.isArray(ctx.chat)) return null;
  const stopEl = document.querySelector("#mes_stop");
  let stopVisible = false;
  if (stopEl) {
    const style = window.getComputedStyle(stopEl);
    stopVisible = style.display !== "none" && style.visibility !== "hidden";
  }
  const isLiveGenerating = Boolean(
    stopVisible ||
    ctx.streamingProcessor ||
    document.body?.dataset?.generating === "true"
  );
  if (ctx.chat.length === 0) {
    return { isLiveGenerating, mesId: null, text: "", reasoning: "" };
  }
  const sp = ctx.streamingProcessor;
  const mesId = sp && typeof sp.messageId === "number" ? sp.messageId : ctx.chat.length - 1;
  const m = ctx.chat[mesId];
  if (!m || m.is_user) {
    return { isLiveGenerating, mesId: null, text: "", reasoning: "" };
  }
  const mesEl = document.querySelector('.mes[mesid="' + mesId + '"]');
  const domReasoning = mesEl ? (mesEl.querySelector(".mes_reasoning")?.textContent || "") : "";
  const text =
    (sp && typeof sp.text === "string" && sp.text) ||
    String(m.mes || "");
  const reasoning =
    (sp && typeof sp.reasoning === "string" && sp.reasoning) ||
    (m.extra && typeof m.extra.reasoning === "string" ? m.extra.reasoning : "") ||
    domReasoning;
  return { isLiveGenerating, mesId, text, reasoning };
})()`;

export const TAVERN_EXTRACT_CHARACTERS_SCRIPT = `(() => {
  const st = window.SillyTavern;
  const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
  if (!ctx || !Array.isArray(ctx.characters)) return [];
  const tagById = new Map();
  if (Array.isArray(ctx.tags)) {
    for (const t of ctx.tags) {
      if (t && t.id && t.name) tagById.set(String(t.id), String(t.name));
    }
  }
  const tagMap = ctx.tagMap && typeof ctx.tagMap === "object" ? ctx.tagMap : {};
  return ctx.characters.map((ch, idx) => {
    const avatar = String(ch.avatar || "");
    const tagSet = new Set();
    const mappedIds = Array.isArray(tagMap[avatar]) ? tagMap[avatar] : [];
    for (const tid of mappedIds) {
      const tn = tagById.get(String(tid));
      if (tn) tagSet.add(tn);
    }
    const embeddedTags = Array.isArray(ch.data?.tags)
      ? ch.data.tags
      : Array.isArray(ch.tags)
        ? ch.tags
        : [];
    for (const t of embeddedTags) {
      if (typeof t === "string" && t.trim()) tagSet.add(t.trim());
    }
    const rawNotes = String(
      ch.data?.creator_notes || ch.creatorcomment || ch.description || ch.first_mes || ""
    );
    const tagline = rawNotes.replace(/\\s+/g, " ").trim().slice(0, 120);
    return {
      id: idx,
      name: String(ch.name || "未命名角色"),
      avatar,
      chat: ch.chat ? String(ch.chat) : null,
      lastChatRaw: ch.date_last_chat ?? ch.last_mes ?? 0,
      tags: Array.from(tagSet).slice(0, 8),
      tagline,
    };
  });
})()`;

export const TAVERN_REFRESH_CHARACTERS_SCRIPT = `(async () => {
  const st = window.SillyTavern;
  const ctx = st && typeof st.getContext === "function" ? st.getContext() : null;
  if (!ctx || !Array.isArray(ctx.characters)) return;
  const res = await fetch("/api/characters/all", {
    method: "POST",
    headers: ctx.getRequestHeaders(),
    body: JSON.stringify({}),
  });
  if (!res.ok) return;
  const freshList = await res.json();
  if (!Array.isArray(freshList)) return;
  const byAvatar = new Map();
  for (const item of freshList) {
    if (item && item.avatar) byAvatar.set(String(item.avatar), item);
  }
  for (const ch of ctx.characters) {
    if (!ch || !ch.avatar) continue;
    const fresh = byAvatar.get(String(ch.avatar));
    if (!fresh) continue;
    if (fresh.chat) ch.chat = String(fresh.chat);
    if (fresh.date_last_chat !== undefined) ch.date_last_chat = fresh.date_last_chat;
    if (fresh.last_mes !== undefined) ch.last_mes = fresh.last_mes;
  }
})()`;
