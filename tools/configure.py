#!/usr/bin/env python3
"""Turns creator/ (who this copy of the app belongs to) into the files the app
and the backend are built from. Run it after every change to creator/.

    ./configure                 write everything, then regenerate the Xcode project
    ./configure --check         only validate creator/
    ./configure --no-xcodegen   write everything, leave the Xcode project alone

What it reads:
    creator/app.json            names, bundle id, backend, analytics
    creator/persona.md          who the creator is and how they talk (for the agent)
    creator/icon.png            the app icon, 1024x1024 (optional)
    creator/migrations/*.sql    extra database changes for this copy only (optional)

What it writes (all gitignored):
    Generated/                  Swift constants, the privacy policy, build settings
    supabase/                   the backend, ready for the Supabase CLI
    App/Assets.xcassets/AppIcon.appiconset/AppIcon.png

The first run copies creator.example/ to creator/ so there is something to edit.
Python standard library only; works with the python3 that ships with Xcode.
"""
import argparse
import base64
import datetime
import json
import os
import re
import shutil
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import policy  # noqa: E402

# The namespace the shared backend source is written with. ./configure swaps it
# for backend.namespace wherever it appears under backend/.
ENGINE_NAMESPACE = "creatorapp"

PRONOUNS = {
    "he": {"subject": "he", "object": "him", "possessive": "his", "reflexive": "himself", "subjectIs": "he is"},
    "she": {"subject": "she", "object": "her", "possessive": "her", "reflexive": "herself", "subjectIs": "she is"},
    "they": {"subject": "they", "object": "them", "possessive": "their", "reflexive": "themself", "subjectIs": "they are"},
}

DEFAULT_SECRETS = {
    "model": "AGENT_MODEL",
    "dailyCap": "AGENT_DAILY_CAP",
    "globalDailyCap": "AGENT_GLOBAL_DAILY_CAP",
    "maxTokens": "AGENT_MAX_TOKENS",
    "effort": "AGENT_EFFORT",
    "openRouterKey": "AGENT_OPENROUTER_API_KEY",
}


class ConfigError(Exception):
    pass


def path(*parts):
    return os.path.join(ROOT, *parts)


def read(*parts):
    with open(path(*parts), encoding="utf-8") as f:
        return f.read()


def write(relative, content, written):
    """Writes a file only when its content changed, so builds stay incremental."""
    target = path(relative)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    data = content if isinstance(content, bytes) else content.encode("utf-8")
    written.append(relative)
    if os.path.exists(target):
        with open(target, "rb") as f:
            if f.read() == data:
                return False
    with open(target, "wb") as f:
        f.write(data)
    return True


# ------------------------------------------------------------------ creator/

def text_at(data, dotted, default=None, required=False):
    node = data
    for key in dotted.split("."):
        node = node.get(key) if isinstance(node, dict) else None
        if node is None:
            break
    if node is None or (isinstance(node, str) and not node.strip()):
        if required:
            raise ConfigError(f"creator/app.json: \"{dotted}\" is missing.")
        return default
    if not isinstance(node, (str, int)) or isinstance(node, bool):
        raise ConfigError(f"creator/app.json: \"{dotted}\" should be text.")
    return str(node).strip()


def is_secret_key(key):
    """True for a Supabase key that must never ship inside an app."""
    if key.startswith("sb_secret_"):
        return True
    parts = key.split(".")
    if len(parts) == 3:  # an older JWT-style key: the role is in the middle part
        try:
            payload = base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
            return json.loads(payload).get("role") == "service_role"
        except (ValueError, AttributeError):
            return False
    return False


