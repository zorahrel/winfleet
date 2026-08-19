# Aperture da 42 secondi invece di 9

**Quando**: comparso la sera del 19/08/2026. Prima dello stesso giorno le
aperture stavano sui 8.6-9.8 secondi misurati dal Dock.

## Il sintomo

Ogni apertura impiega circa 42 secondi. Nel log di Moonlight
(`/tmp/Moonlight-*.log`) c'e' un salto secco:

```
00:00:00 - Qt Info: Sent WoL packet to WinFleet 1 via ff02::1%utun8:48110
00:00:35 - Qt Warning: Error resolving "windowsatti.local" : "Host not found"
00:00:35 - Qt Info: "WindowsAtti" is now online at "192.168.1.2:47989"
```

Trentacinque secondi fra l'ultimo pacchetto e il primo segno di vita. Dopo,
tutto il resto (handshake, decoder, primo frame) richiede cinque secondi.

## Cosa e' stato escluso

Ognuna di queste e' stata misurata, non supposta:

- **Non e' il codice di winfleet.** Con `git stash` sulle modifiche del giorno:
  42.9 secondi, identico.
- **Non e' l'identificativo di bundle unificato.** Il rallentamento c'era anche
  con gli identificativi separati.
- **Non e' quello che passiamo a Moonlight.** Nome mDNS o indirizzo IP diretto:
  42 e 44 secondi. L'attesa non riguarda l'host a cui ci si connette.
- **Non e' mDNS del Mac.** `getaddrinfo("windowsatti.local")` risponde in 8 ms e
  restituisce l'IPv4 giusto. `dns-sd` mostra che l'host annuncia solo 192.168.1.2.
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
fd00::62d8:30cc:2bcd:a22b   MORTO (2019ms)
fe80::3351:fff6:650e:a191   MORTO (2031ms)
192.168.1.2                 ok    (42ms)
```

E `getaddrinfo` restituisce i due IPv6 PRIMA dell'IPv4.

- **Non e' Tailscale.** Spento con `tailscale down` e rimisurato: 92.7 secondi,
  cioe' PEGGIO. Riacceso.

## Cosa proverei, in ordine

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
