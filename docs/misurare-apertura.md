# Aperture lente: come si misurano, e come NON si misurano

**Aggiornamento 20/08/2026.** Il rallentamento a 42 secondi descritto qui sotto
era in buona parte un ERRORE DI MISURA mio. Rimisurato il giorno dopo, sei
aperture di fila stanno fra 7.6 e 12.7 secondi.

## Come si misura, e perche' il numero sbagliato e' facile da ottenere

`winfleet open` NON ritorna quando la finestra e' pronta: resta vivo a fare da
supervisore finche' la finestra esiste - segue il ridimensionamento, tiene il
ritaglio, libera lo slot alla chiusura. Cronometrare quanto ci mette il comando
a tornare misura la durata della SESSIONE, non dell'apertura.

Il numero giusto lo scrive winfleet stesso nella traccia:

```bash
grep "aperta:" ~/.config/winfleet/trace.log | tail -6
```

La riga `aperta:` porta i millisecondi dall'avvio dello stream. In alternativa,
dal Dock, si aspetta che compaia la misura DI QUELLA finestra - ma attenzione:
il file `slotN.size` viene riscritto in continuazione dalla libreria, quindi
guardare "esiste" invece di "e' cambiato" da' risposte a caso (e' cosi' che ho
ottenuto 107 secondi per un'apertura che ne aveva richiesti 7.9).

## Quel che resta vero

Nel log di Moonlight compare davvero, a volte, un'attesa di 35 secondi:

```
00:00:35 - Qt Warning: Error resolving "PCdiCasa.local" : "Host not found"
```

Ma NON e' su tutte le aperture: su sei misurate il giorno dopo, zero. Quando
capita, il nome risolve verso un IPv6 link-local che non risponde e Qt aspetta
prima di ripiegare sull'IPv4. E' un caso occasionale, non la norma.

C'e' anche un secondo costo occasionale, questo sicuro e visibile in traccia:

```
nessuna modalita': i monitor virtuali sono spariti, li faccio rinascere
```

Sedici secondi per ricrearli. Succede quando il VDD sull'host si e' perso, ed e'
capitato una volta sola in una giornata di prove.

## Cosa e' stato escluso (e resta valido)

Ognuna di queste e' stata misurata, non supposta:

- **Non e' il codice di winfleet.** Con `git stash` sulle modifiche del giorno:
  42.9 secondi, identico.
- **Non e' l'identificativo di bundle unificato.** Il rallentamento c'era anche
  con gli identificativi separati.
- **Non e' quello che passiamo a Moonlight.** Nome mDNS o indirizzo IP diretto:
  42 e 44 secondi. L'attesa non riguarda l'host a cui ci si connette.
- **Non e' mDNS del Mac.** `getaddrinfo("PCdiCasa.local")` risponde in 8 ms e
  restituisce l'IPv4 giusto. `dns-sd` mostra che l'host annuncia solo 192.168.1.50.
- **Non e' un host "fantasma" nelle preferenze.** Ce n'era uno senza nome ne'
  indirizzo, rimosso: nessun cambiamento.
- **Non e' `manualaddress`.** Toglierlo peggiora (111 secondi). Ripristinato.
- **Non e' `QT_DISABLE_IPV6`.** Con quella variabile: 44.7 secondi.
- **Non e' il carico sull'host.** CPU all'1%, istanze Sunshine fresche.

## Cosa resta

L'attesa e' dentro il resolver di Qt, e riguarda gli host che Moonlight tiene in
memoria - non quello a cui si sta connettendo. Il Mac ha **otto interfacce
utun** (VPN/Tailscale) e Moonlight manda pacchetti su ognuna: 112 pacchetti WoL
per apertura, 77 dei quali verso indirizzi IPv6 multicast su interfacce VPN.

Gli IPv6 dell'host non rispondono:

```
fd00::1122:3344:5566:7788   MORTO (2019ms)
fe80::aabb:ccdd:eeff:0011   MORTO (2031ms)
192.168.1.50                 ok    (42ms)
```

E `getaddrinfo` restituisce i due IPv6 PRIMA dell'IPv4.

- **Non e' Tailscale.** Spento con `tailscale down` e rimisurato: 92.7 secondi,
  cioe' PEGGIO. Riacceso.

## Se ricapita

Prima di tutto: RIMISURARE con la traccia, non col cronometro sul comando.
Se le righe `aperta:` stanno sotto i quindici secondi, non c'e' niente da
sistemare.

Se invece sono davvero decine di secondi, in ordine:

1. **Riavviare il Mac.** Il problema e' comparso in giornata senza che nulla
   cambiasse nel codice: qualcosa nello stato di rete si e' incastrato, e un
   riavvio e' l'unica cosa che rimette in ordine il resolver di sistema senza
   toccare configurazioni.
2. **Disattivare IPv6 sull'interfaccia Ethernet/Wi-Fi** (Impostazioni di Rete,
   configura IPv6 come "Solo locale"). Gli IPv6 dell'host sono entrambi morti e
   `getaddrinfo` li restituisce per primi: se il tempo torna a 9 secondi, la
   causa e' confermata.
3. Se nessuna funziona: il fork di Moonlight e' nostro (`fork/`), e si puo'
   guardare dove il resolver aspetta - ma sono trentacinque secondi tondi, che
   sanno di timeout fisso da qualche parte in Qt.

## Come misurarlo

```bash
pkill -f "runners/.*Moonlight stream"; sleep 3
rm -f ~/.config/winfleet/slot0.size
t0=$(date +%s%N); winfleet open Paint >/dev/null 2>&1
python3 -c "print(f'{($(date +%s%N)-$t0)/1e9:.1f}s')"
```

E per vedere dove aspetta:

```bash
grep -vE "gamecontroller|WoL" "$(ls -t /tmp/Moonlight-*.log | head -1)" |
  awk -F' - ' '{split($1,a,":"); s=a[3]+0; if (s!=l) { print $1, substr($2,1,60); l=s } }'
```
