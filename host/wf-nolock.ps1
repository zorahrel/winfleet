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

# 5. Il prompt UAC sul desktop NORMALE, non sul "secure desktop"
#
# E' il difetto piu' insidioso di tutti, perche' non somiglia a un difetto.
# Quando Windows chiede "consenti a questa app di apportare modifiche", per
# impostazione predefinita disegna quel prompt su un DESKTOP SEPARATO (il
# secure desktop): un desktop che Sunshine non cattura e che quindi non arriva
# mai nello stream. Da qui il sintomo, visto dal vivo il 26/08: la finestra
# smette di rispondere ai click, e nessuna finestra winfleet mostra il perche'.
# Il PC intero e' fermo in attesa di una risposta a una domanda invisibile.
#
# Peggio: l'unico modo di rispondere e' sedersi davanti al monitor fisico, che
# e' esattamente cio' che winfleet esiste per evitare. E il blocco non e'
# limitato alla finestra che ha causato il prompt - il secure desktop prende
# l'input di TUTTO il sistema, quindi si fermano anche Parsec e le altre
# finestre.
#
# PromptOnSecureDesktop=0 lascia il prompt sul desktop normale: si vede nello
# stream e ci si puo' cliccare. Il prompt resta - non si sta disabilitando UAC
# (EnableLUA e ConsentPromptBehaviorAdmin non si toccano): si sta solo
# chiedendo a Windows di disegnarlo dove qualcuno puo' vederlo.
Set-ItemProperty $p PromptOnSecureDesktop 0 -Type DWord

Write-Output 'blocco automatico disattivato'
Write-Output 'prompt UAC: sul desktop normale (visibile nello stream)'
Write-Output ('monitor-timeout: ' + ((powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'CA corrente') -replace '.*:\s*',''))
