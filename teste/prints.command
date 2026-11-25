#!/bin/zsh
# Prints e vídeo do README em MODO DEMONSTRAÇÃO (dados fictícios do demo.py; nada do usuário aparece): o notch, a legenda,
# a gaveta e as páginas, os Ajustes aba por aba, o assistente passo a passo e um vídeo de ~30 s de uso.
# Rodar pelo Terminal.app (é quem tem Gravação de Tela e Acessibilidade):  open -a Terminal teste/prints.command
# Para o app oficial enquanto roda e devolve no fim. Fundo neutro no lugar do papel de parede (FROTA_FUNDO=1).
set -u
cd "$(dirname "$0")"
REPO=$PWD/..
OUT=${OUT_DIR:-$(cat "$PWD/.saida" 2>/dev/null)}; OUT=${OUT:-$HOME/Library/Caches/fleetnotch/testes}  # teste/.saida: pasta local (fora do git)
mkdir -p "$OUT"; cd "$OUT"; rm -f *.png prints.log; [ "${VIDEO:-0}" = 1 ] && rm -f *.mp4 *.gif
ROT=${ROT:-$(sed -n "s/^ROT=//p" "$REPO/install.sh")}  # o bundle id do app oficial (install.sh)
export PREFIXO=$ROT   # o gravador só enxerga as janelas deste app
swiftc -O "$REPO/teste/ctl.swift" -o ctl && swiftc -O "$REPO/teste/grava.swift" -o grava || exit 1
APP=$OUT/FleetNotchDemo.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library "$REPO/FleetNotch.swift" "$REPO/Ajustes.swift" "$REPO/Assistente.swift" "$REPO/Visual.swift" -o "$APP/Contents/MacOS/FleetNotch" || exit 1
cp "$REPO"/{coleta,comum,agentes,caixas,ajustes,pergunta,demo,acoes,modelos,sonda}.py "$REPO/sonda_linux.sh" "$APP/Contents/Resources/"
cp -R "$REPO/i18n" "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $ROT.demo" -c "Add :CFBundleName string FleetNotchDemo" \
  -c "Add :CFBundleExecutable string FleetNotch" -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" >/dev/null
codesign -s - --force "$APP" 2>/dev/null
python3 "$REPO/demo.py" --config | python3 -c "import json,sys; c=json.load(sys.stdin); c['aparencia']={'atalho': True}; print(json.dumps(c))" > demo-config.json
defaults delete "$ROT.demo" >/dev/null 2>&1  # 1ª vez de novo: a dica do notch aparece sozinha
# idioma dos prints: IDIOMA=en|es|fr (padrão: português); só o app de demonstração, nunca o oficial
IDIOMA=${IDIOMA:-pt}; defaults write "$ROT.demo" idioma "$IDIOMA"
tr() { [ "$IDIOMA" = pt ] && print -r -- "$1" || python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], sys.argv[2]))" "$REPO/i18n/$IDIOMA.json" "$1"; }
typeset -A Q1=(pt "Quanto é 15% de 2.340?" en "What's 15% of 2,340?" es "Cuanto es el 15% de 2.340?" fr "Combien font 15 % de 2 340 ?")
typeset -A Q2=(pt "O que é Tailscale, em uma linha?" en "What is Tailscale, in one line?" es "Que es Tailscale, en una linea?" fr "C'est quoi Tailscale, en une ligne ?")
launchctl bootout gui/$(id -u)/$ROT 2>/dev/null
FROTA_CONFIG=$OUT/demo-config.json FROTA_DEMO=1 FROTA_FUNDO=1 DEMO_PASSO=6 "$APP/Contents/MacOS/FleetNotch" >/dev/null 2>&1 &
DEMO=$!
C=./ctl
G() { SEM_FUNDO=1 ./grava "$@" >> prints.log 2>&1; }
N() { $C notify "$ROT.demo.$1" "${2:-}"; }  # as notificações do app levam o bundle id dele
log() { print -r -- "$(date +%H:%M:%S) $*" >> prints.log; }
$C move 1700 900
sleep 5.5; G foto 01-dica-primeira-vez.png 760 0 400 440         # a dica aparece sozinha ~4 s depois de abrir
sleep 10; G foto 02-notch-fechado.png 760 0 400 44
$C glide 1700 900 960 14 0.6; sleep 1.2; G foto 03-legenda-hover.png 780 0 360 420
$C click 960 14; sleep 1.8; G foto 04-gaveta.png 480 0 960 760
$C glide 960 300 700 70 0.6; sleep 0.8; G foto 05-gaveta-hover-agente.png 480 0 960 760
# 0.3: Light × Full, os estilos dos anéis, o uso por modelo da conta e o histórico do ⌘C (itens inventados do modo demo)
$C move 1700 900; sleep 0.6
V() { N visual "$1"; sleep "${2:-1.4}"; }
V modo=light 1.8; G foto 04-gaveta-light.png 480 0 960 760
for e in atividade neon orgulho pastel mono grafite; do V estilo=$e 1.2; G foto "14-estilo-$e-light.png" 480 0 960 760; done
V modo=full 1.6
for e in atividade neon orgulho pastel; do V estilo=$e 1.2; G foto "14-estilo-$e.png" 480 0 960 760; done
V estilo=classico 1.2
N pagina conta:claude; sleep 2.6; G foto 12-conta-por-modelo.png 480 0 960 620
N pagina frota; sleep 1.0
V copiados=1 1.6; G foto 13-copiados.png 480 0 960 860
V modo=light 1.6; G foto 13-copiados-light.png 480 0 960 760
V modo=full 1.2; V copiados=0 1.2
N pagina agente:nova; sleep 1.6; G foto 06-pagina-agente.png 480 0 960 520
N pagina servidor:web-01; sleep 1.6; G foto 07-pagina-servidor.png 480 0 960 520
N pagina email; sleep 1.6; G foto 08-pagina-email.png 480 0 960 420
N pagina frota; sleep 1.2
$C atalho; sleep 1.0; $C type "${Q1[$IDIOMA]}"; $C key 36; sleep 9; G foto 09-pergunta-rapida.png 480 0 960 820
$C key 53; sleep 1.2
# Ajustes, aba por aba (a janela sozinha, com sombra)
N ajustes; sleep 2.2
for aba in geral aparencia macs:1 servidores:0 email ia:0 agentes:1 copiados; do
  N aba $aba; sleep 1.4; G janela "10-ajustes-${aba%%:*}.png" "*"
