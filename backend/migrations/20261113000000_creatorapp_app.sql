-- Backend schema for the creator app (iPhone).
--
-- Everything this app owns lives in the `creatorapp` schema (plus one storage
-- bucket, `creatorapp-media`, and edge functions prefixed `creatorapp-`), so it
-- can never be confused with anything else in this Supabase project. To remove
-- the app's data entirely: `drop schema creatorapp cascade;`, delete the bucket,
-- and drop the `creatorapp_on_auth_user_created` trigger on auth.users.

create schema creatorapp;

grant usage on schema creatorapp to authenticated, service_role;
alter default privileges in schema creatorapp grant all on tables to service_role;
alter default privileges in schema creatorapp grant all on sequences to service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create function creatorapp.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Profiles (one per signed-up user). `is_admin` marks the creator account(s):
-- admins post to the feed, see every 1:1 thread, and can read a member's goals.
-- ---------------------------------------------------------------------------

create table creatorapp.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 60),
  is_admin boolean not null default false,
  onboarded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_touch before update on creatorapp.profiles
  for each row execute function creatorapp.touch_updated_at();

-- SECURITY DEFINER so RLS policies can ask "is the caller an admin?" without
-- recursing into the profiles policies.
create function creatorapp.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from creatorapp.profiles p
    where p.id = (select auth.uid()) and p.is_admin
  );
$$;

alter table creatorapp.profiles enable row level security;

-- Members may only change their own name / onboarding flag; never is_admin.
grant select on creatorapp.profiles to authenticated;
grant update (display_name, onboarded_at) on creatorapp.profiles to authenticated;

create policy "profiles: read own, admins read all"
  on creatorapp.profiles for select to authenticated
  using (id = (select auth.uid()) or creatorapp.is_admin());

create policy "profiles: update own"
  on creatorapp.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Create the profile row when someone signs up. Never blocks the sign-up.
create function creatorapp.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into creatorapp.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(
      new.raw_user_meta_data ->> 'display_name',
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      ''
    ), 60)
  )
  on conflict (id) do nothing;
  return new;
exception when others then
  raise warning 'creatorapp.handle_new_user failed: %', sqlerrm;
  return new;
end;
$$;

create trigger creatorapp_on_auth_user_created
  after insert on auth.users
  for each row execute function creatorapp.handle_new_user();

-- Safety net the app calls after sign-in (covers accounts that pre-date the trigger).
create function creatorapp.ensure_profile()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  insert into creatorapp.profiles (id) values (uid) on conflict (id) do nothing;
end;
$$;

-- ---------------------------------------------------------------------------
-- One-time creator codes: how the first admin account is claimed from inside
-- the app (Settings → Creator access). Only SHA-256 hashes are stored.
-- ---------------------------------------------------------------------------

create table creatorapp.admin_codes (
  code_hash text primary key,
  note text,
  claimed_by uuid references auth.users (id) on delete set null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table creatorapp.admin_codes enable row level security;

create table creatorapp.admin_claim_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table creatorapp.admin_claim_attempts enable row level security;

create function creatorapp.claim_admin(code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
  recent int;
  hashed text;
begin
  if uid is null then
    raise exception 'not signed in';
  end if;

  select count(*) into recent
  from creatorapp.admin_claim_attempts a
  where a.user_id = uid and a.created_at > now() - interval '1 hour';
  if recent >= 5 then
    raise exception 'Too many attempts. Try again in an hour.';
  end if;
  insert into creatorapp.admin_claim_attempts (user_id) values (uid);

  hashed := encode(
    sha256(convert_to(upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')),
    'hex'
  );

  update creatorapp.admin_codes c
  set claimed_by = uid, claimed_at = now()
  where c.code_hash = hashed and c.claimed_by is null;
  if not found then
    return false;
  end if;

  insert into creatorapp.profiles (id, is_admin) values (uid, true)
  on conflict (id) do update set is_admin = true;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Goals: what each member is working toward. The agent gets these as context,
-- and the creator (admin) can read them when replying in the 1:1 chat.
-- ---------------------------------------------------------------------------

create table creatorapp.goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 140),
  details text not null default '' check (char_length(details) <= 2000),
  status text not null default 'active' check (status in ('active', 'done')),
  target_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index goals_user_idx on creatorapp.goals (user_id, created_at);

create trigger goals_touch before update on creatorapp.goals
  for each row execute function creatorapp.touch_updated_at();

create function creatorapp.enforce_goal_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select count(*) from creatorapp.goals g where g.user_id = new.user_id) >= 50 then
    raise exception 'You can keep up to 50 goals. Remove one to add another.';
  end if;
  return new;
end;
$$;

create trigger goals_limit before insert on creatorapp.goals
  for each row execute function creatorapp.enforce_goal_limit();

alter table creatorapp.goals enable row level security;
grant select, insert, update, delete on creatorapp.goals to authenticated;

create policy "goals: read own, admins read all"
  on creatorapp.goals for select to authenticated
  using (user_id = (select auth.uid()) or creatorapp.is_admin());
create policy "goals: insert own"
  on creatorapp.goals for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "goals: update own"
  on creatorapp.goals for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "goals: delete own"
  on creatorapp.goals for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Feed. `post` = the creator's own content (often early, before it is public
-- elsewhere); `share` = a link to something the creator wants members to see.
-- ---------------------------------------------------------------------------

create table creatorapp.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid default auth.uid() references auth.users (id) on delete set null,
  kind text not null default 'post' check (kind in ('post', 'share')),
  body text not null default '' check (char_length(body) <= 8000),
  link_url text check (link_url is null or link_url ~* '^https?://'),
  link_title text check (link_title is null or char_length(link_title) <= 300),
  link_image_path text,
  media_kind text check (media_kind in ('image', 'video')),
  media_path text,
  media_poster_path text,
  media_width int,
  media_height int,
  media_duration real,
  is_early boolean not null default false,
  public_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint posts_has_content check (
    char_length(btrim(body)) > 0 or link_url is not null or media_path is not null
  ),
  constraint posts_media_pair check ((media_kind is null) = (media_path is null))
);
create index posts_created_idx on creatorapp.posts (created_at desc);

