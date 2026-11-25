// Ajustes: o config.json do usuário (~/Library/Application Support/<App>/config.json, sem segredo nenhum), quem grava
// nele, e a janela de Ajustes nativa (cena Settings do SwiftUI, com abas como os Ajustes dos apps da Apple).
// Segredo (chave do Composio, senha de app do IMAP, token da UAZAPI, chave de API) mora só no Keychain e passa pelo
// ajustes.py, sempre pelo stdin.
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Config

struct CMaquina: Codable, Identifiable, Equatable {
    var id = UUID().uuidString, nome = "", curto = "", host = "", usuario = "", modelo = "", icone = "", visivel = true
}
struct CServidor: Codable, Identifiable, Equatable {
    var id = UUID().uuidString, nome = "", host = "", usuario = "", porta = 22, servicos: [String] = [], docker = false, icone = "", visivel = true
}
/// Periférico renomeado e/ou com ícone trocado (chave = id do periférico na gaveta, ex.: "bMagic Keyboard"). Vazio = padrão.
struct CAparelho: Codable, Equatable {
    var nome = "", icone = ""
    var vazio: Bool { nome.isEmpty && icone.isEmpty }
}
extension CAparelho {  // tolera chave faltando (config editada à mão ou de versão futura)
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        nome = try c.decodeIfPresent(String.self, forKey: .nome) ?? ""
        icone = try c.decodeIfPresent(String.self, forKey: .icone) ?? ""
    }
}
struct CEmailConta: Codable, Identifiable, Equatable {
    var id = UUID().uuidString, nome = "", provedor = "composio", conta = "", endereco = "", servidor = "", porta = 993, usuario = "", visivel = true
}
struct CEmail: Codable, Equatable { var intervalo = 60, contas: [CEmailConta] = [] }
struct CIA: Codable, Identifiable, Equatable {
    var id = UUID().uuidString, nome = "", ferramenta = "Claude", fonte = "", perfil = "", app: [String] = [], perguntar = "", modelo = "", visivel = true
}
struct CSite: Codable, Equatable { var nome: String, url: String }
struct CAgente: Codable, Identifiable, Equatable {
    var id = UUID().uuidString, nome = "", tipo = "hermes", home = "", perfil = "", rotulo = "", porta = 0, url = "", log = "", foto = ""
    var sites: [CSite] = [], vercelProjetos: [String: String] = [:]
    var conta = "", versao = "", cplMax: Double? = nil
    var pasta = "", dias: Double = 1, arquivo = ""
    var uazapiURL = "", instancias: [String: String] = [:], visivel = true
}
struct CSinc: Codable, Equatable { var agentes = "backup" }
struct CModulos: Codable, Equatable {
    var macs = true, servidores = true, email = true, ia = true, agentes = true, sincronizacao = true, acoes = true, pergunta = true
    var orca = FileManager.default.fileExists(atPath: "/Applications/Orca.app")  // ligado só se o Orca estiver instalado
    var copiados = false  // histórico do ⌘C: desligado até a pessoa ligar (assistente ou Ajustes › Copiados)
    var ordem = ["topo", "macs", "servidores", "email", "orca", "sincronizacao", "pergunta", "copiados"]
}
/// Um anel (de fora, do meio ou de dentro): cor ou degradê (cor → cor2), espessura relativa, opacidade do trilho, brilho
/// e ponta. É o que o editor dos Ajustes mexe; os presets são combinações prontas (Visual.swift, Presets).
struct CAnel: Codable, Equatable { var cor = "#64D2FF", cor2 = "", espessura = 1.0, trilho = 0.16, brilho = 0.0, redonda = true }
/// Estilo dos anéis: os três anéis do Mac e a cor dos anéis das contas de IA ("neutro", "marca" ou "destaque").
struct CEstilo: Codable, Equatable, Identifiable {
    var id = "classico", nome = "", aneis = [CAnel(cor: "#64D2FF"), CAnel(cor: "#A69CFF"), CAnel(cor: "#7DDBB8")], contas = "neutro"
}
/// Histórico do que se copia: só na memória, com limite e validade; nunca o que vem destes apps (bundle id).
struct CCopiados: Codable, Equatable {
    var limite = 20, expira = 86400
    var excluidos = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop"]
}
/// Tudo que é gosto (Ajustes › Aparência e o assistente). Nada disso muda a coleta: mexer aqui não reinicia o coletor.
struct CVisual: Codable, Equatable {
    var modo = "full", destaque = "#64D2FF", densidade = "padrao", metricas = ["cpu", "gpu", "ram"], numeros = "compactos"
    var notch = "completo", abrirNoHover = false, somAbrir = false, somAlerta = false, atalhoTecla = "ctrl-opt-space", atalhoAcao = "pergunta"
    var estilo = CEstilo(), presets: [CEstilo] = [], copiados = CCopiados()
}
/// Preço por milhão de tokens (USD) de um modelo, pelo prefixo do id. Vazio na config = a tabela padrão do modelos.py.
struct CPreco: Codable, Equatable, Identifiable {
    var id = UUID().uuidString, modelo = ""
    var entrada: Double? = nil, saida: Double? = nil, cacheLe: Double? = nil, cache5m: Double? = nil, cache1h: Double? = nil
}
struct CAparencia: Codable, Equatable {
    var ilha = true, todasTelas = false, corAtencao = "#FF9F0A", corCritico = "#FF453A", atalho = false
    var limites: [String: [Int]] = ["cpu": [60, 85], "gpu": [60, 85], "ram": [80, 92], "temp": [85, 95], "disco": [10, 5], "ia": [80, 95]]
}
struct Config: Codable, Equatable {
    var versao = 1, intervalo = 20, lento = 60, usuarioSSH = "", painel = ""
    var maquinas: [CMaquina] = [], servidores: [CServidor] = [], email = CEmail(), ia: [CIA] = [], agentes: [CAgente] = []
    var aparelhos: [String: CAparelho] = [:]  // periféricos renomeados (o campo pode faltar: config antiga)
    var sincronizacao = CSinc(), modulos = CModulos(), aparencia = CAparencia(), demo = false
    var visual = CVisual(), precos: [CPreco] = []

    /// Lê tolerando chave faltando (arquivo de versão velha ou editado à mão): mescla com os padrões antes de decodificar.
    static func ler(_ d: Data) -> Config? {
        guard let arq = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func dic<T: Encodable>(_ v: T) -> [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) as? [String: Any] ?? [:] }
        let elementos = ["maquinas": dic(CMaquina()), "servidores": dic(CServidor()), "ia": dic(CIA()), "agentes": dic(CAgente()), "email.contas": dic(CEmailConta()),
                         "precos": dic(CPreco()), "visual.presets": dic(CEstilo()), "visual.estilo.aneis": dic(CAnel()), "aneis": dic(CAnel())]
        func mesclar(_ p: [String: Any], _ a: [String: Any], _ caminho: String) -> [String: Any] {
            var r = p
            for (k, v) in a {
                let c = caminho.isEmpty ? k : caminho + "." + k
                if let d = v as? [String: Any], let base = p[k] as? [String: Any] { r[k] = mesclar(base, d, c) }
                else if let l = v as? [Any], let e = elementos[c] { r[k] = l.map { ($0 as? [String: Any]).map { mesclar(e, $0, "") } ?? $0 } }
                else { r[k] = v }
            }
            return r
        }
        guard let junto = try? JSONSerialization.data(withJSONObject: mesclar(dic(Config()), arq, "")),
              var c = try? JSONDecoder().decode(Config.self, from: junto) else { return nil }
        // item sem id (ou repetido) ganha um id novo: a seleção das listas dos Ajustes depende disso
        func unicos<T>(_ l: inout [T], _ k: WritableKeyPath<T, String>) {
            var vistos = Set<String>()
            for i in l.indices where l[i][keyPath: k].isEmpty || !vistos.insert(l[i][keyPath: k]).inserted {
                l[i][keyPath: k] = UUID().uuidString; vistos.insert(l[i][keyPath: k])
            }
        }
        unicos(&c.maquinas, \.id); unicos(&c.servidores, \.id); unicos(&c.ia, \.id); unicos(&c.agentes, \.id); unicos(&c.email.contas, \.id)
        unicos(&c.precos, \.id)
        // bloco novo da gaveta (config de versão anterior não tem): entra no fim da ordem, desligado ou não conforme o módulo
        for b in CModulos().ordem where !c.modulos.ordem.contains(b) { c.modulos.ordem.append(b) }
        while c.visual.estilo.aneis.count < 3 { c.visual.estilo.aneis.append(CAnel()) }
        return c
    }
}

