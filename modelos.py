"""Uso por modelo de cada conta de IA, só leitura e só local: soma os tokens que o Claude Code e o Codex já gravam nos
próprios registros (JSONL) e estima o custo por uma tabela de preços local. Nada sai do Mac, nenhuma API é chamada.

  python3 modelos.py --conta <id>   JSON com hoje / 7 dias / mês, modelo a modelo (a página da conta na gaveta)
  python3 modelos.py --aquecer      só atualiza o cache (o app roda uma vez ao abrir, em segundo plano)
  python3 modelos.py --precos       a tabela de preços padrão (os Ajustes mostram e editam; a editada mora no config.json)
  python3 modelos.py --demo         dados fictícios (modo demonstração)

Fontes: Claude Code grava cada resposta em <config>/projects/**/*.jsonl (~/.claude, ou o home de cada perfil do Orca);
o Codex grava em ~/.codex/sessions/**/*.jsonl (e no home de cada conta do Orca). Perfis que apontam pra mesma pasta
(link simbólico) são lidos uma vez só e a página avisa que o histórico é compartilhado.

Incremental: cada arquivo é lido só a partir de onde parou; o cache (~/Library/Caches/<App>/modelos.json) guarda, por
arquivo, até onde leu e o total por dia e por modelo. Arquivo que não mudou nem é aberto. Parado, nada roda."""
import calendar, fcntl, glob, json, os, re, sys, time
from comum import CACHE, carregar, t

ORCA = os.path.expanduser('~/Library/Application Support/orca')
ARQ = os.path.join(CACHE, 'modelos.json')
DIAS_GUARDA = 40  # o mês inteiro + folga; dia mais velho que isso sai do cache

# USD por milhão de tokens: entrada, saída, leitura de cache, escrita de cache (5 min e 1 h). Prefixo do id do modelo:
# vale o mais longo que casar ("claude-opus-5-5" antes de "claude-opus-5"). Preços públicos da Anthropic (nov/2026);
# os da OpenAI ficam em branco de propósito: o app não inventa preço (os Ajustes deixam preencher).
PRECOS = [
    {'modelo': 'claude-fable-5-2', 'entrada': 8, 'saida': 40, 'cacheLe': 0.2, 'cache5m': 10, 'cache1h': 16},
    {'modelo': 'claude-mythos-5-2', 'entrada': 8, 'saida': 40, 'cacheLe': 0.2, 'cache5m': 10, 'cache1h': 16},
    {'modelo': 'claude-fable-5-1', 'entrada': 10, 'saida': 50, 'cacheLe': 0.25, 'cache5m': 12.5, 'cache1h': 20},
    {'modelo': 'claude-fable-5', 'entrada': 10, 'saida': 50, 'cacheLe': 1, 'cache5m': 12.5, 'cache1h': 20},
    {'modelo': 'claude-opus-5-5', 'entrada': 4, 'saida': 20, 'cacheLe': 0.2, 'cache5m': 5, 'cache1h': 8},
    {'modelo': 'claude-opus-5', 'entrada': 5, 'saida': 25, 'cacheLe': 0.5, 'cache5m': 6.25, 'cache1h': 10},
    {'modelo': 'claude-opus-4', 'entrada': 5, 'saida': 25, 'cacheLe': 0.5, 'cache5m': 6.25, 'cache1h': 10},
    {'modelo': 'claude-sonnet-5-5', 'entrada': 2, 'saida': 10, 'cacheLe': 0.1, 'cache5m': 2.5, 'cache1h': 4},
    {'modelo': 'claude-sonnet-5', 'entrada': 2, 'saida': 10, 'cacheLe': 0.2, 'cache5m': 2.5, 'cache1h': 4},
    {'modelo': 'claude-sonnet-4', 'entrada': 3, 'saida': 15, 'cacheLe': 0.3, 'cache5m': 3.75, 'cache1h': 6},
    # ponytail: Haiku 5.5 custa 5× acima de 100 mil tokens de prompt; aqui vale a faixa de baixo (o uso típico)
    {'modelo': 'claude-haiku-5-5', 'entrada': 0.1, 'saida': 0.5, 'cacheLe': 0.01, 'cache5m': 0.125, 'cache1h': 0.2},
    {'modelo': 'claude-haiku-4-5', 'entrada': 1, 'saida': 5, 'cacheLe': 0.1, 'cache5m': 1.25, 'cache1h': 2},
]
CAMPOS = ('entrada', 'saida', 'cacheLe', 'cache5m', 'cache1h')

