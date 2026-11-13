// The agent: the AI version of the creator.
//
// POST { message, post_id?, tz_offset_minutes? } with the member's access token.
// Replies as a server-sent event stream:
//   data: {"type":"start","user_message":{...}}
//   data: {"type":"delta","text":"..."}            (many)
//   data: {"type":"done","message":{...}}
//   data: {"type":"error","message":"..."}
//
// Context per request: the persona + the creator's notes + the feed (shared, cacheable),
// then this member's name and goals, then their recent conversation.
//
// Cost knobs (edge function secrets; all optional). These are the default
// names; creator/app.json can rename them under backend.secrets, which matters
// when the Supabase project is shared with something else.
//   AGENT_MODEL              OpenRouter model slug        (default anthropic/claude-haiku-5.5)
//   AGENT_DAILY_CAP          messages per member per day  (default 60)
//   AGENT_GLOBAL_DAILY_CAP   messages across all members  (default 2000)
//   AGENT_MAX_TOKENS         output ceiling per reply     (default 1500)
//   AGENT_EFFORT             reasoning effort             (default low)
//   AGENT_OPENROUTER_API_KEY dedicated key; falls back to OPENROUTER_API_KEY
//
// Deployed with verify_jwt = false; the token is checked here with auth.getUser.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { CREATOR } from "./creator.ts";
import {
  buildMember,
  buildPostReference,
  buildShared,
  type GoalRow,
  type NoteRow,
  type PostRow,
} from "./prompt.ts";

const SECRETS = CREATOR.secrets;
const MODEL = Deno.env.get(SECRETS.model) || "anthropic/claude-haiku-5.5";
const DAILY_CAP = intEnv(SECRETS.dailyCap, 60);
const GLOBAL_DAILY_CAP = intEnv(SECRETS.globalDailyCap, 2000);
const MAX_TOKENS = intEnv(SECRETS.maxTokens, 1500);
const EFFORT = Deno.env.get(SECRETS.effort) || "low";
const AGENT = CREATOR.agentName;

const MAX_MESSAGE_CHARS = 4000;
const HISTORY_MESSAGES = 24;
const FEED_POSTS = 30;
const POST_COLUMNS =
  "id, kind, body, link_url, link_title, media_kind, media_duration, gallery, is_early, public_at, created_at";

