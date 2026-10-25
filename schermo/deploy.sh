#!/usr/bin/env bash
# Distribuisce lo schermo del PC e lo registra, oppure lo verifica con le prove vere.
#   deploy.sh            copia pagina, guardiano e interruttore in C:\winfleet, registra il task wf-schermo
#   deploy.sh verifica   prove sul PC vero: compare da fermo, niente veglia, GPU sotto il 5%, sparisce
#                        con uno stream e al primo tocco (exit 0 = tutte verdi)
#   deploy.sh off|on|status   interruttore (wf-schermo-ctl.ps1)
# Non scrive mai stato.js ed esiti.jsonl: sono dati di wf-autosleep.
set -u
HOST="${HOST_SSH:-zorah@192.168.1.2}"; IP="${HOST##*@}"
AQUI="$(cd "$(dirname "$0")" && pwd)"; HOSTDIR="$AQUI/../host"
S=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST")
PS='powershell -NoProfile -ExecutionPolicy Bypass -File'
ko() { echo "KO: $*" >&2; exit 1; }

deploy() {
  "${S[@]}" 'if not exist C:\winfleet\schermo\prova mkdir C:\winfleet\schermo\prova' >/dev/null || ko "PC irraggiungibile"
  scp -q "$HOSTDIR/wf-schermo.ps1" "$HOSTDIR/wf-schermo-ctl.ps1" "$HOSTDIR/wf-schermo-install.ps1" "$HOST:C:/winfleet/" || ko "scp script"
  # la pagina: index.html, i font e le istantanee di prova; mai stato.js ed esiti.jsonl
  scp -q "$AQUI/index.html" "$AQUI/stato-attesa.js" "$AQUI/stato-lavora.js" "$HOST:C:/winfleet/schermo/" || ko "scp pagina"
  scp -q -r "$AQUI/fonts" "$HOST:C:/winfleet/schermo/" || ko "scp font"
  scp -q "$AQUI/prova/"*.ps1 "$HOST:C:/winfleet/schermo/prova/" || ko "scp prove"
  # la sintassi si controlla sul PC, dove c'e' il parser giusto (PowerShell 5.1)
  for f in wf-schermo wf-schermo-ctl wf-schermo-install; do
    r=$("${S[@]}" "powershell -NoProfile -Command \"\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('C:\\winfleet\\$f.ps1',[ref]\$null,[ref]\$e); if(\$e){\$e|ForEach-Object{\$_.Message}; exit 1}\"") || ko "sintassi $f: $r"
  done
  "${S[@]}" "$PS C:\\winfleet\\wf-schermo-install.ps1" || ko "registrazione del task"
  echo "distribuito e registrato"
}

# righe di log nuove dal punto $1
nuove() { "${S[@]}" 'type C:\winfleet\schermo.log' 2>/dev/null | tr -d '\r' | tail -n +"$(( $1 + 1 ))"; }
righe() { "${S[@]}" 'type C:\winfleet\schermo.log' 2>/dev/null | tr -d '\r' | wc -l | tr -d ' '; }
attendi() { # attendi <da-riga> <regex> <secondi>
  local t=0; while [ $t -lt "$3" ]; do nuove "$1" | /usr/bin/grep -Eq "$2" && return 0; sleep 3; t=$((t + 3)); done; return 1
}
edge() { "${S[@]}" "$PS C:\\winfleet\\wf-schermo-ctl.ps1 status" | tr -d '\r' | sed -n 's/.*Edge schermo: \([0-9]*\).*/\1/p'; }