RM = re.compile(rb'"model":"([^"]+)"')
RID = re.compile(rb'"id":"([^"]+)"')
RTS = re.compile(rb'"timestamp":"(\d{4}-\d\d-\d\dT\d\d:\d\d)')
RNUM = re.compile(rb'\d+')
DIA = {}  # "2026-11-24T12:08" (UTC) → dia local: um strptime por minuto distinto, não por mensagem


def dia(ts):
    if ts not in DIA:
        DIA[ts] = time.strftime('%Y-%m-%d', time.localtime(calendar.timegm(time.strptime(ts, '%Y-%m-%dT%H:%M'))))
    return DIA[ts]


def _n(b, chave, de=0):
    i = b.find(chave, de)
    if i < 0:
        return 0
    m = RNUM.match(b, i + len(chave))
    return int(m.group()) if m else 0


def somar(dias, d, modelo, v):
    """v = [entrada, saída, cache lido, cache escrito 5 min, cache escrito 1 h]; o 6º número conta as respostas."""
    linha = dias.setdefault(d, {}).setdefault(modelo, [0, 0, 0, 0, 0, 0])
    for i, x in enumerate(v):
        linha[i] += x
    linha[5] += 1


def linha_claude(l, st, vistos):
    """Uma resposta do Claude Code: a linha "assistant" com message.usage. O Claude Code grava uma linha por bloco de
    conteúdo da MESMA resposta (mesmo id, mesmo usage): conta uma vez só."""
    j = l.find(b'"usage":{')
    if j < 0 or b'"type":"assistant"' not in l:
        return
    m, mid, ts = RM.search(l), RID.search(l), RTS.search(l, j)
    if not m or not ts or m.group(1).startswith(b'<'):  # "<synthetic>": mensagem de erro do próprio CLI, sem custo
        return
    k = mid.group(1).decode() if mid else None
    if k and (k in vistos or k in st['ids']):
        return
    if k:
        vistos.add(k)
        st['ids'] = (st['ids'] + [k])[-64:]
    u = l[j:]
    cw = _n(u, b'"cache_creation_input_tokens":')
    c1 = _n(u, b'"ephemeral_1h_input_tokens":')
    modelo = m.group(1).decode() + ('|fast' if b'"speed":"fast"' in u else '')
    somar(st['d'], dia(ts.group(1).decode()), modelo,
          [_n(u, b'"input_tokens":'), _n(u, b'"output_tokens":'), _n(u, b'"cache_read_input_tokens":'), max(0, cw - c1), c1])


def linha_codex(l, st, vistos):
    """Codex: o modelo vem do turn_context mais recente do arquivo; o uso, do token_usage_record (um por resposta, com
    response_id). Codex mais antigo só tem token_count: aí vale o last_token_usage dele."""
    if b'"turn_context"' in l[:200]:
        m = RM.search(l)
        if m:
            st['m'] = m.group(1).decode()
        return
    tur = b'"token_usage_record"' in l[:200]
    if not tur and (st.get('tur') or b'"token_count"' not in l):
        return
    try:
        d = json.loads(l)
        p = d['payload']
        u = p['usage'] if tur else (p.get('info') or {}).get('last_token_usage')
        ts = RTS.search(l)
    except (ValueError, KeyError, TypeError):
        return
    if not u or not ts:
        return
    if tur:
        st['tur'] = True
        k = p.get('response_id')
        if k and (k in vistos or k in st['ids']):
            return
        if k:
            vistos.add(k)
            st['ids'] = (st['ids'] + [k])[-64:]
    lido = u.get('cached_input_tokens') or 0
    somar(st['d'], dia(ts.group(1).decode()), st.get('m') or 'gpt',
          [max(0, (u.get('input_tokens') or 0) - lido), u.get('output_tokens') or 0, lido, u.get('cache_write_input_tokens') or 0, 0])