/// Dono do config.json. Toda edição nos Ajustes cai aqui; 0,8 s depois de parar de mexer, grava (atômico) e avisa: o
/// coletor reinicia com a config nova e a ilha se remonta se mudou a aparência.
final class ConfigStore: ObservableObject {
    static let nomeApp = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "FleetNotch"
    static let arquivo: URL = {
        if let p = ProcessInfo.processInfo.environment["FROTA_CONFIG"] { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(nomeApp).appendingPathComponent("config.json")
    }()
    static var pasta: URL { arquivo.deletingLastPathComponent() }
    @Published var c = Config()
    @Published private(set) var existe = false
    let salvo = PassthroughSubject<Config, Never>()
    private var gravando: AnyCancellable?

    init() {
        if let d = try? Data(contentsOf: ConfigStore.arquivo), let c = Config.ler(d) { self.c = c; existe = true }
        gravando = $c.dropFirst().removeDuplicates().debounce(for: .seconds(0.8), scheduler: RunLoop.main).sink { [weak self] _ in self?.gravar() }
    }

    func gravar() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let d = try? e.encode(c) else { return }
        try? FileManager.default.createDirectory(at: ConfigStore.pasta, withIntermediateDirectories: true)
        try? d.write(to: ConfigStore.arquivo, options: .atomic)
        existe = true
        salvo.send(c)
    }

    /// Caminho absoluto da foto escolhida pra um agente (fica em <pasta>/fotos/<id>.png).
    static func foto(_ a: CAgente?) -> String? {
        guard let f = a?.foto, !f.isEmpty else { return nil }
        let p = f.hasPrefix("/") ? f : pasta.appendingPathComponent(f).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
}

/// Os scripts Python do app (dentro do .app em Resources). Rodam fora da main thread; a resposta é sempre 1 JSON.
enum Py {
    static func rodar(_ script: String, _ args: [String] = [], entrada: String? = nil, fim: @escaping ([String: Any]) -> Void) {
        let caminho = Bundle.main.path(forResource: script, ofType: "py") ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(), saida = Pipe(), ent = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [caminho] + args
            p.environment = ambiente()
            p.standardOutput = saida
            p.standardError = FileHandle.nullDevice
            p.standardInput = ent
            var d = Data()
            if (try? p.run()) != nil {
                if let e = entrada { ent.fileHandleForWriting.write(Data(e.utf8)) }
                try? ent.fileHandleForWriting.close()
                d = saida.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            }
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            DispatchQueue.main.async { fim(j ?? ["erro": t("sem resposta")]) }
        }
    }
    static func ambiente() -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["FROTA_APP"] = ConfigStore.nomeApp
        e["FROTA_CONFIG"] = ConfigStore.arquivo.path
        e["FROTA_LANG"] = Idioma.shared.codigo  // o Python fala o mesmo idioma da interface (comum.t)
        return e
    }
    /// Segredo pro Keychain: vai pelo stdin do ajustes.py (nunca na linha de comando).
    static func guardar(_ conta: String, _ valor: String, fim: @escaping (Bool) -> Void = { _ in }) {
        rodar("ajustes", ["segredo-guardar", "--conta", conta], entrada: valor) { fim($0["ok"] as? Bool == true) }
    }
}

/// Cor em hexadecimal (#RRGGBB), que é como ela mora no config.json.
extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .orange
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

// MARK: - Estado da janela (seleções, resultados de teste, o que veio do sistema)

final class EstadoAjustes: ObservableObject {
    @Published var aba = "geral"
    @Published var maquina: String?
    @Published var servidor: String?
    @Published var ia: String?
    @Published var agente: String?
    @Published var bloco: String?
    @Published var testes: [String: [String: Any]] = [:]  // id → resposta do "Testar"
    @Published var testando: Set<String> = []
    @Published var nos: [[String: Any]] = []
    @Published var hostsSSH: [[String: Any]] = []
    @Published var fontesIA: [[String: Any]] = []
    @Published var agentesAchados: [[String: Any]] = []
    @Published var contasComposio: [[String: Any]] = []
    @Published var erroComposio: String?
    @Published var temSegredo: [String: Bool] = [:]
    @Published var digitado: [String: String] = [:]  // campos de senha/chave ainda não salvos (nunca vão pro config)

    func testar(_ id: String, _ args: [String], entrada: String? = nil, script: String = "ajustes") {
        testando.insert(id)
        Py.rodar(script, args, entrada: entrada) { [weak self] r in self?.testes[id] = r; self?.testando.remove(id) }
    }
    func conferir(_ conta: String) {
        Py.rodar("ajustes", ["segredo-existe", "--conta", conta]) { [weak self] r in self?.temSegredo[conta] = r["existe"] as? Bool ?? false }
    }
    func carregar() {
        Py.rodar("ajustes", ["descobrir"]) { [weak self] r in self?.nos = r["nos"] as? [[String: Any]] ?? [] }
        Py.rodar("ajustes", ["ssh-hosts"]) { [weak self] r in self?.hostsSSH = r["hosts"] as? [[String: Any]] ?? [] }
        Py.rodar("ajustes", ["ia-fontes"]) { [weak self] r in self?.fontesIA = r["contas"] as? [[String: Any]] ?? [] }
        Py.rodar("ajustes", ["agentes"]) { [weak self] r in self?.agentesAchados = r["agentes"] as? [[String: Any]] ?? [] }
        for c in ["composio", "anthropic", "openai"] { conferir(c) }
    }
    func buscarComposio() {
        erroComposio = nil
        Py.rodar("ajustes", ["email-contas"]) { [weak self] r in
            self?.contasComposio = r["contas"] as? [[String: Any]] ?? []
            self?.erroComposio = r["erro"] as? String
        }
    }
}

// MARK: - A janela

struct AjustesView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var a: EstadoAjustes
    let assistente: () -> Void
    let modelo: Modelo
    var body: some View {
        TabView(selection: $a.aba) {
            AbaGeral(store: store, a: a, assistente: assistente).tabItem { Label(t("Geral"), systemImage: "gearshape") }.tag("geral")
            AbaAparencia(store: store).tabItem { Label(t("Aparência"), systemImage: "paintpalette") }.tag("aparencia")
            AbaMacs(store: store, a: a, modelo: modelo).tabItem { Label(t("Macs"), systemImage: "desktopcomputer") }.tag("macs")
            AbaServidores(store: store, a: a).tabItem { Label(t("Servidores"), systemImage: "server.rack") }.tag("servidores")
            AbaEmail(store: store, a: a).tabItem { Label(t("E-mail"), systemImage: "envelope") }.tag("email")
            AbaIA(store: store, a: a).tabItem { Label(t("IA"), systemImage: "sparkles") }.tag("ia")
            AbaAgentes(store: store, a: a).tabItem { Label(t("Agentes"), systemImage: "person.2.wave.2") }.tag("agentes")
            AbaCopiados(store: store, copiados: modelo.copiados).tabItem { Label(t("Copiados"), systemImage: "doc.on.clipboard") }.tag("copiados")
        }
        .frame(width: 780, height: 580)
        .onAppear {
            a.carregar()
            NSApp.activate(ignoringOtherApps: true)  // app de barra: sem isso a janela abre atrás do app da frente
        }
    }
}

