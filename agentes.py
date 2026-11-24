"""Status de agentes de IA (plugável), SÓ LENDO: nunca reinicia, nunca manda mensagem, nunca escreve no agente.

Cada agente do config.json tem um `tipo`:
  hermes    Hermes Agent: `home` (padrão ~/.hermes) e `perfil` (vazio = o principal; senão um dos perfis servidos pelo
            gateway, em <home>/profiles/<perfil>). Lê os LaunchAgents (`rotulo`, padrão ai.hermes.), gateway_state.json e
            a batida, crons (jobs.json, ticker, cron-watchdog), kanban (sqlite imutável) e as linhas novas dos logs.
  openclaw  OpenClaw: `porta` do gateway (padrão 18789, GET /readyz), LaunchAgent (`rotulo`, padrão ai.openclaw.gateway)
            e o log (~/Library/Logs/openclaw/gateway.log).
  generico  qualquer outro: `url` de health (2xx = no ar), `rotulo` de LaunchAgent e `log` (último erro, última atividade).
Opcional em qualquer tipo: instâncias de WhatsApp na UAZAPI (`uazapiURL` + `instancias`), com o admintoken no Keychain
(conta "uazapi:<host>"). Saída de cada um: estado, nivel, canais, problemas, erro, atividade e o que o tipo souber a mais."""
import glob, json, os, re, sqlite3, time, urllib.error, urllib.parse, urllib.request

from datetime import date
from pathlib import Path

from comum import run, ACHADO, N_, _iso, _json, _json_m, _limpa, _novas, dur, quando, segredo, servicos, t

UAZ = {}  # url → (quando, dado): a UAZAPI é consultada a cada 5 min, não a cada ciclo


def _x(p):
    return os.path.expanduser(p) if p else p


def uazapi(a, agora):
    """Status das instâncias na UAZAPI (GET /instance/all com o admintoken do Keychain, só em memória). Devolve só nome e
    status; nunca imprime, grava nem devolve token."""
    url, inst = (a.get('uazapiURL') or '').rstrip('/'), a.get('instancias') or {}
    if not url or not inst:
        return None
    if url in UAZ and agora - UAZ[url][0] < 300:
        return UAZ[url][1]
    try:
        tok = segredo('uazapi:' + urllib.parse.urlparse(url).netloc)
        if not tok:
            dado = [{'nome': 'UAZAPI', 'status': t('sem token (Ajustes › Agentes)')}]
        else:
            req = urllib.request.Request(url + '/instance/all', headers={'admintoken': tok, 'Accept': 'application/json'})
            todas = {i.get('name'): i for i in json.load(urllib.request.urlopen(req, timeout=4))}
            dado = [{'nome': rot, 'status': (todas.get(n) or {}).get('status', t('sumiu'))} for n, rot in inst.items()]
    except Exception as e:  # sem rede, token errado, formato mudou: diz o tipo do erro, nunca o conteúdo
        dado = [{'nome': 'UAZAPI', 'status': t('erro ({0})', type(e).__name__)}]
    UAZ[url] = (agora, dado)
    return dado


ESTADOS = {'connected': N_('conectado'), 'disconnected': N_('desconectado'), 'fatal': N_('fora (fatal)'), 'connecting': N_('conectando')}
# estado do agente: o app compara ("no ar", "sem acesso") e traduz na hora de mostrar (t(estado)); 'respondeu {0}' já sai traduzido
N_('no ar'), N_('travado'), N_('parado'), N_('estacionado'), N_('fora do gateway'), N_('sem acesso'), N_('iniciando'), N_('pede atenção')


def canal(nome, estado):
    return {'nome': nome, 'estado': t(ESTADOS.get(estado, estado or '—')),
            'nivel': -1 if estado is None else 0 if estado in ('connected', 'running') else 1 if estado == 'connecting' else 2}


