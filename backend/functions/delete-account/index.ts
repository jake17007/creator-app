// Permanently delete the calling member's account (App Review requirement).
// Their profile, goals, agent conversation and 1:1 thread all reference
// auth.users with ON DELETE CASCADE, so removing the auth user removes them.
//
// Creator (admin) accounts are refused: deleting one would also delete every
// reply the creator has sent. Remove admin access first if that is ever intended.
//
// Deployed with verify_jwt = false; the token is checked here with auth.getUser.
import { createClient } from "npm:@supabase/supabase-js@2";

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), {
      db: { schema: "creatorapp" },
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ error: "unauthorized" }, 401);
    const { data, error } = await db.auth.getUser(token);
    if (error || !data?.user) return json({ error: "unauthorized" }, 401);

    const { data: profile } = await db
      .from("profiles")
      .select("is_admin")
      .eq("id", data.user.id)
      .maybeSingle();
    if (profile?.is_admin) {
      return json({
        error: "admin_account",
        message: "This is the creator account, so it can't be deleted from inside the app.",
      }, 403);
    }

    const { error: deleteError } = await db.auth.admin.deleteUser(data.user.id);
    if (deleteError) {
      console.error("delete-account failed:", deleteError);
      return json({ error: "delete_failed" }, 500);
    }
    return json({ ok: true });
  } catch (error) {
    console.error("delete-account error:", error);
    return json({ error: "delete_failed" }, 500);
  }
});
