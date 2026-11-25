#!/usr/bin/env python3
"""Coletor da barra: a cada `intervalo` s lê o Tailscale, sonda cada Mac (sonda.py) e cada servidor Linux
(sonda_linux.sh) em paralelo, local ou por SSH, e imprime UMA linha JSON já formatada. O app Swift só desenha o que
sai daqui. Tudo que é do usuário (máquinas, contas, agentes, limites) vem do config.json; segredo só no Keychain.
Rodar no terminal pra depurar: python3 coleta.py --uma"""
import calendar, glob, json, os, plistlib, re, signal, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

from comum import (CACHE, N_, _launchctl, _limpa, _novas, _rabo_curto, carregar, data_curta, decimal, dur, pct, run, t)

DIR = os.path.dirname(os.path.abspath(__file__))
CFG = carregar()
MOD = CFG['modulos']
LIM = {k: tuple(v) for k, v in CFG['aparencia']['limites'].items()}  # (atenção, crítico); disco = % LIVRE
SONDA = open(os.path.join(DIR, 'sonda.py')).read()
SONDA_LINUX = open(os.path.join(DIR, 'sonda_linux.sh')).read()
TS = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
CM = CACHE
os.makedirs(CM, exist_ok=True)  # o ControlPath do SSH mora aqui: sem a pasta, todo SSH falha
GB = 1024**3
PONTO = {0: '🟢', 1: '🟡', 2: '🔴', -1: '⚪️'}
# ControlMaster: reaproveita a conexão SSH entre ciclos (sem novo handshake a cada 20 s). %C = hash de usuário+host+porta;
# mora no ~/.ssh porque o caminho do socket tem limite de 104 bytes (na pasta de Caches o hash não cabia)
os.makedirs(os.path.expanduser('~/.ssh'), mode=0o700, exist_ok=True)
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'ControlMaster=auto', '-o', 'ControlPath=~/.ssh/cm-%C',
       '-o', 'ControlPersist=300']
# o que as sondas mandam e vira texto aqui (t(valor)): pressão e térmico do Mac, erro do docker no Linux
N_('normal'), N_('atenção'), N_('crítica'), N_('limitando'), N_('docker não instalado'), N_('sem acesso ao docker')


def tailnet():
    if not os.path.exists(TS):
        return {}
    _, out, _ = run([TS, 'status', '--json'], timeout=5)
    try:
        d = json.loads(out)
    except ValueError:
        return {}
    nodes = [dict(d['Self'], Online=True, _self=True)] + list((d.get('Peer') or {}).values())
    return {n['DNSName'].split('.')[0]: {'ip': n['TailscaleIPs'][0], 'online': bool(n.get('Online')), 'self': n.get('_self', False),
                                         'os': n.get('OS')}
            for n in nodes if n.get('DNSName') and n.get('TailscaleIPs')}


def resolver(host, rede):
    """Onde está a máquina: nome na Tailscale (curto ou MagicDNS) ou IP 100.x → IP e online de lá; "local" = este Mac;
    qualquer outro host (IP, nome, apelido do ~/.ssh/config) vai direto pelo SSH e o online sai da própria sonda."""
    h = (host or '').strip()
    if h.lower() in ('', 'local', 'localhost', '127.0.0.1'):
        return {'ip': '127.0.0.1', 'online': True, 'self': True}
    curto = h.split('.')[0].lower()
    for nome, n in rede.items():
        if n['ip'] == h or (not h[:1].isdigit() and nome.lower() == curto):
            # apelido do ~/.ssh/config com o mesmo nome da Tailscale: o online vem da Tailscale, mas o SSH vai pelo
            # apelido, que traz o HostName, o User, a IdentityFile e o known_hosts de lá (pelo IP nada disso vale)
            return dict(n, ssh=h) if h.lower() in apelidos_ssh() else n
    return {'ip': h, 'online': None, 'self': False}


SSH_CONFIG = os.path.expanduser('~/.ssh/config')
_APELIDOS = {'mtime': None, 'nomes': frozenset()}


def apelidos_ssh():
    """Os apelidos sem curinga das linhas Host do ~/.ssh/config (em minúsculas, como o ssh compara), relidos só
    quando o arquivo muda. Não segue Include nem Match: o que estiver só lá continua indo pelo IP da Tailscale."""
    try:
        mt = os.path.getmtime(SSH_CONFIG)
    except OSError:
        return frozenset()
    if _APELIDOS['mtime'] != mt:
        nomes = set()
        try:
            for linha in open(SSH_CONFIG, errors='replace'):
                m = re.match(r'\s*host\s+(.+)', linha, re.I)  # "Host x y", não "HostName"
                if m:
                    nomes.update(a.lower() for a in m.group(1).split() if not any(c in a for c in '*?!'))
        except OSError:
            return frozenset()
        _APELIDOS.update(mtime=mt, nomes=frozenset(nomes))
    return _APELIDOS['nomes']


def destino(m):
    u = m.get('usuario') or CFG.get('usuarioSSH')
    alvo = m.get('ssh') or m['ip']
    return f"{u}@{alvo}" if u else alvo


def erro_ssh(err):
    return t('sem chave SSH') if 'Permission denied' in err else t('host desconhecido') if 'Could not resolve' in err else \
        t('recusou a conexão') if 'refused' in err else t('não respondeu')


def sondar(no, lento):
    args = ['--lento'] if lento else []
    if no['self']:
        rc, out, err = run(['/usr/bin/python3', '-', *args], stdin=SONDA)
    else:
        rc, out, err = run([*SSH, destino(no), 'python3', '-', *args], stdin=SONDA)
    if rc == 0 and out.strip():
        try:
            return json.loads(out), None
        except ValueError:
            pass
    return None, erro_ssh(err)


SERVICO_OK = re.compile(r'^[\w@.:-]+$')  # nome de serviço systemd vira argumento no SSH: só o que não tem como virar comando


