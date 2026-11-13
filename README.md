# Creator app (iPhone)

An iPhone app a creator runs for the people who follow them. Members get:

- **A feed** of the creator's posts, before they go anywhere else.
- **An AI version of the creator** that knows the member's goals and everything in the feed.
- **A 1:1 chat** with the real creator.

It is one codebase that becomes *your* app when you put your name in one file.
SwiftUI, iOS 17+, with [Supabase](https://supabase.com) for accounts, data and
storage, and [OpenRouter](https://openrouter.ai) for the AI.

| Tab | Members | The creator's account |
|---|---|---|
| Feed | Your posts: text, links, a photo or a swipeable carousel (up to 10), video. `EARLY` marks what isn't public elsewhere yet. "Ask" on any post opens the AI about it. | Same, plus write, edit and delete posts. |
| AI (named after you, e.g. `sam.0`) | Chat with the AI version of you. It sees their name, their goals and the feed. | Same. |
| Your name / Inbox | Their one thread with the real you. | An inbox of every member's thread, each with that member's goals. |
| Goals | What they are working toward (title, context, target date). | Same (your own). |
| You | Name, privacy policy, sign out, delete account. | Plus **Teach**: notes that become part of what the AI knows about you. |

## Make your own

You need a Mac with a recent Xcode (this was built with Xcode 27.2), and:

```bash
brew install xcodegen supabase/tap/supabase
```

The setup itself only needs the Python that comes with Xcode. The test tools
under `tools/` that end in `.mjs` need Node 22.6 or newer.

### 1. Put your name on it

```bash
./configure
```

The first run creates a `creator/` folder from `creator.example/`. That folder
is your copy of the app, and it is the only thing you edit:

| File | What goes in it |
|---|---|
| `creator/app.json` | The app's name, your name, the AI's name, your bundle id, your contact email. See [the settings](#creatorappjson). |
| `creator/persona.md` | Who you are and how you talk, for the AI. The example explains each part. |
| `creator/icon.png` | Your app icon, 1024×1024, no transparency. |

Then run `./configure` again and open `CreatorApp.xcodeproj`. The app runs in
the simulator under your name straight away. Nobody can sign in until it has a
backend, which is the next step.

`creator/` is gitignored, so your details never end up in a fork by accident.

### 2. Give it a backend

1. Create a project at supabase.com (the free plan is enough to start).
2. From the project's settings, copy its **reference id** into
   `backend.projectRef` and its **publishable key** into
   `backend.publishableKey` in `creator/app.json`. Use the publishable (anon)
   key, never a secret key: this one ships inside the app.
3. Get an API key from openrouter.ai for the AI.
4. Run:

```bash
supabase login
./tools/backend-setup.sh
```

The script creates the database, storage and sign-in settings, deploys three
small functions, stores your OpenRouter key on the project, and makes your
one-time **creator code** (saved in `.local/creator-code.txt`). It asks before
it changes anything. Use a project made for this app.

Then run the app, create an account, open **You**, tap the version number five
times and enter the creator code. That account is now the creator: it can post
to the feed, sees the inbox, and can teach the AI.

Check the whole backend any time with `node tools/e2e-backend.mjs` (it creates
two throwaway accounts, tries everything a member can and can't do, and deletes
them again).

### 3. Put it on your phone

Add your Apple team id to `apple.teamId`, create the app's record in App Store
Connect with your bundle id, and:

```bash
./tools/testflight.sh
```

That bumps the build number, archives, and uploads to TestFlight with the
account Xcode is signed in to.

## creator/app.json

| Setting | What it is |
|---|---|
| `app.name` | The app's name: under the icon and on the sign-in screen. |
| `app.bundleId` | Your bundle id, like `com.yourname.yourapp`. |
| `app.urlScheme` | Opens the app from sign-in links. Lowercase letters and digits. |
| `app.version`, `app.build` | Version and build number. `tools/testflight.sh` bumps the build. |
| `creator.name` | You, as members see you: "Message Sam", the Sam tab. |
| `creator.fullName`, `creator.handle` | Optional. How the AI introduces who it is a version of. |
| `creator.pronouns` | `he`, `she` or `they`. Used in the AI's instructions and the privacy policy. |
| `agent.name` | The AI's name, like `sam.0`. |
| `legal.entity` | The person or company the privacy policy is from. |
| `legal.contactEmail` | Shown in the privacy policy and used by "Contact support". |
| `legal.policyUpdated` | The privacy policy's "Last updated" date. |
| `apple.teamId` | Your Apple developer team. Only needed for a real device or TestFlight. |
| `backend.namespace` | Names the database schema, the storage bucket and the functions, so the app can share a Supabase project safely. Pick it once: it can't be renamed after the database exists. |
| `backend.projectRef`, `backend.publishableKey` | Your Supabase project. |
| `backend.secrets` | Optional. Renames the function secrets listed under [Cost](#cost-and-the-knobs), for a shared project. |
| `analytics.posthogToken` | Optional. Leave empty and nothing is tracked. See [Analytics](#analytics-and-screen-recordings-optional). |

Run `./configure` after every change. It checks the file and tells you what is
wrong in plain words.

## The AI

Each reply is built from: the persona (`creator/persona.md`), your **Teach**
notes, the latest 30 feed posts (plus each post's private "notes for the AI",
such as a video's transcript), the member's name and goals, and their last 24
messages. It answers as you, in the first person, but it says it is an AI when
asked, never invents facts about you, and sends anything that needs the real
you to your tab.

The rules every creator's AI follows are in `backend/functions/agent/prompt.ts`.
What makes it *you* is `creator/persona.md`. To try a change without touching
the database:

```bash
./configure
node --experimental-strip-types tools/try-agent.mjs            # a few test conversations
node --experimental-strip-types tools/try-agent.mjs --prompt   # just print what the AI is told
```

### Cost and the knobs

Replies go through OpenRouter and you pay per reply. Measured on this app in
November 2026: about **$0.0001 to $0.0007 a reply** on the default model
(`anthropic/claude-haiku-5.5`) and **$0.003 to $0.008** on
`anthropic/claude-sonnet-5.5`. Prices change, so check OpenRouter.

Two caps keep a bad day from becoming a bill. They are function secrets
(`supabase secrets set NAME=value`), all optional:

| Secret | Default | What it does |
|---|---|---|
| `AGENT_MODEL` | `anthropic/claude-haiku-5.5` | The OpenRouter model. |
| `AGENT_DAILY_CAP` | `60` | Replies per member per day. |
| `AGENT_GLOBAL_DAILY_CAP` | `2000` | Replies across everyone per day. This is the spend ceiling. |
| `AGENT_MAX_TOKENS` | `1500` | Longest a reply can be. |
| `AGENT_EFFORT` | `low` | Reasoning effort. |
| `AGENT_OPENROUTER_API_KEY` | falls back to `OPENROUTER_API_KEY` | The key. Give the app its own, with a spend limit set at OpenRouter. |

Every reply carries an `X-Agent-Model` header, and `tools/e2e-backend.mjs`
prints it, so you can always see which model is live. Daily usage per member is
in the `agent_usage` table.

## Analytics and screen recordings (optional)

Off by default. Put a [PostHog](https://posthog.com) project token in
`analytics.posthogToken` and the app sends:

- **Usage events**: which screens get opened and that something happened
  (a message was sent, a goal was added). Never the text. People are identified
  by account id and display name, not email.
- **Screen recordings** of every session, from launch. Anything a member wrote
  or typed is blacked out in them (sign-up fields, chats, goals, name, email).
  Mark new views that show member content with `.privateContent()`.

Know what you are turning on. The app shows **no prompt and has no off
switch**; the privacy policy is where people are told, and `./configure` adds
that disclosure whenever a token is set. Apple's review guideline 2.5.14 asks
for consent before recording what people do, so review may ask for a prompt,
and privacy law where your members live may ask for more. The App Store privacy
labels also need "Product Interaction" and "Coarse Location" under Analytics.
PostHog gives 2,500 mobile recordings a month free and charged $0.01 for each
one after that when this was written (November 2026); set a billing limit there
to cap it.

`dashboard/` is a small local page that plays those recordings as they come in,
with a list of what each person did:

```bash
POSTHOG_PERSONAL_API_KEY=phx_... python3 dashboard/server.py   # http://localhost:8792
```

It needs `analytics.posthogProjectId` in `creator/app.json` and a PostHog
personal API key that can read recordings and run queries. The key stays in the
server; the page only talks to localhost.

## Privacy policy

`./configure` writes one standard-form policy, filled in with your names, into
both places it is shown: the in-app screen (You > Privacy Policy) and a public
page at `https://<project>.supabase.co/functions/v1/<namespace>-privacy`, which
is the link to give the App Store. The wording is in `tools/policy.py`. It is a
starting point and has not been reviewed by a lawyer.

## How it is put together

```
creator.example/   the example copy; ./configure copies it to creator/
creator/           YOUR copy: names, persona, icon, your own database changes (gitignored)
App/               the iPhone app (SwiftUI)
backend/           the database, the three functions and the Supabase settings
tools/             configure, backend setup, TestFlight upload, tests
dashboard/         the live session-recordings page
project.yml        the Xcode project, generated with xcodegen

Generated/         written by ./configure: Swift constants, privacy policy, build settings
supabase/          written by ./configure: backend/ with your namespace, for the Supabase CLI
```

Nothing under `App/`, `backend/` or `tools/` names a particular creator. If you
find yourself editing them to change a name, that is a bug: it belongs in
`creator/app.json`.

The backend keeps everything it owns under one namespace: a Postgres schema
(tables, row-level security, a few functions), a private storage bucket
(`<namespace>-media`: members read, the creator writes), three edge functions
(`<namespace>-agent`, `-delete-account`, `-privacy`) and one trigger on
`auth.users` that creates a member's profile.

Changes that belong to your backend only (a first batch of posts, an extra
creator code) go in `creator/migrations/` as SQL files named with a 14-digit
timestamp. `./configure` adds them to the ones in `backend/migrations/`.

### After pulling an update

```bash
./configure
supabase db push --include-all                       # new database changes, if any
supabase functions deploy <namespace>-agent --use-api   # and the other two, if they changed
```

### Tests

```bash
node --experimental-strip-types tools/test-agent-offline.mjs   # the AI function, with a fake database and model: free, offline
node tools/e2e-backend.mjs                                     # the real backend, end to end: a few cents of AI replies at most
```

A debug build can be pointed at another backend, such as a local `supabase start`:

```bash
SIMCTL_CHILD_BACKEND_URL=http://127.0.0.1:54321 SIMCTL_CHILD_BACKEND_KEY=<anon key> \
  xcrun simctl launch booted <your bundle id>
```

## Not built yet

- Push notifications (new post, new message). Until then the Inbox tab's badge
  is how the creator sees new messages.
- Password reset by email (needs a mail provider on the Supabase project).
- Revoking the Sign in with Apple token when an account is deleted.
- The public privacy policy is plain text; a page on your own site would look
  better in the App Store listing.

## License

MIT. See [LICENSE](LICENSE): copy it, change it, ship your own.