verifica() {
  local esito=0 T=$(mktemp -d); trap "rm -rf '$T'; \"\${S[@]}\" \"del C:\\\\winfleet\\\\schermo.secondi\" >/dev/null 2>&1" EXIT
  v() { if [ "$1" = ok ]; then echo "OK  $2"; else echo "KO  $2"; esito=1; fi; }
  # Partenza pulita: spento, soglia di prova scritta, POI acceso. Se la soglia arrivasse dopo `on` il
  # guardiano partirebbe con 300 s; e il punto di partenza del log si prende prima di accendere,
  # cosi' «mostro la schermata» non puo' arrivare prima che lo si cerchi.
  "${S[@]}" "$PS C:\\winfleet\\wf-schermo-ctl.ps1 off" >/dev/null
  echo 20 > "$T/s"; scp -q "$T/s" "$HOST:C:/winfleet/schermo.secondi"
  local L0; L0=$(righe)
  "${S[@]}" "$PS C:\\winfleet\\wf-schermo-ctl.ps1 on" >/dev/null
  attendi "$L0" 'avviato \(soglia 20 s\)' 30 && v ok "guardiano partito con la soglia di prova (20 s)" || v ko "il guardiano non e' partito con soglia 20 s"
  "${S[@]}" "$PS C:\\winfleet\\wf-schermo-ctl.ps1 status" | tr -d '\r'
  # 1. compare da ferma
  if attendi "$L0" 'mostro la schermata' 150; then v ok "compare con l'input fermo (soglia di prova 20 s)"; else v ko "non e' comparsa in 150 s"; fi
  sleep 20; [ "$(edge)" -ge 1 ] 2>/dev/null && v ok "Edge dello schermo in esecuzione" || v ko "Edge dello schermo assente"
  # 2. niente veglia e GPU: un minuto di letture
  local M; M=$("${S[@]}" "$PS C:\\winfleet\\schermo\\prova\\misura.ps1" | tr -d '\r' | tail -1); echo "    $M"
  echo "$M" | /usr/bin/grep -q '"req":\[\]' && v ok "nessuna richiesta di alimentazione che tenga sveglio (SYSTEM/AWAYMODE/EXECUTION)" || v ko "richiesta di alimentazione presente"
  local med; med=$(echo "$M" | sed -n 's/.*"gpuMed":\([0-9]*\).*/\1/p'); [ -n "$med" ] && [ "$med" -le 5 ] && v ok "GPU mediana ${med}% (<= 5)" || v ko "GPU mediana ${med:-?}%"
  local cpu; cpu=$(echo "$M" | sed -n 's/.*"cpuTop":{[^}]*"c":\([0-9.]*\).*/\1/p'); [ -n "$cpu" ] && awk "BEGIN{exit !($cpu < 0.5)}" && v ok "processo piu' pesante ${cpu} core (< 0,5)" || v ko "processo piu' pesante ${cpu:-?} core"
  # 3. stream: due connessioni TCP tenute aperte dal Mac verso Sunshine (la stessa regola di wf-autosleep)
  local L1; L1=$(righe)
  ( sleep 45 | nc "$IP" 47989 ) >/dev/null 2>&1 & ( sleep 45 | nc "$IP" 47984 ) >/dev/null 2>&1 &
  if attendi "$L1" 'nascosta: stream' 20; then v ok "sparisce con uno stream"; else v ko "non e' sparita con lo stream"; fi
  [ "$(edge)" = 0 ] && v ok "Edge chiuso durante lo stream" || v ko "Edge ancora aperto durante lo stream"
  sleep 3; local L2; L2=$(righe)
  # senza stream non deve restare nascosta per sempre: riappare (il Mac rilascia le connessioni dopo 45 s)
  if attendi "$L1" 'mostro la schermata' 120; then v ok "senza stream ricompare"; else v ko "non e' ricomparsa dopo lo stream"; fi
  # 4. primo tocco
  local L3; L3=$(righe); sleep 5
  "${S[@]}" "$PS C:\\winfleet\\schermo\\prova\\lancia-tocco.ps1" | tr -d '\r'
  if attendi "$L3" 'nascosta: input' 15; then v ok "sparisce al primo tocco"; else v ko "non e' sparita al tocco"; fi
  [ "$(edge)" = 0 ] && v ok "Edge chiuso dopo il tocco" || v ko "Edge ancora aperto dopo il tocco"
  # 5. non torna subito: dopo il tocco serve quiete piena
  sleep 8; [ "$(edge)" = 0 ] && v ok "non ricompare subito dopo il tocco (soglia 20 s)" || v ko "ricomparsa troppo presto"
  return $esito
}

# Il PC dorme ancora con la schermata accesa: soglia di autosleep a 3 minuti, nessuna sessione ssh
# (conta come uso), schermata mostrata; il PC deve addormentarsi entro 10 minuti. Poi lo si sveglia
# e si toglie la soglia di prova.
sonno() {
  local i
  "${S[@]}" '(echo 3)> C:\winfleet\autosleep.minutes' >/dev/null || ko "soglia di prova"
  "${S[@]}" '(echo 20)> C:\winfleet\schermo.secondi' >/dev/null  # la schermata compare dopo 20 s, prima del sonno a 3 min
  "${S[@]}" "$PS C:\\winfleet\\wf-schermo-ctl.ps1 on" >/dev/null
  echo "soglia 3 min scritta, lascio il PC: $(date +%T)"
  for i in $(seq 1 20); do sleep 30; [ "$(pc-state | sed -n 's/.*"pc":"\([a-z]*\)".*/\1/p')" = dorme ] && { echo "OK  il PC dorme (dopo ~$((i / 2)) min) con la schermata accesa"; pc-wake >/dev/null 2>&1; "${S[@]}" 'del C:\winfleet\autosleep.minutes C:\winfleet\schermo.secondi' >/dev/null; return 0; }; done
  pc-wake >/dev/null 2>&1; "${S[@]}" 'del C:\winfleet\autosleep.minutes C:\winfleet\schermo.secondi' >/dev/null
  echo "KO  il PC non si e' addormentato in 10 min"; return 1
}

case "${1:-deploy}" in
  sonno) sonno ;;
  barra) "${S[@]}" "$PS C:\\winfleet\\schermo\\prova\\barra.ps1" | tr -d '\r'; exit ${PIPESTATUS[0]} ;;
  deploy) deploy ;;
  verifica) verifica ;;
  off|on|status) "${S[@]}" "$PS C:\\winfleet\\wf-schermo-ctl.ps1 $1" ;;
  *) echo "uso: $0 [deploy|verifica|off|on|status]"; exit 64 ;;
esac
