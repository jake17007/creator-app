// End-to-end check of the live backend, using only what the app itself can do
// (publishable key + member sessions). Creates throwaway accounts, exercises
// every table's permissions, talks to the agent, and deletes the accounts again.
//
//   node tools/e2e-backend.mjs                                      # member flows only
//   E2E_ADMIN_CODE=XXXX-XXXX-XXXX-XXXX node tools/e2e-backend.mjs   # + creator flows
//
// E2E_ADMIN_CODE must be a spare one-time code (tools/creator_code.py --another),
// NOT your real one: it gets used up, and the account that redeems it is an
// admin, so it can't delete itself. Remove it afterwards with a migration in
// creator/migrations/ (delete from auth.users where email like 'e2e-%@example.com').
// Costs a few agent replies (well under a cent on the default model).
//
// Reads Generated/creator.json, so run ./configure first. BACKEND_URL and
// BACKEND_KEY override it, e.g. to test a local `supabase start`.
import { readFileSync } from "node:fs";

const CREATOR = JSON.parse(readFileSync(new URL("../Generated/creator.json", import.meta.url), "utf8"));
const URL_BASE = process.env.BACKEND_URL || CREATOR.backend.url;
const KEY = process.env.BACKEND_KEY || CREATOR.backend.publishableKey;
const SCHEMA = CREATOR.backend.namespace;
const AGENT = CREATOR.agent.name;
const NAME = CREATOR.creator.name;
if (!URL_BASE || !KEY) {
  console.error("No backend to test: creator/app.json needs backend.projectRef and backend.publishableKey.");
  process.exit(1);
}
const run = Math.random().toString(36).slice(2, 8);
const PASSWORD = `e2e-${run}-${Math.random().toString(36).slice(2, 10)}`;

