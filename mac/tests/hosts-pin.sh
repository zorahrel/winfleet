#!/opt/homebrew/bin/bash
# Fissare un nome in /etc/hosts non deve rompere /etc/hosts.
#
# mDNS su Windows non si aggiusta: la porta 5353 se la prende il primo che la
# chiede (Steam, Arc, qualunque Chromium con WebRTC) e il responder di sistema
# smette di annunciare. Il nome pero' serve - Moonlight confronta gli host per
# indirizzo ignorando la porta, quindi con un IP nudo le quattro istanze
# sembrano la stessa - e /etc/hosts e' l'unico posto che non dipende da nessun
# servizio.
#
# Ma /etc/hosts e' un file di SISTEMA, condiviso con tutto il resto: qui dentro
# ci sono voci di lavoro che non c'entrano niente con winfleet. Un comando che
# lo riscrive male non da' un errore: rompe la risoluzione di altri nomi, e lo
# si scopre giorni dopo su tutt'altro.
#
# Si verifica la REGOLA di riscrittura su una copia, mai sul file vero.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Un /etc/hosts realistico: commenti, localhost, e voci di lavoro che devono
# sopravvivere a qualunque cosa faccia winfleet.
cat > "$tmp/hosts" <<'H'
##
# Host Database
##
127.0.0.1	localhost
255.255.255.255	broadcasthost
::1             localhost
212.35.217.65 blog.esempio.it
192.168.1.5 altro-pc.local
127.0.0.1 uno.localhost due.localhost
H
prima_altre="$(grep -v 'windowsatti' "$tmp/hosts")"

# La stessa riscrittura di hosts_pin, isolata: togli le righe che nominano il
# nome, poi aggiungi quella nuova.
riscrivi(){ # file ip nome
  local f="$1" ip="$2" nome="$3"
  grep -vE "[[:space:]]$nome([[:space:]]|$)" "$f" > "$f.new" || true
  printf '%s %s\n' "$ip" "$nome" >> "$f.new"
  mv "$f.new" "$f"
}

# --- 1. la voce si aggiunge ------------------------------------------------
riscrivi "$tmp/hosts" 192.168.1.9 windowsatti.local
if grep -qx "192.168.1.9 windowsatti.local" "$tmp/hosts"; then
  echo "  ok   la voce viene scritta"
else
  echo "  NO   la voce non c'e' dopo la scrittura"
  fail=1
fi

# --- 2. e NON si duplica quando l'IP cambia --------------------------------
# E' il caso vero: il DHCP ha spostato il PC da .2 a .9. Due voci per lo stesso
# nome fanno risolvere quella sbagliata, e il sintomo e' una finestra che non
# si apre - senza nessun errore che nomini /etc/hosts.
riscrivi "$tmp/hosts" 192.168.1.20 windowsatti.local
n="$(grep -c 'windowsatti\.local' "$tmp/hosts" || true)"
if [ "$n" = 1 ] && grep -qx "192.168.1.20 windowsatti.local" "$tmp/hosts"; then
  echo "  ok   cambiando IP la voce si sostituisce, non si accumula"
else
  echo "  NO   $n voci per lo stesso nome: risolverebbe l'indirizzo sbagliato"
  fail=1
fi

# --- 3. e non tocca NIENTE altro -------------------------------------------
# La cosa che conta davvero: questo file non e' nostro.
dopo_altre="$(grep -v 'windowsatti' "$tmp/hosts")"
if [ "$prima_altre" = "$dopo_altre" ]; then
  echo "  ok   le altre voci di /etc/hosts restano identiche"
else
  echo "  NO   /etc/hosts e' stato alterato altrove:"
  diff <(printf '%s\n' "$prima_altre") <(printf '%s\n' "$dopo_altre") | sed 's/^/       /'
  fail=1
fi

# --- 4. un nome che ne CONTIENE un altro non viene travolto ----------------
# "windowsatti.local" non deve portarsi via "vecchio-windowsatti.local", e
# viceversa: il filtro cerca il nome preceduto da spazio e seguito da spazio o
# fine riga, non una sottostringa qualsiasi.
printf '10.0.0.1 vecchio-windowsatti.local\n' >> "$tmp/hosts"
riscrivi "$tmp/hosts" 192.168.1.30 windowsatti.local
if grep -qx "10.0.0.1 vecchio-windowsatti.local" "$tmp/hosts"; then
  echo "  ok   un nome che ne contiene un altro non viene toccato"
else
  echo "  NO   «vecchio-windowsatti.local» e' stato rimosso per sbaglio"
  fail=1
fi

# --- 5. il comando esiste ---------------------------------------------------
# La password si puo' digitare solo da un terminale, quindi la riparazione deve
# avere un comando proprio: dentro il doctor lanciato dal Dock non c'e' nessuno
# a cui chiederla.
if grep -q '^  host-name) cmd_host_name;;' bin/winfleet; then
  echo "  ok   «winfleet host-name» e' agganciato al comando"
else
  echo "  NO   host-name non e' nel dispatcher"
  fail=1
fi

# --- 6. e non si blocca mai su sudo ----------------------------------------
# Un sudo che aspetta una password che nessuno puo' digitare lascia il comando
# appeso per sempre, con l'icona del Dock che gira e nessuna spiegazione.
if grep -q 'sudo -n true' bin/winfleet && grep -q 'tty -s' bin/winfleet; then
  echo "  ok   sudo si prova senza bloccare, e si guarda se c'e' un terminale"
else
  echo "  NO   manca il controllo che evita il blocco su sudo"
  fail=1
fi

exit "$fail"
