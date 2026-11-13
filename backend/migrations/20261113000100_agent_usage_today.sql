-- Spend guard lookup for the creatorapp-agent edge function: how many agent
-- messages this member has sent today (UTC), and how many everyone has.

create function creatorapp.agent_usage_today(p_user uuid)
returns table (mine int, everyone bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce((
      select u.messages from creatorapp.agent_usage u
      where u.user_id = p_user and u.day = (now() at time zone 'utc')::date
    ), 0),
    coalesce((
      select sum(u.messages) from creatorapp.agent_usage u
      where u.day = (now() at time zone 'utc')::date
    ), 0);
$$;

revoke all on function creatorapp.agent_usage_today(uuid) from public, anon, authenticated;
grant execute on function creatorapp.agent_usage_today(uuid) to service_role;
