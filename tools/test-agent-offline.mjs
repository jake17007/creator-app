// Runs the agent edge function on this Mac with a fake database and a fake
// model, so its request handling can be checked without a backend, Deno or an
// API key. Nothing leaves the machine and nothing is billed.
//
//   node --experimental-strip-types tools/test-agent-offline.mjs
//
// It tests the copy ./configure wrote to supabase/functions/<namespace>-agent/,
// so run ./configure first. For the real thing, deployed, use e2e-backend.mjs.
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const CREATOR = JSON.parse(readFileSync(new URL("../Generated/creator.json", import.meta.url), "utf8"));
const NAME = CREATOR.creator.name;
const AGENT = CREATOR.agent.name;
const SECRETS = CREATOR.backend.secrets;
const source = fileURLToPath(new URL(`../supabase/functions/${CREATOR.backend.namespace}-agent/`, import.meta.url));

let passed = 0;
let failed = 0;
function check(name, ok, detail = "") {
  if (ok) passed += 1;
  else failed += 1;
  console.log(`  ${ok ? "ok  " : "FAIL"} ${name}${ok || !detail ? "" : ` — ${detail}`}`);
}

// --- A stand-in for the Supabase client: just the calls the function makes ---
const MEMBER = "11111111-1111-4111-8111-111111111111";
const POST = "22222222-2222-4222-8222-222222222222";
let tables;
let usage;
let bumps;
function reset() {
  tables = {
    profiles: [{ id: MEMBER, display_name: "Alex" }],
    goals: [{ user_id: MEMBER, title: "Ship my first iOS app", details: "", status: "active", target_date: null, created_at: "2026-01-01T00:00:00Z" }],
    posts: [{ id: POST, kind: "post", body: "A post about finishing small things.", link_url: null, link_title: null, media_kind: null, media_duration: null, gallery: [], is_early: false, public_at: null, created_at: "2026-01-02T00:00:00Z" }],
    post_context: [{ post_id: POST, context: "Private note about the post." }],
    agent_notes: [{ title: "Right now", content: "Testing the offline harness." }],
    agent_messages: [],
  };
  usage = { mine: 0, everyone: 0 };
  bumps = [];
}

let sequence = 0; // insertion order, to break ties between rows saved in the same millisecond
function query(table) {
  const state = { action: "select", filters: [], row: null, one: false, newestFirst: false };
  const matches = (row) => state.filters.every(([column, values]) => values.includes(row[column]));
  const run = () => {
    if (state.action === "insert") {
      const row = { id: crypto.randomUUID(), created_at: new Date().toISOString(), post_id: null, ...state.row, seq: ++sequence };
      tables[table].push(row);
      return { data: state.one ? row : [row], error: null };
    }
    if (state.action === "delete") {
      tables[table] = tables[table].filter((row) => !matches(row));
      return { data: null, error: null };
    }
    const rows = tables[table].filter(matches);
    if (state.newestFirst) rows.sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0));
    return { data: state.one ? rows[0] ?? null : rows, error: null };
  };
  const builder = {
    select: () => builder,
    order: (_column, options) => ((state.newestFirst = options?.ascending === false), builder),
    limit: () => builder,
    eq: (column, value) => (state.filters.push([column, [value]]), builder),
    in: (column, values) => (state.filters.push([column, values]), builder),
    insert: (row) => ((state.action = "insert"), (state.row = row), builder),
    delete: () => ((state.action = "delete"), builder),
    single: () => ((state.one = true), builder),
    maybeSingle: () => ((state.one = true), builder),
    then: (resolve, reject) => Promise.resolve().then(run).then(resolve, reject),
  };
  return builder;
}

const stub = `export function createClient() { return globalThis.__fakeDb; }\n`;
globalThis.__fakeDb = {
  auth: {
    getUser: async (token) =>
      token === "good" ? { data: { user: { id: MEMBER } }, error: null } : { data: null, error: new Error("bad token") },
  },
  from: query,
  rpc(name, args) {
    const result = name === "agent_usage_today" ? { data: usage, error: null } : (bumps.push(args), { data: null, error: null });
    const thenable = { single: () => thenable, then: (resolve) => Promise.resolve(result).then(resolve) };
    return thenable;
  },
};

// --- A stand-in for the model: two chunks of text, then the token counts ---
let modelCalls;
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init) => {
  if (!String(url).startsWith("https://openrouter.ai/")) return realFetch(url, init);
  modelCalls.push({ headers: init.headers, body: JSON.parse(init.body) });
  const sse = [
    { choices: [{ delta: { content: "Start with " } }] },
    { choices: [{ delta: { content: "the smallest version." } }] },
    { choices: [{ delta: {} }], usage: { prompt_tokens: 1234, completion_tokens: 9 } },
  ].map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(sse, { status: 200, headers: { "Content-Type": "text/event-stream" } });
};

