#!/bin/sh
# Compila topics-server.exe SUL PC da un ramo di topics-app e lo mette in
# E:\topics-nodo\bin, dove avvia-nodo.ps1 lo preferisce a quello installato.
# Serve finche' la release per Windows non ha il ponte MCP corretto: la 2.3.30
# lancia il ponte con "topics-server.exe run <script>" e ottiene un secondo
# server, e gli agenti del nodo restano senza strumenti di Topics.
#
# Uso: compila-dal-ramo.sh <checkout di topics-app> [ref]   (default HEAD)
# Il Mac fa solo git archive e scp: bun install e bun build girano sul PC.
# Non riavvia il nodo: il binario nuovo vale dal prossimo avvio di avvia-nodo.ps1.
set -eu
REPO="${1:?checkout di topics-app}"
REF="${2:-HEAD}"
BUN_VERSION="${PC_NODO_BUN:-1.4.2}"
HOST_SSH="${PC_NODO_SSH:-$(sed -n 's/^[[:space:]]*HOST_SSH="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$HOME/.config/winfleet/config.env" | head -1)}"
[ -n "$HOST_SSH" ] || { echo "compila-dal-ramo: HOST_SSH mancante" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SHA=$(git -C "$REPO" rev-parse --short "$REF")
git -C "$REPO" archive --format=tar.gz -o "$TMP/src.tgz" "$REF"
scp -q -o BatchMode=yes "$TMP/src.tgz" "$HOST_SSH:E:/topics-nodo/dl/topics-src.tgz"
echo "sorgente $SHA copiato sul PC"

# PowerShell come -EncodedCommand: vedi pc-nodo-prep per il perche'.
cat > "$TMP/compila.ps1" <<PS
\$ProgressPreference = 'SilentlyContinue'
\$b = 'E:\topics-nodo\build'
New-Item -ItemType Directory -Force -Path \$b, 'E:\topics-nodo\bin' | Out-Null
\$bun = "\$b\bun-windows-x64\bun.exe"
if (-not (Test-Path \$bun) -or (& \$bun --version) -ne '$BUN_VERSION') {
  Invoke-WebRequest -UseBasicParsing https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-windows-x64.zip -OutFile "\$b\bun.zip"
  Expand-Archive -Force "\$b\bun.zip" \$b
}
\$src = "\$b\src"
if (Test-Path \$src) { Remove-Item -Recurse -Force \$src }
New-Item -ItemType Directory -Force -Path \$src | Out-Null
tar -xzf 'E:\topics-nodo\dl\topics-src.tgz' -C \$src
if (\$LASTEXITCODE -ne 0) { "ERRORE tar \$LASTEXITCODE"; exit 1 }
Set-Location \$src
\$env:PATH = "\$b\bun-windows-x64;\$env:PATH"
# Lo stderr dei comandi nativi passa da stdout: con -NonInteractive via ssh
# PowerShell lo incapsula in CLIXML e l'errore vero non si legge.
& \$bun install --frozen-lockfile 2>&1 | ForEach-Object { "\$_" } | Select-Object -Last 3
if (\$LASTEXITCODE -ne 0) { "ERRORE bun install \$LASTEXITCODE"; exit 1 }
& \$bun run scripts/gen-migrations-manifest.ts 2>&1 | ForEach-Object { "\$_" } | Select-Object -Last 1
& \$bun build --compile --target=bun-windows-x64 --external playwright-core --external chromium-bidi --external electron ./server/sidecar-entry.ts --outfile E:\topics-nodo\bin\topics-server-nuovo.exe 2>&1 | ForEach-Object { "\$_" } | Select-Object -Last 2
if (\$LASTEXITCODE -ne 0) { "ERRORE bun build \$LASTEXITCODE"; exit 1 }
# Prova di fumo: col flag il binario deve rispondere come server MCP.
\$in = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prova","version":"1"}}}' + "\`n" + '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
\$r = (\$in | & E:\topics-nodo\bin\topics-server-nuovo.exe --topics-mcp-bridge --base-url=http://127.0.0.1:3333 --session-key=topic:prova --profile=dispatch 2>&1) -join "\`n"
if ("\$r" -notmatch 'approval_prompt') { "ERRORE: il binario non fa da ponte MCP"; exit 1 }
"pronto: E:\topics-nodo\bin\topics-server-nuovo.exe ($SHA)"
PS
ENC=$(iconv -f UTF-8 -t UTF-16LE "$TMP/compila.ps1" | base64 | tr -d '\n')
ssh -o BatchMode=yes "$HOST_SSH" "powershell -NoProfile -NonInteractive -EncodedCommand $ENC" 2>/dev/null | tee "$TMP/out.txt"
/usr/bin/grep -q '^pronto:' "$TMP/out.txt" || exit 1
echo "per usarlo: sul PC sposta topics-server-nuovo.exe su topics-server.exe e riavvia il nodo"