def ler(caminho, st, tipo, vistos):
    """Lê o arquivo do ponto onde parou até a última linha completa (aos pedaços: tem log de centenas de MB)."""
    tamanho = os.path.getsize(caminho)
    if tamanho < st['o']:  # foi reescrito: começa de novo
        st.update(o=0, d={}, ids=[], tur=False)
    if tamanho == st['o']:
        return
    fn = linha_claude if tipo == 'claude' else linha_codex
    chave = b'"usage":{' if tipo == 'claude' else b'\n'
    with open(caminho, 'rb') as fh:
        fh.seek(st['o'])
        resto = b''
        while True:
            pedaco = fh.read(8 << 20)
            if not pedaco:
                break
            buf = resto + pedaco
            fim = buf.rfind(b'\n')
            if fim < 0:
                # ponytail: linha sem fim por mais de 64 MB é resultado de ferramenta gigante (nunca uma resposta com usage): pula
                resto = buf if len(buf) < 64 << 20 else b''
                if not resto:
                    st['o'] += len(buf)
                continue
            # só as linhas que interessam (no Claude, as que têm "usage"), achadas sem quebrar o pedaço inteiro em linhas
            i = 0
            while True:
                j = buf.find(chave, i, fim) if tipo == 'claude' else (i if i < fim else -1)
                if j < 0:
                    break
                a = buf.rfind(b'\n', 0, j) + 1 if tipo == 'claude' else j
                b = buf.find(b'\n', j)
                if b > a:
                    fn(buf[a:b], st, vistos)
                i = b + 1
            st['o'] += fim + 1
            resto = buf[fim + 1:]


def fontes(c):
    """(tipo, [pastas reais]) de onde vem o uso desta conta."""
    fonte = c.get('fonte') or (c.get('uso') or {}).get('fonte')
    if fonte == 'claude-perfil':
        p = c.get('perfil') or (c.get('uso') or {}).get('perfil')
        base = f'{ORCA}/claude-profiles/{p}/home' if p else os.path.expanduser('~/.claude')
        return 'claude', [os.path.realpath(os.path.join(base, 'projects'))]
    if fonte == 'codex-sessoes':
        dirs = [os.path.expanduser('~/.codex/sessions')] + glob.glob(f'{ORCA}/codex-accounts/*/home/sessions')
        return 'codex', sorted({os.path.realpath(d) for d in dirs})
    return None, []


def janelas(agora):
    """Primeiro dia (local) de cada janela: hoje, os últimos 7 dias (hoje incluso) e o mês corrente."""
    lt = time.localtime(agora)
    hoje = time.strftime('%Y-%m-%d', lt)
    sete = time.strftime('%Y-%m-%d', time.localtime(agora - 6 * 86400))
    return {'hoje': hoje, '7d': sete, 'mes': time.strftime('%Y-%m-01', lt)}


def atualizar(pastas, agora=None):
    """Lê o que entrou desde a última vez em todas as pastas e devolve o cache (com trava: o aquecimento do app e a
    página aberta podem rodar juntos)."""
    agora = agora or time.time()
    os.makedirs(CACHE, exist_ok=True)
    with open(ARQ + '.trava', 'w') as trava:
        fcntl.flock(trava, fcntl.LOCK_EX)
        try:
            cache = json.load(open(ARQ))
            assert cache.get('v') == 1
        except (OSError, ValueError, AssertionError):
            cache = {'v': 1, 'arq': {}}
        corte = agora - DIAS_GUARDA * 86400
        menor = time.strftime('%Y-%m-%d', time.localtime(corte))
        vistos = set()  # ponytail: dedupe entre arquivos só dentro desta leitura (cópia de sessão "fork" lida em dias diferentes contaria 2×; não vi acontecer)
        for tipo, raiz in pastas:
            for d, _, fs in os.walk(raiz, followlinks=True):
                for f in fs:
                    if not f.endswith('.jsonl'):
                        continue
                    p = os.path.join(d, f)
                    try:
                        mt = os.path.getmtime(p)
                    except OSError:
                        continue
                    if mt < corte:  # nada recente aqui (e o que já estava no cache sai no corte abaixo)
                        continue
                    st = cache['arq'].setdefault(p, {'o': 0, 'd': {}, 'ids': [], 'k': tipo})
                    try:
                        ler(p, st, tipo, vistos)
                    except OSError:
                        continue
                    st['t'] = mt
        for p in list(cache['arq']):
            st = cache['arq'][p]
            st['d'] = {k: v for k, v in st['d'].items() if k >= menor}
            if st.get('t', 0) < corte or not os.path.exists(p):
                del cache['arq'][p]
        tmp = ARQ + '.tmp'
        with open(tmp, 'w') as fh:
            json.dump(cache, fh, separators=(',', ':'))
        os.replace(tmp, ARQ)
    return cache


