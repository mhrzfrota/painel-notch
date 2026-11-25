"""Checagem mínima da lógica de cor/alerta/texto do coleta.py: python3 teste_coleta.py"""
from coleta import nivel, linhas

GB = 1024**3
base = {'cpu': 10, 'gpu': 5, 'ram': {'usado': 8 * GB, 'total': 64 * GB}, 'swap': {'usado': 0, 'total': GB},
        'pressao': 'normal', 'temp': 40.0, 'termico': 'normal', 'carga': [1.0, 1.0, 1.0], 'uptime': 90000,
        'modelo': 'Mac17,14', 'macos': '27.0', 'top': [['WindowServer', 20.0]],
        'discos': [{'nome': 'Interno', 'livre': 400 * GB, 'total': 1000 * GB}], 'rede': None}

assert nivel(base) == (0, [])
assert nivel(dict(base, cpu=70))[0] == 1
assert nivel(dict(base, gpu=90))[0] == 2
assert nivel(dict(base, ram={'usado': 60 * GB, 'total': 64 * GB}))[0] == 2
assert nivel(dict(base, pressao='atenção')) == (1, ['memória sob pressão (atenção)'])
assert nivel(dict(base, gpu=None, temp=None))[0] == 0  # sem GPU/temp não quebra
cheio = dict(base, discos=[{'nome': 'Arquivo-SSD', 'livre': 16 * GB, 'total': 466 * GB}])
assert nivel(cheio) == (0, ['disco Arquivo-SSD com 3% livre'])  # disco cheio = alerta, não muda a cor
assert any(l.startswith('⚠️ Disco Arquivo-SSD') for l in linhas(cheio, '192.0.2.3', None))
assert 'Ligado há 1d 1h · Mac17,14 · macOS 27.0' in linhas(base, '-', None)
print('ok')
from coleta import card
assert card(cheio, {'monitores': [{'nome': 'LS27', 'res': None}], 'usb': [{'nome': 'Extreme SSD', 'hub': False}], 'tb': []}) == \
    ['CPU 10% · GPU 5%', 'RAM 12% · 40°C', '⚠️ Arquivo-SSD 3% livre', '1 monitor · 1 USB']
print('ok card')
import coleta, pergunta
pergunta.logado = lambda prov, perfil=None: True  # o teste de login de verdade chama o CLI; aqui todo mundo está logado
pergunta.anotado = lambda prov, perfil=None: 0      # e nenhuma pergunta viu token vencido
agora = 1_000_000
# anel do Claude sem Orca: o statusline.py grava, o coletor lê do ~/.claude (conta com perfil vazio)
import os, statusline, tempfile, time
statusline.ARQ = coleta.CLAUDE_RL = os.path.join(tempfile.mkdtemp(), 'deck-rate-limits.json')
sl = {'rate_limits': {'five_hour': {'used_percentage': 23.4, 'resets_at': 2_000_000_000}}, 'model': {'id': 'x', 'display_name': 'Opus'}}
assert coleta.janela_claude('') == (None, {})
statusline.gravar(sl, time.time())
assert coleta.janela_claude('')[1] == {'five_hour': (23.4, 2_000_000_000)}
statusline.gravar({'rate_limits': {'five_hour': {'used_percentage': 99, 'resets_at': 1}}}, time.time())  # < 15 s: não regrava
assert coleta.janela_claude(None)[1] == {'five_hour': (23.4, 2_000_000_000)}
assert statusline.linha(sl) == 'Opus · 5h 23%' and statusline.linha({}) == 'Claude'
c = coleta.conta({'nome': 'X', 'fonte': 'claude-perfil', 'perfil': ''}, agora)  # janela de 2033 lida do arquivo
assert c['pct'] == 23 and c['janela'] == '5h', c
os.remove(coleta.CLAUDE_RL)
assert coleta.conta({'nome': 'X', 'fonte': 'claude-perfil', 'perfil': ''}, agora)['card'] == ['sem dado recente', 'falta o statusline (ver README)']
print('ok statusline')
coleta.janela_claude = lambda perfil:(agora - 600, {'five_hour': (40, agora - 1), 'seven_day': (99, agora + 3600)})
c = coleta.conta({'nome': 'X', 'ferramenta': 'Claude', 'uso': {'fonte': 'claude-perfil', 'perfil': 'p'}, 'app': ['/nao/existe.app']}, agora)
assert (c['pct'], c['nivel']) == (99, 2) and c['card'][0] == 'semana 99%' and c['card'][2] == 'visto há 10min', c  # 5h já resetou: some
print('ok conta')
from coleta import alerta
assert alerta(base) is None
assert alerta(cheio) == {'texto': 'Arquivo-SSD · 3% livre', 'nivel': 2, 'tipo': 'disco'}
assert alerta(dict(base, pressao='atenção'))['tipo'] == 'memoria'
assert alerta(dict(base, temp=90.0)) == {'texto': 'limitando por calor · 90°C', 'nivel': 1, 'tipo': 'calor'}
print('ok alerta')
from coleta import nivel_de, detalhe
assert (nivel_de('cpu', 59), nivel_de('cpu', 60), nivel_de('cpu', 85), nivel_de('ram', 91), nivel_de('gpu', None)) == (0, 1, 2, 1, 0)
dt = detalhe(dict(base, discos=cheio['discos']), '192.0.2.3', None)
assert dt['discos'][0] == {'nome': 'Arquivo-SSD', 'livre': 16, 'total': 466, 'usado': 97} and dt['ligado'] == '1d 1h'
print('ok niveis/detalhe')
sem = coleta.conta({'nome': 'Gemini', 'ferramenta': 'Gemini', 'uso': None})
assert (sem['nivel'], sem['card'], sem.get('semFonte'), sem['app'], sem['rotulo']) == (-1, ['sem dado de uso'], True, None, 'Gemini')
assert c['app'] is None and c['ferramenta'] == 'Claude'
print('ok contas')
# conectados (rodada 4): card e linhas com a estrutura nova da sonda
plug = {'monitores': [{'nome': 'LS27D300G', 'res': '1920×1080', 'hz': 100, 'principal': True, 'interno': False}],
        'usb': [{'nome': 'Extreme SSD', 'marca': 'SanDisk', 'vel': '5 Gb/s', 'hub': False}, {'nome': 'USB3.2 Hub', 'marca': 'G', 'vel': None, 'hub': True}],
        'tb': [], 'bluetooth': [{'nome': 'Magic Trackpad', 'bateria': 97, 'tipo': 'trackpad'}], 'audio': {'nome': 'Mac Studio Speakers', 'via': 'builtin'}}
