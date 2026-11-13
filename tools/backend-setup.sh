#!/bin/bash
# Sets up the backend for your copy of the app on a NEW Supabase project.
# Run it once, after creator/app.json has backend.projectRef and
# backend.publishableKey (both from the project's dashboard).
#
# What it does, in order:
#   1. Links this folder to the project.
#   2. Makes your one-time creator code (kept in .local/, only its hash is sent).
#   3. Creates the database tables, permissions and the media bucket.
#   4. Pushes the auth settings in supabase/config.toml: exposes the app's
#      schema to the API, lets people sign up without confirming their email,
#      and turns on Sign in with Apple for your bundle id.
#   5. Deploys the three edge functions (agent, delete-account, privacy).
#   6. Stores your OpenRouter API key on the project, for the agent.
#
# Needs the Supabase CLI (brew install supabase/tap/supabase), signed in with
# `supabase login`. Steps 3 to 6 change the project, so use a project that was
# made for this app.
#
# Usage:  ./tools/backend-setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v supabase >/dev/null || { echo "The Supabase CLI isn't installed: brew install supabase/tap/supabase"; exit 1; }

./configure --no-xcodegen
# setting app.name  ->  the value at that path in the resolved settings
setting() { python3 -B tools/setting.py "$1"; }
REF=$(setting backend.projectRef)
NS=$(setting backend.namespace)
APP=$(setting app.name)
AGENT=$(setting agent.name)
KEY_NAME=$(setting backend.secrets.openRouterKey)

if [ -z "$REF" ] || [ -z "$(setting backend.publishableKey)" ]; then
  echo "creator/app.json needs backend.projectRef and backend.publishableKey first."
  echo "Both are in the Supabase dashboard: Project Settings > General (Reference ID) and > API Keys."
  exit 1
fi

echo
echo "This sets up Supabase project $REF as the backend for \"$APP\"."
echo "It creates the \"$NS\" schema and bucket, changes the project's auth settings,"
echo "deploys three functions and stores an API key. Use a project made for this app."
read -r -p "Type the project ref to go ahead: " answer
[ "$answer" = "$REF" ] || { echo "Stopped; nothing was changed."; exit 1; }

echo; echo "1/6  Linking to the project…"
echo "(If it asks for the database password, you can leave it blank.)"
supabase link --project-ref "$REF"

echo; echo "2/6  Creator code…"
if [ -f .local/creator-code.txt ]; then
  echo "Using the code that is already in .local/creator-code.txt."
else
  python3 tools/creator_code.py
fi
./configure --no-xcodegen

echo; echo "3/6  Creating the database…"
supabase db push

echo; echo "4/6  Pushing auth settings…"
supabase config push --project-ref "$REF"

echo; echo "5/6  Deploying functions…"
for fn in agent delete-account privacy; do
  supabase functions deploy "$NS-$fn" --use-api --project-ref "$REF"
done

echo; echo "6/6  OpenRouter key for $AGENT…"
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  read -r -s -p "Paste your OpenRouter API key (it won't be shown): " OPENROUTER_API_KEY; echo
fi
if [ -z "$OPENROUTER_API_KEY" ]; then
  echo "No key given. $AGENT stays off until you run:"
  echo "  supabase secrets set $KEY_NAME=<key> --project-ref $REF"
else
  # Through a private file, so the key never shows up in the process list.
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  printf '%s=%s\n' "$KEY_NAME" "$OPENROUTER_API_KEY" > "$tmp"
  supabase secrets set --env-file "$tmp" --project-ref "$REF"
fi

echo
echo "Done. Check it end to end with:  node tools/e2e-backend.mjs"
echo "Your creator code is in .local/creator-code.txt: sign up in the app, open You,"
echo "tap the version number five times and type it in."