def _ultimo_erro(logs):
    """Última linha ERROR/CRITICAL dos logs (leitura incremental; o achado fica entre ciclos)."""
    melhor = None
    for lg in logs:
        for l in _novas(lg):
            m = re.match(r'(\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d)[,.\d]*\S*\s+(?:\[[^\]]*\]\s+)?(?:ERROR|CRITICAL|FATAL|error)\b[\s:]+(?:\[[^\]]*\]\s+)?(?:[\w.]+: )?(.*)', l)
            if m:
                ts = time.mktime(time.strptime(m.group(1).replace('T', ' '), '%Y-%m-%d %H:%M:%S'))
                ACHADO[lg] = {'ts': ts, 'texto': _limpa(m.group(2))}
        if lg in ACHADO and (melhor is None or ACHADO[lg]['ts'] > melhor['ts']):
            melhor = ACHADO[lg]
    return melhor


def hermes(a, agora):
    raiz = _x(a.get('home') or '~/.hermes')
    perfil = (a.get('perfil') or '').strip()
    principal = perfil in ('', 'default')
    casa = raiz if principal else f'{raiz}/profiles/{perfil}'
    if not os.path.isdir(casa):
        return {'estado': 'sem acesso', 'nivel': -1}
    serv = servicos(a.get('rotulo') or 'ai.hermes.')
    g = _json(f'{raiz}/gateway_state.json') or {}
    hb = _iso((_json(f'{raiz}/state/gateway.heartbeat') or {}).get('updated_at'))
    gw = next((s for s in serv if s['nome'] == 'gateway'), None)
    vivo = bool(gw and gw['pid']) and g.get('gateway_state') == 'running'
    fresco = hb is not None and agora - hb < 180
    estado = 'no ar' if vivo and fresco else 'travado' if vivo else 'parado'
    if estado == 'no ar' and not principal:  # perfil: o gateway (multiplex) tem que estar servindo ele
        if perfil in (g.get('parked_profiles') or {}):
            estado = 'estacionado'
        elif g.get('served_profiles') and perfil not in g['served_profiles']:
            estado = 'fora do gateway'
    plat = g.get('platforms') or {}
    meus = {k: v for k, v in plat.items() if ':' not in k} if principal else \
        {k.split(':', 1)[1]: v for k, v in plat.items() if k.startswith(perfil + ':')}
    canais = [canal({'whatsapp': 'WhatsApp', 'telegram': 'Telegram'}.get(k, k.title()), v.get('state')) for k, v in sorted(meus.items())]
    uaz = uazapi(a, agora)
    if uaz:
        ruim = [i for i in uaz if i['status'] != 'connected']
        wa = next((c for c in canais if c['nome'] == 'WhatsApp'), None)
        if wa is None:
            canais.append(dict(canal('WhatsApp', 'connected' if not ruim else 'disconnected'), nivel=1 if ruim else 0))
        elif ruim and wa['nivel'] == 0:
            wa['nivel'] = 1
    perfis = [{'nome': k.replace(':', ' · '), 'estado': v.get('state')} for k, v in plat.items() if ':' in k and v.get('needs_attention')] \
        if principal else []
    jobs = (_json_m(f'{casa}/cron/jobs.json') or {}).get('jobs', [])
    ativos = [j for j in jobs if j.get('enabled') and j.get('state') == 'scheduled']
    falhando = [j for j in ativos if j.get('last_status') == 'error']
    prox = min(((_iso(j.get('next_run_at')), j.get('name', '')) for j in ativos if _iso(j.get('next_run_at'))), default=None)
    try:
        tick = float(open(f'{raiz}/cron/ticker_heartbeat').read().split()[0])
    except (OSError, ValueError, IndexError):
        tick = None
    # o cron-watchdog é um só (na raiz) e vigia os jobs de todos os perfis: cada agente fica com os problemas dos SEUS
    # jobs; o principal fica também com o que não é de perfil nenhum
    wd = _json(f'{raiz}/state/cron-watchdog/status.json') or {}
    meus = {j.get('id') for j in jobs}
    if principal:
        alheios = {j.get('id') for p in glob.glob(f'{raiz}/profiles/*/cron/jobs.json') for j in (_json_m(p) or {}).get('jobs', [])}
    problemas = {}  # o watchdog repete o mesmo job em chaves diferentes (execution:<id>, job_status:<id>): um por job
    for i in wd.get('issues', []):
        job = i.get('key', '').split(':')[-1]
        if job in meus or (principal and job not in alheios):
            problemas.setdefault(job, {'titulo': _limpa(i.get('title', '')), 'nivel': 2 if i.get('severity') == 'critical' else 1})
    problemas = list(problemas.values())
    kb = {}
    try:
        quadro = open(f'{casa}/kanban/current').read().strip()
        c = sqlite3.connect(f'file:{casa}/kanban/boards/{quadro}/kanban.db?mode=ro&immutable=1', uri=True, timeout=1)
        kb = dict(c.execute('select status, count(*) from tasks group by status').fetchall())
        c.close()
        kb = {'quadro': quadro, 'fila': kb.get('todo', 0) + kb.get('triage', 0), 'rodando': kb.get('running', 0) + kb.get('in_progress', 0),
              'bloqueados': kb.get('blocked', 0), 'revisar': kb.get('review', 0)}
    except Exception:
        kb = {}
    ult = None
    if principal:  # o principal responde no gateway: última mensagem recebida/resposta enviada (nunca o texto)
        lg = f'{raiz}/logs/gateway.log'
        for l in _novas(lg):
            m = re.match(r'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),\d+ INFO gateway\.run: (inbound message|response ready): platform=(\w+)', l)
            if m:
                ACHADO[lg] = {'ts': time.mktime(time.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')), 'canal': m.group(3),
                              'tipo': t('mensagem recebida') if m.group(2) == 'inbound message' else t('resposta enviada')}
        ult = ACHADO.get(lg)
    else:  # perfil: o log do próprio agente diz quando ele trabalhou pela última vez
        try:
            ult = {'ts': os.path.getmtime(f'{casa}/logs/agent.log'), 'canal': None, 'tipo': t('trabalho')}
        except OSError:
            ult = None
    erro = _ultimo_erro([f'{casa}/logs/gateway.error.log'] if principal else [f'{casa}/logs/errors.log', f'{casa}/logs/gateway.error.log'])
    nivel = -1 if estado == 'sem acesso' else 2 if estado in ('parado', 'travado', 'fora do gateway') or any(c['nivel'] >= 2 for c in canais) else \
        1 if estado == 'estacionado' or problemas or falhando or any(c['nivel'] == 1 for c in canais) or (tick and agora - tick > 300) else 0
    return {'estado': estado, 'nivel': nivel, 'agentes': g.get('active_agents') if principal else None, 'versao': g.get('code_version'),
            'servicos': serv if principal else None, 'canais': canais, 'uazapi': uaz, 'perfis': perfis,
            'crons': {'ativos': len(ativos), 'falhando': len(falhando), 'agendador': bool(tick and agora - tick < 300),
                      'proximo': dict(quando(prox[0], agora), nome=_limpa(prox[1], 48)) if prox else None},
            'kanban': kb, 'problemas': problemas, 'erro': dict(quando(erro['ts'], agora), texto=erro['texto']) if erro else None,
            'atividade': dict(quando(ult['ts'], agora), canal=ult.get('canal'), tipo=ult['tipo']) if ult else None,
            'batida': quando(hb, agora), 'avatar': next((p for p in (f'{casa}/assets/avatar.png',) if os.path.exists(p)), None)}


def _http(url, timeout=2):
    """(código, json|None); 0 = nem conectou."""
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers={'Accept': 'application/json'}), timeout=timeout)
        corpo, cod = r.read(65536), r.status
    except urllib.error.HTTPError as e:
        corpo, cod = e.read(65536), e.code
    except Exception:
        return 0, None
    try:
        return cod, json.loads(corpo)
    except ValueError:
        return cod, None


