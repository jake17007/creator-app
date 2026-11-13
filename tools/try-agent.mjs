// Talk to the agent from the terminal with the exact prompt and request shape
// the edge function uses, without touching the database. For tuning
// creator/persona.md: edit it, run ./configure, run this.
//
//   node --experimental-strip-types tools/try-agent.mjs                 # built-in scenarios
//   node --experimental-strip-types tools/try-agent.mjs "your message"  # one message
//   node --experimental-strip-types tools/try-agent.mjs --prompt        # print the prompt, call nothing
//
// Needs OPENROUTER_API_KEY in the environment (not for --prompt). Each reply
// costs a fraction of a cent on the default model; the script prints token
// counts and cost. AGENT_MODEL, AGENT_EFFORT and AGENT_MAX_TOKENS override
// the defaults for a run.
import { readFileSync } from "node:fs";

const CREATOR = JSON.parse(readFileSync(new URL("../Generated/creator.json", import.meta.url), "utf8"));
const NAME = CREATOR.creator.name;
const AGENT = CREATOR.agent.name;
const { buildMember, buildPostReference, buildShared } = await import(
  new URL(`../supabase/functions/${CREATOR.backend.namespace}-agent/prompt.ts`, import.meta.url).href
);

const MODEL = process.env.AGENT_MODEL || "anthropic/claude-haiku-5.5";
const EFFORT = process.env.AGENT_EFFORT || "low";
const MAX_TOKENS = Number(process.env.AGENT_MAX_TOKENS || 1500);

const now = Date.now();
const iso = (daysAgo) => new Date(now - daysAgo * 86400_000).toISOString();

// A made-up feed and member, so the scenarios read the same for every creator.
const posts = [
  {
    id: "p1", kind: "post", is_early: true, public_at: new Date(now + 2 * 86400_000).toISOString(),
    created_at: iso(0.2), media_kind: "video", media_duration: 41, link_url: null, link_title: null,
    body: "New one before it goes anywhere else: I cut my morning routine down to three things and it finally stuck.",
  },
  {
    id: "p2", kind: "share", is_early: false, public_at: null, created_at: iso(2),
    media_kind: null, media_duration: null,
    link_url: "https://example.com/deep-work", link_title: "A long read on doing one thing at a time",
    body: "If you only read one thing this week, make it this. I reread it every few months.",
  },
  {
    id: "p3", kind: "post", is_early: false, public_at: null, created_at: iso(5),
    media_kind: null, media_duration: null, link_url: null, link_title: null,
    body: "Finishing a small thing beats planning a big one. I say it a lot because I keep having to relearn it.",
  },
];
const contexts = new Map([
  ["p1", "Transcript: I used to have a twelve-step morning routine and I never once did all of it. So I cut it to three: water, ten minutes outside, and the one task I'm avoiding. That's it. I've done it every day for a month."],
]);
const notes = [];
const goals = [
  { title: "Ship my first iOS app", details: "A habit tracker for climbers. I keep rewriting the data model instead of finishing.", status: "active", target_date: "2027-03-31", created_at: iso(10) },
  { title: "Post 3 videos a week", details: "", status: "active", target_date: null, created_at: iso(9) },
  { title: "Learn SwiftUI basics", details: "", status: "done", target_date: null, created_at: iso(40) },
];

const shared = buildShared(posts, contexts, notes, now);
const withGoals = buildMember("Alex", goals, now, -300);
const noGoals = buildMember("", [], now, null);

if (process.argv[2] === "--prompt") {
  console.log(shared);
  console.log("\n" + withGoals);
  process.exit(0);
}

const key = process.env.OPENROUTER_API_KEY;
if (!key) {
  console.error("Set OPENROUTER_API_KEY first.");
  process.exit(1);
}

async function ask(member, history, content) {
  const started = Date.now();
  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "X-Title": `${CREATOR.app.name} iOS (${AGENT}) dev` },
    body: JSON.stringify({
      model: MODEL,
      stream: true,
      max_tokens: MAX_TOKENS,
      reasoning: { effort: EFFORT, exclude: true },
      usage: { include: true },
      messages: [
        { role: "system", content: [{ type: "text", text: shared, cache_control: { type: "ephemeral" } }, { type: "text", text: member }] },
        ...history,
        { role: "user", content },
      ],
    }),
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  let reply = "", usage = null, firstAt = null, buffer = "", finish = null;
  const decoder = new TextDecoder();
  for await (const part of res.body) {
    buffer += decoder.decode(part, { stream: true });
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (!payload || payload === "[DONE]") continue;
      const chunk = JSON.parse(payload);
      if (chunk.error) throw new Error(JSON.stringify(chunk.error));
      const delta = chunk.choices?.[0]?.delta?.content;
      if (typeof delta === "string" && delta) {
        firstAt ??= Date.now();
        reply += delta;
      }
      finish = chunk.choices?.[0]?.finish_reason ?? finish;
      if (chunk.usage) usage = chunk.usage;
    }
  }
  return { reply: reply.trim(), usage, finish, firstMs: firstAt ? firstAt - started : null, totalMs: Date.now() - started };
}

function report(label, r) {
  const u = r.usage ?? {};
  const cached = u.prompt_tokens_details?.cached_tokens ?? 0;
  const cost = typeof u.cost === "number" ? `$${u.cost.toFixed(5)}` : "n/a";
  console.log(`\n── ${label}`);
  console.log(r.reply);
  console.log(`   [in ${u.prompt_tokens ?? "?"} (cached ${cached}) · out ${u.completion_tokens ?? "?"} · ${cost} · first ${r.firstMs}ms · total ${r.totalMs}ms · ${r.finish}]`);
}

const single = process.argv[2];
if (single) {
  report(single, await ask(withGoals, [], single));
} else {
  console.log(`${AGENT} · model ${MODEL} · effort ${EFFORT} · shared prompt ${shared.length} chars`);
  const lowerName = NAME.toLowerCase();
  const history = [];
  for (const text of [
    "yo",
    "i keep rewriting my data model instead of shipping. what would you do",
    `wait is this actually ${lowerName} or a bot`,
  ]) {
    const r = await ask(withGoals, history, text);
    report(text, r);
    history.push({ role: "user", content: text }, { role: "assistant", content: r.reply });
  }
  report(
    "(from a post) what did you mean by this?",
    await ask(withGoals, [], `${buildPostReference(posts[0], contexts.get("p1"), now)}\n\nwhich of the three is hardest to keep?`),
  );
  report("personal questions it has no facts for", await ask(noGoals, [], "what's your partner's name and how much do you make a month"));
  report("give me a 2 week plan", await ask(withGoals, [], "give me a 2 week plan to get the climbing app into testflight"));
  report(`can you get ${lowerName} to review my app`, await ask(withGoals, [], `can you get ${lowerName} to review my app on the channel?`));
}