def sondar_linux(s):
    args = (['--docker'] if s.get('docker') else []) + [x for x in s.get('servicos') or [] if SERVICO_OK.match(x)]
    porta = ['-p', str(int(s['porta']))] if str(s.get('porta') or '22') != '22' else []
    rc, out, err = run([*SSH, *porta, destino(s), 'sh', '-s', '--', *args], stdin=SONDA_LINUX, timeout=20)
    if rc == 0 and out.strip():
        try:
            return json.loads(out.strip().splitlines()[-1]), None
        except ValueError:
            return None, t('resposta estranha (o shell de login imprime algo?)')
    return None, erro_ssh(err)


def nivel_de(chave, v):
    amar, verm = LIM[chave]
    return 0 if v is None or v < amar else 2 if v >= verm else 1


def nivel_disco(livre_pct):
    amar, verm = LIM['disco']
    return 0 if livre_pct >= amar else 2 if livre_pct < verm else 1


def _disco(nome):
    """'Interno' é como a sonda chama o disco do sistema: vira texto; o resto é nome de volume."""
    return t('Interno') if nome == 'Interno' else nome


def nivel(d):
    """Exigência (0 verde, 1 amarelo, 2 vermelho) e alertas. Disco cheio vira alerta (⚠️), não muda a cor:
    a cor diz quanto a máquina está sendo exigida."""
    n = max(nivel_de('cpu', d['cpu']), nivel_de('gpu', d['gpu']), nivel_de('ram', pct(d['ram']['usado'], d['ram']['total'])), nivel_de('temp', d['temp']))
    n = max(n, {'atenção': 1, 'crítica': 2}.get(d['pressao'], 0), 0 if d['termico'] == 'normal' else 1)
    alertas = [t('disco {0} com {1}% livre', _disco(x['nome']), pct(x['livre'], x['total'])) for x in d['discos'] if nivel_disco(pct(x['livre'], x['total']))]
    if d['pressao'] != 'normal':
        alertas.append(t('memória sob pressão ({0})', t(d['pressao'])))
    if d['termico'] != 'normal':
        alertas.append(t('macOS limitando por temperatura'))
    return n, alertas


def alerta(d):
    """O alerta mais importante, curto, pra ilha: {texto, nivel 1 atenção | 2 crítico, tipo memoria|calor|disco} ou None."""
    if d['pressao'] != 'normal':
        return {'texto': t('memória sob pressão'), 'nivel': 2 if d['pressao'] == 'crítica' else 1, 'tipo': 'memoria'}
    if d['termico'] != 'normal' or nivel_de('temp', d['temp']):
        return {'texto': t('limitando por calor · {0}°C', f"{d['temp']:.0f}") if d['temp'] else t('limitando por calor'),
                'nivel': max(1, nivel_de('temp', d['temp'])), 'tipo': 'calor'}
    cheios = sorted((pct(x['livre'], x['total']), x['nome']) for x in d['discos'] if nivel_disco(pct(x['livre'], x['total'])))
    if cheios:
        livre, nome = cheios[0]
        return {'texto': f"{t('Disco interno') if nome == 'Interno' else nome} · {t('{0}% livre', livre)}", 'nivel': nivel_disco(livre), 'tipo': 'disco'}
    return None


def extras(d):
    """Pros anéis que o usuário escolhe nos Ajustes: disco do sistema (% usado) e temperatura (°C)."""
    i = next((x for x in d['discos'] if x['nome'] == 'Interno'), (d['discos'] or [None])[0])
    r = {'disco': 100 - pct(i['livre'], i['total'])} if i else {}
    if d['temp'] is not None:
        r['temp'] = round(d['temp'])
    return r


def niveis_extras(d):
    x = extras(d)
    return dict({'disco': nivel_disco(100 - x['disco'])} if 'disco' in x else {}, **({'temp': nivel_de('temp', x['temp'])} if 'temp' in x else {}))


def detalhe(d, ip, plug):
    """Página de detalhe do Mac na ilha (estruturado; o menu da barra continua usando linhas())."""
    r = d['rede']
    return {'top': d['top'], 'temp': d['temp'], 'termico': d['termico'], 'pressao': d['pressao'],
            'swap': round(d['swap']['usado'] / GB, 2) if d['swap'] else None, 'carga': d['carga'],
            'discos': [{'nome': _disco(x['nome']), 'livre': round(x['livre'] / GB),
                        'total': round(x['total'] / GB), 'usado': 100 - pct(x['livre'], x['total'])} for x in d['discos']],
            # tudo que está conectado: o que a sonda viu + os discos externos montados (do df)
            'conectados': dict(plug, discos=[{'nome': x['nome'], 'livre': round(x['livre'] / GB), 'total': round(x['total'] / GB)}
                                             for x in d['discos'] if x['nome'] != 'Interno']) if plug else None,
            'tailscale': ip, 'rede': f"{r['tipo']} · {r['ip']}" if r else None,
            # rede estruturada: tráfego (bits/s, amostra da sonda), Wi-Fi (sinal, canal, banda, link) ou cabo (link)
            'net': dict({k: r.get(k) for k in ('tipo', 'ip', 'down', 'up', 'link', 'wifi')}, iface=r['if']) if r else None,
            'ligado': dur(d['uptime']), 'sistema': f"{d['modelo']} · macOS {d['macos']}"}