create trigger posts_touch before update on creatorapp.posts
  for each row execute function creatorapp.touch_updated_at();

alter table creatorapp.posts enable row level security;
grant select, insert, update, delete on creatorapp.posts to authenticated;

create policy "posts: members read"
  on creatorapp.posts for select to authenticated using (true);
create policy "posts: admins insert"
  on creatorapp.posts for insert to authenticated with check (creatorapp.is_admin());
create policy "posts: admins update"
  on creatorapp.posts for update to authenticated
  using (creatorapp.is_admin()) with check (creatorapp.is_admin());
create policy "posts: admins delete"
  on creatorapp.posts for delete to authenticated using (creatorapp.is_admin());

-- Extra context about a post that only the agent sees (e.g. a video's transcript),
-- so the agent can talk about media it cannot watch.
create table creatorapp.post_context (
  post_id uuid primary key references creatorapp.posts (id) on delete cascade,
  context text not null check (char_length(context) <= 20000),
  updated_at timestamptz not null default now()
);
create trigger post_context_touch before update on creatorapp.post_context
  for each row execute function creatorapp.touch_updated_at();

alter table creatorapp.post_context enable row level security;
grant select, insert, update, delete on creatorapp.post_context to authenticated;
create policy "post_context: admins only"
  on creatorapp.post_context for all to authenticated
  using (creatorapp.is_admin()) with check (creatorapp.is_admin());

-- ---------------------------------------------------------------------------
-- The agent: what the creator teaches it about themself, the chat history, and
-- per-day usage (the spend guard).
-- ---------------------------------------------------------------------------

create table creatorapp.agent_notes (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 120),
  content text not null check (char_length(content) <= 8000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger agent_notes_touch before update on creatorapp.agent_notes
  for each row execute function creatorapp.touch_updated_at();

alter table creatorapp.agent_notes enable row level security;
grant select, insert, update, delete on creatorapp.agent_notes to authenticated;
create policy "agent_notes: admins only"
  on creatorapp.agent_notes for all to authenticated
  using (creatorapp.is_admin()) with check (creatorapp.is_admin());

-- Written only by the `creatorapp-agent` edge function (service role), so a
-- member can neither forge assistant turns nor skip the daily cap.
create table creatorapp.agent_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null check (char_length(content) <= 16000),
  post_id uuid references creatorapp.posts (id) on delete set null,
  created_at timestamptz not null default now()
);
create index agent_messages_user_idx on creatorapp.agent_messages (user_id, created_at);

alter table creatorapp.agent_messages enable row level security;
grant select, delete on creatorapp.agent_messages to authenticated;
create policy "agent_messages: read own"
  on creatorapp.agent_messages for select to authenticated
  using (user_id = (select auth.uid()));
create policy "agent_messages: delete own"
  on creatorapp.agent_messages for delete to authenticated
  using (user_id = (select auth.uid()));

create table creatorapp.agent_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  messages int not null default 0,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  primary key (user_id, day)
);
alter table creatorapp.agent_usage enable row level security;

