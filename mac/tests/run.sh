#!/bin/bash
# Prova le due cose che la libreria iniettata deve garantire, senza bisogno dei
# permessi di Accessibilita' (che servirebbero per muovere davvero un mouse) e
# senza un PC Windows acceso.
#
#   ./mac/tests/run.sh
#
# 1. TRASCINAMENTO. Il click sulla barra del titolo deve muovere la finestra del
#    MAC, non finire dentro Windows. Il test riproduce la condizione vera - una
#    vista che copre tutta la finestra e ingoia i mouseDown, come fa SDL - e gira
#    DUE volte: senza libreria deve FALLIRE, con libreria deve PASSARE. Se
#    passasse in entrambi i casi non proverebbe nulla: e' esattamente l'errore in
#    cui e' caduta la prima versione di questo test.
#
# 2. RIDUCI A ICONA. Minimizzando e ripristinando la finestra sul Mac, la libreria
#    deve chiamare /show sull'agente. Qui l'agente e' finto e registra le
#    richieste, cosi' si vede l'ordine esatto: prima min, poi restore.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

LIB="${WF_TEST_LIB:-$HOME/.config/winfleet/wf-chrome.dylib}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill "${AGENT_PID:-0}" 2>/dev/null' EXIT

fail=0
say() { printf '%s\n' "$*"; }

clang -dynamiclib -framework Cocoa -framework Foundation -o "$TMP/wf-chrome.dylib" mac/wf-chrome.m || exit 1
[ -n "${WF_TEST_LIB:-}" ] || LIB="$TMP/wf-chrome.dylib"

# --- 1. trascinamento -------------------------------------------------------
clang -framework Cocoa -o "$TMP/drag" mac/tests/drag-titlebar.m 2>/dev/null || exit 1

without="$("$TMP/drag" 2>&1 | grep -o 'ESITO_BARRA: [A-Z]*' | awk '{print $2}')"
# WF_FORCE_DRAG: il test sintetizza un click ma non puo' muovere il mouse fisico,
# e la libreria - giustamente - tratta un premi-e-rilascia fermo come un click
# sull'app, non come un trascinamento (senza, la barra degli indirizzi di certe
# app diventa incliccabile). Si forza quindi la sola parte non simulabile, e si
# verifica tutto il resto della catena.
with="$(DYLD_INSERT_LIBRARIES="$LIB" WF_WIN=600x400 WF_FORCE_DRAG=1 "$TMP/drag" 2>&1 | grep -o 'ESITO_BARRA: [A-Z]*' | awk '{print $2}')"
video="$(DYLD_INSERT_LIBRARIES="$LIB" WF_WIN=600x400 WF_FORCE_DRAG=1 "$TMP/drag" 2>&1 | grep -o 'ESITO_VIDEO: [A-Z]*' | awk '{print $2}')"

if [ "$without" = FAIL ] && [ "$with" = PASS ]; then
  say "ok   barra: senza libreria finisce in Windows, con libreria trascina il Mac"
else
  say "NO   barra: senza=$without con=$with (servono FAIL e PASS: se sono uguali il test non discrimina)"
  fail=1
fi

if [ "$video" = PASS ]; then
  say "ok   video: il click dentro l'app arriva comunque a Windows"
else
  say "NO   video: il click nell'area video non arriva all'app ($video)"
  fail=1
fi

# --- 2. riduci a icona ------------------------------------------------------
clang -framework Cocoa -o "$TMP/mini" mac/tests/minimize-sync.m 2>/dev/null || exit 1

PORT=48099
python3 - "$PORT" >"$TMP/agent.log" 2>&1 <<'PY' &
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print(self.path, flush=True)
        self.send_response(200); self.send_header('Content-Length','2'); self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H) as s:
    s.serve_forever()
PY
AGENT_PID=$!
sleep 1

DYLD_INSERT_LIBRARIES="$LIB" WF_WIN=400x300 WF_AGENT="127.0.0.1:$PORT" WF_SLOT=1 "$TMP/mini" >/dev/null 2>&1
sleep 0.5
got="$(grep -o 'how=[a-z]*' "$TMP/agent.log" | awk -F= '{print $2}' | tr '\n' ' ')"
if [ "$got" = "min restore " ]; then
  say "ok   icona: la libreria dice a Windows di minimizzare e poi di tornare"
else
  say "NO   icona: chiamate ricevute [$got], attese [min restore ]"
  fail=1
fi

