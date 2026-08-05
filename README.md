<div align="center">

# WinFleet

**Your Windows apps as native, GPU-accelerated windows on your Mac.**

Open the desktop — or a single app — from a Windows PC as a real, resizable macOS
window. Full GPU encode (NVENC / AMF / QuickSync), 60 fps+, low latency. Reuses the
PC's **already-running session** — no RDP login, no account juggling, no locked screen.

</div>

---

## Why

The usual options each miss something:

| | Native windows | Full GPU / high fps | Reuses live session | No login required |
|---|:---:|:---:|:---:|:---:|
| RDP RemoteApp | ✅ | ❌ | ❌ (new session) | ❌ (needs password) |
| Parsec / VNC (full screen) | ❌ | ✅ | ✅ | ✅ |
| **WinFleet** | ✅ | ✅ | ✅ | ✅ |

WinFleet doesn't reinvent the hard part. It stands on **[Sunshine]** (host) and
**[Moonlight]** (client) — the open-source, gaming-grade streaming stack — and adds the
orchestration that turns them into a **windowed, per-app** experience with Dock icons and
one-command launch.

[Sunshine]: https://github.com/LizardByte/Sunshine
[Moonlight]: https://github.com/moonlight-stream/moonlight-qt

## How it works

```
   Mac                                             Windows PC (RTX / AMD / Intel)
 ┌───────────────────────┐                       ┌──────────────────────────────┐
 │  winfleet open <app>  │                       │            Sunshine          │
 │          │            │      encoded H.264/   │   (NVENC hardware encode)     │
 │          ▼            │       HEVC over UDP    │             ▲                │
 │   Moonlight (window)  │◀─────────────────────▶│   live session of your user  │
 │   = native macOS win  │   LAN (preferred) or   │   (apps already open)        │
 └───────────────────────┘   Tailscale (anywhere) └──────────────────────────────┘
```

- **LAN-first, Tailscale-fallback.** On your own network WinFleet dials the raw LAN IP
  (full MTU, no VPN overhead); away from home it falls back to the Tailscale address
  automatically. It probes before every launch.
- **Windowed.** Moonlight runs in `windowed` display mode, so each stream is an ordinary,
  resizable Mac window you can tile beside your Mac apps.
- **Live session.** Streaming attaches to the session already signed in on the PC — the
  apps you left open are right there. Nothing is disconnected.

## Install

### Mac

```sh
git clone https://github.com/zorahrel/winfleet.git
cd winfleet
./install.sh          # installs Moonlight (if needed) + the `winfleet` command
```

### Windows PC (once, PowerShell as Administrator)

```powershell
# copy the host/ folder over, then:
.\setup.ps1 -WebPass '<choose-a-password>'
```

`setup.ps1` installs/configures Sunshine, picks the right hardware encoder for your GPU,
opens the firewall to **LAN + Tailscale only**, and prints the addresses to use.

### Pair (once)

```sh
winfleet setup     # enter the Tailscale / LAN addresses from setup.ps1
winfleet pair      # Moonlight shows a PIN → enter it in the Sunshine web UI
```

## Use

```sh
winfleet search blender       # find an app installed on the PC and open it
winfleet open Desktop         # the whole live desktop, in a window
winfleet open Blender         # a single app, in its own window
winfleet stop                 # close the session cleanly
winfleet fit                  # snap the window back to the stream's proportions
winfleet scan                 # re-read the list of apps installed on the PC
winfleet list                 # apps published by the host
winfleet dock                 # generate Dock icons — click = window
winfleet doctor               # diagnostics: reachability, endpoint, pairing
winfleet endpoint             # which address it would use right now
```

### Finding and opening apps

`winfleet search` reads the PC's Start Menu, so you get the apps a person would
actually launch rather than every binary on disk. Pick one and WinFleet registers it
on the host by itself, then opens it:

```sh
$ winfleet search telegram
  ○ registro «Telegram» sull'host…
  ✓ «Telegram» registrata
Telegram → finestra sul Mac  (192.168.1.3, lan, 3440x1440, 60 fps, 80 Mbps)
```

This needs SSH access to the host — set `HOST_SSH="user@address"` in the config.
Without it, register apps on the PC instead:

```powershell
.\add-isolated-app.ps1 -Name "Blender" -Path "C:\Program Files\Blender\blender.exe"
```

### The window

The stream window is an ordinary Mac window: move it, resize it, put it on another
Space. WinFleet keeps it **locked to the stream's proportions** as you resize, so the
image always fills it — no black bars — and it keeps it on screen (Moonlight would
otherwise size the window to the remote resolution, which lands an ultrawide host
partly outside a laptop display). Drag the width; the height follows. `winfleet fit`
re-snaps it at any time.

## Performance notes