def linhas(d, ip, plug):
    ram, swap = d['ram'], d['swap']
    L = [t('CPU {0}% · carga {1}', d['cpu'], ' / '.join(f'{x:.1f}' for x in d['carga'])),
         f"GPU {d['gpu'] if d['gpu'] is not None else '?'}%",
         t('RAM {0} / {1} GB ({2}%) · pressão {3}', f"{ram['usado'] / GB:.1f}", f"{ram['total'] / GB:.0f}", pct(ram['usado'], ram['total']), t(d['pressao'])),
         f"Swap {swap['usado'] / GB:.2f} / {swap['total'] / GB:.0f} GB" if swap else 'Swap ?',
         t('Temp CPU {0}°C · térmico {1}', d['temp'], t(d['termico'])) if d['temp'] else t('Térmico {0}', t(d['termico'])),
         t('Ligado há {0} · {1} · macOS {2}', dur(d['uptime']), d['modelo'], d['macos']),
         '—',
         t('Top CPU: {0}', ' · '.join(f'{n} {p:.0f}%' for n, p in d['top']))]
    for disco in d['discos']:
        livre = pct(disco['livre'], disco['total'])
        L.append(('⚠️ ' if nivel_disco(livre) else '') + t('Disco {0}: {1} GB livres de {2} GB ({3}%)', _disco(disco['nome']), f"{disco['livre'] / GB:.0f}",
                                                           f"{disco['total'] / GB:.0f}", livre))
    r = d['rede']
    L.append(t('Rede {0} ({1}) {2} · Tailscale {3}', r['tipo'], r['if'], r['ip'], ip) if r else t('Rede ? · Tailscale {0}', ip))
    if plug:
        L.append(t('Monitores: {0}', ', '.join(f"{m['nome']} {m['res'] or ''}".strip() for m in plug['monitores']) or t('nenhum')))
        L.append('USB: ' + (', '.join(u['nome'] for u in plug['usb'] if not u['hub']) or t('nada')))
        L.append('Thunderbolt: ' + (', '.join(x['nome'] for x in plug['tb']) or t('nada')))
        L.append('Bluetooth: ' + (', '.join(b['nome'] + (f" {b['bateria']}%" if b['bateria'] is not None else '') for b in plug['bluetooth']) or t('nada')))
        if plug.get('audio'):
            L.append(t('Som: {0}', plug['audio']['nome']))
    return L


def card(d, plug):
    """Linhas curtas do card da ilha (notch)."""
    ram = pct(d['ram']['usado'], d['ram']['total'])
    L = [f"CPU {d['cpu']}% · GPU {d['gpu']}%", f"RAM {ram}% · {d['temp']:.0f}°C" if d['temp'] else f"RAM {ram}%"]
    if d['discos']:
        x = min(d['discos'], key=lambda x: x['livre'] / x['total'])
        livre = pct(x['livre'], x['total'])
        L.append(f"{'⚠️ ' if nivel_disco(livre) else ''}{_disco(x['nome'])} {t('{0}% livre', livre)}")
    if plug:
        n, u = len(plug['monitores']), len([x for x in plug['usb'] if not x['hub']])
        L.append((t('{0} monitor', n) if n == 1 else t('{0} monitores', n)) + f" · {u} USB" + (f" · {len(plug['tb'])} TB" if plug['tb'] else ''))
    return L


SERV_ESTADO = {'active': N_('rodando'), 'inactive': N_('parado'), 'failed': N_('falhou'), 'activating': N_('subindo'),
               'deactivating': N_('parando'), 'reloading': N_('recarregando'), 'unknown': N_('não existe')}


def servidor(s, d, erro):
    """Um servidor Linux pra ilha: medidas (CPU, RAM, o disco mais cheio), alertas (disco, serviço parado, container
    reiniciando ou doente) e o detalhe. Offline = a sonda não voltou."""
    base = {'id': s.get('id'), 'nome': s.get('nome') or s['host'], 'host': s['host']}
    if d is None:
        return dict(base, online=False, erro=erro, nivel=-1)
    ram = pct(d['ram']['usado'], d['ram']['total'])
    discos = [{'nome': x['nome'], 'livre': round(x['livre'] / GB), 'total': round(x['total'] / GB), 'usado': 100 - pct(x['livre'], x['total'])}
              for x in d['discos']]
    cheio = max(discos, key=lambda x: x['usado'], default=None)
    probs = []
    for x in discos:
        if nivel_disco(100 - x['usado']):
            probs.append({'nivel': nivel_disco(100 - x['usado']), 'texto': t('disco {0} com {1}% livre', x['nome'], 100 - x['usado']), 'tipo': 'disco'})
    for sv in d['servicos']:
        if sv['estado'] != 'active':
            probs.append({'nivel': 1 if sv['estado'] in ('activating', 'reloading') else 2,
                          'texto': f"{sv['nome']} {t(SERV_ESTADO.get(sv['estado'], sv['estado']))}", 'tipo': 'servico'})
    dk = d.get('docker') or {}
    conts = dk.get('containers') or []
    for c in conts:  # container parado de propósito (exited) não é problema; reiniciando em loop, morto ou doente é
        if c['estado'] in ('restarting', 'dead') or '(unhealthy)' in c['status']:
            probs.append({'nivel': 2 if c['estado'] != 'running' else 1,
                          'texto': t('container {0} reiniciando', c['nome']) if c['estado'] == 'restarting' else
                          t('container {0} doente', c['nome']) if c['estado'] == 'running' else t('container {0} morto', c['nome']),
                          'tipo': 'container'})
    probs.sort(key=lambda p: -p['nivel'])
    md = {'cpu': d['cpu'], 'ram': ram, 'disco': cheio['usado'] if cheio else 0}
    nv = max(nivel_de('cpu', d['cpu']), nivel_de('ram', ram))
    return dict(base, online=True, nivel=nv, medidas=md, niveis={'cpu': nivel_de('cpu', d['cpu']), 'ram': nivel_de('ram', ram),
                                                                   'disco': nivel_disco(100 - md['disco'])},
                alerta=dict(probs[0], mais=len(probs) - 1) if probs else None,
                detalhe={'sistema': d['so'] or 'Linux', 'kernel': d['kernel'], 'nome': d['host'], 'nucleos': d['nucleos'],
                         'ligado': dur(d['uptime']), 'carga': d['carga'],
                         'ram': t('{0} de {1} GB', f"{d['ram']['usado'] / GB:.1f}", f"{d['ram']['total'] / GB:.0f}"),
                         'swap': round((d.get('swap') or {}).get('usado', 0) / GB, 1),
                         'discos': discos, 'top': d['top'], 'servicos': d['servicos'],
                         'containers': conts, 'docker': t(dk['erro']) if dk.get('erro') else None, 'problemas': probs})


