#!/opt/homebrew/bin/bash
# Un nome che non risolve non e' un indirizzo.
#
# Il guasto vero, 25/08: "Arc non ha ancora aperto una finestra", finestra
# VUOTA per 88 secondi, e nel log di Moonlight l'unica riga che spiegava
# qualcosa: 'Failed to connect to PCdiCasa.local:48089'. Sul PC,
# steamwebhelper aveva preso la porta 5353 e il responder mDNS di Windows non
# rispondeva piu': "pcdicasa.local" era diventato irrisolvibile da questo
# Mac. winfleet indirizzava comunque le istanze per nome, perche' il nome era
# scritto in config e nessuno controllava che valesse ancora qualcosa.
#
# Verificato che la causa fosse quella: lo stesso stream, lanciato a mano
# sull'INDIRIZZO Tailscale invece che sul nome, ha negoziato e decodificato
# video in 13 secondi ("Received first video packet after 1000 ms").
#
# Qui si verifica il ripiego: se il nome risolve si usa quello (non collide con
# l'istanza di sistema), altrimenti un indirizzo - meglio una finestra sulla
# porta giusta che una finestra vuota.
#
# Il test e' capace di fallire: con la vecchia riga slot_addr torna sempre il
# nome, anche quando non risolve.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# risoluzione_finta -> indirizzo scelto per lo slot 0
#
# Si sostituisce la RISOLUZIONE, non la decisione: il test esercita cosi'
# host_name_resolves per davvero, compresa la regola sul 127.x.
# (I commenti stanno QUI e non dentro la stringa: un apostrofo italiano
# dentro '...' chiude la quote, e il file non compila piu'.)
addr_con(){ # ip_restituito_da_dscacheutil ("" = non risolve)
  rm -rf "$tmp/cfg"; mkdir -p "$tmp/cfg"
  /opt/homebrew/bin/bash -c '
    source bin/winfleet 2>/dev/null
    CONFIG_DIR="'"$tmp"'/cfg"
    HOST_NAME="pcdicasa.local"; HOST_TS="100.0.0.1"; HOST_LAN="192.168.1.42"
    SLOT_BASE=48089
    host_name_resolves(){
      local ip="'"$1"'"
      case "$ip" in ""|127.*) return 1;; *) return 0;; esac
    }
    echo "A=$(slot_addr 0)"
  ' 2>/dev/null | sed -n 's/^A=//p'
}

verifica(){ # descrizione ip atteso
  local desc="$1" ip="$2" atteso="$3" got
  got="$(addr_con "$ip")"
  if [ "${got:-x}" = "$atteso" ]; then
    echo "  ok   $desc: $got"
  else
    echo "  NO   $desc: atteso «${atteso}», ottenuto «${got:-(niente)}»"
    fail=1
  fi
}

# --- 1. il nome si usa quando vale ------------------------------------------
# E' la via preferita: Moonlight confronta gli host per indirizzo ignorando la
# porta, quindi un IP nudo finirebbe sull'istanza di sistema.
verifica "il nome risolve"        "192.168.1.42" "pcdicasa.local:48089"

# --- 2. e si ripiega quando non vale ----------------------------------------
verifica "il nome non risolve"    ""            "100.0.0.1:48089"

# --- 3. il router che risponde per se' non conta ----------------------------
# Visto dal vivo: il DNS di casa risolveva "pcdicasa.homenet.example"
# in 127.0.0.1. Un nome che risolve a localhost e' peggio di uno che non
# risolve: lo stream parte e si connette a se stesso.
verifica "risolve a localhost"    "127.0.0.1"   "100.0.0.1:48089"

# --- 4. senza Tailscale si usa la LAN ---------------------------------------
lan="$(/opt/homebrew/bin/bash -c '
  source bin/winfleet 2>/dev/null
  CONFIG_DIR="'"$tmp"'/cfg4"; mkdir -p "$CONFIG_DIR"
  HOST_NAME="pcdicasa.local"; HOST_TS=""; HOST_LAN="192.168.1.42"
  SLOT_BASE=48089
  host_name_resolves(){ return 1; }
  echo "A=$(slot_addr 1)"
' 2>/dev/null | sed -n 's/^A=//p')"
if [ "${lan:-x}" = "192.168.1.42:48189" ]; then
  echo "  ok   senza Tailscale ripiega sulla LAN: $lan"
else
  echo "  NO   senza Tailscale: atteso «192.168.1.42:48189», ottenuto «${lan:-(niente)}»"
  fail=1
fi

# --- 5. la porta resta quella dello slot ------------------------------------
# Il ripiego cambia l'HOST, non lo slot: sbagliare porta vuol dire aprire la
# finestra su un'altra istanza, che e' il guasto che il nome doveva evitare.
p2="$(addr_con "")"
if [ "${p2##*:}" = 48089 ]; then
  echo "  ok   il ripiego non cambia la porta dello slot"
else
  echo "  NO   il ripiego ha cambiato porta: ${p2:-(niente)}"
  fail=1
fi

exit "$fail"