create function creatorapp.agent_usage_bump(p_user uuid, p_messages int, p_input bigint, p_output bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into creatorapp.agent_usage (user_id, day, messages, input_tokens, output_tokens)
  values (p_user, (now() at time zone 'utc')::date, p_messages, p_input, p_output)
  on conflict (user_id, day) do update set
    messages = creatorapp.agent_usage.messages + excluded.messages,
    input_tokens = creatorapp.agent_usage.input_tokens + excluded.input_tokens,
    output_tokens = creatorapp.agent_usage.output_tokens + excluded.output_tokens;
$$;

-- ---------------------------------------------------------------------------
-- 1:1 chat with the real creator. One thread per member, keyed by the member's id.
-- ---------------------------------------------------------------------------

create table creatorapp.dm_messages (
  id uuid primary key default gen_random_uuid(),
  thread_user_id uuid not null references auth.users (id) on delete cascade,
  sender_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index dm_messages_thread_idx on creatorapp.dm_messages (thread_user_id, created_at);

alter table creatorapp.dm_messages enable row level security;
grant select, insert on creatorapp.dm_messages to authenticated;

create policy "dm: members read their thread, admins read all"
  on creatorapp.dm_messages for select to authenticated
  using (thread_user_id = (select auth.uid()) or creatorapp.is_admin());
create policy "dm: send as yourself, into your own thread unless admin"
  on creatorapp.dm_messages for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and (thread_user_id = (select auth.uid()) or creatorapp.is_admin())
  );

-- Mark the other side's messages in a thread as read.
create function creatorapp.mark_thread_read(thread uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if thread = uid then
    update creatorapp.dm_messages m set read_at = now()
    where m.thread_user_id = uid and m.sender_id <> uid and m.read_at is null;
  elsif creatorapp.is_admin() then
    update creatorapp.dm_messages m set read_at = now()
    where m.thread_user_id = thread and m.sender_id = thread and m.read_at is null;
  else
    raise exception 'not allowed';
  end if;
end;
$$;

-- Admin inbox: one row per member who has a thread. Non-admins get no rows.
create function creatorapp.admin_threads()
returns table (
  member_id uuid,
  member_name text,
  member_email text,
  last_body text,
  last_at timestamptz,
  last_from_member boolean,
  unread bigint,
  active_goals bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    t.thread_user_id,
    coalesce(p.display_name, ''),
    coalesce(u.email::text, ''),
    latest.body,
    latest.created_at,
    latest.sender_id = t.thread_user_id,
    (select count(*) from creatorapp.dm_messages m
      where m.thread_user_id = t.thread_user_id
        and m.sender_id = t.thread_user_id
        and m.read_at is null),
    (select count(*) from creatorapp.goals g
      where g.user_id = t.thread_user_id and g.status = 'active')
  from (select distinct d.thread_user_id from creatorapp.dm_messages d) t
  join lateral (
    select m.body, m.created_at, m.sender_id
    from creatorapp.dm_messages m
    where m.thread_user_id = t.thread_user_id
    order by m.created_at desc
    limit 1
  ) latest on true
  left join creatorapp.profiles p on p.id = t.thread_user_id
  left join auth.users u on u.id = t.thread_user_id
  where (select creatorapp.is_admin())
  order by latest.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges. Postgres lets PUBLIC execute new functions by default
-- and this schema is exposed over the API, so lock everything down first.
-- ---------------------------------------------------------------------------

revoke all on all functions in schema creatorapp from public, anon, authenticated;

grant execute on function creatorapp.is_admin() to authenticated, service_role;
grant execute on function creatorapp.ensure_profile() to authenticated;
grant execute on function creatorapp.claim_admin(text) to authenticated;
grant execute on function creatorapp.mark_thread_read(uuid) to authenticated;
grant execute on function creatorapp.admin_threads() to authenticated;
grant execute on function creatorapp.agent_usage_bump(uuid, int, bigint, bigint) to service_role;

-- ---------------------------------------------------------------------------
-- Realtime (new DMs and new posts arrive live; RLS still applies).
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table creatorapp.dm_messages;
alter publication supabase_realtime add table creatorapp.posts;

-- ---------------------------------------------------------------------------
-- Media: a private bucket. Any signed-in member can view; only admins write.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'creatorapp-media',
  'creatorapp-media',
  false,
  209715200,
  array['image/jpeg', 'image/png', 'image/heic', 'video/mp4', 'video/quicktime']
);

create policy "creatorapp media: members read"
  on storage.objects for select to authenticated
  using (bucket_id = 'creatorapp-media');
create policy "creatorapp media: admins upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'creatorapp-media' and creatorapp.is_admin());
create policy "creatorapp media: admins update"
  on storage.objects for update to authenticated
  using (bucket_id = 'creatorapp-media' and creatorapp.is_admin())
  with check (bucket_id = 'creatorapp-media' and creatorapp.is_admin());
create policy "creatorapp media: admins delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'creatorapp-media' and creatorapp.is_admin());
