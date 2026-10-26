# Accendere il PC come nodo di Topics

Il PC Windows esegue il server di Topics e il Mac gli passa le card da lavorare, attraverso un tunnel SSH.
La procedura si fa una volta sola: dopo, il nodo riparte da solo a ogni accesso al PC.

1. **Sul PC: installa e registra l'avvio.** Da PowerShell via SSH l'installer NSIS fallisce senza dire niente,
   quindi lancia `installa.ps1` da un task pianificato di tipo Interactive:
   `installa.ps1 -Version <x.y.z>`. Esce 0 solo se la versione installata è quella richiesta.
   Poi esegui `registra-nodo.ps1`: crea il task «topics-nodo» (AtLogOn, senza finestra) e lo avvia.
   Con release ≥ 2.3.33 il ponte MCP è già nella release; `bin\topics-server.exe` serve solo per una
   build compilata da un ramo (`compila-dal-ramo.sh`).

2. **Sul Mac: porta del modello e tunnel.** In `~/.topics-server-env` aggiungi
   `TOPICS_MODEL_PROXY_PORT=3391`; vale dal prossimo riavvio del server.
   Il tunnel `pc-nodo-tunnel` gira in launchd come `com.jarvis.pc-nodo-tunnel`, con log in
   `~/.claude/jarvis/logs/pc-nodo-tunnel.log`. Fa due cose: `-L 3393` sul Mac arriva alla 3341 del PC,
   e `-R 3394` del PC arriva alla 3391 del Mac.

3. **Appaiamento.** Dal Mac: `POST /api/machines/pair` con `{"baseUrl":"http://127.0.0.1:3393"}`,
   che restituisce un codice. Sul PC, da loopback (da lì sei proprietario):
   `GET /api/auth/pair/pending` per vedere la richiesta, poi
   `POST /api/auth/pair/approve` con `{requestId}` su `127.0.0.1:3333`.
   Dal Mac, `GET /api/machines/pair/<pairingId>` restituisce la macchina.
   Rinominala con `PATCH /api/machines/<id>` e `{name}`.

4. **Token del modello.** Dal Mac: `POST /api/machines/<id>/model-token`. Il token è mostrato una sola volta.
   Scrivilo in `E:\topics-nodo\modello.env`:

   ```
   ANTHROPIC_BASE_URL=http://127.0.0.1:3394
   ANTHROPIC_AUTH_TOKEN=<token>
   ```

   Poi riavvia il server del nodo. Il token non va mai in un file del repo.

5. **Hook `node-run`.** In `~/.topics/hooks.json` aggiungi l'evento `node-run` che lancia
   `python3 <winfleet>/nodo/pc-nodo-prep` con `timeoutMs` 300000. Sui nodi che non sono il PC
   (Cloud Claude) lo script esce 0 senza svegliare il PC.

6. **Board.** Solo per una board git il cui lavoro sta sul ramo di default, perché il nodo parte sempre da
   `origin/HEAD`: `PATCH /api/boards/<boardId>/settings` con `{"dispatchMachineId":"<id>"}`.
   Vale solo per le card nuove.

7. **Sonno.** `host\wf-autosleep.ps1` sospende il PC dopo un certo tempo senza uso, ma conta come lavoro
   le card in corso sul nodo: finché una card lavora, il PC resta acceso. Un `ssh -N` aperto non lo tiene
   sveglio da solo.
