"""Checagem dos idiomas: python3 teste_i18n.py
- toda chave usada no código (t("…") / N_("…") no Swift e no Python, mais i18n/extras.txt) existe em en, es e fr;
- os marcadores {0}, {1}… da tradução são os mesmos da chave;
- nenhuma chave sobrando nas tabelas (tabela limpa = dá pra revisar);
- nenhum texto de interface cru no Swift (Text("…"), Button("…"), Toggle("…")… sem t()).
Com --chaves imprime as chaves e onde aparecem (pra quem traduz)."""
import glob, json, os, re, sys

AQUI = os.path.dirname(os.path.abspath(__file__))
IDIOMAS = ['en', 'es', 'fr']
SWIFT = ['FleetNotch.swift', 'Ajustes.swift', 'Assistente.swift', 'Visual.swift']
PY = [f for f in sorted(glob.glob(os.path.join(AQUI, '*.py'))) if not os.path.basename(f).startswith(('teste', 'sonda'))]

# termos que não se traduzem (marca, sigla, unidade): um texto só com eles pode ficar cru no Swift
TECNICOS = set('''CPU GPU RAM SSD HDD USB Wi-Fi WiFi Tailscale Orca Hermes OpenClaw Claude Codex ChatGPT GPT Composio IMAP SSH Mac
macOS Thunderbolt Bluetooth GB MB KB TB IP DNS HTTP HTTPS URL API OK Linux VPS Raspberry Pi Gmail Outlook WhatsApp Telegram UAZAPI
Keychain iCloud Finder Dock Spotlight Docker systemd LaunchAgent JSON PID RPM dBm GHz Mbps Gbps Hz Studio mini Air Pro iMac
FleetNotch FleetNotch Fleetnotch'''.split())


def unescape_swift(s):
    return re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m.group(1), 16)), s).replace('\\"', '"').replace('\\n', '\n') \
        .replace('\\t', '\t').replace('\\\\', '\\')


def chaves():
    """{chave: [arquivo:linha, …]}"""
    achadas = {}
    for f in SWIFT:
        for n, l in enumerate(open(os.path.join(AQUI, f)), 1):
            for m in re.finditer(r'(?<![\w.])(?:t|N_)\(\s*"((?:[^"\\]|\\.)*)"', l):
                achadas.setdefault(unescape_swift(m.group(1)), []).append(f'{f}:{n}')
    for f in PY:
        nome = os.path.basename(f)
        for n, l in enumerate(open(f), 1):
            for m in re.finditer(r'''(?<![\w.])(?:t|N_)\(\s*(['"])((?:(?!\1)[^\\]|\\.)*)\1''', l):
                achadas.setdefault(bytes(m.group(2), 'utf-8').decode('unicode_escape').encode('latin-1').decode('utf-8'), []).append(f'{nome}:{n}')
    extras = os.path.join(AQUI, 'i18n', 'extras.txt')
    for l in open(extras):
        if l.strip() and not l.startswith('#'):
            achadas.setdefault(l.strip(), []).append('i18n/extras.txt')
    return achadas


def crus():
    """Texto de interface sem t() no Swift."""
    ruins = []
    padrao = re.compile(r'(?<![\w.])(Text|Button|Toggle|Label|Picker|Section|TextField|SecureField|Menu|LabeledContent|Link)\(\s*"((?:[^"\\]|\\.)*)"'
                        r'|\.(help|navigationTitle|accessibilityLabel)\(\s*"((?:[^"\\]|\\.)*)"')
    for f in SWIFT:
        for n, l in enumerate(open(os.path.join(AQUI, f)), 1):
            if l.lstrip().startswith('//'):
                continue
            for m in padrao.finditer(l):
                txt = m.group(2) if m.group(2) is not None else m.group(4)
                sem_interp = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', ' ', txt)
                palavras = [p for p in re.findall(r'[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ-]{2,}', sem_interp) if p not in TECNICOS]
                if palavras:
                    ruins.append(f'{f}:{n}: {txt[:70]}')
    return ruins


def marcadores(s):
    return sorted(set(re.findall(r'\{\d+\}', s)))


def main():
    usadas = chaves()
    if '--chaves' in sys.argv:
        for k, onde in sorted(usadas.items(), key=lambda kv: kv[1][0]):
            print(json.dumps(k, ensure_ascii=False), '\t', ', '.join(onde[:3]))
        return
    erros = []
    for c in IDIOMAS:
        tab = json.load(open(os.path.join(AQUI, 'i18n', f'{c}.json')))
        falta = [k for k in usadas if k not in tab]
        sobra = [k for k in tab if k not in usadas]
        trocado = [k for k in usadas if k in tab and marcadores(k) != marcadores(tab[k])]
        vazio = [k for k in usadas if k in tab and not tab[k].strip()]
        for nome, lista in (('falta', falta), ('sobra', sobra), ('marcador diferente', trocado), ('vazia', vazio)):
            if lista:
                erros.append(f'{c}: {len(lista)} {nome}: ' + ' | '.join(lista[:5]))
    cru = crus()
    if cru:
        erros.append(f'{len(cru)} textos de interface sem t() no Swift:\n  ' + '\n  '.join(cru[:15]))
    if erros:
        print('\n'.join(erros))
        sys.exit(1)
    print(f'ok i18n: {len(usadas)} chaves em {", ".join(IDIOMAS)} (+ português na fonte)')


if __name__ == '__main__':
    main()
