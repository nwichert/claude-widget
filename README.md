# Claude Pulse

A floating macOS panel that shows what your Claude Desktop sessions are doing, so you stop missing the moment one finishes or asks you something.

It lists your Claude Code sessions, Duet tasks, artifacts, recent chats and open pull requests in one always-on-top window, and turns a row green when Claude is done or orange when it is waiting on your answer.

> **Unofficial.** Claude Pulse is not made or supported by Anthropic. It works by reading files and screens that Claude Desktop does not document, so a Claude update can break parts of it without warning. See [What can break](#what-can-break).

## What it shows

| Section           | What you get                                                                                                                               | Where it comes from                                                                   | How fresh                          |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- | ---------------------------------- |
| **Code**          | Each Claude Code session: working, done, or waiting on your answer; project folder; model; how full its context is; git branch and changes | Claude's local session files and transcripts; `git`                                   | Live (every 2 seconds)             |
| **Pull requests** | Open PRs you wrote or are asked to review, with checks and review status                                                                   | The GitHub CLI (`gh`)                                                                 | Every 3 minutes                    |
| **Duet tasks**    | Tasks from Claude Duet's Active tab, with "Needs input" in orange                                                                          | Read off Duet's screen through Accessibility                                          | Only while Duet is open in the app |
| **Artifacts**     | Artifacts you edited recently, ones newly shared with you, and comment threads that tag you                                                | A snapshot file written by a scheduled Claude session                                 | As often as that session runs      |
| **Chats**         | Your recent chats, with hide and "load more"                                                                                               | Read off Claude's sidebar through Accessibility                                       | Only while the Claude tab is open  |
| **Your usage**    | 14-day sessions, prompts and tokens by project, plus skills worth creating                                                                 | `tools/usage_stats.py` for the counts; a scheduled Claude session for the suggestions | As often as that session runs      |

### Session states

- **Blue, pulsing: working.** Nothing for you to do.
- **Green bar: "Done. Get back to me".** The turn finished while you were not looking. It clears when you open the session or dismiss it.
- **Orange bar: waiting on your answer.** Claude stopped on a question or approval, ended its turn by asking you something, or the turn failed. It stays until you answer or dismiss it, even for the session you are looking at.

### Other features

- **Click to open.** Clicking a session, chat or Duet task opens it in Claude Desktop. Artifacts and pull requests open in your browser.
- **Notifications** when a session finishes or needs an answer, when someone tags you on an artifact, when an artifact is shared with you, and when a Duet task starts needing input. A one-time reminder follows if a session is still waiting after 15 minutes (configurable).
- **Minimize** to a one-line ticker that rotates through what needs you and your usage. Expanding restores the size you had.
- **Resizable**, with the size and position remembered.
- **Settings** (the gear icon) to switch each section on or off and set reminder and retention times.
- **Menu-bar icon** with a count of sessions waiting on you. Left-click shows or hides the panel; right-click opens a menu.

## Requirements

- macOS 14 or later, with Claude Desktop installed.
- Xcode command-line tools (for `swift build`).
- Optional: the [GitHub CLI](https://cli.github.com), logged in with `gh auth login`, for the pull request section. Every account `gh` is logged in to is used.

## Build and run

```bash
./build.sh --run
```

This builds a release binary, wraps it as `build/ClaudePulse.app` (a menu-bar app with no Dock icon), signs it, and launches it. Run the same command again after changing the code.

### Signing matters

macOS ties privacy permissions to an app's code signature. `build.sh` signs with the first "Apple Development" identity in your keychain if there is one, and falls back to an ad-hoc signature otherwise. With an ad-hoc signature the permissions below are lost on every rebuild. To pick a specific identity:

```bash
CODESIGN_IDENTITY="<identity hash or name>" ./build.sh --run
```

## Permissions

Claude Pulse asks for two, and works in a reduced way without either.

- **Notifications.** Without this you get no banners. The panel shows an orange warning when notifications are switched on in the widget but blocked by macOS.
- **Accessibility** (System Settings → Privacy & Security → Accessibility). Needed for chats and Duet tasks, for opening a specific chat or Duet task, and for one of the signals that a session is waiting. Code sessions, pull requests, artifacts and usage work without it.

Turning on Accessibility reading also switches on Claude Desktop's accessibility tree, which Electron apps leave off by default. That can make Claude slightly heavier until it is restarted.

## Snapshot files

Artifacts and the usage section cannot be fetched by the widget itself: that data is not on disk, and deciding which requests deserve a skill needs a model. Instead, a Claude session writes JSON files that the widget reads and displays with their age.

| File (in `~/Library/Application Support/ClaudePulse/`) | Contents                                                                                |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| `artifacts.json`                                       | Your artifacts and shared artifacts, with comment-thread counts and tags waiting on you |
| `insights.json`                                        | Usage totals by project, what the work was for, and skill suggestions                   |

The intended setup is two scheduled tasks in Claude Desktop: one that lists artifacts and reads their comments every couple of hours, and one that runs `tools/usage_stats.py` and reviews a sample of your prompts once a day. Each run costs tokens, and scheduled tasks only run while Claude Desktop is open. Without these files the two sections simply do not appear.

`tools/usage_stats.py` can also be run on its own:

```bash
python3 tools/usage_stats.py --days 14
```

It reads `~/.claude/projects/*/*.jsonl` and prints exact counts per project, the tools and skills used, and a sample of prompts. Nothing leaves your machine.

## Privacy

- Everything Claude Pulse reads stays on your Mac. It makes no network requests of its own; the only outside calls are the ones `gh` makes to GitHub.
- It never stores a credential. For GitHub it asks `gh` for each account's token and hands it straight back to `gh` for that account's queries, in memory only.
- It does read your session titles, transcripts (for token counts and the question Claude last asked), chat titles, Duet task titles and artifact titles, and shows them on screen. Chat and Duet titles are cached in the app's preferences so they survive a restart.

## What can break

Claude Pulse depends on things Anthropic does not document and may change:

- **Session files** in `~/.claude/sessions/` and `~/Library/Application Support/Claude/claude-code-sessions/`, and the fields inside them.
- **Transcript format** in `~/.claude/projects/`, including the name of the tool Claude uses to close a turn.
- **The `claude://` link** used to open a session (`claude://code/continue?session=…`).
- **The layout and labels of Claude Desktop's sidebar and Duet's Tasks pane**, which chats and Duet are read from. A redesign or a renamed label will stop those sections updating.

The readers are written to degrade rather than crash: a missing field leaves a row with less detail, and a section whose source has changed stops updating or disappears.

Known limits:

- **Chats and Duet are only read while they are on screen** in Claude Desktop. Otherwise the widget shows the last list it saw, marked with its age. A Duet task that changes while Duet is closed is not noticed until Duet is opened again.
- **Chats have no working or waiting state** and no token counts; only a title and a badge are available.
- **Context percentages are inferred.** Claude does not record a model's context window size anywhere readable, so the widget assumes 1M tokens once it has seen a model go past 200k, and 200k otherwise.
- **Plan usage (the 5h / 7d meters) is not live.** It is the last sample Claude Desktop saved, shown with its age.
- **Opening a chat or a Duet task presses buttons in Claude Desktop** on your behalf, so the Claude window visibly switches tabs.

## Project layout

```
Sources/ClaudePulse/
  main.swift           app delegate, menu-bar item, notifications
  Panel.swift          the floating window: sizing, position, minimize
  Views.swift          all SwiftUI views and the colour palette
  SessionStore.swift   Code sessions: reads Claude's files, decides each state
  TokenTally.swift     token use and the closing question, from transcripts
  ChatReader.swift     chats, Duet tasks and sidebar status, through Accessibility
  ArtifactStore.swift  reads artifacts.json
  InsightsStore.swift  reads insights.json
  GitHubReader.swift   pull requests through gh
  Git.swift            branch and working-tree status
  Settings.swift       preferences
  AXProbe.swift        diagnostics for mapping Claude's screens
tools/usage_stats.py   exact usage counts from local transcripts
build.sh               build, bundle, sign, launch
```

### Diagnostics

The app has a few command-line modes for checking what it sees. Modes that read Claude's screen must be started through `open` so macOS applies the app's own Accessibility permission:

```bash
# Render the panel to a PNG without showing it
build/ClaudePulse.app/Contents/MacOS/ClaudePulse --snapshot out.png

# Record every page Claude's window shows for 60 seconds
open -n build/ClaudePulse.app --args --ax-follow /tmp/pages.txt 60
```