assert card(base, plug)[-1] == '1 monitor · 1 USB'
L = linhas(base, '-', plug)
assert 'Bluetooth: Magic Trackpad 97%' in L and 'Som: Mac Studio Speakers' in L and 'USB: Extreme SSD' in L
assert detalhe(cheio, '-', plug)['conectados']['discos'] == [{'nome': 'Arquivo-SSD', 'livre': 16, 'total': 466}]
from sonda import curto
assert (curto('Alex’s Magic Keyboard #2'), curto('AirPods de Sam'), curto('AirPods Pro')) == ('Magic Keyboard', 'AirPods', 'AirPods Pro')
print('ok conectados')
# Hermes (agentes.py): só leitura de um ~/.hermes falso
import tempfile, os as _os, comum, agentes
h = tempfile.mkdtemp()
for d in ('state/cron-watchdog', 'cron', 'logs', 'kanban/boards/q', 'profiles/dev/logs', 'profiles/dev/cron'):
    _os.makedirs(f'{h}/{d}')
agora = 1_800_000_000
iso = lambda t: __import__('datetime').datetime.fromtimestamp(t, __import__('datetime').timezone.utc).isoformat()
json_ = __import__('json')
json_.dump({'gateway_state': 'running', 'active_agents': 2, 'served_profiles': ['default', 'dev'],
            'platforms': {'whatsapp': {'state': 'connected'}, 'dev:whatsapp': {'state': 'fatal', 'needs_attention': True}}}, open(f'{h}/gateway_state.json', 'w'))
json_.dump({'updated_at': iso(agora - 30)}, open(f'{h}/state/gateway.heartbeat', 'w'))
json_.dump({'jobs': [{'id': 'a', 'name': 'A', 'enabled': True, 'state': 'scheduled', 'last_status': 'ok', 'next_run_at': iso(agora + 600)},
                     {'id': 'j1', 'name': 'B', 'enabled': True, 'state': 'scheduled', 'last_status': 'error', 'next_run_at': iso(agora + 60)},
                     {'id': 'c', 'name': 'C', 'enabled': False, 'state': 'paused'}]}, open(f'{h}/cron/jobs.json', 'w'))
json_.dump({'jobs': [{'id': 'd1', 'name': 'D', 'enabled': True, 'state': 'scheduled', 'last_status': 'ok'}]}, open(f'{h}/profiles/dev/cron/jobs.json', 'w'))
open(f'{h}/profiles/dev/config.yaml', 'w').write('x: 1\n')
open(f'{h}/cron/ticker_heartbeat', 'w').write(f'{agora - 20} 1')
json_.dump({'issues': [{'key': 'execution:j1', 'title': 'Execução não concluiu: B', 'severity': 'critical'},
                       {'key': 'job_status:j1', 'title': 'B falhou', 'severity': 'critical'},
                       {'key': 'job_status:d1', 'title': 'D falhou', 'severity': 'warning'}]}, open(f'{h}/state/cron-watchdog/status.json', 'w'))
open(f'{h}/logs/gateway.log', 'w').write('2026-11-21 23:08:43,1 INFO gateway.run: inbound message: platform=whatsapp user=X msg=\'segredo\'\n')
open(f'{h}/logs/gateway.error.log', 'w').write('2026-11-21 21:38:47,3 ERROR gateway.run: Fatal adapter error chat 120363000000000000@g.us\n')
open(f'{h}/profiles/dev/logs/errors.log', 'w').write('2026-11-21 22:00:00,1 ERROR [x] agent.tool: deu ruim em /Users/fulano/arq\n')
open(f'{h}/profiles/dev/logs/agent.log', 'w').write('trabalhando\n')
comum.run = lambda cmd, stdin=None, timeout=15: (0, '51007\t75\tai.hermes.gateway\n-\t0\tai.hermes.watchdog\n', '')
comum.LCTL['quando'] = 0
agentes.uazapi = lambda a, agora: [{'nome': 'Principal', 'status': 'connected'}]
r = agentes.hermes({'home': h}, agora)
assert (r['estado'], r['nivel'], r['agentes']) == ('no ar', 1, 2), r
assert r['canais'] == [{'nome': 'WhatsApp', 'estado': 'conectado', 'nivel': 0}], r['canais']
assert r['crons']['ativos'] == 2 and r['crons']['falhando'] == 1 and r['crons']['proximo']['nome'] == 'B' and r['crons']['agendador']
assert [p['titulo'] for p in r['problemas']] == ['Execução não concluiu: B'], r['problemas']  # o D é do perfil dev, não do principal
assert r['perfis'] == [{'nome': 'dev · whatsapp', 'estado': 'fatal'}]
assert r['erro']['texto'] == 'Fatal adapter error chat …' and r['atividade']['tipo'] == 'mensagem recebida'
assert 'segredo' not in json_.dumps(r), 'texto de mensagem nunca sai do log'
r2 = agentes.hermes({'home': h}, agora)  # 2º ciclo sem linha nova no log: o último evento continua lá (leitura incremental)
assert r2['atividade'] == r['atividade'] and r2['erro'] == r['erro']
with open(f'{h}/logs/gateway.log', 'a') as f:  # linha nova (e uma pela metade, que fica pro próximo ciclo)
    f.write('2026-11-21 23:30:00,1 INFO gateway.run: response ready: platform=whatsapp chat=x\n2026-11-21 23:31:00,1 INFO gat')
assert agentes.hermes({'home': h}, agora)['atividade']['tipo'] == 'resposta enviada'
dev = agentes.hermes({'home': h, 'perfil': 'dev'}, agora)  # perfil servido pelo gateway: canais e problemas DELE
assert (dev['estado'], dev['nivel']) == ('no ar', 2) and dev['canais'][0]['estado'] == 'fora (fatal)', dev
assert [p['titulo'] for p in dev['problemas']] == ['D falhou'] and dev['atividade']['tipo'] == 'trabalho'
assert dev['erro']['texto'] == 'deu ruim em …', dev['erro']
json_.dump({'updated_at': iso(agora - 900)}, open(f'{h}/state/gateway.heartbeat', 'w'))
assert agentes.hermes({'home': h}, agora)['estado'] == 'travado'  # processo vivo, batida velha
comum.run = lambda cmd, stdin=None, timeout=15: (0, '-\t1\tai.hermes.gateway\n', '')
comum.LCTL['quando'] = 0  # launchctl list é lido 1× por ciclo: o teste troca a saída, então força reler
assert agentes.hermes({'home': h}, agora)['nivel'] == 2  # gateway parado
assert agentes.hermes({'home': h + '/nao'}, agora) == {'estado': 'sem acesso', 'nivel': -1}
lista = agentes.estado([{'id': 'x', 'nome': 'Quebrado', 'tipo': 'hermes', 'home': 7}], agora)  # um agente que quebra não derruba o resto
assert lista[0]['nome'] == 'Quebrado' and lista[0]['nivel'] == -1
print('ok hermes')

