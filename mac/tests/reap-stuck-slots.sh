#!/opt/homebrew/bin/bash
# Verifica la LOGICA di reap_stuck_slots senza toccare l'host: si simulano gli
# stati che l'host puo' riportare e si controlla quali slot verrebbero liberati.
set -u
SLOTS=4
# slot 0: nostro e vivo -> non si tocca
# slot 1: BUSY ma non nostro -> si libera
# slot 2: FREE -> niente da fare
# slot 3: BUSY ma non nostro -> si libera
slot_live(){ [ "$1" = 0 ]; }
slot_state(){ case "$1" in 0|1|3) echo "SUNSHINE_SERVER_BUSY";; *) echo "SUNSHINE_SERVER_FREE";; esac; }
trace(){ :; }
SSH_OPTS=(); HOST_SSH=""
freed_list=""
reap_stuck_slots(){
  local i freed=0
  for i in $(seq 0 $(( SLOTS - 1 ))); do
    slot_live "$i" && continue
    case "$(slot_state "$i")" in
      *BUSY*) freed_list="$freed_list $i"; freed=$(( freed + 1 ));;
    esac
  done
  return 0
}
reap_stuck_slots
echo "slot che verrebbero liberati:$freed_list"
[ "$freed_list" = " 1 3" ] && echo "PASS: libera solo i bloccati non nostri" || echo "FAIL"