// --- Load the function with those stand-ins in place of Deno and Supabase ---
const env = { SUPABASE_URL: "http://local.test", SUPABASE_SERVICE_ROLE_KEY: "service", [SECRETS.model]: "test/model", [SECRETS.dailyCap]: "3" };
let handler;
globalThis.Deno = { env: { get: (key) => env[key] }, serve: (fn) => (handler = fn) };

const work = mkdtempSync(join(tmpdir(), "agent-offline-"));
try {
  for (const file of ["prompt.ts", "creator.ts"]) copyFileSync(join(source, file), join(work, file));
  const index = readFileSync(join(source, "index.ts"), "utf8");
  const patched = index.replace(/from "npm:@supabase\/supabase-js@2";/, 'from "./supabase-stub.mjs";');
  if (patched === index) throw new Error("index.ts no longer imports supabase-js the way this test expects");
  writeFileSync(join(work, "index.ts"), patched);
  writeFileSync(join(work, "supabase-stub.mjs"), stub);
  await import(pathToFileURL(join(work, "index.ts")).href);
} finally {
  rmSync(work, { recursive: true, force: true });
}

async function call({ method = "POST", token = "good", body = { message: "hi" } } = {}) {
  modelCalls = [];
  const response = await handler(new Request("http://local.test/agent", {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  }));
  const text = await response.text();
  const events = text.split("\n").filter((line) => line.startsWith("data:")).map((line) => JSON.parse(line.slice(5)));
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    // a stream, not JSON
  }
  return { status: response.status, headers: response.headers, json, events };
}

console.log(`${AGENT} (offline)`);

reset();
check("only POST is accepted", (await call({ method: "GET" })).status === 405);
check("no token is refused", (await call({ token: "" })).status === 401);
check("a bad token is refused", (await call({ token: "bad" })).status === 401);
check("an empty message is refused", (await call({ body: { message: "   " } })).status === 400);

reset();
usage = { mine: 3, everyone: 3 };
const capped = await call();
check("the per-member daily cap stops the reply and points at the creator's tab",
  capped.status === 429 && capped.json?.error === "daily_limit" && capped.json.message.includes(`${NAME} tab`), JSON.stringify(capped.json));
check("no model call is made past the cap", modelCalls.length === 0);

reset();
const off = await call();
check("without an API key it says the agent isn't switched on", off.status === 503 && off.json?.message === `${AGENT} isn't switched on yet.`, JSON.stringify(off.json));

env[SECRETS.openRouterKey] = "test-key";
reset();
const reply = await call({ body: { message: "what should I do today?", tz_offset_minutes: -300 } });
const request = modelCalls[0];
check("a reply streams back", reply.status === 200 && (reply.headers.get("content-type") ?? "").startsWith("text/event-stream"), `${reply.status}`);
check("the stream is start, text, done", reply.events.map((e) => e.type).join(",") === "start,delta,delta,done", reply.events.map((e) => e.type).join(","));
check("the reply is the model's text", reply.events.at(-1)?.message?.content === "Start with the smallest version.");
check("the model comes from the configured secret", request?.body.model === "test/model" && reply.headers.get("x-agent-model") === "test/model");
check("the API key comes from the configured secret", request?.headers.Authorization === "Bearer test-key");
check("the request is labelled with the app and agent names", request?.headers["X-Title"] === `${CREATOR.app.name} iOS (${AGENT})`, request?.headers["X-Title"]);
const system = request?.body.messages[0].content ?? [];
check("the shared prompt introduces the agent and is marked cacheable",
  system[0]?.text.startsWith(`You are ${AGENT} — the AI version of ${NAME}`) && system[0]?.cache_control?.type === "ephemeral");
check("the shared prompt carries the creator's notes and the feed",
  system[0]?.text.includes("Testing the offline harness.") && system[0]?.text.includes("A post about finishing small things.") &&
  system[0]?.text.includes("Private note about the post."));
check("the member block carries their name and goal", system[1]?.text.includes("Name: Alex") && system[1]?.text.includes("Ship my first iOS app"));
check("both turns were saved", tables.agent_messages.map((m) => m.role).join(",") === "user,assistant");
check("usage was counted", bumps.length === 1 && bumps[0].p_input === 1234 && bumps[0].p_output === 9, JSON.stringify(bumps));

const about = await call({ body: { message: "what did you mean?", post_id: POST } });
const asked = modelCalls[0]?.body.messages.at(-1)?.content ?? "";
check("asking about a post sends the post along", about.status === 200 && asked.includes("(They opened this from a post in the feed") && asked.endsWith("what did you mean?"));
check("earlier turns are sent as history", modelCalls[0]?.body.messages.length === 4, `${modelCalls[0]?.body.messages.length}`);
check("the message is linked to the post", tables.agent_messages.at(-2)?.post_id === POST);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
