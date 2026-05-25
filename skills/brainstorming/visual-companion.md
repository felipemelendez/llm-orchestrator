# Visual Brainstorming Companion

Operational reference for the browser-based visual panel. Scripts live in
`skills/brainstorming/scripts/`.

## Starting the server

```bash
bash skills/brainstorming/scripts/start-server.sh --project-dir <workspace-root>
```

The script prints a `server-started` JSON object and also writes it to
`state/server-info` inside the session directory. Capture two paths from that
JSON before doing anything else:

- `screen_dir` — write HTML files here to push content to the browser.
- `state_dir` — read `state_dir/events` here to receive user clicks.

Tell the user: "Open **http://localhost:\<port\>** in a browser to see the
visual panel." Do not auto-open the URL.

### Platform launch

`start-server.sh` auto-detects the harness and chooses foreground vs. background automatically. Operator notes per platform:

- **macOS/Linux + Claude Code** — default: server is backgrounded by the script; nothing special needed.
- **Windows / Git-Bash** (`OSTYPE` is `msys`, `cygwin`, or `mingw`) — script runs in foreground; invoke the Bash tool with `run_in_background: true`, then read `state/server-info` on the next turn.
- **Codex** (`CODEX_CI` set) — script runs in foreground; same as Windows: use `run_in_background: true`.
- **Gemini CLI** — pass `--foreground` to `start-server.sh` and set the shell tool's background flag.
- **Remote / container** — start with `--host 0.0.0.0 --url-host localhost` so the printed URL is reachable inside the container.

Add the session directory (e.g. `.llm-orchestrator/brainstorm/` or the chosen `--project-dir` path) to `.gitignore`.

## Server health

Before pushing a screen, check that the server is running: if `state/server-stopped` exists or `state/server-info` is absent, the server has exited (it auto-stops after 30 min idle). Restart it with `bash skills/brainstorming/scripts/start-server.sh --project-dir <workspace-root>` before writing any content.

## Pushing a screen

Write a uniquely-named `.html` file into `screen_dir`. Never reuse a filename
across a session; use a naming scheme like `layout.html`, `layout-v2.html`,
`options-nav.html`.

- **Fragment HTML** (no `<html>` tag) is auto-wrapped in the frame template.
- **Full documents** (starting with `<!DOCTYPE html>`) are served as-is.

The browser reloads automatically via WebSocket as soon as the file appears.
The `events` file in `state_dir` is cleared whenever a new screen is pushed.

## Reading user input

On the next turn after pushing a screen, read `state_dir/events`. The file is
JSONL; each line is one click event:

```json
{"text": "Option A", "choice": "a", "id": "opt-a", "timestamp": "..."}
```

Use the most-recent event as the user's answer. If the file is empty the user
has not clicked yet — ask them to click and continue in a follow-up message.

## Returning to terminal-only

When visual output is no longer needed for the current question, push a
`waiting.html` screen that shows a neutral message (e.g. "Continue in the
terminal"). This clears stale content and avoids the user acting on an old
screen.

At the end of the brainstorming session, stop the server:

```bash
bash skills/brainstorming/scripts/stop-server.sh
```

## Offer wording

Use this exact phrasing when offering the visual panel (in its own message):

> Some of the upcoming questions involve layouts or visual structure. I can open
> a browser panel to show diagrams and clickable mockups instead of describing
> them in text. Want me to start it? (yes / no — you can skip it and stay in
> the terminal)

## Per-question decision: visual vs terminal

Ask: "Would the user understand this better by seeing it than by reading it?"

Render visually when the question involves:
- UI mockups or wireframes (screen layouts, component placement)
- Side-by-side design comparisons
- Architecture or data-flow diagrams
- State machine diagrams
- Multi-column layout comparisons where spatial relationship matters

Keep in the terminal when the question involves:
- Written requirements or acceptance criteria
- A/B/C conceptual choices (naming, approach, priority)
- Tradeoff lists or decision matrices
- API shape or data-model decisions
- Anything that reads clearly as a short bulleted list

A question about a UI topic is not automatically a visual question. If the
answer is "pick a name for this button," stay in the terminal.

## Frame CSS class vocabulary

These classes are available in the auto-wrapping frame template. Use them in
fragment HTML without writing your own `<style>` block unless truly necessary.

| Class | Purpose |
|---|---|
| `.options` / `.option` / `.letter` | Clickable A/B/C choice list |
| `.cards` / `.card` | Grid of selectable design cards |
| `.mockup` | Bordered container for a UI sketch |
| `.split` | Two-column side-by-side layout |
| `.pros-cons` | Two-column pros and cons grid |
| `.mock-nav` | Simulated top navigation bar |
| `.mock-sidebar` | Simulated sidebar panel |
| `.mock-content` | Simulated content area |
| `.mock-button` | Simulated button element |
| `.mock-input` | Simulated text input |
| `.placeholder` | Dashed placeholder area inside a mockup |

Full CSS definitions are in
`skills/brainstorming/scripts/frame-template.html`.
