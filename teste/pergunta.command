#!/bin/zsh
# Teste curto da pergunta rápida no app de demonstração (atalho global → digita → Enter → resposta). Pelo Terminal.app.
cd "$(dirname "$0")"; REPO=$PWD/..
OUT=${OUT_DIR:-$(cat "$PWD/.saida" 2>/dev/null)}; OUT=${OUT:-$HOME/Library/Caches/fleetnotch/testes}  # teste/.saida: pasta local (fora do git)
mkdir -p "$OUT"; cd "$OUT"
ROT=$(sed -n "s/^ROT=//p" "$REPO/install.sh"); export PREFIXO=$ROT
APP=$OUT/FleetNotchDemo.app
swiftc -O -swift-version 5 -parse-as-library "$REPO/FleetNotch.swift" "$REPO/Ajustes.swift" "$REPO/Assistente.swift" "$REPO/Visual.swift" -o "$APP/Contents/MacOS/FleetNotch" || exit 1
cp "$REPO"/{coleta,comum,agentes,caixas,ajustes,pergunta,demo,acoes,modelos,sonda}.py "$REPO/sonda_linux.sh" "$APP/Contents/Resources/"
codesign -s - --force "$APP" 2>/dev/null
launchctl bootout gui/$(id -u)/$ROT 2>/dev/null
FROTA_CONFIG=$OUT/demo-config.json FROTA_DEMO=1 FROTA_FUNDO=1 "$APP/Contents/MacOS/FleetNotch" >/dev/null 2>&1 &
D=$!
sleep 4; ./ctl move 1700 900; ./ctl atalho; sleep 1.2; ./ctl type "Quanto é 15% de 2.340?"; sleep 0.3; ./ctl key 36; sleep 8
SEM_FUNDO=1 ./grava foto 12-pergunta-resposta.png 480 0 960 820 > pergunta.log 2>&1
kill $D; launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/$ROT.plist" 2>/dev/null
echo fim >> pergunta.log
osascript -e 'tell application "Terminal" to close (every window whose name contains ".command")' &
