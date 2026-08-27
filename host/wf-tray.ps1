<#
.SYNOPSIS
  Icona nella barra di Windows: dice se winfleet sta bene, e cosa c'e' che non va.

.DESCRIPTION
  Nasce da un guasto preciso. Il 27/08 l'istanza Sunshine dello slot 0 e' morta da
  sola all'01:00 e nessuno se n'e' accorto per TREDICI ore: sul Mac le aperture
  dicevano "il PC e' spento", sul PC non c'era niente da guardare - nessuna finestra,
  nessuna icona, nessun avviso. Il guasto era scritto in tre log diversi, tutti
  invisibili a chi stava usando il computer.

  Questa e' la faccia del sistema sul lato Windows: un'icona che si guarda in un
  colpo d'occhio e che cambia colore quando qualcosa non va.

    verde   tutto in ordine
    giallo  funziona ma c'e' qualcosa da sapere (un'istanza giu', monitor mancanti)
    rosso   winfleet non puo' aprire niente

  Il suggerimento sotto il mouse dice CHE COSA, non "errore": "istanza 1 giu'"
  manda a guardare in un posto solo. Il menu col destro permette di riparare
  senza aprire un terminale.

  Non e' Sunshine: quello resta invisibile di proposito (system_tray = disabled in
  ogni istanza), perche' e' un dettaglio interno e vederne quattro nella barra
  confonderebbe e basta. Questa icona parla di winfleet.

  Cosa guarda, ogni 15 secondi:
    - le quattro istanze Sunshine (una porta ciascuna): chi non risponde e' uno
      schermo perso;
    - i monitor virtuali: senza, non si apre niente;
    - l'agente sulla porta 48088: senza, le finestre non si ridimensionano;
    - quante finestre sono in uso adesso.

.EXAMPLE
  powershell -File wf-tray.ps1
#>
[CmdletBinding()]
param(
  [int]$Slots = 4,
  [int]$SlotBase = 48089,
  [int]$AgentPort = 48088,
  # Ogni quanto ricontrollare. Quindici secondi: un guasto va visto entro il
  # tempo in cui uno ci riprova, non entro il minuto. Il controllo costa
  # millisecondi (sono richieste su localhost).
  [int]$OgniSecondi = 15
)

$ErrorActionPreference = 'Stop'
$LOG = 'C:\winfleet\tray.log'
function Note($m) { "$(Get-Date -f 'HH:mm:ss')  $m" | Add-Content $LOG -EA SilentlyContinue }

# trap a livello di script con "continue", non "break".
#
# Trappola gia' pagata in wf-vdd.ps1: "trap { break }" esce dal ciclo, cioe'
# TERMINA lo script - un errore banale e recuperabile uccideva il processo che
# tiene vivi i monitor. Qui varrebbe lo stesso: un singhiozzo di rete durante un
# controllo spegnerebbe l'icona, e l'unica cosa che dice se il sistema sta bene
# sparirebbe proprio quando serve.
trap { Note "ERRORE: $_"; continue }

Set-Content $LOG '' -EA SilentlyContinue
Note "avvio: $Slots finestre, base $SlotBase, agente $AgentPort"

# Una tray alla volta.
#
# Il task puo' essere rilanciato (al logon, a mano, dal guardiano) e ogni giro
# lascerebbe un'icona in piu' nella barra: quattro icone identiche che dicono la
# stessa cosa sono peggio di nessuna, perche' chi guarda pensa a un guasto.
$mio = $PID
# Per RIGA DI COMANDO, non per nome del processo: con "conhost --headless"
# (che i task usano per non lasciare console aperte sul desktop) il processo si
# chiama conhost.exe, e un filtro sul nome non lo vede. Gia' costato quattro
# monitor virtuali staccati e due pinger vivi insieme.
$mioPadre = (Get-CimInstance Win32_Process -Filter "ProcessId=$mio" -EA SilentlyContinue).ParentProcessId
Get-CimInstance Win32_Process -EA SilentlyContinue |
  Where-Object { $_.CommandLine -like '*wf-tray.ps1*' -and
                 $_.ProcessId       -ne $mio -and
                 $_.ProcessId       -ne $mioPadre -and
                 $_.ParentProcessId -ne $mio } |
  ForEach-Object {
    Note "c'e' gia' una tray (pid $($_.ProcessId)): la chiudo"
    Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
  }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- l'icona ---------------------------------------------------------------
