// Assistente de primeira execução: sem config.json, o app abre aqui. Descobre os Macs na Tailscale, explica e resolve a
// chave SSH (gera, instala com ssh-copy-id no Terminal, testa), e oferece servidores do ~/.ssh/config, e-mail pelo
// Composio, contas de IA e agentes achados neste Mac. No fim grava o config.json (sem segredo) e a ilha aparece.
import SwiftUI

final class EstadoAssistente: ObservableObject {
    @Published var passo = 0
    @Published var c: Config
    @Published var chave: [String: Any] = [:]
    @Published var marcados: Set<String> = []  // ids "mac:<host>", "srv:<apelido>", "mail:<conta>", "ia:<perfil|ferramenta>", "ag:<nome>"
    init(_ c: Config) { self.c = c }
    func alterna(_ k: String) { if marcados.contains(k) { marcados.remove(k) } else { marcados.insert(k) } }
}

struct AssistenteView: View {
    @ObservedObject var e: EstadoAssistente
    @ObservedObject var a: EstadoAjustes
    let concluir: (Config) -> Void
    static var titulos: [String] { [t("Boas-vindas"), t("Visual"), t("Do seu jeito"), t("Macs"), t("Acesso SSH"), t("Servidores"), t("E-mail"), t("IA"), t("Agentes"), t("Pronto")] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<Self.titulos.count, id: \.self) { i in
                    Capsule().fill(i <= e.passo ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: i == e.passo ? 22 : 8, height: 6)
                }
            }.padding(.top, 18).animation(.easeOut(duration: 0.2), value: e.passo)
            Group {
                switch e.passo {
                case 0: boasVindas
                case 1: visual
                case 2: extras
                case 3: macs
                case 4: ssh
                case 5: servidores
                case 6: email
                case 7: ia
                case 8: agentes
                default: pronto
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 36).padding(.top, 22)
            Divider()
            HStack {
                if e.passo == 0 { SeletorIdioma(compacto: true).pickerStyle(.menu).fixedSize() }
                if e.passo > 0 && e.passo < 9 { Button(t("Voltar")) { e.passo -= 1 } }
                Spacer()
                if [5, 6, 7, 8].contains(e.passo) { Button(t("Pular")) { e.passo += 1 } }
                Button(e.passo == 0 ? t("Começar") : e.passo == 9 ? t("Abrir a ilha") : t("Continuar")) { avancar() }
                    .keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(width: 660, height: 600)
        .onAppear {
            a.carregar()
            Py.rodar("ajustes", ["chave"]) { e.chave = $0 }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func cabecalho(_ simbolo: String, _ titulo: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: simbolo).font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor).frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(titulo).font(.system(size: 20, weight: .semibold))
                Text(texto).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.bottom, 14)
    }

    func caixa(_ k: String, @ViewBuilder _ rotulo: () -> some View) -> some View {
        Toggle(isOn: Binding(get: { e.marcados.contains(k) }, set: { _ in e.alterna(k) })) { rotulo() }.toggleStyle(.checkbox)
    }

    var boasVindas: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black).frame(width: 120, height: 34)
                    .overlay(HStack(spacing: 4) { ForEach(0..<4, id: \.self) { _ in Circle().fill(Color.white.opacity(0.8)).frame(width: 5, height: 5) } }.padding(.leading, 14),
                             alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Tudo que é seu, num relance")).font(.system(size: 22, weight: .semibold))
                    Text(t("Seus Macs, servidores, e-mails, agentes e contas de IA no notch do topo da tela.")).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Label(t("Os outros Macs são lidos por SSH, sem instalar nada neles."), systemImage: "desktopcomputer")
                Label(t("Só leitura. Nada do que é seu sai deste Mac: o app não tem servidor."), systemImage: "lock")
                Label(t("Senhas e chaves ficam no Keychain, nunca em arquivo."), systemImage: "key")
                Label(t("Dá pra mudar tudo depois em Ajustes (⌘,)."), systemImage: "gearshape")
            }.font(.system(size: 13))
        }
    }

    /// Light ou Full e o estilo dos anéis, com a ilha desenhada em miniatura (o mesmo que os Ajustes › Aparência mostram).
    var visual: some View {
        VStack(alignment: .leading, spacing: 12) {
            cabecalho("paintpalette", t("Do jeito que você gosta de olhar"), t("Dá pra mudar tudo depois em Ajustes › Aparência, com prévia ao vivo."))
            SeletorModo(modo: $e.c.visual.modo, estilo: e.c.visual.estilo)
            Text(t("Estilo dos anéis")).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
            GaleriaPresets(v: $e.c.visual, colunas: 8)
            HStack {
                ColorPicker(t("Cor de destaque"), selection: Binding(get: { Color(hex: e.c.visual.destaque) }, set: { e.c.visual.destaque = $0.hex }), supportsOpacity: false)
                Spacer()
                Picker(t("Densidade"), selection: $e.c.visual.densidade) {
                    Text(t("Compacta")).tag("compacta"); Text(t("Padrão")).tag("padrao"); Text(t("Arejada")).tag("arejada")
                }.pickerStyle(.segmented).frame(width: 300)
            }
        }
    }

    /// O resto do gosto e o histórico do ⌘C: o opt-in vem primeiro, com a explicação de privacidade do lado do botão.
    var extras: some View {
        VStack(alignment: .leading, spacing: 4) {
            cabecalho("slider.horizontal.3", t("Do seu jeito"), t("Notch, números, som e atalho. Tudo opcional, tudo nos Ajustes depois."))
            Form {
                Section {
                    Toggle(t("Guardar o histórico do que você copia (⌘C)"), isOn: $e.c.modulos.copiados)
                } footer: {
                    Text(t("Desligado por padrão. Ligado, fica só na memória deste Mac e some quando o app fecha; ignora senhas e o que os gerenciadores de senha marcam como sensível."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { OpcoesVisuais(v: $e.c.visual, basico: false) }
                Section { OpcoesAtalho(ligado: $e.c.aparencia.atalho, v: $e.c.visual) }
            }.formStyle(.grouped).padding(.horizontal, -20)
        }
    }

    var macs: some View {
        VStack(alignment: .leading) {
            cabecalho("dot.radiowaves.left.and.right", t("Seus Macs na Tailscale"),
                      t("Marque os que você quer ver. Pra ler um Mac à distância, ele precisa estar na mesma Tailscale e com o Login Remoto ligado."))
            if a.nos.isEmpty {
                Text(t("Não achei a Tailscale neste Mac. Dá pra seguir só com este Mac e adicionar outros depois, pelo IP ou nome.")).foregroundStyle(.secondary)
                caixa("mac:local") { Text(t("Este Mac")) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(a.nos.filter { $0["os"] as? String == "macOS" }.enumerated()), id: \.offset) { _, n in
                        let host = n["host"] as? String ?? "", este = n["este"] as? Bool == true, on = n["online"] as? Bool == true
                        caixa("mac:\(host)") {
                            HStack {
                                Circle().fill(on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                                Text(host)
                                if este { Text(t("este Mac")).font(.caption).foregroundStyle(.secondary) }
                                if !on { Text(t("offline agora")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }.onAppear {
            if e.marcados.filter({ $0.hasPrefix("mac:") }).isEmpty {
                for n in a.nos where n["este"] as? Bool == true || n["online"] as? Bool == true { if n["os"] as? String == "macOS" { e.marcados.insert("mac:\(n["host"] as? String ?? "")") } }
                if a.nos.isEmpty { e.marcados.insert("mac:local") }
            }
        }
    }

    var remotos: [String] {
        e.marcados.filter { $0.hasPrefix("mac:") }.map { String($0.dropFirst(4)) }
            .filter { h in h != "local" && !a.nos.contains { $0["host"] as? String == h && $0["este"] as? Bool == true } }.sorted()
    }

    var ssh: some View {
        VStack(alignment: .leading, spacing: 12) {
            cabecalho("key", t("Acesso por chave SSH"),
                      t("O app entra nos outros Macs com uma chave (sem senha) e só roda uma leitura de CPU, memória e disco. A chave mora em ~/.ssh e nunca sai daqui; o outro Mac só guarda a parte pública."))
            HStack {
                if e.chave["existe"] as? Bool == true {
                    Label(t("Chave pronta: {0}", e.chave["digital"] as? String ?? ""), systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                } else {
                    Label(t("Este Mac ainda não tem chave SSH."), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    Button(t("Gerar chave")) { Py.rodar("ajustes", ["gerar-chave"]) { e.chave = $0 } }
                }
            }
            if remotos.isEmpty { Text(t("Você marcou só este Mac: nada a fazer aqui.")).foregroundStyle(.secondary) }
            ForEach(remotos, id: \.self) { h in
                HStack(alignment: .top) {
                    Text(h).frame(width: 190, alignment: .leading)
                    Button(t("Instalar chave…")) { Py.rodar("ajustes", ["instalar-chave", "--host", h]) { _ in } }.disabled(e.chave["existe"] as? Bool != true)
                    Button(t("Testar")) { a.testar("mac:\(h)", ["testar", "--host", h]) }
                    ResultadoTeste(r: a.testes["mac:\(h)"], rodando: a.testando.contains("mac:\(h)"))
                }
            }
            Text(t("\"Instalar chave\" abre o Terminal com ssh-copy-id: você digita a senha do outro Mac lá, uma vez (o app nunca vê a senha). No outro Mac, ligue Ajustes do Sistema › Geral › Compartilhamento › Login Remoto."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var servidores: some View {
        VStack(alignment: .leading) {
            cabecalho("server.rack", t("Servidores Linux (opcional)"),
                      t("VPS e servidores com SSH: CPU, memória, disco, serviços do systemd e containers. Só leitura, sem sudo, sem instalar nada."))
            if a.hostsSSH.isEmpty { Text(t("Nada no ~/.ssh/config. Dá pra adicionar depois em Ajustes › Servidores.")).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(a.hostsSSH.enumerated()), id: \.offset) { _, h in
                        let ap = h["apelido"] as? String ?? ""
                        caixa("srv:\(ap)") { HStack { Text(ap); Text(h["usuario"] as? String ?? "").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }
        }
    }

    var email: some View {
        VStack(alignment: .leading, spacing: 10) {
            cabecalho("envelope", t("E-mail (opcional)"),
                      t("Pelo Composio, com a sua chave: quantos não lidos e o último cabeçalho de cada conta. Nunca o corpo. A chave fica no Keychain."))
            CampoSegredo(conta: "composio", titulo: t("Chave do Composio"), dica: t("uak_… ou ak_…"), a: a)
            HStack {
                Button(t("Importar do Composio CLI")) { Py.rodar("ajustes", ["composio-importar"]) { _ in a.conferir("composio"); a.buscarComposio() } }
                Button(t("Buscar contas")) { a.buscarComposio() }.disabled(a.temSegredo["composio"] != true)
            }
            if let erro = a.erroComposio { Text(erro).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(a.contasComposio.filter { $0["status"] as? String == "ACTIVE" }.enumerated()), id: \.offset) { _, x in
                        caixa("mail:\(x["id"] as? String ?? "")") { Text(x["apelido"] as? String ?? "") }
                    }
                }
            }
        }.onAppear { if a.temSegredo["composio"] == true { a.buscarComposio() } }
    }

    var ia: some View {
        VStack(alignment: .leading) {
            cabecalho("sparkles", t("Contas de IA (opcional)"), t("O uso de cada assinatura num anel, e a pergunta rápida usando as contas já logadas neste Mac (sem chave de API)."))
            if a.fontesIA.isEmpty { Text(t("Não achei Claude Code nem Codex neste Mac.")).foregroundStyle(.secondary) }
            ForEach(Array(a.fontesIA.enumerated()), id: \.offset) { _, f in
                caixa("ia:\(f["perfil"] as? String ?? "")\(f["ferramenta"] as? String ?? "")") {
                    HStack { LogoApp(caminhos: f["app"] as? [String] ?? [], ferramenta: f["ferramenta"] as? String ?? "", tamanho: 18); Text(f["nome"] as? String ?? "") }
                }
            }
        }
    }

    var agentes: some View {
        VStack(alignment: .leading) {
            cabecalho("person.2.wave.2", t("Agentes (opcional)"), t("Hermes, OpenClaw ou qualquer agente com uma URL de health: no ar ou não, canais e último erro. Só leitura."))
            if a.agentesAchados.isEmpty { Text(t("Nenhum agente achado neste Mac. Dá pra adicionar um genérico em Ajustes › Agentes.")).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(a.agentesAchados.enumerated()), id: \.offset) { _, x in
                        caixa("ag:\(x["nome"] as? String ?? "")") {
                            HStack { Text(x["nome"] as? String ?? ""); Text(x["tipo"] as? String ?? "").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    var pronto: some View {
        let c = montar()
        return VStack(alignment: .leading, spacing: 14) {
            cabecalho("checkmark.seal", t("Pronto"), t("Olhe o topo da tela: clique no notch pra abrir. Passe o mouse nele pra ver o que cada ponto quer dizer."))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text(t("Macs")).foregroundStyle(.secondary); Text("\(c.maquinas.count)") }
                GridRow { Text(t("Servidores")).foregroundStyle(.secondary); Text("\(c.servidores.count)") }
                GridRow { Text(t("Contas de e-mail")).foregroundStyle(.secondary); Text("\(c.email.contas.count)") }
                GridRow { Text(t("Contas de IA")).foregroundStyle(.secondary); Text("\(c.ia.count)") }
                GridRow { Text(t("Agentes")).foregroundStyle(.secondary); Text("\(c.agentes.count)") }
            }.font(.system(size: 13))
        }
    }

    func avancar() {
        if e.passo == 9 { concluir(montar()); return }
        e.passo += (e.passo == 3 && remotos.isEmpty) ? 2 : 1  // sem Mac remoto, não tem o que fazer no passo da chave
    }

    /// A config que sai do assistente: a que já existia + o que foi marcado (nada duplica).
    func montar() -> Config {
        var c = e.c
        for k in e.marcados.sorted() {
            let v = String(k.split(separator: ":", maxSplits: 1).last ?? "")
            if k.hasPrefix("mac:") && !c.maquinas.contains(where: { $0.host == v }) {
                let este = v == "local" || a.nos.contains { $0["host"] as? String == v && $0["este"] as? Bool == true }
                let nome = este ? (Foundation.Host.current().localizedName ?? t("Este Mac")) : v
                c.maquinas.append(CMaquina(nome: nome, curto: String(nome.prefix(12)), host: v))
            } else if k.hasPrefix("srv:") && !c.servidores.contains(where: { $0.host == v }) {
                c.servidores.append(CServidor(nome: v, host: v))
            } else if k.hasPrefix("mail:"), let x = a.contasComposio.first(where: { $0["id"] as? String == v }), !c.email.contas.contains(where: { $0.conta == v }) {
                let ap = x["apelido"] as? String ?? v
                c.email.contas.append(CEmailConta(nome: ap.components(separatedBy: "@").first ?? ap, conta: v, endereco: ap.contains("@") ? ap : ""))
            } else if k.hasPrefix("ia:"), let f = a.fontesIA.first(where: { "\($0["perfil"] as? String ?? "")\($0["ferramenta"] as? String ?? "")" == v }),
                      !c.ia.contains(where: { $0.perfil == (f["perfil"] as? String ?? "") && $0.ferramenta == (f["ferramenta"] as? String ?? "") }) {
                c.ia.append(CIA(nome: f["nome"] as? String ?? "", ferramenta: f["ferramenta"] as? String ?? "", fonte: f["fonte"] as? String ?? "",
                                perfil: f["perfil"] as? String ?? "", app: f["app"] as? [String] ?? [], perguntar: f["perguntar"] as? String ?? ""))
            } else if k.hasPrefix("ag:"), let x = a.agentesAchados.first(where: { $0["nome"] as? String == v }), !c.agentes.contains(where: { $0.nome == v }) {
                c.agentes.append(CAgente(nome: v, tipo: x["tipo"] as? String ?? "generico", home: x["home"] as? String ?? "", perfil: x["perfil"] as? String ?? "",
                                         porta: x["porta"] as? Int ?? 0))
            }
        }
        return c
    }
}
