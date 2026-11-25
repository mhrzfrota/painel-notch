#!/bin/zsh
# Teste de glitch da ilha (dados do modo demonstração): ~10 min de uso automático (abre/fecha, hover em tudo, detalhes, voltar, Esc, clique fora,
# abre-fecha rápido, tela cheia/Space, troca de tela e despertar pelos mesmos tratadores) com os dados mudando a cada
# 5 s, gravado sem cursor e analisado quadro a quadro (glitch.py). Rodar pelo Terminal.app (Gravação de Tela +
# Acessibilidade):  open -a Terminal teste/sessao.command      (DUR=120 pra uma rodada curta)
# Para o app oficial durante o teste e devolve no fim. Nada é instalado fora da pasta de saída.
set -u
cd "$(dirname "$0")"
REPO=$PWD/..
OUT=${OUT_DIR:-$(cat "$PWD/.saida" 2>/dev/null)}; OUT=${OUT:-$HOME/Library/Caches/fleetnotch/testes}  # teste/.saida: pasta local (fora do git)
mkdir -p "$OUT"; cd "$OUT"
DUR=${DUR:-600}
ROT=$(sed -n "s/^ROT=//p" "$REPO/install.sh"); export PREFIXO=$ROT
swiftc -O "$REPO/teste/ctl.swift" -o ctl && swiftc -O "$REPO/teste/grava.swift" -o grava || exit 1
APP=$OUT/FleetNotchTeste.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library "$REPO/FleetNotch.swift" "$REPO/Ajustes.swift" "$REPO/Assistente.swift" "$REPO/Visual.swift" -o "$APP/Contents/MacOS/FleetNotch" || exit 1
cp "$REPO"/{coleta,comum,agentes,caixas,ajustes,pergunta,demo,acoes,modelos,sonda}.py "$REPO/sonda_linux.sh" "$APP/Contents/Resources/"
python3 "$REPO/demo.py" --config > demo-config.json   # dados que mudam a cada 5 s (demo.py), nada do usuário
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $ROT.teste" -c "Add :CFBundleName string FleetNotchTeste" \
  -c "Add :CFBundleExecutable string FleetNotch" -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" >/dev/null
codesign -s - --force "$APP" 2>/dev/null
launchctl bootout gui/$(id -u)/$ROT 2>/dev/null
FROTA_CONFIG=$OUT/demo-config.json FROTA_DEMO=1 DEMO_PASSO=5 "$APP/Contents/MacOS/FleetNotch" >/dev/null 2>&1 &
TESTE=$!
sleep 3
C=./ctl
log() { print -r -- "$(date +%H:%M:%S) $*" >> sessao.log; }
rm -f sessao.log sessao.mp4
$C move 1700 900
SEM_CURSOR=1 ./grava video sessao.mp4 $DUR 480 0 960 640 > grava.txt 2>&1 &
REC=$!
sleep 2
T0=$(date +%s); i=0
while (( $(date +%s) - T0 < DUR - 50 )); do
  i=$((i+1)); log "volta $i"
  $C click 960 14; sleep 1.6                                              # abre
  $C glide 960 14 716 175 0.5; $C glide 716 175 1100 175 2.4; sleep 0.4    # hover nos Macs
  $C glide 1100 175 690 315 0.5; $C glide 690 315 1100 315 2.2; sleep 0.4  # hover nos aparelhos
  $C glide 1100 315 760 383 0.5; $C glide 760 383 1160 383 1.2             # servidores
  $C glide 1160 383 695 70 0.5; $C glide 695 70 815 70 0.8                 # agentes
  $C glide 815 70 1108 65 0.6; $C glide 1108 65 1228 65 0.8; sleep 0.4     # contas
  $C move 1700 900; sleep 6                                                # parado, dados mudando
  $C click 960 175; sleep 2.2; $C click 645 63; sleep 1.6                  # detalhe do Mac e volta
  $C click 755 70; sleep 2.2; $C click 630 63; sleep 1.6                   # detalhe do agente e volta
  $C key 53; sleep 1.4                                                     # Esc
  $C click 960 14; sleep 0.15; $C click 960 14; sleep 0.15; $C click 960 14; sleep 1.4   # abre-fecha-abre
  $C click 520 320; sleep 1.4                                              # clique fora (na própria janela)
  $C click 960 14; sleep 1.2; $C click 790 10; sleep 1.4                   # clique fora (barra de menus vazia)
  $C notify $ROT.teste.teste telas; sleep 0.8                  # troca de tela (fechada)
  $C notify $ROT.teste.teste despertar; sleep 0.8              # despertar (fechada)
  $C click 960 14; sleep 1.0
  $C notify $ROT.teste.teste telas; sleep 0.8                  # troca de tela (aberta)
  $C notify $ROT.teste.teste despertar; sleep 0.8              # despertar (aberta)
  $C key 53; sleep 1.2
  $C move 1700 900; sleep 2
done
wait $REC
kill $TESTE 2>/dev/null
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/$ROT.plist" 2>/dev/null
python3 "$REPO/teste/glitch.py" sessao.mp4 > relatorio.txt 2>&1
cat relatorio.txt
osascript -e 'tell application "Terminal" to close (every window whose name contains ".command")' &