# Disegnata qui invece che caricata da un file: un .ico in piu' e' un file che
# puo' mancare, e un'icona che non si carica fa fallire l'avvio della tray -
# cioe' proprio la cosa che deve dire se il resto funziona.
function Icona([System.Drawing.Color]$colore) {
  $bmp = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.Clear([System.Drawing.Color]::Transparent)
  # Una finestra stilizzata: cornice e barra del titolo. Si legge a 16x16, che
  # e' l'unica misura in cui questa icona verra' mai vista.
  $p = New-Object System.Drawing.Pen $colore, 2
  $b = New-Object System.Drawing.SolidBrush $colore
  $g.DrawRectangle($p, 2, 3, 12, 10)
  $g.FillRectangle($b, 2, 3, 13, 3)
  $g.Dispose(); $p.Dispose(); $b.Dispose()
  $h = $bmp.GetHicon()
  $ico = [System.Drawing.Icon]::FromHandle($h)
  # Si tiene l'handle per liberarlo dopo: le icone create cosi' NON vengono
  # raccolte dal garbage collector, e una nuova ogni quindici secondi
  # esaurirebbe le handle GDI nel giro di qualche giorno (limite 10.000 per
  # processo). Non e' teoria: e' il modo classico in cui una tray "sta su per
  # una settimana e poi sparisce".
  [PSCustomObject]@{ Icon = $ico; Handle = $h; Bitmap = $bmp }
}

$script:iconaViva = $null
function ImpostaIcona($tray, [System.Drawing.Color]$colore) {
  $nuova = Icona $colore
  $vecchia = $script:iconaViva
  $tray.Icon = $nuova.Icon
  $script:iconaViva = $nuova
  if ($vecchia) {
    $vecchia.Icon.Dispose()
    [void][Win32Tray]::DestroyIcon($vecchia.Handle)
    $vecchia.Bitmap.Dispose()
  }
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Tray {
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
}
'@

# --- i controlli -----------------------------------------------------------
# Una porta risponde? Mezzo secondo di pazienza: sono tutte su questo stesso PC,
# quindi o rispondono subito o non ci sono.
function PortaViva([int]$porta) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $r = $c.BeginConnect('127.0.0.1', $porta, $null, $null)
    if (-not $r.AsyncWaitHandle.WaitOne(500)) { return $false }
    $c.EndConnect($r); return $true
  } catch { return $false } finally { $c.Close() }
}

# Un'istanza e' occupata da uno stream? Lo dice lei, come al Mac.
function IstanzaInUso([int]$porta) {
  try {
    $w = New-Object Net.WebClient
    $x = $w.DownloadString("http://127.0.0.1:$porta/serverinfo?uniqueid=winfleet")
    return ($x -match 'BUSY')
  } catch { return $false }
}

function StatoMonitor {
  # Quanti monitor virtuali ci sono DAVVERO, chiedendolo a Windows.
  #
  # Non si legge vdd.json: quello dice cosa il driver ha chiesto, non cosa
  # esiste adesso. I monitor si staccano da soli quando il pinger smette (visto
  # succedere), e in quello stato il file continua a dire "4" mentre Windows ne
  # vede uno. Un controllo che legge le intenzioni invece dei fatti non e' un
  # controllo.
  try {
    $n = @([System.Windows.Forms.Screen]::AllScreens).Count
    # Uno e' il monitor fisico (o WinDisc a PC senza schermi): i virtuali sono
    # gli altri.
    return [Math]::Max(0, $n - 1)
  } catch { return -1 }
}

# --- il menu ---------------------------------------------------------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

function VoceMenu([string]$testo, [scriptblock]$azione) {
  $v = New-Object System.Windows.Forms.ToolStripMenuItem $testo
  if ($azione) { $v.add_Click($azione) } else { $v.Enabled = $false }
  $menu.Items.Add($v) | Out-Null
  return $v
}

# La prima voce e' il riepilogo: si legge aprendo il menu, senza aspettare il
# suggerimento del mouse.
$vRiepilogo = VoceMenu 'controllo in corso...' $null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

VoceMenu 'Riavvia le finestre che non rispondono' {
  # La riparazione che il doctor fa dal Mac, disponibile anche da qui: chi sta
  # usando il PC non deve andare a cercare un altro computer per rimettere in
  # piedi il proprio.
  for ($i = 0; $i -lt $script:Slots; $i++) {
    if (-not (PortaViva ($script:SlotBase + $i * 100))) {
      Note "menu: riavvio winfleet-sun$i"
      schtasks /end /tn "winfleet-sun$i" 2>&1 | Out-Null
      schtasks /run /tn "winfleet-sun$i" 2>&1 | Out-Null
    }
  }
  Controlla
} | Out-Null

