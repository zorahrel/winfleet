<div align="center">

# WinFleet

**Your Windows apps as native, GPU-accelerated windows on your Mac.**

One app, one Mac window — with the app's own name in the title bar, its own icon in the
Dock, resizable for real. Full GPU encode (NVENC / AMF / QuickSync), 60 fps+, low latency,
on the PC's **already-running session**: no RDP login, no locked screen, no second account.

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
orchestration that turns them into a per-app, windowed experience.

[Sunshine]: https://github.com/LizardByte/Sunshine
[Moonlight]: https://github.com/moonlight-stream/moonlight-qt

## One app, one window

```sh
winfleet search telegram      # find it on the PC and open it
winfleet open "Microsoft Edge"
winfleet windows              # what's open, and what's free
winfleet stop 2               # close window 2 (or `stop` for all)
```

Not a desktop with the app in it, and not a scaled picture of one. The window **is** the
app: drag its corner and the Windows side changes resolution to match, so the app reflows
the way it would on a real monitor instead of stretching.

That works because each app gets **a screen of its own**. WinFleet plugs virtual monitors
into the Parsec Virtual Display Adapter — already present on most gaming PCs, so there is
usually nothing to install — and runs one Sunshine instance per monitor. Isolation then
costs nothing: no taskbar, no other windows, no wallpaper, because nothing else ever draws
on that screen. **The PC's real desktop is left completely alone**, and several apps stream
at the same time, one per monitor.

### It looks like the app, not like a stream

```sh
winfleet dock Telegram "Microsoft Edge"    # launchers with the real Windows icons
```

- **Title bar** shows `Telegram`. On macOS, Moonlight titles the window with the host's
  name and nothing else, so WinFleet renames the instance to the app before connecting.
- **Dock, ⌘-Tab and the menu bar** show the app's name and its Windows icon, because the
  stream is drawn by a copy of Moonlight that carries the app's identity. On APFS the copy
  is a clone: instant, and it costs no disk space.
- **Spotlight** finds it, and a click on the Dock icon opens the window.

The icon is pulled off the Windows executable at full 256×256 through the shell's image
factory — the same path Explorer uses — so it is the real icon, transparency included, not
a blurry 32-pixel stamp.

### Which apps

`winfleet scan` reads the PC's Start Menu **and** its packaged apps. That second part
matters: Notepad, Calculator, Photos and most of what ships with Windows 11 have no
shortcut on disk at all, so a Start-Menu-only scan silently misses half the Start menu.

```sh
$ winfleet search blocco
Blocco note → finestra 1 sul Mac  (WindowsAtti.local, 1280x800, 60 fps)
```

## Install

### Mac

```sh
git clone https://github.com/zorahrel/winfleet.git
cd winfleet
./install.sh          # Moonlight (if needed) + the `winfleet` command
winfleet setup        # addresses, mDNS name, how many windows, SSH
```

### Windows PC (once, PowerShell as Administrator)

`winfleet push` copies `host/*.ps1` to `C:\winfleet` over SSH and checks they compile
there. Then, on the PC:

```powershell
.\setup.ps1 -WebPass '<choose-a-password>'   # Sunshine, encoder, firewall
.\setup-vdd.ps1 -Slots 2                     # 2 virtual monitors = 2 windows
schtasks /run /tn winfleet-vdd
.\wf-instance.ps1 -Slot 0                    # one Sunshine instance per monitor
.\wf-instance.ps1 -Slot 1
```

### Pair (once per window)

Open Moonlight, click the padlocked **WinFleet N**, and type the PIN into that instance's
web UI (`https://<host>:48090`, `:48190`, …). The CLI never prints the PIN, so this step
is done from the GUI. Then `winfleet scan` and you're set.

> The **mDNS name** (`PCdiCasa.local`) is not cosmetic: Moonlight compares known hosts by
> address and ignores the port, so with a bare IP every instance looks like the same PC.

## Commands

```sh
winfleet open <app>        open an app in a window
winfleet search <text>     find an app on the PC and open it
winfleet windows           which windows are open, and on what
winfleet dock <app...>     make .app launchers (real name, real icon)
winfleet apps              launchers made so far
winfleet fit               snap windows back to the pixels they receive
winfleet stop [n]          close one window, or all of them
winfleet scan              re-read the PC's app list
winfleet push              upload the host scripts to C:\winfleet
winfleet clean             drop Moonlight hosts that answer with another identity
winfleet doctor            diagnostics
```

`WINFLEET_TRACE=1` writes what the window supervisor sees to
`~/.config/winfleet/trace.log` — the only sane way to debug a window that "resizes itself".

## Performance notes

- **Native pixels.** The Mac window is exactly as many pixels as the virtual monitor, so
  nothing is rescaled at either end and there are no black bars. Without an explicit
  resolution Moonlight asks for 1280x720 and the host downscales — soft no matter how much
  bitrate you throw at it.
- **Bitrate.** `BITRATE=auto` scales with pixel count (20 Mbps at 720p up to 80 Mbps above
  1440p). On a wired LAN with NVENC you can push higher — set a number instead.