def _log(a, padrao):
    lg = _x(a.get('log') or padrao)
    if not lg or not os.path.exists(lg):
        return None, None
    try:
        at = os.path.getmtime(lg)
    except OSError:
        at = None
    return _ultimo_erro([lg]), at


def openclaw(a, agora):
    porta = int(a.get('porta') or 18789)
    rot = a.get('rotulo') or 'ai.openclaw.gateway'
    serv = servicos(rot)
    cod, j = _http(f'http://127.0.0.1:{porta}/readyz')
    falhas = [str(x) for x in (j or {}).get('failing') or []]
    if cod == 200:
        estado = 'no ar'
    elif cod == 503:
        estado = 'iniciando' if (j or {}).get('status') == 'starting' else 'pede atenção'
    elif cod:
        estado = t('respondeu {0}', cod)
    else:
        estado = 'parado' if serv or os.path.isdir(_x(a.get('home') or '~/.openclaw')) else 'sem acesso'
    # "channel:whatsapp:default" → canal WhatsApp com problema; o resto vira problema com o nome que o OpenClaw deu
    canais, problemas = {}, []
    for f in falhas:
        p = f.split(':')
        if p[0] in ('channel', 'channels') and len(p) > 1:
            canais[p[1]] = canal(p[1].title().replace('Whatsapp', 'WhatsApp'), 'disconnected')
        else:
            problemas.append({'titulo': _limpa(f, 60), 'nivel': 1})
    erro, at = _log(a, '~/Library/Logs/openclaw/gateway.log')
    nivel = -1 if estado == 'sem acesso' else 0 if estado == 'no ar' else 1 if estado in ('iniciando', 'pede atenção') and not canais else 2
    return {'estado': estado, 'nivel': nivel, 'canais': list(canais.values()), 'problemas': problemas, 'servicos': serv,
            'uazapi': uazapi(a, agora), 'erro': dict(quando(erro['ts'], agora), texto=erro['texto']) if erro else None,
            'atividade': dict(quando(at, agora), canal=None, tipo='log') if at else None, 'porta': porta}


