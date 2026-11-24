export async function sendBarkNotification(
  barkUrl: string,
  title: string,
  body: string
): Promise<void> {
  const trimmed = barkUrl.trim().replace(/\/+$/, "");
  if (!trimmed) return;

  try {
    await fetch(trimmed, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8" },
      body: JSON.stringify({
        title,
        body,
        group: "Relay",
        sound: "minuet",
      }),
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    // Best-effort notification
  }
}