def preco(modelo, tabela):
    m = modelo.split('|')[0]
    casa = [p for p in tabela if p.get('modelo') and m.startswith(p['modelo'])]
    return max(casa, key=lambda p: len(p['modelo'])) if casa else None


def custo(v, p, fast):
    """USD. Modo rápido (fast) do Claude custa o dobro na entrada e na saída."""
    if not p or any(not isinstance(p.get(k), (int, float)) for k in CAMPOS):
        return None
    f = 2 if fast else 1
    return (v[0] * p['entrada'] * f + v[1] * p['saida'] * f + v[2] * p['cacheLe'] + v[3] * p['cache5m'] + v[4] * p['cache1h']) / 1e6


def nome(modelo):
    """'claude-opus-5-5' → 'Opus 5.5'; 'gpt-6.2-sol' → 'GPT-6.2 Sol'; 'claude-sonnet-4-5-20250929' → 'Sonnet 4.5'."""
    base, _, extra = modelo.partition('|')
    partes = [x for x in base.split('-') if x and not (x.isdigit() and len(x) == 8)]
    if partes and partes[0] == 'gpt' and len(partes) > 1:
        partes = ['GPT-' + partes[1]] + partes[2:]
    elif partes and partes[0] == 'claude':
        partes = partes[1:]
    r, num = [], []
    for x in partes:
        if x.isdigit():
            num.append(x)
            continue
        if num:
            r.append('.'.join(num))
            num = []
        r.append(x if x[:1].isupper() else x.capitalize())
    if num:
        r.append('.'.join(num))
    return ' '.join(r) + (' · fast' if extra == 'fast' else '')


def resumo(conta, cfg, agora=None):
    agora = agora or time.time()
    tipo, dirs = fontes(conta)
    if not tipo:
        return {'erro': t('Esta conta não tem fonte local de uso (Ajustes › IA › De onde vem o uso).')}
    cache = atualizar([(tipo, d) for d in dirs], agora)
    tabela = cfg.get('precos') or PRECOS
    ini = janelas(agora)
    soma = {j: {} for j in ini}
    por_dia = {}
    arquivos = 0
    for p, st in cache['arq'].items():
        if not any(p == d or p.startswith(d.rstrip('/') + '/') for d in dirs):
            continue
        arquivos += 1
        for d, mods in st['d'].items():
            for m, v in mods.items():
                if d >= ini['7d']:
                    dd = por_dia.setdefault(d, [0, 0.0])
                    dd[0] += sum(v[:5])
                    dd[1] += custo(v, preco(m, tabela), m.endswith('|fast')) or 0
                for j, de in ini.items():
                    if d >= de:
                        a = soma[j].setdefault(m, [0, 0, 0, 0, 0, 0])
                        for i in range(6):
                            a[i] += v[i]
    saida = {}
    for j, mods in soma.items():
        lista, total, sem = [], 0.0, []
        for m, v in mods.items():
            c = custo(v, preco(m, tabela), m.endswith('|fast'))
            if c is None:
                sem.append(nome(m))
            total += c or 0
            lista.append({'id': m, 'nome': nome(m), 'entrada': v[0], 'saida': v[1], 'cacheLe': v[2], 'cacheEscreve': v[3] + v[4],
                          'respostas': v[5], 'custo': None if c is None else round(c, 4)})
        lista.sort(key=lambda x: (-(x['custo'] or 0), -(x['entrada'] + x['saida'] + x['cacheLe'] + x['cacheEscreve'])))
        saida[j] = {'modelos': lista, 'custo': round(total, 4), 'semPreco': sorted(set(sem)),
                    'tokens': sum(x['entrada'] + x['saida'] + x['cacheLe'] + x['cacheEscreve'] for x in lista)}
    hoje = time.localtime(agora)
    dias = [time.strftime('%Y-%m-%d', time.localtime(time.mktime(hoje) - (6 - i) * 86400)) for i in range(7)]
    outros = [c.get('nome') for c in cfg.get('ia') or [] if c.get('id') != conta.get('id') and fontes(c)[0] == tipo and set(fontes(c)[1]) & set(dirs)]
    return {'conta': conta.get('id'), 'tipo': tipo, 'janelas': saida, 'arquivos': arquivos, 'compartilhado': outros,
            'dias': [{'dia': d, 'tokens': por_dia.get(d, [0, 0])[0], 'custo': round(por_dia.get(d, [0, 0])[1], 4)} for d in dias]}