def generico(a, agora):
    serv = servicos(a['rotulo']) if a.get('rotulo') else []
    cod, _ = _http(a['url']) if a.get('url') else (None, None)
    vivo_l = any(s['pid'] for s in serv) if serv else None
    if cod is not None:
        estado = 'no ar' if 200 <= cod < 300 else 'parado' if cod == 0 else t('respondeu {0}', cod)
    elif vivo_l is not None:
        estado = 'no ar' if vivo_l else 'parado'
    else:
        estado = 'sem acesso'
    erro, at = _log(a, None)
    uaz = uazapi(a, agora)
    canais = [dict(canal('WhatsApp', 'connected' if all(i['status'] == 'connected' for i in uaz) else 'disconnected'))] if uaz else []
    nivel = -1 if estado == 'sem acesso' else 0 if estado == 'no ar' and not any(c['nivel'] for c in canais) else 2 if estado != 'no ar' else 1
    return {'estado': estado, 'nivel': nivel, 'canais': canais, 'problemas': [], 'servicos': serv or None, 'uazapi': uaz,
            'erro': dict(quando(erro['ts'], agora), texto=erro['texto']) if erro else None,
            'atividade': dict(quando(at, agora), canal=None, tipo='log') if at else None}


def cacheado(segundos):
    def decorar(ler):
        cache = {}

        def consultar(a, agora):
            chave = json.dumps(a, sort_keys=True)
            if chave not in cache or not 0 <= agora - cache[chave][0] < segundos:
                cache[chave] = (agora, ler(a, agora))
            return cache[chave][1]
        return consultar
    return decorar


def cartao(canais=(), problemas=(), estado=None, nivel=None, atividade=None):
    if nivel is None:
        nivel = max((item['nivel'] for item in (*canais, *problemas)), default=0)
    return dict(canais=list(canais), problemas=list(problemas), estado=estado or t('pede atenção' if nivel else 'no ar'),
                nivel=nivel, atividade=atividade, erro=None)


VERCEL = 'https://api.vercel.com/v6/deployments'
META = 'https://graph.facebook.com'


