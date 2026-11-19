# Claude Pulse

A floating macOS panel that shows what your Claude Desktop sessions are doing, so you stop missing the moment one finishes or asks you something.

It lists your Claude Code sessions, Duet tasks, artifacts, recent chats and open pull requests in one always-on-top window, and turns a row green when Claude is done or orange when it is waiting on your answer.

> **Unofficial.** Claude Pulse is not made or supported by Anthropic. It works by reading files and screens that Claude Desktop does not document, so a Claude update can break parts of it without warning. See [What can break](#what-can-break).

## What it shows

| Section           | What you get                                                                                                                               | Where it comes from                                                                   | How fresh                          |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- | ---------------------------------- |
| **Code**          | Each Claude Code session: working, done, or waiting on your answer; project folder; model; how full its context is; git branch and changes | Claude's local session files and transcripts; `git`                                   | Live (every 2 seconds)             |
| **Pull requests** | Open PRs you wrote or are asked to review, with checks and review status                                                                   | The GitHub CLI (`gh`)                                                                 | Every 3 minutes                    |
| **Duet tasks**    | Duet's channels and groups, each with its Active tasks; "Needs input" in orange                                                            | Read off Duet's screen through Accessibility                                          | Only while Duet is open in the app |
| **Artifacts**     | Artifacts you edited recently, ones newly shared with you, and comment threads that tag you                                                | A snapshot file written by a scheduled Claude session                                 | As often as that session runs      |
| **Chats**         | Your recent chats, with hide and "load more"                                                                                               | Read off Claude's sidebar through Accessibility                                       | Only while the Claude tab is open  |
| **Your usage**    | 14-day sessions, prompts and tokens by project, plus skills worth creating                                                                 | `tools/usage_stats.py` for the counts; a scheduled Claude session for the suggestions | As often as that session runs      |

### Session states

- **Blue, pulsing: working.** Nothing for you to do.
- **Green bar: "Done. Get back to me".** The turn finished while you were not looking. It clears when you open the session or dismiss it.
- **Orange bar: waiting on your answer.** Claude stopped on a question or approval, ended its turn by asking you something, or the turn failed. It stays until you answer or dismiss it, even for the session you are looking at.

### Other features

- **Click to open.** Clicking a session, chat or Duet task opens it in Claude Desktop. Artifacts and pull requests open in your browser.
- **Notifications** when a session finishes or needs an answer, when someone tags you on an artifact, when an artifact is shared with you, when a Duet task starts needing input, and when a chat you asked something and left has its answer. A one-time reminder follows if a session is still waiting after 15 minutes (configurable).
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

This builds a release binary, wraps it as a menu-bar app with no Dock icon, signs it, installs it to `~/Applications/ClaudePulse.app`, and launches it from there. Run the same command again after changing the code.

### Start automatically

```bash
tools/install-autostart.sh
```

This installs a per-user launchd agent that opens Claude Pulse at login and whenever Claude Desktop is opened. Quitting Claude Pulse from its menu keeps it closed until Claude Desktop is next opened. Remove it with `tools/install-autostart.sh --uninstall`. It needs no administrator rights and installs nothing outside your home folder.

### Signing matters

macOS ties privacy permissions to an app's code signature. `build.sh` signs with the first "Apple Development" identity in your keychain if there is one, and falls back to an ad-hoc signature otherwise. With an ad-hoc signature the permissions below are lost on every rebuild. To pick a specific identity:

```bash
CODESIGN_IDENTITY="<identity hash or name>" ./build.sh --run
```

## Permissions

Claude Pulse asks for two, and works in a reduced way without either.

- **Notifications.** Without this you get no banners. The panel shows an orange warning when notifications are switched on in the widget but blocked by macOS.
- **Accessibility** (System Settings → Privacy & Security → Accessibility). Needed for chats and Duet tasks, for opening a specific chat or Duet task, and for one of the signals that a session is waiting. Code sessions, pull requests, artifacts and usage work without it. Screen watching, if you switch it on, uses the same permission; it needs no Screen Recording access because it takes no screenshots.

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

## Screen watching (optional, off by default)

Skill suggestions normally come only from what you ask Claude Code. Repeated work done elsewhere, in a spreadsheet, a CRM or a browser, is invisible to that. Settings → Screen activity → **Watch my screen to suggest skills** fills the gap.

While it is on, every 10 seconds Claude Pulse records:

- the app in front and its window title;
- the text visible in that window: labels, headings, links, button names and static text, up to about 2,000 characters.

It deliberately leaves out:

- **anything you type.** Text fields and text areas contribute their label only. That also means the body of a document you are editing is not recorded;
- **any window with a password field**, which is recorded by title only;
- **apps on the "Never watch these apps" list** (password managers, System Settings and Messages to start with; add your own from the apps recently in front);
- **private and incognito browser windows**, recognised by their title;
- **the lock screen and screen saver**, and Claude Pulse itself.

E-mail addresses, long numbers and things that look like keys or tokens are replaced with `[email]`, `[number]` and `[token]` before anything is written. This is pattern matching and will miss things: the log can still hold anything that was readable on screen. Use the "Never watch these apps" list and the pause switch for anything sensitive.

While watching, the menu-bar item shows an eye, and its right-click menu has **Stop watching my screen for now**. A pause lasts until you resume or relaunch.

Entries are written to `~/Library/Application Support/ClaudePulse/activity/YYYY-MM-DD.jsonl`, readable only by your user account. Files older than the "Keep what's recorded for" setting (7 days by default) are deleted automatically, and **Delete everything recorded so far** removes all of them at once.

Claude Pulse itself still never calls a model. To turn the log into suggestions, add this to the daily scheduled task that already writes `insights.json`:

```bash
python3 tools/activity_stats.py --days 7
```

It prints the time spent per app, the window titles you keep returning to, the app-to-app sequences you repeat, and short text samples from the most repeated windows. Ask the session to look for repeated manual workflows in that output and add them to `skillIdeas` with `"source": "screen"`, so the panel can mark them as coming from screen activity. That step does send the summary to Claude, like the prompt sample from `usage_stats.py`.

Some apps expose little to Accessibility. Chrome and most Electron apps often give only a window title unless an assistive tool is running. To see what a given app yields, without recording anything:

```bash
open -n ~/Applications/ClaudePulse.app --args --observe-probe /tmp/observe.txt 30
```

## Privacy

- Everything Claude Pulse reads stays on your Mac. It makes no network requests of its own; the only outside calls are the ones `gh` makes to GitHub.
- It never stores a credential. For GitHub it asks `gh` for each account's token and hands it straight back to `gh` for that account's queries, in memory only.
- It does read your session titles, transcripts (for token counts and the question Claude last asked), chat titles, Duet task titles and artifact titles, and shows them on screen. Chat and Duet titles are cached in the app's preferences so they survive a restart.
- Screen watching is off unless you switch it on. When on, it keeps a local log of the front app, window titles and visible text, as described under [Screen watching](#screen-watching-optional-off-by-default). The app does not send that log anywhere; the scheduled Claude session you point at `tools/activity_stats.py` reads a summary of it.

## What can break

Claude Pulse depends on things Anthropic does not document and may change:

- **Session files** in `~/.claude/sessions/` and `~/Library/Application Support/Claude/claude-code-sessions/`, and the fields inside them.
- **Transcript format** in `~/.claude/projects/`, including the name of the tool Claude uses to close a turn.
- **The `claude://` link** used to open a session (`claude://code/continue?session=…`).
- **The layout and labels of Claude Desktop's sidebar and Duet's Tasks pane**, which chats and Duet are read from. A redesign or a renamed label will stop those sections updating.

The readers are written to degrade rather than crash: a missing field leaves a row with less detail, and a section whose source has changed stops updating or disappears.

Known limits:

- **Chats and Duet are only read while they are on screen** in Claude Desktop. Otherwise the widget shows the last list it saw, marked with its age. A Duet task that changes while Duet is closed is not noticed until Duet is opened again.
- **Duet questions and approvals that are not tasks.** When Claude asks something in a channel, or wants approval to use a tool, Duet shows a banner in the Tasks pane ("Claude needs your answer in #name") instead of a task. The widget lists that as needing input in its channel. It is read like everything else in Duet: while that channel is on screen, or on a look-in if "Everything" repeats the banner.
- **The model-switch guess under the usage bar** appears when the limit shown names a model ("Weekly · Fable"). It is the share of that model's weighted tokens in this week's Code sessions that went to quick turns (a short reply, at most two edits, no subagents), applied to the percentage shown. Chats and Duet leave no local record and are not counted, so the figure can be well off if most of that model's use is there.
- **Clearing a Duet alert.** A task that is ready for review stops asking for you once its channel or group has been on screen in Duet with Claude in front and you at the keyboard. One that needs input stays under Needs You until it is answered. Duet itself keeps the task at that status until you resolve it, so Pulse goes by you having seen it; the alert returns if the task's status changes. A background look-in never counts as you seeing it.
- **Looking in on Duet.** To cover that gap, the widget sends Claude's window to Duet for a few seconds, reads the task list, and puts the window back where it was (a Code session or the Claude tab). It looks once about a minute after you leave Duet with a task running or waiting on you, then every 2 minutes while a task is running (Settings → Duet; 1, 2 or 5 minutes, or off). It waits for a 10-second pause if you are using Claude. A task that starts on its own while Duet is off screen, such as a scheduled one, is not known to be running, so it does not trigger a look. `~/Library/Application Support/ClaudePulse/duet-lookin.log` records when it looked and why it held off.
- **Duet's Tasks pane follows the conversation that is open.** "Everything" lists every task; a channel or group lists only its own. A task is filed under a channel or group once it has been seen there, so one created in a channel while you were on Everything shows in the main list until you open that channel.
- **With a Duet task's detail open, or the Tasks pane hidden, there is no list to read.** The widget then takes each task's status from the cards in the conversation and from the open task's header, so a task that starts needing input is still noticed. Tasks it cannot see there keep their last known status.
- **Chat answers you walked away from.** A chat can only be read while it is on screen, and its row in the sidebar says nothing about whether Claude is still answering. So the widget watches the chat that is open: if Claude finishes while you are in another app, you are told then. If you move Claude's window to another chat, a Code session or Duet mid-answer, the end cannot be seen, so two minutes later you are told the answer should be in. While that wait runs the chat shows at the top of Chats as "answering". Once the answer is in, the chat sits under Needs You as "answer waiting" until you open or clear it, with one reminder on the same timer as sessions. `~/Library/Application Support/ClaudePulse/chat-answers.log` records each step. A chat you asked and left before the widget's next reading (every 5 seconds) is missed. Beyond that, chats have no working or waiting state and no token counts.
- **Context percentages are inferred.** Claude does not record a model's context window size anywhere readable, so the widget assumes 1M tokens once it has seen a model go past 200k, and 200k otherwise.
- **The usage limit in the footer is read from Claude Desktop's usage ring.** It shows whichever limit the ring is showing (5-hour or weekly) and updates only while a page with that ring is open; otherwise it is the last reading, shown with its age.
- **Opening a chat or a Duet task presses buttons in Claude Desktop** on your behalf, so the Claude window visibly switches tabs.

## Project layout

```
Sources/ClaudePulse/
  main.swift           app delegate, menu-bar item, notifications
  Panel.swift          the floating window: sizing, position, minimize
  Views.swift          all SwiftUI views and the colour palette
  SessionStore.swift   Code sessions: reads Claude's files, decides each state
  TokenTally.swift     token use and the closing question, from transcripts
  ModelFit.swift       share of each model's Code use that went to quick turns
  ChatReader.swift     chats, Duet tasks and sidebar status, through Accessibility
  ArtifactStore.swift  reads artifacts.json
  InsightsStore.swift  reads insights.json
  GitHubReader.swift   pull requests through gh
  Git.swift            branch and working-tree status
  Settings.swift       preferences
  AXProbe.swift        diagnostics for mapping Claude's screens
  AXHelpers.swift      shared Accessibility wrappers
  ActivityObserver.swift  optional screen watching: front app, title and visible text
tools/usage_stats.py   exact usage counts from local transcripts
tools/activity_stats.py  summary of the screen-watching log
tools/install-autostart.sh  start at login and with Claude Desktop
tools/make_icon.swift  regenerate the app icon
build.sh               build, bundle, sign, launch
```

### Diagnostics

The app has a few command-line modes for checking what it sees. Modes that read Claude's screen must be started through `open` so macOS applies the app's own Accessibility permission:

```bash
# Render the panel to a PNG without showing it
~/Applications/ClaudePulse.app/Contents/MacOS/ClaudePulse --snapshot out.png

# Record every page Claude's window shows for 60 seconds
open -n ~/Applications/ClaudePulse.app --args --ax-follow /tmp/pages.txt 60
```