- **fps.** 60 by default, the host advertises up to 120. Set `FPS` in the config.
- **Codec.** Sunshine negotiates HEVC when the client supports it (Apple Silicon does),
  noticeably cleaner than H.264 at the same bitrate.
- **Path.** LAN first (full MTU, no VPN overhead), Tailscale when you're away. Probed
  before every launch.
- **Mouse.** `--absolute-mouse`, the right pointer mode for productivity apps.

## How the pieces fit

| | |
|---|---|
| `wf-vdd.ps1` | plugs the virtual monitors, keeps them alive, changes their resolution on request |
| `wf-instance.ps1` | creates a Sunshine instance bound to one monitor, on its own ports |
| `wf-inst-ctl.ps1` | starts / stops an instance |
| `wf-rename.ps1` | renames an instance — that is what names the window on the Mac |
| `wf-place.ps1` | opens the app and holds it over its monitor |
| `wf-icon.ps1` | hands back an app's icon as a PNG |
| `scan-apps.ps1` | lists the installed apps, shortcuts and packaged alike |
| `bin/winfleet` | picks a free window, follows resizes, keeps the Mac window honest |

### Things that had to be worked around

All of them are commented where they bite, so nobody re-discovers them the hard way.

- **A service cannot open your windows, and your session cannot see your screens.**
  Sunshine as a service lives in session 0 and can only launch apps by duplicating the
  console token — a privilege only LocalSystem holds, so an instance running as you fails
  with `ACCESS_DENIED` even elevated. Meanwhile a plain process in session 0 enumerates no
  displays at all. So Sunshine only streams, and WinFleet opens apps from a scheduled task
  in your own session.
- **Sunshine is a console program.** Owned by a scheduled task it takes `CTRL_CLOSE` when
  that console goes away — a remote shell disconnecting was enough to kill a session
  mid-stream. The task now only launches it, detached.
- **An indirect display driver refuses `ChangeDisplaySettingsEx`** with a position, or
  staged with `CDS_NORESET`: `DISP_CHANGE_FAILED` every time. Resolution alone, applied
  immediately, works — Windows re-lays-out the desktop itself.
- **`Set-Content -Encoding UTF8` writes a BOM**, which Sunshine treats as a broken
  `apps.json` and silently replaces with its defaults.
- **Moonlight sizes the window itself**, and not only once: if the stream doesn't fit the
  display SDL thinks is active, it rebuilds the window at 80% — seconds after opening it at
  the right size. WinFleet holds the size for a while before it starts watching, otherwise
  that correction reads as "the user resized" and the window walks down a resolution per
  reconnect.
- **Spaces don't survive the trip.** Through ssh → cmd → PowerShell, quoting collapses and
  `Microsoft Edge` arrives as two arguments. Names and paths travel base64.
- **AppleScript resolves `every process whose unix id is N` by index**, so with several
  Moonlight processes you drive the wrong window. `tell (first process whose …)` is the
  form that works.
- **Finder's desktop rectangle is the union of all displays.** With two monitors it
  promises room a window cannot have, and macOS truncates the window silently. WinFleet
  measures the real maximum once, with a window in hand, and remembers it.

## Whole-desktop mode

`winfleet open Desktop` still streams the PC's live session in a single window, at native
resolution, aspect-locked. No virtual monitors involved.

## Troubleshooting

- **`winfleet doctor` shows the host unreachable** — PC off, Sunshine stopped, or firewall.
  On the PC: `Get-Service SunshineService`.
- **Moonlight can't reach the LAN IP but Tailscale works** — grant Moonlight the macOS
  *Local Network* permission (System Settings → Privacy & Security → Local Network).
- **A window won't open and the log says the control stream failed** — that instance is
  down or unpaired. `winfleet windows` tells you which; restart it with
  `wf-inst-ctl.ps1 -Slot N -Action restart`.
- **Old hosts with warning icons pile up in Moonlight** — `winfleet clean`. It only drops
  entries whose address answers with a *different* identity; a PC that is merely off stays.

## Layout

```
winfleet/
├── bin/winfleet              # Mac: open / search / windows / dock / clean / doctor
├── host/
│   ├── setup.ps1             # Sunshine: install, encoder, firewall
│   ├── setup-vdd.ps1         # registers the virtual-monitor manager
│   ├── wf-vdd.ps1            # virtual monitors: attach, keep-alive, resolution
│   ├── wf-instance.ps1       # one Sunshine instance bound to one monitor
│   ├── wf-inst-ctl.ps1       # start / stop / inspect an instance
│   ├── wf-rename.ps1         # rename an instance = name the Mac window
│   ├── wf-place.ps1          # open the app and hold it over its monitor
│   ├── wf-icon.ps1           # an app's icon, as PNG
│   └── scan-apps.ps1         # installed apps, shortcuts and packaged
└── install.sh                # Mac: Moonlight + the winfleet command
```

Config in `~/.config/winfleet/config.env` (addresses, host SSH, how many windows, fps,
bitrate, per-app window sizes) — never committed.

## License

MIT — see [LICENSE](LICENSE).

Built on the shoulders of [Sunshine] and [Moonlight]. WinFleet is the glue that makes them
feel like native Windows-app windows on macOS.