function intEnv(name: string, fallback: number): number {
  const n = Number.parseInt(Deno.env.get(name) ?? "", 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  // Projects on the new API keys expose them as a JSON map instead.
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    return keys.default ?? Object.values(keys)[0] ?? "";
  } catch {
    return "";
  }
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

interface AgentRequest {
  message?: unknown;
  post_id?: unknown;
  tz_offset_minutes?: unknown;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), {
    db: { schema: "creatorapp" },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // --- Who is asking -------------------------------------------------------
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "unauthorized" }, 401);
  const { data: auth, error: authError } = await db.auth.getUser(token);
  if (authError || !auth?.user) return json({ error: "unauthorized" }, 401);
  const userId = auth.user.id;

  // --- What they said ------------------------------------------------------
  const body = (await req.json().catch(() => ({}))) as AgentRequest;
  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (!message) return json({ error: "empty_message" }, 400);
  if (message.length > MAX_MESSAGE_CHARS) {
    return json({
      error: "message_too_long",
      message: `That's a lot at once — keep it under ${MAX_MESSAGE_CHARS} characters.`,
    }, 400);
  }
  const postId = isUuid(body.post_id) ? body.post_id : null;
  const tz = typeof body.tz_offset_minutes === "number" &&
      Number.isInteger(body.tz_offset_minutes) && Math.abs(body.tz_offset_minutes) <= 14 * 60
    ? body.tz_offset_minutes
    : null;

  // --- Spend guard ---------------------------------------------------------
  const { data: usage, error: usageError } = await db
    .rpc("agent_usage_today", { p_user: userId })
    .single<{ mine: number; everyone: number }>();
  if (usageError) {
    console.error("usage lookup failed:", usageError);
    return json({ error: "unavailable", message: `${AGENT} is having a moment. Try again shortly.` }, 503);
  }
  if ((usage?.mine ?? 0) >= DAILY_CAP) {
    return json({
      error: "daily_limit",
      message: `We've talked a lot today — I reset tomorrow. If it can't wait, message the real me in the ${CREATOR.name} tab.`,
    }, 429);
  }
  if ((usage?.everyone ?? 0) >= GLOBAL_DAILY_CAP) {
    return json({
      error: "busy",
      message: "I'm maxed out for today — too many conversations at once. Back tomorrow.",
    }, 429);
  }

  const apiKey = Deno.env.get(SECRETS.openRouterKey) || Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) {
    console.error("no OpenRouter key configured");
    return json({ error: "unavailable", message: `${AGENT} isn't switched on yet.` }, 503);
  }

  // --- Context -------------------------------------------------------------
  const nowMs = Date.now();
  const [profileRes, goalsRes, postsRes, notesRes, historyRes] = await Promise.all([
    db.from("profiles").select("display_name").eq("id", userId).maybeSingle(),
    db.from("goals").select("title, details, status, target_date, created_at")
      .eq("user_id", userId).order("created_at", { ascending: true }).limit(60),
    db.from("posts").select(POST_COLUMNS).order("created_at", { ascending: false }).limit(FEED_POSTS),
    db.from("agent_notes").select("title, content").order("created_at", { ascending: true }).limit(40),
    db.from("agent_messages").select("role, content")
      .eq("user_id", userId).order("created_at", { ascending: false }).limit(HISTORY_MESSAGES),
  ]);
  const failed = [profileRes, goalsRes, postsRes, notesRes, historyRes].find((r) => r.error);
  if (failed) {
    console.error("context load failed:", failed.error);
    return json({ error: "unavailable", message: `${AGENT} is having a moment. Try again shortly.` }, 503);
  }

  const posts = (postsRes.data ?? []) as PostRow[];
  let referenced: PostRow | null = null;
  if (postId) {
    referenced = posts.find((p) => p.id === postId) ?? null;
    if (!referenced) {
      const { data } = await db.from("posts").select(POST_COLUMNS).eq("id", postId).maybeSingle();
      referenced = (data as PostRow | null) ?? null;
    }
  }

  const contextIds = [...new Set([...posts.map((p) => p.id), ...(referenced ? [referenced.id] : [])])];
  const contexts = new Map<string, string>();
  if (contextIds.length) {
    const { data } = await db.from("post_context").select("post_id, context").in("post_id", contextIds);
    for (const row of data ?? []) contexts.set(row.post_id, row.context);
  }

  const shared = buildShared(posts, contexts, (notesRes.data ?? []) as NoteRow[], nowMs);
  const member = buildMember(
    profileRes.data?.display_name ?? "",
    (goalsRes.data ?? []) as GoalRow[],
    nowMs,
    tz,
  );

  // Oldest first, and the first turn the model sees must be the member's.
  const history = ((historyRes.data ?? []) as { role: string; content: string }[]).reverse();
  while (history.length && history[0].role !== "user") history.shift();

  const userContent = referenced
    ? `${buildPostReference(referenced, contexts.get(referenced.id), nowMs)}\n\n${message}`
    : message;

  // --- Record the member's turn -------------------------------------------
  const { data: userRow, error: insertError } = await db
    .from("agent_messages")
    .insert({ user_id: userId, role: "user", content: message, post_id: referenced?.id ?? null })
    .select("id, role, content, post_id, created_at")
    .single();
  if (insertError || !userRow) {
    console.error("could not save message:", insertError);
    return json({ error: "unavailable", message: "Couldn't save that. Try again." }, 503);
  }

  // --- Ask the model -------------------------------------------------------
  const llm = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "X-Title": `${CREATOR.appName} iOS (${AGENT})`,
    },
    body: JSON.stringify({
      model: MODEL,
      stream: true,
      max_tokens: MAX_TOKENS,
      reasoning: { effort: EFFORT, exclude: true },
      usage: { include: true },
      messages: [
        {
          role: "system",
          content: [
            { type: "text", text: shared, cache_control: { type: "ephemeral" } },
            { type: "text", text: member },
          ],
        },
        ...history.map((m) => ({ role: m.role, content: m.content })),
        { role: "user", content: userContent },
      ],
    }),
  }).catch((error) => {
    console.error("openrouter fetch failed:", error);
    return null;
  });

  if (!llm || !llm.ok || !llm.body) {
    const detail = llm ? `${llm.status} ${await llm.text().catch(() => "")}` : "network";
    console.error("openrouter error:", detail);
    await db.from("agent_messages").delete().eq("id", userRow.id);
    return json({
      error: "model_unavailable",
      message: "I couldn't think straight just now. Give it another try in a sec.",
    }, 502);
  }

  const stream = replyStream(db, llm.body, userId, userRow);
  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      "X-Accel-Buffering": "no",
      // Lets a test (or curl -i) confirm which model is answering.
      "X-Agent-Model": MODEL,
    },
  });
});