done
$C cmd 13; sleep 0.8
# assistente de primeira execução, passo a passo
N assistente; sleep 2.2
for p in 0 1 2 3 4 5 6 7 8 9; do N passo $p; sleep 1.3; G janela "11-assistente-$p.png" "$(tr Boas-vindas)"; done
$C cmd 13; sleep 1
# o painel da barra de menus (Full e Light), aberto como um clique no ícone
$C key 53; sleep 0.8
# (o ícone da barra não é janela do app no macOS 27: a posição vem da Acessibilidade, pelo System Events, e o clique é de verdade)
painel() {
  local raw=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $DEMO) to get {position, size} of every menu bar item of menu bar 2" 2>&1)
  local xy=$(print -r -- "$raw" | python3 -c "import sys; v=[int(float(x)) for x in sys.stdin.read().replace(',',' ').split() if x.lstrip('-').replace('.','').isdigit()]; print(v[0]+v[2]//2, v[1]+v[3]//2) if len(v)==4 else None")
  log "painel: $raw -> $xy"
  [ -n "$xy" ] && $C click ${=xy}
}
painel; sleep 1.6; G janela 15-painel-barra.png "@painel"; $C key 53; sleep 0.8
V modo=light 1.0; painel; sleep 1.6; G janela 15-painel-barra-light.png "@painel"; $C key 53; sleep 0.8; V modo=full 1.0
# vídeo de uso (~32 s): notch → legenda → gaveta → hover → agente → volta → pergunta → Esc  (VIDEO=1)
if [ "${VIDEO:-0}" = 1 ]; then
$C move 1700 900
SEM_FUNDO=1 ./grava video uso.mp4 34 480 0 960 760 >> prints.log 2>&1 &
REC=$!
sleep 1.5
$C glide 1500 700 960 14 1.0; sleep 2.6                      # legenda
$C click 960 14; sleep 2.0                                   # abre
$C glide 960 14 716 175 0.6; $C glide 716 175 1100 175 2.0   # Macs
$C glide 1100 175 760 383 0.5; $C glide 760 383 1160 383 1.2 # servidores
$C glide 1160 383 695 70 0.6; $C glide 695 70 815 70 1.0     # agentes
$C glide 815 70 1228 65 0.8; sleep 0.4                       # contas de IA
$C glide 1228 65 755 70 0.5; $C click 755 70; sleep 2.6      # agente com problema
$C click 630 63; sleep 1.4                                   # volta
$C atalho; sleep 0.8; $C type "${Q2[$IDIOMA]}"; $C key 36; sleep 8.5
$C key 53; sleep 1.5
wait $REC
# vídeo da 0.3 (~26 s): Full → Light → estilos → Full → conta por modelo → copiados
$C move 1700 900
$C click 960 14; sleep 1.6
SEM_FUNDO=1 SEM_CURSOR=1 ./grava video estilos.mp4 26 480 0 960 760 >> prints.log 2>&1 &
REC=$!
sleep 1.2
V modo=light 2.2
for e in atividade neon orgulho pastel; do V estilo=$e 1.5; done
V modo=full 2.0
V estilo=classico 1.4
N pagina conta:claude; sleep 3.2
N pagina frota; sleep 1.4
V copiados=1 2.4
V copiados=0 0.8
wait $REC
$C key 53; sleep 1
fi
kill $DEMO 2>/dev/null
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/$ROT.plist" 2>/dev/null
# GIF do README: 15 qps, 720 px, paleta própria (fica leve e nítido)
# (corta o 1,4 s inicial de notch parado) GIF do README a 15 qps e 720 px com paleta própria; MP4 leve pra landing
[ -f uso.mp4 ] && ffmpeg -y -loglevel error -ss 1.4 -i uso.mp4 -vf "fps=15,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" uso.gif
[ -f uso.mp4 ] && ffmpeg -y -loglevel error -ss 1.4 -i uso.mp4 -an -c:v libx264 -crf 26 -preset slow -pix_fmt yuv420p -movflags +faststart uso-site.mp4
[ -f estilos.mp4 ] && ffmpeg -y -loglevel error -ss 0.8 -i estilos.mp4 -vf "fps=15,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" estilos.gif
# folha com 4 estilos lado a lado (2 × 2)
ls 14-estilo-atividade.png 14-estilo-neon.png 14-estilo-orgulho.png 14-estilo-pastel.png >/dev/null 2>&1 && ffmpeg -y -loglevel error \
  -i 14-estilo-atividade.png -i 14-estilo-neon.png -i 14-estilo-orgulho.png -i 14-estilo-pastel.png \
  -filter_complex "[0][1][2][3]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0,scale=iw/2:-1" 14-estilos.png
ls -la >> prints.log
osascript -e 'tell application "Terminal" to close (every window whose name contains ".command")' &