def demo(agora=None):
    """Uma conta fictícia, sempre a mesma (prints do README)."""
    agora = agora or time.time()

    def jan(f):
        ms = [('claude-opus-5-5', 'Opus 5.5', 41_200, 1_930_000, 61_800_000, 2_100_000, 1480),
              ('claude-fable-5-2', 'Fable 5.2', 8_400, 412_000, 9_300_000, 640_000, 212),
              ('claude-sonnet-5-5', 'Sonnet 5.5', 3_100, 288_000, 7_900_000, 410_000, 190),
              ('claude-haiku-5-5', 'Haiku 5.5', 9_800, 96_000, 1_200_000, 88_000, 340)]
        lista = []
        for i, nm, e, s, cl, ce, r in ms:
            v = [round(e * f), round(s * f), round(cl * f), round(ce * f), 0]
            lista.append({'id': i, 'nome': nm, 'entrada': v[0], 'saida': v[1], 'cacheLe': v[2], 'cacheEscreve': v[3], 'respostas': round(r * f),
                          'custo': round(custo(v, preco(i, PRECOS), False), 4)})
        return {'modelos': lista, 'custo': round(sum(x['custo'] for x in lista), 4), 'semPreco': [],
                'tokens': sum(x['entrada'] + x['saida'] + x['cacheLe'] + x['cacheEscreve'] for x in lista)}
    curva = [0.55, 0.8, 0.35, 1.0, 0.9, 0.62, 0.74]
    base = jan(1)
    return {'conta': 'demo', 'tipo': 'claude', 'janelas': {'hoje': jan(0.14), '7d': base, 'mes': jan(3.6)}, 'arquivos': 214, 'compartilhado': [],
            'dias': [{'dia': time.strftime('%Y-%m-%d', time.localtime(agora - (6 - i) * 86400)), 'tokens': round(base['tokens'] / 5.2 * c),
                      'custo': round(base['custo'] / 5.2 * c, 4)} for i, c in enumerate(curva)]}


def main():
    a = sys.argv[1:]
    if '--precos' in a:
        print(json.dumps({'precos': PRECOS}))
        return
    if '--demo' in a:
        print(json.dumps(demo()))
        return
    cfg = carregar()
    if '--aquecer' in a:
        os.nice(10)
        pastas = {(f[0], d) for c in cfg['ia'] for f in [fontes(c)] if f[0] for d in f[1]}
        atualizar(sorted(pastas))
        print(json.dumps({'ok': True}))
        return
    if '--conta' in a:
        cid = a[a.index('--conta') + 1]
        conta = next((c for c in cfg['ia'] if c.get('id') == cid), None)
        print(json.dumps(resumo(conta, cfg) if conta else {'erro': t('Conta não encontrada')}, ensure_ascii=False))
        return
    print(__doc__)


if __name__ == '__main__':
    main()