# --- 3. aritmetica del ritaglio ------------------------------------------
# Durante il resize la finestra sul Mac cresce prima della finestra su Windows.
# In quell'istante il rettangolo mostrato non deve MAI eccedere quello che
# Windows ha confermato (si vedrebbe il desktop) ne' avere una forma diversa
# dalla finestra (comparirebbero bande nere ai lati).
clang -o "$TMP/crop" mac/tests/crop-arithmetic.c 2>/dev/null || exit 1
if "$TMP/crop" > "$TMP/crop.out" 2>&1; then
  say "ok   ritaglio: mai desktop scoperto, mai bande, in tutti i casi provati"
else
  say "NO   ritaglio:"
  sed 's/^/       /' "$TMP/crop.out"
  fail=1
fi

# --- 4. slot bloccati -----------------------------------------------------
# Una sessione Sunshine appesa lascia lo slot "occupato" senza che ci sia una
# finestra: da li' in poi niente finestra calda e le aperture tornano lente.
# Qui si verifica che vengano liberati SOLO gli slot bloccati che non sono
# nostri: chiudere una sessione viva spegnerebbe l'app di qualcuno.
if /opt/homebrew/bin/bash mac/tests/reap-stuck-slots.sh 2>/dev/null | grep -q PASS; then
  say "ok   slot bloccati: libera quelli appesi, non tocca quelli in uso"
else
  say "NO   slot bloccati: la selezione non e' corretta"
  fail=1
fi

# --- 5. Cmd+W ---------------------------------------------------------------
# Cmd+W deve chiudere la finestra del MAC, non finire dentro Windows a chiudere
# la scheda del browser remoto. E il resto della tastiera deve continuare ad
# arrivare all'app: intercettare ogni Cmd romperebbe copia, incolla e nuova
# scheda per far funzionare una scorciatoia.
clang -framework Cocoa -o "$TMP/keys" mac/tests/close-shortcut.m 2>/dev/null || exit 1
kw_without="$("$TMP/keys" 2>&1 | grep -o 'ESITO_CMDW: [A-Z]*' | awk '{print $2}')"
kw_with="$(DYLD_INSERT_LIBRARIES="$LIB" WF_WIN=600x400 "$TMP/keys" 2>&1 | grep -o 'ESITO_CMDW: [A-Z]*' | awk '{print $2}')"
kt="$(DYLD_INSERT_LIBRARIES="$LIB" WF_WIN=600x400 "$TMP/keys" 2>&1 | grep -o 'ESITO_CMDT: [A-Z]*' | awk '{print $2}')"
ks="$(DYLD_INSERT_LIBRARIES="$LIB" WF_WIN=600x400 "$TMP/keys" 2>&1 | grep -o 'ESITO_CMDSHIFTW: [A-Z]*' | awk '{print $2}')"
if [ "$kw_without" = FAIL ] && [ "$kw_with" = PASS ] && [ "$kt" = PASS ] && [ "$ks" = PASS ]; then
  say "ok   Cmd+W: chiude la finestra del Mac, e Cmd+T/Cmd+Shift+W restano all'app"
else
  say "NO   Cmd+W: senza=$kw_without con=$kw_with  CmdT=$kt  CmdShiftW=$ks"
  fail=1
fi

# --- 6. proporzioni dell'icona ---------------------------------------------
# Un'icona non quadrata non deve uscire stirata, e il badge di Windows deve
# esserci su tutte: sono le due cose che si notano nel Dock a colpo d'occhio.
if python3 mac/tests/icon-aspect.py > "$TMP/icon.out" 2>&1; then
  say "ok   icone: nessuna deformazione, badge presente in tutte le forme"
else
  say "NO   icone:"
  sed 's/^/       /' "$TMP/icon.out"
  fail=1
fi

# --- 7. scambio dell'app su una finestra calda ------------------------------
# Aprire un'app deve mostrare QUELLA app: se la finestra sul monitor e' rimasta
# quella di prima lo scambio non e' avvenuto, e dichiararlo riuscito significa
# mostrare il Blocco note con l'icona di Arc.
if /opt/homebrew/bin/bash mac/tests/swap-window.sh > "$TMP/swap.out" 2>&1; then
  say "ok   scambio app: riuscito solo se la finestra e' davvero cambiata"
else
  say "NO   scambio app:"
  sed 's/^/       /' "$TMP/swap.out"
  fail=1
fi

