# Impedisce che la sessione si blocchi da sola: quando Windows blocca lo schermo la
# sessione grafica si riduce, i monitor virtuali smettono di disegnare e winfleet
# mostra rettangoli neri. E' il difetto che rende il sistema inutilizzabile appena
# ci si allontana dalla scrivania.
$ErrorActionPreference = 'Continue'

# 1. Niente spegnimento schermo / sospensione a corrente
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0

# 2. Niente screensaver e niente richiesta password al risveglio
New-Item -Path 'HKCU:\Control Panel\Desktop' -Force | Out-Null
Set-ItemProperty 'HKCU:\Control Panel\Desktop' ScreenSaveActive     '0'
Set-ItemProperty 'HKCU:\Control Panel\Desktop' ScreenSaverIsSecure  '0'
Set-ItemProperty 'HKCU:\Control Panel\Desktop' ScreenSaveTimeOut    '0'

# 3. Niente blocco automatico dopo inattivita' (criterio di sistema)
$p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
New-Item -Path $p -Force | Out-Null
Set-ItemProperty $p InactivityTimeoutSecs 0 -Type DWord

# 4. Niente password al risveglio dalla sospensione
powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
powercfg /setactive SCHEME_CURRENT

Write-Output 'blocco automatico disattivato'
Write-Output ('monitor-timeout: ' + ((powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'CA corrente') -replace '.*:\s*',''))