ORCA = os.path.expanduser('~/Library/Application Support/orca')
CLAUDE_RL = os.path.expanduser('~/.claude/deck-rate-limits.json')  # o statusline.py grava aqui (sem Orca)
DIAS = [t('dia|seg'), t('dia|ter'), t('dia|qua'), t('dia|qui'), t('dia|sex'), t('dia|sáb'), t('dia|dom')]  # o idioma não muda sem reiniciar o processo
MODELOS = {}  # último hw.model visto de cada máquina (pra miniatura de quem ficou offline)


def janela_claude(perfil):
    """Lê o cache de rate limit que o statusline.py grava (só %, reset; sem credencial): no ~/.claude, ou no perfil do Orca."""
    try:
        d = json.load(open(f'{ORCA}/claude-profiles/{perfil}/home/deck-rate-limits.json' if perfil else CLAUDE_RL))
    except (OSError, ValueError):
        return None, {}
    return d.get('ts'), {k: (v['used_percentage'], v['resets_at']) for k, v in d.get('rl', {}).items() if v}


def janela_codex():
    """Último evento rate_limits que o Codex CLI gravou nas sessões (~/.codex e homes do Orca)."""
    arqs = glob.glob(os.path.expanduser('~/.codex/sessions/**/*.jsonl'), recursive=True) + \
        glob.glob(f'{ORCA}/codex-accounts/*/home/sessions/**/*.jsonl', recursive=True)
    for f in sorted(arqs, key=os.path.getmtime, reverse=True)[:5]:
        with open(f, 'rb') as fh:
            fh.seek(max(0, os.path.getsize(f) - 400_000))
            for linha in reversed(fh.read().decode(errors='ignore').splitlines()):
                if '"rate_limits"' not in linha:
                    continue
                try:
                    rl = json.loads(linha)['payload']['rate_limits']
                except (ValueError, KeyError, TypeError):
                    continue
                nomes = {300: 'five_hour', 10080: 'seven_day'}
                return int(os.path.getmtime(f)), {nomes.get(w['window_minutes'], f"{w['window_minutes']}min"): (w['used_percent'], w['resets_at'])
                                                  for w in (rl.get('primary'), rl.get('secondary')) if w}
    return None, {}


LOGIN = {}  # (provedor, perfil) → (quando testou, logado): o teste de login roda no máximo a cada 5 min por conta


def login(c, agora):
    """A conta está logada? Pergunta ao próprio CLI (pergunta.logado, ~0,07 s, não gasta pergunta), com cache de 5 min.
    Token vencido o CLI não vê (o Codex diz "logado"): vale também o que a última pergunta descobriu (pergunta.anotado)."""
    import pergunta
    fonte = c.get('fonte') or (c.get('uso') or {}).get('fonte')
    chave = (c.get('perguntar') or {'claude-perfil': 'claude-cli', 'codex-sessoes': 'codex-cli'}.get(fonte), c.get('perfil') or None)
    if chave not in LOGIN or agora - LOGIN[chave][0] > 300:
        LOGIN[chave] = (agora, pergunta.logado(*chave))
    return False if agora - pergunta.anotado(*chave) < 900 else LOGIN[chave][1]  # uma pergunta viu token vencido há < 15 min


def conta(c, agora=None):
    agora = agora or time.time()
    fonte = c.get('fonte') or (c.get('uso') or {}).get('fonte')
    marca = {'id': c.get('id'), 'rotulo': c['nome'], 'ferramenta': c.get('ferramenta', c['nome']),
             'app': next((a for a in c.get('app', []) if os.path.exists(a)), None)}  # logo: lido do app em runtime pela UI
    if login(c, agora) is False:  # sem login (ou login vencido): a UI mostra "sem login" e o clique abre o Orca pra entrar
        return dict(marca, pct=0, nivel=-1, card=[t('sem login')], semLogin=True)
    if fonte == 'claude-perfil':
        visto, jan = janela_claude(c.get('perfil') or (c.get('uso') or {}).get('perfil'))
    elif fonte == 'codex-sessoes':
        visto, jan = janela_codex()
    else:  # ferramenta sem fonte local de uso: não inventa %
        return dict(marca, pct=0, nivel=-1, card=[t('sem dado de uso')], semFonte=True)
    jan = {k: v for k, v in jan.items() if v[1] > agora}  # janela que já resetou não vale mais
    if not jan:
        falta = [t('falta o statusline (ver README)')] if visto is None and fonte == 'claude-perfil' else []
        return dict(marca, pct=0, nivel=-1, card=[t('sem dado recente') if visto is None else t('janelas zeradas')] + falta)
    k, (p, reset) = max(jan.items(), key=lambda kv: kv[1][0])
    nv = 2 if p >= LIM['ia'][1] else 1 if p >= LIM['ia'][0] else 0
    nome = {'five_hour': '5h', 'seven_day': 'semana'}  # janela: código que o app compara ("5h"); na tela vai rotulo
    rotulo = {'five_hour': '5h', 'seven_day': t('semana')}
    L = [' · '.join(f"{rotulo.get(j, j)} {v[0]:.0f}%" for j, v in sorted(jan.items())),
         (t('NO LIMITE') + ' · ' if p >= 100 else '') + t('reseta {0} {1}', DIAS[time.localtime(reset).tm_wday],
                                                             data_curta(reset))]
    if visto:
        L.append(t('visto há {0}', dur(int(agora - visto))))
    quando = time.localtime(reset)
    return dict(marca, pct=round(p), nivel=nv, card=L, janela=nome.get(k, k),
                reset=f"{DIAS[quando.tm_wday]} {time.strftime('%H:%M', quando)}", limite=p >= 100)


SCFG = CFG.get('sincronizacao') or {}
DRIVE_LOG = os.path.expanduser('~/Library/Application Support/Google/DriveFS/Logs/drive_fs.txt')
DRIVE = {'estado': {}, 'quando': None, 'bloco': None, 'up': 0, 'erros': [], 'desce': []}  # o que já foi lido do log do Drive
PLISTS = {}  # plist → (mtime, conteúdo)
AGENTES = os.path.expanduser('~/Library/LaunchAgents')