# sincronização: log do Drive, rclone e backups, tudo falso
import plistlib, time as _t
agora = _t.time()
z = lambda t: _t.strftime('%Y-%m-%dT%H:%M:%S', _t.gmtime(t)) + '.123ZI [1:core_1] '
log = f'{h}/drive_fs.txt'
open(log, 'w').write(z(agora - 60) + 'sync_engine.cc:2713:operator() Sync engine activity state:\nactive_downloads: 0\nactive_uploads: 3\n'
                     'operation_queue_size: 12\nchange_ids_up_to_date: false\n\n'
                     + z(agora - 30) + 'merger.cc:2294:operator() Content upload of x succeeded\n'
                     + z(agora - 100) + "HandleFailedChange [UploadModifyMergeQueueItem 1] Status='CANCELLED'\n"
                     + z(agora - 120) + 'cloud_subsystem.cc:192:OnChangeNotificationReceived Generated 4 download events\n')
coleta.DRIVE_LOG = log
ps = '  777 01:02:03 /opt/homebrew/bin/rclone sync /Users/x/Docs gdrive:Backup --log-level NOTICE\n  778 00:10 rclone lsjson gdrive:\n'
def falso(cmd, stdin=None, timeout=15):
    return {'pgrep': (0, '777 rclone\n123 Google Drive\n', ''), 'ps': (0, ps, ''), 'lsof': (0, '', ''),
            'launchctl': (0, 'PID\tStatus\tLabel\n-\t0\tcom.exemplo.backup-ok\n-\t0\tcom.exemplo.backup-velho\n-\t1\tcom.exemplo.backup-erro\n'
                                 '4242\t0\tcom.exemplo.backup-agora\n', '')}[cmd[0]]
coleta.run = comum.run = falso
comum.LCTL['quando'] = 0
dv = coleta.drive(agora, True)
assert (dv['subindo'], dv['fila'], dv['ativo'], dv['emDia'], dv['errosHora'], dv['recebeu']) == (3, 12, True, False, 1, 4), dv
assert dv['ultimoErro'] == {'quando': '1min', 'tipo': 'upload', 'motivo': 'CANCELLED'}
rc = coleta.rclone(agora, ['777'])
assert coleta.rclone(agora, []) == []  # nenhum rclone vivo: nem chama o ps
ps = '  779 00:42 rclone copyto /Users/x/IMG_1.MOV gdrive:Fotos/IMG_1.MOV\n'
um = coleta.rclone(agora, ['779'])[0]
assert (um['cmd'], um['arquivos'], um['ha'], um['destino']) == ('copyto', ['IMG_1.MOV'], '42s', 'gdrive:Fotos/IMG_1.MOV'), um
ps = '  777 01:02:03 /opt/homebrew/bin/rclone sync /Users/x/Docs gdrive:Backup --log-level NOTICE\n'
assert len(rc) == 1 and (rc[0]['cmd'], rc[0]['origem'], rc[0]['destino'], rc[0]['ha']) == ('sync', '/Users/x/Docs', 'gdrive:Backup', '1h 2min'), rc
ag = f'{h}/agentes'
_os.makedirs(ag)
ontem = agora - 86400 * 2
for nome, log_em in (('ok', agora - 30), ('velho', ontem), ('erro', agora - 30), ('agora', ontem)):
    lf = f'{h}/backup-{nome}.log'
    open(lf, 'w').write(f'linha de {nome} /Users/x/segredo\n')
    _os.utime(lf, (log_em, log_em))
    hora = _t.localtime(agora - 120)  # o horário agendado já passou há 2 min
    plistlib.dump({'Label': f'com.exemplo.backup-{nome}', 'StandardOutPath': lf,
                   'StartCalendarInterval': {'Hour': hora.tm_hour, 'Minute': hora.tm_min}}, open(f'{ag}/com.exemplo.backup-{nome}.plist', 'wb'))
plistlib.dump({'Label': 'com.exemplo.outra-coisa'}, open(f'{ag}/com.exemplo.outra-coisa.plist', 'wb'))
coleta.AGENTES = ag
bk = {b['nome']: b for b in coleta.backups(agora)}
assert set(bk) == {'backup-ok', 'backup-velho', 'backup-erro', 'backup-agora'}, bk
assert (bk['backup-ok']['estado'], bk['backup-velho']['estado'], bk['backup-erro']['estado'], bk['backup-agora']['estado']) == ('ok', 'atrasado', 'erro', 'rodando')
assert bk['backup-erro']['saida'] == 1 and '/Users/x' not in bk['backup-ok']['linha']
s = coleta.sincronizacao(agora)
assert (s['ativo'], s['seta'], s['nivel']) == (True, 'sobe', 1), s
assert s['resumo'].startswith('rclone sync Docs → gdrive:Backup · há 1h 2min') and 'backup-erro saiu com erro 1' in s['resumo'] \
    and 'backup-velho não rodou às' in s['resumo'] and 'Drive subindo 3 · 12 na fila' in s['resumo'], s['resumo']
assert s['problema'].startswith('backup-erro saiu com erro 1') and 'rclone' not in s['problema'], s['problema']
assert s['atividade'].startswith('rclone sync Docs') and 'backup-erro' not in s['atividade'], s['atividade']
semana = coleta._agendado({'Weekday': 0, 'Hour': 4, 'Minute': 0}, agora)
assert _t.localtime(semana).tm_wday == 6 and agora - semana < 7 * 86400  # Weekday 0 = domingo
print('ok sincronização')

# config: padrões, módulos e o que está escondido some
import comum as _c
cfg = tempfile.mktemp(suffix='.json')
json_.dump({'maquinas': [{'nome': 'A', 'host': 'a'}, {'nome': 'B', 'host': 'b', 'visivel': False}], 'modulos': {'email': False},
            'aparencia': {'limites': {'cpu': [50, 70]}}}, open(cfg, 'w'))
