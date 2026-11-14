# Making a Kongi extension

An extension is a folder in a GitHub repository with a manifest and a program:

```
kongi-extension.json
main.sh            any executable: a shell script, Python, Node, a compiled binary
```

```json
{
  "name": "My extension",
  "description": "One line people see in the marketplace.",
  "version": "1.0",
  "run": "main.sh",
  "events": "on-event.sh",
  "uninstall": "uninstall.sh"
}
```

| Field | |
|---|---|
| `run` | Started when the extension is turned on (and every time Kongi starts). Stopped when it's turned off or Kongi quits. It can run forever (a loop) or do its job and exit. |
| `events` | Optional. Run once per event, with the event name as the first argument and `$KONGI_EVENT`, and the details as JSON on stdin. |
| `uninstall` | Optional. Run once just before the extension is removed (up to 10 seconds) — undo any settings you changed. |

All paths are relative to the extension's folder and can't point outside it. Output goes to `extension.log` (Settings → Extensions → the document button). Kongi sets `$KONGI` (the command below), `$KONGI_EXTENSION`, `$KONGI_EXTENSION_NAME` and `$KONGI_LANGUAGE` (the app language: `en`, `ko`, `ja`, `zh-Hans`, `zh-Hant`, `es`, `fr`, `de`, `it`, `pt-BR`, `ru`) so you can show text in the user's language.

## The `kongi` command

Use `"$KONGI"` from an extension. From your own apps and scripts, use the same command without an extension: Settings → Extensions → For developers shows the path.

```sh
# A notice in the island. Same --id replaces the last one; --url opens on click.
"$KONGI" notify "Deploy finished" "api · 42s" --symbol paperplane.fill --seconds 6 --id deploy --url https://example.com

# Wrap a build or test: progress %, passed/failed counts and a pass/fail ring, then a notice when it ends.
"$KONGI" run --name "Nightly build" -- make release

# Report progress yourself (for work you can't wrap with run).
"$KONGI" task backup --name "Backup" --progress 40%
"$KONGI" task backup --done          # or --failed

# A row in the menu bar window that you keep updating. --progress draws a bar; --url opens on click.
"$KONGI" widget weather --title "Seoul" --value "7°" --detail "Clear" --symbol sun.max.fill
"$KONGI" widget weather --remove

# What Kongi knows right now, as JSON: Claude usage, live sessions (Claude Code, Codex), builds.
"$KONGI" status
```

Symbols are [SF Symbols](https://developer.apple.com/sf-symbols/) names. Widgets disappear when the extension stops.

## Events

| Event | When | JSON |
|---|---|---|
| `session.start` | A Claude Code or Codex session starts | `session_id`, `agent` (`claude`/`codex`), `project`, `cwd` |
| `session.prompt` | You send a message | + `prompt` |
| `session.approval` | The agent asks for permission | + `tool`, `detail` |
| `session.done` | The agent finishes a turn | + `message` (its last reply) |
| `session.error` | A turn stops with an error (e.g. a usage limit) | + `message` |
| `session.end` | The session closes | |
| `task.done` / `task.failed` | A `kongi run` or `kongi task` ends | `id`, `name`, `seconds`, `passed`, `failed` |

```sh
#!/bin/sh
# on-event.sh — flash a light when Claude finishes
[ "$1" = "session.done" ] && curl -s -X POST http://hue.local/api/flash
```

## Actions (input in the island)

An extension can add actions that take text in the island and show a result the user can copy or send to a Claude Code conversation. `run` is optional when an extension only has actions.

```json
{
  "name": "Prompt upgrade",
  "version": "1.0",
  "actions": [{
    "id": "upgrade",
    "title": { "en": "Upgrade a prompt", "ko": "프롬프트 업그레이드" },
    "placeholder": "Paste a prompt to improve…",
    "run": "upgrade.sh",
    "choiceTitle": "Model",
    "choices": [{ "id": "haiku", "title": "Haiku" }, { "id": "opus", "title": "Opus" }],
    "timeout": 180
  }]
}
```

- Text fields take a plain string or one per language (`en`, `ko`, `ja`, `zh-Hans`, `zh-Hant`, `es`, `fr`, `de`, `it`, `pt-BR`, `ru`). Kongi falls back to English.
- Kongi runs `run` with the user's input on stdin and the chosen option in `$KONGI_CHOICE` (the last choice is remembered). `$KONGI_ACTION` is the action id, and `$KONGI_CLAUDE` is the path of the `claude` CLI if it's installed.
- Print the result to stdout and exit 0. A non-zero exit shows the end of stderr as the error. Actions are stopped after `timeout` seconds (default 120, at most 600).
- Add `"context": ["project", "files"]` to show a project picker and an attach button. Kongi then writes a JSON file and puts its path in `$KONGI_CONTEXT`: `language`, `project` (folder), `conversation` (title), `messages` (recent `{role, text}`), `changedFiles`, `files` (attached paths), `answers` (`{question, answer}`) and `skipQuestions`.
- To ask the user first, print only `{"questions": [{"question": "…", "options": ["…"]}]}` (up to 3). Kongi shows them with answer fields and runs the action again with `answers` filled in, or with `skipQuestions: true` if the user skips. Ask once; don't ask again when `answers` or `skipQuestions` is set.
- See [`prompt-upgrade`](prompt-upgrade) for a complete example that calls Claude Code.

## Other agents

Any agent whose hooks send Claude Code–style JSON can show up in the island like Claude Code: point its hooks at `kongi --agent <name>` (stdin is the hook JSON).

## Publishing

People install it from **Settings → Extensions → Install from GitHub** with `owner/repo` or `owner/repo/path/to/folder`. To list it in the marketplace, open a pull request that adds it to [`marketplace/catalog.json`](../marketplace/catalog.json).

Extensions run with the user's permissions, like any app. Kongi asks before installing and shows the repository, but it can't sandbox them — keep yours small and readable.