# --- 8. finestre calde ------------------------------------------------------
# Due finestre calde non possono usare la stessa app: sono a istanza singola e
# la seconda chiuderebbe la prima. E si contano da AVVIATE, non da pronte, o se
# ne prepara una di troppo a ogni giro.
if /opt/homebrew/bin/bash mac/tests/warm-windows.sh > "$TMP/warm.out" 2>&1; then
  say "ok   finestre calde: app diverse, quantita' giusta, nessuna marcata a vuoto"
else
  say "NO   finestre calde:"
  sed 's/^/       /' "$TMP/warm.out"
  fail=1
fi

# --- 9. istanze mute -------------------------------------------------------
# Un'istanza Sunshine che non risponde non e' un'istanza occupata: contarla come
# tale ha tenuto il rifornitore fermo quaranta minuti con tutti gli slot vuoti,
# e ogni apertura tornava a costare quindici secondi senza un errore visibile.
if /opt/homebrew/bin/bash mac/tests/slot-free.sh > "$TMP/slotfree.out" 2>&1; then
  say "ok   slot muti: contano come disponibili, gli occupati no"
else
  say "NO   slot muti:"
  sed 's/^/       /' "$TMP/slotfree.out"
  fail=1
fi

# --- 10. nome della finestra ------------------------------------------------
# Una finestra tenuta calda nasce col bundle dell'app usata per scaldarla: se il
# nome non si aggiorna, nel Dock compaiono tre "Blocco note" che sono tre app
# diverse - e sembra che si siano aperte da sole delle app a caso.
clang -framework Cocoa -o "$TMP/wname" mac/tests/window-name.m 2>/dev/null || exit 1
# Il file va riscritto PRIMA DI OGNI giro: il test stesso, alla fine, ci mette
# "::pronto::" per provare la seconda proprieta', e il giro dopo leggerebbe
# quello invece del nome dell'app.
printf 'Arc\n' > "$TMP/name.txt"
nm_without="$(WF_NAME="$TMP/name.txt" "$TMP/wname" 2>&1 | grep -o 'ESITO_NOME: [A-Z]*' | awk '{print $2}')"
printf 'Arc\n' > "$TMP/name.txt"
nm_with="$(DYLD_INSERT_LIBRARIES="$LIB" WF_NAME="$TMP/name.txt" WF_WIN=600x400 "$TMP/wname" 2>&1 | grep -o 'ESITO_NOME: [A-Z]*' | awk '{print $2}')"
if [ "$nm_without" = FAIL ] && [ "$nm_with" = PASS ]; then
  say "ok   nome: la finestra prende il nome dell'app che ci sta dentro"
else
  say "NO   nome: senza=$nm_without con=$nm_with (servono FAIL e PASS)"
  fail=1
fi

# E la parte che l'utente vede per prima: una finestra di scorta non deve
# comparire nel Dock. Ne comparivano tre, col nome dell'app usata per scaldarle.
printf 'Arc\n' > "$TMP/name.txt"
sc_without="$(WF_NAME="$TMP/name.txt" "$TMP/wname" 2>&1 | grep -o 'ESITO_SCORTA: [A-Z]*' | awk '{print $2}')"
printf 'Arc\n' > "$TMP/name.txt"
sc_with="$(DYLD_INSERT_LIBRARIES="$LIB" WF_NAME="$TMP/name.txt" WF_WIN=600x400 "$TMP/wname" 2>&1 | grep -o 'ESITO_SCORTA: [A-Z]*' | awk '{print $2}')"
if [ "$sc_without" = FAIL ] && [ "$sc_with" = PASS ]; then
  say "ok   scorta: le finestre tenute pronte restano fuori dal Dock"
else
  say "NO   scorta: senza=$sc_without con=$sc_with (servono FAIL e PASS)"
  fail=1
fi

# --- 11. icone: badge e allineamento ---------------------------------------
# Il badge di Windows e' cio' che distingue una finestra remota da un'app del
# Mac, e il runner e' l'icona che si vede mentre l'app e' APERTA: due posti dove
# un'icona sbagliata resta per giorni senza che niente la segnali.
if /opt/homebrew/bin/bash mac/tests/icon-badge.sh > "$TMP/icb.out" 2>&1; then
  say "ok   icone reali: badge presente, runner e lanciatori allineati e firmati"
else
  say "NO   icone reali:"
  sed 's/^/       /' "$TMP/icb.out"
  fail=1
fi