let passed = 0;
let failed = 0;
function check(name, ok, detail = "") {
  if (ok) {
    passed += 1;
    console.log(`  ok   ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

async function http(path, { method = "GET", token, body, headers = {}, raw = false } = {}) {
  const res = await fetch(`${URL_BASE}${path}`, {
    method,
    headers: {
      apikey: KEY,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined && !raw ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : raw ? body : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // not JSON
  }
  return { status: res.status, json, text };
}

const profileHeaders = { "Accept-Profile": SCHEMA, "Content-Profile": SCHEMA };
const rest = (path, opts = {}) =>
  http(`/rest/v1/${path}`, { ...opts, headers: { ...profileHeaders, ...(opts.headers ?? {}) } });
const insert = (table, token, row) =>
  rest(table, { method: "POST", token, body: row, headers: { Prefer: "return=representation" } });
const rpc = (fn, token, args = {}) => rest(`rpc/${fn}`, { method: "POST", token, body: args });

async function signUp(label, name) {
  const email = `e2e-${label}-${run}@example.com`;
  const res = await http("/auth/v1/signup", {
    method: "POST",
    body: { email, password: PASSWORD, data: { display_name: name } },
  });
  const token = res.json?.access_token;
  const id = res.json?.user?.id;
  check(`sign up ${label} returns a session (email confirmation is off)`, Boolean(token && id),
    `${res.status} ${res.text.slice(0, 200)}`);
  return { email, token, id, name };
}

async function askAgent(token, message, postId) {
  const res = await fetch(`${URL_BASE}/functions/v1/${SCHEMA}-agent`, {
    method: "POST",
    headers: { apikey: KEY, Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ message, post_id: postId ?? undefined, tz_offset_minutes: -300 }),
  });
  if (res.status !== 200) return { status: res.status, error: await res.text() };
  const events = [];
  let buffer = "";
  const decoder = new TextDecoder();
  for await (const chunk of res.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (line.startsWith("data:")) events.push(JSON.parse(line.slice(5).trim()));
    }
  }
  return {
    status: 200,
    model: res.headers.get("x-agent-model"),
    events,
    deltas: events.filter((e) => e.type === "delta").length,
    reply: events.find((e) => e.type === "done")?.message?.content ?? null,
    error: events.find((e) => e.type === "error")?.message ?? null,
  };
}

console.log(`backend ${URL_BASE} · run ${run}\n`);

// --- Signed-out visitors get nothing ----------------------------------------
console.log("signed out");
{
  const posts = await rest("posts?select=id&limit=1");
  check("cannot read the feed", posts.status >= 400, `${posts.status} ${posts.text.slice(0, 120)}`);
  const agent = await http(`/functions/v1/${SCHEMA}-agent`, { method: "POST", body: { message: "hi" } });
  check(`cannot talk to ${AGENT}`, agent.status === 401, `${agent.status}`);
  const privacy = await http(`/functions/v1/${SCHEMA}-privacy`);
  check("can read the privacy policy", privacy.status === 200 && privacy.text.includes("PRIVACY POLICY"));
}

// --- Member A ---------------------------------------------------------------
console.log("\nmember A");
const a = await signUp("a", "Sam Tester");
if (!a.token) {
  console.log("\nCannot continue without a session. Is email confirmation still on for this project?");
  process.exit(1);
}
{
  const profile = await rest(`profiles?select=id,display_name,is_admin,onboarded_at&id=eq.${a.id}`, { token: a.token });
  check("profile row was created with the sign-up name",
    profile.json?.[0]?.display_name === "Sam Tester" && profile.json?.[0]?.is_admin === false,
    profile.text.slice(0, 200));

  const escalate = await rest(`profiles?id=eq.${a.id}`, { method: "PATCH", token: a.token, body: { is_admin: true } });
  check("cannot make itself an admin", escalate.status >= 400, `${escalate.status}`);

  const rename = await rest(`profiles?id=eq.${a.id}`, { method: "PATCH", token: a.token, body: { display_name: "Sam" } });
  check("can rename itself", rename.status < 300, `${rename.status} ${rename.text.slice(0, 120)}`);

  const goal = await insert("goals", a.token, {
    title: "Ship my first iOS app",
    details: "A habit tracker for climbers. I keep rewriting the data model.",
  });
  check("can add a goal", goal.status === 201 && goal.json?.[0]?.user_id === a.id, `${goal.status} ${goal.text.slice(0, 160)}`);
  a.goalId = goal.json?.[0]?.id;

  const feed = await rest("posts?select=id,body,link_url,is_early&order=created_at.desc", { token: a.token });
  check("can read the feed", feed.status === 200 && Array.isArray(feed.json), `${feed.status} n=${feed.json?.length}`);
  a.firstPostId = feed.json?.[0]?.id ?? null; // null on a backend with nothing posted yet

  const post = await insert("posts", a.token, { body: "members cannot post" });
  check("cannot post to the feed", post.status >= 400, `${post.status}`);

  const context = await rest("post_context?select=post_id", { token: a.token });
  check(`cannot read ${AGENT}'s private post notes`, context.status === 200 && context.json.length === 0, `${context.status} n=${context.json?.length}`);
  const notes = await rest("agent_notes?select=id", { token: a.token });
  check(`cannot read ${NAME}'s notes for ${AGENT}`, notes.status === 200 && notes.json.length === 0, `${notes.status}`);
  const usage = await rest("agent_usage?select=day", { token: a.token });
  check("cannot read usage counters", usage.status >= 400, `${usage.status}`);
  const codes = await rest("admin_codes?select=code_hash", { token: a.token });
  check("cannot read creator codes", codes.status >= 400, `${codes.status}`);

  const forged = await insert("agent_messages", a.token, { user_id: a.id, role: "assistant", content: "forged" });
  check(`cannot forge ${AGENT} messages`, forged.status >= 400, `${forged.status}`);

  const threads = await rpc("admin_threads", a.token);
  check("creator inbox is empty for a member", threads.status === 200 && threads.json.length === 0, `${threads.status}`);

  const wrongCode = await rpc("claim_admin", a.token, { code: "AAAA-AAAA-AAAA-AAAA" });
  check("a wrong creator code is rejected", wrongCode.status === 200 && wrongCode.json === false, `${wrongCode.status} ${wrongCode.text}`);
}

// --- The agent ---------------------------------------------------------------
console.log(`\n${AGENT}`);
{
  const first = await askAgent(a.token, "what have you been working on lately?", a.firstPostId);
  check("streams a reply", first.status === 200 && first.deltas > 0 && Boolean(first.reply),
    `${first.status} ${first.error ?? ""}`);
  console.log(`       model: ${first.model ?? "(not reported)"}`);
  if (first.reply) console.log(`       "${first.reply.replace(/\s+/g, " ").slice(0, 220)}"`);

  const second = await askAgent(a.token, "ok and what should i do today for my own goal? one sentence");
  check("uses the member's goal", Boolean(second.reply) && /app|climb|model|ship|habit/i.test(second.reply ?? ""),
    second.error ?? second.reply?.slice(0, 160));
  if (second.reply) console.log(`       "${second.reply.replace(/\s+/g, " ").slice(0, 220)}"`);

  const history = await rest("agent_messages?select=role,content,post_id&order=created_at.asc", { token: a.token });
  check("both turns of both exchanges were saved", history.json?.length === 4 &&
    history.json.map((m) => m.role).join(",") === "user,assistant,user,assistant", `n=${history.json?.length}`);
  check("the first message is linked to the post it was about (when the feed has one)", history.json?.[0]?.post_id === a.firstPostId);

  const empty = await askAgent(a.token, "   ");
  check("empty messages are refused", empty.status === 400, `${empty.status}`);
}

// --- Direct messages + isolation between members -----------------------------
console.log("\ndirect messages and isolation");
const b = await signUp("b", "Other Member");
{
  const dm = await insert("dm_messages", a.token, { thread_user_id: a.id, body: `hey ${NAME}, quick question about the app` });
  check(`A can message ${NAME}`, dm.status === 201 && dm.json?.[0]?.sender_id === a.id, `${dm.status} ${dm.text.slice(0, 160)}`);

  const spoof = await insert("dm_messages", a.token, { thread_user_id: a.id, sender_id: b.id, body: "spoofed sender" });
  check("A cannot send as someone else", spoof.status >= 400, `${spoof.status}`);

  const intrude = await insert("dm_messages", b.token, { thread_user_id: a.id, body: "B writing into A's thread" });
  check("B cannot write into A's thread", intrude.status >= 400, `${intrude.status}`);

  const peekDm = await rest(`dm_messages?select=id&thread_user_id=eq.${a.id}`, { token: b.token });
  check("B cannot read A's thread", peekDm.status === 200 && peekDm.json.length === 0, `n=${peekDm.json?.length}`);
  const peekGoals = await rest(`goals?select=id&user_id=eq.${a.id}`, { token: b.token });
  check("B cannot read A's goals", peekGoals.status === 200 && peekGoals.json.length === 0, `n=${peekGoals.json?.length}`);
  const peekChat = await rest(`agent_messages?select=id&user_id=eq.${a.id}`, { token: b.token });
  check(`B cannot read A's ${AGENT} conversation`, peekChat.status === 200 && peekChat.json.length === 0, `n=${peekChat.json?.length}`);
  const peekProfile = await rest(`profiles?select=id&id=eq.${a.id}`, { token: b.token });
  check("B cannot read A's profile", peekProfile.status === 200 && peekProfile.json.length === 0, `n=${peekProfile.json?.length}`);
  const editGoal = await rest(`goals?id=eq.${a.goalId}`, { method: "PATCH", token: b.token, body: { title: "hacked" }, headers: { Prefer: "return=representation" } });
  check("B cannot edit A's goal", editGoal.status >= 400 || editGoal.json?.length === 0, `${editGoal.status}`);
  const markRead = await rpc("mark_thread_read", b.token, { thread: a.id });
  check("B cannot mark A's thread read", markRead.status >= 400, `${markRead.status}`);
}

// --- Creator flows (only with a spare one-time code) -------------------------
let c = null;
if (process.env.E2E_ADMIN_CODE) {
  console.log("\ncreator");
  c = await signUp("admin", "E2E Creator");
  const claim = await rpc("claim_admin", c.token, { code: process.env.E2E_ADMIN_CODE });
  check("spare creator code is accepted", claim.json === true, `${claim.status} ${claim.text}`);
  const reuse = await rpc("claim_admin", b.token, { code: process.env.E2E_ADMIN_CODE });
  check("the same code cannot be used twice", reuse.json === false, `${reuse.status} ${reuse.text}`);

  const post = await insert("posts", c.token, {
    kind: "post", body: `e2e early post ${run}`, is_early: true,
    link_url: "https://example.com", link_title: "Example",
  });
  check("creator can post", post.status === 201, `${post.status} ${post.text.slice(0, 160)}`);
  const postId = post.json?.[0]?.id;
  const ctx = await rest("post_context", { method: "POST", token: c.token, body: { post_id: postId, context: "e2e private note" }, headers: { Prefer: "resolution=merge-duplicates" } });
  check(`creator can attach private notes for ${AGENT}`, ctx.status < 300, `${ctx.status} ${ctx.text.slice(0, 120)}`);
  const seen = await rest(`posts?select=id&id=eq.${postId}`, { token: a.token });
  check("members see the new post", seen.json?.length === 1);

  const note = await insert("agent_notes", c.token, { title: `e2e ${run}`, content: "My favourite test word is quixotic." });
  check(`creator can teach ${AGENT}`, note.status === 201, `${note.status}`);
  const taught = await askAgent(a.token, "what's your favourite test word? just the word");
  check(`${AGENT} uses what the creator taught it`, /quixotic/i.test(taught.reply ?? ""), taught.reply?.slice(0, 120) ?? taught.error);

  const inbox = await rpc("admin_threads", c.token);
  const row = inbox.json?.find((t) => t.member_id === a.id);
  check("creator inbox lists A's thread with 1 unread and 1 goal",
    row?.unread === 1 && row?.active_goals === 1 && row?.member_name === "Sam", JSON.stringify(row ?? inbox.text).slice(0, 200));
  const goals = await rest(`goals?select=title&user_id=eq.${a.id}`, { token: c.token });
  check("creator can read A's goals", goals.json?.length === 1);
  const reply = await insert("dm_messages", c.token, { thread_user_id: a.id, body: "hey Sam — happy to help. what's the question?" });
  check("creator can reply in A's thread", reply.status === 201, `${reply.status} ${reply.text.slice(0, 120)}`);
  const read = await rpc("mark_thread_read", c.token, { thread: a.id });
  const inboxAfter = await rpc("admin_threads", c.token);
  check("marking read clears the unread count", read.status < 300 && inboxAfter.json?.find((t) => t.member_id === a.id)?.unread === 0);
  const aThread = await rest(`dm_messages?select=body,sender_id,read_at&thread_user_id=eq.${a.id}&order=created_at.asc`, { token: a.token });
  check("A sees the reply, and sees their own message was read",
    aThread.json?.length === 2 && aThread.json[0].read_at !== null && aThread.json[1].sender_id === c.id);

  // Media: only the creator writes; any member reads; visitors don't.
  const jpeg = Buffer.from("/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=", "base64");
  const path = `images/e2e-${run}.jpg`;
  const up = await http(`/storage/v1/object/${SCHEMA}-media/${path}`, { method: "POST", token: c.token, body: jpeg, raw: true, headers: { "Content-Type": "image/jpeg" } });
  check("creator can upload media", up.status === 200, `${up.status} ${up.text.slice(0, 160)}`);
  const memberUp = await http(`/storage/v1/object/${SCHEMA}-media/images/e2e-member-${run}.jpg`, { method: "POST", token: a.token, body: jpeg, raw: true, headers: { "Content-Type": "image/jpeg" } });
  check("members cannot upload media", memberUp.status >= 400, `${memberUp.status}`);
  const down = await http(`/storage/v1/object/authenticated/${SCHEMA}-media/${path}`, { token: a.token });
  check("members can view media", down.status === 200, `${down.status}`);
  const anonDown = await http(`/storage/v1/object/authenticated/${SCHEMA}-media/${path}`);
  check("signed-out visitors cannot view media", anonDown.status >= 400, `${anonDown.status}`);
  const signed = await http(`/storage/v1/object/sign/${SCHEMA}-media/${path}`, { method: "POST", token: a.token, body: { expiresIn: 60 } });
  check("members can get a streaming link", signed.status === 200 && Boolean(signed.json?.signedURL), `${signed.status} ${signed.text.slice(0, 120)}`);

  // Leave nothing behind.
  await http(`/storage/v1/object/${SCHEMA}-media/${path}`, { method: "DELETE", token: c.token });
  const delPost = await rest(`posts?id=eq.${postId}`, { method: "DELETE", token: c.token });
  const delNote = await rest(`agent_notes?id=eq.${note.json?.[0]?.id}`, { method: "DELETE", token: c.token });
  check("creator can delete its post and note", delPost.status < 300 && delNote.status < 300);

  const adminDelete = await http(`/functions/v1/${SCHEMA}-delete-account`, { method: "POST", token: c.token });
  check("the creator account cannot be deleted from the app", adminDelete.status === 403, `${adminDelete.status}`);
} else {
  console.log("\ncreator flows skipped (set E2E_ADMIN_CODE to a spare one-time code to run them)");
}

// --- Account deletion --------------------------------------------------------
console.log("\naccount deletion");
for (const member of [a, b]) {
  const del = await http(`/functions/v1/${SCHEMA}-delete-account`, { method: "POST", token: member.token });
  check(`${member.name} can delete their account`, del.status === 200 && del.json?.ok === true, `${del.status} ${del.text.slice(0, 120)}`);
  const signIn = await http("/auth/v1/token?grant_type=password", { method: "POST", body: { email: member.email, password: PASSWORD } });
  check(`${member.name} can no longer sign in`, signIn.status >= 400, `${signIn.status}`);
}
if (c) {
  const inbox = await rpc("admin_threads", c.token);
  check("A's thread is gone from the creator inbox", !inbox.json?.some((t) => t.member_id === a.id));
  console.log(`\nNOTE: creator test account ${c.email} still exists (admins can't self-delete). Remove it with a cleanup migration in creator/migrations/.`);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