VoceMenu 'Rifai i monitor virtuali' {
  Note 'menu: rifaccio i monitor virtuali'
  schtasks /end /tn winfleet-vdd 2>&1 | Out-Null
  schtasks /run /tn winfleet-vdd 2>&1 | Out-Null
  Controlla
} | Out-Null

VoceMenu 'Apri il registro (tray.log)' {
  Start-Process notepad.exe $LOG
} | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
VoceMenu 'Nascondi questa icona' {
  # "Esci" sarebbe una parola sbagliata: non chiude winfleet, che continua a
  # funzionare benissimo senza questa icona. Toglie solo l'icona.
  Note 'chiusa dal menu'
  $script:tray.Visible = $false
  [System.Windows.Forms.Application]::Exit()
} | Out-Null

# --- la tray ---------------------------------------------------------------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.ContextMenuStrip = $menu
$script:tray.Visible = $true
ImpostaIcona $script:tray ([System.Drawing.Color]::FromArgb(120,120,120))
$script:tray.Text = 'WinFleet: controllo in corso...'

# Lo stato precedente, per avvisare solo quando CAMBIA.
#
# Una notifica a ogni giro sarebbe rumore e verrebbe silenziata dopo un'ora;
# quella che arriva quando qualcosa peggiora davvero si legge.
$script:ultimo = ''

function Controlla {
  $giu = @()
  $inUso = 0
  for ($i = 0; $i -lt $script:Slots; $i++) {
    $porta = $script:SlotBase + $i * 100
    if (PortaViva $porta) {
      if (IstanzaInUso $porta) { $inUso++ }
    } else {
      $giu += ($i + 1)
    }
  }
  $agente = PortaViva $script:AgentPort
  $monitor = StatoMonitor

  # Il colore dice quanto e' grave, il testo dice cosa.
  $colore = [System.Drawing.Color]::FromArgb(40,170,80)      # verde
  $righe = @()
  $livello = 'ok'

  if ($giu.Count -ge $script:Slots) {
    # Nessuna finestra disponibile: winfleet non puo' aprire niente.
    $colore = [System.Drawing.Color]::FromArgb(210,60,50)    # rosso
    $livello = 'rotto'
    $righe += 'Nessuna finestra disponibile'
  } elseif ($giu.Count -gt 0) {
    $colore = [System.Drawing.Color]::FromArgb(230,160,30)   # giallo
    $livello = 'attenzione'
    $righe += "Finestra $($giu -join ', ') non risponde"
  }

  if ($monitor -lt $script:Slots -and $monitor -ge 0) {
    if ($livello -eq 'ok') { $colore = [System.Drawing.Color]::FromArgb(230,160,30); $livello = 'attenzione' }
    $righe += "$monitor monitor virtuali su $($script:Slots)"
  }
  if (-not $agente) {
    if ($livello -eq 'ok') { $colore = [System.Drawing.Color]::FromArgb(230,160,30); $livello = 'attenzione' }
    $righe += 'Agente non risponde (le finestre non si ridimensionano)'
  }

  if ($righe.Count -eq 0) {
    $libere = $script:Slots - $inUso
    $righe += "$libere finestre libere, $inUso in uso"
  }

  # Il suggerimento del mouse ha un limite di 63 caratteri: oltre, Windows lo
  # TRONCA in silenzio, e la parte tagliata e' proprio la spiegazione.
  $testo = "WinFleet - " + ($righe -join ' | ')
  if ($testo.Length -gt 63) { $testo = $testo.Substring(0, 60) + '...' }
  $script:tray.Text = $testo
  ImpostaIcona $script:tray $colore
  $vRiepilogo.Text = ($righe -join '  |  ')

  # Si avvisa solo quando lo stato PEGGIORA, e una volta sola.
  $ora = "$livello|$($righe -join ';')"
  if ($ora -ne $script:ultimo) {
    Note "stato: $livello - $($righe -join ' | ')"
    if ($livello -ne 'ok' -and $script:ultimo -notlike "$livello|*") {
      $script:tray.BalloonTipTitle = 'WinFleet'
      $script:tray.BalloonTipText = ($righe -join "`n")
      $script:tray.BalloonTipIcon = if ($livello -eq 'rotto') { 'Error' } else { 'Warning' }
      $script:tray.ShowBalloonTip(6000)
    }
    $script:ultimo = $ora
  }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $OgniSecondi * 1000
$timer.add_Tick({ Controlla })
$timer.Start()

# Un primo controllo subito: aspettare quindici secondi per sapere com'e' messo
# il sistema, appena acceso, e' proprio il momento in cui interessa di piu'.
Controlla

[System.Windows.Forms.Application]::Run()