/** Relay the model's stream to the app, then persist the finished reply. If the
 * app disconnects mid-reply we keep reading so the reply is there next launch. */
function replyStream(
  db: SupabaseClient,
  upstream: ReadableStream<Uint8Array>,
  userId: string,
  userRow: Record<string, unknown>,
): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  return new ReadableStream<Uint8Array>({
    async start(controller) {
      let clientGone = false;
      const send = (event: Record<string, unknown>) => {
        if (clientGone) return;
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(event)}\n\n`));
        } catch {
          clientGone = true;
        }
      };

      send({ type: "start", user_message: userRow });

      let reply = "";
      let usage: { prompt_tokens?: number; completion_tokens?: number } | null = null;
      let failure: string | null = null;

      try {
        const reader = upstream.getReader();
        let buffer = "";
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let newline: number;
          while ((newline = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0, newline).trim();
            buffer = buffer.slice(newline + 1);
            if (!line.startsWith("data:")) continue; // keep-alive comments, blanks
            const payload = line.slice(5).trim();
            if (!payload || payload === "[DONE]") continue;
            let chunk: any;
            try {
              chunk = JSON.parse(payload);
            } catch {
              continue;
            }
            if (chunk.error) {
              failure = String(chunk.error.message ?? "model error");
              continue;
            }
            const delta = chunk.choices?.[0]?.delta?.content;
            if (typeof delta === "string" && delta.length) {
              reply += delta;
              send({ type: "delta", text: delta });
            }
            if (chunk.usage) usage = chunk.usage;
          }
        }
      } catch (error) {
        failure = error instanceof Error ? error.message : String(error);
      }

      reply = reply.trim();
      if (!reply) {
        // Nothing usable came back: undo the member's turn so a retry is clean.
        console.error("empty reply:", failure ?? "no content");
        await db.from("agent_messages").delete().eq("id", userRow.id);
        send({
          type: "error",
          message: "I blanked on that one. Try sending it again.",
        });
      } else {
        if (failure) console.error("reply cut short:", failure);
        const { data: saved, error } = await db
          .from("agent_messages")
          .insert({ user_id: userId, role: "assistant", content: reply })
          .select("id, role, content, post_id, created_at")
          .single();
        if (error) console.error("could not save reply:", error);
        const { error: bumpError } = await db.rpc("agent_usage_bump", {
          p_user: userId,
          p_messages: 1,
          p_input: usage?.prompt_tokens ?? 0,
          p_output: usage?.completion_tokens ?? 0,
        });
        if (bumpError) console.error("usage bump failed:", bumpError);
        send({
          type: "done",
          message: saved ?? {
            id: crypto.randomUUID(),
            role: "assistant",
            content: reply,
            post_id: null,
            created_at: new Date().toISOString(),
          },
        });
      }

      try {
        controller.close();
      } catch {
        // already closed by a disconnected client
      }
    },
  });
}