class SemRedirecionamento(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None  # Authorization só pode chegar ao endpoint original.


def api(url, parametros, token):
    req = urllib.request.Request(url + '?' + urllib.parse.urlencode(parametros),
                                 headers={'Authorization': 'Bearer ' + token})
    try:
        with urllib.request.build_opener(SemRedirecionamento).open(req, timeout=8) as resposta:
            dados = json.load(resposta)
    except urllib.error.HTTPError as erro:
        with erro:
            try:
                dados = json.load(erro)
            except ValueError:
                raise ValueError('HTTP ' + str(erro.code)) from None
        if not isinstance(dados, dict) or not dados.get('error'):
            raise ValueError('HTTP ' + str(erro.code))
    if dados.get('error'):
        mensagem = dados['error'].get('message') or t('pede atenção')
        raise ValueError(_limpa(' '.join(mensagem.replace(token, '…').split())))
    return dados


@cacheado(300)
def sites(a, agora):
    canais, problemas = [], []
    projetos = a.get('vercelProjetos') or {}
    token = segredo('vercel') if projetos else None
    for site in a.get('sites', []):
        nome, url = site['nome'], site['url']
        inicio = time.monotonic()
        try:
            if urllib.parse.urlsplit(url).scheme not in ('http', 'https'):
                raise ValueError()
            req = urllib.request.Request(url, headers={'User-Agent': 'painel-notch/1.0'})
            with urllib.request.urlopen(req, timeout=8) as resposta:
                lento = time.monotonic() - inicio > 3
                nivel = int(lento) if 200 <= resposta.status < 300 else 2
        except (OSError, ValueError):
            nivel = 2
        canais.append(dict(nome=nome, estado=t(('no ar', N_('lento'), 'fora do ar')[nivel]), nivel=nivel))
        if token and projetos.get(nome):
            try:
                lista = api(VERCEL, dict(projectId=projetos[nome], limit=1), token)['deployments']
                if lista and lista[0].get('state', lista[0].get('readyState')) in ('ERROR', 'CANCELED'):
                    problemas.append(dict(titulo=t('deploy com erro: {0}', nome), nivel=2))
            except (OSError, ValueError, KeyError):
                problemas.append(dict(titulo=t('falha ao consultar deploy: {0}', nome), nivel=1))
    return cartao(canais, problemas, atividade=dict(quando(agora, agora), tipo=t('última checagem'), canal=None))


@cacheado(600)
def metaads(a, agora):
    conta = a.get('conta', '')
    token = segredo('meta:' + conta) if conta else None
    if not token:
        return cartao(estado=t('sem acesso'), nivel=-1)
    base = '/'.join((META, urllib.parse.quote(a.get('versao') or 'v21.0', safe=''), urllib.parse.quote(conta, safe='')))
    try:
        linhas = api(base + '/insights', dict(date_preset='today', fields='spend,actions'), token)['data']
        gasto = sum(float(x.get('spend', 0)) for x in linhas)
        conversas = sum(int(y['value']) for x in linhas for y in x.get('actions', [])
                        if y['action_type'] == 'onsite_conversion.messaging_conversation_started_7d')
        params = dict(effective_status='["ACTIVE"]', fields='id', limit=100)
        campanhas = 0
        while True:
            pagina = api(base + '/campaigns', params, token)
            campanhas += len(pagina['data'])
            paging = pagina.get('paging', {})
            if not paging.get('next'):
                break
            cursor = paging['cursors']['after']
            if cursor == params.get('after'):
                raise ValueError(t('pede atenção'))
            params['after'] = cursor
    except (OSError, ValueError, KeyError, TypeError) as erro:
        msg = str(erro) if type(erro) is ValueError else type(erro).__name__
        return cartao(problemas=[dict(titulo=_limpa(msg.replace(token, '…')), nivel=1)])
    canais = [dict(nome=t('Gasto hoje'), estado='R$ ' + f'{gasto:.2f}'.replace('.', ','), nivel=0),
              dict(nome=t('Conversas'), estado=str(conversas), nivel=0),
              dict(nome=t('Campanhas no ar'), estado=str(campanhas), nivel=0)]
    problemas = []
    if not campanhas:
        problemas.append(dict(titulo=t('nenhuma campanha no ar'), nivel=2))
    if conversas and a.get('cplMax') is not None and gasto / conversas > a['cplMax']:
        problemas.append(dict(titulo=t('custo por conversa acima do limite'), nivel=1))
    return cartao(canais, problemas)


@cacheado(120)
def git(a, agora):
    pasta = Path(_x(a.get('pasta') or '~/Desktop/projects'))
    if not pasta.is_dir():
        return cartao(estado=t('sem acesso'), nivel=-1)
    alertas, pendentes = [], set()
    for repo in sorted(pasta.iterdir()):
        if not (repo / '.git').exists():
            continue
        cmd = ['git', '--no-optional-locks', '-c', 'core.fsmonitor=false', '-C', str(repo)]
        rc, saida, _ = run(cmd + ['status', '--porcelain', '-z', '-uall', '--no-renames'], timeout=8)
        if rc:
            alertas.append((agora, t('{0}: falha ao ler status', repo.name)))
            pendentes.add(repo)
            continue
        datas = []
        for item in filter(None, saida.split('\0')):
            caminho = repo / item[3:]
            try:
                datas.append(caminho.lstat().st_mtime)
            except FileNotFoundError:
                while not caminho.exists() and caminho != repo:
                    caminho = caminho.parent
                datas.append(caminho.stat().st_mtime)
        if datas and agora - max(datas) > float(a.get('dias', 1)) * 86400:
            dias = int((agora - max(datas)) // 86400)
            alertas.append((max(datas), t('{0}: alterações sem commit há {1} dias', repo.name, dias)))
            pendentes.add(repo)
        rc, valor, _ = run(cmd + ['rev-list', '--count', '@{u}..HEAD'], timeout=8)
        if not rc and int(valor):
            _, datas_commit, _ = run(cmd + ['log', '--format=%ct', '@{u}..HEAD'], timeout=8)
            mais_antigo = min(map(int, datas_commit.split()), default=agora)
            alertas.append((mais_antigo, t('{0}: {1} commits sem push', repo.name, valor.strip())))
            pendentes.add(repo)
    return cartao(estado=t('{0} repos pendentes', len(pendentes)) if pendentes else t('tudo salvo'),
                  problemas=[dict(titulo=msg, nivel=1) for _, msg in sorted(alertas)[:8]])


@cacheado(60)
def foco(a, agora):
    try:
        linhas = Path(_x(a.get('arquivo') or '')).read_text(encoding='utf-8').splitlines()
        texto = '\n'.join(linhas).replace('**', '').replace('__', '')
        semana = date.fromisoformat(re.search(r'(?im)^\s*(?:#+\s*)?Semana de:\s*(\d{4}-\d\d-\d\d)', texto)[1])
    except (OSError, TypeError, ValueError):
        return cartao(estado=t('sem acesso'), nivel=-1)
    problemas = []
    if (date.fromtimestamp(agora) - semana).days > 7:
        problemas.append(dict(titulo=t('foco vencido, rode o /revisar'), nivel=1))
    secao, prioridades = 0, []
    for linha in linhas:
        titulo = re.match(r'^\s*(#{1,6})\s+(.+)', linha)
        destaque = re.match(r'^\s*\*\*(Prioridade\s+\d+\b.*?)\*\*', linha, re.I)
        if destaque:
            prioridades.append(destaque[1])
        elif titulo:
            if 'prioridade' in titulo[2].lower():
                secao = len(titulo[1])
                if re.search(r'\bprioridade\s+\d+', titulo[2], re.I):
                    prioridades.append(titulo[2])
            elif secao and len(titulo[1]) > secao:
                prioridades.append(titulo[2])
            else:
                secao = 0
        elif secao:
            item = re.match(r'^\s*\d+[.)]\s+(.+)', linha)
            if item:
                prioridades.append(item[1])
        if len(prioridades) == 3:
            break
    # links de wiki ([[Nota]] ou [[Nota|apelido]]) viram só o texto
    prioridades = [re.sub(r'\[\[(?:[^\]|]*\|)?([^\]]*)\]\]', r'\1', p) for p in prioridades]
    problemas.extend(dict(titulo=_limpa(p.strip('* '), 60), nivel=0) for p in prioridades)
    return cartao(problemas=problemas)


TIPOS = {'sites': sites, 'metaads': metaads, 'git': git, 'foco': foco, 'hermes': hermes, 'openclaw': openclaw, 'generico': generico}


def estado(lista, agora=None):
    """Todos os agentes configurados, na ordem do config. Um agente que quebra não derruba os outros."""
    agora = agora or time.time()
    r = []
    for a in lista:
        try:
            e = TIPOS.get(a.get('tipo') or 'generico', generico)(a, agora)
        except Exception as ex:
            e = {'estado': 'sem acesso', 'nivel': -1, 'problemas': [{'titulo': t('erro lendo o agente ({0})', type(ex).__name__), 'nivel': 1}]}
        r.append(dict(e, id=a.get('id'), nome=a.get('nome') or a.get('perfil') or a.get('tipo', t('agente')), tipo=a.get('tipo') or 'generico'))
    return r