# --- 10b. Cmd+W passa dal menu, come in un'app nativa ----------------------
# Il monitor sugli eventi non basta e non e' mai bastato: AppKit manda i tasti
# prima a performKeyEquivalent: della barra dei menu, e solo quello che avanza
# arriva ai monitor locali. Verificato dal vivo su Arc, con la finestra a fuoco
# confermato: il monitor non e' scattato una sola volta. La strada giusta e'
# quella di qualsiasi app del Mac - una voce nel menu Finestra con la sua
# scorciatoia.
clang -framework Cocoa -Wno-deprecated-declarations -o "$TMP/menukey" mac/tests/menu-shortcut.m 2>/dev/null || exit 1
if "$TMP/menukey" > "$TMP/menukey.out" 2>&1; then
  say "ok   menu: Cmd+W e Cmd+M nel menu Finestra, Cmd+T e Cmd+Shift+W all'app"
else
  say "NO   menu:"
  sed 's/^/       /' "$TMP/menukey.out"
  fail=1
fi

# --- 10b-bis. Cmd+W in una finestra VERA -----------------------------------
# Il test del menu gira in un processo di prova e dice che la voce e' collegata
# bene. Non diceva se, dentro un Moonlight vero, quella voce chiude davvero: il
# delegate di SDL rifiuta windowShouldClose:, quindi performClose: non chiudeva
# niente e lo stream finiva per una strada sua 4.6 secondi dopo. Ora 0.14s.
if /opt/homebrew/bin/bash mac/tests/cmdw-live.sh > "$TMP/cmdwlive.out" 2>&1; then
  say "ok   Cmd+W dal vivo: $(grep -o 'si chiude in .*' "$TMP/cmdwlive.out" | head -1)"
else
  say "NO   Cmd+W dal vivo:"
  sed 's/^/       /' "$TMP/cmdwlive.out"
  fail=1
fi

# --- 10c. app che non apre nessuna finestra --------------------------------
# La finestra di Moonlight si apre SEMPRE, anche quando su Windows non e'
# partito niente: si aspettavano 45 secondi e poi altri 20, cioe' 56 misurati,
# per dire una cosa che l'host sapeva dopo 35. Trovato con la Calcolatrice, che
# su quel PC e' rotta e non apre finestre comunque la si lanci.
if /opt/homebrew/bin/bash mac/tests/no-window.sh > "$TMP/nowin.out" 2>&1; then
  say "ok   app senza finestra: lo si scopre subito, non dopo un minuto"
else
  say "NO   app senza finestra:"
  sed 's/^/       /' "$TMP/nowin.out"
  fail=1
fi

# --- 10c-ter. l'agente sull'host che smette di rispondere ------------------
# Tre volte in un pomeriggio: processo vivo, porta in ascolto, ogni richiesta
# che scade. Da fuori sembra un PC spento. La causa probabile e' corretta ma non
# dimostrata, quindi oltre al fix c'e' una rete: se non risponde, si riavvia.
if /opt/homebrew/bin/bash mac/tests/agent-revive.sh > "$TMP/revive.out" 2>&1; then
  say "ok   agente host: se smette di rispondere, torna da solo"
else
  say "NO   agente host:"
  sed 's/^/       /' "$TMP/revive.out"
  fail=1
fi

# --- 10c-bis. col PC spento ------------------------------------------------
# "winfleet open" con l'host irraggiungibile usciva con codice ZERO e senza una
# riga di output: una pipe con pipefail (curl esce 28) terminava il comando a
# meta', prima del messaggio. Uno script che ne guarda l'esito andava avanti
# convinto.
if /opt/homebrew/bin/bash mac/tests/host-down.sh > "$TMP/hostdown.out" 2>&1; then
  say "ok   PC spento: lo dice ed esce con errore, invece di fingere"
else
  say "NO   PC spento:"
  sed 's/^/       /' "$TMP/hostdown.out"
  fail=1
fi

# --- 10c-bis. il nome sotto l'icona ----------------------------------------
# Aprendo un'app su una finestra CALDA, nel Dock compariva il nome della scorta:
# "Armoury Crate" si leggeva "Finestra WinFleet". Il file del nome e il titolo
# della finestra erano gia' giusti - era la scheda che LaunchServices tiene per
# ogni processo vivo a restare quella del bundle di partenza.
if /opt/homebrew/bin/bash mac/tests/dock-name.sh > "$TMP/dockname.out" 2>&1; then
  say "ok   nome nel Dock: l'app riusata mostra il proprio, non quello della scorta"
else
  say "NO   nome nel Dock:"
  sed 's/^/       /' "$TMP/dockname.out"
  fail=1
