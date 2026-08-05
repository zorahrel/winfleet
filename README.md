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
winfleet open Desktop         # the whole live desktop, in a window
winfleet open Blender         # a single app, in its own window
winfleet stop                 # close the session cleanly
winfleet list                 # apps available on the host
winfleet dock                 # generate Dock icons — click = window
winfleet doctor               # diagnostics: reachability, endpoint, pairing
winfleet endpoint             # which address it would use right now
```

Add an app so it gets a catalog entry and a Dock icon:

```sh
winfleet add blender "Blender"
winfleet dock blender
```

To expose a specific `.exe` as its own Sunshine app (so `winfleet open` launches it
directly), run on the PC:

```powershell
.\add-app.ps1 -Name "Blender" -Path "C:\Program Files\Blender\blender.exe" -WebPass '<pw>'
```

## Performance notes

- **Bitrate.** Default 40 Mbps. On a wired LAN with NVENC you can push 80–150 Mbps for
  near-lossless — set `BITRATE` in `~/.config/winfleet/config.env`.
- **fps.** 60 by default; the host advertises up to 120. Set `FPS` in the config.
- **Codec.** Sunshine negotiates HEVC when the client supports it (Apple Silicon does),
  which looks noticeably cleaner than H.264 at the same bitrate.
- **Mouse.** WinFleet uses Moonlight's `--absolute-mouse` (remote-desktop pointer), the
  right mode for productivity apps.

## Modes

| Mode | What you see | Setup |
|---|---|---|
| **Desktop** | the entire live session in one window | works out of the box |
| **Per-app** | one app registered as a Sunshine app, in its own window | `add-app.ps1` |
| **Isolated** *(advanced)* | one app on a dedicated **virtual display**, so the stream shows only that window | needs a Virtual Display Driver — see below |

**Isolated windows.** True "one app = one clean window" (no desktop behind it) uses a
per-app virtual monitor: the app is maximized on a virtual display and Sunshine streams
that display. The [Parsec Virtual Display Adapter] or [MikeTheTech's Virtual Display
Driver] provide the monitors. This is on the roadmap for first-class support.

[Parsec Virtual Display Adapter]: https://github.com/nomi-san/parsec-vdd
[MikeTheTech's Virtual Display Driver]: https://github.com/VirtualDrivers/Virtual-Display-Driver

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
│   ├── setup.ps1       # Windows: install & configure Sunshine, encoder, firewall
│   └── add-app.ps1     # Windows: register an .exe as a Sunshine app (via API)
└── install.sh          # Mac: install Moonlight + the winfleet command
```

Config lives in `~/.config/winfleet/config.env` (host addresses, fps, bitrate) and is
never committed.

## License

MIT — see [LICENSE](LICENSE).

Built on the shoulders of [Sunshine] and [Moonlight]. WinFleet is the glue that makes them
feel like native Windows-app windows on macOS.
