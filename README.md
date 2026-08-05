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

## Windows, one per app

`winfleet search telegram` opens Telegram as a Mac window. Not a desktop with Telegram
in it, and not a scaled picture of one: the window *is* the app, and resizing it resizes
the Windows window.

That works because each app gets **a screen of its own**. WinFleet plugs virtual monitors
into the Parsec Virtual Display Adapter — already present on most gaming PCs, so nothing
is installed — and runs one Sunshine instance per monitor. Isolation then costs nothing:
no taskbar, no other windows, no desktop, because nothing else ever draws on that screen.
The PC's real desktop is left completely alone, and several apps stream at once, one per
monitor.

```sh
winfleet windows          # quali finestre sono libere
winfleet search edge      # apre Edge nella prima libera
winfleet search telegram  # e Telegram in un'altra, insieme
```

### Resizing

Drag the Mac window and the **Windows display changes resolution to match**: the app
reflows the way it would on a real monitor of that size, instead of being stretched. When
you stop dragging, WinFleet picks the closest resolution the virtual monitor supports,
switches it, and reconnects — about a second, and the app keeps running throughout. The
size is remembered per app, so it opens that way next time.

### Setup on the PC (once, PowerShell as Administrator)

```powershell
.\setup.ps1 -WebPass '<scegli-una-password>'   # Sunshine, encoder, firewall
.\setup-vdd.ps1 -Slots 2                       # 2 monitor virtuali = 2 finestre
schtasks /run /tn winfleet-vdd
.\wf-instance.ps1 -Slot 0                      # un'istanza Sunshine per monitor
.\wf-instance.ps1 -Slot 1
```

Then on the Mac, once per instance: open Moonlight, click the padlocked **WinFleet N**,
and enter the PIN it shows in that instance's web UI (`https://<host>:48090`, `:48190`, …).

### How the pieces fit

| | |
|---|---|
| `wf-vdd.ps1` | plugs the virtual monitors, keeps them alive, changes their resolution on request |
| `wf-instance.ps1` | creates a Sunshine instance bound to one monitor, on its own ports |
| `wf-inst-ctl.ps1` | starts/stops an instance |
| `wf-place.ps1` | opens the app and holds it over its monitor |
| `bin/winfleet` | picks a free window, follows resizes, keeps the Mac window honest |

Four Windows details this had to work around, all documented in the scripts:

- **A service cannot open your windows, and your session cannot see your screens.**
  Sunshine as a service lives in session 0 and can only launch apps by duplicating the
  console token — a privilege only LocalSystem holds, so an instance running as you fails
  with `ACCESS_DENIED` even elevated. Meanwhile a plain process in session 0 enumerates no
  displays at all. So Sunshine only streams, and WinFleet opens apps from a scheduled task
  in your own session.
- **Sunshine is a console program.** Owned by a scheduled task it takes `CTRL_CLOSE` when
  that console goes away — a remote shell disconnecting was enough to kill a session
  mid-stream. The task now only launches it, detached.
- **An indirect display driver refuses `ChangeDisplaySettingsEx` with a position or
  staged with `CDS_NORESET`** — `DISP_CHANGE_FAILED` every time. Resolution alone, applied
  immediately, works; Windows re-lays-out the desktop itself.
- **PowerShell's `Set-Content -Encoding UTF8` writes a BOM**, which Sunshine treats as a
  broken `apps.json` and silently replaces with its defaults.

## Whole-desktop mode

`winfleet open Desktop` still streams the PC's live session in a window, at native
resolution, aspect-locked. No virtual monitors involved.

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
├── bin/winfleet              # Mac: open / search / windows / fit / dock / doctor
├── host/
│   ├── setup.ps1             # Sunshine: installazione, encoder, firewall
│   ├── setup-vdd.ps1         # registra il gestore dei monitor virtuali
│   ├── wf-vdd.ps1            # monitor virtuali: aggancio, keep-alive, risoluzione
│   ├── wf-instance.ps1       # crea un'istanza Sunshine legata a un monitor
│   ├── wf-inst-ctl.ps1       # avvia/ferma/interroga un'istanza
│   ├── wf-place.ps1          # apre l'app e la tiene sul suo schermo
│   └── scan-apps.ps1         # elenca le app installate (per `winfleet search`)
└── install.sh                # Mac: Moonlight + il comando winfleet
```

Config in `~/.config/winfleet/config.env` (indirizzi, SSH dell'host, numero di finestre,
fps, bitrate) — mai committato.

## License

MIT — see [LICENSE](LICENSE).

Built on the shoulders of [Sunshine] and [Moonlight]. WinFleet is the glue that makes them
feel like native Windows-app windows on macOS.
