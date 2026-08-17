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

exit "$fail"
