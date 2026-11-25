#!/usr/bin/env python3
"""Modo demonstração: uma frota FICTÍCIA (Macs, servidores, e-mail, IA, agentes, Orca, sincronização) que muda a cada
passo, no mesmo formato do coleta.py. Serve pra gravar o README, tirar print e experimentar o app sem configurar nada.
Nenhum dado real: nomes, hosts e e-mails são inventados (example.com).

    python3 demo.py            uma linha JSON por passo (DEMO_PASSO s, padrão 4), pra sempre
    python3 demo.py --config   o config.json fictício que acompanha (pra print dos Ajustes)"""
import copy, json, os, sys, time

from comum import decimal, dur, t

GB = 1024**3


def passou(minutos):
    """Tempo decorrido como o coletor escreve (comum.dur, no idioma do app): passou(130) → '2h 10min'."""
    return dur(minutos * 60)


def nv(v, a, c):
    return 0 if v < a else 2 if v >= c else 1


def mac(nome, curto, modelo, cpu, gpu, ram, alerta=None, conectados=None, discos=None, sistema='macOS 26.3', local=False):
    return {'id': curto.lower().replace(' ', '-'), 'titulo': f'🟢 {nome}', 'linhas': [f'CPU {cpu}%'],
            'nivel': max(nv(cpu, 60, 85), nv(gpu, 60, 85), nv(ram, 80, 92)), 'nome': nome, 'curto': curto,
            'modelo': modelo, 'ts': curto.lower().replace(' ', '-'), 'local': local, 'card': [f'CPU {cpu}%'],
            'medidas': {'cpu': cpu, 'gpu': gpu, 'ram': ram, 'carga': max(cpu, gpu), 'disco': 100 - round(100 * (discos or [{'livre': 612, 'total': 994}])[0]['livre'] / (discos or [{'livre': 612, 'total': 994}])[0]['total']), 'temp': 41 + cpu // 4},
            'niveis': {'cpu': nv(cpu, 60, 85), 'gpu': nv(gpu, 60, 85), 'ram': nv(ram, 80, 92), 'disco': 0, 'temp': 0},
            'alerta': alerta,
            'detalhe': {'top': [['Final Cut Pro', 38.0], ['WindowServer', 12.0], ['Xcode', 9.0]], 'temp': 48.0, 'termico': 'normal',
                        'pressao': 'normal', 'swap': 0.0, 'carga': [2.1, 1.8, 1.6],
                        'discos': discos or [{'nome': t('Interno'), 'livre': 612, 'total': 994, 'usado': 38}],
                        'conectados': conectados, 'tailscale': '192.0.2.10', 'rede': 'Ethernet · 192.0.2.20', 'ligado': passou(6 * 1440 + 4 * 60),
                        'sistema': f'{modelo} · {sistema}'}}


ESTUDIO = {'monitores': [{'nome': 'Studio Display', 'res': '5120×2880', 'hz': 60, 'principal': True, 'interno': False},
                         {'nome': 'Pro Display XDR', 'res': '6016×3384', 'hz': 60, 'principal': False, 'interno': False}],
           'usb': [{'nome': 'Audio Interface', 'marca': 'Focusrite', 'vel': '480 Mb/s', 'hub': False}],
           'tb': [{'nome': 'Thunderbolt Dock', 'marca': 'CalDigit'}],
           'bluetooth': [{'nome': 'Magic Keyboard', 'bateria': 64, 'tipo': 'teclado'}, {'nome': 'Magic Trackpad', 'bateria': 41, 'tipo': 'trackpad'},
                         {'nome': 'AirPods Pro', 'bateria': 82, 'tipo': 'fones'}],
           'audio': {'nome': 'AirPods Pro', 'via': 'bluetooth'},
           'discos': [{'nome': 'Archive', 'livre': 1240, 'total': 4000}]}


def servidor(nome, host, so, cpu, ram, disco, servicos, containers, problemas=()):
    probs = [dict(p) for p in problemas]
    return {'id': nome, 'nome': nome, 'host': host, 'online': True, 'nivel': 0, 'medidas': {'cpu': cpu, 'ram': ram, 'disco': disco},
            'niveis': {'cpu': 0, 'ram': 0, 'disco': 0}, 'alerta': dict(probs[0], mais=len(probs) - 1) if probs else None,
            'detalhe': {'sistema': so, 'kernel': '6.8.0-49-generic', 'nome': nome, 'nucleos': 8, 'ligado': passou(41 * 1440 + 2 * 60), 'carga': [0.8, 0.7, 0.6],
                        'ram': t('{0} de {1} GB', f'{ram * 32 / 100:.1f}', 32), 'swap': 0.0,
                        'discos': [{'nome': '/', 'livre': round(320 * (100 - disco) / 100), 'total': 320, 'usado': disco}],
                        'top': [['postgres', 21.0], ['node', 9.0], ['nginx', 2.0]],
                        'servicos': [{'nome': s, 'estado': e} for s, e in servicos],
                        'containers': [{'nome': c, 'estado': e, 'status': st, 'imagem': im} for c, e, st, im in containers],
                        'docker': None, 'problemas': probs}}


def agente(id_, nome, tipo, estado, nivel, canais, ha, erro=None, problemas=()):
    return {'id': id_, 'nome': nome, 'tipo': tipo, 'estado': estado, 'nivel': nivel,
            'canais': [{'nome': n, 'estado': e, 'nivel': v} for n, e, v in canais], 'problemas': list(problemas),
            'erro': {'hora': '08:12', 'ha': passou(182), 'texto': erro} if erro else None,
            'atividade': {'hora': '11:40', 'ha': ha, 'canal': 'whatsapp', 'tipo': t('mensagem recebida')},
            'batida': {'hora': '11:43', 'ha': passou(0)}, 'versao': '0.21.5' if tipo == 'hermes' else None, 'agentes': 1 if tipo == 'hermes' else None,
            'servicos': [{'nome': 'gateway', 'rotulo': f'dev.exemplo.{id_}', 'pid': True, 'saida': 0}],
            'crons': {'ativos': 12, 'falhando': 0, 'agendador': True, 'proximo': {'hora': '12:00', 'ha': passou(16), 'nome': t('Resumo do dia')}} if tipo == 'hermes' else None,
            'kanban': {}, 'uazapi': None, 'perfis': [], 'avatar': None}


def base():
    # jan é o código que o app compara ('5h' | 'semana'); no card vai o texto ('semana' é chave do coleta.py)
    conta = lambda id_, nome, ferr, pct, nivel, jan, reset, app: {'id': id_, 'rotulo': nome, 'pct': pct, 'nivel': nivel, 'card': [f'{t(jan)} {pct}%'],
                                                                 'janela': jan, 'reset': reset, 'limite': False, 'ferramenta': ferr, 'app': app}
    app = lambda *c: next((x for x in c if os.path.exists(x)), None)
    em_dia = f"{t('Drive em dia')} · {t('último envio há {0}', passou(12))}"
    return {
        'barra': '🟢 Studio CPU 34%', 'pico': 'Studio CPU 34%', 'nivel': 0, 'atualizado': '', 'painel': None, 'semConfig': False,
        'maquinas': [
            mac('Studio', 'Studio', 'com.apple.macstudio', 34, 22, 61, conectados=ESTUDIO, local=True, sistema='macOS 26.3'),
            mac('MacBook Pro', 'MBP', 'com.apple.macbookpro', 12, 4, 47),
            mac(t('Render mini'), 'Render', 'com.apple.macmini', 81, 92, 58, alerta=None),
            mac(t('Design Air'), 'Air', 'com.apple.macbookair', 6, 2, 39,
                alerta={'texto': f"{t('Disco interno')} · {t('{0}% livre', 7)}", 'nivel': 1, 'tipo': 'disco'},
                discos=[{'nome': t('Interno'), 'livre': 34, 'total': 494, 'usado': 93}]),
            {'id': 'old-imac', 'titulo': f"⚪️ {t('Old iMac')} — {t('offline')}", 'linhas': [], 'nivel': -1, 'nome': t('Old iMac'), 'curto': 'iMac',
             'modelo': 'com.apple.imac', 'ts': 'old-imac', 'local': False, 'card': [t('offline')]}],
        'servidores': [
            servidor('web-01', 'web-01.example.com', 'Ubuntu 24.04 LTS', 18, 44, 52, [('nginx', 'active'), ('docker', 'active')],
                     [('app', 'running', 'Up 12 days (healthy)', 'ghcr.io/acme/app:2.4'), ('worker', 'running', 'Up 12 days', 'ghcr.io/acme/worker:2.4')]),
            servidor('db-01', 'db-01.example.com', 'Debian 12', 9, 71, 64, [('postgresql', 'active')], []),
            servidor('edge-sp', 'edge-sp.example.com', 'Ubuntu 22.04 LTS', 4, 22, 31, [('caddy', 'active')],
                     [('tunnel', 'running', 'Up 3 days', 'cloudflare/cloudflared:2026.10')])],
        'contas': [conta('claude', 'Pro', 'Claude', 42, 0, 'semana', t('dia|seg') + ' 09:00', app('/Applications/Claude.app')),
                   conta('chatgpt', 'Plus', 'ChatGPT', 18, 0, '5h', t('hoje') + ' 15:20', app('/Applications/ChatGPT.app', '/Applications/Codex.app')),
                   {'id': 'gemini', 'rotulo': 'Gemini', 'pct': 0, 'nivel': -1, 'card': [t('sem dado de uso')], 'ferramenta': 'Gemini', 'app': None, 'semFonte': True}],
        # estado do agente ('no ar') fica cru: o app compara e traduz
        'agentes': [agente('atlas', 'Atlas', 'hermes', 'no ar', 0, [('WhatsApp', t('conectado'), 0), ('Telegram', t('conectado'), 0)], passou(3)),
                    agente('nova', 'Nova', 'openclaw', 'no ar', 0, [('Telegram', t('conectado'), 0)], passou(18)),
                    agente('scout', 'Scout', 'generico', 'no ar', 0, [], passou(64))],
        'email': {'contas': [
            {'id': 'trabalho', 'nome': t('Trabalho'), 'endereco': 'you@example.com', 'provedor': 'composio', 'app': 'gmail', 'estado': 'ok', 'nivel': 0,
             'erro': None, 'naoLidos': 12, 'chegou': passou(9), 'verificado': passou(4),
             'ultimo': {'de': 'Lia Moreno', 'assunto': t('Contrato revisado (v3)'), 'ha': passou(9), 'hora': '22/11 11:34'}, 'cabecalhoHa': passou(1)},
            {'id': 'pessoal', 'nome': t('Pessoal'), 'endereco': 'me@example.org', 'provedor': 'imap', 'app': 'imap', 'estado': 'ok', 'nivel': 0,
             'erro': None, 'naoLidos': 3, 'chegou': None, 'verificado': passou(2),
             'ultimo': {'de': 'Airline', 'assunto': t('Seu cartão de embarque'), 'ha': passou(130), 'hora': '22/11 09:33'}, 'cabecalhoHa': passou(2)},
            {'id': 'projeto', 'nome': t('Projeto paralelo'), 'endereco': 'hello@example.net', 'provedor': 'composio', 'app': 'outlook', 'estado': 'expirada',
             'nivel': 1, 'erro': t('conexão expirada: reconecte no Composio'), 'naoLidos': None, 'chegou': None, 'verificado': None, 'ultimo': None,
             'cabecalhoHa': None}],
            'naoLidos': 15, 'nivel': 1, 'problema': f"{t('Projeto paralelo')}: {t('conexão expirada: reconecte no Composio')}",
            'chegou': {'conta': t('Trabalho'), 'ha': passou(9)}, 'intervalo': 60},
        'orca': {'aberto': True, 'nivel': 0, 'workspaces': 4, 'rodando': 3, 'workers': 2, 'esperando': 0, 'revisar': 2, 'automacoes': 6,
                 'erro': {'nome': t('Relatório semanal'), 'texto': t('precheck saiu com código 1'), 'ts': 0, 'ha': passou(2 * 1440 + 3 * 60)}},
        'sincronizacao': {'ativo': False, 'seta': None, 'nivel': 0, 'resumo': em_dia, 'problema': None,
                          'atividade': em_dia,
                          'drive': {'app': True, 'subindo': 0, 'baixando': 0, 'fila': 0, 'emDia': True, 'enviouHa': passou(12), 'ativo': False,
                                    'recebeu': 3, 'errosHora': 0, 'ultimoErro': None, 'estadoHa': passou(1)},
                          'rclone': [], 'backups': [{'nome': t('backup-fotos'), 'estado': 'ok', 'saida': None, 'horario': '03:00',
                                                     'ultimo': {'hora': '22/11 03:00', 'ha': passou(8 * 60 + 43)}, 'linha': t('ok: 1.204 arquivos')}]}}


def passos():
    e0 = base()
    e1 = copy.deepcopy(e0)  # o Studio aperta e começa uma cópia grande
    s = e1['maquinas'][0]
    s['medidas'].update(cpu=72, carga=72)
    s['niveis']['cpu'] = 1
    copia = f"rclone sync {t('Projetos')} → b2:backup"  # a pasta de origem: ~/Projetos
    e1['sincronizacao'].update(ativo=True, seta='sobe', atividade=f'{copia} · 12%', resumo=f'{copia} · 12%')
    e1['sincronizacao']['rclone'] = [{'pid': 4242, 'cmd': 'sync', 'origem': '~/' + t('Projetos'), 'destino': 'b2:backup', 'ha': passou(2), 'arquivos': ['render-final.mov'],
                                      'nAbertos': 1, 'progresso': {'feito': decimal('1.2') + ' GiB', 'total': decimal('9.8') + ' GiB', 'pct': 12, 'vel': '48 MiB/s', 'eta': '3m2s'}}]
    e2 = copy.deepcopy(e1)  # chega e-mail; a cópia anda
    e2['email']['contas'][0].update(naoLidos=13, chegou=passou(0), ultimo={'de': 'Bruno Costa', 'assunto': t('Re: lançamento na quinta'),
                                                                            'ha': passou(0), 'hora': '22/11 11:43'})
    e2['email'].update(naoLidos=16, chegou={'conta': t('Trabalho'), 'ha': passou(0)})
    e2['sincronizacao']['rclone'][0]['progresso'].update(pct=48, feito=decimal('4.7') + ' GiB', eta='1m40s')
    e2['sincronizacao'].update(atividade=f'{copia} · 48%')
    e3 = copy.deepcopy(e2)  # um agente perde o WhatsApp e um agente do Orca espera você
    a = e3['agentes'][1]
    a.update(estado='pede atenção', nivel=2, erro={'hora': '11:44', 'ha': passou(0), 'texto': t('WhatsApp desconectou (sessão encerrada)')})
    a['canais'] = [{'nome': 'WhatsApp', 'estado': t('desconectado'), 'nivel': 2}, {'nome': 'Telegram', 'estado': t('conectado'), 'nivel': 0}]
    e3['orca'].update(esperando=1, nivel=1)
    e3['sincronizacao']['rclone'][0]['progresso'].update(pct=86, feito=decimal('8.4') + ' GiB', eta='31s')
    e3['sincronizacao'].update(atividade=f'{copia} · 86%')
    return [e0, e1, e2, e3]


def config():
    m = lambda id_, nome, curto, host, icone: {'id': id_, 'nome': nome, 'curto': curto, 'host': host, 'usuario': '', 'icone': icone, 'modelo': '', 'visivel': True}
    s = lambda id_, host, sv, dk: {'id': id_, 'nome': id_, 'host': host, 'usuario': 'deploy', 'porta': 22, 'servicos': sv, 'docker': dk, 'visivel': True}
    return {'versao': 1, 'intervalo': 20, 'lento': 60, 'usuarioSSH': '', 'painel': '',
            'maquinas': [m('studio', 'Studio', 'Studio', 'local', ''), m('mbp', 'MacBook Pro', 'MBP', 'mbp', ''),
                         m('render', t('Render mini'), 'Render', 'render-mini', ''), m('air', t('Design Air'), 'Air', 'design-air', ''),
                         m('old-imac', t('Old iMac'), 'iMac', 'old-imac', 'com.apple.imac')],
            'servidores': [s('web-01', 'web-01.example.com', ['nginx', 'docker'], True), s('db-01', 'db-01.example.com', ['postgresql'], False),
                           s('edge-sp', 'edge-sp.example.com', ['caddy'], True)],
            'email': {'intervalo': 60, 'contas': [
                {'id': 'trabalho', 'nome': t('Trabalho'), 'provedor': 'composio', 'conta': 'ca_demo1', 'endereco': 'you@example.com', 'visivel': True},
                {'id': 'pessoal', 'nome': t('Pessoal'), 'provedor': 'imap', 'servidor': 'imap.example.org', 'porta': 993, 'usuario': 'me@example.org', 'visivel': True},
                {'id': 'projeto', 'nome': t('Projeto paralelo'), 'provedor': 'composio', 'conta': 'ca_demo2', 'endereco': 'hello@example.net', 'visivel': True}]},
            'ia': [{'id': 'claude', 'nome': 'Pro', 'ferramenta': 'Claude', 'fonte': 'claude-perfil', 'perfil': '', 'app': ['/Applications/Claude.app'],
                    'perguntar': 'claude-cli', 'modelo': '', 'visivel': True},
                   {'id': 'chatgpt', 'nome': 'Plus', 'ferramenta': 'ChatGPT', 'fonte': 'codex-sessoes', 'perfil': '',
                    'app': ['/Applications/ChatGPT.app', '/Applications/Codex.app'], 'perguntar': 'codex-cli', 'modelo': '', 'visivel': True},
                   {'id': 'gemini', 'nome': 'Gemini', 'ferramenta': 'Gemini', 'fonte': '', 'perfil': '', 'app': [], 'perguntar': '', 'modelo': '', 'visivel': True}],
            'agentes': [{'id': 'atlas', 'nome': 'Atlas', 'tipo': 'hermes', 'home': '~/.hermes', 'perfil': '', 'foto': '', 'visivel': True},
                        {'id': 'nova', 'nome': 'Nova', 'tipo': 'openclaw', 'porta': 18789, 'rotulo': 'ai.openclaw.gateway', 'foto': '', 'visivel': True},
                        {'id': 'scout', 'nome': 'Scout', 'tipo': 'generico', 'url': 'http://127.0.0.1:8088/health', 'foto': '', 'visivel': True}],
            'sincronizacao': {'agentes': 'backup'}, 'demo': True}


def main():
    import signal
    for s in (signal.SIGUSR1, signal.SIGUSR2):  # os pedidos do app (cabeçalho de e-mail, gaveta abriu) não têm o que fazer aqui
        signal.signal(s, signal.SIG_IGN)
    if '--config' in sys.argv:
        print(json.dumps(config(), ensure_ascii=False, indent=2))
        return
    seq, i, passo = passos(), 0, float(os.environ.get('DEMO_PASSO', '4'))
    while True:
        e = seq[i % len(seq)]
        e['atualizado'] = time.strftime('%H:%M:%S')
        try:
            print(json.dumps(e, ensure_ascii=False), flush=True)
        except BrokenPipeError:
            return
        if '--uma' in sys.argv or os.getppid() == 1:
            return
        i += 1
        time.sleep(passo)


if __name__ == '__main__':
    main()