c = _c.carregar(cfg)
assert [m['nome'] for m in c['maquinas']] == ['A'] and c['modulos']['email'] is False and c['modulos']['macs'] is True
assert c['aparencia']['limites']['cpu'] == [50, 70] and c['aparencia']['limites']['disco'] == [10, 5] and c['intervalo'] == 20
assert _c.carregar('/nao/existe.json')['maquinas'] == []  # sem config: vazio (o app abre o assistente)
print('ok config')

# onde está cada máquina: Tailscale (nome ou IP), este Mac, ou direto pelo SSH
rede = {'studio': {'ip': '192.0.2.1', 'online': True, 'self': True}, 'mini': {'ip': '192.0.2.2', 'online': False, 'self': False}}
assert coleta.resolver('studio', rede)['self'] and coleta.resolver('mini.tail1234.ts.net', rede)['online'] is False
assert coleta.resolver('192.0.2.2', rede)['ip'] == '192.0.2.2' and coleta.resolver('local', rede)['self']
assert coleta.resolver('vps.example.com', rede) == {'ip': 'vps.example.com', 'online': None, 'self': False}
assert coleta.destino({'ip': 'vps', 'usuario': 'root'}) == 'root@vps' and coleta.destino({'ip': 'vps', 'usuario': ''}) in ('vps', f"{coleta.CFG.get('usuarioSSH')}@vps")
print('ok resolver')
# apelido do ~/.ssh/config com o mesmo nome da Tailscale: online da Tailscale, SSH pelo apelido (chave/usuário/known_hosts)
cfg_ssh = os.path.join(tempfile.mkdtemp(), 'config')
open(cfg_ssh, 'w').write('Host studio mini\n    HostName mini.tail1234.ts.net\n    User eu\nHost *.ts.net\n    IdentitiesOnly yes\n')
SSH_CONFIG_ORIG, coleta.SSH_CONFIG = coleta.SSH_CONFIG, cfg_ssh
assert coleta.apelidos_ssh() == {'studio', 'mini'}  # curinga e HostName ficam de fora
r = coleta.resolver('mini', rede)
assert r['ip'] == '192.0.2.2' and r['online'] is False and r['ssh'] == 'mini' and coleta.destino(dict(r, usuario='')) in ('mini', f"{coleta.CFG.get('usuarioSSH')}@mini")
assert 'ssh' not in coleta.resolver('192.0.2.2', rede)  # IP digitado continua indo pelo IP
open(cfg_ssh, 'w').write('Host outro\n'); os.utime(cfg_ssh, (1, 1))  # mudou o arquivo: relê
assert coleta.apelidos_ssh() == {'outro'} and 'ssh' not in coleta.resolver('mini', rede)
coleta.SSH_CONFIG = '/nao/existe'
assert coleta.apelidos_ssh() == frozenset() and coleta.resolver('mini', rede) == rede['mini']
coleta.SSH_CONFIG = SSH_CONFIG_ORIG
print('ok apelido ssh')

# servidor Linux: disco, serviço parado e container doente viram alerta; container parado de propósito não
L = {'so': 'Ubuntu 24.04', 'kernel': '6.8', 'host': 'web', 'nucleos': 4, 'uptime': 90000, 'carga': [0.5, 0.4, 0.3], 'cpu': 12,
     'ram': {'total': 8 * GB, 'usado': 2 * GB}, 'swap': {'total': 0, 'usado': 0},
     'discos': [{'nome': '/', 'total': 100 * GB, 'livre': 4 * GB}], 'top': [['node', 9.0]],
     'servicos': [{'nome': 'nginx', 'estado': 'active'}, {'nome': 'redis', 'estado': 'failed'}],
     'docker': {'containers': [{'nome': 'app', 'estado': 'running', 'status': 'Up 2 days (unhealthy)', 'imagem': 'x'},
                               {'nome': 'job', 'estado': 'exited', 'status': 'Exited (0) 3 days ago', 'imagem': 'y'}]}}
sv = coleta.servidor({'nome': 'web', 'host': 'web.example.com'}, L, None)
assert sv['online'] and sv['medidas'] == {'cpu': 12, 'ram': 25, 'disco': 96}, sv['medidas']
assert [p['texto'] for p in sv['detalhe']['problemas']] == ['disco / com 4% livre', 'redis falhou', 'container app doente'], sv['detalhe']['problemas']
assert sv['alerta']['mais'] == 2 and sv['detalhe']['ligado'] == '1d 1h'
off = coleta.servidor({'nome': 'db', 'host': 'db'}, None, 'sem chave SSH')
assert (off['online'], off['nivel'], off['erro']) == (False, -1, 'sem chave SSH')
assert coleta.SERVICO_OK.match('nginx') and not coleta.SERVICO_OK.match('x; rm -rf ~')  # serviço vira argumento no SSH
print('ok servidor')

# agentes OpenClaw e genérico: health HTTP de verdade (servidor local de mentira)
import http.server, threading as _th
class H(http.server.BaseHTTPRequestHandler):
    resp = (200, b'{"ok":true}')
    def do_GET(self):
        self.send_response(H.resp[0]); self.end_headers(); self.wfile.write(H.resp[1])
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
_th.Thread(target=srv.serve_forever, daemon=True).start()
porta = srv.server_address[1]
comum.run = lambda cmd, stdin=None, timeout=15: (0, '', '')
comum.LCTL['quando'] = 0
assert agentes.openclaw({'porta': porta}, agora)['estado'] == 'no ar'
H.resp = (503, b'{"status":"ready","failing":["channel:whatsapp:default","agent-database:main"]}')
oc = agentes.openclaw({'porta': porta}, agora)
assert (oc['estado'], oc['nivel']) == ('pede atenção', 2) and oc['canais'][0]['nome'] == 'WhatsApp' and oc['problemas'][0]['titulo'] == 'agent-database:main', oc
H.resp = (200, b'ok')
assert agentes.generico({'url': f'http://127.0.0.1:{porta}/health'}, agora)['estado'] == 'no ar'
srv.shutdown()
assert agentes.generico({'url': f'http://127.0.0.1:{porta}/health'}, agora)['estado'] == 'parado'
assert agentes.generico({}, agora)['estado'] == 'sem acesso'
print('ok openclaw/genérico')