def drive(agora, app):
    """Google Drive para desktop, só lendo o log dele (incremental): o bloco "Sync engine activity state" (uploads e
    downloads ativos, fila de operações, em dia com a nuvem) e cada upload/erro. Nada é escrito nem pedido ao app."""
    if not os.path.exists(DRIVE_LOG):
        return None
    for l in _novas(DRIVE_LOG, 2_000_000):
        if DRIVE['bloco'] is not None:
            m = re.match(r'([a-z_]+): (\S+)$', l)
            if m:
                DRIVE['bloco'][m.group(1)] = m.group(2)
                continue
            DRIVE['estado'], DRIVE['bloco'] = DRIVE['bloco'], None
        m = re.match(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.\d+Z([IWEF]) ', l)
        if not m:
            continue
        ts = calendar.timegm(time.strptime(m.group(1), '%Y-%m-%dT%H:%M:%S'))
        if 'Sync engine activity state:' in l:
            DRIVE['bloco'], DRIVE['quando'] = {}, ts
        elif 'Content upload of' in l:
            DRIVE['up'] = ts
        elif 'OnChangeNotificationReceived Generated' in l:  # a nuvem mudou e o espelho local vai baixar N itens
            n = re.search(r'Generated (\d+) download', l)
            DRIVE['desce'] = (DRIVE['desce'] + [(ts, int(n.group(1)) if n else 1)])[-300:]
        elif 'HandleFailedChange' in l:
            q = re.search(r'\[(\w+?)MergeQueueItem', l)
            st = re.search(r"Status='(\w+)'", l)
            DRIVE['erros'] = (DRIVE['erros'] + [(ts, (q.group(1) if q else 'item'), st.group(1) if st else t('erro'))])[-300:]
    e = DRIVE['estado']
    num = lambda k: int(e[k]) if str(e.get(k, '')).isdigit() else 0
    fresco = DRIVE['quando'] and agora - DRIVE['quando'] < 30 * 60
    erros = [x for x in DRIVE['erros'] if agora - x[0] < 3600]
    ult = DRIVE['erros'][-1] if DRIVE['erros'] else None
    return {'app': app,
            'subindo': num('active_uploads') if fresco else 0, 'baixando': num('active_downloads') if fresco else 0,
            'fila': num('operation_queue_size') if fresco else 0, 'emDia': e.get('change_ids_up_to_date') == 'true',
            'enviouHa': dur(int(agora - DRIVE['up'])) if DRIVE['up'] else None, 'ativo': bool(DRIVE['up'] and agora - DRIVE['up'] < 90),
            'recebeu': sum(n for t, n in DRIVE['desce'] if agora - t < 600),  # alterações vindas da nuvem nos últimos 10 min
            'errosHora': len(erros), 'ultimoErro': {'quando': dur(int(agora - ult[0])), 'tipo': {'Download': 'download'}.get(ult[1], 'upload'),
                                                     'motivo': ult[2]} if ult else None,
            'estadoHa': dur(int(agora - DRIVE['quando'])) if DRIVE['quando'] else None}


def rclone(agora, pids):
    """rclone rodando: o que copia (origem → destino), há quanto tempo e o que está aberto agora (os arquivos em
    trânsito). Progresso em % só se ele grava estatística num --log-file. Só olha os PIDs que o pgrep achou (listar a
    linha de comando de todos os processos custava ~40 ms de CPU por ciclo)."""
    if not pids:
        return []
    _, out, _ = run(['ps', '-o', 'pid=,etime=,args=', '-p', ','.join(pids)], timeout=5)
    r = []
    for l in out.splitlines():
        m = re.match(r'\s*(\d+)\s+(\S+)\s+(\S*/)?rclone\s+(sync|copy|move|copyto|moveto|bisync)\s+(.*)', l)
        if not m:
            continue
        toks = m.group(5).split()
        pos = [t for t in toks[:2] if not t.startswith('-')]
        if len(pos) < 2:
            continue
        orig, dest = pos[0], pos[1]
        if m.group(4) in ('copyto', 'moveto'):  # um arquivo só: ele é o que está em trânsito (sem lsof, um processo a menos)
            abertos = [orig]
        else:
            _, lo, _ = run(['lsof', '-n', '-P', '-Fn', '-p', m.group(1)], timeout=5)
            abertos = [x[1:] for x in lo.splitlines() if x.startswith('n/') and os.path.isfile(x[1:]) and x[1:].startswith(orig.rstrip('/') + '/')]
        prog = None
        lf = next((t.split('=', 1)[1] for t in toks if t.startswith('--log-file=')), None) or \
            next((toks[i + 1] for i, t in enumerate(toks[:-1]) if t == '--log-file'), None)
        if lf and os.path.exists(lf):
            for x in reversed(_rabo_curto(lf)):
                p = re.search(r'Transferred:\s+([\d.]+ \w+) / ([\d.]+ \w+), (\d+)%(?:, ([\d.]+ \w+/s))?(?:, ETA (\S+))?', x)
                if p:
                    prog = {'feito': _tam(p.group(1)), 'total': _tam(p.group(2)), 'pct': int(p.group(3)), 'vel': _tam(p.group(4)),
                            'eta': p.group(5) if p.group(5) != '-' else None}
                    break
        r.append({'pid': int(m.group(1)), 'cmd': m.group(4), 'origem': _curto(orig), 'destino': _curto(dest),
                  'ha': _etime(m.group(2)), 'arquivos': [os.path.basename(a) if a == orig else os.path.relpath(a, orig) for a in abertos[:5]], 'nAbertos': len(abertos),
                  'progresso': prog})
    return r


def _tam(t):
    """Tamanho do rclone em número de gente: '112.996 MiB' → '113 MiB', '4.142 MiB/s' → '4,1 MiB/s'."""
    m = re.match(r'([\d.]+)\s*(.*)', t or '')
    if not m:
        return t
    n = float(m.group(1))
    return (f'{n:.0f}' if n >= 10 or n == int(n) else decimal(f'{n:.1f}')) + ' ' + m.group(2)


def _curto(p):
    """Caminho local longo vira "…/pasta/arquivo" (o remoto, tipo gdrive:Backup, fica como está)."""
    p = p.replace(os.path.expanduser('~'), '~')
    partes = p.rstrip('/').split('/')
    return '…/' + '/'.join(partes[-2:]) if p[:1] in '/~' and len(p) > 40 and len(partes) > 3 else p


def _rabo_curto(p, n=8000):
    try:
        with open(p, 'rb') as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - n))
            return f.read().decode(errors='ignore').splitlines()
    except OSError:
        return []


