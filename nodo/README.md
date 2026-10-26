# Accendere il PC come nodo di Topics

Una pagina, sette passi. Gli script sono in questa cartella.

1. **PC: installare e registrare il nodo.**
   Prerequisito: il PC deve avere l'identità git globale (`git config --global user.name` e `git config --global user.email`), altrimenti le card del nodo non possono committare e la consegna esce vuota.
   Lancia `installa.ps1 -Version <x.y.z>` da un task pianificato *Interactive* (via ssh l'installer NSIS fallisce senza dire niente). Poi `registra-nodo.ps1`: crea il task «topics-nodo», AtLogOn, senza finestra.
   La release ≥ 2.3.33 ha già il ponte MCP: `bin\topics-server.exe` serve solo per una build compilata da un ramo (`compila-dal-ramo.sh`).

2. **Mac: proxy del modello e tunnel.**
   Metti `TOPICS_MODEL_PROXY_PORT=3391` in `~/.topics-server-env` (vale dal prossimo riavvio del server).
   Il tunnel (`pc-nodo-tunnel`) va in launchd come `com.jarvis.pc-nodo-tunnel`, log in `~/.claude/jarvis/logs/pc-nodo-tunnel.log`:
   `-L 3393` verso la 3341 del PC, `-R 3394` del PC verso la 3391 del Mac.

3. **Appaiamento.**
   - Mac: `POST /api/machines/pair {"baseUrl":"http://127.0.0.1:3393"}` restituisce un codice.
   - PC: `GET /api/auth/pair/pending`, poi `POST /api/auth/pair/approve {requestId}` su `127.0.0.1:3333` (da loopback si è proprietari).
   - Mac: `GET /api/machines/pair/<pairingId>` restituisce la macchina; rinominala con `PATCH /api/machines/<id> {name}`.

4. **Token del modello.**
   Dal Mac `POST /api/machines/<id>/model-token`: si vede una volta sola.
   Scrivilo in `E:\topics-nodo\modello.env` (`ANTHROPIC_BASE_URL=http://127.0.0.1:3394`, `ANTHROPIC_AUTH_TOKEN=...`) e riavvia il server del nodo.
   Il token non va mai in un file del repo.

5. **Hook.**
   `~/.topics/hooks.json`: evento `node-run` → `python3 <winfleet>/nodo/pc-nodo-prep`, `timeoutMs` 300000.
   Per i nodi che non sono il PC (Cloud Claude) lo script esce 0.

6. **Board.**
   `PATCH /api/boards/<boardId>/settings {"dispatchMachineId":"<id>"}`. Vale solo per le card nuove.
   Mettilo solo su board git il cui lavoro sta sul ramo di default: il nodo parte sempre da origin/HEAD.

7. **Sonno.**
   `host/wf-autosleep.ps1` conta come lavoro le card in corso sul nodo, quindi il PC non va a dormire mentre ne gira una.