def load_config():
    try:
        raw = json.loads(read("creator", "app.json"))
    except ValueError as error:
        raise ConfigError(f"creator/app.json isn't valid JSON: {error}")
    if not isinstance(raw, dict):
        raise ConfigError("creator/app.json should be a JSON object.")

    app_name = text_at(raw, "app.name", required=True)
    if any(bad in app_name for bad in ("//", "$(", "\n")):
        raise ConfigError("creator/app.json: \"app.name\" can't contain //, $( or a line break.")
    bundle_id = text_at(raw, "app.bundleId", required=True)
    if not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", bundle_id):
        raise ConfigError("creator/app.json: \"app.bundleId\" should look like com.yourname.yourapp.")
    namespace = text_at(raw, "backend.namespace", default=ENGINE_NAMESPACE)
    if not re.fullmatch(r"[a-z][a-z0-9]{2,29}", namespace):
        raise ConfigError("creator/app.json: \"backend.namespace\" should be 3 to 30 lowercase letters and digits, "
                          "starting with a letter (it names the database schema, so no spaces or dashes).")
    url_scheme = text_at(raw, "app.urlScheme", default=namespace)
    if not re.fullmatch(r"[a-z][a-z0-9+.-]*", url_scheme):
        raise ConfigError("creator/app.json: \"app.urlScheme\" should be lowercase letters and digits, like myapp.")
    version = text_at(raw, "app.version", default="1.0")
    if not re.fullmatch(r"\d+(\.\d+){0,2}", version):
        raise ConfigError("creator/app.json: \"app.version\" should look like 1.0.")
    build = text_at(raw, "app.build", default="1")
    if not re.fullmatch(r"[1-9]\d*", build):
        raise ConfigError("creator/app.json: \"app.build\" should be a whole number, 1 or more.")
    product_name = text_at(raw, "app.productName", default="CreatorApp")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", product_name):
        raise ConfigError("creator/app.json: \"app.productName\" should be letters and digits only.")

    name = text_at(raw, "creator.name", required=True)
    pronouns = text_at(raw, "creator.pronouns", default="they").lower()
    if pronouns not in PRONOUNS:
        raise ConfigError("creator/app.json: \"creator.pronouns\" should be he, she or they.")
    identity = ", ".join(x for x in (text_at(raw, "creator.fullName"), text_at(raw, "creator.handle")) if x)

    agent_name = text_at(raw, "agent.name", required=True)

    email = text_at(raw, "legal.contactEmail", required=True)
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        raise ConfigError("creator/app.json: \"legal.contactEmail\" doesn't look like an email address.")
    entity = text_at(raw, "legal.entity", default=text_at(raw, "creator.fullName", default=name))
    policy_updated = text_at(raw, "legal.policyUpdated")
    if not policy_updated:
        today = datetime.date.today()
        policy_updated = f"{today.strftime('%B')} {today.day}, {today.year}"

    team_id = text_at(raw, "apple.teamId", default="")
    if team_id and not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ConfigError("creator/app.json: \"apple.teamId\" should be the 10-character Apple team id.")

    project_ref = text_at(raw, "backend.projectRef", default="")
    if project_ref and not re.fullmatch(r"[a-z0-9]{15,30}", project_ref):
        raise ConfigError("creator/app.json: \"backend.projectRef\" should be the Supabase project's reference id.")
    backend_url = text_at(raw, "backend.url", default=f"https://{project_ref}.supabase.co" if project_ref else "")
    if backend_url and not re.fullmatch(r"https?://[^\s/]+(:\d+)?", backend_url):
        raise ConfigError("creator/app.json: \"backend.url\" should be an address like https://abc.supabase.co.")
    publishable_key = text_at(raw, "backend.publishableKey", default="")
    if is_secret_key(publishable_key):
        raise ConfigError("creator/app.json: \"backend.publishableKey\" looks like a secret key. Use the publishable "
                          "(anon) key: this one is shipped inside the app.")
    secrets = dict(DEFAULT_SECRETS)
    for key, value in (raw.get("backend", {}).get("secrets") or {}).items():
        if key not in DEFAULT_SECRETS:
            raise ConfigError(f"creator/app.json: unknown entry \"backend.secrets.{key}\".")
        if not isinstance(value, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", value):
            raise ConfigError(f"creator/app.json: \"backend.secrets.{key}\" should be a name like AGENT_MODEL.")
        secrets[key] = value

    posthog_token = text_at(raw, "analytics.posthogToken", default="")
    if posthog_token and not posthog_token.startswith("phc_"):
        raise ConfigError("creator/app.json: \"analytics.posthogToken\" should be the project token that starts "
                          "with phc_ (not a personal API key).")
    posthog_host = text_at(raw, "analytics.posthogHost", default="https://us.i.posthog.com")

    return {
        "app": {"name": app_name, "bundleId": bundle_id, "urlScheme": url_scheme, "version": version,
                "build": build, "productName": product_name},
        "creator": {"name": name, "identity": identity, "pronouns": pronouns, "pronounSet": PRONOUNS[pronouns]},
        "agent": {"name": agent_name},
        "legal": {"entity": entity, "contactEmail": email, "policyUpdated": policy_updated},
        "apple": {"teamId": team_id},
        "backend": {"namespace": namespace, "projectRef": project_ref, "url": backend_url,
                    "publishableKey": publishable_key, "secrets": secrets},
        "analytics": {"enabled": bool(posthog_token), "posthogToken": posthog_token, "posthogHost": posthog_host,
                      "posthogProjectId": text_at(raw, "analytics.posthogProjectId", default=""),
                      "appTag": text_at(raw, "analytics.appTag", default=f"{namespace}-ios")},
    }


SECTIONS = {
    "who you are": "facts",
    "how you talk": "voice",
    "how you sound": "samples",
    "first-person example": "firstPerson",
}


def load_persona():
    """creator/persona.md: `# Heading` sections, one item per line."""
    persona = {"facts": [], "voice": [], "samples": [], "firstPerson": None}
    if not os.path.exists(path("creator", "persona.md")):
        return persona
    text = re.sub(r"<!--.*?-->", "", read("creator", "persona.md"), flags=re.S)
    section = None
    example = {}
    for line in text.split("\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            title = line.lstrip("#").strip().lower()
            if title not in SECTIONS:
                raise ConfigError(f"creator/persona.md: unknown section \"{line}\". Use: "
                                  + ", ".join(f"\"# {t.capitalize()}\"" for t in SECTIONS) + ".")
            section = SECTIONS[title]
            continue
        if section is None:
            raise ConfigError("creator/persona.md: text has to come under a heading such as \"# Who you are\".")
        if "`" in line or "${" in line or "\\" in line:
            raise ConfigError("creator/persona.md: a backtick, a backslash and ${ aren't allowed.")
        if section == "firstPerson":
            match = re.fullmatch(r"(wrong|right)\s*:\s*(.+)", line, flags=re.I)
            if not match:
                raise ConfigError("creator/persona.md: \"# First-person example\" takes two lines, "
                                  "\"Wrong: ...\" and \"Right: ...\".")
            example[match.group(1).lower()] = match.group(2)
        elif section == "samples":
            persona["samples"].append(line)
        else:
            persona[section].append(re.sub(r"^[-*]\s+", "", line))
    if example:
        if set(example) != {"wrong", "right"}:
            raise ConfigError("creator/persona.md: \"# First-person example\" needs both a Wrong: and a Right: line.")
        persona["firstPerson"] = example
    return persona


# ------------------------------------------------------------------- outputs

def swift_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def creator_swift(c):
    rows = [
        ("The app's name, as it appears under the icon and on the sign-in screen.", "appName", c["app"]["name"]),
        ("The creator, as members see them (\"Message Sam\", the Sam tab).", "name", c["creator"]["name"]),
        ("The AI version of the creator.", "agentName", c["agent"]["name"]),
        ("Names the database schema, the media bucket and the edge functions.", "namespace", c["backend"]["namespace"]),
        ("The Supabase project. Empty until creator/app.json has one.", "backendURL", c["backend"]["url"]),
        ("The project's publishable key. Safe to ship: row-level security protects the data, not this key.",
         "publishableKey", c["backend"]["publishableKey"]),
        ("Opens the app from an auth link: <scheme>://auth-callback.", "urlScheme", c["app"]["urlScheme"]),
        ("Where \"Contact\" in the You tab sends mail.", "contactEmail", c["legal"]["contactEmail"]),
        ("PostHog project token. Empty means no analytics and no screen recordings.", "postHogToken",
         c["analytics"]["posthogToken"]),
        ("", "postHogHost", c["analytics"]["posthogHost"]),
        ("The `app` property on every analytics event, to tell this app apart in a shared PostHog project.",
         "analyticsApp", c["analytics"]["appTag"]),
    ]
    body = []
    for comment, key, value in rows:
        if comment:
            body.append(f"    /// {comment}")
        body.append(f"    static let {key} = {swift_string(value)}")
    return (
        "// Who this copy of the app belongs to.\n"
        "//\n"
        "// Written by ./configure from creator/app.json. Do not edit: change that file\n"
        "// and run ./configure again.\n"
        "\n"
        "enum Creator {\n" + "\n".join(body) + "\n}\n"
    )


def xcconfig(c):
    return (
        "// Written by ./configure from creator/app.json. Do not edit.\n"
        f"CREATOR_APP_NAME = {c['app']['name']}\n"
        f"CREATOR_BUNDLE_ID = {c['app']['bundleId']}\n"
        f"CREATOR_PRODUCT_NAME = {c['app']['productName']}\n"
        f"CREATOR_URL_SCHEME = {c['app']['urlScheme']}\n"
        f"CREATOR_VERSION = {c['app']['version']}\n"
        f"CREATOR_BUILD = {c['app']['build']}\n"
        f"CREATOR_TEAM_ID = {c['apple']['teamId']}\n"
    )


def export_options(c, destination):
    team = f"\t<key>teamID</key>\n\t<string>{c['apple']['teamId']}</string>\n" if c["apple"]["teamId"] else ""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n<dict>\n'
        "\t<key>method</key>\n\t<string>app-store-connect</string>\n"
        "\t<key>signingStyle</key>\n\t<string>automatic</string>\n"
        f"{team}"
        f"\t<key>destination</key>\n\t<string>{destination}</string>\n"
        "</dict>\n</plist>\n"
    )


def creator_ts(c, persona):
    value = {
        "name": c["creator"]["name"],
        "identity": c["creator"]["identity"],
        "appName": c["app"]["name"],
        "agentName": c["agent"]["name"],
        "pronouns": c["creator"]["pronounSet"],
        "persona": persona,
        "secrets": c["backend"]["secrets"],
    }
    return (
        "// Who the agent is the AI version of.\n"
        "//\n"
        "// Written by ./configure from creator/app.json and creator/persona.md. Do not\n"
        "// edit: change those files and run ./configure again.\n"
        "\n"
        "export interface Creator {\n"
        "  /** The creator, as members see them. */\n"
        "  name: string;\n"
        "  /** Full name and handle for the agent's introduction; may be empty. */\n"
        "  identity: string;\n"
        "  appName: string;\n"
        "  agentName: string;\n"
        "  pronouns: { subject: string; object: string; possessive: string; reflexive: string; subjectIs: string };\n"
        "  persona: {\n"
        "    facts: string[];\n"
        "    voice: string[];\n"
        "    samples: string[];\n"
        "    firstPerson: { wrong: string; right: string } | null;\n"
        "  };\n"
        "  /** Names of the edge-function secrets the agent reads. */\n"
        "  secrets: {\n"
        "    model: string;\n"
        "    dailyCap: string;\n"
        "    globalDailyCap: string;\n"
        "    maxTokens: string;\n"
        "    effort: string;\n"
        "    openRouterKey: string;\n"
        "  };\n"
        "}\n"
        "\n"
        "export const CREATOR: Creator = " + json.dumps(value, indent=2, ensure_ascii=False) + ";\n"
    )


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    width, height, _depth, color_type = struct.unpack(">IIBB", data[16:26])
    return width, height, color_type


def render_backend(c, persona, written, notes):
    namespace = c["backend"]["namespace"]

    def render(text):
        return text.replace(ENGINE_NAMESPACE, namespace)

    # Everything under these two folders is generated; start clean so a file
    # that no longer has a source disappears.
    for folder in ("migrations", "functions"):
        shutil.rmtree(path("supabase", folder), ignore_errors=True)

    config = render(read("backend", "config.toml"))
    config = config.replace("__URL_SCHEME__", c["app"]["urlScheme"]).replace("__BUNDLE_ID__", c["app"]["bundleId"])
    leftovers = sorted(set(re.findall(r"__[A-Z_]+__", config)))
    if leftovers:
        raise ConfigError(f"backend/config.toml has placeholders ./configure doesn't know: {leftovers}")
    write("supabase/config.toml", config, written)

    versions = {}
    for name in sorted(os.listdir(path("backend", "migrations"))):
        if name.endswith(".sql"):
            versions[name.split("_")[0]] = name
            write(f"supabase/migrations/{render(name)}", render(read("backend", "migrations", name)), written)
    own = path("creator", "migrations")
    if os.path.isdir(own):
        for name in sorted(os.listdir(own)):
            if not name.endswith(".sql"):
                continue
            version = name.split("_")[0]
            if not re.fullmatch(r"\d{14}", version):
                raise ConfigError(f"creator/migrations/{name}: the name has to start with a 14-digit timestamp.")
            if version in versions:
                raise ConfigError(f"creator/migrations/{name} has the same timestamp as {versions[version]}.")
            versions[version] = name
            # Copied as written: these belong to one backend and already use its names.
            write(f"supabase/migrations/{name}", read("creator", "migrations", name), written)

    for name in ("index.ts", "prompt.ts"):
        write(f"supabase/functions/{namespace}-agent/{name}", render(read("backend", "functions", "agent", name)), written)
    write(f"supabase/functions/{namespace}-agent/creator.ts", creator_ts(c, persona), written)
    write(f"supabase/functions/{namespace}-delete-account/index.ts",
          render(read("backend", "functions", "delete-account", "index.ts")), written)
    write(f"supabase/functions/{namespace}-privacy/index.ts", policy.function_source(c), written)

    if not persona["facts"]:
        notes.append("creator/persona.md has nothing under \"# Who you are\", so the agent knows no facts about "
                     f"{c['creator']['name']} beyond the feed.")


def render_app(c, written, notes):
    write("Generated/Creator.swift", creator_swift(c), written)
    write("Generated/PrivacyPolicy.swift", policy.swift_source(c), written)
    write("Generated/App.xcconfig", xcconfig(c), written)
    write("Generated/ExportOptions-upload.plist", export_options(c, "upload"), written)
    write("Generated/ExportOptions-export.plist", export_options(c, "export"), written)
    # The resolved settings, for the tools (tests, dashboard). No secrets in here.
    resolved = json.loads(json.dumps(c))
    resolved["creator"].pop("pronounSet")
    write("Generated/creator.json", json.dumps(resolved, indent=2, ensure_ascii=False) + "\n", written)

    icon = path("creator", "icon.png")
    if not os.path.exists(icon):
        icon = path("creator.example", "icon.png")
    with open(icon, "rb") as f:
        data = f.read()
    size = png_size(data)
    if size is None:
        raise ConfigError(f"{os.path.relpath(icon, ROOT)} isn't a PNG file.")
    if size[:2] != (1024, 1024):
        raise ConfigError(f"{os.path.relpath(icon, ROOT)} is {size[0]}x{size[1]}; the app icon has to be 1024x1024.")
    if size[2] in (4, 6):
        notes.append(f"{os.path.relpath(icon, ROOT)} has transparency. The App Store rejects icons with an alpha "
                     "channel, so export it without one before you submit.")
    write("App/Assets.xcassets/AppIcon.appiconset/AppIcon.png", data, written)


def main():
    parser = argparse.ArgumentParser(description="Build this copy of the app from creator/.")
    parser.add_argument("--check", action="store_true", help="validate creator/ and stop")
    parser.add_argument("--no-xcodegen", action="store_true", help="don't regenerate the Xcode project")
    args = parser.parse_args()

    created = False
    if not os.path.isdir(path("creator")):
        if args.check:
            print("There is no creator/ folder yet. Run ./configure once to create it.")
            return 1
        shutil.copytree(path("creator.example"), path("creator"))
        created = True

    try:
        config = load_config()
        persona = load_persona()
        if args.check:
            print(f"creator/ is fine: {config['app']['name']} ({config['app']['bundleId']}), "
                  f"{config['agent']['name']} for {config['creator']['name']}.")
            return 0
        written, notes = [], []
        render_app(config, written, notes)
        render_backend(config, persona, written, notes)
    except ConfigError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except FileNotFoundError as error:
        print(f"error: {os.path.relpath(error.filename, ROOT)} is missing.", file=sys.stderr)
        return 1

    print(f"{config['app']['name']}: {config['agent']['name']} for {config['creator']['name']}, "
          f"bundle {config['app']['bundleId']}, version {config['app']['version']} ({config['app']['build']}).")
    print(f"Wrote {len(written)} files to Generated/, supabase/ and the app icon.")
    if not config["backend"]["url"] or not config["backend"]["publishableKey"]:
        notes.append("No backend yet: the app will build and open, but nobody can sign in until "
                     "creator/app.json has backend.projectRef and backend.publishableKey.")
    if not config["analytics"]["enabled"]:
        notes.append("Analytics is off (no analytics.posthogToken), so nothing is recorded.")
    for note in notes:
        print(f"note: {note}")

    if not args.no_xcodegen:
        if shutil.which("xcodegen"):
            result = subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT)
            if result.returncode != 0:
                return result.returncode
            print("Regenerated CreatorApp.xcodeproj.")
        else:
            print("note: xcodegen isn't installed (brew install xcodegen), so the Xcode project wasn't regenerated.")

    if created:
        print("\nThis was the first run, so creator/ now holds a copy of the example.\n"
              "Put your own names in creator/app.json and creator/persona.md, then run ./configure again.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