# e-mail (Composio de mentira): conta 1× por intervalo, cabeçalho só quando pedido, "chegou" quando o total sobe,
# conta expirada não gasta chamada e nada de corpo
import caixas
caixas.ARQ = tempfile.mktemp(suffix='.json')
chamadas = []
caixa = {'tot': 10, 'nao': 3}
def req(metodo, caminho, cab, corpo=None, timeout=20):
    chamadas.append(caminho.split('?')[0])
    if 'connected_accounts' in caminho:
        return {'items': [{'id': 'ca1', 'toolkit': {'slug': 'gmail'}, 'alias': 'a@x', 'status': 'ACTIVE', 'user_id': 'u'},
                          {'id': 'ca2', 'toolkit': {'slug': 'outlook'}, 'alias': 'b@x', 'status': 'EXPIRED', 'user_id': 'u'}]}
    if caminho.endswith('GMAIL_GET_LABEL'):
        assert corpo['user_id'] == 'u' and corpo['arguments'] == {'id': 'INBOX'}
        return {'successful': True, 'data': {'messagesUnread': caixa['nao'], 'messagesTotal': caixa['tot']}}
    if caminho.endswith('/proxy'):
        assert 'fields=' in corpo['endpoint'], 'cabeçalho só com a lista de campos fechada (nunca o corpo)'
        if 'fields=messages/id' in corpo['endpoint']:
            return {'status': 200, 'data': {'messages': [{'id': 'm1'}]}}
        return {'status': 200, 'data': {'internalDate': str(int(agora * 1000)), 'payload': {'headers': [
            {'name': 'From', 'value': 'Lia <lia@x.com>'}, {'name': 'Subject', 'value': 'Oi'}]}}}
    raise AssertionError(caminho)
caixas._req = req
caixas.cabecalhos = lambda chave: {'x-api-key': chave}
caixas.segredo = lambda conta: 'ak_teste'
cfg_e = {'intervalo': 60, 'contas': [{'id': 'g', 'nome': 'G', 'provedor': 'composio', 'conta': 'ca1'},
                                     {'id': 'o', 'nome': 'O', 'provedor': 'composio', 'conta': 'ca2'}]}
r = caixas.estado(cfg_e, agora)
assert chamadas.count('/api/v3.1/tools/execute/GMAIL_GET_LABEL') == 1 and '/api/v3.1/tools/execute/OUTLOOK_GET_MAIL_FOLDER' not in chamadas
g, o = r['contas']
assert (g['naoLidos'], g['estado'], g['ultimo'], o['estado'], o['nivel']) == (3, 'ok', None, 'expirada', 1), r
n = len(chamadas)
caixas.estado(cfg_e, agora + 60)  # dentro do intervalo e sem pedido: nenhuma chamada
assert len(chamadas) == n, chamadas[n:]
caixa.update(tot=11, nao=4)
r = caixas.estado(cfg_e, agora + 3700, pedido=True)  # venceu o intervalo e a página de e-mail pediu
g = r['contas'][0]
assert g['naoLidos'] == 4 and g['chegou'] == '0min' and g['ultimo']['de'] == 'Lia' and g['ultimo']['assunto'] == 'Oi', g
assert r['chegou'] == {'conta': 'G', 'ha': '0min'} and r['naoLidos'] == 4 and r['problema'].startswith('O: conexão expirada')
n = len(chamadas)
caixas.estado(cfg_e, agora + 3760, pedido=True)  # pedido de novo em seguida: o cabeçalho é do mesmo total, não refaz
assert len(chamadas) == n
assert json_.load(open(caixas.ARQ))['contas']['g']['naoLidos'] == 4  # reiniciar o coletor não gasta chamada à toa
print('ok e-mail')

# Orca: só contagens, nunca o conteúdo do agente
r_ps = {'worktrees': [{'sidebarStatus': 'working', 'agents': [{'state': 'working', 'prompt': 'SEGREDO'}, {'state': 'working', 'parentPaneKey': 'p'}]},
                      {'sidebarStatus': 'done', 'agents': [{'state': 'done', 'activity': {'unread': True}}, {'state': 'waiting', 'agentWait': {'x': 1}}]},
                      {'sidebarStatus': 'inactive', 'isArchived': True, 'agents': [{'state': 'working'}]}]}
r_aut = {'automations': [{'id': 'a1', 'name': 'Relatório', 'enabled': True}, {'id': 'a2', 'name': 'Velha', 'enabled': False}]}
r_runs = {'runs': [{'automationId': 'a1', 'status': 'failed', 'error': 'quebrou em /Users/x/y', 'startedAt': str(int((agora - 120) * 1000))},
                   {'automationId': 'a1', 'status': 'skipped_precheck', 'error': 'Precheck exited with code 1.', 'startedAt': str(int(agora * 1000))}]}
coleta.ORCA_BIN = __file__
coleta._orca = lambda *a: {'worktree': r_ps, 'automations': r_aut if a[1] == 'list' else r_runs}[a[0]]
o = coleta.orca(agora)
assert (o['workspaces'], o['rodando'], o['workers'], o['esperando'], o['revisar'], o['automacoes'], o['nivel']) == (1, 2, 1, 1, 1, 1, 1), o
assert o['erro']['nome'] == 'Relatório' and o['erro']['ha'] == '2min' and '/Users/x' not in o['erro']['texto'] and 'SEGREDO' not in json_.dumps(o)
print('ok orca')

# pergunta rápida: o Claude roda sem ferramenta, sem MCP, sem config do usuário, numa pasta vazia; a pergunta vai pelo stdin
import pergunta
visto = {}
def falso_run(cmd, env, pasta, entrada, **kw):
    visto.update(cmd=cmd, pasta=pasta, entrada=entrada, vazia=_os.listdir(pasta) == [], env=env)
    return 0, json_.dumps({'result': '42', 'modelUsage': {'claude-haiku': {}}}), ''
pergunta.run_env = falso_run
pergunta._cli = lambda nome: '/bin/' + nome
r = pergunta.claude('quanto é 6x7?', 'perfil1', None, tempfile.mkdtemp())
assert r['resposta'] == '42' and visto['vazia'] and visto['entrada'] == 'quanto é 6x7?' and 'quanto' not in ' '.join(visto['cmd'])
c = visto['cmd']
assert c[c.index('--tools') + 1] == '' and '--strict-mcp-config' in c and c[c.index('--setting-sources') + 1] == 'project'
assert visto['env']['CLAUDE_CONFIG_DIR'].endswith('/claude-profiles/perfil1/home')
pergunta.codex('oi', None, None, tempfile.mkdtemp())
c = visto['cmd']
assert c[c.index('--sandbox') + 1] == 'read-only' and '--ephemeral' in c and c[-1] == '-'
assert all(f in c for f in ('shell_tool', 'unified_exec', 'code_mode_host', 'view_image', 'browser_use', 'computer_use', 'apps', 'plugins'))
print('ok pergunta')