- **Resolution.** `RESOLUTION=auto` streams the host's native resolution, so there is no
  rescaling at either end. This matters more than it sounds: without an explicit
  resolution Moonlight asks for 1280x720 and the host downscales, which looks soft on a
  1440p host no matter how much bitrate you throw at it. WinFleet learns the host's
  resolution from the first connection and uses it from then on.
- **Bitrate.** `BITRATE=auto` scales with the pixel count (20 Mbps at 720p up to 80 Mbps
  above 1440p). On a wired LAN with NVENC you can push higher — set a number instead.
- **fps.** 60 by default; the host advertises up to 120. Set `FPS` in the config.
- **Codec.** Sunshine negotiates HEVC when the client supports it (Apple Silicon does),
  which looks noticeably cleaner than H.264 at the same bitrate.
- **Mouse.** WinFleet uses Moonlight's `--absolute-mouse` (remote-desktop pointer), the
  right mode for productivity apps.

## Modes

| Mode | What you see | Setup |
|---|---|---|
| **Desktop** | the entire live session in one window | works out of the box |
| **Isolated** | **one app, alone** — no desktop, no taskbar, nothing else | `setup-isolated.ps1` + `add-isolated-app.ps1` |

### Isolated windows — one app, 1:1

`winfleet open <App>` gives you a Mac window containing that Windows app and *only* that
app. Not a cropped desktop, not a maximized window with the taskbar peeking out: the app
is the entire frame.

```powershell
.\setup-isolated.ps1                                              # once
.\add-isolated-app.ps1 -Name Blender -Path "C:\...\blender.exe"
```

Then on the Mac: `winfleet add blender "Blender"` and `winfleet open Blender`.

**How it works — a dedicated desktop.** Windows can host several *desktop objects* in one
session, each with its own set of windows. WinFleet creates one called `WinFleet`, starts
your app there, and switches the screen to it. Nothing else lives on that desktop — no
Explorer, so no taskbar and no icons — so whatever Sunshine captures *is* the app. This is
isolation by construction, not by hiding: no amount of other windows opening on your real
desktop can leak into the stream. When the app closes (or the client disconnects) the
screen returns to your real desktop and the app is closed.

Two Windows traps it clears for you:

- **Session-0 isolation.** Sunshine runs as a service in session 0, so neither launching
  an app nor switching desktops works from there. WinFleet does both through scheduled
  tasks that run *inside your logged-in session*. You must be logged in on the PC (a
  locked screen is fine).
- **Resolution switch.** Sunshine resizes the display to the client's resolution when it
  connects. The launcher keeps refitting the app to the current display, so it fills the
  frame after the switch rather than before it.

**Trade-offs, honestly:**

- While an isolated app is streaming, the PC's own monitor shows that app, not your
  desktop. This is a *remote* mode, not a share-my-screen mode.
- Sunshine streams one session at a time, so it is one app at a time — not several side by
  side. Simultaneous per-window streaming would need a custom remote compositor
  (per-window GPU capture + transport), a much larger project.
- The app is found by watching for the window that appears on the fresh desktop, which is
  robust for apps whose visible window belongs to a different process than the one you
  launch (Store-packaged apps, Chromium, Electron).

## Troubleshooting

- **`winfleet doctor` shows the host unreachable** — PC off, Sunshine service stopped, or
  firewall. On the PC: `Get-Service SunshineService`.
- **Moonlight can't reach the LAN IP but Tailscale works** — grant Moonlight the macOS
  *Local Network* permission (System Settings → Privacy & Security → Local Network).
  WinFleet will keep using Tailscale until then; it still takes the direct LAN path.
- **Pairing says "PIN didn't match"** — a stale pairing. `winfleet pair` again after
  unpairing in the Sunshine web UI (Troubleshooting → Unpair all).

## Layout

```
winfleet/
├── bin/winfleet        # Mac orchestrator (CLI): open / list / dock / pair / doctor
├── host/
│   ├── setup.ps1              # Windows: install & configure Sunshine, encoder, firewall
│   ├── add-app.ps1            # Windows: register an .exe as a Sunshine app
│   ├── setup-isolated.ps1     # Windows: enable isolated (single-app) mode
│   ├── add-isolated-app.ps1   # Windows: register an .exe as an isolated app
│   ├── scan-apps.ps1          # Windows: list installed apps (for `winfleet search`)
│   ├── wf-launch.ps1          # creates the dedicated desktop and switches to it
│   ├── wf-inner.ps1           # runs on that desktop: starts + fits the app
│   └── wf-reset.ps1           # teardown: close the app, back to the real desktop
└── install.sh          # Mac: install Moonlight + the winfleet command
```

Config lives in `~/.config/winfleet/config.env` (host addresses, fps, bitrate) and is
never committed.

## License

MIT — see [LICENSE](LICENSE).

Built on the shoulders of [Sunshine] and [Moonlight]. WinFleet is the glue that makes them
feel like native Windows-app windows on macOS.
