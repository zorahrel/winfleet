#!/bin/bash
# La lista «Ultimi lavori» dello schermo del PC non mostra mai la cartella temporanea.
#
# Il difetto, visto dal vivo: un giro lanciato da una cartella mktemp (Tmp.5jCe2SqScj)
# mostrava quella cartella al posto del nome del lavoro. La catena: offload scrive
# lavoro-<pid>.json con progetto = nome della cartella di partenza, wf-autosleep lo
# copia in stato.js ed esiti.jsonl, index.html lo rendeva cosi' com'e'.
# La regola vive in schermo/nome-lavoro.js (puro, eseguito qui con node) ed e' usata
# da index.html in entrambe le viste; deploy.sh la distribuisce sul PC.
#
#   ./mac/tests/nome-lavoro-schermo.sh   (solo node e grep, niente PC)
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
fail=0

MOD=schermo/nome-lavoro.js
if [ ! -f "$MOD" ]; then
  echo "  NO   schermo: $MOD manca, il nome resta quello verbatim"
  if grep -q '\[u\.progetto' schermo/index.html; then
    echo "  NO   schermo: la pagina rende u.progetto cosi' com'e' (Tmp.5jCe2SqScj in «Ultimi lavori»)"
  fi
  echo FAIL; exit 1
fi
command -v node >/dev/null 2>&1 || { echo "  NO   schermo: serve node per eseguire la regola"; echo FAIL; exit 1; }

# --- 1. il caso visto dal vivo resta leggibile, senza la temporanea ---------------
node -e '
const N = require("./schermo/nome-lavoro.js");
const casi = [
  // [ingresso, titolo atteso, progetto atteso]
  [{progetto:"Tmp.5jCe2SqScj", cosa:"test nel browser"}, "test nel browser", ""],
  [{progetto:"Tmp.5jCe2SqScj", cosa:"Tmp.5jCe2SqScj"}, "", ""],
  [{progetto:"Topics", cosa:"Tmp.5jCe2SqScj"}, "", "Topics"],
  [{progetto:"tmp-8f3ka9z2", cosa:"build"}, "build", ""],
  [{progetto:"Topics", cosa:"test nel browser"}, "test nel browser", "Topics"],
  [{progetto:"Main", cosa:"un comando: npx"}, "un comando: npx", "Main"],
  [{progetto:"Topics-app", cosa:"test nel browser"}, "test nel browser", "Topics-app"],
  [{progetto:"tempo", cosa:"test"}, "test", "tempo"]
];
let ko = 0;
for (const [u, titolo, progetto] of casi) {
  const r = N.nomeLavoro(u);
  if (r.titolo !== titolo || r.progetto !== progetto) { console.error("  NO   schermo: " + JSON.stringify(u) + " -> " + JSON.stringify(r)); ko = 1; }
}
process.exit(ko);
' || fail=1
[ "$fail" = 0 ] && echo "  ok   schermo: la temporanea non arriva al nome, il comando leggibile si"

# --- 2. la pagina usa la regola in entrambe le viste, non il valore verbatim -----
if grep -q 'src="nome-lavoro.js"' schermo/index.html &&
   [ "$(grep -c 'NomeLavoro\.nomeLavoro(' schermo/index.html)" -ge 2 ] &&
   ! grep -q '\[u\.progetto' schermo/index.html; then
  echo "  ok   schermo: lavora e ultimi lavori passano dalla regola"
else
  echo "  NO   schermo: index.html non usa nome-lavoro.js in entrambe le viste"; fail=1
fi

# --- 3. deploy.sh porta la regola sul PC con la pagina -----------------------------
if grep -q 'nome-lavoro.js' schermo/deploy.sh; then
  echo "  ok   schermo: deploy.sh distribuisce la regola"
else
  echo "  NO   schermo: deploy.sh non distribuisce nome-lavoro.js"; fail=1
fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
