#!/bin/sh
# Compila o FleetNotch.app, instala em ~/Applications e liga no login (LaunchAgent do usuário).
# Sem config.json, o app abre o assistente de configuração.
# Rodar de novo = atualizar. Sem sudo. Desinstalar: README, seção "Uninstall" / "Desinstalar".
set -e
cd "$(dirname "$0")"
# sem as Command Line Tools o swiftc (e o /usr/bin/python3) é só um atalho que falha: avisa antes de mexer em qualquer coisa
if ! xcode-select -p >/dev/null 2>&1; then
  echo "FleetNotch is built on your Mac and needs Apple's Command Line Tools (free, no Xcode). Install them with:"
  echo "O FleetNotch é compilado no seu Mac e precisa das Command Line Tools da Apple (grátis, sem Xcode). Instale com:"
  echo
  echo "    xcode-select --install"
  echo
  echo "Then run ./install.sh again. / Depois rode ./install.sh de novo."
  exit 1
fi
APP="$HOME/Applications/FleetNotch.app"
ROT=app.fleetnotch
PL="$HOME/Library/LaunchAgents/$ROT.plist"

launchctl bootout "gui/$(id -u)/$ROT" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library FleetNotch.swift Ajustes.swift Assistente.swift Visual.swift -o "$APP/Contents/MacOS/FleetNotch"
# a config do usuário mora fora do app: ~/Library/Application Support/FleetNotch/config.json (sem segredo; segredo no Keychain)
cp coleta.py comum.py agentes.py caixas.py ajustes.py pergunta.py demo.py acoes.py modelos.py sonda.py sonda_linux.sh "$APP/Contents/Resources/"
# idiomas: as tabelas (o app e o Python leem as mesmas) e um .lproj por idioma, que faz o macOS listar o app em
# Ajustes do Sistema › Geral › Idioma e Região › Aplicativos; o pedido de Localização sai traduzido de cada tabela
cp -R i18n "$APP/Contents/Resources/"
/usr/bin/python3 - "$APP/Contents/Resources" <<'PY'
import json, os, sys
res = sys.argv[1]
pt = [l.strip() for l in open('i18n/extras.txt') if l.strip() and not l.startswith('#')][0]  # o texto do pedido de Localização
for l, c in (('pt-BR', None), ('en', 'en'), ('es', 'es'), ('fr', 'fr')):
    txt = json.load(open(f'i18n/{c}.json')).get(pt, pt) if c else pt
    os.makedirs(f'{res}/{l}.lproj', exist_ok=True)
    esc = txt.replace('\\', '\\\\').replace('"', '\\"')
    open(f'{res}/{l}.lproj/InfoPlist.strings', 'w').write(''.join(f'"{k}" = "{esc}";\n' for k in ('NSLocationUsageDescription', 'NSLocationWhenInUseUsageDescription')))
PY
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ROT</string>
  <key>CFBundleName</key><string>FleetNotch</string>
  <key>CFBundleExecutable</key><string>FleetNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Eduardo Cavalcanti</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string><string>es</string><string>fr</string></array>
  <key>NSLocationUsageDescription</key><string>Pra mostrar o nome da rede Wi-Fi na ilha: o macOS só entrega o nome da rede com Localização. A localização em si não é usada nem guardada.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Pra mostrar o nome da rede Wi-Fi na ilha: o macOS só entrega o nome da rede com Localização. A localização em si não é usada nem guardada.</string>
</dict></plist>
EOF
codesign -s - --force "$APP"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$ROT</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/FleetNotch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PL"
# statusline opcional pro anel do Claude (só com Claude Code instalado; ligar no settings.json: README, "Claude ring")
[ -d "$HOME/.claude" ] && cp statusline.py "$HOME/.claude/fleetnotch-statusline.py" && chmod +x "$HOME/.claude/fleetnotch-statusline.py"
echo "ok: $APP running / rodando (LaunchAgent $ROT)"
# o anel do Claude só enche com o statusline ligado no settings.json: se ainda não está, mostra a linha exata (já encadeada
# com o statusline que a pessoa tiver). Só LÊ o settings.json; quem edita é a pessoa (o app não mexe na config de outro programa)
[ -d "$HOME/.claude" ] && /usr/bin/python3 - "$HOME/.claude/settings.json" <<'PY'
import json, shlex, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except FileNotFoundError:
    d = {}
except ValueError:
    print(f'\nClaude ring / anel do Claude: {p} is not valid JSON / não é um JSON válido. See / veja README.md#claude-ring')
    sys.exit()
atual = ((d.get('statusLine') or {}) if isinstance(d, dict) else {}).get('command') or ''
atual = atual.strip() if isinstance(atual, str) else ''
if 'fleetnotch-statusline.py' in atual:
    sys.exit()  # já ligado
# o statusline.py repassa a entrada pros argumentos (sem shell): comando com pipe, ; ou && vai dentro de sh -c
if atual and any(c in atual for c in '|;&<>`'):
    atual = 'sh -c ' + shlex.quote(atual)
novo = '~/.claude/fleetnotch-statusline.py' + (' ' + atual if atual else '')
print('\nClaude ring / anel do Claude: one more step / falta um passo. In / no ' + p + ':')
print('    "statusLine": ' + json.dumps({'type': 'command', 'command': novo}, ensure_ascii=False))
if atual:
    print('Your current statusline keeps working: it gets the same input. / Seu statusline atual continua igual: recebe a mesma entrada.')
print('It saves only usage % and reset times. / Grava só % de uso e horário de reset. README.md#claude-ring')
PY
echo "uninstall / desinstalar: README.md#uninstall"
