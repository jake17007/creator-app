"""The privacy policy, as one text that ./configure writes into both places it
is shown: the in-app screen (You > Privacy Policy) and the public page served
by the <namespace>-privacy function.

It is a standard-form policy, filled in from creator/app.json. It only
mentions analytics and session replay when analytics is switched on (a PostHog
token is set), because the policy has to match what the app really collects.
It is a starting point, not legal advice: have it reviewed before you rely on it.

Edit the wording here, then run ./configure and redeploy the privacy function.
"""
import textwrap


def build(c):
    """Returns (intro, [(title, [paragraph, ...]), ...]) for a resolved config."""
    app = c["app"]["name"]
    name = c["creator"]["name"]
    agent = c["agent"]["name"]
    entity = c["legal"]["entity"]
    email = c["legal"]["contactEmail"]
    they = c["creator"]["pronounSet"]["subject"]
    analytics = c["analytics"]["enabled"]

    intro = (
        f"This Privacy Policy describes how {entity} (“we,” “us,” or “our”) collects, uses, "
        f"and discloses information in connection with the {app} mobile application (the “App”). "
        "By using the App, you acknowledge the practices described in this Privacy Policy."
    )

    if analytics:
        automatic = (
            "Information collected automatically. When you use the App, we and our service providers "
            "automatically collect certain information, including device and application information "
            "(such as device type, operating system version, and App version), identifiers associated "
            "with your account, your IP address and general location inferred from it, and usage "
            "information about your interactions with the App (such as the screens you view, the "
            "features you use, your taps, gestures, and navigation, and the dates and times of your "
            "activity). We and our analytics providers use software development kits and similar "
            "technologies, including session replay technologies, to collect this information. Text "
            "entry fields and the content you submit are masked in session replay data."
        )
        providers = (
            "including providers of hosting and database services, analytics "
            "and session replay services, and artificial intelligence model services."
        )
        usage_retention = (
            " Usage and session replay data are retained for a "
            "limited period in accordance with our analytics provider's retention settings."
        )
    else:
        automatic = (
            "Information collected automatically. When you use the App, our service providers "
            "automatically collect certain technical information needed to operate it, including "
            "your IP address, device and application information (such as device type, operating "
            "system version, and App version), and the dates and times of your requests."
        )
        providers = (
            "including providers of hosting and database services "
            "and artificial intelligence model services."
        )
        usage_retention = ""

    sections = [
        ("1. Information We Collect", [
            "Information you provide. We collect the information you provide when you create an account "
            "or use the App, including your email address or Sign in with Apple identifier, the name you "
            f"choose, your account credentials, the goals you enter, the messages you exchange with {agent} "
            f"(the App's artificial intelligence feature) and with {name}, and any information you send us "
            "when you contact support.",
            automatic,
            "We do not collect precise location, contacts, photos, or advertising identifiers, and we do "
            "not track you across apps or websites owned by other companies.",
        ]),
        ("2. How We Use Information", [
            "We use the information we collect to provide, maintain, and secure the App; to create and "
            f"manage your account; to generate {agent}'s responses and deliver your messages; to understand "
            "how the App is used, diagnose problems, and improve the App; to communicate with you; and to "
            "comply with legal obligations.",
            f"Your goals and direct messages are accessible to {name} so that {they} can respond to you. Your "
            f"conversations with {agent} are stored and may be reviewed to operate, troubleshoot, and "
            f"improve the App. {agent}'s responses are generated automatically, may be inaccurate, and are "
            "not professional advice. Other members cannot see your information.",
        ]),
        ("3. How We Share Information", [
            "We do not sell your personal information. We disclose information to service providers that "
            f"process it on our behalf, {providers} To generate "
            f"{agent}'s responses, your messages to {agent}, together with your name, goals, and recent "
            "conversation, are processed by third-party artificial intelligence model providers. We do "
            "not use this information to train those models.",
            "We may also disclose information where required by law, to protect the rights, property, or "
            "safety of any person, or in connection with a merger, acquisition, or other business "
            "transfer.",
        ]),
        ("4. Data Retention", [
            "We retain your information for as long as your account is active and as needed for the "
            f"purposes described in this Privacy Policy.{usage_retention} When you "
            f"delete your account, we delete your account information, goals, {agent} conversation, and "
            "direct messages, except where retention is required by law.",
        ]),
        ("5. Your Choices and Rights", [
            "You may update your name and delete your account at any time in the App (You > Delete "
            "account). Depending on where you live, you may have the right to access, correct, or delete "
            "your personal information, or to restrict or object to its processing. To exercise these "
            "rights, contact us using the details below.",
        ]),
        ("6. Security and International Transfers", [
            "We use reasonable technical and organizational measures to protect the information we "
            "collect. No method of transmission or storage is completely secure. Your information may be "
            "processed in the United States and other countries where our service providers operate.",
        ]),
        ("7. Children", [
            "The App is not directed to children under 13, and we do not knowingly collect personal "
            "information from them.",
        ]),
        ("8. Changes to This Privacy Policy", [
            "We may update this Privacy Policy from time to time. We will post the updated version in the "
            "App and revise the “Last updated” date above.",
        ]),
        ("9. Contact Us", [
            f"If you have questions or requests regarding this Privacy Policy, contact us at {email}.",
        ]),
    ]
    return intro, sections


def _wrap(text):
    return "\n".join(textwrap.wrap(text, 78))


def plain_text(c):
    intro, sections = build(c)
    out = [f"{c['app']['name'].upper()}: PRIVACY POLICY", f"Last updated: {c['legal']['policyUpdated']}", "", _wrap(intro), ""]
    for title, paragraphs in sections:
        out += ["", title.upper(), ""]
        for paragraph in paragraphs:
            out += [_wrap(paragraph), ""]
    return "\n".join(out).rstrip() + "\n"


def function_source(c):
    """The edge function that serves the public copy."""
    text = plain_text(c)
    if "`" in text or "${" in text or "\\" in text:
        raise ValueError("the policy text can't contain a backtick, a backslash or ${")
    return f"""// Public privacy policy for the app.
// Deployed with verify_jwt = false so it is reachable without signing in:
//   https://<project>.supabase.co/functions/v1/{c['backend']['namespace']}-privacy
//
// Written by ./configure together with the in-app copy
// (Generated/PrivacyPolicy.swift), so the two always say the same thing: edit
// tools/policy.py, not this file. Supabase serves text/html from edge
// functions as text/plain on its default domain, hence plain text.
const TEXT = `{text}`;

Deno.serve(() =>
  new Response(TEXT, {{ headers: {{ "Content-Type": "text/plain; charset=utf-8" }} }})
);
"""


def swift_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def swift_source(c):
    """The in-app copy (You > Privacy Policy)."""
    intro, sections = build(c)
    rows = "\n".join(
        "        Section(title: %s, body: %s)," % (swift_string(title), swift_string("\n\n".join(paragraphs)))
        for title, paragraphs in sections
    )
    return f"""// The privacy policy shown in You > Privacy Policy.
//
// Written by ./configure together with the public copy served by the privacy
// function, so the two always say the same thing: edit tools/policy.py, not
// this file.

enum PrivacyPolicy {{
    struct Section {{
        let title: String
        let body: String
    }}

    static let lastUpdated = {swift_string(c['legal']['policyUpdated'])}

    static let introduction = {swift_string(intro)}

    static let sections: [Section] = [
{rows}
    ]
}}
"""