# sem login: Alice deslogado cai na Bia; todas deslogadas = mensagem clara (nunca o "Please run /login" do CLI)
cs = [{'nome': 'Alice', 'perguntar': 'claude-cli', 'perfil': 'ed'}, {'nome': 'Bia', 'perguntar': 'claude-cli', 'perfil': 'cl'},
      {'nome': 'GPT', 'perguntar': 'codex-cli'}]
pediu = []
def uma_falsa(erro):
    return lambda p, c, pasta: (pediu.append(c['nome']), {'erro': erro} if c['nome'] in ('Alice', 'GPT') else {'resposta': 'oi!'})[1]
r = pergunta.responder('oie', cs, None, logado=lambda prov, perfil: None, uma=uma_falsa('Not logged in · Please run /login'))
assert (r['resposta'], r['conta'], r['nota'], pediu) == ('oi!', 'Bia', 'Alice sem login, respondi pela Bia', ['Alice', 'Bia']), r
pediu.clear()  # todas deslogadas: o teste barato pula as do Claude (nenhuma pergunta gasta), o Codex responde 401
r = pergunta.responder('oie', cs, None, logado=lambda prov, perfil: False if prov == 'claude-cli' else None,
                       uma=uma_falsa('ERROR: unexpected status 401 Unauthorized: Missing bearer'))
assert r['erro'] == 'Nenhuma conta de IA está logada (Alice, Bia e GPT). Clique num logo pra entrar pelo Orca.' and pediu == ['GPT'], r
assert pergunta.responder('x', cs[:1], None, logado=lambda *a: False)['erro'] == 'Alice está sem login. Clique no logo pra entrar pelo Orca.'
assert not pergunta.SEM_LOGIN.search('demorou mais de 90 s') and not pergunta.SEM_LOGIN.search('sem rede')
testes = []
pergunta.logado = lambda prov, perfil=None: testes.append(perfil) or False
coleta.LOGIN.clear()
x = coleta.conta({'nome': 'Alice', 'fonte': 'claude-perfil', 'perfil': 'ed', 'perguntar': 'claude-cli'}, agora)
coleta.conta({'nome': 'Alice', 'fonte': 'claude-perfil', 'perfil': 'ed', 'perguntar': 'claude-cli'}, agora + 60)
assert (x['semLogin'], x['card'], x['nivel'], testes) == (True, ['sem login'], -1, ['ed']), x  # 2ª coleta em 1 min: cache, sem testar de novo
# token vencido: o Codex diz "logado", a pergunta viu o 401 há 2 min → o coletor marca "sem login" mesmo assim
pergunta.logado, pergunta.anotado = (lambda prov, perfil=None: True), (lambda prov, perfil=None: agora - 120)
coleta.LOGIN.clear()
assert coleta.conta({'nome': 'GPT', 'fonte': 'codex-sessoes', 'perguntar': 'codex-cli'}, agora).get('semLogin')
vencido = '2026-11-23T11:34:25.540588Z ERROR codex_login::auth::manager: Failed to refresh token: Your access token could not be refreshed.'
assert pergunta.CODEX_SEM_LOGIN.search('OpenAI Codex\n' + vencido) and pergunta.CODEX_SEM_LOGIN.search('ERROR: unexpected status 401 Unauthorized')
assert not pergunta.CODEX_SEM_LOGIN.search('2026-11-23T11:34:26Z ERROR rmcp::transport::worker: HTTP 401')  # 401 de MCP não é login
assert not pergunta.CODEX_SEM_LOGIN.search('user\npor que dá ERROR 401 no login?')                           # nem a pergunta ecoada
print('ok sem login')

# rede: velocidade do cabo, contadores do netstat (tráfego da sonda), JSON do networkQuality e a rede estruturada no detalhe
import sonda as _sonda, acoes as _acoes
assert (_sonda.link('\tmedia: autoselect (1000baseT <full-duplex>)'), _sonda.link('media: autoselect (10Gbase-T <full-duplex>)'),
        _sonda.link('media: autoselect (2500Base-T <full-duplex>)'), _sonda.link('media: autoselect (none)')) == (1000, 10000, 2500, None)
_sh = _sonda.sh
_sonda.sh = lambda cmd, timeout=10: ('Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\n'
                                     'en1 1500 <Link#14> aa:bb:cc:dd:ee:ff 10 0 5962893461 9 0 5825633800 0\n'
                                     'en1 1500 192.168.1 192.168.1.130 1 - 100 2 - 200 -\n')
assert _sonda.contadores('en1')[1:] == (5962893461, 5825633800)
_sonda.sh = _sh
v = _acoes.velocidade('{"dl_throughput": 245000000, "ul_throughput": 38000000, "responsiveness": 1234.5, "interface_name": "en1"}')
assert (v['down'], v['up'], v['rpm']) == (245000000, 38000000, 1234.5), v
assert 'erro' in _acoes.velocidade('') and 'NSURLErrorDomain' in _acoes.velocidade('{"error_code": -1009, "error_domain": "NSURLErrorDomain"}')['erro']
w = {'rssi': -51, 'ruido': -81, 'taxa': 57, 'canal': 11, 'banda': '2,4 GHz', 'largura': 20, 'padrao': 'Wi-Fi 4'}
n = coleta.detalhe(dict(base, rede={'tipo': 'Wi-Fi', 'if': 'en1', 'ip': '192.168.1.130', 'wifi': w, 'down': 600945, 'up': 294775}), '100.1.2.3', None)['net']
assert n == {'tipo': 'Wi-Fi', 'ip': '192.168.1.130', 'down': 600945, 'up': 294775, 'link': None, 'wifi': w, 'iface': 'en1'}, n
assert coleta.detalhe(base, '100.1.2.3', None)['net'] is None
print('ok rede')

# Blocos MF, com serviços e credenciais locais fictícios.
from datetime import date, timedelta
from pathlib import Path
from unittest.mock import patch
import subprocess
import json
import urllib.parse


