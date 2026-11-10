# Il PC deve tornare raggiungibile da solo dopo un riavvio, senza mani sopra.
# Perche': il 10/11 un riavvio (tampone per il pool paginato) l'ha lasciato fermo
# all'accesso, senza sshd ne' Tailscale: 8 card bloccate e un gesto fisico chiesto
# ad Attilio.
#
# -Cura   mette a posto cio' che si puo' mettere da qui (serve PowerShell elevato,
#         lo e' gia' quello di ssh): sshd e Tailscale automatici e avviati,
#         Tailscale unattended (resta collegato anche senza nessuno loggato).
# senza   solo il controllo: stampa OK/KO per voce, exit 1 se una non regge al boot.
# L'accesso automatico non serve: nodo e gabbia partono al boot come S4U.
param([switch]$Cura)
$ko = @()
function Check($nome, $ok, $perche) { if ($ok) { "OK  $nome" } else { "KO  ${nome}: $perche"; $script:ko += $nome } }

foreach ($svc in 'sshd', 'Tailscale') {
  $s = Get-Service $svc -ErrorAction SilentlyContinue
  if (-not $s) { Check $svc $false 'servizio assente'; continue }
  if ($Cura) {
    Set-Service $svc -StartupType Automatic
    # il ritardato parte dopo ~2 minuti dal boot e puo' perdere la gara con chi lo cerca
    sc.exe config $svc start= auto | Out-Null
    if ($s.Status -ne 'Running') { Start-Service $svc }
    sc.exe failure $svc reset= 86400 actions= restart/5000/restart/30000/restart/60000 | Out-Null
  }
  $s = Get-CimInstance Win32_Service -Filter "Name='$svc'"
  Check "$svc avvio automatico" ($s.StartMode -eq 'Auto' -and -not $s.DelayedAutoStart) "StartMode=$($s.StartMode) ritardato=$($s.DelayedAutoStart)"
  Check "$svc in esecuzione" ($s.State -eq 'Running') $s.State
}

$ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (Test-Path $ts) {
  if ($Cura) { & $ts set --unattended=true 2>&1 | Out-Null }
  $prefs = & $ts debug prefs 2>$null | Out-String
  Check 'Tailscale unattended' ($prefs -match '"ForceDaemon":\s*true') 'senza unattended si stacca quando nessuno e'' loggato'
}

# firewall: la 22 aperta anche su rete Pubblica (dopo un riavvio la rete puo' cambiare profilo)
$fw = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($Cura -and $fw) { Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Profile Any -Enabled True }
$fw = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
Check 'firewall 22 su ogni profilo' ($fw -and $fw.Enabled -eq 'True' -and "$($fw.Profile)" -eq 'Any') "regola $(if ($fw) { "$($fw.Profile)/$($fw.Enabled)" } else { 'assente' })"

# nodo al boot senza accesso: topics-nodo e topics-card-jail girano S4U all'avvio, cosi'
# l'accesso automatico (e la password di Attilio) non serve piu'.
foreach ($t in 'topics-nodo', 'topics-card-jail') {
  $st = Get-ScheduledTask $t -ErrorAction SilentlyContinue
  $boot = $st -and ($st.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
  Check "nodo parte al boot senza accesso ($t)" ($boot -and $st.Principal.LogonType -eq 'S4U') "trigger/LogonType: $(if ($st) { "$($st.Triggers.CimClass.CimClassName) $($st.Principal.LogonType)" } else { 'task assente' }) (registra-nodo.ps1 / registra-card-jail.ps1)"
}
if ($ko.Count) { exit 1 }
