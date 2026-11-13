#!/usr/bin/env python3
"""Makes a one-time creator code: what you type into the app to turn your own
account into the creator account (You tab, tap the version number five times).

    python3 tools/creator_code.py             your creator code
    python3 tools/creator_code.py --another   an extra code, e.g. for testing

The code itself is written under .local/ (gitignored) and stays on this Mac.
Only its SHA-256 hash goes to the database, through a new file in
creator/migrations/. Afterwards run:

    ./configure && supabase db push

An existing code is never replaced: without --another the script stops if
.local/creator-code.txt is already there.
"""
import argparse
import datetime
import hashlib
import json
import os
import secrets
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no I, L, O, 0 or 1: easy to read back


def main():
    parser = argparse.ArgumentParser(description="Make a one-time creator code.")
    parser.add_argument("--another", action="store_true", help="make an extra code and keep the existing one")
    args = parser.parse_args()

    try:
        with open(os.path.join(ROOT, "creator", "app.json"), encoding="utf-8") as f:
            namespace = (json.load(f).get("backend") or {}).get("namespace") or "creatorapp"
    except FileNotFoundError:
        print("There is no creator/app.json yet. Run ./configure first.", file=sys.stderr)
        return 1

    migrations = os.path.join(ROOT, "creator", "migrations")
    os.makedirs(migrations, exist_ok=True)
    # A migration is identified by its timestamp, so take one nothing else has.
    taken = set()
    for folder in (migrations, os.path.join(ROOT, "backend", "migrations")):
        if os.path.isdir(folder):
            taken.update(name.split("_")[0] for name in os.listdir(folder))
    moment = datetime.datetime.now(datetime.timezone.utc)
    while moment.strftime("%Y%m%d%H%M%S") in taken:
        moment += datetime.timedelta(seconds=1)
    stamp = moment.strftime("%Y%m%d%H%M%S")

    local = os.path.join(ROOT, ".local")
    code_file = os.path.join(local, "creator-code.txt")
    if os.path.exists(code_file):
        if not args.another:
            print("There is already a creator code in .local/creator-code.txt, and it was left alone.\n"
                  "If you haven't used it yet, that is the one to type into the app.\n"
                  "For an extra code, run:  python3 tools/creator_code.py --another", file=sys.stderr)
            return 1
        code_file = os.path.join(local, f"creator-code-{stamp}.txt")

    raw = "".join(secrets.choice(ALPHABET) for _ in range(16))
    pretty = "-".join(raw[i:i + 4] for i in range(0, 16, 4))
    # Must match <namespace>.claim_admin(): uppercase, letters and digits only.
    digest = hashlib.sha256(raw.encode("ascii")).hexdigest()

    os.makedirs(local, exist_ok=True)
    # O_EXCL: never write over a code that is already there.
    fd = os.open(code_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(pretty + "\n")

    migration = os.path.join(migrations, f"{stamp}_creator_code.sql")
    today = datetime.date.today().isoformat()
    with open(migration, "x", encoding="utf-8") as f:
        f.write(
            "-- A one-time creator code. Only the hash is stored; the code itself is in\n"
            "-- .local/ on the Mac that made it and is typed into the app once.\n"
            f"insert into {namespace}.admin_codes (code_hash, note)\n"
            f"values ('{digest}', 'creator code, {today}');\n"
        )

    print(f"Code written to {os.path.relpath(code_file, ROOT)} (keep it private).")
    print(f"Hash written to {os.path.relpath(migration, ROOT)}.")
    print("Next:  ./configure && supabase db push")
    return 0


if __name__ == "__main__":
    sys.exit(main())