class ApiMF(http.server.BaseHTTPRequestHandler):
    campanhas = []
    falha = False

    def log_message(self, *args):
        pass

    def do_GET(self):
        caminho = urllib.parse.urlsplit(self.path).path
        if caminho in ('/redirect', '/ok', '/fora'):
            assert self.headers.get('User-Agent') == 'painel-notch/1.0'
        if caminho == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/ok')
            self.end_headers()
            return
        dados = {}
        status = 200
        if caminho == '/fora':
            status = 503
        elif caminho != '/ok':
            assert self.headers.get('Authorization') == 'Bearer chave'
            if caminho.endswith('/insights'):
                dados = {'data': [{'spend': '12.34', 'actions': [
                    {'action_type': 'onsite_conversion.messaging_conversation_started_7d', 'value': '2'}]}]}
            elif caminho.endswith('/campaigns'):
                dados = {'data': self.campanhas}
            elif caminho == '/deploy':
                dados = {'deployments': [{'state': 'ERROR'}]}
            if self.falha:
                status, dados = 400, {'error': {'message': 'recusado chave'}}
        self.send_response(status)
        self.end_headers()
        self.wfile.write(json.dumps(dados).encode())


with http.server.HTTPServer(('127.0.0.1', 0), ApiMF) as servidor:
    _th.Thread(target=servidor.serve_forever, daemon=True).start()
    origem = f'http://127.0.0.1:{servidor.server_port}'
    try:
        with patch.object(agentes, 'segredo', return_value='chave'), patch.object(agentes, 'VERCEL', origem + '/deploy'):
            cfg = {'sites': [dict(nome='A', url=origem + '/redirect'), dict(nome='B', url=origem + '/fora')],
                   'vercelProjetos': {'A': 'prj_1'}}
            r = agentes.sites(cfg, agora)
            assert [x['nivel'] for x in r['canais']] == [0, 2]
            assert r['nivel'] == 2 and r['problemas'] == [dict(nivel=2, titulo='deploy com erro: A')]
            assert agentes.sites(cfg, agora + 299) == r
        print('ok sites')
        with patch.object(agentes, 'META', origem), patch.object(agentes, 'segredo', return_value='chave') as chave:
            cfg = dict(conta='act_1', cplMax=5)
            r = agentes.metaads(cfg, agora)
            assert [x['estado'] for x in r['canais']] == ['R$ 12,34', '2', '0']
            assert [x['nivel'] for x in r['problemas']] == [2, 1]
            ApiMF.campanhas = [{'id': '1'}]
            assert agentes.metaads(cfg, agora + 599) == r
            assert agentes.metaads(cfg, agora + 600)['nivel'] == 1
            ApiMF.falha = True
            r = agentes.metaads(cfg, agora + 1200)
            assert r['nivel'] == 1 and 'recusado' in str(r) and 'chave' not in str(r)
            chave.return_value = None
            assert agentes.metaads(cfg, agora + 1800)['nivel'] == -1
        print('ok metaads')
    finally:
        servidor.shutdown()


with tempfile.TemporaryDirectory() as tmp:
    pasta = Path(tmp)

    def comando(repo, *args):
        subprocess.run(['git', '-c', 'user.name=Teste', '-c', 'user.email=teste@example.org',
                        '-c', 'commit.gpgsign=false', '-C', str(repo), *args], capture_output=True, check=True)

    remoto = pasta / 'remoto.git'
    comando(pasta, 'init', '--bare', str(remoto))
    for nome in ('limpo', 'alterado', 'pendente'):
        repo = pasta / nome
        comando(pasta, 'init', '-b', 'main', str(repo))
        arq = repo / 'um arquivo'
        arq.write_text('1')
        comando(repo, 'add', '.')
        comando(repo, 'commit', '-m', 'inicial')
        if nome == 'alterado':
            arq.write_text('nova versão')
            os.utime(arq, (agora - 3 * 86400,) * 2)
        if nome == 'pendente':
            comando(repo, 'push', '--set-upstream', str(remoto), 'main')
            comando(repo, 'remote', 'add', 'origin', str(remoto))
            comando(repo, 'fetch', 'origin')
            comando(repo, 'branch', '--set-upstream-to=origin/main')
            comando(repo, 'commit', '--allow-empty', '-m', 'local')
    r = agentes.git(dict(pasta=tmp), agora)
    assert r['estado'] == '2 repos pendentes' and r['nivel'] == 1
    assert [p['titulo'] for p in r['problemas']] == ['alterado: alterações sem commit há 3 dias', 'pendente: 1 commits sem push']
print('ok git')


with tempfile.TemporaryDirectory() as tmp:
    arq = Path(tmp) / 'foco.md'
    cfg = dict(arquivo=str(arq))
    agora = time.time()
    for idade in (0, 8):
        arq.write_text(f'**Semana de:** {date.today() - timedelta(days=idade)}\n## Prioridades\n1. Um\n2. Dois\n3. Três\n4. Quatro\n')
        r = agentes.foco(cfg, agora + idade * 60)
        assert r['nivel'] == int(idade > 7)
        assert [p['titulo'] for p in r['problemas'] if not p['nivel']] == ['Um', 'Dois', 'Três']
    assert agentes.foco(dict(arquivo=str(arq) + '.ausente'), agora)['nivel'] == -1
print('ok foco')

# Exercita a leitura e a gravação reais do app sem abrir a interface nem tocar na configuração do usuário.
import sys
if sys.platform == 'darwin':
    fontes = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory() as tmp:
        pasta = Path(tmp)
        arquivo = pasta / 'config.json'
        entrada = json.loads((fontes / 'docs/config-mf-exemplo.json').read_text())
        entrada['agentes'].append({'id': 'antigo', 'tipo': 'generico', 'url': 'https://example.com'})
        arquivo.write_text(json.dumps(entrada))
        swift = (fontes / 'Ajustes.swift').read_text().split('enum Py {', 1)[0]
        (pasta / 'main.swift').write_text(swift + """
let store = ConfigStore()
precondition(store.existe)
store.c.intervalo += 1
store.gravar()
""")
        subprocess.run(['swift', str(pasta / 'main.swift')], check=True,
                       env=dict(os.environ, FROTA_CONFIG=str(arquivo)))
        salvo = json.loads(arquivo.read_text())
        assert salvo['intervalo'] == 21
        assert len(salvo['agentes']) == len(entrada['agentes'])
        for antes, depois in zip(entrada['agentes'], salvo['agentes']):
            assert all(depois[chave] == valor for chave, valor in antes.items())
            assert ('cplMax' in depois) == ('cplMax' in antes)
        assert salvo['agentes'][-1]['sites'] == [] and salvo['agentes'][-1]['dias'] == 1
    print('ok persistência Swift (config antiga e quatro adaptadores)')