/// Rótulos dos blocos da gaveta (a ordem mora em modulos.ordem).
var nomesBlocos: [String: String] {
    ["topo": t("Agentes e contas de IA"), "macs": t("Macs (mostrador e conectados)"), "servidores": t("Servidores"),
     "email": t("E-mail"), "orca": "Orca", "sincronizacao": t("Sincronização"), "pergunta": t("Pergunta rápida"), "copiados": t("Copiados (⌘C)")]
}

struct AbaGeral: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var a: EstadoAjustes
    let assistente: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section {
                    SeletorIdioma()
                } footer: {
                    Text(t("Também dá pra escolher em Ajustes do Sistema › Geral › Idioma e Região › Aplicativos.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(t("Módulos")) {
                    Toggle(t("Macs"), isOn: $store.c.modulos.macs)
                    Toggle(t("Servidores (VPS)"), isOn: $store.c.modulos.servidores)
                    Toggle(t("E-mail"), isOn: $store.c.modulos.email)
                    Toggle(t("Contas de IA"), isOn: $store.c.modulos.ia)
                    Toggle(t("Agentes"), isOn: $store.c.modulos.agentes)
                    Toggle(t("Sincronização"), isOn: $store.c.modulos.sincronizacao)
                    Toggle("Orca", isOn: $store.c.modulos.orca)
                    Toggle(t("Pergunta rápida"), isOn: $store.c.modulos.pergunta)
                    Toggle(t("Ações nos Macs"), isOn: $store.c.modulos.acoes)
                    Toggle(t("Copiados (histórico do ⌘C)"), isOn: $store.c.modulos.copiados)
                }
                Section(t("Coleta")) {
                    Picker(t("Atualizar a cada"), selection: $store.c.intervalo) {
                        ForEach([10, 20, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                    }
                    TextField(t("Painel externo (opcional)"), text: $store.c.painel, prompt: Text(verbatim: "http://…"))
                    Toggle(t("Dados de demonstração"), isOn: $store.c.demo)
                }
                Section(t("Atalho")) {
                    OpcoesAtalho(ligado: $store.c.aparencia.atalho, v: $store.c.visual)
                }
                Section {
                    Button(t("Abrir o assistente de configuração…"), action: assistente)
                    Text(store.c.demo ? t("Config: dados de demonstração") : t("Config: {0}", ConfigStore.arquivo.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.formStyle(.grouped).frame(width: 380)
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Ordem na gaveta")).font(.headline)
                Text(t("Arraste pra reordenar. E-mail, Orca e Sincronização vizinhos dividem a mesma linha.")).font(.caption).foregroundStyle(.secondary)
                List(selection: $a.bloco) {
                    ForEach(store.c.modulos.ordem, id: \.self) { b in
                        Label(nomesBlocos[b] ?? b, systemImage: "line.3.horizontal").tag(b)
                    }.onMove { store.c.modulos.ordem.move(fromOffsets: $0, toOffset: $1) }
                }.listStyle(.bordered(alternatesRowBackgrounds: true))
            }.padding(20)
        }
    }
}

struct AbaAparencia: View {
    @ObservedObject var store: ConfigStore
    @AppStorage("barraTexto") private var barraTexto = "auto"
    var body: some View {
        Form {
            Section(t("Modo")) {
                SeletorModo(modo: $store.c.visual.modo, estilo: store.c.visual.estilo)
            }
            Section {
                GaleriaPresets(v: $store.c.visual, colunas: 8)
                EditorAneis(v: $store.c.visual)
            } header: { Text(t("Estilo dos anéis")) } footer: {
                Text(t("Âmbar e vermelho continuam valendo por cima de qualquer estilo: o que pede atenção nunca se perde na cor."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Do seu jeito")) {
                OpcoesVisuais(v: $store.c.visual)
            }
            Section {
                Picker(t("Na barra de menus"), selection: $barraTexto) {
                    Text(t("Automático")).tag("auto")
                    Text(t("Ícone e o Mac mais exigido")).tag("texto")
                    Text(t("Só o ícone")).tag("icone")
                }
            } footer: {
                Text(t("No automático, Mac com notch mostra só o ícone: o que não cabe à direita do notch o macOS esconde. Os Ajustes também abrem com o botão direito no notch."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Ilha")) {
                Toggle(t("Mostrar a ilha no topo da tela"), isOn: $store.c.aparencia.ilha)
                Picker(t("Telas"), selection: $store.c.aparencia.todasTelas) {
                    Text(t("Só a principal")).tag(false)
                    Text(t("Todas as telas")).tag(true)
                }.pickerStyle(.segmented)
            }
            Section(t("Cores de alerta")) {
                ColorPicker(t("Atenção"), selection: Binding(get: { Color(hex: store.c.aparencia.corAtencao) }, set: { store.c.aparencia.corAtencao = $0.hex }),
                            supportsOpacity: false)
                ColorPicker(t("Crítico"), selection: Binding(get: { Color(hex: store.c.aparencia.corCritico) }, set: { store.c.aparencia.corCritico = $0.hex }),
                            supportsOpacity: false)
                Button(t("Restaurar as cores da Apple")) { store.c.aparencia.corAtencao = "#FF9F0A"; store.c.aparencia.corCritico = "#FF453A" }
            }
            Section(t("Limites de alerta")) {
                limite(t("CPU acima de"), "cpu", "%")
                limite(t("GPU acima de"), "gpu", "%")
                limite(t("RAM acima de"), "ram", "%")
                limite(t("Temperatura acima de"), "temp", " °C")
                limite(t("Disco com menos de"), "disco", t("% livre"))
                limite(t("Conta de IA acima de"), "ia", "%")
            }
            Section {
                Button(t("Voltar tudo da aparência ao padrão")) {
                    let v = store.c.visual
                    store.c.visual = CVisual(presets: v.presets, copiados: v.copiados)  // os estilos salvos e o histórico ficam
                    store.c.aparencia.corAtencao = "#FF9F0A"; store.c.aparencia.corCritico = "#FF453A"
                }
            } footer: {
                Text(t("Modo Full, estilo Clássico, destaque, densidade, anéis, números, notch, som e atalho voltam ao que vem de fábrica. Os estilos que você salvou ficam."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    func limite(_ titulo: String, _ k: String, _ un: String) -> some View {
        let par = Binding<[Int]>(get: { store.c.aparencia.limites[k] ?? [0, 0] }, set: { store.c.aparencia.limites[k] = $0 })
        return LabeledContent(titulo) {
            HStack(spacing: 14) {
                Stepper(value: Binding(get: { par.wrappedValue[0] }, set: { par.wrappedValue = [$0, par.wrappedValue[1]] }), in: 1...100) {
                    Text(t("atenção {0}{1}", par.wrappedValue[0], un)).monospacedDigit()
                }
                Stepper(value: Binding(get: { par.wrappedValue[1] }, set: { par.wrappedValue = [par.wrappedValue[0], $0] }), in: 1...100) {
                    Text(t("crítico {0}{1}", par.wrappedValue[1], un)).monospacedDigit()
                }
            }
        }
    }
}

/// Lista à esquerda (arrastar reordena; + e − embaixo, como nos Ajustes do Sistema) e o formulário do item à direita.
struct ListaDetalhe<Item: Identifiable & Equatable, Linha: View, Detalhe: View, Mais: View>: View where Item.ID == String {
    @Binding var itens: [Item]
    @Binding var selecao: String?
    let novo: () -> Item
    @ViewBuilder let linha: (Item) -> Linha
    @ViewBuilder let detalhe: (Binding<Item>) -> Detalhe
    @ViewBuilder let mais: () -> Mais
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selecao) {
                    ForEach(itens) { i in linha(i).tag(i.id) }.onMove { itens.move(fromOffsets: $0, toOffset: $1) }
                }.listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 0) {
                    Button { let n = novo(); itens.append(n); selecao = n.id } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button {
                        guard let s = selecao, let i = itens.firstIndex(where: { $0.id == s }) else { return }
                        itens.remove(at: i); selecao = itens.isEmpty ? nil : itens[max(0, i - 1)].id
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }.disabled(selecao == nil)
                    mais()
                    Spacer()
                }.buttonStyle(.borderless).padding(4)
            }.frame(width: 230).padding([.leading, .vertical], 16)
            Group {
                if let s = selecao, let i = itens.firstIndex(where: { $0.id == s }) {
                    detalhe($itens[i]).id(s)
                } else {
                    Text(itens.isEmpty ? t("Nada aqui ainda. Use + pra adicionar.") : t("Escolha um item à esquerda."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Resultado do "Testar": ok (verde) com o resumo, ou o erro e a dica do que fazer.
struct ResultadoTeste: View {
    let r: [String: Any]?, rodando: Bool
    var body: some View {
        if rodando {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(t("Testando…")).foregroundStyle(.secondary) }
        } else if let r = r {
            if r["ok"] as? Bool == true {
                Label((r["resumo"] as? String) ?? t("Conectou"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Label((r["erro"] as? String) ?? t("Não conectou"), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    if let d = r["dica"] as? String { Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }
}

struct AbaMacs: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var a: EstadoAjustes
    @ObservedObject var modelo: Modelo  // os periféricos de agora (o que a gaveta mostra)
    var body: some View {
        ListaDetalhe(itens: $store.c.maquinas, selecao: $a.maquina, novo: { CMaquina(nome: t("Novo Mac")) }, linha: { m in
            HStack(spacing: 8) {
                IconeDispositivo(valor: m.icone.isEmpty ? (m.modelo.isEmpty ? "com.apple.mac" : m.modelo) : m.icone, tamanho: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.nome.isEmpty ? t("Sem nome") : m.nome)
                    Text(m.host).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !m.visivel { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
            }
        }, detalhe: { $m in
            Form {
                Section {
                    TextField(t("Nome"), text: $m.nome)
                    TextField(t("Nome curto (barra de menus)"), text: $m.curto, prompt: Text(m.nome))
                    TextField(t("Host"), text: $m.host, prompt: Text(t("nome na Tailscale, IP ou \"local\"")))
                    TextField(t("Usuário SSH"), text: $m.usuario, prompt: Text(store.c.usuarioSSH.isEmpty ? t("o mesmo deste Mac") : store.c.usuarioSSH))
                    LinhaIcone(valor: $m.icone, padrao: m.modelo.isEmpty ? "com.apple.mac" : m.modelo)
                    Toggle(t("Mostrar na ilha"), isOn: $m.visivel)
                    Button(t("Voltar ao padrão (nome do host, ícone pelo modelo)")) { m.nome = m.host; m.curto = ""; m.icone = "" }
                        .disabled(m.nome == m.host && m.curto.isEmpty && m.icone.isEmpty)
                }
                SecaoPerifericos(store: store, q: modelo.estado.maquinas.first { $0.id == m.id || ($0.ts != nil && $0.ts == m.host) })
                Section {
                    HStack {
                        Button(t("Testar conexão")) {
                            a.testar(m.id, ["testar", "--host", m.host] + (m.usuario.isEmpty ? [] : ["--usuario", m.usuario]))
                        }.disabled(m.host.isEmpty)
                        Button(t("Instalar chave SSH…")) {
                            Py.rodar("ajustes", ["instalar-chave", "--host", m.host] + (m.usuario.isEmpty ? [] : ["--usuario", m.usuario])) { _ in }
                        }.disabled(m.host.isEmpty || ["local", "localhost"].contains(m.host))
                    }
                    ResultadoTeste(r: a.testes[m.id], rodando: a.testando.contains(m.id))
                        .onChange(of: a.testes[m.id]?["modelo"] as? String) { _, novo in if let n = novo { m.modelo = n } }
                } footer: {
                    Text(t("Os outros Macs são lidos por SSH, com chave (sem senha) e sem instalar nada neles. No Mac de destino: Ajustes do Sistema › Geral › Compartilhamento › Login Remoto."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }, mais: {
            Menu {
                let ja = Set(store.c.maquinas.map(\.host))
                ForEach(Array(a.nos.enumerated()), id: \.offset) { _, n in
                    let host = n["host"] as? String ?? ""
                    if (n["os"] as? String) == "macOS" && !ja.contains(host) && !(n["este"] as? Bool == true && ja.contains("local")) {
                        Button(n["este"] as? Bool == true ? t("{0} (este Mac)", host) : host) {
                            let novo = CMaquina(nome: host, curto: String(host.prefix(10)), host: host)
                            store.c.maquinas.append(novo); a.maquina = novo.id
                        }
                    }
                }
                if a.nos.isEmpty { Text(t("Nada na Tailscale")) }
            } label: { Image(systemName: "dot.radiowaves.left.and.right") }.menuIndicator(.hidden).fixedSize().help(t("Adicionar da Tailscale"))
        })
    }
}

struct AbaServidores: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var a: EstadoAjustes
    var body: some View {
        ListaDetalhe(itens: $store.c.servidores, selecao: $a.servidor, novo: { CServidor(nome: t("novo-servidor")) }, linha: { s in
            HStack(spacing: 8) {
                IconeDispositivo(valor: s.icone.isEmpty ? "sf:server.rack" : s.icone, tamanho: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.nome.isEmpty ? s.host : s.nome)
                    Text(s.host).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !s.visivel { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
            }
        }, detalhe: { $s in
            Form {
                Section {
                    TextField(t("Nome"), text: $s.nome)
                    TextField(t("Host"), text: $s.host, prompt: Text(t("IP, nome ou apelido do ~/.ssh/config")))
                    TextField(t("Usuário SSH"), text: $s.usuario, prompt: Text(t("o do ~/.ssh/config")))
                    TextField(t("Porta"), value: $s.porta, format: .number.grouping(.never))
                    TextField(t("Serviços (systemd)"), text: Binding(get: { s.servicos.joined(separator: ", ") },
                                                                set: { s.servicos = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                              prompt: Text(verbatim: "nginx, postgresql, docker"))
                    Toggle(t("Containers Docker"), isOn: $s.docker)
                    LinhaIcone(valor: $s.icone, padrao: "sf:server.rack")
                    Toggle(t("Mostrar na ilha"), isOn: $s.visivel)
                    Button(t("Voltar ao padrão (nome do host, ícone de servidor)")) { s.nome = s.host; s.icone = "" }
                        .disabled(s.nome == s.host && s.icone.isEmpty)
                }
                Section {
                    Button(t("Testar conexão")) {
                        a.testar(s.id, ["testar", "--host", s.host, "--linux", "--porta", "\(s.porta)", "--servicos", s.servicos.joined(separator: ",")]
                                 + (s.usuario.isEmpty ? [] : ["--usuario", s.usuario]) + (s.docker ? ["--docker"] : []))
                    }.disabled(s.host.isEmpty)
                    ResultadoTeste(r: a.testes[s.id], rodando: a.testando.contains(s.id))
                } footer: {
                    Text(t("Só leitura, sem sudo e sem instalar nada: CPU, memória, disco, carga, tempo ligado, os serviços que você escolher e os containers."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }, mais: {
            Menu {
                ForEach(Array(a.hostsSSH.enumerated()), id: \.offset) { _, h in
                    let ap = h["apelido"] as? String ?? ""
                    Button(ap) {
                        let novo = CServidor(nome: ap, host: ap, porta: Int(h["porta"] as? String ?? "") ?? 22)
                        store.c.servidores.append(novo); a.servidor = novo.id
                    }
                }
                if a.hostsSSH.isEmpty { Text(t("Nada no ~/.ssh/config")) }
            } label: { Image(systemName: "doc.text") }.menuIndicator(.hidden).fixedSize().help(t("Adicionar do ~/.ssh/config"))
        })
    }
}

struct AbaEmail: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var a: EstadoAjustes
    var body: some View {
        let comp = store.c.email.contas.filter { $0.provedor == "composio" }.count
        let chamadas = comp * 30 * 24 * 60 / max(store.c.email.intervalo, 1)
        Form {
            Section {
                CampoSegredo(conta: "composio", titulo: t("Chave da API"), dica: t("uak_… ou ak_…"), a: a)
                HStack {
                    Button(t("Importar do Composio CLI")) { Py.rodar("ajustes", ["composio-importar"]) { _ in a.conferir("composio"); a.buscarComposio() } }
                    Button(t("Buscar contas")) { a.buscarComposio() }.disabled(a.temSegredo["composio"] != true)
                }
                if let e = a.erroComposio { Text(e).foregroundStyle(.red) }
                ForEach(Array(a.contasComposio.enumerated()), id: \.offset) { _, x in
                    let id = x["id"] as? String ?? "", apelido = x["apelido"] as? String ?? id, ativa = x["status"] as? String == "ACTIVE"
                    Toggle(isOn: Binding(get: { store.c.email.contas.contains { $0.conta == id } }, set: { liga in
                        if liga { store.c.email.contas.append(CEmailConta(nome: apelido.components(separatedBy: "@").first ?? apelido, conta: id, endereco: apelido.contains("@") ? apelido : "")) }
                        else { store.c.email.contas.removeAll { $0.conta == id } }
                    })) {
                        HStack {
                            Image(systemName: (x["app"] as? String) == "outlook" ? "envelope.badge" : "envelope")
                            Text(apelido)
                            if !ativa { Text((x["status"] as? String ?? "").lowercased()).font(.caption).foregroundStyle(.orange) }
                        }
                    }.disabled(!ativa && !store.c.email.contas.contains { $0.conta == id })
                }
                Picker(t("Contar não lidos a cada"), selection: $store.c.email.intervalo) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { Text($0 < 60 ? "\($0) min" : "\($0 / 60) h").tag($0) }
                }
            } header: { Text("Composio") } footer: {
                Text(comp == 1 ? t("Só leitura: quantos não lidos e o último cabeçalho (de, assunto, hora), nunca o corpo. ≈ {0} chamadas de ferramenta por mês ({1} conta); o status das contas é de graça e o cabeçalho só é buscado quando você abre a página de e-mail. No plano grátis do Composio: 10 mil execuções/mês.", chamadas, comp)
                                : t("Só leitura: quantos não lidos e o último cabeçalho (de, assunto, hora), nunca o corpo. ≈ {0} chamadas de ferramenta por mês ({1} contas); o status das contas é de graça e o cabeçalho só é buscado quando você abre a página de e-mail. No plano grátis do Composio: 10 mil execuções/mês.", chamadas, comp))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($store.c.email.contas) { $c in
                    if c.provedor == "imap" {
                        VStack(alignment: .leading) {
                            TextField(t("Nome"), text: $c.nome)
                            TextField(t("Servidor IMAP"), text: $c.servidor, prompt: Text(verbatim: "imap.gmail.com"))
                            TextField(t("Usuário"), text: $c.usuario, prompt: Text(t("voce@exemplo.com")))
                            CampoSegredo(conta: "imap:\(c.usuario)@\(c.servidor)", titulo: t("Senha de app"), dica: t("a senha de app, não a da conta"), a: a)
                            Button(t("Remover esta conta"), role: .destructive) { store.c.email.contas.removeAll { $0.id == c.id } }
                        }
                    } else if !a.contasComposio.contains(where: { $0["id"] as? String == c.conta }) {
                        HStack { TextField(t("Nome"), text: $c.nome); Text(c.endereco).foregroundStyle(.secondary); Toggle("", isOn: $c.visivel).labelsHidden() }
                    }
                }
                Button(t("Adicionar conta IMAP")) { store.c.email.contas.append(CEmailConta(nome: "IMAP", provedor: "imap", servidor: "imap.gmail.com", porta: 993)) }
            } header: { Text(t("Contas")) } footer: {
                Text(t("IMAP é de graça e não passa pelo Composio: a caixa abre só pra leitura e só os campos do cabeçalho são pedidos.")).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear { if a.temSegredo["composio"] == true { a.buscarComposio() } }
    }
}

/// Campo de senha/chave: o que se digita vai direto pro Keychain (nunca pro config.json); mostra se já existe.
struct CampoSegredo: View {
    let conta: String, titulo: String, dica: String
    @ObservedObject var a: EstadoAjustes
    var body: some View {
        LabeledContent(titulo) {
            HStack {
                SecureField(dica, text: Binding(get: { a.digitado[conta] ?? "" }, set: { a.digitado[conta] = $0 })).frame(minWidth: 160)
                Button(t("Salvar")) {
                    let v = a.digitado[conta] ?? ""
                    Py.guardar(conta, v) { _ in a.digitado[conta] = nil; a.conferir(conta) }
                }.disabled((a.digitado[conta] ?? "").isEmpty)
                if a.temSegredo[conta] == true {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help(t("Guardada no Keychain"))
                    Button(t("Remover")) { Py.rodar("ajustes", ["segredo-apagar", "--conta", conta]) { _ in a.conferir(conta) } }
                }
            }
        }.onAppear { if a.temSegredo[conta] == nil { a.conferir(conta) } }
    }
}

struct AbaIA: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var a: EstadoAjustes
    @StateObject private var precos = Local(false)
    var body: some View {
        ListaDetalhe(itens: $store.c.ia, selecao: $a.ia, novo: { CIA(nome: t("Nova conta")) }, linha: { c in
            HStack(spacing: 8) {
                LogoApp(caminhos: c.app, ferramenta: c.ferramenta, tamanho: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.nome.isEmpty ? c.ferramenta : c.nome)
                    Text(c.ferramenta).font(.caption).foregroundStyle(.secondary)
                }
            }
        }, detalhe: { $c in
            Form {
                Section {
                    TextField(t("Nome"), text: $c.nome)
                    TextField(t("Ferramenta"), text: $c.ferramenta, prompt: Text(verbatim: "Claude, ChatGPT, Gemini…"))
                    Picker(t("De onde vem o uso"), selection: $c.fonte) {
                        Text(verbatim: "Claude Code").tag("claude-perfil")
                        Text(t("Codex (sessões)")).tag("codex-sessoes")
                        Text(t("Sem fonte (só o logo)")).tag("")
                    }
                    if c.fonte == "claude-perfil" {
                        Picker(t("Perfil"), selection: $c.perfil) {
                            Text(verbatim: "~/.claude").tag("")  // statusline.py, sem Orca
                            ForEach(Array(a.fontesIA.enumerated()), id: \.offset) { _, f in
                                if let p = f["perfil"] as? String, !p.isEmpty { Text(p).tag(p) }
                            }
                        }
                    }
                    TextField(t("App do logo"), text: Binding(get: { c.app.joined(separator: ", ") },
                                                         set: { c.app = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }),
                              prompt: Text(verbatim: "/Applications/Claude.app"))
                    Toggle(t("Mostrar na ilha"), isOn: $c.visivel)
                } header: { Text(t("Conta")) } footer: {
                    Text(t("Na gaveta, clique no anel da conta pra ver o uso de hoje, da semana e do mês, modelo por modelo, com o custo estimado."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker(t("Responder com"), selection: $c.perguntar) {
                        Text(t("Não usar")).tag("")
                        Text(t("Claude Code (CLI já logado)")).tag("claude-cli")
                        Text(t("Codex (CLI já logado)")).tag("codex-cli")
                        Text(t("API da Anthropic (chave)")).tag("anthropic-api")
                        Text(t("API da OpenAI (chave)")).tag("openai-api")
                    }
                    TextField(t("Modelo"), text: $c.modelo, prompt: Text(c.perguntar == "claude-cli" ? "haiku" : t("padrão")))
                    if c.perguntar == "anthropic-api" { CampoSegredo(conta: "anthropic", titulo: t("Chave da Anthropic"), dica: "sk-ant-…", a: a) }
                    if c.perguntar == "openai-api" { CampoSegredo(conta: "openai", titulo: t("Chave da OpenAI"), dica: "sk-…", a: a) }
                } header: { Text(t("Pergunta rápida")) } footer: {
                    Text(t("Roda numa pasta temporária vazia, sem nenhuma ferramenta (nem arquivo, nem terminal, nem web), com tempo-limite. Nenhum arquivo do Mac vai junto. Gasta da cota desta conta (o anel mostra)."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }, mais: {
            Menu {
                ForEach(Array(a.fontesIA.enumerated()), id: \.offset) { _, f in
                    Button(f["nome"] as? String ?? "") {
                        let n = CIA(nome: f["nome"] as? String ?? "", ferramenta: f["ferramenta"] as? String ?? "", fonte: f["fonte"] as? String ?? "",
                                    perfil: f["perfil"] as? String ?? "", app: f["app"] as? [String] ?? [], perguntar: f["perguntar"] as? String ?? "")
                        store.c.ia.append(n); a.ia = n.id
                    }
                }
                if a.fontesIA.isEmpty { Text(t("Nada achado neste Mac")) }
            } label: { Image(systemName: "wand.and.stars") }.menuIndicator(.hidden).fixedSize().help(t("Adicionar o que foi achado neste Mac"))
            Button(t("Preços…")) { precos.v = true }.help(t("Preços por modelo"))
        })
        .sheet(isPresented: $precos.v) { TabelaPrecos(store: store) { precos.v = false } }
    }
}

/// Logo de uma ferramenta: o ícone do app instalado; sem app, o monograma.
struct LogoApp: View {
    let caminhos: [String], ferramenta: String, tamanho: CGFloat
    var body: some View {
        if let p = caminhos.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: tamanho, height: tamanho)
        } else {
            Monograma(nome: ferramenta, tamanho: tamanho)
        }
    }
}

/// Iniciais num círculo cinza com degradê, como os contatos da Apple (agente sem foto, conta sem app).
struct Monograma: View {
    let nome: String, tamanho: CGFloat
    var body: some View {
        let ini = nome.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.44)], startPoint: .top, endPoint: .bottom))
            Text(ini.isEmpty ? "?" : ini).font(.system(size: tamanho * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }.frame(width: tamanho, height: tamanho)
    }
}

/// Foto do agente: a que o usuário escolheu; senão a do próprio agente (ex.: assets/avatar.png do Hermes); senão o monograma.
struct FotoAgente: View {
    let caminho: String?, nome: String, tamanho: CGFloat
    var body: some View {
        if let c = caminho, let i = avatares[c] ?? NSImage(contentsOfFile: c).map({ avatares[c] = $0; return $0 }) {
            Image(nsImage: i).resizable().interpolation(.high).scaledToFill().frame(width: tamanho, height: tamanho).clipShape(Circle())
        } else {
            Monograma(nome: nome, tamanho: tamanho)
        }
    }
}

/// Guarda a foto escolhida: recorte quadrado do centro, 256 × 256, PNG em <pasta do config>/fotos/<id>.png.
func guardarFoto(_ url: URL, id: String, pasta: String = "fotos") -> String? {
    guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let lado = min(cg.width, cg.height)
    guard let quadrado = cg.cropping(to: CGRect(x: (cg.width - lado) / 2, y: (cg.height - lado) / 2, width: lado, height: lado)) else { return nil }
    let alvo = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: alvo)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: quadrado, size: .init(width: lado, height: lado)).draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
    NSGraphicsContext.restoreGraphicsState()
    let rel = "\(pasta)/\(id).png", destino = ConfigStore.pasta.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard (try? alvo.representation(using: .png, properties: [:])?.write(to: destino)) != nil else { return nil }
    avatares[destino.path] = nil
    return rel
}

private struct CamposSites: View {
    @Binding var agente: CAgente
    @State private var linhas: String
    @State private var projetos: String

    init(agente: Binding<CAgente>) {
        _agente = agente
        let g = agente.wrappedValue
        _linhas = State(initialValue: g.sites.map { "\($0.nome) | \($0.url)" }.joined(separator: "\n"))
        _projetos = State(initialValue: g.vercelProjetos.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
    }

    var body: some View {
        TextField(t("Sites (um por linha)"), text: $linhas, prompt: Text(verbatim: "Nome | https://example.com"), axis: .vertical)
            .onChange(of: linhas) { _, texto in
                agente.sites = texto.split(separator: "\n").compactMap { linha in
                    let par = linha.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard par.count == 2, !par[0].isEmpty, let url = URLComponents(string: par[1]),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !(url.host ?? "").isEmpty
                    else { return nil }
                    return CSite(nome: par[0], url: par[1])
                }
            }
        TextField(t("Projetos da Vercel"), text: $projetos, prompt: Text(verbatim: "Nome=prj_…"))
            .onChange(of: projetos) { _, texto in
                var mapa: [String: String] = [:]
                for entrada in texto.split(separator: ",") {
                    let par = entrada.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if par.count == 2, !par[0].isEmpty, !par[1].isEmpty { mapa[par[0]] = par[1] }
                }
                agente.vercelProjetos = mapa
            }
    }
}

struct AbaAgentes: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var a: EstadoAjustes
    var body: some View {
        ListaDetalhe(itens: $store.c.agentes, selecao: $a.agente, novo: { CAgente(nome: t("Novo agente"), tipo: "generico") }, linha: { g in
            HStack(spacing: 8) {
                FotoAgente(caminho: ConfigStore.foto(g), nome: g.nome, tamanho: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(g.nome.isEmpty ? t("Sem nome") : g.nome)
                    Text(["hermes": "Hermes", "openclaw": "OpenClaw", "generico": t("Genérico"),
                          "sites": t("Sites"), "metaads": "Meta Ads", "git": "Git", "foco": t("Foco")][g.tipo] ?? g.tipo).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !g.visivel { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
            }
        }, detalhe: { $g in
            Form {
                Section {
                    HStack(spacing: 14) {
                        FotoAgente(caminho: ConfigStore.foto(g), nome: g.nome, tamanho: 56)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.3)))
                            .onDrop(of: [.fileURL], isTargeted: nil) { prov in
                                _ = prov.first?.loadObject(ofClass: URL.self) { u, _ in
                                    if let u = u { DispatchQueue.main.async { if let f = guardarFoto(u, id: g.id) { g.foto = f } } }
                                }
                                return true
                            }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t("Arraste uma imagem pra foto, ou:")).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(t("Escolher…")) {
                                    let p = NSOpenPanel()
                                    p.allowedContentTypes = [.image]
                                    if p.runModal() == .OK, let u = p.url, let f = guardarFoto(u, id: g.id) { g.foto = f }
                                }
                                if !g.foto.isEmpty { Button(t("Remover")) { g.foto = "" } }
                            }
                        }
                    }
                    TextField(t("Nome"), text: $g.nome)
                    Picker(t("Tipo"), selection: $g.tipo) {
                        Text("Hermes").tag("hermes"); Text("OpenClaw").tag("openclaw"); Text(t("Genérico")).tag("generico")
                        Text(t("Sites")).tag("sites")
                        Text(verbatim: "Meta Ads").tag("metaads")
                        Text(verbatim: "Git").tag("git")
                        Text(t("Foco")).tag("foco")
                    }
                    Toggle(t("Mostrar na ilha"), isOn: $g.visivel)
                }
                Section(t("De onde ler o status")) {
                    switch g.tipo {
                    case "hermes":
                        TextField(t("Pasta do Hermes"), text: $g.home, prompt: Text(verbatim: "~/.hermes"))
                        Picker(t("Perfil"), selection: $g.perfil) {
                            Text(t("Principal")).tag("")
                            ForEach(Array(a.agentesAchados.enumerated()), id: \.offset) { _, x in
                                if let p = x["perfil"] as? String, !p.isEmpty { Text(p).tag(p) }
                            }
                            if !g.perfil.isEmpty && !a.agentesAchados.contains(where: { $0["perfil"] as? String == g.perfil }) { Text(g.perfil).tag(g.perfil) }
                        }
                        TextField(t("LaunchAgents"), text: $g.rotulo, prompt: Text(verbatim: "ai.hermes."))
                    case "openclaw":
                        TextField(t("Porta do gateway"), value: $g.porta, format: .number.grouping(.never), prompt: Text("18789"))
                        TextField("LaunchAgent", text: $g.rotulo, prompt: Text(verbatim: "ai.openclaw.gateway"))
                        TextField(t("Pasta de estado"), text: $g.home, prompt: Text(verbatim: "~/.openclaw"))
                        TextField(t("Log"), text: $g.log, prompt: Text(verbatim: "~/Library/Logs/openclaw/gateway.log"))
                    case "sites":
                        CamposSites(agente: $g).id(g.id)
                        CampoSegredo(conta: "vercel", titulo: t("Token da Vercel"), dica: t("token da conta"), a: a)
                    case "metaads":
                        TextField(t("Conta"), text: $g.conta, prompt: Text(verbatim: "act_123456789"))
                        TextField(t("Versão da API"), text: $g.versao, prompt: Text(verbatim: "v21.0"))
                        TextField(t("Custo por conversa máximo"), value: $g.cplMax, format: .number)
                        if !g.conta.isEmpty {
                            CampoSegredo(conta: "meta:\(g.conta)", titulo: t("Token da Meta"), dica: t("token da conta"), a: a)
                                .id(g.conta)
                        }
                    case "git":
                        TextField(t("Pasta dos repositórios"), text: $g.pasta, prompt: Text(verbatim: "~/Desktop/projects"))
                        TextField(t("Dias"), value: $g.dias, format: .number)
                    case "foco":
                        TextField(t("Arquivo de foco"), text: $g.arquivo, prompt: Text(verbatim: "~/Documents/Vault/foco-da-semana.md"))
                    default:
                        TextField(t("URL de health"), text: $g.url, prompt: Text(verbatim: "http://127.0.0.1:8080/health"))
                        TextField("LaunchAgent", text: $g.rotulo, prompt: Text(t("com.exemplo.agente")))
                        TextField(t("Log"), text: $g.log, prompt: Text(t("~/Library/Logs/agente.log")))
                    }
                }
                if !["sites", "metaads", "git", "foco"].contains(g.tipo) {
                    Section {
                        TextField(t("URL da UAZAPI"), text: $g.uazapiURL, prompt: Text(t("https://suaconta.uazapi.com")))
                        TextField(t("Instâncias"), text: Binding(get: { g.instancias.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") },
                                                              set: { t in g.instancias = Dictionary(t.split(separator: ",").compactMap { par -> (String, String)? in
                                                                  let p = par.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                                                                  return p.count == 2 && !p[0].isEmpty ? (p[0], p[1]) : nil
                                                              }, uniquingKeysWith: { $1 }) }),
                                  prompt: Text(t("nome-da-instancia=Rótulo, …")))
                        if let host = URL(string: g.uazapiURL)?.host, !host.isEmpty {
                            CampoSegredo(conta: "uazapi:\(host)", titulo: "Admintoken", dica: t("token da conta"), a: a)
                        }
                    } header: { Text(t("WhatsApp na UAZAPI (opcional)")) } footer: {
                        Text(t("Só leitura: o app vê se o agente está no ar, os canais e o último erro. Nunca reinicia nem manda mensagem.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(t("Testar")) {
                        let d = (try? JSONEncoder().encode(g)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        a.testar(g.id, ["agente-testar"], entrada: d)
                    }
                    if let r = a.testes[g.id] {
                        let ok = (r["nivel"] as? Int ?? -1) == 0
                        Label("\(r["estado"] as? String ?? "?")" + (((r["canais"] as? [[String: Any]]) ?? []).map { " · \($0["nome"] as? String ?? "") \($0["estado"] as? String ?? "")" }.joined()),
                              systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Color.green : Color.orange)
                    } else if a.testando.contains(g.id) { ProgressView().controlSize(.small) }
                }
            }.formStyle(.grouped)
        }, mais: {
            Menu {
                Section("Hermes") {
                    ForEach(Array(a.agentesAchados.enumerated()), id: \.offset) { _, x in
                        if x["tipo"] as? String == "hermes" {
                            Button(x["nome"] as? String ?? "") { adicionar(x) }
                        }
                    }
                }
                Button("OpenClaw") { adicionar(["nome": "OpenClaw", "tipo": "openclaw", "porta": 18789]) }
                Button(t("Genérico (URL de health)")) { adicionar(["nome": t("Agente"), "tipo": "generico"]) }
            } label: { Image(systemName: "wand.and.stars") }.menuIndicator(.hidden).fixedSize().help(t("Adicionar agente achado neste Mac"))
        })
    }

    func adicionar(_ x: [String: Any]) {
        let n = CAgente(nome: x["nome"] as? String ?? t("Agente"), tipo: x["tipo"] as? String ?? "generico", home: x["home"] as? String ?? "",
                        perfil: x["perfil"] as? String ?? "", porta: x["porta"] as? Int ?? 0)
        store.c.agentes.append(n)
        a.agente = n.id
    }
}

// MARK: - Nomes e ícones dos aparelhos (Macs, servidores, periféricos): ficam só na config, o hostname não muda

/// Valor do ícone na config: "" = padrão; UTType de aparelho da Apple ("com.apple.macmini", o desenho do AirDrop);
/// "sf:<SF Symbol>"; "des:raspberry" (desenho próprio); "img:icones/<id>.png" (imagem sua, ao lado do config.json).
var galeriaIcones: [(String, String)] { [
    ("com.apple.macstudio", "Mac Studio"), ("com.apple.macmini", "Mac mini"), ("com.apple.macbookair", "MacBook Air"),
    ("com.apple.macbookpro", "MacBook Pro"), ("com.apple.imac", "iMac"), ("com.apple.macpro", "Mac Pro"),
    ("com.apple.studio-display", "Studio Display"), ("com.apple.pro-display-xdr", "Pro Display"), ("com.apple.iphone", "iPhone"),
    ("com.apple.ipad", "iPad"), ("com.apple.vision-pro", "Vision Pro"), ("sf:homepod.fill", "HomePod"),
    ("sf:server.rack", t("Servidor")), ("sf:xserve", t("Servidor 1U")), ("sf:cloud.fill", "VPS"), ("des:raspberry", "Raspberry Pi"),
    ("sf:pc", "PC"), ("sf:laptopcomputer", t("Notebook")), ("sf:display", t("Monitor")), ("sf:tv", "TV"),
    ("sf:externaldrive.fill", t("Disco")), ("sf:internaldrive.fill", "SSD"), ("sf:keyboard.fill", t("Teclado")), ("sf:magicmouse.fill", t("Mouse")),
    ("sf:rectangle.and.hand.point.up.left.fill", "Trackpad"), ("sf:headphones", t("Fones")), ("sf:airpodspro", "AirPods"),
    ("sf:airpodsmax", "AirPods Max"), ("sf:hifispeaker.fill", t("Caixa de som")), ("sf:mic.fill", t("Microfone")), ("sf:web.camera.fill", t("Webcam")),
    ("sf:camera.fill", t("Câmera")), ("sf:printer.fill", t("Impressora")), ("sf:wifi.router.fill", t("Roteador")),
    ("sf:antenna.radiowaves.left.and.right", t("Antena")), ("sf:gamecontroller.fill", t("videogame|Controle")), ("sf:point.3.connected.trianglepath.dotted", "Hub"),
    ("sf:bolt.horizontal.fill", "Thunderbolt"), ("sf:cable.connector", t("Cabo")), ("sf:bolt.car.fill", t("Eletroposto")),
    ("sf:sensor.fill", t("Sensor")), ("sf:lightbulb.fill", t("Lâmpada")),
] }

/// Estado local de uma view (@State é macro no SDK novo e o swiftc solto não acha o plugin).
final class Rascunho: ObservableObject { @Published var texto = ""; @Published var lido = false; @Published var aberto = false }

var imagensIcone: [String: NSImage] = [:]
func imagemIcone(_ v: String) -> NSImage? {
    let rel = String(v.dropFirst(4)), p = rel.hasPrefix("/") ? rel : ConfigStore.pasta.appendingPathComponent(rel).path
    if let i = imagensIcone[p] { return i }
    let i = NSImage(contentsOfFile: p)
    imagensIcone[p] = i
    return i
}

/// O ícone de um aparelho em qualquer lugar (gaveta, galeria, Ajustes). SF Symbol e desenho vão num prato redondo,
/// como os periféricos da gaveta; aparelho da Apple e imagem própria ocupam o quadrado todo.
struct IconeDispositivo: View {
    let valor: String, tamanho: CGFloat
    var prato = true
    var body: some View {
        if valor.hasPrefix("sf:") {
            ZStack {
                if prato { Circle().fill(Color.primary.opacity(0.1)) }
                Image(systemName: String(valor.dropFirst(3))).font(.system(size: tamanho * 0.42, weight: .medium)).foregroundStyle(.secondary)
            }.frame(width: tamanho, height: tamanho)
        } else if valor == "des:raspberry" {
            Raspberry().frame(width: tamanho * 0.86, height: tamanho * 0.6).frame(width: tamanho, height: tamanho)
        } else if valor.hasPrefix("img:"), let i = imagemIcone(valor) {
            Image(nsImage: i).resizable().interpolation(.high).scaledToFill().frame(width: tamanho, height: tamanho)
                .clipShape(RoundedRectangle(cornerRadius: tamanho * 0.22, style: .continuous))
        } else {
            Image(nsImage: icone(valor.isEmpty || valor.hasPrefix("img:") ? "com.apple.mac" : valor)).resizable().scaledToFit().frame(width: tamanho, height: tamanho)
        }
    }
}

/// Desenho próprio (não existe SF Symbol de Raspberry Pi): a placa verde, os pinos GPIO, o chip, o logo em framboesa e a USB.
struct Raspberry: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: h * 0.1, style: .continuous).fill(Color(red: 0.13, green: 0.55, blue: 0.29))
                HStack(spacing: w * 0.022) {
                    ForEach(0..<10, id: \.self) { _ in Rectangle().fill(Color(red: 0.93, green: 0.78, blue: 0.35)).frame(width: w * 0.045, height: h * 0.11) }
                }.offset(x: w * 0.09, y: h * 0.08)
                RoundedRectangle(cornerRadius: w * 0.03).fill(Color.black.opacity(0.85)).frame(width: w * 0.27, height: w * 0.27).offset(x: w * 0.38, y: h * 0.36)
                Circle().fill(Color(red: 0.77, green: 0.1, blue: 0.29)).frame(width: h * 0.24, height: h * 0.24).offset(x: w * 0.1, y: h * 0.6)
                RoundedRectangle(cornerRadius: w * 0.015).fill(Color(white: 0.82)).frame(width: w * 0.15, height: h * 0.3).offset(x: w * 0.87, y: h * 0.22)
            }
        }
    }
}

/// Imagem própria: escolhe o arquivo, recorta quadrado de 256 px e guarda em <pasta do config>/icones/<uuid>.png.
func escolherImagem() -> String? {
    NSApp.activate(ignoringOtherApps: true)  // app de barra: sem isso o painel abre atrás do app da frente
    let p = NSOpenPanel()
    p.allowedContentTypes = [.image]
    p.message = t("Escolha uma imagem pro ícone (ela é recortada em quadrado)")
    guard p.runModal() == .OK, let u = p.url, let rel = guardarFoto(u, id: UUID().uuidString, pasta: "icones") else { return nil }
    return "img:" + rel
}

/// A galeria (miniaturas estilo AirDrop): o padrão primeiro, depois aparelhos da Apple, SF Symbols e o desenho do
/// Raspberry Pi; a sua imagem, se tiver; no fim, "Imagem…".
struct GaleriaIcones: View {
    let atual: String, padrao: String, colunas: Int
    let escolher: (String) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 4), count: colunas), spacing: 6) {
            celula("", padrao, t("Padrão"))
            ForEach(galeriaIcones, id: \.0) { celula($0.0, $0.0, $0.1) }
            if atual.hasPrefix("img:") { celula(atual, atual, t("Sua imagem")) }
            Button { if let v = escolherImagem() { escolher(v) } } label: {
                VStack(spacing: 3) {
                    ZStack {
                        Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(width: 30, height: 30).padding(4)
                    Text(t("Imagem…")).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).help(t("Usar uma imagem sua"))
        }
    }
    func celula(_ valor: String, _ desenho: String, _ nome: String) -> some View {
        let sel = atual == valor
        return Button { escolher(valor) } label: {
            VStack(spacing: 3) {
                IconeDispositivo(valor: desenho, tamanho: 30).padding(4)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(sel ? 0.18 : 0)))
                Text(nome).font(.system(size: 9, weight: sel ? .semibold : .regular)).foregroundStyle(sel ? .primary : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.frame(width: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).help(nome)
    }
}

/// O ícone como botão: clique abre a galeria num popover.
struct BotaoIcone: View {
    @Binding var valor: String
    let padrao: String
    var tamanho: CGFloat = 24
    @StateObject private var r = Rascunho()
    var body: some View {
        Button { r.aberto = true } label: {
            HStack(spacing: 3) {
                IconeDispositivo(valor: valor.isEmpty ? padrao : valor, tamanho: tamanho)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(t("Trocar o ícone"))
        .popover(isPresented: $r.aberto, arrowEdge: .bottom) {
            GaleriaIcones(atual: valor, padrao: padrao, colunas: 8) { valor = $0; r.aberto = false }.padding(12)
        }
    }
}

struct LinhaIcone: View {
    @Binding var valor: String
    let padrao: String
    var body: some View {
        LabeledContent(t("Ícone")) {
            HStack(spacing: 10) {
                BotaoIcone(valor: $valor, padrao: padrao)
                if !valor.isEmpty { Button(t("Padrão")) { valor = "" } }
            }
        }
    }
}

/// Periféricos do Mac escolhido (o que está conectado agora) e os já renomeados: nome e ícone de cada um.
struct SecaoPerifericos: View {
    @ObservedObject var store: ConfigStore
    let q: Maquina?
    var body: some View {
        let vivos = aparelhos(q)
        let fora = store.c.aparelhos.keys.filter { k in !vivos.contains { $0.id == k } }.sorted()
        Section {
            if vivos.isEmpty && fora.isEmpty { Text(t("Nada conectado agora (ou o Mac está fora do ar)")).foregroundStyle(.secondary) }
            ForEach(vivos) { a in linha(a.id, original: a.nome, padrao: "sf:" + simbolo(a)) }
            ForEach(fora, id: \.self) { k in linha(k, original: String(k.dropFirst()), padrao: "sf:cable.connector") }
        } header: { Text(t("Periféricos")) } footer: {
            Text(t("O nome e o ícone ficam só aqui (o aparelho não muda). Também dá pelo notch: botão direito no periférico."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    func linha(_ k: String, original: String, padrao: String) -> some View {
        func campo(_ c: WritableKeyPath<CAparelho, String>) -> Binding<String> {
            Binding(get: { store.c.aparelhos[k]?[keyPath: c] ?? "" }, set: { v in
                var x = store.c.aparelhos[k] ?? CAparelho()
                x[keyPath: c] = v
                store.c.aparelhos[k] = x.vazio ? nil : x
            })
        }
        return HStack(spacing: 10) {
            BotaoIcone(valor: campo(\.icone), padrao: padrao, tamanho: 22)
            TextField(original, text: campo(\.nome), prompt: Text(original))
            if store.c.aparelhos[k] != nil {
                Button { store.c.aparelhos[k] = nil } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).help(t("Voltar ao padrão"))
            }
        }
    }
}