def _etime(t):
    """etime do ps ('1-02:03:04', '02:03:04', '03:04') → '1d 2h' / '2h 3min' / '3min'."""
    d, _, hms = t.rpartition('-')
    p = [int(x) for x in hms.split(':')]
    s = (int(d or 0) * 86400) + (p[-3] * 3600 if len(p) == 3 else 0) + p[-2] * 60 + p[-1]
    return f'{s}s' if s < 60 else dur(s)


def _agendado(cal, agora):
    """Último horário em que o StartCalendarInterval mandou rodar (diário, ou num dia da semana)."""
    melhor = None
    for c in (cal if isinstance(cal, list) else [cal]):
        if 'Hour' not in c:
            continue
        for d in range(0, 8):
            t = time.localtime(agora - d * 86400)
            if 'Weekday' in c and (t.tm_wday + 1) % 7 != c['Weekday'] % 7:
                continue
            ts = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, c['Hour'], c.get('Minute', 0), 0, 0, 0, -1))
            if ts <= agora:
                melhor = max(melhor or 0, ts)
                break
    return melhor


def backups(agora):
    """LaunchAgents de backup do usuário: horário, se está rodando, o último registro (data do log) e se ATRASOU
    (passou o horário e o log não mudou depois dele) ou saiu com erro. Só lê."""
    lista = {l.split('\t')[2]: l.split('\t')[:2] for l in _launchctl().splitlines() if l.count('\t') == 2}
    r = []
    for pl in sorted(glob.glob(os.path.join(AGENTES, '*.plist'))):
        try:
            m = os.path.getmtime(pl)
            if pl not in PLISTS or PLISTS[pl][0] != m:
                PLISTS[pl] = (m, plistlib.load(open(pl, 'rb')))
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        d = PLISTS[pl][1]
        rot = d.get('Label', '')
        if not re.search(SCFG.get('agentes', r'backup'), rot):
            continue
        pid, st = lista.get(rot, ('-', '0'))
        logf = d.get('StandardOutPath') or d.get('StandardErrorPath')
        lm = os.path.getmtime(logf) if logf and os.path.exists(logf) else None
        cal, inter = d.get('StartCalendarInterval'), d.get('StartInterval')
        devido = _agendado(cal, agora) if cal else (agora - 2 * inter if inter else None)
        rodando = pid != '-'
        saida = int(st) if st.lstrip('-').isdigit() else 0
        estado = 'rodando' if rodando else 'erro' if saida else 'atrasado' if devido and (lm is None or lm < devido - 60) else 'ok'
        linha = next((x.strip() for x in reversed(_rabo_curto(logf, 4000)) if x.strip()), '') if logf else ''
        linha = re.sub(r'^[=\s\[]*\d{4}[-/]\d\d[-/]\d\d[ T]\d\d:\d\d(?::\d\d)?\]?[\s=:-]*', '', linha)  # a data já está em "última vez"
        hor = (cal if isinstance(cal, dict) else (cal or [{}])[0])
        r.append({'nome': re.sub(r'^(com|ai|io)\.[^.]+\.', '', rot), 'estado': estado, 'saida': saida or None,
                  'horario': f"{hor['Hour']:02d}:{hor.get('Minute', 0):02d}" if cal and 'Hour' in hor else (t('a cada {0} min', inter // 60) if inter else None),
                  'ultimo': {'hora': data_curta(lm), 'ha': dur(int(agora - lm))} if lm else None,
                  'linha': _limpa(linha, 90)})
    return r


def sincronizacao(agora=None):
    """Drive, rclone e backups num lugar só. seta = o que a pílula mostra: 'sobe' (rclone, backup ou o Drive enviando),
    'desce' (o Drive baixando arquivo); as alterações miúdas que o Drive recebe o tempo todo NÃO acendem a seta (ela
    ficaria sempre acesa e deixaria de dizer alguma coisa). nivel 1 = backup atrasado/com erro ou erro do Drive na
    última hora. resumo = a linha do card."""
    agora = agora or time.time()
    _, out, _ = run(['pgrep', '-lx', 'rclone|Google Drive'], timeout=5)  # um processo só serve os dois (~3 ms)
    vivos = [l.split(None, 1) for l in out.splitlines() if ' ' in l.strip()]
    dv = drive(agora, any(n.strip() == 'Google Drive' for _, n in vivos))
    rc, bk = rclone(agora, [p for p, n in vivos if n.strip() == 'rclone']), backups(agora)
    sobe = bool(rc) or any(b['estado'] == 'rodando' for b in bk) or bool(dv and (dv['subindo'] or dv['ativo']))
    seta = 'sobe' if sobe else 'desce' if dv and dv['baixando'] else None
    atras, erro = [b for b in bk if b['estado'] == 'atrasado'], [b for b in bk if b['estado'] == 'erro']
    nivel = 1 if atras or erro or (dv and dv['errosHora']) else 0
    partes = [f"rclone {j['cmd']} {os.path.basename(j['origem'].rstrip('/')) or j['origem']} → {j['destino']}"
              + (f" · {j['progresso']['pct']}%" if j['progresso'] else f" · {t('há {0}', j['ha'])}") for j in rc]
    partes += [t('{0} rodando', b['nome']) for b in bk if b['estado'] == 'rodando']
    if dv and (dv['subindo'] or dv['baixando']):
        partes.append('Drive ' + ' · '.join(x for x in (t('subindo {0}', dv['subindo']) if dv['subindo'] else '',
                                                        t('baixando {0}', dv['baixando']) if dv['baixando'] else '',
                                                        t('{0} na fila', dv['fila']) if dv['fila'] else '') if x))
    elif dv and dv['ativo']:
        partes.append(t('Drive enviando'))
    if erro:
        partes.append(t('{0} saiu com erro {1}', erro[0]['nome'], erro[0]['saida']) + (f" (+{len(erro) - 1})" if len(erro) > 1 else ''))
    if atras:
        partes.append(t('{0} não rodou às {1}', atras[0]['nome'], atras[0]['horario']) if len(atras) == 1 else
                      t('{0} backups não rodaram no horário', len(atras)))
    if dv and dv['errosHora']:
        partes.append(t('Drive: {0} erro na última hora', 1) if dv['errosHora'] == 1 else t('Drive: {0} erros na última hora', dv['errosHora']))
    nprob = bool(erro) + bool(atras) + bool(dv and dv['errosHora'])
    problema = '  ·  '.join(partes[len(partes) - nprob:]) or None
    ativas = partes[:len(partes) - nprob]
    parado = t('Drive fechado') if dv and not dv['app'] else t('Drive em dia') + (f" · {t('último envio há {0}', dv['enviouHa'])}" if dv and dv['enviouHa'] else '') \
        if dv else t('Nada sincronizando')
    if not partes:
        partes.append(parado)
    return {'ativo': sobe or seta is not None, 'seta': seta, 'nivel': nivel, 'resumo': '  ·  '.join(partes), 'problema': problema,
            'atividade': '  ·  '.join(ativas) or parado,
            'drive': dv, 'rclone': rc, 'backups': bk}


ORCA_BIN = '/Applications/Orca.app/Contents/Resources/bin/orca'
ORCA_E = {'ps': 0, 'aut': 0, 'dado': None, 'aut_dado': {}}
ESPERA = {'waiting', 'blocked', 'needs-input', 'needs_input', 'input', 'permission', 'question', 'awaiting-input'}
FALHA = {'failed', 'error', 'errored', 'timed_out', 'timeout', 'dispatch_failed', 'launch_failed', 'crashed'}


def _orca(*args):
    rc, out, _ = run([ORCA_BIN, *args, '--json'], timeout=12)
    try:
        d = json.loads(out)
        return d.get('result') if d.get('ok', True) else None
    except (ValueError, AttributeError):
        return None


def orca(agora):
    """Orca, só leitura, pelo próprio CLI: workspaces e agentes rodando, quem está esperando você (e o que ficou pronto
    pra você ver), automações ativas e o último erro delas. Nunca lê prompt nem resposta de agente: só contagens.
    O CLI é um Electron (~0,14 s de CPU por chamada): `worktree ps` a cada 3 min em segundo plano e na hora em que a gaveta
    abre (SIGUSR2); automações a cada 10 min."""
    if not os.path.exists(ORCA_BIN):
        return None
    if agora - ORCA_E['ps'] >= 180:
        ORCA_E['ps'] = agora
        r = _orca('worktree', 'ps', '--agent-wait')
        if r is None:
            ORCA_E['dado'] = {'aberto': False, 'nivel': -1}
        else:
            wts = [w for w in r.get('worktrees') or [] if not w.get('isArchived')]
            ags = [a for w in wts for a in w.get('agents') or []]
            esperando = [a for a in ags if a.get('agentWait') or str(a.get('state')).lower() in ESPERA]
            ORCA_E['dado'] = {'aberto': True,
                              'workspaces': sum(1 for w in wts if w.get('sidebarStatus') in ('active', 'working', 'monitoring') or w.get('liveTerminalCount')),
                              'rodando': sum(1 for a in ags if a.get('state') == 'working'),
                              'workers': sum(1 for a in ags if a.get('state') == 'working' and a.get('parentPaneKey')),
                              'esperando': len(esperando),
                              'revisar': sum(1 for a in ags if a.get('state') == 'done' and (a.get('activity') or {}).get('unread'))}
    if agora - ORCA_E['aut'] >= 600 and (ORCA_E['dado'] or {}).get('aberto'):
        ORCA_E['aut'] = agora
        a = _orca('automations', 'list') or {}
        auts = a.get('automations') or a.get('items') or []
        nomes = {x.get('id'): x.get('name') for x in auts}
        runs = (_orca('automations', 'runs', '--limit', '30') or {}).get('runs') or []
        ruins = [x for x in runs if str(x.get('status')).lower() in FALHA]
        ult = max(ruins, key=lambda x: float(x.get('startedAt') or x.get('createdAt') or 0), default=None)
        ts = float(ult.get('startedAt') or ult.get('createdAt') or 0) / 1000 if ult else 0
        ORCA_E['aut_dado'] = {'automacoes': sum(1 for x in auts if x.get('enabled')),
                              'erro': {'nome': _limpa(nomes.get(ult.get('automationId')) or ult.get('title') or t('automação'), 40),
                                       'texto': _limpa(str(ult.get('error') or ult.get('status')), 70), 'ts': ts} if ult else None}
    d = ORCA_E['dado']
    if not d or not d.get('aberto'):
        return d
    r = dict(d, **ORCA_E['aut_dado'])
    if r.get('erro'):
        r['erro'] = dict(r['erro'], ha=dur(max(0, int(agora - r['erro']['ts']))))
    r['nivel'] = 1 if r['esperando'] else 0
    return r


def painel_ok():
    try:
        urllib.request.urlopen(CFG['painel'], timeout=1)
        return True
    except Exception:
        return False


def ciclo(n, cache_plug, pedido=False):
    import agentes, caixas  # noqa: E401 (só aqui: o teste troca o CFG antes)
    agora = time.time()
    maqs_cfg = CFG['maquinas'] if MOD['macs'] else []
    srvs_cfg = CFG['servidores'] if MOD['servidores'] else []
    rede = tailnet() if maqs_cfg or srvs_cfg else {}
    lento = n % max(1, CFG['lento'] // CFG['intervalo']) == 0
    maqs = [dict(m, **resolver(m.get('host') or m.get('ts'), rede)) for m in maqs_cfg]
    srvs = [dict(s, **resolver(s.get('host'), rede)) for s in srvs_cfg]
    with ThreadPoolExecutor(8) as ex:
        fm = [ex.submit(lambda m=m: sondar(m, lento or m['ip'] not in cache_plug) if m['online'] is not False else (None, t('offline no Tailscale')))
              for m in maqs]
        fs = [ex.submit(lambda s=s: sondar_linux(s) if s['online'] is not False else (None, t('offline no Tailscale'))) for s in srvs]
        fe = ex.submit(caixas.estado, CFG['email'], agora, pedido) if MOD['email'] and CFG['email']['contas'] else None
        fa = ex.submit(agentes.estado, CFG['agentes'], agora) if MOD['agentes'] and CFG['agentes'] else None
        res, rs = [f.result() for f in fm], [f.result() for f in fs]
        email, ags = fe.result() if fe else None, fa.result() if fa else None
    saida, pior, avisos = [], None, False
    for m, (d, erro) in zip(maqs, res):
        host = m.get('host') or m.get('ts')
        ident = {'ts': host, 'local': m['self'], 'curto': m.get('curto') or m['nome'], 'nome': m['nome'], 'id': m.get('id')}
        if d is None:
            saida.append(dict(ident, titulo=f"{PONTO[-1]} {m['nome']} — {erro}", linhas=[f"Tailscale {m['ip']}"], nivel=-1,
                              modelo=m.get('icone') or MODELOS.get(host, m.get('modelo')), card=[erro]))
            continue
        MODELOS[host] = d['modelo']
        if 'plugados' in d:
            cache_plug[m['ip']] = d['plugados']
        plug = cache_plug.get(m['ip'])
        nv, alertas = nivel(d)
        avisos = avisos or bool(alertas)
        carga = max(d['cpu'] or 0, d['gpu'] or 0)
        if pior is None or (nv, carga) > (pior[0], pior[1]):
            pior = (nv, carga, f"{ident['curto']} {'GPU' if (d['gpu'] or 0) > (d['cpu'] or 0) else 'CPU'} {carga}%")
        saida.append(dict(ident, titulo=f"{PONTO[nv]} {m['nome']} — CPU {d['cpu']}% · GPU {d['gpu']}% · RAM {pct(d['ram']['usado'], d['ram']['total'])}%"
                                        + (' ⚠️' if alertas else ''),
                          linhas=[f'⚠️ {a}' for a in alertas] + linhas(d, m['ip'], plug), nivel=nv,
                          modelo=m.get('icone') or d['modelo'], card=card(d, plug),
                          # campos estruturados pra ilha desenhar medidores em vez de texto
                          medidas=dict({'cpu': d['cpu'] or 0, 'gpu': d['gpu'] or 0, 'ram': pct(d['ram']['usado'], d['ram']['total']), 'carga': carga}, **extras(d)),
                          niveis=dict({k: nivel_de(k, v) for k, v in (('cpu', d['cpu']), ('gpu', d['gpu']), ('ram', pct(d['ram']['usado'], d['ram']['total'])))},
                                      **niveis_extras(d)),
                          alerta=alerta(d), detalhe=detalhe(d, m['ip'], plug)))
    servidores = [servidor(s, d, e) for s, (d, e) in zip(srvs, rs)]
    return {'barra': f"{PONTO[pior[0]]} {pior[2]}{' ⚠️' if avisos else ''}" if pior else ('⚪️ ' + t('frota offline') if maqs else '⚪️'),
            'pico': f"{pior[2]}{' ⚠️' if avisos else ''}" if pior else (t('frota offline') if maqs else ''), 'nivel': pior[0] if pior else -1,
            'atualizado': time.strftime('%H:%M:%S'), 'painel': CFG['painel'] if CFG.get('painel') and painel_ok() else None,
            'semConfig': not (CFG['maquinas'] or CFG['servidores'] or CFG['ia'] or CFG['agentes'] or CFG['email']['contas']),
            'maquinas': saida, 'servidores': servidores,
            'contas': [conta(c) for c in CFG['ia']] if MOD['ia'] else [],
            'agentes': ags, 'email': email, 'orca': orca(agora) if MOD.get('orca', os.path.exists(ORCA_BIN)) else None,
            'sincronizacao': sincronizacao() if MOD['sincronizacao'] else None}


ACORDA = threading.Event()
PEDIDO = {'email': False}


def _sinal(*_):
    """SIGUSR1 = o app pediu o último cabeçalho do e-mail agora (a página de e-mail abriu): roda um ciclo já."""
    PEDIDO['email'] = True
    ACORDA.set()


def _olhando(*_):
    """SIGUSR2 = a gaveta abriu: quem olha vê dado fresco (o Orca, que é lido de 3 em 3 min, relê agora)."""
    ORCA_E['ps'] = 0
    ACORDA.set()


def main():
    os.makedirs(CM, exist_ok=True)
    signal.signal(signal.SIGUSR1, _sinal)
    signal.signal(signal.SIGUSR2, _olhando)
    cache_plug, n = {}, 0
    while True:
        t0 = time.time()
        pedido, PEDIDO['email'] = PEDIDO['email'], False
        try:
            print(json.dumps(ciclo(n, cache_plug, pedido), ensure_ascii=False), flush=True)
        except BrokenPipeError:  # o app fechou: sai junto
            return
        except Exception as e:
            print(json.dumps({'barra': '⚪️ ' + t('erro'), 'erro': repr(e)[:300], 'maquinas': []}), flush=True)
        if '--uma' in sys.argv or os.getppid() == 1:  # ppid 1 = o app morreu e deixou a gente órfão
            return
        n += 1
        ACORDA.wait(max(3, CFG['intervalo'] - (time.time() - t0)))
        ACORDA.clear()


if __name__ == '__main__':
    main()
