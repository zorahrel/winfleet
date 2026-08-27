# Fa in modo che l'icona di winfleet si VEDA nella barra, invece di finire
# nel cassetto nascosto.
#
# Windows 11 mette ogni icona nuova nell'overflow (la freccetta "^"): resta
# viva, risponde, cambia colore, e non la guarda nessuno. Per un'icona il cui
# unico scopo e' dire "guarda qui, c'e' un problema" e' come non averla:
# verificato fotografando l'area di notifica dopo aver avviato la tray - zero
# pixel colorati, l'icona era nell'overflow.
#
# La preferenza sta in HKCU:\Control Panel\NotifyIconSettings, una chiave per
# icona, con IsPromoted=1 per quelle mostrate. La chiave giusta si riconosce
# dall'ExecutablePath: qui e' powershell.exe, perche' la tray e' uno script.
$base = 'HKCU:\Control Panel\NotifyIconSettings'
if (-not (Test-Path $base)) { throw "non trovo $base (Windows troppo vecchio?)" }

$fatte = 0
Get-ChildItem $base | ForEach-Object {
  $p = Get-ItemProperty -Path $_.PSPath
  # Il percorso nel registro usa il GUID della cartella di sistema, non
  # "C:\Windows\...": si cerca il nome dell'eseguibile, che c'e' in entrambi.
  if ("$($p.ExecutablePath)" -like '*powershell.exe') {
    Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -Type DWord
    $fatte++
  }
}
if ($fatte -eq 0) {
  # Nessuna voce: la tray non e' ancora mai partita, quindi Windows non l'ha
  # registrata. Non e' un errore da urlare, ma va detto: chi ha lanciato questo
  # comando si aspetta di vedere un'icona.
  'nessuna icona powershell registrata: avvia prima la tray (schtasks /run /tn winfleet-tray)'
} else {
  # Explorer legge questa preferenza all'avvio: senza riavviarlo, la modifica
  # c'e' nel registro e non si vede sullo schermo - cioe' esattamente il guasto
  # che si sta curando.
  Stop-Process -Name explorer -Force -EA SilentlyContinue
  Start-Sleep -Seconds 3
  if (-not (Get-Process explorer -EA SilentlyContinue)) { Start-Process explorer.exe }
  "promosse $fatte icone, Explorer riavviato"
}