# (os registros reais são JSON compacto, sem espaço depois de ':')
# uso por modelo (modelos.py): Claude com a mesma resposta em 2 linhas (conta 1×), modo rápido, cache 5 min × 1 h,
# Codex com token_usage_record (e o token_count repetido ignorado), leitura incremental e preço pelo prefixo mais longo
import modelos
raiz = tempfile.mkdtemp()
modelos.ARQ = os.path.join(raiz, 'cache.json')
modelos.CACHE = raiz
cl, cx = os.path.join(raiz, 'projects', 'p'), os.path.join(raiz, 'sessions', '2026')
os.makedirs(cl); os.makedirs(cx)
ts = time.strftime('%Y-%m-%dT%H:%M:00.000Z', time.gmtime())


def resp(mid, modelo, ent, sai, lido=0, w5=0, w1=0, fast=False):
    u = {'input_tokens': ent, 'cache_creation_input_tokens': w5 + w1, 'cache_read_input_tokens': lido, 'output_tokens': sai,
         'cache_creation': {'ephemeral_5m_input_tokens': w5, 'ephemeral_1h_input_tokens': w1}, 'speed': 'fast' if fast else 'standard'}
    return json.dumps({'parentUuid': None, 'message': {'model': modelo, 'id': mid, 'role': 'assistant', 'content': [{'type': 'text', 'text': '"usage":{ no texto'}],
                       'usage': u}, 'requestId': 'r' + mid, 'type': 'assistant', 'timestamp': ts}, separators=(',', ':')) + '\n'


import json
arq = os.path.join(cl, 's.jsonl')
with open(arq, 'w') as fh:
    fh.write(resp('m1', 'claude-opus-5-5', 10, 1000, lido=1_000_000, w5=100_000) + resp('m1', 'claude-opus-5-5', 10, 1000, lido=1_000_000, w5=100_000))
    fh.write(json.dumps({'type': 'user', 'message': {'content': 'x'}, 'toolUseResult': {'usage': {'output_tokens': 999}}}, separators=(',', ':')) + '\n')  # usage de subagente: não conta
    fh.write(resp('m2', 'claude-sonnet-4-5-20250929', 0, 0, w1=1_000_000) + resp('m3', 'claude-opus-5-5', 1000, 0, fast=True))
    fh.write(resp('m4', '<synthetic>', 0, 0) + '{"type":"assistant","message":{"usage":{')  # linha pela metade: fica pra próxima
cod = [{'type': 'turn_context', 'payload': {'model': 'gpt-6.2-sol'}},
       {'type': 'token_usage_record', 'payload': {'response_id': 'a', 'usage': {'input_tokens': 500, 'cached_input_tokens': 400, 'output_tokens': 7}}},
       {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {'last_token_usage': {'input_tokens': 500, 'output_tokens': 7}}}}]
with open(os.path.join(cx, 'r.jsonl'), 'w') as fh:
    fh.write(''.join(json.dumps(dict(x, timestamp=ts), separators=(',', ':')) + '\n' for x in cod))
modelos.fontes = lambda c: ('claude', [os.path.realpath(os.path.join(raiz, 'projects'))]) if c['fonte'] == 'claude-perfil' \
    else ('codex', [os.path.realpath(os.path.join(raiz, 'sessions'))])
cfg = {'ia': [{'id': 'a', 'nome': 'Lia', 'fonte': 'claude-perfil'}, {'id': 'b', 'nome': 'Bia', 'fonte': 'claude-perfil'},
              {'id': 'g', 'nome': 'GPT', 'fonte': 'codex-sessoes'}]}
r = modelos.resumo(cfg['ia'][0], cfg)
h = {m['id']: m for m in r['janelas']['hoje']['modelos']}
assert set(h) == {'claude-opus-5-5', 'claude-sonnet-4-5-20250929', 'claude-opus-5-5|fast'}, h
o = h['claude-opus-5-5']
assert (o['entrada'], o['saida'], o['cacheLe'], o['cacheEscreve'], o['respostas']) == (10, 1000, 1_000_000, 100_000, 1), o
assert abs(o['custo'] - (10 * 4 + 1000 * 20 + 1_000_000 * 0.2 + 100_000 * 5) / 1e6) < 1e-4  # (custo sai com 4 casas)
assert abs(h['claude-sonnet-4-5-20250929']['custo'] - 6.0) < 1e-6 and h['claude-sonnet-4-5-20250929']['nome'] == 'Sonnet 4.5'  # 1 h: 2× a entrada
assert abs(h['claude-opus-5-5|fast']['custo'] - 1000 * 8 / 1e6) < 1e-9 and h['claude-opus-5-5|fast']['nome'] == 'Opus 5.5 · fast'
assert r['compartilhado'] == ['Bia'] and r['janelas']['mes']['semPreco'] == []
with open(arq, 'a') as fh:  # a linha pela metade termina e conta; o que já foi lido não conta de novo
    fh.write('"input_tokens":5,"output_tokens":5}},"id":"m5","model":"claude-haiku-5-5","timestamp":"' + ts + '"}\n')
r2 = modelos.resumo(cfg['ia'][0], cfg)['janelas']['hoje']
assert {m['id']: m['respostas'] for m in r2['modelos']} == {'claude-opus-5-5': 1, 'claude-sonnet-4-5-20250929': 1, 'claude-opus-5-5|fast': 1, 'claude-haiku-5-5': 1}, r2
assert modelos.resumo(cfg['ia'][0], cfg)['janelas']['hoje'] == r2  # nada novo: o mesmo resultado, sem reler
g = modelos.resumo(cfg['ia'][2], cfg)['janelas']['7d']
assert [(m['nome'], m['entrada'], m['cacheLe'], m['saida'], m['custo']) for m in g['modelos']] == [('GPT-6.2 Sol', 100, 400, 7, None)], g
assert g['semPreco'] == ['GPT-6.2 Sol']
assert modelos.nome('gpt-6.1-terra') == 'GPT-6.1 Terra' and modelos.nome('claude-fable-5-2') == 'Fable 5.2'
assert modelos.preco('claude-opus-5-5', modelos.PRECOS)['entrada'] == 4 and modelos.preco('claude-opus-5', modelos.PRECOS)['entrada'] == 5
assert modelos.demo()['janelas']['7d']['custo'] > 0
print('ok modelos')