fi

# --- 10d. il comando che chiude -------------------------------------------
# "winfleet stop Paint" moriva con «Paint: unbound variable» e non chiudeva
# niente: l'argomento finiva in un'espressione aritmetica. Era li' dal primo
# commit, perche' i test guardavano sempre l'apertura e mai la chiusura.
if /opt/homebrew/bin/bash mac/tests/stop-cmd.sh > "$TMP/stop.out" 2>&1; then
  say "ok   chiusura: stop funziona col nome dell'app, non solo col numero"
else
  say "NO   chiusura:"
  sed 's/^/       /' "$TMP/stop.out"
  fail=1
fi

# --- 11. due aperture insieme ----------------------------------------------
# Successo dal vivo: due "winfleet open" a pochi secondi l'uno dall'altro hanno
# messo Paint e Arc sulla STESSA istanza. Chi aveva chiesto Paint si e' visto
# aprire Arc, e il primo processo e' rimasto orfano - senza un solo messaggio di
# errore, perche' formalmente non era successo niente di illegale.
if /opt/homebrew/bin/bash mac/tests/slot-race.sh > "$TMP/race.out" 2>&1; then
  say "ok   due aperture insieme: finestre diverse, nessuna sovrascritta"
else
  say "NO   due aperture insieme:"
  sed 's/^/       /' "$TMP/race.out"
  fail=1
fi

# --- 11a. pairing rimasto a meta' ------------------------------------------
# L'host aveva gia' il nostro certificato ma il Mac aveva perso il suo: da fuori
# identico a "mai accoppiata", e la finestra si apre VUOTA. Due su quattro sono
# rimaste cosi' per giorni, col sintomo visibile altrove - le finestre figlie
# restavano su Windows con "nessuno slot libero" mentre due slot erano liberi,
# perche' uno slot spaiato non conta come disponibile.
if /opt/homebrew/bin/bash mac/tests/pair-auto.sh > "$TMP/pair.out" 2>&1; then
  say "ok   pairing: se l'host ci conosce gia', si ripara senza chiedere un PIN"
else
  say "NO   pairing:"
  sed 's/^/       /' "$TMP/pair.out"
  fail=1
fi

# --- 11b. il rifornitore delle finestre pronte -----------------------------
# L'agente launchd si era scaricato da solo ("service inactive" nei log, nessun
# riavvio del Mac). Senza danno visibile finche' la scorta resta spenta
# (WF_WARM=0), ma riaccenderla senza agente vuol dire scorta sempre a zero:
# quindici secondi ad apertura invece di due. Il plist era installato a mano,
# quindi una volta perso restava perso.
if /opt/homebrew/bin/bash mac/tests/ready-agent.sh > "$TMP/ready.out" 2>&1; then
  say "ok   rifornitore: se l'agente sparisce, torna da solo"
else
  say "NO   rifornitore:"
  sed 's/^/       /' "$TMP/ready.out"
  fail=1
fi

# --- 12. posizione del mouse col ritaglio -----------------------------------
# Il click deve cadere dove punti, a qualunque misura della finestra. Il conto
# del rettangolo video partiva dalla forma dello schermo remoto invece che da
# quella del ritaglio: fino a 210 pixel di errore, nullo al centro e sui bordi e
# massimo in mezzo - per questo sembrava capriccioso.
clang -O2 -o "$TMP/mousemap" mac/tests/mouse-mapping.c 2>/dev/null || exit 1
if "$TMP/mousemap" > "$TMP/mousemap.out" 2>&1; then
  say "ok   mouse: il click cade dove punti, a ogni misura della finestra"
else
  say "NO   mouse:"
  sed 's/^/       /' "$TMP/mousemap.out"
  fail=1
fi

# --- 13. finestre aperte da un'altra app ------------------------------------
# Da Arc si clicca "scarica" e Windows apre Esplora file sullo stesso schermo
# virtuale: la finestra c'e' ma nessuno la mostra, e da fuori sembra che il click
# non abbia fatto niente. Qui si verifica quando una finestra e' "orfana" e
# quando invece non va toccata - e' li' che si fanno danni.
if /opt/homebrew/bin/bash mac/tests/orphan-windows.sh > "$TMP/orph.out" 2>&1; then
  say "ok   finestre figlie: riconosciute, senza rubare quelle degli altri slot"
else
  say "NO   finestre figlie:"
  sed 's/^/       /' "$TMP/orph.out"
  fail=1
fi

exit "$fail"
