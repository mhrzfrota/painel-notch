# config.json

`~/Library/Application Support/FleetNotch/config.json`. Written by the Settings window and the first-run assistant; you rarely need to
edit it by hand. **No secrets here**: keys and passwords live in the Keychain (service `FleetNotch`). Missing keys fall back to defaults.

```json
{
  "intervalo": 20,
  "usuarioSSH": "",
  "maquinas": [
    {"nome": "Studio", "curto": "Studio", "host": "local", "usuario": "", "icone": "", "visivel": true},
    {"nome": "MacBook Pro", "host": "mbp", "icone": "com.apple.macbookpro"}
  ],
  "servidores": [
    {"nome": "web-01", "host": "web-01", "usuario": "deploy", "porta": 22, "servicos": ["nginx", "docker"], "docker": true}
  ],
  "email": {"intervalo": 60, "contas": [
    {"nome": "Work", "provedor": "composio", "conta": "ca_…", "endereco": "you@example.com"},
    {"nome": "Personal", "provedor": "imap", "servidor": "imap.example.org", "porta": 993, "usuario": "me@example.org"}
  ]},
  "ia": [
    {"nome": "Pro", "ferramenta": "Claude", "fonte": "claude-perfil", "perfil": "<profile id>", "app": ["/Applications/Claude.app"],
     "perguntar": "claude-cli", "modelo": ""},
    {"nome": "Plus", "ferramenta": "ChatGPT", "fonte": "codex-sessoes", "perguntar": "codex-cli"}
  ],
  "agentes": [
    {"nome": "Atlas", "tipo": "hermes", "home": "~/.hermes", "perfil": "", "foto": "fotos/<id>.png"},
    {"nome": "Nova", "tipo": "openclaw", "porta": 18789},
    {"nome": "Scout", "tipo": "generico", "url": "http://127.0.0.1:8088/health", "rotulo": "com.example.scout", "log": "~/Library/Logs/scout.log"}
  ],
  "sincronizacao": {"agentes": "backup"},
  "modulos": {"macs": true, "servidores": true, "email": true, "ia": true, "agentes": true, "sincronizacao": true, "orca": true,
              "pergunta": true, "acoes": true, "copiados": false,
              "ordem": ["topo", "macs", "servidores", "email", "orca", "sincronizacao", "pergunta", "copiados"]},
  "aparencia": {"ilha": true, "todasTelas": false, "corAtencao": "#FF9F0A", "corCritico": "#FF453A", "atalho": false,
                "limites": {"cpu": [60, 85], "gpu": [60, 85], "ram": [80, 92], "temp": [85, 95], "disco": [10, 5], "ia": [80, 95]}},
  "demo": false,
  "visual": {"modo": "full", "destaque": "#64D2FF", "densidade": "padrao", "metricas": ["cpu", "gpu", "ram"], "numeros": "compactos",
             "notch": "completo", "abrirNoHover": false, "somAbrir": false, "somAlerta": false,
             "atalhoTecla": "ctrl-opt-space", "atalhoAcao": "pergunta",
             "estilo": {"id": "classico", "nome": "", "contas": "neutro", "aneis": [
               {"cor": "#64D2FF", "cor2": "", "espessura": 1.0, "trilho": 0.16, "brilho": 0.0, "redonda": true}, {"cor": "#A69CFF"}, {"cor": "#7DDBB8"}]},
             "presets": [], "copiados": {"limite": 20, "expira": 86400, "excluidos": ["com.1password.1password", "com.apple.keychainaccess"]}},
  "precos": [{"modelo": "claude-opus-5-5", "entrada": 4, "saida": 20, "cacheLe": 0.2, "cache5m": 5, "cache1h": 8}]
}
```

| Key | Meaning |
|---|---|
| `host` | Tailscale name (short or MagicDNS), an IP, an `~/.ssh/config` alias, or `local` for this Mac |
| `icone` | empty = automatic from `hw.model`; or a model type such as `com.apple.macmini` |
| `servicos` | systemd units to check with `systemctl is-active` (names only: letters, digits, `@ . : _ -`) |
| `email.intervalo` | minutes between unread counts (1 Composio tool call per account each time) |
| `fonte` | `claude-perfil` (Claude Code rate-limit cache written by `statusline.py`: `~/.claude` when `perfil` is empty, else that Orca profile), `codex-sessoes` (Codex CLI sessions) or empty |
| `perguntar` | quick-ask provider: `claude-cli`, `codex-cli`, `anthropic-api`, `openai-api` or empty |
| `limites` | `[attention, critical]`; for `disco` it is **% free** (below = alert) |
| `modulos.orca` | missing = on only if `/Applications/Orca.app` exists |
| `ordem` | drawer blocks top to bottom; neighbouring `email`, `orca`, `sincronizacao` share one row; `copiados` is the clipboard history |
| `visual.modo` | `light` (icons and rings, numbers on hover) or `full` |
| `visual.metricas` | what the three Mac rings show, outside in: `cpu`, `gpu`, `ram`, `disco` (system disk % used), `temp` (°C) |
| `visual.notch` | closed notch: `completo` (all signals), `alertas` (only what needs you) or `vazio` (no signals) |
| `visual.estilo` | the ring style: per ring `cor`, optional gradient end `cor2`, `espessura` (×), `trilho` (track opacity), `brilho` (glow 0–1), `redonda`; `contas`: `neutro`, `marca` (each AI's brand color) or `destaque` |
| `visual.atalhoTecla` | `ctrl-opt-space`, `opt-space`, `shift-cmd-space`, `ctrl-opt-f`, `opt-cmd-n`; `atalhoAcao`: `pergunta` or `gaveta` |
| `visual.copiados` | clipboard history (module `modulos.copiados`, off by default): `limite` items, `expira` seconds, `excluidos` bundle ids |
| `precos` | USD per million tokens by model-id prefix (longest wins); empty = the built-in table in `modelos.py` |

### How `host` is reached

Every cycle the collector reads `tailscale status` and resolves each `host`:

| `host` is… | Online status from | SSH goes to |
|---|---|---|
| `local` (or empty) | — | nothing: this Mac is read directly |
| a Tailscale name or `100.x` IP that is **also a `Host` alias in `~/.ssh/config`** | Tailscale | the **alias**, so its `HostName`, `User`, `IdentityFile` and `known_hosts` entry apply |
| a Tailscale name or `100.x` IP with no alias | Tailscale | the node's Tailscale IP |
| anything else (IP, DNS name, alias of a host outside the tailnet) | the probe itself | `host` as typed |

Only plain aliases on `Host` lines count (no wildcards); `Include` and `Match` are not followed. A user set in the app's
**SSH username** field still wins over the alias's `User`.

Keychain accounts (service `FleetNotch`): `composio`, `imap:<user>@<server>`, `uazapi:<host>`, `anthropic`, `openai`.
