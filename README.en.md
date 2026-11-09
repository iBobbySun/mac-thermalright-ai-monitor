# MacTR — AI Agent & System Monitor for Thermalright LCD

[中文](README.md) · [English](README.en.md)

Turn the 1920×480 LCD on your Thermalright CPU cooler into a live dashboard that shows
your Mac's vitals **and what your AI coding agents are doing right now** — all native on
macOS, no Windows required.

![On real hardware](img/photo.jpg)

<sub>Running on a Thermalright Trofeo Vision 9.16 cooler.</sub>

![Dashboard](img/dashboard.gif)

<sub>Live demo (fake data). Both agents "working" → columns breathe, Bongo Cat types,
Pikachu hops and crackles with CPU load, clock ticks.</sub>

> Fork of [beret21/MacTR](https://github.com/beret21/MacTR), reworked around a central
> **AI Agents** panel that tracks [Claude Code](https://claude.com/claude-code) and
> [Codex](https://openai.com/codex) sessions in real time, plus
> [OpenCode Zen](https://opencode.ai) subscription quota.

## Highlights

### 🤖 AI Agents panel
Reads your **local** Claude Code and Codex session logs (read-only) and — once an API key is
configured — the OpenCode Zen usage endpoint. Shows 1–2 agents at a time:

- **Current project** and the **last thing it said** — Markdown tables in the message are
  rendered as real aligned tables, not raw `| … |` text.
- **Plan / step progress** — `步骤 4/6` badge + a segmented progress bar, parsed from
  Codex `update_plan` and Claude `TodoWrite`. Stale plans from a finished turn disappear.
- **Today's token usage** — total + In/Out, in a compact `万 / 亿` format (the OpenCode
  usage API reports no token counts, so that column shows `—`).
- **Remaining quota** — Claude (5-hour / 7-day) and Codex (5-hour / 7-day) from local
  transcripts, OpenCode (rolling / weekly / monthly) from its usage API; each with the
  remaining % and reset time.
- **Live status** — the column **breathes** while an agent is working and **flashes** for
  ~10 s when it finishes a turn or needs your input.

### 🖥️ System panels
- **CPU** — usage arc gauge, per-core P/E bars, temperature (via IOHIDEventSystemClient,
  no sudo), load average.
- **Memory** — pressure-colored usage gauge, Active/Wired/Compressed/Available breakdown,
  a full-width clock, date, uptime and process count.

### 🐱⚡ Desk pets that react to activity
- A **Bongo Cat** taps its keyboard while your agents work (and dozes when idle).
- A **Pikachu** whose electricity crackles harder as CPU load rises, and who hops and
  turns while an agent is running.

### ⚙️ Under the hood
- **Adaptive frame rate** — the LCD runs at ~15 fps only while something is animating
  (agent working, heavy CPU); otherwise it idles at 2 fps to save power.
- **USB hotplug** — auto-reconnect on plug/unplug and sleep/wake.
- **On-Mac preview** — when no LCD is connected it renders to a window instead, so you can
  develop and see changes without the hardware.
- **Menu bar app** — runs in the background, no dock icon.

## Hardware

| | |
|---|---|
| **Product** | [Thermalright Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) |
| **Display** | 9.16" IPS, 1920 × 480 |
| **Connection** | USB Type-C (USB 2.0) |
| **Device** | `0416:5408` (LY Bulk protocol) |

## Requirements

- Apple Silicon Mac (M1–M5)
- macOS 15 (Sequoia) or newer
- [Homebrew](https://brew.sh) with `libusb`
- A recent Swift toolchain (Xcode 16+, or Swift 6.1+ via Homebrew)

## Build & run

```bash
brew install libusb pkg-config

git clone https://github.com/m1ng-li/mac-thermalright-ai-monitor.git
cd mac-thermalright-ai-monitor
export MACTR_BUILD_DIR="$HOME/build_dir/mac-thermalright-ai-monitor"
swift build --scratch-path "$MACTR_BUILD_DIR" -c release

"$MACTR_BUILD_DIR/release/MacTR"          # menu-bar app; drives the LCD, or previews in a window
```

> If your Command Line Tools are broken and `swift build` fails on the package manifest,
> install the Homebrew Swift toolchain (`brew install swift`) and use
> `/opt/homebrew/opt/swift/bin/swift build --scratch-path "$MACTR_BUILD_DIR" -c release`.

### Auto-start on login

```bash
cp packaging/com.beret21.MacTR.plist ~/Library/LaunchAgents/   # edit the path inside first
launchctl load -w ~/Library/LaunchAgents/com.beret21.MacTR.plist
```

## Modes

```bash
"$MACTR_BUILD_DIR/release/MacTR"                 # menu-bar app (LCD, or preview window if no LCD)
"$MACTR_BUILD_DIR/release/MacTR" --preview       # force the on-Mac preview window
"$MACTR_BUILD_DIR/release/MacTR" --demo          # drive the LCD with polished fake data (for photos)
"$MACTR_BUILD_DIR/release/MacTR" --snapshot x.png --cores 10   # render one demo frame to a PNG
"$MACTR_BUILD_DIR/release/MacTR" --gif x.gif --frames 48 --fps 12 --scale 2   # animated demo GIF
"$MACTR_BUILD_DIR/release/MacTR" --benchmark 120 # measure achievable LCD frame rate
"$MACTR_BUILD_DIR/release/MacTR" --opencode-usage # diagnostics: OpenCode key status + rolling/weekly/monthly windows
```

Only one process can hold the USB device at a time — stop the running instance before
using `--demo` / `--benchmark`.

## How agent data is read

Apart from the sources below, MacTR does not talk to any network or API. This fork removes
the Sparkle auto-updater; Claude / Codex only read the local transcripts those CLIs already
write to disk, and the OpenCode quota is **optional** — it is only queried after you enter an
API key in Settings.

| Agent | Source | What's parsed |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | assistant messages, `usage` tokens, `TodoWrite` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | agent messages, `token_count`, `rate_limits`, `update_plan` |
| OpenCode | `GET https://opencode.ai/zen/go/v1/usage` (Bearer API key, optional) | rolling / weekly / monthly usage % and reset times |

Token totals are scoped to the local day; the panel gracefully shows the last session's
context when an agent hasn't run yet today.

### OpenCode usage (optional)

1. Create an API key in the OpenCode Zen console, open **Settings → Agents**, paste it into the
   OpenCode field and click "Save & Test".
2. The key is never written in plain text: an AES-128 key derived as
   `MD5(local random secret + per-save salt)` encrypts it with AES-GCM into the local
   preferences, and the UI only shows the key's MD5 fingerprint (first 8 hex chars) for
   verification. This is on-disk obfuscation — it keeps the key out of casual view, it is not
   strong protection against a local attacker.
3. Once configured, the dashboard polls the quota every 60 s. Failures (invalid key, offline,
   API change) are shown in that column and retried automatically without affecting other panels.
4. The endpoint only returns status + percentage + reset time, so OpenCode's "Today token"
   field shows `—`. Clearing the key removes all network traffic.

### Which agents the dashboard shows

Tick Claude / Codex / OpenCode in **Settings → Agents** — **at most 2 are shown at once**
(the remaining toggles are disabled once two are selected). Orientation still lives in
**Settings → Display**.

## Privacy

Apart from the optional OpenCode quota lookup, everything is local and read-only: no
telemetry, no third-party network calls. The only outbound request — made only after you
configure an OpenCode API key — is `GET https://opencode.ai/zen/go/v1/usage` once every 60 s,
carrying that key as an `Authorization: Bearer` header and no local data at all. Without a key,
there is no network traffic. The key is stored only on this Mac (see the encryption above).

## Credits

- [beret21/MacTR](https://github.com/beret21/MacTR) — the original macOS driver this is built on
- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) — LY Bulk protocol reverse engineering
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) — IOHIDEventSystemClient temperature reading
- [kuroni/bongocat-osu](https://github.com/kuroni/bongocat-osu) — Bongo Cat sprite
- Pikachu artwork via [PokeAPI/sprites](https://github.com/PokeAPI/sprites) — Pokémon is © Nintendo / Creatures / GAME FREAK; included here as a cosmetic homage only

> The Bongo Cat and Pikachu are purely decorative. If you redistribute builds, note that
> their artwork belongs to the respective owners — swap or remove the embedded
> `BongoCatAsset.swift` / `PikachuAsset.swift` if that matters for your use.

## License

MIT (inherited from the upstream project). Third-party assets remain under their own terms.

---

Built with Swift + libusb. Developed with [Claude Code](https://claude.com/claude-code).
