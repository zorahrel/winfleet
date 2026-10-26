# Accendere il PC come nodo di Topics

Il PC Windows esegue le card che la Topics del Mac gli assegna. Questa pagina
descrive la procedura completa, dall'installazione alla prima card. Gli script
sono in questa cartella; qui non si cambia codice.

Fatti verificati il 26/10 sulla Topics di produzione.

## Passi

1. **Sul PC, installa Topics come nodo.** Da PowerShell crea un task pianificato
   di tipo *Interactive* che lancia `installa.ps1 -Version <x.y.z>`. Non lanciarlo
   via ssh: l'installer NSIS fallisce senza dire niente. La release deve essere
   ≥ 2.3.33, che porta già il ponte MCP. Solo una build compilata da un ramo
   richiede `bin\topics-server.exe`.

2. **Sul PC, registra l'avvio automatico.** Lancia `registra-nodo.ps1`. Crea il
   task «topics-nodo» con trigger AtLogOn, senza finestra, e lo avvia subito.

3. **Sul Mac, collega il tunnel e la porta del modello.**
   - In `~/.topics-server-env` aggiungi `TOPICS_MODEL_PROXY_PORT=3391`. Vale
     dal prossimo riavvio del server Topics.
   - Il tunnel gira in launchd come `com.jarvis.pc-nodo-tunnel`. Il suo log è
     `~/.claude/jarvis/logs/pc-nodo-tunnel.log`.
   - Il tunnel fa due cose: `-L 3393` porta la 3341 del PC sul Mac, e
     `-R 3394` riporta la 3391 del Mac sul PC.

4. **Appaia il PC.** Dal Mac chiama `POST /api/machines/pair` con
   `{"baseUrl":"http://127.0.0.1:3393"}`: risponde con un codice.
   Sul PC leggi le richieste con `GET /api/auth/pair/pending` e approvi con
   `POST /api/auth/pair/approve {requestId}` su `127.0.0.1:3333`. Da loopback
   sei già proprietario, quindi non serve altro. Dal Mac chiedi la macchina con
   `GET /api/machines/pair/<pairingId>`, poi dalla a un nome con
   `PATCH /api/machines/<id> {name}`.

5. **Dai al nodo il token del modello.** Dal Mac chiama
   `POST /api/machines/<id>/model-token`. Il token viene mostrato una sola volta.
   Scrivilo in `E:\topics-nodo\modello.env` con due righe:
   `ANTHROPIC_BASE_URL=http://127.0.0.1:3394` e `ANTHROPIC_AUTH_TOKEN=...`.
   Poi riavvia il server del nodo. Il token non va mai in un file del repo.

6. **Installa l'hook di preparazione.** Nel file `~/.topics/hooks.json` del Mac
   aggiungi l'evento `node-run` che lancia `python3 <winfleet>/nodo/pc-nodo-prep`,
   con `timeoutMs` a 300000. Lo script risveglia il PC, porta il ramo di default
   con un bundle git e registra il progetto. Per i nodi che non sono il PC, come
   Cloud Claude, esce 0 senza fare nulla.

7. **Assegna la board al nodo.** Chiama
   `PATCH /api/boards/<boardId>/settings {"dispatchMachineId":"<id>"}`.
   L'impostazione vale solo per le card nuove. Mettila solo su una board git il
   cui lavoro sta sul ramo di default, perché il nodo parte sempre da
   `origin/HEAD`.

Il sonno del PC è gestito da `host/wf-autosleep.ps1`: conta come lavoro le card
in corso sul nodo, quindi il PC non si addormenta mentre una card gira.

## Controlli

- Il task «topics-nodo» deve risultare in esecuzione sul PC.
- Il log `installa.log` nella cartella `E:\topics-nodo` deve chiudere con `OK`
  sulla versione richiesta. Se chiude con `KO`, la versione installata è diversa.
- Il log del tunnel sul Mac non deve mostrare errori di connessione.
