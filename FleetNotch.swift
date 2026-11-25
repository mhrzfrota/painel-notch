// Frota na barra de menus + "ilha" estilo notch/Dynamic Island no topo da tela.
// Casca fina: roda coleta.py (fica vivo e imprime 1 linha JSON por ciclo) e desenha. O que medir, cores, limiares
// e textos moram no Python; aqui só se mostra. A UI só redesenha quando chega linha nova (sem timer, sem polling).
import Carbon
import Combine
import CoreLocation
import CoreWLAN
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Idiomas

/// Tradução. A chave é o texto em português (a língua-fonte); {0}, {1}… são os argumentos, na ordem.
/// "contexto|texto" desambigua palavra curta (ex.: "dia|seg"): em português aparece só o que vem depois da barra.
/// Tabelas em Resources/i18n/<código>.json (en, es, fr), as mesmas que o Python usa (comum.t). See i18n/README.md.
func t(_ s: String, _ a: Any...) -> String {
    var r = Idioma.shared.tabela[s] ?? (s.contains("|") ? String(s.split(separator: "|", maxSplits: 1)[1]) : s)
    for (i, v) in a.enumerated() { r = r.replacingOccurrences(of: "{\(i)}", with: "\(v)") }
    return r
}

/// Marca um texto pra tradução sem traduzir agora (valores que chegam em variável e são traduzidos depois com t(x)).
func N_(_ s: String) -> String { s }

/// Idioma do app. "auto" (padrão) segue o sistema, inclusive o idioma por app dos Ajustes do Sistema (o app traz
/// pt-BR/en/es/fr.lproj, então aparece em Geral › Idioma e Região › Aplicativos). Os Ajustes do app escolhem na hora:
/// a interface se refaz (ComIdioma) e o coletor reinicia (o Python lê FROTA_LANG).
final class Idioma: ObservableObject {
    static let shared = Idioma()
    static let suportados = ["pt", "en", "es", "fr"]
    /// Cada idioma no próprio idioma (convenção dos seletores de idioma).
    static let nomes: [(String, String)] = [("pt", "Português (Brasil)"), ("en", "English"), ("es", "Español"), ("fr", "Français")]
    @Published private(set) var codigo = "pt"
    private(set) var tabela: [String: String] = [:]
    var escolha: String { UserDefaults.standard.string(forKey: "idioma") ?? "auto" }

    private init() { aplicar() }

    func escolher(_ e: String) {
        objectWillChange.send()  // o seletor mostra a escolha mesmo quando o idioma resolvido não muda ("auto" = o atual)
        UserDefaults.standard.set(e, forKey: "idioma")
        aplicar()
    }

    private func aplicar() {
        let c = escolha == "auto" ? Idioma.doSistema() : escolha
        let novo = Idioma.suportados.contains(c) ? c : "en"
        tabela = Idioma.carregar(novo)
        setenv("FROTA_LANG", novo, 1)
        if novo != codigo { codigo = novo }
    }

    /// O que o macOS resolveu pro app (idioma por app ou o do sistema), contra os .lproj que o app traz; fora deles, inglês.
    static func doSistema() -> String {
        let l = Bundle.main.preferredLocalizations.first ?? "en"
        let base = String(l.prefix(2))
        return suportados.contains(base) ? base : "en"
    }

    static func carregar(_ c: String) -> [String: String] {
        guard c != "pt", let url = Bundle.main.url(forResource: c, withExtension: "json", subdirectory: "i18n"),
              let d = try? Data(contentsOf: url), let tab = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return tab
    }
}

/// Seletor de idioma (Ajustes › Geral e a primeira tela do assistente). Cada idioma aparece no próprio idioma.
struct SeletorIdioma: View {
    @ObservedObject private var idioma = Idioma.shared
    var compacto = false
    var body: some View {
        Picker(selection: Binding(get: { idioma.escolha }, set: { idioma.escolher($0) })) {
            Text(t("Automático (idioma do sistema)")).tag("auto")
            Divider()
            ForEach(Idioma.nomes, id: \.0) { Text($0.1).tag($0.0) }
        } label: {
            if compacto { Image(systemName: "globe") } else { Text(t("Idioma")) }
        }
    }
}

/// Refaz a árvore inteira quando o idioma muda (as views leem t() no body).
struct ComIdioma<C: View>: View {
    @ObservedObject private var idioma = Idioma.shared
    let conteudo: () -> C
    init(@ViewBuilder _ conteudo: @escaping () -> C) { self.conteudo = conteudo }
    var body: some View { conteudo().id(idioma.codigo).environment(\.locale, Locale(identifier: idioma.codigo)) }
}

struct Medidas: Decodable, Equatable { let cpu: Int; let gpu: Int; let ram: Int; let carga: Int; var disco: Int? = nil; var temp: Int? = nil }
struct Alerta: Decodable, Equatable { let texto: String; let nivel: Int; let tipo: String? }
struct Niveis: Decodable, Equatable { let cpu: Int; let gpu: Int; let ram: Int; var disco: Int? = nil; var temp: Int? = nil }
struct Disco: Decodable, Equatable { let nome: String; let livre: Int; let total: Int; let usado: Int }
// o que está plugado ou pareado (sonda.py conectados()); discos = externos montados
struct Monitor: Decodable, Equatable { let nome: String; let res: String?; let hz: Int?; let principal: Bool?; let interno: Bool? }
struct Usb: Decodable, Equatable { let nome: String; let marca: String?; let vel: String?; let hub: Bool? }
struct Tb: Decodable, Equatable { let nome: String?; let marca: String? }
struct Bt: Decodable, Equatable { let nome: String; let bateria: Int?; let tipo: String? }
struct Audio: Decodable, Equatable { let nome: String?; let via: String? }
struct DiscoExt: Decodable, Equatable { let nome: String; let livre: Int; let total: Int }
struct Conectados: Decodable, Equatable {
    let monitores: [Monitor]; let usb: [Usb]; let tb: [Tb]; let bluetooth: [Bt]; let audio: Audio?; let discos: [DiscoExt]?
}
struct Detalhe: Decodable, Equatable {
    let top: [[Dado]]; let temp: Double?; let termico: String; let pressao: String; let swap: Double?
    let discos: [Disco]; let conectados: Conectados?; let tailscale: String; let rede: String?; let ligado: String; let sistema: String
    let net: Net?
}
/// Rede da sonda: tráfego em bits/s (amostra de ~1 s a cada ciclo), Wi-Fi (CoreWLAN) ou cabo (link em Mb/s).
struct Net: Decodable, Equatable { let tipo: String; let iface: String?; let ip: String?; let down: Int?; let up: Int?; let link: Int?; let wifi: WifiInfo? }
struct WifiInfo: Decodable, Equatable {
    let rssi: Int?; let ruido: Int?; let taxa: Int?; let canal: Int?; let banda: String?; let largura: Int?; let padrao: String?
}
// agentes de IA (agentes.py, só leitura): Hermes, OpenClaw ou genérico, todos no mesmo formato
struct Quando: Decodable, Equatable { let hora: String; let ha: String }
struct Evento: Decodable, Equatable { let hora: String; let ha: String; let texto: String?; let canal: String?; let tipo: String? }
struct Servico: Decodable, Equatable { let nome: String; let pid: Bool; let saida: Int? }
struct Instancia: Decodable, Equatable { let nome: String; let status: String }
struct Perfil: Decodable, Equatable { let nome: String; let estado: String? }
struct Proximo: Decodable, Equatable { let hora: String; let ha: String; let nome: String }
struct Crons: Decodable, Equatable { let ativos: Int; let falhando: Int; let agendador: Bool; let proximo: Proximo? }
struct Kanban: Decodable, Equatable { let quadro: String?; let fila: Int?; let rodando: Int?; let bloqueados: Int?; let revisar: Int? }
struct Problema: Decodable, Equatable { let titulo: String; let nivel: Int }
struct CanalAg: Decodable, Equatable { let nome: String; let estado: String; let nivel: Int }
struct Agente: Decodable, Equatable {
    let id: String?; let nome: String; let tipo: String; let estado: String; let nivel: Int
    let canais: [CanalAg]?; let problemas: [Problema]?; let erro: Evento?; let atividade: Evento?; let batida: Quando?
    let versao: String?; let agentes: Int?; let servicos: [Servico]?; let uazapi: [Instancia]?; let perfis: [Perfil]?
    let crons: Crons?; let kanban: Kanban?; let avatar: String?; let porta: Int?
    var noAr: Bool { estado == "no ar" }
    // estado (agentes.py) chega cru e aparece com t(estado):
    // N_("no ar") N_("sem acesso") N_("parado") N_("travado") N_("estacionado") N_("fora do gateway") N_("iniciando") N_("pede atenção")
}
// servidores Linux (sonda_linux.sh)
struct MedidasS: Decodable, Equatable { let cpu: Int; let ram: Int; let disco: Int }
struct NiveisS: Decodable, Equatable { let cpu: Int; let ram: Int; let disco: Int }
struct ProblemaS: Decodable, Equatable { let nivel: Int; let texto: String; let tipo: String?; let mais: Int? }
struct ServicoS: Decodable, Equatable { let nome: String; let estado: String }
struct Container: Decodable, Equatable { let nome: String; let estado: String; let status: String; let imagem: String }
struct DetalheS: Decodable, Equatable {
    let sistema: String; let kernel: String; let nome: String; let nucleos: Int; let ligado: String; let carga: [Double]; let ram: String
    let swap: Double?; let discos: [Disco]; let top: [[Dado]]; let servicos: [ServicoS]; let containers: [Container]; let docker: String?
    let problemas: [ProblemaS]
}
struct Servidor: Decodable, Equatable {
    let id: String?; let nome: String; let host: String; let online: Bool; let erro: String?; let nivel: Int
    let medidas: MedidasS?; let niveis: NiveisS?; let alerta: ProblemaS?; let detalhe: DetalheS?
}
// e-mail (caixas.py): só contagem e cabeçalho, nunca o corpo
struct CabecalhoEmail: Decodable, Equatable { let de: String; let assunto: String; let ha: String; let hora: String }
struct ContaEmail: Decodable, Equatable {
    let id: String; let nome: String; let endereco: String?; let provedor: String; let app: String?; let estado: String; let nivel: Int
    let erro: String?; let naoLidos: Int?; let chegou: String?; let verificado: String?; let ultimo: CabecalhoEmail?; let cabecalhoHa: String?
}
struct Chegada: Decodable, Equatable { let conta: String; let ha: String }
struct Email: Decodable, Equatable { let contas: [ContaEmail]; let naoLidos: Int; let nivel: Int; let problema: String?; let chegou: Chegada?; let intervalo: Int? }
// Orca (CLI em modo leitura): só contagens
struct ErroOrca: Decodable, Equatable { let nome: String; let texto: String; let ha: String? }
struct Orca: Decodable, Equatable {
    let aberto: Bool; let nivel: Int; let workspaces: Int?; let rodando: Int?; let workers: Int?; let esperando: Int?; let revisar: Int?
    let automacoes: Int?; let erro: ErroOrca?
}
/// Valor heterogêneo do JSON (o top vem como ["nome", 12.3]).
enum Dado: Decodable, Equatable {
    case texto(String), numero(Double)
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .numero(n) } else { self = .texto(try c.decode(String.self)) }
    }
    var texto: String { if case .texto(let t) = self { return t }; return "" }
    var numero: Double { if case .numero(let n) = self { return n }; return 0 }
}
// sincronização (coleta.py sincronizacao(), só leitura): Google Drive para desktop, rclone e LaunchAgents de backup
struct ErroSinc: Decodable, Equatable { let quando: String; let tipo: String; let motivo: String }
struct DriveSinc: Decodable, Equatable {
    let app: Bool; let subindo: Int; let baixando: Int; let fila: Int; let emDia: Bool; let enviouHa: String?; let ativo: Bool
    let recebeu: Int; let errosHora: Int; let ultimoErro: ErroSinc?; let estadoHa: String?
}
struct Progresso: Decodable, Equatable { let feito: String; let total: String; let pct: Int; let vel: String?; let eta: String? }
struct Rclone: Decodable, Equatable {
    let pid: Int; let cmd: String; let origem: String; let destino: String; let ha: String; let arquivos: [String]; let nAbertos: Int; let progresso: Progresso?
}
struct Backup: Decodable, Equatable { let nome: String; let estado: String; let saida: Int?; let horario: String?; let ultimo: Quando?; let linha: String }
struct Sinc: Decodable, Equatable {
    let ativo: Bool; let seta: String?; let nivel: Int; let resumo: String; let problema: String?; let atividade: String?
    let drive: DriveSinc?; let rclone: [Rclone]; let backups: [Backup]
}
struct Maquina: Decodable {
    let titulo: String; let linhas: [String]; let nivel: Int; let nome: String?; let curto: String?; let modelo: String?; let card: [String]?
    let medidas: Medidas?; let alerta: Alerta?; let niveis: Niveis?; let detalhe: Detalhe?
    let ts: String?; let local: Bool?  // host do config (as ações chamam o Mac por ele) e se é este Mac
    let id: String?  // id na config (renomear e trocar ícone)
}
struct Conta: Decodable {
    let id: String?; let rotulo: String; let pct: Int; let nivel: Int; let card: [String]; let janela: String?; let reset: String?; let limite: Bool?
    let ferramenta: String?; let app: String?; let semFonte: Bool?; let semLogin: Bool?
}
struct Estado: Decodable {
    let barra: String; let pico: String?; let atualizado: String?; let painel: String?
    let maquinas: [Maquina]; var contas: [Conta]? = nil; var agentes: [Agente]? = nil; var sincronizacao: Sinc? = nil
    var servidores: [Servidor]? = nil; var email: Email? = nil; var orca: Orca? = nil; var semConfig: Bool? = nil
    static func vazio(_ barra: String) -> Estado { Estado(barra: barra, pico: nil, atualizado: nil, painel: nil, maquinas: []) }
}

/// Roda o coletor (ou o demo.py, no modo demonstração) e publica cada linha. Config salva nos Ajustes = reinicia o
/// coletor na hora (sem o "coletor parado" de 5 s, que é só pra quando ele morre sozinho).
final class Modelo: ObservableObject {
    @Published var estado = Estado.vazio("⚪️ …")
    let acoes = Acoes()
    let pergunta = Pergunta()
    let uso = UsoModelos()     // uso por modelo das contas de IA (modelos.py, sob demanda)
    let copiados = Copiados()  // histórico do ⌘C (só com o módulo ligado)
    private var processo: Process?
    private var reiniciando = false
    var demo: () -> Bool = { false }

    func iniciar() { Task.detached { await self.rodar() } }

    func reiniciar() { reiniciando = true; processo?.terminate() }

    /// A página de e-mail abriu: pede ao coletor o último cabeçalho agora (SIGUSR1; ele roda um ciclo na hora).
    func pedirEmail() { if let p = processo, p.isRunning, !demo() { kill(p.processIdentifier, SIGUSR1) } }

    /// A gaveta abriu: um ciclo na hora (SIGUSR2), no máximo 1 a cada 15 s, pra quem olha ver dado fresco.
    private var olhou = Date.distantPast
    func olhar() {
        guard Date().timeIntervalSince(olhou) > 15, let p = processo, p.isRunning, !demo() else { return }
        olhou = Date()
        kill(p.processIdentifier, SIGUSR2)
    }

    func rodar() async {
        while true {
            let script = Bundle.main.path(forResource: demo() ? "demo" : "coleta", ofType: "py")!
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-u", script]
            p.environment = Py.ambiente()
            let saida = Pipe()
            p.standardOutput = saida
            p.standardError = FileHandle.nullDevice
            processo = p
            do {
                try p.run()
                for try await linha in saida.fileHandleForReading.bytes.lines {
                    if let e = try? JSONDecoder().decode(Estado.self, from: Data(linha.utf8)) {
                        await MainActor.run {
                            trafego.iface = e.maquinas.first { $0.local == true }?.detalhe?.net?.iface
                            if Paleta.reduzir { self.estado = e } else { withAnimation(.spring(response: 0.6, dampingFraction: 1)) { self.estado = e } }
                        }
                    }
                }
            } catch {}
            if p.isRunning { p.terminate() }
            if reiniciando { reiniciando = false; continue }
            // coleta.py morreu (não deveria): mostra e reinicia
            await MainActor.run { self.estado = Estado.vazio("⚪️ coletor parado") }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}

// MARK: - Pergunta rápida (pergunta.py: as contas já logadas do Claude Code ou do Codex, ou uma chave de API do Keychain)

struct Resposta: Codable, Identifiable, Equatable {
    var id = UUID().uuidString, pergunta = "", resposta = "", erro = "", conta = "", ferramenta = "", segundos = 0.0, quando = Date()
    var nota: String? = nil  // "Alice sem login, respondi pela Bia" (opcional: o histórico antigo não tem)
}

final class Pergunta: ObservableObject {
    @Published var texto = ""
    @Published var conta: String?   // id da conta de IA escolhida
    @Published var rodando = false
    @Published var atual: Resposta?
    @Published var historico: [Resposta] = []
    @Published var foco = false     // o atalho global pede foco no campo
    static let arquivo = ConfigStore.pasta.appendingPathComponent("perguntas.json")

    init() { historico = (try? JSONDecoder().decode([Resposta].self, from: Data(contentsOf: Pergunta.arquivo))) ?? [] }

    func enviar(_ c: CIA) {
        let p = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !rodando, !c.perguntar.isEmpty else { return }
        rodando = true
        atual = nil
        var args = ["--conta", c.id, "--nome", c.nome, "--provedor", c.perguntar]  // --conta: sem login, o pergunta.py tenta as outras
        if !c.perfil.isEmpty && c.perguntar == "claude-cli" { args += ["--perfil", c.perfil] }
        if !c.modelo.isEmpty { args += ["--modelo", c.modelo] }
        Py.rodar("pergunta", args, entrada: p) { [weak self] r in
            guard let s = self else { return }
            let x = Resposta(pergunta: p, resposta: r["resposta"] as? String ?? "", erro: r["erro"] as? String ?? "",
                             conta: r["conta"] as? String ?? (c.nome.isEmpty ? c.ferramenta : c.nome), ferramenta: c.ferramenta,
                             segundos: r["segundos"] as? Double ?? 0, nota: r["nota"] as? String)
            s.rodando = false
            s.atual = x
            if x.erro.isEmpty { s.texto = "" }
            s.historico = Array(([x] + s.historico).prefix(10))  // só as últimas 10, só neste Mac
            try? FileManager.default.createDirectory(at: ConfigStore.pasta, withIntermediateDirectories: true)
            try? JSONEncoder().encode(s.historico).write(to: Pergunta.arquivo, options: .atomic)
        }
    }
}

// MARK: - Ações (acoes.py faz o trabalho, aqui ou no Mac remoto via SSH; a UI mostra a prévia e pede o 2º clique)

struct ItemCache: Decodable, Equatable, Identifiable { let id: String; let nome: String; let caminho: String; let bytes: Int; let pulado: String?; let nota: String? }
struct Previa: Decodable, Equatable { let itens: [ItemCache]?; let total: Int?; let erro: String? }
struct LixeiraT: Decodable, Equatable { let bytes: Int; let itens: Int; let semAcesso: Bool? }
struct DiscoT: Decodable, Equatable { let nome: String; let livre: Int; let total: Int }
struct AppT: Decodable, Equatable { let nome: String; let pid: Int; let app: String; let cpu: Double }
struct Tamanhos: Decodable, Equatable { let lixeira: LixeiraT?; let discos: [DiscoT]?; let apps: [AppT]?; let erro: String? }

/// Ação destrutiva rodando ou acabada, por "<máquina>:<alvo>" (cache, lixeira, disco:<nome>, app:<pid>).
enum Fase: Equatable { case rodando, feito(String), falhou(String) }

/// Separador decimal do idioma da interface: ponto em inglês, vírgula em português, espanhol e francês.
func decimal(_ s: String) -> String { Idioma.shared.codigo == "en" ? s : s.replacingOccurrences(of: ".", with: ",") }

func gb(_ b: Int) -> String {
    if b > 0 && b < 1_000_000 { return t("menos de 1 MB") }
    return b >= 1_000_000_000 ? decimal(String(format: "%.1f", Double(b) / 1e9)) + " " + t("unidade|GB") : "\(b / 1_000_000) " + t("unidade|MB")
}

/// Roda acoes.py fora da main thread. Fica vivo com o app: fechar a gaveta no meio de uma limpeza não perde o resultado.
struct Velocidade: Decodable, Equatable { var down: Double? = nil, up: Double? = nil, rpm: Double? = nil, erro: String? = nil }

final class Acoes: ObservableObject {
    @Published var velocidades: [String: Velocidade] = [:]  // teste de velocidade, por Mac
    @Published var medindo: Set<String> = []
    @Published var tamanhos: [String: Tamanhos] = [:]  // por Mac (nome no Tailscale)
    @Published var previas: [String: Previa] = [:]
    @Published var fases: [String: Fase] = [:]
    private var pedidos: [String: Date] = [:]

    func rodar(_ args: [String], fim: @escaping (Data) -> Void) {
        let script = Bundle.main.path(forResource: "acoes", ofType: "py")!
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(), saida = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script] + args
            p.standardOutput = saida
            p.standardError = FileHandle.nullDevice
            var dado = Data()
            if (try? p.run()) != nil { dado = saida.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit() }
            DispatchQueue.main.async { fim(dado) }
        }
    }

    /// networkQuality naquele Mac (aqui ou por SSH): ~20 s e consome banda, então só roda no clique.
    func testarVelocidade(_ ts: String) {
        guard !medindo.contains(ts) else { return }
        medindo.insert(ts)
        rodar(["velocidade", "--maquina", ts]) { [weak self] d in
            self?.medindo.remove(ts)
            self?.velocidades[ts] = (try? JSONDecoder().decode(Velocidade.self, from: d)) ?? Velocidade(erro: t("o Mac não respondeu"))
        }
    }

    /// Lixeira, discos externos e apps abertos (1× por minuto por Mac, ou na hora depois de uma ação).
    func carregar(_ ts: String, forcar: Bool = false) {
        if !forcar, let t = pedidos[ts], Date().timeIntervalSince(t) < 60 { return }
        pedidos[ts] = Date()
        rodar(["tamanhos", "--maquina", ts]) { [weak self] d in
            self?.tamanhos[ts] = (try? JSONDecoder().decode(Tamanhos.self, from: d)) ?? Tamanhos(lixeira: nil, discos: nil, apps: nil, erro: t("o Mac não respondeu"))
        }
    }

    func previa(_ ts: String) {
        previas[ts] = nil
        fases[ts + ":cache"] = nil
        rodar(["cache-previa", "--maquina", ts]) { [weak self] d in
            self?.previas[ts] = (try? JSONDecoder().decode(Previa.self, from: d)) ?? Previa(itens: nil, total: nil, erro: t("o Mac não respondeu"))
        }
    }

    /// Só depois do 2º clique. O resultado vira uma frase (liberou X, ejetado, erro…).
    func executar(_ chave: String, _ args: [String], depois: (() -> Void)? = nil) {
        guard fases[chave] != .rodando else { return }
        fases[chave] = .rodando
        rodar(args) { [weak self] d in
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? ["erro": t("o Mac não respondeu")]
            self?.fases[chave] = Acoes.fase(args[0], j)
            depois?()
        }
    }

    static func fase(_ acao: String, _ j: [String: Any]) -> Fase {
        if let e = j["erro"] as? String { return .falhou(e) }
        let liberou = gb(j["liberado"] as? Int ?? 0)
        switch acao {
        case "cache-limpar":
            let itens = j["itens"] as? [[String: Any]] ?? []
            let pulados = itens.filter { $0["pulado"] != nil }.count, erros = itens.reduce(0) { $0 + (($1["erros"] as? [Any])?.count ?? 0) }
            return .feito(t("Liberou {0}", liberou) + (pulados > 0 ? " · " + (pulados > 1 ? t("{0} pulados", pulados) : t("{0} pulado", pulados)) : "")
                          + (erros > 0 ? " · " + (erros > 1 ? t("{0} arquivos não saíram", erros) : t("{0} arquivo não saiu", erros)) : ""))
        case "lixeira-esvaziar": return .feito(t("Lixeira vazia · liberou {0}", liberou))
        case "ejetar": return j["ok"] as? Bool == true ? .feito(t("Ejetado")) : .falhou(j["mensagem"] as? String ?? t("não ejetou"))
        case "reiniciar": return j["ok"] as? Bool == true ? .feito(j["forcado"] as? Bool == true ? t("Reaberto (precisou forçar)") : t("Reaberto")) : .falhou(t("fechou, mas não reabriu"))
        default: return j["ok"] as? Bool == true ? .feito(t("Feito")) : .falhou(t("não deu"))
        }
    }
}

// MARK: - Visual

/// Paleta (docs/design.md): preto verdadeiro, branco em níveis, UMA cor de destaque (ciano = medida),
/// âmbar/vermelho só pra estado. Nada de verde: normal não precisa de cor.
enum Paleta {
    /// O gosto que está valendo (Ajustes › Aparência): o AppDelegate troca na hora em que a config muda.
    static var v = CVisual()
    static var ciano: Color { Color(hex: v.destaque) }  // a cor de destaque (padrão #64D2FF)
    static var leve: Bool { v.modo == "light" }
    /// Densidade: o respiro entre os blocos da gaveta.
    static var respiro: CGFloat { v.densidade == "compacta" ? 0.6 : v.densidade == "arejada" ? 1.45 : 1 }
    // atenção e crítico vêm dos Ajustes (Aparência); o padrão é o âmbar e o vermelho do sistema
    static var ambar = Color(hex: "#FF9F0A")
    static var vermelho = Color(hex: "#FF453A")
    static var nsAmbar: NSColor { NSColor(ambar) }
    static var nsVermelho: NSColor { NSColor(vermelho) }
    // sistema OU a chave do próprio app (defaults write app.fleetnotch reduzirMovimento -bool true): é como se
    // testa o caminho de acessibilidade sem mexer na configuração do Mac
    static var reduzir: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "reduzirMovimento") }
    static var contraste: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || UserDefaults.standard.bool(forKey: "aumentarContraste") }
    // texto em 3 níveis, todos ≥ 4,5:1 no preto (o rótulo de 38% de antes dava 3,3:1); Aumentar contraste sobe tudo
    static var primario: Color { .white.opacity(contraste ? 1 : 0.92) }
    static var secundario: Color { .white.opacity(contraste ? 0.85 : 0.66) }
    static var terciario: Color { .white.opacity(contraste ? 0.72 : 0.5) }
    static var trilho: Double { contraste ? 0.3 : 0.16 }  // trilho dos anéis (a cor da métrica bem apagada)
    // anéis triplos (de fora pra dentro, as métricas escolhidas; padrão CPU, GPU, RAM): a cor do estilo; âmbar/vermelho quando
    // a métrica pede atenção
    static var metricas: [Color] { v.estilo.aneis.map { Color(hex: $0.cor) } }
    static var nomes: [String] { v.metricas.map(nomeMetrica) }
    static func metrica(_ i: Int, nivel: Int) -> Color { nivel >= 1 ? estado(nivel) : metricas[i] }
    static func conta(_ nivel: Int) -> Color { nivel < 0 ? .white.opacity(0.2) : nivel == 0 ? .white.opacity(0.85) : estado(nivel) }
    /// Anel de uma conta de IA: estado quando pede atenção; senão branco, a cor da marca ou a de destaque (estilo dos anéis).
    static func corConta(_ c: Conta) -> Color {
        if c.nivel != 0 { return conta(c.nivel) }
        switch v.estilo.contas {
        case "marca": return corMarca(c.ferramenta ?? c.rotulo)
        case "destaque": return ciano
        default: return conta(0)
        }
    }
    static let mola = Animation.spring(response: 0.4, dampingFraction: 1)
    static func estado(_ nivel: Int) -> Color { nivel >= 2 ? vermelho : ambar }
}

/// Miniatura oficial do modelo (a mesma do AirDrop/Finder), lida do sistema em runtime: hw.model → UTType → ícone.
/// Aceita também um UTType genérico (ex.: com.apple.macmini) pra máquina que nunca foi vista online.
var icones: [String: NSImage] = [:]
func icone(_ modelo: String?) -> NSImage {
    let m = modelo ?? ""
    if let i = icones[m] { return i }
    let porCodigo = UTType(tag: m, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
    let tipo = (porCodigo?.isDynamic == false ? porCodigo : nil) ?? UTType(m)
    let i = tipo.map { NSWorkspace.shared.icon(for: $0) } ?? NSImage(named: NSImage.computerName)!
    icones[m] = i
    return i
}

/// Logo da ferramenta: o ícone do app instalado, lido em runtime (NSWorkspace). Sem app, monograma neutro com a inicial.
var logos: [String: NSImage] = [:]
struct Logo: View {
    let c: Conta, tamanho: CGFloat
    var body: some View {
        if let a = c.app {
            Image(nsImage: logos[a] ?? { let i = NSWorkspace.shared.icon(forFile: a); logos[a] = i; return i }())
                .resizable().scaledToFit().frame(width: tamanho, height: tamanho)
        } else {
            ZStack {
                Circle().fill(Color.white.opacity(0.14))
                Text(String((c.ferramenta ?? c.rotulo).prefix(1)).uppercased())
                    .font(.system(size: tamanho * 0.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.75))
            }.frame(width: tamanho * 0.86, height: tamanho * 0.86)
        }
    }
}

/// Medidor circular: trilho na própria cor bem apagada (como os anéis do Apple Watch) e arco começando ao meio-dia.
/// Com estilo (Ajustes › Aparência › Anéis): degradê ao longo do arco, espessura, trilho, brilho e ponta. A cor de estado
/// (âmbar/vermelho), quando vem, ganha do estilo: o que pede atenção nunca fica bonito demais pra ser visto.
struct Anel: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let valor: Int, cor: Color, diametro: CGFloat, linha: CGFloat
    var estilo: CAnel? = nil
    var body: some View {
        let e = estilo, w = linha * CGFloat(e?.espessura ?? 1), frac = CGFloat(max(0, min(valor, 100))) / 100
        let doEstilo = e != nil && cor == Color(hex: e!.cor)  // a view chamou com a cor do estilo: não é cor de estado
        let fim = doEstilo && !(e!.cor2.isEmpty) ? Color(hex: e!.cor2) : cor
        let trilho = Paleta.contraste ? max(e?.trilho ?? Paleta.trilho, 0.3) : (e?.trilho ?? Paleta.trilho)
        let brilho = doEstilo && !Paleta.contraste ? CGFloat(e!.brilho) : 0
        ZStack {
            Circle().inset(by: w / 2).stroke(cor.opacity(trilho), lineWidth: w)
            Circle().inset(by: w / 2).trim(from: 0, to: frac)
                .stroke(AngularGradient(colors: [cor, fim], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * Double(max(frac, 0.01)))),
                        style: StrokeStyle(lineWidth: w, lineCap: (e?.redonda ?? true) ? .round : .butt))
                .rotationEffect(.degrees(-90))
                .shadow(color: brilho > 0 ? fim.opacity(0.9 * brilho) : .clear, radius: brilho * w * 1.2)
        }.frame(width: diametro, height: diametro)
    }
}

/// Anéis triplos concêntricos estilo Activity: CPU (fora), GPU (meio), RAM (dentro).
struct Aneis: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let md: Medidas, nv: Niveis?, diametro: CGFloat, linha: CGFloat
    var body: some View {
        let k = Paleta.v.metricas + ["cpu", "gpu", "ram"]
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Anel(valor: md.valor(k[i]), cor: Paleta.metrica(i, nivel: nv?.valor(k[i]) ?? 0), diametro: diametro - CGFloat(i) * 2 * (linha + 2), linha: linha,
                     estilo: Paleta.v.estilo.aneis[i])
            }
        }
        // dica do sistema ao parar o mouse: diz qual anel é qual sem depender da legenda do rodapé
        .help((0..<3).map { "\(nomeMetrica(k[$0])) \(md.texto(k[$0]))" }.joined(separator: " · "))
    }
}

/// Selo de alerta no canto do ícone (disco, termômetro, memória), na cor do nível, com aro preto separando dos anéis.
struct Selo: View {
    let a: Alerta, tamanho: CGFloat
    var body: some View {
        let simbolo = ["disco": "externaldrive.fill", "calor": "thermometer.medium", "memoria": "memorychip.fill"][a.tipo ?? ""] ?? "exclamationmark"
        ZStack {
            Circle().fill(Color.black).frame(width: tamanho + 4, height: tamanho + 4)
            Circle().fill(Paleta.estado(a.nivel)).frame(width: tamanho, height: tamanho)
            Image(systemName: simbolo).font(.system(size: tamanho * 0.48, weight: .bold)).foregroundColor(.black)
        }
    }
}

/// A gaveta não tem medida fixa: ela mede o conteúdo (TamanhoKey) e faz morph pra ele.
enum Medida {
    /// A janela da gaveta começa este tanto ACIMA da base do notch: é onde moram o pescoço e os filetes, por baixo do notch.
    static let encaixe: CGFloat = 12
}

/// Tamanho natural de cada página da gaveta (por id), medido do próprio conteúdo. A gaveta faz morph pro da página atual.
struct TamanhoKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) { value.merge(nextValue()) { $1 } }
}
/// Onde está cada alvo de hover (por id), no espaço da gaveta: o hover sai da geometria real, não de conta feita à mão.
struct AlvosKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}
extension View {
    /// Página no tamanho natural (nunca é espremida no tamanho de outra página durante a troca) e medida.
    func pagina(_ id: String) -> some View {
        fixedSize().background(GeometryReader { g in Color.clear.preference(key: TamanhoKey.self, value: [id: g.size]) })
    }
    func alvo(_ id: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: AlvosKey.self, value: [id: g.frame(in: .named("gaveta"))]) })
    }
}

/// A gaveta como peça única: o "pescoço" da largura do notch, filetes côncavos e o corpo com cantos contínuos.
/// Animável no tamanho do corpo: fechada, tem altura zero e some inteira atrás do notch (nada sobra nos cantos dele).
struct Gaveta: Shape {
    let notch: CGSize, topo: CGFloat  // topo = onde fica a base do notch nesta janela
    var corpo: CGSize
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(corpo.width, corpo.height) }
        set { corpo = CGSize(width: newValue.first, height: newValue.second) }
    }
    func path(in r: CGRect) -> Path {
        // o pescoço só ganha fundura junto com o corpo: com a gaveta fechada (h = 0) a forma é vazia, então os cantos
        // arredondados do notch ficam à mostra (antes o pescoço fechado deixava os cantos quadrados)
        let cx = r.midX, yd = topo, y0 = yd - min(10, max(0, corpo.height) * 0.8), pesc = notch.width / 2 - 6
        let w = max(corpo.width, 2 * pesc), h = max(0, corpo.height)
        let xa = cx - pesc, xb = cx + pesc, xl = cx - w / 2, xr = cx + w / 2, yb = yd + h
        let f = min(10, (w / 2 - pesc) / 2, h / 2), rt = min(14, (w / 2 - pesc - f) / 1.4, h / 3), rb = min(26, w / 4, h / 2.4)
        var p = Path()
        // canto contínuo (squircle): curva mais longa que um arco, controles perto do vértice
        func canto(_ a: CGPoint, _ v: CGPoint, _ b: CGPoint) {
            p.addLine(to: a)
            p.addCurve(to: b, control1: CGPoint(x: v.x + (a.x - v.x) * 0.22, y: v.y + (a.y - v.y) * 0.22),
                       control2: CGPoint(x: v.x + (b.x - v.x) * 0.22, y: v.y + (b.y - v.y) * 0.22))
        }
        let et = rt * 1.4, eb = rb * 1.4
        p.move(to: CGPoint(x: xa, y: y0))
        p.addLine(to: CGPoint(x: xb, y: y0))
        p.addLine(to: CGPoint(x: xb, y: yd - f))
        p.addQuadCurve(to: CGPoint(x: xb + f, y: yd), control: CGPoint(x: xb, y: yd))  // filete côncavo
        canto(CGPoint(x: xr - et, y: yd), CGPoint(x: xr, y: yd), CGPoint(x: xr, y: yd + et))
        canto(CGPoint(x: xr, y: yb - eb), CGPoint(x: xr, y: yb), CGPoint(x: xr - eb, y: yb))
        canto(CGPoint(x: xl + eb, y: yb), CGPoint(x: xl, y: yb), CGPoint(x: xl, y: yb - eb))
        canto(CGPoint(x: xl, y: yd + et), CGPoint(x: xl, y: yd), CGPoint(x: xl + et, y: yd))
        p.addLine(to: CGPoint(x: xa - f, y: yd))
        p.addQuadCurve(to: CGPoint(x: xa, y: yd - f), control: CGPoint(x: xa, y: yd))
        p.closeSubpath()
        return p
    }
}

final class EstadoIlha: ObservableObject {
    @Published var aberta = false
    @Published var montada = false   // a gaveta só existe na árvore enquanto aberta ou fechando: fechada, dado novo não custa render
    @Published var pagina: String?   // página aberta: "mac:<nome>", "hermes" ou "sinc"; nil = a frota
    @Published var acao: String?     // painel de ação aberto na página do Mac (cache, lixeira, discos, apps)
    @Published var hover: String?    // alvo sob o mouse ("mac:<nome>", "hermes", "conta:<rótulo>", "ap:<id>", "offline")
    @Published var tamanho: CGSize = .zero  // tamanho medido da página atual: é pra ele que a gaveta faz morph
    @Published var dica = false             // a legenda do notch aparecendo sozinha na 1ª vez, com a explicação
    // geometria dos alvos e último ponto do mouse (não publicados: não redesenham nada). O hover é recalculado quando
    // QUALQUER um muda: se a faixa de conectados troca de Mac embaixo de um mouse parado, o alvo é o novo, não o velho.
    var alvos: [String: CGRect] = [:] { didSet { recalcular() } }
    var mouse: CGPoint? { didSet { recalcular() } }
    func recalcular() {
        var id: String?
        if let p = mouse, aberta, pagina == nil { id = alvos.first { $0.value.contains(p) }?.key }
        if id != hover { hover = id }
    }
}

extension AnyTransition {
    /// Troca no mesmo lugar SEM sobrepor: o velho some rápido e o novo entra logo depois (cross-fade simultâneo deixava
    /// dois textos, ou duas faixas de aparelhos, um em cima do outro por um instante).
    static var troca: AnyTransition {
        Paleta.reduzir ? .opacity : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.06)),
                                                removal: .opacity.animation(.easeIn(duration: 0.06)))
    }
}

/// O conteúdo materializa quando a gaveta nasce: opacidade, desfoque e escala, em ondas que saem do notch
/// (complicações, mostrador, conectados, legenda). Reduzir movimento: só opacidade.
struct Entrada: ViewModifier {
    let onda: Int, aberta: Bool
    func body(content: Content) -> some View {
        let r = Paleta.reduzir
        content.opacity(aberta ? 1 : 0)
            .blur(radius: aberta || r ? 0 : 6)
            .scaleEffect(aberta || r ? 1 : 0.96, anchor: .top)
            .animation(r ? .easeOut(duration: 0.18)
                       : .spring(response: 0.42, dampingFraction: 1).delay(aberta ? 0.05 + Double(onda) * 0.05 : 0), value: aberta)
    }
}

/// Só a gaveta é SwiftUI. O notch (silhueta + indicadores) é Core Animation puro, ver NotchView.
struct IlhaView: View {
    @ObservedObject var m: Modelo
    @ObservedObject var e: EstadoIlha
    @ObservedObject var cfg: ConfigStore
    let notch: CGSize, janela: CGSize
    @AppStorage("legendaVista") private var legendaVista = false
    @Environment(\.openSettings) private var abrirAjustes

    var body: some View {
        let reduzir = Paleta.reduzir
        // fechada (ou nascendo): corpo de altura zero, escondido atrás do notch. Aberta: o tamanho MEDIDO da página.
        let aberto = (e.aberta || reduzir) && e.tamanho != .zero
        let forma = Gaveta(notch: notch, topo: Medida.encaixe, corpo: aberto ? e.tamanho : CGSize(width: notch.width - 12, height: 0))
        ZStack(alignment: .top) {
            forma.fill(Color.black).shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 12)
            // profundidade sem vidro: um levante de luz atrás do mostrador e o aro aceso em cima, apagando pra baixo
            // (no tamanho da janela, pra forma recortar no mesmo espaço de coordenadas da gaveta)
            RadialGradient(colors: [Color(white: Paleta.contraste ? 0 : 0.075), .clear],
                           center: UnitPoint(x: 0.5, y: (Medida.encaixe + 160) / janela.height), startRadius: 0, endRadius: 190)
                .frame(width: janela.width, height: janela.height).clipShape(forma)
            forma.stroke(LinearGradient(colors: [.white.opacity(Paleta.contraste ? 0.4 : 0.16), .white.opacity(Paleta.contraste ? 0.25 : 0.04)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 1).clipShape(forma)
            if e.montada {
                conteudo.padding(.top, Medida.encaixe)
                    .frame(width: janela.width, height: janela.height, alignment: .top)
                    .clipShape(forma)
            }
        }
        .opacity(reduzir && !e.aberta ? 0 : 1)  // Reduzir movimento: sem morph, só cross-fade
        .frame(width: janela.width, height: janela.height, alignment: .top)
        .coordinateSpace(name: "gaveta")
        .onPreferenceChange(AlvosKey.self) { e.alvos = $0 }
        .onPreferenceChange(TamanhoKey.self) { t in
            guard let n = t[e.pagina ?? "frota"], n != e.tamanho else { return }
            // gaveta fechada: só registra (é invisível); aberta: toda mudança de tamanho é morph com a mesma mola
            // (Reduzir movimento: o tamanho troca na hora e só o conteúdo faz cross-fade)
            if !e.aberta || Paleta.reduzir { e.tamanho = n } else { withAnimation(Paleta.mola) { e.tamanho = n } }
        }
        .foregroundStyle(Paleta.primario)
        .environment(\.colorScheme, .dark)  // preta como o notch e a Dynamic Island nos dois modos; por dentro, sempre o esquema escuro
        .animation(Paleta.reduzir ? .easeOut(duration: 0.15) : Paleta.mola, value: cfg.c.visual)  // Light ⇄ Full, estilo, densidade: transição suave
        .onAppear { abrirSettings = { abrirAjustes() } }  // a notificação <ID>.ajustes abre os Ajustes por aqui
    }

    var conteudo: some View {
        let ida: AnyTransition = Paleta.reduzir ? .opacity : .move(edge: .trailing).combined(with: .opacity)
        let volta: AnyTransition = Paleta.reduzir ? .opacity : .move(edge: .leading).combined(with: .opacity)
        let p = e.pagina ?? ""
        // cada página no próprio tamanho natural: a que sai não é re-diagramada no tamanho da que entra
        return ZStack(alignment: .top) {
            if p.hasPrefix("agente:"), let g = (m.estado.agentes ?? []).first(where: { "agente:" + ($0.id ?? $0.nome) == p }) {
                PaginaAgente(g: g, foto: foto(g), voltar: voltar).padding(20).pagina(p).transition(ida)
            } else if p.hasPrefix("servidor:"), let s = (m.estado.servidores ?? []).first(where: { "servidor:" + ($0.id ?? $0.nome) == p }) {
                PaginaServidor(s: s, voltar: voltar, icone: cfg.c.servidores.first { $0.id == s.id }?.icone ?? "",
                               editar: { abrir("editar:srv:" + (s.id ?? "")) }).padding(20).pagina(p).transition(ida)
            } else if p.hasPrefix("editar:") {
                // .id: cada item é uma view nova (o rascunho do nome não passa de um aparelho pro outro)
                PaginaEditar(chave: p, store: cfg, e: m.estado, voltar: voltar).id(p).padding(20).pagina(p).transition(ida)
            } else if p == "email", let x = m.estado.email {
                PaginaEmail(x: x, voltar: voltar).padding(20).pagina(p).transition(ida).onAppear { m.pedirEmail() }
            } else if p.hasPrefix("conta:"), let c = (m.estado.contas ?? []).first(where: { "conta:" + ($0.id ?? $0.rotulo) == p }) {
                PaginaConta(c: c, cia: cfg.c.ia.first { $0.id == c.id }, voltar: voltar, uso: m.uso, demo: cfg.c.demo).padding(20).pagina(p).transition(ida)
            } else if p == "historico" {
                PaginaHistorico(p: m.pergunta, voltar: voltar).padding(20).pagina(p).transition(ida)
            } else if p == "sinc", let s = m.estado.sincronizacao {
                PaginaSinc(s: s, voltar: voltar).padding(20).pagina("sinc").transition(ida)
            } else if let q = m.estado.maquinas.first(where: { "mac:" + ($0.nome ?? "") == p && $0.medidas != nil }) {
                PaginaMac(q: q, voltar: voltar, acoes: m.acoes, ilha: e, comAcoes: cfg.c.modulos.acoes, nomes: cfg.c.aparelhos, abrir: abrir)
                    .padding(20).pagina(p).transition(ida)
            } else {
                Mostrador(e: m.estado, ilha: e, cfg: cfg.c, pergunta: m.pergunta, copiados: m.copiados, legenda: !legendaVista, abrir: abrir)
                    .padding(.horizontal, 20).padding(.top, 14 * Paleta.respiro).padding(.bottom, 14 * Paleta.respiro)
                    .pagina("frota").transition(volta)  // a frota sai e volta pela esquerda
            }
        }
    }

    /// A foto do agente: a escolhida nos Ajustes; senão a que o próprio agente tem (assets/avatar.png do Hermes).
    func foto(_ g: Agente) -> String? { ConfigStore.foto(cfg.c.agentes.first { $0.id == g.id }) ?? g.avatar }

    func voltar() { withAnimation(Paleta.reduzir ? .easeOut(duration: 0.15) : Paleta.mola) { e.pagina = nil; e.acao = nil } }
    func abrir(_ p: String) { withAnimation(Paleta.reduzir ? .easeOut(duration: 0.15) : Paleta.mola) { e.hover = nil; e.pagina = p } }
}

// MARK: - O mostrador (direção escolhida, docs/design-v4.md)

/// A frota como um mostrador do Apple Watch que nasce do notch: o Mac principal no meio, com os anéis de
/// Atividade; os outros Macs em órbita; os agentes e as contas de IA como complicações em cima; embaixo, tudo que
/// está conectado no Mac em foco; e uma legenda que diz com precisão o que está sob o mouse, ou o que mais pede atenção.
struct Mostrador: View {
    let e: Estado
    @ObservedObject var ilha: EstadoIlha
    let cfg: Config
    @ObservedObject var pergunta: Pergunta
    @ObservedObject var copiados: Copiados
    let legenda: Bool
    let abrir: (String) -> Void
    static let cartoes: Set<String> = ["email", "orca", "sincronizacao"]

    var body: some View {
        let on = e.maquinas.filter { $0.medidas != nil }, off = e.maquinas.filter { $0.medidas == nil }
        let foco = on.first { "mac:" + ($0.nome ?? "") == ilha.hover } ?? on.first  // conectados do Mac sob o mouse; senão a central
        let aps = aparelhos(foco, nomes: cfg.aparelhos)
        let r = Paleta.respiro
        VStack(spacing: 0) {
            ForEach(Array(linhas().enumerated()), id: \.element) { i, linha in
                bloco(linha, on: on, off: off, aps: aps, foco: foco).padding(.top, i == 0 ? 0 : linha == ["macs"] ? 4 * r : 12 * r)
                    .modifier(Entrada(onda: i, aberta: ilha.aberta))
            }
            legendaView(on: on, off: off, aps: aps).frame(height: 16).padding(.top, 12 * r).modifier(Entrada(onda: 6, aberta: ilha.aberta))
        }
        .frame(width: 584)  // + 2 × 20 de margem = 624, grade de 8
        .animation(.easeOut(duration: 0.15), value: ilha.hover)
    }

    var agentes: [Agente] { cfg.modulos.agentes ? e.agentes ?? [] : [] }
    var contas: [Conta] { cfg.modulos.ia ? e.contas ?? [] : [] }

    func visivel(_ b: String) -> Bool {
        switch b {
        case "topo": return !agentes.isEmpty || !contas.isEmpty
        case "macs": return cfg.modulos.macs && (!e.maquinas.isEmpty || !cfg.maquinas.isEmpty)
        case "servidores": return cfg.modulos.servidores && !(e.servidores ?? []).isEmpty
        case "email": return cfg.modulos.email && e.email != nil
        case "orca": return cfg.modulos.orca && e.orca?.aberto == true
        case "sincronizacao": return cfg.modulos.sincronizacao && e.sincronizacao != nil
        case "pergunta": return cfg.modulos.pergunta && cfg.ia.contains { !$0.perguntar.isEmpty && $0.visivel }
        case "copiados": return cfg.modulos.copiados
        default: return false
        }
    }

    /// As linhas da gaveta na ordem dos Ajustes. E-mail, Orca e Sincronização vizinhos dividem uma linha (até 3 cartões).
    /// No Light, servidores e cartões viram ícones e vizinhos dividem uma fileira só.
    func linhas() -> [[String]] {
        let junta = Paleta.leve ? Mostrador.cartoes.union(["servidores"]) : Mostrador.cartoes, maximo = Paleta.leve ? 4 : 3
        var r: [[String]] = []
        for b in cfg.modulos.ordem where visivel(b) {
            if junta.contains(b), let u = r.last, u.allSatisfy(junta.contains), u.count < maximo { r[r.count - 1].append(b) } else { r.append([b]) }
        }
        return r
    }

    @ViewBuilder func bloco(_ linha: [String], on: [Maquina], off: [Maquina], aps: [Aparelho], foco: Maquina?) -> some View {
        switch linha.count == 1 ? linha[0] : "linha" {
        case "topo": topo
        case "macs": macs(on: on, off: off, aps: aps, foco: foco)
        case "servidores": servidores
        case "pergunta": BlocoPergunta(p: pergunta, contas: cfg.ia.filter { !$0.perguntar.isEmpty && $0.visivel }, uso: e.contas ?? [], abrir: abrir)
        case "copiados": BlocoCopiados(c: copiados, luz: luz)
        default:
            if Paleta.leve {
                HStack(spacing: 14) {  // no Light, cada cartão (e cada servidor) vira o ícone com o sinal
                    ForEach(linha, id: \.self) { c in if c == "servidores" { iconesServidores } else { icone(c) } }
                }
            } else {
                let n = CGFloat(linha.count), w = (584 - 10 * (n - 1)) / n
                HStack(spacing: 10) {
                    ForEach(linha, id: \.self) { c in cartao(c, compacto: linha.count > 1).frame(width: w) }
                }
            }
        }
    }

    /// Light: e-mail, Orca e sincronização como pratos redondos; o ponto diz o estado, os números vão pra legenda no hover.
    @ViewBuilder func icone(_ c: String) -> some View {
        switch c {
        case "email":
            if let x = e.email {
                PratoSinal(sinal: x.problema != nil ? Paleta.ambar : x.naoLidos > 0 ? Paleta.ciano : nil) { Prato(simbolo: "envelope.fill", cor: Paleta.secundario) }
                    .opacity(luz("email")).contentShape(Rectangle()).alvo("email").onTapGesture { abrir("email") }
            }
        case "orca":
            if let o = e.orca {
                PratoSinal(sinal: (o.esperando ?? 0) > 0 ? Paleta.ciano : nil) { Image(nsImage: iconeApp("/Applications/Orca.app")).resizable().scaledToFit().padding(2) }
                    .opacity(luz("orca")).contentShape(Rectangle()).alvo("orca").onTapGesture { abrirOrca() }
            }
        default:
            if let s = e.sincronizacao {
                PratoSinal(sinal: s.nivel >= 1 ? Paleta.ambar : nil) { SetaSinc(s: s, tamanho: 34) }
                    .opacity(luz("sinc")).contentShape(Rectangle()).alvo("sinc").onTapGesture { abrir("sinc") }
            }
        }
    }

    @ViewBuilder func cartao(_ c: String, compacto: Bool) -> some View {
        switch c {
        case "email":
            if let x = e.email { CardEmail(x: x, compacto: compacto).opacity(luz("email")).contentShape(Rectangle()).alvo("email").onTapGesture { abrir("email") } }
        case "orca":
            if let o = e.orca { CardOrca(o: o, compacto: compacto).opacity(luz("orca")).contentShape(Rectangle()).alvo("orca").onTapGesture { abrirOrca() } }
        default:
            if let s = e.sincronizacao { CardSinc(s: s, compacto: compacto).opacity(luz("sinc")).contentShape(Rectangle()).alvo("sinc").onTapGesture { abrir("sinc") } }
        }
    }

    var topo: some View {
        HStack(alignment: .top, spacing: 0) {
            if agentes.count == 1, let g = agentes.first, !Paleta.leve {
                ComplicacaoAgente(g: g, foto: foto(g)).opacity(luz("agente:" + (g.id ?? g.nome)))
                    .contentShape(Rectangle()).alvo("agente:" + (g.id ?? g.nome)).onTapGesture { abrir("agente:" + (g.id ?? g.nome)) }
            } else if !agentes.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(agentes.prefix(agentes.count > 5 ? 4 : 5).enumerated()), id: \.offset) { _, g in
                        AvatarAgente(g: g, foto: foto(g)).opacity(luz("agente:" + (g.id ?? g.nome)))
                            .contentShape(Rectangle()).alvo("agente:" + (g.id ?? g.nome)).onTapGesture { abrir("agente:" + (g.id ?? g.nome)) }
                    }
                    if agentes.count > 5 { MaisAgentes(n: agentes.count - 4) }
                }.frame(width: 300, alignment: .leading)
            }
            Spacer(minLength: 24)
            HStack(spacing: 12) {
                ForEach(contas, id: \.rotulo) { c in
                    GaugeConta(c: c).opacity(luz("conta:" + c.rotulo)).contentShape(Rectangle()).alvo("conta:" + c.rotulo)
                        .onTapGesture { if c.semLogin == true { abrirOrca() } else { abrir("conta:" + (c.id ?? c.rotulo)) } }
                }
            }
        }
    }

    @ViewBuilder func macs(on: [Maquina], off: [Maquina], aps: [Aparelho], foco: Maquina?) -> some View {
        let sats = Array(on.dropFirst().prefix(4)), esq = sats.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).reversed()
        let dir = sats.enumerated().filter { $0.offset % 2 == 1 }.map(\.element), lado = CGFloat(max(esq.count, dir.count)) * 104
        VStack(spacing: 0) {
            if let h = on.first {
                HStack(alignment: .top, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) { ForEach(Array(esq), id: \.nome) { satelite($0) } }.frame(width: lado, alignment: .trailing)
                    Heroi(q: h).opacity(luz("mac:" + (h.nome ?? ""))).contentShape(Rectangle())
                        .alvo("mac:" + (h.nome ?? "")).onTapGesture { abrir("mac:" + (h.nome ?? "")) }.editavel("editar:mac:" + (h.id ?? ""), abrir).frame(width: 176)
                    HStack(alignment: .top, spacing: 0) { ForEach(dir, id: \.nome) { satelite($0) } }.frame(width: lado, alignment: .leading)
                }
            } else {
                Vazio(texto: e.barra.contains("parado") ? t("Coletor parado · reiniciando") : off.isEmpty ? t("Coletando a frota…") : t("Nenhum Mac respondeu"))
            }
            HStack(alignment: .top, spacing: 0) {
                // a faixa inteira é UMA peça por Mac: quando o foco muda de Mac, ela troca de uma vez (sem item misturado)
                HStack(alignment: .top, spacing: 0) {
                    // a rede (com o tráfego) fica sempre, no fim; os outros enchem o resto das 7 vagas
                    let rede = aps.filter { $0.net != nil }, faixa = Array(aps.filter { $0.net == nil }.prefix(7 - rede.count)) + rede
                    ForEach(faixa) { a in Dispositivo(a: a).opacity(luz("ap:" + a.id)).alvo("ap:" + a.id).editavel("editar:ap:" + a.id, abrir) }
                }.id(foco?.nome ?? "").transition(.troca)
                Spacer(minLength: 16)
                if !off.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(off, id: \.nome) { q in IconeDispositivo(valor: q.modelo ?? "", tamanho: 16, prato: false).opacity(0.35) }
                        if !Paleta.leve { Text(t("{0} offline", off.count)).font(.system(size: 11)).foregroundStyle(Paleta.terciario).padding(.leading, 2) }
                    }.padding(.top, 8).contentShape(Rectangle()).alvo("offline")
                }
            }.frame(height: 48, alignment: .top).padding(.top, 16)
        }
    }

    @ViewBuilder var servidores: some View {
        if Paleta.leve { HStack(spacing: 14) { iconesServidores }.frame(maxWidth: .infinity) } else { servidoresFull(e.servidores ?? []) }
    }

    @ViewBuilder var iconesServidores: some View {
                ForEach(e.servidores ?? [], id: \.nome) { s in
                    PratoSinal(sinal: !s.online ? Paleta.estado(2) : s.alerta.map { Paleta.estado($0.nivel) }) {
                        IconeDispositivo(valor: cfg.servidores.first { $0.id == s.id }?.icone.nilSeVazio ?? "sf:server.rack", tamanho: 34)
                    }.opacity(s.online ? luz("servidor:" + (s.id ?? s.nome)) : 0.5).contentShape(Rectangle())
                        .alvo("servidor:" + (s.id ?? s.nome)).onTapGesture { if s.online { abrir("servidor:" + (s.id ?? s.nome)) } }
                }
    }

    func servidoresFull(_ ss: [Servidor]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(188), spacing: 10), count: 3), alignment: .leading, spacing: 10) {
            ForEach(ss, id: \.nome) { s in
                TileServidor(s: s, icone: cfg.servidores.first { $0.id == s.id }?.icone ?? "").opacity(luz("servidor:" + (s.id ?? s.nome))).contentShape(Rectangle())
                    .alvo("servidor:" + (s.id ?? s.nome)).onTapGesture { if s.online { abrir("servidor:" + (s.id ?? s.nome)) } }
                    .editavel("editar:srv:" + (s.id ?? ""), abrir)
            }
        }
    }

    func foto(_ g: Agente) -> String? { ConfigStore.foto(cfg.agentes.first { $0.id == g.id }) ?? g.avatar }

    func satelite(_ q: Maquina) -> some View {
        Satelite(q: q).opacity(luz("mac:" + (q.nome ?? ""))).contentShape(Rectangle())
            .alvo("mac:" + (q.nome ?? "")).onTapGesture { abrir("mac:" + (q.nome ?? "")) }.editavel("editar:mac:" + (q.id ?? ""), abrir).frame(width: 104)
    }

    /// Foco: o que está sob o mouse fica aceso; os vizinhos do MESMO grupo (Macs, contas, aparelhos) esmaecem.
    func luz(_ id: String) -> Double {
        guard let h = ilha.hover, h != id else { return 1 }
        let g = { (s: String) in s.split(separator: ":").first.map(String.init) ?? s }
        return g(h) == g(id) ? 0.4 : 1
    }

    /// Uma linha, sempre no mesmo lugar (nada pula): o que está sob o mouse; parado, o que mais pede atenção.
    @ViewBuilder func legendaView(on: [Maquina], off: [Maquina], aps: [Aparelho]) -> some View {
        let (texto, cor): (String, Color) = {
            let h = ilha.hover ?? ""
            if h.hasPrefix("mac:"), let q = on.first(where: { "mac:" + ($0.nome ?? "") == h }), let md = q.medidas {
                let nums = Paleta.v.metricas.map { nomeMetrica($0) + " " + md.texto($0) }.joined(separator: "  ")
                return ("\(q.nome ?? "")  ·  " + nums + (q.alerta.map { "  ·  \($0.texto)" } ?? ""),
                        q.alerta.map { Paleta.estado($0.nivel) } ?? Paleta.secundario)
            }
            if h.hasPrefix("agente:"), let g = agentes.first(where: { "agente:" + ($0.id ?? $0.nome) == h }) {
                return (resumoAgente(g) + "  ·  " + t("clique pra ver tudo"), g.nivel >= 1 ? Paleta.estado(g.nivel) : Paleta.secundario)
            }
            if h.hasPrefix("servidor:"), let s = (e.servidores ?? []).first(where: { "servidor:" + ($0.id ?? $0.nome) == h }) {
                guard let md = s.medidas else { return ("\(s.nome)  ·  " + t("fora do ar ({0})", s.erro ?? t("sem resposta")), Paleta.estado(2)) }
                return ("\(s.nome)  ·  CPU \(md.cpu)%  RAM \(md.ram)%  " + t("disco {0}%", md.disco) + (s.alerta.map { "  ·  \($0.texto)" } ?? ""),
                        s.alerta.map { Paleta.estado($0.nivel) } ?? Paleta.secundario)
            }
            if h == "email", let x = e.email {
                return ((x.contas.count == 1 ? t("{0} não lidos em {1} conta", x.naoLidos, x.contas.count) : t("{0} não lidos em {1} contas", x.naoLidos, x.contas.count))
                        + (x.chegou.map { "  ·  " + t("chegou e-mail há {0} em {1}", $0.ha, $0.conta) } ?? "") + "  ·  " + t("clique pra ver os últimos"), Paleta.secundario)
            }
            if h == "orca", let o = e.orca {
                return (["Orca", t("{0} rodando", o.rodando ?? 0), t("{0} esperando você", o.esperando ?? 0), t("{0} pra revisar", o.revisar ?? 0),
                         ((o.automacoes ?? 0) == 1 ? t("{0} automação", 1) : t("{0} automações", o.automacoes ?? 0)), t("clique abre o Orca")].joined(separator: "  ·  "),
                        (o.esperando ?? 0) > 0 ? Paleta.ciano : Paleta.secundario)
            }
            if h == "sinc", e.sincronizacao != nil { return (t("Drive, rclone e backups") + "  ·  " + t("clique pra ver tudo"), Paleta.secundario) }
            if h.hasPrefix("conta:"), let c = contas.first(where: { "conta:" + $0.rotulo == h }) {
                if c.semLogin == true {
                    let orca = FileManager.default.fileExists(atPath: "/Applications/Orca.app") ? "  ·  " + t("clique pra entrar pelo Orca") : ""
                    return ("\(c.rotulo)  ·  \(c.ferramenta ?? "")  ·  " + t("sem login") + orca, Paleta.secundario)
                }
                return c.nivel < 0 ? ("\(c.rotulo)  ·  \(c.ferramenta ?? "")  ·  " + c.card.joined(separator: "  ·  "), Paleta.secundario)
                    : ("\(c.rotulo)  ·  \(c.ferramenta ?? "")  ·  " + usoJanela(c) + "  ·  " + t("volta {0}", c.reset ?? "—") + "  ·  " + t("clique pra ver por modelo"),
                       c.nivel >= 1 ? Paleta.estado(c.nivel) : Paleta.secundario)
            }
            if h.hasPrefix("ap:"), let a = aps.first(where: { "ap:" + $0.id == h }) { return (a.detalhe, Paleta.secundario) }
            if h.hasPrefix("clip:"), let i = copiados.itens.first(where: { "clip:" + $0.id.uuidString == h }) { return (legendaCopiado(i), Paleta.secundario) }
            if h == "offline" { return (t("Fora do ar: {0}", off.map { $0.nome ?? "" }.joined(separator: ", ")), Paleta.secundario) }
            if legenda { return ("", Paleta.terciario) }
            let a = atencao(e)
            guard let p = a.first else { return (Paleta.leve ? "" : t("Tudo em ordem"), Paleta.terciario) }
            return (p.texto + (a.count > 1 ? "  ·  +\(a.count - 1)" : ""), Paleta.estado(p.nivel))
        }()
        Group {
            if legenda && ilha.hover == nil { Legenda(visual: cfg.visual) } else if ilha.hover == "ap:rede", let a = aps.first(where: { $0.id == "rede" }) {
                LegendaRede(a: a)
            } else {
                Text(texto).font(.system(size: 11).monospacedDigit()).foregroundStyle(cor).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(texto)
        .transition(.troca)
    }
}

/// O que mais pede atenção, do pior pro menos grave (é o que a legenda mostra quando nada está sob o mouse).
func atencao(_ e: Estado) -> [(nivel: Int, texto: String)] {
    var r: [(nivel: Int, texto: String)] = []
    for q in e.maquinas where q.medidas != nil {
        if let a = q.alerta { r.append((a.nivel, t("{0} no {1}", a.texto, q.curto ?? q.nome ?? ""))) }
        if q.nivel >= 1 { r.append((q.nivel, t("{0} muito exigido", q.nome ?? ""))) }
    }
    for s in e.servidores ?? [] {
        if !s.online { r.append((2, t("{0} fora do ar ({1})", s.nome, s.erro ?? t("sem resposta")))) }
        if let a = s.alerta { r.append((a.nivel, t("{0} no {1}", a.texto, s.nome))) }
    }
    for g in e.agentes ?? [] where g.nivel >= 1 {
        if !g.noAr { r.append((2, "\(g.nome): \(t(g.estado))")) }
        for c in g.canais ?? [] where c.nivel >= 1 { r.append((c.nivel, t("{0} de {1} {2}", c.nome, g.nome, c.estado))) }
        for p in g.problemas ?? [] { r.append((p.nivel, "\(g.nome): " + problema(p.titulo))) }
    }
    if let p = e.email?.problema { r.append((1, t("E-mail: {0}", p))) }
    if let n = e.orca?.esperando, n > 0 { r.append((1, "Orca: " + (n == 1 ? t("{0} agente esperando você", n) : t("{0} agentes esperando você", n)))) }
    if let p = e.sincronizacao?.problema { r.append((1, p)) }
    for c in e.contas ?? [] where c.nivel >= 1 { r.append((c.nivel, "\(c.rotulo): " + usoJanela(c) + " · " + t("volta {0}", c.reset ?? "—"))) }
    return r.enumerated().sorted { ($0.element.nivel, -$0.offset) > ($1.element.nivel, -$1.offset) }.map(\.element)
}

/// Título do cron-watchdog em português de gente: "Execução não concluiu: X" vira "Cron falhando: X".
func problema(_ s: String) -> String {
    s.hasPrefix("Execução não concluiu: ") ? t("Cron falhando: {0}", s.dropFirst(23)) : s.hasSuffix(" falhou") ? t("Cron falhando: {0}", s.dropLast(7)) : s
}

func resumoAgente(_ g: Agente) -> String {
    ["\(g.nome) \(t(g.estado))",
     (g.canais ?? []).isEmpty ? nil : (g.canais ?? []).map { $0.nome + ($0.nivel >= 1 ? " \($0.estado)" : "") }.joined(separator: ", "),
     g.atividade.map { t("{0} há {1}", $0.tipo ?? t("atividade"), $0.ha) },
     g.crons.map { ($0.ativos == 1 ? t("{0} cron", 1) : t("{0} crons", $0.ativos)) + ($0.falhando > 0 ? " " + t("({0} falhando)", $0.falhando) : "") }].compactMap { $0 }.joined(separator: "  ·  ")
}

/// "80% das 5 horas" ou "80% da semana": o uso da conta de IA na janela que mais pesa.
func usoJanela(_ c: Conta) -> String { c.janela == "5h" ? t("{0}% das 5 horas", c.pct) : t("{0}% da semana", c.pct) }

/// Legenda mínima: só na primeira vez que a gaveta abre (depois os números aparecem no hover).
struct Legenda: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: visual.estilo.aneis[i].cor)).frame(width: 6, height: 6)
                    Text(nomeMetrica(visual.metricas.indices.contains(i) ? visual.metricas[i] : "cpu")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Paleta.secundario)
                }
            }
            Text(t("anéis de fora pra dentro · passe o mouse pra ver os números")).font(.system(size: 11)).foregroundStyle(Paleta.terciario)
        }
    }
}

/// O Mac central: anéis grandes (CPU fora, GPU meio, RAM dentro), o desenho do aparelho dentro, selo se tiver alerta.
struct Heroi: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let q: Maquina
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Aneis(md: q.medidas!, nv: q.niveis, diametro: 128, linha: 6)
                IconeDispositivo(valor: q.modelo ?? "", tamanho: 56)
                if let a = q.alerta { Selo(a: a, tamanho: 24).position(x: 110, y: 110) }
            }.frame(width: 128, height: 128)
            if !Paleta.leve {  // Light: só o mostrador; o nome e os números vêm na legenda, no hover
                Text(q.nome ?? "").font(.system(size: 15, weight: .semibold)).lineLimit(1).padding(.top, 8).transition(.opacity)
                Numeros(v: Paleta.v.metricas.map { q.medidas!.valor($0) }, tamanho: 11).padding(.top, 4).transition(.opacity)
            }
        }
    }
}

/// Mac em órbita: mesmos anéis, menores; o nome pode quebrar em duas linhas (nada de "…" no nome do Mac).
struct Satelite: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let q: Maquina
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Aneis(md: q.medidas!, nv: q.niveis, diametro: 72, linha: 3.5)
                IconeDispositivo(valor: q.modelo ?? "", tamanho: 30)
                if let a = q.alerta { Selo(a: a, tamanho: 16).position(x: 62, y: 62) }
            }.frame(width: 72, height: 72)
            if !Paleta.leve {
                Text(q.nome ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(Paleta.secundario)
                    .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 8).transition(.opacity)
            }
        }.padding(.top, Paleta.leve ? 28 : 28)  // centro dos satélites na altura do centro do mostrador
    }
}

/// "● CPU 9  ● GPU 0  ● RAM 53": o ponto colorido liga o número ao anel e o nome diz qual é (sem depender da legenda).
struct Numeros: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let v: [Int], tamanho: CGFloat
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 3) {
                    Circle().fill(Paleta.metricas[i]).frame(width: 5, height: 5)
                    Text(Paleta.nomes[i]).font(.system(size: tamanho - 1, weight: .semibold)).foregroundStyle(Paleta.terciario)
                    Text("\(v[i])").font(.system(size: tamanho, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Paleta.secundario).contentTransition(.numericText(value: Double(v[i])))
                }
            }
        }
    }
}

/// Conta de IA como complicação circular: logo da ferramenta no anel de uso, o % embaixo na cor do nível.
struct GaugeConta: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let c: Conta
    var body: some View {
        let sem = c.nivel < 0, semLogin = c.semLogin == true
        VStack(spacing: 4) {
            ZStack {
                Anel(valor: sem ? 0 : c.pct, cor: Paleta.corConta(c), diametro: 40, linha: 3)
                Logo(c: c, tamanho: 20).opacity(semLogin ? 0.4 : 1)
            }.frame(width: 40, height: 40)
            if !Paleta.leve {
                Text(semLogin ? t("sem login") : sem ? "—" : "\(c.pct)%").font(.system(size: semLogin ? 10 : 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(c.nivel >= 1 ? Paleta.estado(c.nivel) : semLogin ? Paleta.terciario : Paleta.secundario).lineLimit(1)
                    .contentTransition(.numericText(value: Double(c.pct)))
            }
        }.frame(width: semLogin && !Paleta.leve ? 56 : 48)
    }
}

var avatares: [String: NSImage] = [:]

/// Um agente sozinho, como complicação: a foto, o nome, os canais (o ponto é o estado) e a última coisa que aconteceu.
struct ComplicacaoAgente: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let g: Agente, foto: String?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FotoAgente(caminho: foto, nome: g.nome, tamanho: 32).opacity(g.noAr ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.nome).font(.system(size: 12, weight: .semibold))
                if g.noAr {
                    if !(g.canais ?? []).isEmpty {
                        HStack(spacing: 10) { ForEach((g.canais ?? []).prefix(3), id: \.nome) { c in Canal(nome: c.nome, nivel: c.nivel) } }
                    }
                    if let p = g.problemas?.first {
                        Text(problema(p.titulo)).font(.system(size: 11)).foregroundStyle(Paleta.estado(p.nivel)).lineLimit(1)
                    } else {
                        Text(g.atividade.map { t("{0} · há {1}", $0.tipo ?? t("atividade"), $0.ha) } ?? g.crons.map { t("{0} crons ativos", $0.ativos) } ?? t("no ar"))
                            .font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(1)
                    }
                } else {
                    Text(g.estado == "sem acesso" ? t("sem acesso ao agente") : t(g.estado))
                        .font(.system(size: 11)).foregroundStyle(g.nivel >= 1 ? Paleta.estado(2) : Paleta.terciario)
                }
            }
        }.frame(width: 300, alignment: .leading)
    }
}

/// Vários agentes: uma fileira de fotos, como no AirDrop. Aro na cor do estado quando algo está errado; parado esmaece.
struct AvatarAgente: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let g: Agente, foto: String?
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                FotoAgente(caminho: foto, nome: g.nome, tamanho: 38).opacity(g.noAr || g.nivel < 0 ? 1 : 0.45)
                if g.nivel >= 1 { Circle().stroke(Paleta.estado(g.nivel), lineWidth: 2).frame(width: 44, height: 44) }
                if g.nivel < 0 { Circle().stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 44, height: 44) }
            }.frame(width: 46, height: 46)
            if !Paleta.leve {
                Text(g.nome).font(.system(size: 10, weight: .medium)).foregroundStyle(g.nivel >= 1 ? Paleta.estado(g.nivel) : Paleta.secundario)
                    .lineLimit(1).frame(width: 54)
            }
        }
    }
}

struct MaisAgentes: View {
    let n: Int
    var body: some View {
        VStack(spacing: 4) {
            ZStack { Circle().fill(Color.white.opacity(0.1)); Text("+\(n)").font(.system(size: 12, weight: .semibold, design: .rounded)) }.frame(width: 38, height: 38)
                .frame(width: 46, height: 46)
            Text(t("mais")).font(.system(size: 10)).foregroundStyle(Paleta.terciario)
        }
    }
}

/// Servidor como os módulos pequenos da Central de Controle: ícone no prato, nome, CPU · RAM · disco; o alerta, se houver.
struct TileServidor: View {
    let s: Servidor
    var icone = ""
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                IconeDispositivo(valor: icone.isEmpty ? "sf:server.rack" : icone, tamanho: 30)
                if let a = s.alerta { Circle().fill(Paleta.estado(a.nivel)).frame(width: 8, height: 8).offset(x: 11, y: -11) }
            }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.nome).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let md = s.medidas {
                    if let a = s.alerta {
                        Text(a.texto).font(.system(size: 10)).foregroundStyle(Paleta.estado(a.nivel)).lineLimit(1)
                    } else {
                        let disco = Image(systemName: "internaldrive")
                        Text("CPU \(md.cpu) · RAM \(md.ram) · \(disco) \(md.disco)%")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Paleta.terciario).lineLimit(1)
                    }
                } else {
                    Text(t("fora do ar")).font(.system(size: 10)).foregroundStyle(Paleta.estado(2))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(Paleta.contraste ? 0.12 : 0.05)))
        .opacity(s.online ? 1 : 0.6)
    }
}

/// Moldura comum dos cartões (e-mail, Orca, sincronização): ícone, título, valor à direita e a linha do que está acontecendo.
struct Cartao<Icone: View, Direita: View>: View {
    let titulo: String, linha: String, corLinha: Color, compacto: Bool
    @ViewBuilder let icone: () -> Icone
    @ViewBuilder let direita: () -> Direita
    var body: some View {
        HStack(spacing: 10) {
            icone().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(titulo).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                    direita()
                }
                Text(linha).font(.system(size: 11).monospacedDigit()).foregroundStyle(corLinha).lineLimit(1).truncationMode(.tail)
            }
            if !compacto { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Paleta.terciario) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(Paleta.contraste ? 0.12 : 0.05)))
    }
}

struct Prato: View {
    let simbolo: String, cor: Color
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(Paleta.contraste ? 0.16 : 0.08))
            Image(systemName: simbolo).font(.system(size: 12, weight: .medium)).foregroundStyle(cor)
        }
    }
}

struct CardEmail: View {
    let x: Email, compacto: Bool
    var body: some View {
        let ok = x.problema == nil
        Cartao(titulo: t("E-mail"), linha: !ok ? (x.problema ?? "") : x.chegou.map { t("chegou há {0} em {1}", $0.ha, $0.conta) } ?? t("nada novo desde a última verificação"),
               corLinha: ok ? Paleta.terciario : Paleta.ambar, compacto: compacto) {
            Prato(simbolo: "envelope.fill", cor: Paleta.secundario)
        } direita: {
            Text("\(x.naoLidos)").font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Paleta.secundario)
                .contentTransition(.numericText(value: Double(x.naoLidos)))
        }
    }
}

struct CardOrca: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let o: Orca, compacto: Bool
    var body: some View {
        let esp = o.esperando ?? 0
        Cartao(titulo: "Orca", linha: esp > 0 ? (esp == 1 ? t("{0} agente esperando você", esp) : t("{0} agentes esperando você", esp))
                : t("{0} rodando", o.rodando ?? 0) + " · " + t("{0} pra revisar", o.revisar ?? 0), corLinha: esp > 0 ? Paleta.ciano : Paleta.terciario, compacto: compacto) {
            Image(nsImage: iconeApp("/Applications/Orca.app")).resizable().scaledToFit().padding(1)
        } direita: {
            if esp > 0 {
                Text("\(esp)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Paleta.ciano))
            } else {
                Text(t("{0} ativos", o.workspaces ?? 0)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Paleta.terciario)
            }
        }
    }
}

/// Abre o Orca (= `open -a Orca`): card do Orca e conta de IA sem login (é no Orca que se entra na conta).
func abrirOrca() {
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca") ?? URL(string: "file:///Applications/Orca.app") {
        NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Pergunta rápida: escolhe a conta pelo logo, digita, Enter. A resposta (Markdown simples) aparece embaixo, com copiar.
struct BlocoPergunta: View {
    @ObservedObject var p: Pergunta
    let contas: [CIA], uso: [Conta]
    let abrir: (String) -> Void
    var body: some View {
        // sem login (teste barato do coletor, cache de 5 min): marcada, nunca escolhida por padrão; o clique abre o Orca pra entrar
        let semLogin = { (c: CIA) in uso.first { $0.id == c.id }?.semLogin == true }
        let escolhida = contas.first { $0.id == p.conta && !semLogin($0) } ?? contas.first { !semLogin($0) } ?? contas.first
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(contas) { c in
                        let sem = semLogin(c)
                        Button { if sem { abrirOrca() } else { p.conta = c.id } } label: {
                            HStack(spacing: 3) {
                                LogoApp(caminhos: c.app, ferramenta: c.ferramenta, tamanho: 18)
                                    .padding(3).background(Circle().fill(Color.white.opacity(c.id == escolhida?.id && !sem ? 0.18 : 0)))
                                    .opacity(sem ? 0.35 : c.id == escolhida?.id ? 1 : 0.5)
                                if sem { Text(t("{0} sem login", c.nome)).font(.system(size: 10, weight: .medium)).foregroundStyle(Paleta.terciario).fixedSize() }
                            }
                        }.buttonStyle(.plain).help(sem ? t("{0} está sem login · clique pra entrar pelo Orca", c.nome) : "\(c.nome) · \(c.ferramenta)")
                    }
                }
                CampoPergunta(texto: $p.texto, foco: $p.foco) { if let c = escolhida { p.enviar(c) } }.frame(height: 20)
                if p.rodando { ProgressView().controlSize(.small) } else {
                    Button { if let c = escolhida { p.enviar(c) } } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)).foregroundStyle(p.texto.isEmpty ? Paleta.terciario : Paleta.primario)
                    }.buttonStyle(.plain).disabled(p.texto.isEmpty)
                }
                Button { abrir("historico") } label: { Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                    .buttonStyle(.plain).help(t("Últimas 10 perguntas"))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(Paleta.contraste ? 0.14 : 0.07)))
            if let r = p.atual {
                RespostaView(r: r, limite: 120)
            }
        }
    }
}

/// Campo de uma linha que envia no Enter e aceita foco por código (o atalho global). NSTextField puro: o TextField do
/// SwiftUI, dentro do painel que não ativa o app, tratava o Enter como quebra de linha.
struct CampoPergunta: NSViewRepresentable {
    @Binding var texto: String
    @Binding var foco: Bool
    var dica = t("Pergunte rápido…")
    let enviar: () -> Void
    func makeNSView(context: Context) -> NSTextField {
        let t = NSTextField()
        t.isBordered = false
        t.drawsBackground = false
        t.focusRingType = .none
        t.font = .systemFont(ofSize: 13)
        t.textColor = .white
        t.placeholderAttributedString = NSAttributedString(string: dica, attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.45),
                                                                                                    .font: NSFont.systemFont(ofSize: 13)])
        t.cell?.usesSingleLineMode = true
        t.cell?.isScrollable = true
        t.delegate = context.coordinator
        return t
    }
    func updateNSView(_ t: NSTextField, context: Context) {
        if t.stringValue != texto { t.stringValue = texto }
        if foco {
            DispatchQueue.main.async {
                t.window?.makeKey()
                t.window?.makeFirstResponder(t)
                foco = false
            }
        }
    }
    func makeCoordinator() -> Coord { Coord(self) }
    final class Coord: NSObject, NSTextFieldDelegate {
        var pai: CampoPergunta
        init(_ p: CampoPergunta) { pai = p }
        func controlTextDidChange(_ n: Notification) { if let t = n.object as? NSTextField { pai.texto = t.stringValue } }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy s: Selector) -> Bool {
            if s == #selector(NSResponder.insertNewline(_:)) { pai.enviar(); return true }
            return false
        }
    }
}

/// Uma resposta: o texto em Markdown simples, quem respondeu e quanto levou, e o botão de copiar.
struct RespostaView: View {
    let r: Resposta, limite: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if r.erro.isEmpty {
                ScrollView {
                    Text((try? AttributedString(markdown: r.resposta, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(r.resposta))
                        .font(.system(size: 12)).foregroundStyle(Paleta.primario).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: limite).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(r.erro).font(.system(size: 12)).foregroundStyle(Paleta.ambar)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    let segundos = decimal(String(format: "%.1f", r.segundos))
                    Text("\(r.conta) · \(segundos) s").font(.system(size: 10)).foregroundStyle(Paleta.terciario)
                    if let n = r.nota { Text(n).font(.system(size: 10)).foregroundStyle(Paleta.terciario.opacity(0.8)) }
                }
                Spacer()
                if r.erro.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(r.resposta, forType: .string)
                    } label: { Label(t("Copiar"), systemImage: "doc.on.doc").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(Paleta.secundario)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(Paleta.contraste ? 0.1 : 0.04)))
    }
}

/// Canal de um agente: o ponto é o estado (branco conectado, âmbar meio caído, vermelho fora); o nome não muda.
struct Canal: View {
    let nome: String, nivel: Int
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(nivel < 0 ? Color.white.opacity(0.25) : nivel == 0 ? Paleta.secundario : Paleta.estado(nivel)).frame(width: 5, height: 5)
            Text(nome).font(.system(size: 11)).foregroundStyle(nivel >= 1 ? Paleta.estado(nivel) : Paleta.secundario)
        }
    }
}

/// Vazio elegante: os três trilhos sem valor e uma frase calma (nunca uma tela preta muda).
struct Vazio: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let texto: String
    var body: some View {
        VStack(spacing: 10) {
            ZStack { ForEach(0..<3, id: \.self) { i in Anel(valor: 0, cor: Paleta.metricas[i], diametro: 128 - CGFloat(i) * 16, linha: 6, estilo: Paleta.v.estilo.aneis[i]) } }
                .frame(width: 128, height: 128)
            Text(texto).font(.system(size: 12)).foregroundStyle(Paleta.terciario)
        }.frame(maxWidth: .infinity).padding(.top, 8)
    }
}

// MARK: - Sincronização

/// A seta da sincronização num prato redondo: sobe (enviando) ou desce (baixando), andando devagar enquanto dura.
/// Parada, o símbolo de sincronizar, âmbar se algum backup não rodou. Reduzir movimento: a seta não anda.
struct SetaSinc: View {
    let s: Sinc, tamanho: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(Paleta.contraste ? 0.16 : 0.08))
            if let seta = s.seta {
                let dy = (seta == "desce" ? 1 : -1) * tamanho * 0.08
                Image(systemName: seta == "desce" ? "arrow.down" : "arrow.up").font(.system(size: tamanho * 0.42, weight: .semibold))
                    .foregroundStyle(Paleta.primario)
                    .phaseAnimator(Paleta.reduzir ? [false] : [false, true]) { v, f in v.offset(y: f ? dy : 0).opacity(f ? 0.4 : 1) }
                        animation: { _ in .easeInOut(duration: 0.9) }
            } else {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: tamanho * 0.4, weight: .medium))
                    .foregroundStyle(s.nivel >= 1 ? Paleta.ambar : Paleta.secundario)
            }
        }.frame(width: tamanho, height: tamanho).clipShape(Circle())
    }
}

/// O card da sincronização no mostrador: a seta; na 1ª linha o título e, à direita, o que deu errado (âmbar); na 2ª,
/// o que está acontecendo agora (ou que está tudo em dia) e, quando o rclone conta, a barra de progresso.
struct CardSinc: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let s: Sinc
    var compacto = false
    var progresso: Progresso? { s.rclone.first(where: { $0.progresso != nil })?.progresso }
    func pct(_ pr: Progresso) -> some View {
        Text("\(pr.pct)%").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Paleta.secundario)
            .contentTransition(.numericText(value: Double(pr.pct)))
    }
    var body: some View {
        HStack(spacing: 10) {
            SetaSinc(s: s, tamanho: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Text(t("Sincronização")).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                    if let p = s.problema, !compacto { Text(p).font(.system(size: 11)).foregroundStyle(Paleta.ambar).lineLimit(1) }
                }
                HStack(spacing: 6) {
                    Text(compacto && s.problema != nil ? s.problema! : s.atividade ?? s.resumo).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(compacto && s.problema != nil ? Paleta.ambar : s.ativo ? Paleta.secundario : Paleta.terciario)
                        .lineLimit(1).truncationMode(compacto ? .tail : .middle)
                    // compacto (divide a linha com E-mail e Orca): o percentual desce pra cá e o título fica com a largura toda,
                    // senão "Sincronização" / "Sincronización" / "Synchronisation" saem cortados
                    if compacto, let pr = progresso { Spacer(minLength: 4); pct(pr) }
                }
            }
            Spacer(minLength: 8)
            if !compacto, let pr = progresso {  // a cópia que conta o progresso
                pct(pr)
                Barra(pct: pr.pct, largura: 72, cor: Paleta.ciano)
            }
            if !compacto { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Paleta.terciario) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(Paleta.contraste ? 0.12 : 0.05)))
    }
}

struct Barra: View {
    let pct: Int, largura: CGFloat, cor: Color
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(Paleta.contraste ? 0.22 : 0.1))
            Capsule().fill(cor).frame(width: largura * CGFloat(max(0, min(pct, 100))) / 100)
        }.frame(width: largura, height: 3)
    }
}

/// Página da sincronização: o Google Drive (o que sobe, o que desce, fila e erros), cada cópia do rclone rodando e os
/// LaunchAgents de backup (horário, última vez, ok/erro/não rodou).
struct PaginaSinc: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let s: Sinc, voltar: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Voltar(acao: voltar)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    SetaSinc(s: s, tamanho: 56)
                    Text(t("Sincronização")).font(.system(size: 15, weight: .semibold)).padding(.top, 12)
                    Text(s.seta == "sobe" ? t("enviando agora") : s.seta == "desce" ? t("baixando agora") : t("nada sincronizando agora"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Paleta.secundario).padding(.top, 2)
                    if let p = s.problema {
                        Text(p).font(.system(size: 11)).foregroundStyle(Paleta.ambar).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                }.frame(width: 168, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    Secao("Google Drive") {
                        if let d = s.drive {
                            Linha(t("Estado"), !d.app ? t("fechado") : d.subindo + d.baixando > 0 ? t("sincronizando") : d.emDia ? t("em dia") : t("conferindo a nuvem"),
                                  cor: d.app ? nil : Paleta.ambar)
                            Linha(t("Subindo"), "\(d.subindo)" + (d.fila > 0 ? " · " + t("{0} na fila", d.fila) : ""))
                            Linha(t("Baixando"), "\(d.baixando)")
                            Linha(t("Da nuvem, 10 min"), d.recebeu == 1 ? t("{0} alteração", d.recebeu) : t("{0} alterações", d.recebeu))
                            Linha(t("Último envio"), d.enviouHa.map { t("há {0}", $0) } ?? "—")
                            Linha(t("Erros na última hora"), "\(d.errosHora)", cor: d.errosHora > 0 ? Paleta.ambar : nil)
                            if let er = d.ultimoErro {
                                // er.tipo (coleta.py) chega cru: N_("download") N_("upload")
                                Text(t("Último erro há {0}: {1} {2}", er.quando, t(er.tipo), er.motivo == "CANCELLED" ? t("cancelado") : er.motivo.lowercased()))
                                    .font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(2)
                            }
                        } else {
                            Text(t("Google Drive não está neste Mac")).font(.system(size: 12)).foregroundStyle(Paleta.terciario)
                        }
                    }
                }.frame(width: 236, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    Secao("rclone") {
                        if s.rclone.isEmpty { Text(t("Nenhuma cópia rodando")).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                        ForEach(s.rclone, id: \.pid) { j in
                            VStack(alignment: .leading, spacing: 3) {
                                Linha(j.cmd, j.progresso.map { "\($0.pct)%" } ?? t("há {0}", j.ha))
                                Text("\(j.origem) → \(j.destino)").font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(1).truncationMode(.middle)
                                if let p = j.progresso {
                                    Barra(pct: p.pct, largura: 236, cor: Paleta.ciano).padding(.vertical, 2)
                                    Text(t("{0} de {1}", p.feito, p.total) + (p.eta.map { " · " + t("faltam {0}", $0) } ?? "")).font(.system(size: 11).monospacedDigit()).foregroundStyle(Paleta.terciario)
                                } else if !j.arquivos.isEmpty {
                                    Text(t("agora: {0}", j.arquivos.joined(separator: ", "))).font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                    Secao(t("Backups")) {
                        if s.backups.isEmpty { Text(t("Nenhum agente de backup")).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                        ForEach(s.backups, id: \.nome) { b in
                            VStack(alignment: .leading, spacing: 2) {
                                Linha(b.nome, estadoBackup(b), cor: b.estado == "erro" || b.estado == "atrasado" ? Paleta.ambar : nil)
                                Text([b.ultimo.map { t("última vez {0}", $0.hora) }, b.linha.isEmpty ? nil : b.linha].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(1)
                            }
                        }
                    }
                }.frame(width: 236, alignment: .leading)
            }
        }
    }

    func estadoBackup(_ b: Backup) -> String {
        switch b.estado {
        case "rodando": return t("rodando agora")
        case "erro": return t("erro (saída {0})", b.saida ?? 0)
        case "atrasado": return t("não rodou às {0}", b.horario ?? "?")
        default: return "ok" + (b.horario.map { " · \($0)" } ?? "")
        }
    }
}

// MARK: - Aparelhos conectados

/// Um aparelho conectado num Mac, pronto pra desenhar: ícone, rótulo curto embaixo e a frase completa da legenda.
struct Aparelho: Identifiable {
    let id: String; let tipo: String; var nome: String; var rotulo: String; var detalhe: String; let bateria: Int?
    var icone = ""  // da config (renomeado/ícone trocado); vazio = o símbolo do tipo
    var net: Net? = nil, local = false, tailscale = ""  // só o item "rede"
}

func simbolo(_ a: Aparelho) -> String {
    switch a.tipo {
    case "monitor": return "display"
    case "teclado": return "keyboard.fill"
    case "trackpad": return "rectangle.and.hand.point.up.left.fill"
    case "mouse": return "magicmouse.fill"
    case "fones": return a.nome.localizedCaseInsensitiveContains("max") ? "airpodsmax" : "airpodspro"
    case "caixa": return "hifispeaker.fill"
    case "som": return "speaker.wave.2.fill"
    case "disco": return "externaldrive.fill"
    case "hub": return "point.3.connected.trianglepath.dotted"
    case "tb": return "bolt.horizontal.fill"
    case "wifi": return "wifi"
    case "cabo": return "network"
    default: return "cable.connector"
    }
}

/// Tudo que está conectado num Mac, numa lista só: monitores, discos externos, Bluetooth, USB, Thunderbolt, saída de som
/// e a rede. Disco USB não se repete: aparece como o volume montado (com o espaço livre).
func aparelhos(_ q: Maquina?, rede: Bool = true, nomes: [String: CAparelho] = [:]) -> [Aparelho] {
    aparelhosBrutos(q, rede: rede).map { renomear($0, nomes[$0.id]) }
}

/// O nome e o ícone que o usuário escolheu (só na config) no lugar dos do sistema; o detalhe passa a dizer o nome novo.
func renomear(_ a: Aparelho, _ x: CAparelho?) -> Aparelho {
    guard let x = x else { return a }
    var b = a
    if !x.nome.isEmpty {
        if let r = b.detalhe.range(of: a.nome) { b.detalhe.replaceSubrange(r, with: x.nome) }
        b.nome = x.nome
    }
    b.icone = x.icone
    return b
}

func aparelhosBrutos(_ q: Maquina?, rede: Bool) -> [Aparelho] {
    guard let d = q?.detalhe else { return [] }
    var r: [Aparelho] = []
    if let c = d.conectados {
        for m in c.monitores {
            let nome = m.interno == true ? t("Tela embutida") : m.nome
            r.append(.init(id: "m" + m.nome, tipo: "monitor", nome: nome, rotulo: m.res ?? t("monitor"),
                           detalhe: [nome, m.res, m.hz.map { "\($0) Hz" }, m.principal == true ? t("principal") : nil].compactMap { $0 }.joined(separator: " · "), bateria: nil))
        }
        for x in c.discos ?? [] {
            r.append(.init(id: "d" + x.nome, tipo: "disco", nome: x.nome, rotulo: "\(x.livre) GB",
                           detalhe: "\(x.nome) · " + t("{0} GB livres de {1} GB", x.livre, x.total), bateria: nil))
        }
        for b in c.bluetooth {
            r.append(.init(id: "b" + b.nome, tipo: b.tipo ?? "", nome: b.nome, rotulo: b.bateria.map { "\($0)%" } ?? t("ligado"),
                           detalhe: "\(b.nome) · Bluetooth" + (b.bateria.map { " · " + t("bateria {0}%", $0) } ?? ""), bateria: b.bateria))
        }
        let armazenamento = { (n: String) in n.range(of: "ssd|storage|drive|disk|disco", options: [.regularExpression, .caseInsensitive]) != nil }
        for u in c.usb where u.hub != true && !(armazenamento(u.nome) && !(c.discos ?? []).isEmpty) {
            r.append(.init(id: "u" + u.nome, tipo: "usb", nome: u.nome, rotulo: u.vel ?? "USB",
                           detalhe: [u.nome, u.marca, u.vel].compactMap { $0 }.joined(separator: " · ") + " · USB", bateria: nil))
        }
        let hubs = c.usb.filter { $0.hub == true }
        if !hubs.isEmpty {
            let nome = hubs.count > 1 ? t("Dock USB") : t("Hub USB")
            r.append(.init(id: "hub", tipo: "hub", nome: nome, rotulo: hubs.count > 1 ? t("dock") : t("hub"),
                           detalhe: nome + " · " + (hubs.count > 1 ? t("{0} hubs", hubs.count) : t("{0} hub", hubs.count)) +
                               (Set(hubs.compactMap(\.marca)).first.map { " · \($0)" } ?? ""), bateria: nil))
        }
        for t in c.tb { r.append(.init(id: "t" + (t.nome ?? ""), tipo: "tb", nome: t.nome ?? "Thunderbolt", rotulo: "TB",
                                       detalhe: [t.nome, t.marca].compactMap { $0 }.joined(separator: " · ") + " · Thunderbolt", bateria: nil)) }
        if let a = c.audio, let n = a.nome {
            r.append(.init(id: "a", tipo: "som", nome: n, rotulo: a.via == "builtin" ? t("som") : String(n.prefix(8)), detalhe: t("Saída de som: {0}", n), bateria: nil))
        }
    }
    if rede, let rr = d.rede {
        let wifi = rr.hasPrefix("Wi-Fi")
        r.append(.init(id: "rede", tipo: wifi ? "wifi" : "cabo", nome: wifi ? "Wi-Fi" : t("Cabo"), rotulo: wifi ? "Wi-Fi" : t("cabo"),
                       detalhe: d.net.map { resumoRede($0, d.tailscale, ssid: nil) } ?? "\(rr) · Tailscale \(d.tailscale)", bateria: nil,
                       net: d.net, local: q?.local == true, tailscale: d.tailscale))
    }
    return r
}

/// Aparelho na faixa de baixo, como no widget de Baterias: ícone no prato, anel de bateria quando tem, rótulo curto.
struct Dispositivo: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let a: Aparelho
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.white.opacity(Paleta.contraste ? 0.16 : 0.08))
                if let b = a.bateria { Anel(valor: b, cor: b < 10 ? Paleta.vermelho : b < 20 ? Paleta.ambar : .white.opacity(0.8), diametro: 30, linha: 2) }
                Glifo(a: a, tamanho: 30)
            }.frame(width: 30, height: 30)
            if Paleta.leve {
                EmptyView()  // Light: só o aparelho no prato; o rótulo e o tráfego vão pra legenda
            } else if let n = a.net { TaxaCompacta(net: n, local: a.local) } else {
                Text(a.rotulo).font(.system(size: 10).monospacedDigit()).foregroundStyle(Paleta.terciario).lineLimit(1)
            }
        }.frame(width: Paleta.leve ? 48 : a.net == nil ? 64 : 88)
    }
}

/// O desenho de um periférico no prato: o símbolo do tipo, ou o ícone que o usuário escolheu.
struct Glifo: View {
    let a: Aparelho, tamanho: CGFloat
    var body: some View {
        if a.icone.isEmpty || a.icone.hasPrefix("sf:") {
            Image(systemName: a.icone.isEmpty ? simbolo(a) : String(a.icone.dropFirst(3)))
                .font(.system(size: tamanho * 0.4, weight: .medium)).foregroundStyle(Paleta.secundario)
        } else {
            IconeDispositivo(valor: a.icone, tamanho: tamanho * 0.72, prato: false)
        }
    }
}

extension View {
    /// Botão direito → "Renomear e trocar ícone…" (abre a página de edição na própria gaveta).
    func editavel(_ pagina: String, _ abrir: @escaping (String) -> Void) -> some View {
        contextMenu { Button(t("Renomear e trocar ícone…")) { abrir(pagina) } }
    }
}

struct BotaoEditar: View {
    let acao: () -> Void
    var body: some View {
        Button(action: acao) { Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(Paleta.terciario).padding(3).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(t("Renomear e trocar ícone"))
    }
}

/// Renomear e trocar o ícone de um Mac, servidor ou periférico, direto da gaveta. O nome fica só na config (o hostname
/// e o nome do aparelho não mudam); o ícone vem da galeria ou de uma imagem sua; "Voltar ao padrão" desfaz os dois.
struct PaginaEditar: View {
    let chave: String  // "editar:mac:<id>", "editar:srv:<id>" ou "editar:ap:<id do periférico>"
    @ObservedObject var store: ConfigStore
    let e: Estado, voltar: () -> Void
    @StateObject private var r = Rascunho()

    var tipo: String { chave.split(separator: ":", maxSplits: 2).dropFirst().first.map(String.init) ?? "" }
    var id: String { chave.split(separator: ":", maxSplits: 2).dropFirst(2).first.map(String.init) ?? "" }
    var periferico: Aparelho? { e.maquinas.lazy.flatMap { aparelhos($0) }.first { $0.id == id } }
    /// (nome original, ícone padrão, ícone atual, nome atual)
    var info: (String, String, String, String) {
        switch tipo {
        case "mac":
            let m = store.c.maquinas.first { $0.id == id }, vivo = e.maquinas.first { $0.id == id }?.modelo
            let padrao = !(m?.modelo ?? "").isEmpty ? m!.modelo : (m?.icone ?? "").isEmpty ? vivo ?? "com.apple.mac" : "com.apple.mac"
            return (m?.host ?? "", padrao, m?.icone ?? "", m?.nome ?? "")
        case "srv":
            let s = store.c.servidores.first { $0.id == id }
            return (s?.host ?? "", "sf:server.rack", s?.icone ?? "", s?.nome ?? "")
        default:
            let a = periferico, x = store.c.aparelhos[id]
            return (a?.nome ?? String(id.dropFirst()), a.map { "sf:" + simbolo($0) } ?? "sf:cable.connector", x?.icone ?? "", x?.nome ?? "")
        }
    }

    var body: some View {
        let (original, padrao, icone, _) = info
        VStack(alignment: .leading, spacing: 14) {
            Voltar(acao: { salvarNome(); voltar() })
            HStack(spacing: 16) {
                IconeDispositivo(valor: icone.isEmpty ? padrao : icone, tamanho: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tipo == "ap" ? t("Periférico") : tipo == "srv" ? t("Servidor") : "Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(Paleta.terciario)
                    CampoPergunta(texto: $r.texto, foco: .constant(false), dica: original) { salvarNome() }
                        .frame(width: 300, height: 20).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(Paleta.contraste ? 0.14 : 0.07)))
                    Text(t("Original: {0}  ·  o nome fica só aqui, o aparelho não muda", original)).font(.system(size: 10)).foregroundStyle(Paleta.terciario)
                }
            }
            Text(t("Ícone")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Paleta.terciario)
            GaleriaIcones(atual: icone, padrao: padrao, colunas: 10) { mudarIcone($0) }
            HStack {
                Button(t("Voltar ao padrão")) { padraoTudo() }.buttonStyle(.plain).foregroundStyle(Paleta.secundario)
                Spacer()
                Button(t("Pronto")) { salvarNome(); voltar() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 5).background(Capsule().fill(Color.white.opacity(0.14)))
            }.font(.system(size: 12))
        }
        .frame(width: 584, alignment: .leading)
        .onAppear { if !r.lido { r.texto = info.3; r.lido = true } }
    }

    func salvarNome() {
        let n = r.texto.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tipo {
        case "mac":
            if let i = store.c.maquinas.firstIndex(where: { $0.id == id }) {
                let novo = n.isEmpty ? store.c.maquinas[i].host : n
                if store.c.maquinas[i].nome != novo { store.c.maquinas[i].nome = novo; store.c.maquinas[i].curto = "" }
            }
        case "srv":
            if let i = store.c.servidores.firstIndex(where: { $0.id == id }) { store.c.servidores[i].nome = n.isEmpty ? store.c.servidores[i].host : n }
        default:
            var x = store.c.aparelhos[id] ?? CAparelho()
            x.nome = n == info.0 ? "" : n
            store.c.aparelhos[id] = x.vazio ? nil : x
        }
    }

    func mudarIcone(_ v: String) {
        switch tipo {
        case "mac": if let i = store.c.maquinas.firstIndex(where: { $0.id == id }) { store.c.maquinas[i].icone = v }
        case "srv": if let i = store.c.servidores.firstIndex(where: { $0.id == id }) { store.c.servidores[i].icone = v }
        default:
            var x = store.c.aparelhos[id] ?? CAparelho()
            x.icone = v
            store.c.aparelhos[id] = x.vazio ? nil : x
        }
    }

    func padraoTudo() {
        switch tipo {
        case "mac":
            if let i = store.c.maquinas.firstIndex(where: { $0.id == id }) {
                store.c.maquinas[i].nome = store.c.maquinas[i].host; store.c.maquinas[i].curto = ""; store.c.maquinas[i].icone = ""
                r.texto = store.c.maquinas[i].host
            }
        case "srv":
            if let i = store.c.servidores.firstIndex(where: { $0.id == id }) {
                store.c.servidores[i].nome = store.c.servidores[i].host; store.c.servidores[i].icone = ""; r.texto = store.c.servidores[i].host
            }
        default:
            store.c.aparelhos[id] = nil
            r.texto = ""
        }
    }
}

// MARK: - Rede: tráfego ao vivo, Wi-Fi e teste de velocidade

/// Tráfego deste Mac (bits/s), dos contadores da interface (getifaddrs: nenhum processo) 1× por segundo, e só com a
/// gaveta aberta; fechada, o timer não existe (os outros Macs, e este fechado, usam a amostra da sonda a cada ciclo).
/// Também o nome da rede Wi-Fi, que o macOS só entrega com Localização: pedida uma vez, num botão, nunca sozinha.
final class Trafego: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var down: Double?  // nil = ainda sem duas leituras
    @Published var up: Double?
    @Published var ssid: String?
    @Published var localizacao: CLAuthorizationStatus = .notDetermined
    var iface: String?
    private var timer: Timer?, anterior: (Date, UInt32, UInt32)?, abertas = Set<ObjectIdentifier>()
    private lazy var gps: CLLocationManager = { let m = CLLocationManager(); m.delegate = self; return m }()

    func ligar(_ aberta: Bool, quem: AnyObject) {
        if aberta { abertas.insert(ObjectIdentifier(quem)) } else { abertas.remove(ObjectIdentifier(quem)) }
        if abertas.isEmpty { timer?.invalidate(); timer = nil; anterior = nil; down = nil; up = nil; return }
        guard timer == nil else { return }
        localizacao = gps.authorizationStatus
        lerSSID()
        medir()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.medir() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func medir() {
        guard let i = iface, let (rx, tx) = Trafego.contadores(i) else { return }
        let agora = Date()
        if let (t0, rx0, tx0) = anterior {
            let dt = agora.timeIntervalSince(t0)  // contadores de 32 bits: a subtração com estouro dá o delta certo
            if dt > 0.2 { down = Double(rx &- rx0) * 8 / dt; up = Double(tx &- tx0) * 8 / dt }
        }
        anterior = (agora, rx, tx)
    }

    static func contadores(_ nome: String) -> (UInt32, UInt32)? {
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primeiro = lista else { return nil }
        defer { freeifaddrs(lista) }
        for p in sequence(first: primeiro, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), String(cString: a.ifa_name) == nome, let d = a.ifa_data else { continue }
            let x = d.assumingMemoryBound(to: if_data.self).pointee
            return (x.ifi_ibytes, x.ifi_obytes)
        }
        return nil
    }

    func pedirLocalizacao() { NSApp.activate(ignoringOtherApps: true); gps.requestWhenInUseAuthorization() }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { localizacao = m.authorizationStatus; lerSSID() }
    func lerSSID() { ssid = CWWiFiClient.shared().interface()?.ssid() }
}
let trafego = Trafego()

/// 12,4 Mb/s · 850 kb/s · 1,2 Gb/s (bits, como o plano de internet e o teste de velocidade).
func bits(_ b: Double?) -> String {
    guard let b = b else { return "—" }
    let (v, u) = b >= 1e9 ? (b / 1e9, "Gb/s") : b >= 1e6 ? (b / 1e6, "Mb/s") : (b / 1e3, "kb/s")
    return decimal(v < 10 && u != "kb/s" ? String(format: "%.1f", v) : String(Int(v.rounded()))) + " " + u
}
/// O mesmo, curto pra faixa de baixo: 12M, 850k, 1,2G.
func bitsCurto(_ b: Double?) -> String {
    guard let b = b else { return "—" }
    let (v, u) = b >= 1e9 ? (b / 1e9, "G") : b >= 1e6 ? (b / 1e6, "M") : (b / 1e3, "k")
    return decimal(v < 10 && u != "k" ? String(format: "%.1f", v) : String(Int(v.rounded()))) + u
}
func sinal(_ rssi: Int) -> String { rssi >= -55 ? t("sinal|ótimo") : rssi >= -67 ? t("sinal|bom") : rssi >= -75 ? t("sinal|fraco") : t("sinal|ruim") }

/// "Wi-Fi Casa · 5 GHz · canal 157 · link 780 Mb/s · sinal -51 dBm · 192.168.1.20 · Tailscale 100.x" (sem nome sem Localização).
func resumoRede(_ n: Net, _ ts: String, ssid: String?, curto: Bool = false) -> String {
    var p: [String] = []
    if n.tipo == "Wi-Fi" {
        let w = n.wifi
        p.append(ssid.map { "Wi-Fi \($0)" } ?? "Wi-Fi")
        p += [w?.banda, w?.canal.map { t("canal {0}", $0) }, w?.taxa.map { t("link {0}", bits(Double($0) * 1e6)) }, w?.rssi.map { t("sinal {0} dBm", $0) }].compactMap { $0 }
    } else {
        p.append(n.tipo)
        if let l = n.link { p.append(t("link {0}", bits(Double(l) * 1e6))) }
    }
    if curto { return p.joined(separator: " · ") }
    if let ip = n.ip, !ip.isEmpty { p.append(ip) }
    p.append("Tailscale \(ts)")
    return p.joined(separator: " · ")
}

/// ↓/↑ na faixa de baixo: ao vivo (1 s) se for este Mac com a gaveta aberta; senão a amostra da sonda.
struct TaxaCompacta: View {
    let net: Net, local: Bool
    @ObservedObject var t = trafego
    var body: some View {
        let vivo = local && t.down != nil
        let d = vivo ? t.down : net.down.map(Double.init), u = vivo ? t.up : net.up.map(Double.init)
        Text("↓\(bitsCurto(d)) ↑\(bitsCurto(u))").font(.system(size: 10).monospacedDigit()).foregroundStyle(Paleta.terciario).lineLimit(1)
            .contentTransition(.numericText()).animation(.easeOut(duration: 0.25), value: d)
    }
}

/// Legenda com o mouse em cima da rede: o tráfego com unidade e o resto (Wi-Fi/cabo, link, sinal, IPs).
struct LegendaRede: View {
    let a: Aparelho
    @ObservedObject var tr = trafego
    var body: some View {
        let vivo = a.local && tr.down != nil
        let d = vivo ? tr.down : a.net?.down.map(Double.init), u = vivo ? tr.up : a.net?.up.map(Double.init)
        let resto = a.net.map { resumoRede($0, a.tailscale, ssid: a.local ? tr.ssid : nil, curto: true) } ?? a.detalhe
        Text("↓ \(bits(d))  ↑ \(bits(u))" + (vivo ? " " + t("agora") : "") + "  ·  \(resto)").font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Paleta.secundario).lineLimit(1).truncationMode(.middle).contentTransition(.numericText())
    }
}

/// Rede na página do Mac: Wi-Fi (nome com Localização, sinal, canal, banda, link) ou cabo (link), tráfego, IPs e o teste
/// de velocidade (networkQuality, só no clique: consome banda).
struct SecaoRede: View {
    let q: Maquina
    @ObservedObject var acoes: Acoes
    @ObservedObject var tr = trafego
    var body: some View {
        let d = q.detalhe, local = q.local == true, vivo = local && tr.down != nil, ts = q.ts ?? ""
        Secao(t("Rede")) {
            if let n = d?.net {
                Linha(n.tipo == "Wi-Fi" ? "Wi-Fi" : n.tipo, n.tipo == "Wi-Fi" ? (local ? tr.ssid : nil) ?? t("conectado") : n.link.map { bits(Double($0) * 1e6) } ?? t("conectado"))
                Linha(vivo ? t("Agora") : t("Tráfego"), "↓ \(bits(vivo ? tr.down : n.down.map(Double.init)))   ↑ \(bits(vivo ? tr.up : n.up.map(Double.init)))")
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.25), value: tr.down)
                if let w = n.wifi {
                    if let r = w.rssi { Linha(t("Sinal"), "\(r) dBm · \(sinal(r))", cor: r < -75 ? Paleta.ambar : nil) }
                    Linha(t("Canal"), [w.canal.map(String.init), w.banda, w.largura.map { "\($0) MHz" }].compactMap { $0 }.joined(separator: " · "))
                    if let tx = w.taxa { Linha(t("Link"), bits(Double(tx) * 1e6) + (w.padrao.map { " · \($0)" } ?? "")) }
                }
                if let ip = n.ip, !ip.isEmpty { Linha(t("IP local"), ip) }
                if local && n.tipo == "Wi-Fi" && tr.ssid == nil && tr.localizacao == .notDetermined {
                    Button { tr.pedirLocalizacao() } label: { Label(t("Mostrar o nome da rede"), systemImage: "location").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Paleta.secundario)
                        .help(t("O macOS só entrega o nome da rede Wi-Fi a apps com Localização. É pedida uma vez; a localização em si não é usada."))
                }
            } else if let r = d?.rede {
                Linha(r.components(separatedBy: " · ").first ?? t("Rede"), r.components(separatedBy: " · ").last ?? "—")
            }
            Linha("Tailscale", d?.tailscale ?? "—")
            if acoes.medindo.contains(ts) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(t("Medindo a internet… uns 20 s")).font(.system(size: 11)).foregroundStyle(Paleta.terciario) }
            } else {
                if let v = acoes.velocidades[ts] {
                    if let e = v.erro { Text(e).font(.system(size: 11)).foregroundStyle(Paleta.ambar) } else {
                        Linha(t("Download"), bits(v.down))
                        Linha(t("Upload"), bits(v.up))
                        if let rpm = v.rpm { Linha(t("Responsividade"), "\(Int(rpm)) RPM").help(t("Idas e voltas por minuto com a rede ocupada: quanto maior, menos a chamada engasga")) }
                    }
                }
                Button { acoes.testarVelocidade(ts) } label: {
                    Label(acoes.velocidades[ts] == nil ? t("Testar velocidade") : t("Testar de novo"), systemImage: "speedometer").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(Paleta.secundario).disabled(ts.isEmpty)
                    .help(t("networkQuality do macOS: ~20 s, consome banda; só roda quando você clica"))
            }
        }
    }
}

// MARK: - Páginas de detalhe

/// Voltar com área de clique decente (o "‹ Frota" de antes tinha 42 × 14 pt).
struct Voltar: View {
    let acao: () -> Void
    var body: some View {
        Button(action: acao) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(t("Frota")).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(Paleta.secundario).padding(.vertical, 6).padding(.trailing, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Página de um Mac: o mostrador dele, tudo que está conectado, processos, discos e sistema. Embaixo, as ações; a que
/// apaga ou fecha alguma coisa abre um painel no lugar das colunas, com a prévia em números e o botão de 2 cliques.
struct PaginaMac: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let q: Maquina, voltar: () -> Void
    @ObservedObject var acoes: Acoes
    @ObservedObject var ilha: EstadoIlha
    var comAcoes = true  // Ajustes › Geral › Ações nos Macs
    var nomes: [String: CAparelho] = [:], abrir: (String) -> Void = { _ in }
    var body: some View {
        let d = q.detalhe, md = q.medidas!
        VStack(alignment: .leading, spacing: 8) {
            Voltar(acao: voltar)
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 0) {
                    ZStack {
                        Aneis(md: md, nv: q.niveis, diametro: 104, linha: 5)
                        IconeDispositivo(valor: q.modelo ?? "", tamanho: 46)
                        if let a = q.alerta { Selo(a: a, tamanho: 22).position(x: 89, y: 89) }
                    }.frame(width: 104, height: 104)
                    HStack(spacing: 6) {
                        Text(q.nome ?? "").font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                        BotaoEditar { abrir("editar:mac:" + (q.id ?? "")) }
                    }.padding(.top, 10)
                    Text(d?.sistema ?? "").font(.system(size: 11)).foregroundStyle(Paleta.terciario).padding(.top, 2)
                    Numeros(v: Paleta.v.metricas.map { md.valor($0) }, tamanho: 11).padding(.top, 8)
                    if let a = q.alerta {
                        Text(a.texto).font(.system(size: 11)).foregroundStyle(Paleta.estado(a.nivel)).multilineTextAlignment(.center).padding(.top, 8)
                    }
                }.frame(width: 168)
                if let a = ilha.acao, let ts = q.ts {
                    PainelAcao(tipo: a, q: q, ts: ts, acoes: acoes, fechar: { abrirAcao(a) }).frame(width: 472, alignment: .leading).transition(.troca)
                } else {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 16) {
                            Secao(t("Conectados")) {
                                let aps = aparelhos(q, rede: false, nomes: nomes)
                                if aps.isEmpty { Text(t("Nada além do próprio Mac")).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                                ForEach(aps) { a in LinhaAparelho(a: a).editavel("editar:ap:" + a.id, abrir) }
                            }
                            SecaoRede(q: q, acoes: acoes)
                        }.frame(width: 236, alignment: .leading)
                        VStack(alignment: .leading, spacing: 16) {
                            Secao(t("Processos")) {
                                ForEach(Array((d?.top ?? []).enumerated()), id: \.offset) { _, t in
                                    Linha(t.first?.texto ?? "", "\(Int((t.last?.numero ?? 0).rounded()))%")
                                }
                            }
                            Secao(t("Discos")) {
                                ForEach(d?.discos ?? [], id: \.nome) { x in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Linha(x.nome, t("{0} GB livres", x.livre))
                                        Barra(pct: x.usado, largura: 208, cor: x.usado >= 95 ? Paleta.vermelho : x.usado >= 90 ? Paleta.ambar : .white.opacity(0.5))
                                    }
                                }
                            }
                            Secao(t("Sistema")) {
                                Linha(t("Temperatura"), d?.temp.map { "\(Int($0.rounded())) °C" } ?? "—")
                                Linha(t("Ligado há"), d?.ligado ?? "—")
                                // pressão de memória (sonda.py) chega crua: N_("normal") N_("atenção") N_("crítica")
                                Linha(t("Memória"), t("pressão {0}", t(d?.pressao ?? "—")) + (d?.swap.map { $0 >= 0.1 ? " · " + t("swap {0} {1}", decimal(String(format: "%.1f", $0)), t("unidade|GB")) : "" } ?? ""))
                            }
                        }.frame(width: 208, alignment: .leading)
                    }.transition(.troca)
                }
            }
            if comAcoes, let ts = q.ts { BarraAcoes(q: q, ts: ts, acoes: acoes, aberta: ilha.acao, abrir: abrirAcao).padding(.top, 12) }
        }
        .onAppear { if let ts = q.ts { acoes.carregar(ts) } }
    }

    /// Abre o painel da ação (o mesmo botão de novo fecha). A gaveta mede o painel e faz morph pra ele.
    func abrirAcao(_ a: String) {
        withAnimation(Paleta.reduzir ? .easeOut(duration: 0.15) : Paleta.mola) { ilha.acao = ilha.acao == a ? nil : a }
    }
}

/// As ações do Mac, como os botões da Central de Controle: prato redondo, o nome e o número que importa embaixo.
/// Abrir (Downloads, Monitor de Atividade, Terminal) é um clique; o que apaga ou fecha abre o painel com a prévia.
struct BarraAcoes: View {
    let q: Maquina, ts: String
    @ObservedObject var acoes: Acoes
    let aberta: String?, abrir: (String) -> Void
    var body: some View {
        let tam = acoes.tamanhos[ts], local = q.local == true, limpando = acoes.fases[ts + ":cache"] == .rodando
        let l = tam?.lixeira
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Color.white.opacity(Paleta.contraste ? 0.22 : 0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                BotaoAcao(simbolo: "sparkles", nome: t("Liberar cache"), ativo: aberta == "cache",
                          valor: limpando ? t("limpando…") : acoes.fases[ts + ":cache"] != nil ? t("medir de novo")
                            : acoes.previas[ts]?.total.map { t("até {0}", gb($0)) } ?? t("ver prévia")) {
                    if aberta != "cache" && !limpando { acoes.previa(ts) }  // a prévia é sempre medida na hora
                    abrir("cache")
                }
                BotaoAcao(simbolo: "trash", nome: t("Lixeira"), ativo: aberta == "lixeira",
                          valor: tam == nil ? "…" : l == nil ? "—" : l!.semAcesso == true ? t("sem acesso") : l!.itens == 0 ? t("vazia") : gb(l!.bytes)) { abrir("lixeira") }
                if local {
                    BotaoAcao(simbolo: "arrow.down.circle", nome: t("Downloads"), ativo: false, valor: t("abrir no Finder")) { acoes.rodar(["abrir", "--alvo", "downloads"]) { _ in } }
                }
                if let ds = tam?.discos, !ds.isEmpty || aberta == "discos" {
                    BotaoAcao(simbolo: "eject", nome: t("Ejetar"), ativo: aberta == "discos", valor: ds.count == 1 ? ds[0].nome : t("{0} discos", ds.count)) { abrir("discos") }
                }
                BotaoAcao(simbolo: "arrow.clockwise", nome: t("Reiniciar app"), ativo: aberta == "apps", valor: tam?.apps.map { $0.count == 1 ? t("{0} aberto", 1) : t("{0} abertos", $0.count) } ?? "…") { abrir("apps") }
                if local {
                    BotaoAcao(simbolo: "waveform.path.ecg", nome: t("Monitor de Atividade|Monitor"), ativo: false, valor: t("Monitor de Atividade|de Atividade")) { acoes.rodar(["abrir", "--alvo", "monitor"]) { _ in } }
                } else {
                    BotaoAcao(simbolo: "terminal", nome: "Terminal", ativo: false, valor: t("SSH neste Mac")) { acoes.rodar(["abrir", "--alvo", "terminal", "--maquina", ts]) { _ in } }
                }
            }
        }
    }
}

struct BotaoAcao: View {
    let simbolo: String, nome: String, ativo: Bool, valor: String?, acao: () -> Void
    var body: some View {
        Button(action: acao) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(ativo ? Color.white.opacity(0.92) : Color.white.opacity(Paleta.contraste ? 0.16 : 0.08))
                    Image(systemName: simbolo).font(.system(size: 13, weight: .medium)).foregroundStyle(ativo ? Color.black : Paleta.secundario)
                }.frame(width: 34, height: 34)
                Text(nome).font(.system(size: 11)).foregroundStyle(Paleta.secundario).lineLimit(1)
                Text(valor ?? " ").font(.system(size: 10).monospacedDigit()).foregroundStyle(Paleta.terciario).lineLimit(1).truncationMode(.middle)
            }.frame(width: 92).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Ação que apaga ou fecha: o 1º clique só arma (vira "Confirmar…" em vermelho por 4 s), o 2º executa. Um duplo-clique
/// acidental não confirma: o 2º clique só vale depois de 0,4 s.
final class Gatilho: ObservableObject { @Published var armadoEm: Date? }  // @State é macro no SDK novo e o swiftc solto não acha o plugin
struct BotaoConfirma: View {
    let titulo: String, confirmar: String, acao: () -> Void
    @StateObject private var g = Gatilho()
    var body: some View {
        let armado = g.armadoEm != nil
        Button {
            if let t = g.armadoEm {
                guard Date().timeIntervalSince(t) > 0.4 else { return }
                g.armadoEm = nil
                acao()
            } else {
                let agora = Date()
                g.armadoEm = agora
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [g] in if g.armadoEm == agora { g.armadoEm = nil } }
            }
        } label: {
            Text(armado ? confirmar : titulo).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(armado ? Color.black : Paleta.primario)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(armado ? Paleta.vermelho : Color.white.opacity(Paleta.contraste ? 0.24 : 0.14)))
                .contentShape(Capsule())
        }.buttonStyle(.plain).animation(.easeOut(duration: 0.15), value: armado)
    }
}

struct Botao: View {
    let titulo: String, acao: () -> Void
    init(_ titulo: String, _ acao: @escaping () -> Void) { self.titulo = titulo; self.acao = acao }
    var body: some View {
        Button(action: acao) {
            Text(titulo).font(.system(size: 12, weight: .medium)).foregroundStyle(Paleta.secundario)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(Paleta.contraste ? 0.16 : 0.08))).contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

/// O painel de uma ação, no lugar das colunas: o que vai acontecer, com números, e só então o botão de 2 cliques.
/// Tudo fica no log ~/Library/Logs/fleetnotch/acoes.log do Mac onde rodou (e um resumo no do Mac do app).
struct PainelAcao: View {
    let tipo: String, q: Maquina, ts: String
    @ObservedObject var acoes: Acoes
    let fechar: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch tipo {
            case "cache": cache
            case "lixeira": lixeira
            case "discos": discos
            default: apps
            }
        }
    }

    @ViewBuilder var cache: some View {
        let p = acoes.previas[ts], fase = acoes.fases[ts + ":cache"]
        Cabecalho(simbolo: "sparkles", titulo: t("Liberar cache"),
                  texto: t("Só caches que se refazem sozinhos. Documentos, projetos, .hermes, .claude, Fotos e Mail nunca entram; cache de app aberto ou em uso fica."))
        if let itens = p?.itens {
            VStack(alignment: .leading, spacing: 5) {
                if itens.isEmpty { Text(t("Nenhum cache da lista neste Mac")).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                ForEach(itens) { i in
                    HStack(spacing: 8) {
                        Text(i.nome).font(.system(size: 12)).foregroundStyle(Paleta.secundario).lineLimit(1).frame(width: 168, alignment: .leading)
                        Text(i.pulado.map { t("pula · {0}", $0) } ?? i.caminho).font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(i.nota != nil ? t("até {0}", gb(i.bytes)) : gb(i.bytes)).font(.system(size: 12, weight: .medium).monospacedDigit())
                            .strikethrough(i.pulado != nil).foregroundStyle(i.pulado == nil ? Paleta.primario : Paleta.terciario)
                    }.opacity(i.pulado == nil ? 1 : 0.6)
                }
            }
            let total = p?.total ?? 0, ids = itens.filter { $0.pulado == nil }.map(\.id).joined(separator: ",")
            Rodape(fase: fase, rodando: t("Apagando…"), deNovo: (t("Medir de novo"), { acoes.previa(ts) }), fechar: fechar) {
                Text(total > 0 ? (itens.contains { $0.nota != nil && $0.pulado == nil } ? t("Vai liberar até {0}", gb(total)) : t("Vai liberar {0}", gb(total)))
                     : t("Nada a apagar agora"))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer(minLength: 8)
                Botao(t("Cancelar"), fechar)
                if total > 0 {
                    BotaoConfirma(titulo: t("Apagar {0}", gb(total)), confirmar: t("Confirmar: apagar {0}", gb(total))) {
                        acoes.executar(ts + ":cache", ["cache-limpar", "--ids", ids, "--maquina", ts])
                    }
                }
            }
        } else if let e = p?.erro {
            Text(e).font(.system(size: 12)).foregroundStyle(Paleta.ambar)
        } else {
            Carregando(texto: t("Medindo os caches deste Mac…"))
        }
    }

    @ViewBuilder var lixeira: some View {
        let l = acoes.tamanhos[ts]?.lixeira, fase = acoes.fases[ts + ":lixeira"], local = q.local == true
        let pode = l != nil && l!.semAcesso != true && l!.itens > 0
        Cabecalho(simbolo: "trash", titulo: t("Esvaziar a Lixeira"),
                  texto: l == nil ? t("Olhando a Lixeira…") : l!.semAcesso == true ? t("O macOS não deixa este app ler a Lixeira deste Mac (Acesso Total ao Disco). Dá pra abrir e esvaziar no Finder.")
                    : l!.itens == 0 ? t("A Lixeira está vazia.") : (l!.itens == 1 ? t("{0} item", l!.itens) : t("{0} itens", l!.itens)) + " · " + gb(l!.bytes))
        if pode && fase == nil {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Paleta.ambar)
                Text(t("Apaga de vez tudo que está na Lixeira. Não tem volta: nada disso pode ser recuperado depois."))
                    .font(.system(size: 12)).foregroundStyle(Paleta.primario).fixedSize(horizontal: false, vertical: true)
            }
        }
        Rodape(fase: fase, rodando: t("Esvaziando…"), deNovo: nil, fechar: fechar) {
            if local { Botao(t("Abrir no Finder")) { acoes.rodar(["abrir", "--alvo", "lixeira"]) { _ in } } }
            Spacer(minLength: 8)
            Botao(pode ? t("Cancelar") : t("Fechar"), fechar)
            if pode {
                BotaoConfirma(titulo: t("Esvaziar a Lixeira"), confirmar: t("Confirmar: apagar para sempre")) {
                    acoes.executar(ts + ":lixeira", ["lixeira-esvaziar", "--itens", "\(l!.itens)", "--maquina", ts]) { acoes.carregar(ts, forcar: true) }
                }
            }
        }
    }

    @ViewBuilder var discos: some View {
        let ds = acoes.tamanhos[ts]?.discos ?? []
        Cabecalho(simbolo: "eject", titulo: t("Ejetar disco"), texto: t("Desmonta com segurança. Se algum app estiver usando o disco, o macOS recusa e diz quem."))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ds, id: \.nome) { d in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 13)).foregroundStyle(Paleta.secundario).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.nome).font(.system(size: 12)).foregroundStyle(Paleta.secundario)
                        Text(t("{0} livres de {1}", gb(d.livre), gb(d.total))).font(.system(size: 11).monospacedDigit()).foregroundStyle(Paleta.terciario)
                    }
                    Spacer(minLength: 8)
                    EstadoAcao(fase: acoes.fases[ts + ":disco:" + d.nome], rodando: t("Ejetando…")) {
                        BotaoConfirma(titulo: t("Ejetar"), confirmar: t("Confirmar")) {
                            acoes.executar(ts + ":disco:" + d.nome, ["ejetar", "--volume", d.nome, "--maquina", ts]) { acoes.carregar(ts, forcar: true) }
                        }
                    }
                }
            }
            // o que já foi ejetado some da lista: fica a confirmação
            ForEach(acoes.fases.keys.filter { $0.hasPrefix(ts + ":disco:") && !ds.map(\.nome).contains(String($0.dropFirst(ts.count + 7))) }.sorted(), id: \.self) { k in
                if case .feito(let t)? = acoes.fases[k] {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Paleta.terciario).frame(width: 20)
                        Text(String(k.dropFirst(ts.count + 7))).font(.system(size: 12)).foregroundStyle(Paleta.terciario)
                        Spacer(minLength: 8)
                        Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(Paleta.secundario)
                    }
                }
            }
            if ds.isEmpty && acoes.fases.keys.allSatisfy({ !$0.hasPrefix(ts + ":disco:") }) {
                Text(t("Nenhum disco externo montado")).font(.system(size: 12)).foregroundStyle(Paleta.terciario)
            }
        }
        HStack { Spacer(); Botao(t("Fechar"), fechar) }
    }

    @ViewBuilder var apps: some View {
        let as_ = acoes.tamanhos[ts]?.apps ?? []
        Cabecalho(simbolo: "arrow.clockwise", titulo: t("Reiniciar um app"),
                  texto: t("Fecha o app (pede pra sair; se não sair em 5 s, força) e abre de novo. O que não foi salvo nele pode se perder."))
        VStack(alignment: .leading, spacing: 8) {
            if acoes.tamanhos[ts] == nil { Carregando(texto: t("Vendo os apps abertos…")) }
            ForEach(as_, id: \.nome) { a in
                HStack(spacing: 10) {
                    Image(nsImage: iconeApp(a.app)).resizable().frame(width: 20, height: 20)
                    Text(a.nome).font(.system(size: 12)).foregroundStyle(Paleta.secundario).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(lround(a.cpu))% CPU").font(.system(size: 11).monospacedDigit()).foregroundStyle(Paleta.terciario)
                    EstadoAcao(fase: acoes.fases[ts + ":app:" + a.nome], rodando: t("Reiniciando…")) {
                        BotaoConfirma(titulo: t("Reiniciar"), confirmar: t("Confirmar")) {
                            acoes.executar(ts + ":app:" + a.nome, ["reiniciar", "--pid", "\(a.pid)", "--maquina", ts]) { acoes.carregar(ts, forcar: true) }
                        }
                    }
                }
            }
        }
        HStack { Spacer(); Botao(t("Fechar"), fechar) }
    }
}

/// Ícone do app (o de verdade, lido do disco; app de outro Mac que não existe aqui ganha o ícone genérico).
func iconeApp(_ caminho: String) -> NSImage {
    if let i = logos[caminho] { return i }
    let i = FileManager.default.fileExists(atPath: caminho) ? NSWorkspace.shared.icon(forFile: caminho) : NSWorkspace.shared.icon(for: .application)
    logos[caminho] = i
    return i
}

struct Cabecalho: View {
    let simbolo: String, titulo: String, texto: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.white.opacity(Paleta.contraste ? 0.16 : 0.08))
                Image(systemName: simbolo).font(.system(size: 14, weight: .medium)).foregroundStyle(Paleta.secundario)
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(titulo).font(.system(size: 15, weight: .semibold))
                Text(texto).font(.system(size: 11)).foregroundStyle(Paleta.terciario).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Carregando: View {
    let texto: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(texto).font(.system(size: 12)).foregroundStyle(Paleta.terciario)
        }
    }
}

/// Rodapé de uma ação: antes, os botões; rodando, a frase com o indicador; depois, o resultado (e "de novo", se houver).
struct Rodape<C: View>: View {
    let fase: Fase?, rodando: String, deNovo: (String, () -> Void)?, fechar: () -> Void, botoes: C
    init(fase: Fase?, rodando: String, deNovo: (String, () -> Void)?, fechar: @escaping () -> Void, @ViewBuilder _ botoes: () -> C) {
        self.fase = fase; self.rodando = rodando; self.deNovo = deNovo; self.fechar = fechar; self.botoes = botoes()
    }
    var body: some View {
        HStack(spacing: 10) {
            switch fase {
            case .rodando?: Carregando(texto: rodando)
            case .feito(let x)?:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Paleta.secundario)
                Text(x).font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer(minLength: 8)
                if let d = deNovo { Botao(d.0, d.1) }
                Botao(t("Fechar"), fechar)
            case .falhou(let x)?:
                Text(x).font(.system(size: 12)).foregroundStyle(Paleta.ambar).lineLimit(2)
                Spacer(minLength: 8)
                if let d = deNovo { Botao(d.0, d.1) }
                Botao(t("Fechar"), fechar)
            case nil: botoes
            }
        }.frame(minHeight: 28)
    }
}

/// Estado de uma ação numa linha (ejetar um disco, reiniciar um app): o botão, ou rodando, ou o resultado.
struct EstadoAcao<C: View>: View {
    let fase: Fase?, rodando: String, botao: C
    init(fase: Fase?, rodando: String, @ViewBuilder _ botao: () -> C) { self.fase = fase; self.rodando = rodando; self.botao = botao() }
    var body: some View {
        switch fase {
        case .rodando?: Carregando(texto: rodando)
        case .feito(let t)?: Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(Paleta.secundario)
        case .falhou(let t)?: Text(t).font(.system(size: 11)).foregroundStyle(Paleta.ambar).lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
        case nil: botao
        }
    }
}

/// Página de um agente: canais, serviços, trabalho (crons e kanban), o que pede atenção, último erro e última atividade.
/// Hermes mostra tudo; OpenClaw e genérico mostram o que o tipo sabe. Só leitura: nenhum botão mexe no agente.
struct PaginaAgente: View {
    let g: Agente, foto: String?, voltar: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Voltar(acao: voltar)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    FotoAgente(caminho: foto, nome: g.nome, tamanho: 56).opacity(g.noAr ? 1 : 0.45)
                    Text(g.nome).font(.system(size: 15, weight: .semibold)).padding(.top, 12)
                    Text(t(g.estado)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(g.noAr || g.nivel < 0 ? Paleta.secundario : Paleta.estado(max(g.nivel, 1))).padding(.top, 2)
                    Text([["hermes": "Hermes", "openclaw": "OpenClaw", "generico": t("Agente")][g.tipo] ?? g.tipo, g.versao,
                          g.agentes.map { $0 == 1 ? t("{0} sessão", $0) : t("{0} sessões", $0) }, g.porta.map { t("porta {0}", $0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Paleta.terciario).padding(.top, 2)
                    if let b = g.batida { Text(t("batida há {0}", b.ha)).font(.system(size: 11)).foregroundStyle(Paleta.terciario).padding(.top, 2) }
                }.frame(width: 168, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    Secao(t("Canais")) {
                        if (g.canais ?? []).isEmpty && (g.uazapi ?? []).isEmpty { Text(t("Nenhum canal informado")).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                        ForEach(g.canais ?? [], id: \.nome) { c in
                            Linha(c.nome, c.estado, cor: c.nivel < 0 ? Paleta.terciario : c.nivel == 0 ? nil : Paleta.estado(c.nivel))
                        }
                        ForEach(g.uazapi ?? [], id: \.nome) { i in LinhaEstado(rotulo: "UAZAPI · \(i.nome)", valor: i.status) }
                    }
                    if let p = g.perfis, !p.isEmpty {
                        Secao(t("Outros perfis")) { ForEach(p, id: \.nome) { x in LinhaEstado(rotulo: x.nome, valor: x.estado) } }
                    }
                    if let ss = g.servicos, !ss.isEmpty {
                        Secao(t("Serviços")) {
                            ForEach(ss, id: \.nome) { s in Linha(s.nome, s.pid ? t("rodando") : s.saida == 0 ? "ok" : t("saiu ({0})", s.saida.map(String.init) ?? "?")) }
                        }
                    }
                }.frame(width: 236, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    if let c = g.crons {
                        Secao("Crons") {
                            Linha(t("Ativos"), "\(c.ativos)")
                            Linha(t("Falhando"), "\(c.falhando)", cor: c.falhando > 0 ? Paleta.ambar : nil)
                            if let p = c.proximo {
                                Linha(t("Próximo"), p.hora)
                                Text(p.nome).font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(1)
                            }
                        }
                    }
                    if let k = g.kanban, let f = k.fila {
                        Secao("Kanban") {
                            Linha(t("Na fila"), "\(f)")
                            Linha(t("Rodando"), "\(k.rodando ?? 0)")
                            Linha(t("Bloqueados"), "\(k.bloqueados ?? 0)")
                        }
                    }
                    if let ps = g.problemas, !ps.isEmpty {
                        Secao(t("Pede atenção")) {
                            ForEach(Array(ps.enumerated()), id: \.offset) { _, p in
                                Text(problema(p.titulo)).font(.system(size: 12)).foregroundStyle(Paleta.estado(p.nivel)).lineLimit(2)
                            }
                        }
                    }
                    Secao(t("Atividade")) {
                        Linha(g.atividade?.tipo ?? t("atividade|última"), g.atividade.map { "\($0.hora) · " + t("há {0}", $0.ha) } ?? "—")
                        if let er = g.erro {
                            Linha(t("Último erro"), "\(er.hora) · " + t("há {0}", er.ha), cor: Paleta.ambar)
                            Text(er.texto ?? "").font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(2)
                        }
                    }
                }.frame(width: 236, alignment: .leading)
            }
        }
    }
}

/// Página de um servidor Linux: medidas, serviços escolhidos, containers, discos, processos e sistema.
struct PaginaServidor: View {
    let s: Servidor, voltar: () -> Void
    var icone = "", editar: () -> Void = {}
    var body: some View {
        let d = s.detalhe
        VStack(alignment: .leading, spacing: 8) {
            Voltar(acao: voltar)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    IconeDispositivo(valor: icone.isEmpty ? "sf:server.rack" : icone, tamanho: 56)
                    HStack(spacing: 6) { Text(s.nome).font(.system(size: 15, weight: .semibold)); BotaoEditar(acao: editar) }.padding(.top, 12)
                    Text(d?.sistema ?? "").font(.system(size: 11)).foregroundStyle(Paleta.terciario).padding(.top, 2)
                    if let md = s.medidas {
                        HStack(spacing: 8) {
                            ForEach(Array([("CPU", md.cpu), ("RAM", md.ram), (t("disco"), md.disco)].enumerated()), id: \.offset) { i, x in
                                VStack(spacing: 2) {
                                    Text("\(x.1)%").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                        .foregroundStyle([s.niveis?.cpu, s.niveis?.ram, s.niveis?.disco][i].map { $0 >= 1 ? Paleta.estado($0) : Paleta.primario } ?? Paleta.primario)
                                    Text(x.0).font(.system(size: 10)).foregroundStyle(Paleta.terciario)
                                }.frame(width: 44)
                            }
                        }.padding(.top, 10)
                    }
                    if let a = s.alerta { Text(a.texto).font(.system(size: 11)).foregroundStyle(Paleta.estado(a.nivel)).padding(.top, 8) }
                }.frame(width: 168, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    Secao(t("Serviços")) {
                        if (d?.servicos ?? []).isEmpty { Text(t("Nenhum escolhido (Ajustes › Servidores)")).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                        ForEach(d?.servicos ?? [], id: \.nome) { v in
                            Linha(v.nome, ["active": t("rodando"), "inactive": t("parado"), "failed": t("falhou"), "unknown": t("não existe")][v.estado] ?? v.estado,
                                  cor: v.estado == "active" ? nil : v.estado == "activating" ? Paleta.ambar : Paleta.vermelho)
                        }
                    }
                    if let erro = d?.docker {
                        Secao(t("Containers")) { Text(erro).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
                    } else if let cs = d?.containers, !cs.isEmpty {
                        Secao(t("Containers")) {
                            ForEach(cs.prefix(8), id: \.nome) { c in
                                Linha(c.nome, c.status.replacingOccurrences(of: "Up ", with: t("Docker “Up 3 days”|há") + " ").replacingOccurrences(of: " (healthy)", with: ""),
                                      cor: c.estado == "running" && !c.status.contains("unhealthy") ? nil : c.estado == "exited" ? Paleta.terciario : Paleta.ambar)
                            }
                            if cs.count > 8 { Text(t("+ {0} containers", cs.count - 8)).font(.system(size: 11)).foregroundStyle(Paleta.terciario) }
                        }
                    }
                }.frame(width: 236, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    Secao(t("Discos")) {
                        ForEach(d?.discos ?? [], id: \.nome) { x in
                            VStack(alignment: .leading, spacing: 4) {
                                Linha(x.nome, t("{0} GB livres", x.livre))
                                Barra(pct: x.usado, largura: 208, cor: x.usado >= 95 ? Paleta.vermelho : x.usado >= 90 ? Paleta.ambar : .white.opacity(0.5))
                            }
                        }
                    }
                    Secao(t("Processos")) {
                        ForEach(Array((d?.top ?? []).enumerated()), id: \.offset) { _, t in Linha(t.first?.texto ?? "", "\(Int((t.last?.numero ?? 0).rounded()))%") }
                    }
                    Secao(t("Sistema")) {
                        Linha(t("Ligado há"), d?.ligado ?? "—")
                        Linha(t("Carga"), (d?.carga ?? []).map { String(format: "%.2f", $0) }.joined(separator: " · "))
                        Linha(t("Memória"), d?.ram ?? "—")
                        Linha(t("Núcleos"), "\(d?.nucleos ?? 0)")
                    }
                }.frame(width: 208, alignment: .leading)
            }
        }
    }
}

/// Página do e-mail: cada conta com os não lidos e o último cabeçalho (buscado quando a página abre). Nunca o corpo.
struct PaginaEmail: View {
    let x: Email, voltar: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Voltar(acao: voltar)
            HStack(alignment: .firstTextBaseline) {
                Text(t("E-mail")).font(.system(size: 15, weight: .semibold))
                Text(x.naoLidos == 1 ? t("{0} não lido", 1) : t("{0} não lidos", x.naoLidos)).font(.system(size: 12)).foregroundStyle(Paleta.secundario)
                Spacer()
                Text(t("contagem a cada {0} · só cabeçalho, nunca o corpo", x.intervalo.map { $0 < 60 ? "\($0) min" : "\($0 / 60) h" } ?? "—"))
                    .font(.system(size: 11)).foregroundStyle(Paleta.terciario)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(x.contas, id: \.id) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Prato(simbolo: c.app == "outlook" ? "envelope.badge" : c.provedor == "imap" ? "tray" : "envelope", cor: Paleta.secundario).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(c.nome).font(.system(size: 12, weight: .semibold))
                                if let e = c.endereco, !e.isEmpty { Text(e).font(.system(size: 11)).foregroundStyle(Paleta.terciario).lineLimit(1) }
                                Spacer()
                                Text(c.naoLidos.map { "\($0)" } ?? "—").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            }
                            if let e = c.erro {
                                Text(e).font(.system(size: 11)).foregroundStyle(Paleta.ambar)
                            } else if let u = c.ultimo {
                                HStack(spacing: 6) {
                                    Text(u.de).font(.system(size: 11, weight: .medium)).foregroundStyle(Paleta.secundario).lineLimit(1)
                                    Text(u.assunto).font(.system(size: 11)).foregroundStyle(Paleta.secundario).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 4)
                                    Text(t("há {0}", u.ha)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Paleta.terciario)
                                }
                            } else {
                                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(t("buscando o último cabeçalho…")).font(.system(size: 11)).foregroundStyle(Paleta.terciario) }
                            }
                        }
                    }
                }
            }.frame(width: 560).padding(.top, 6)
        }
    }
}

/// As últimas 10 perguntas rápidas (só neste Mac, em Application Support).
struct PaginaHistorico: View {
    @ObservedObject var p: Pergunta
    let voltar: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Voltar(acao: voltar)
            Text(t("Últimas perguntas")).font(.system(size: 15, weight: .semibold))
            if p.historico.isEmpty { Text(t("Nada ainda.")).font(.system(size: 12)).foregroundStyle(Paleta.terciario) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(p.historico) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.pergunta).font(.system(size: 12, weight: .medium)).foregroundStyle(Paleta.secundario).lineLimit(2)
                            RespostaView(r: r, limite: 80)
                        }
                    }
                }
            }.frame(maxHeight: 420)
        }.frame(width: 560)
    }
}

struct Secao<C: View>: View {
    let titulo: String, conteudo: C
    init(_ titulo: String, @ViewBuilder _ conteudo: () -> C) { self.titulo = titulo; self.conteudo = conteudo() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titulo).font(.system(size: 11, weight: .semibold)).foregroundStyle(Paleta.terciario)
            conteudo
        }
    }
}

/// Rótulo à esquerda, valor à direita, um tamanho só. Quem trunca (com "…") é o lado menos importante.
struct Linha: View {
    let a: String, b: String, cor: Color?
    init(_ a: String, _ b: String, cor: Color? = nil) { self.a = a; self.b = b; self.cor = cor }
    var body: some View {
        HStack(spacing: 8) {
            Text(a).font(.system(size: 12)).foregroundStyle(Paleta.secundario).lineLimit(1)
            Spacer(minLength: 4)
            Text(b).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(cor ?? Paleta.primario).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Estado de canal/perfil em palavras (conectado / desconectado / fatal), com a cor só quando não está bem.
struct LinhaEstado: View {
    let rotulo: String, valor: String?
    var body: some View {
        let ok = valor == "connected" || valor == "running"
        let texto = ["connected": t("conectado"), "disconnected": t("desconectado"), "fatal": t("fora (fatal)"), "connecting": t("conectando")][valor ?? ""] ?? (valor ?? "—")
        Linha(rotulo, texto, cor: valor == nil ? Paleta.terciario : ok ? nil : valor == "connecting" ? Paleta.ambar : Paleta.vermelho)
    }
}

/// Aparelho na lista do detalhe: ícone pequeno no prato, nome e o valor que importa.
struct LinhaAparelho: View {
    let a: Aparelho
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(Paleta.contraste ? 0.16 : 0.08))
                Glifo(a: a, tamanho: 20)
            }.frame(width: 20, height: 20)
            Text(a.nome).font(.system(size: 12)).foregroundStyle(Paleta.secundario).lineLimit(1)
            Spacer(minLength: 4)
            Text(a.rotulo)
                .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(a.bateria.map { $0 < 20 ? Paleta.estado($0 < 10 ? 2 : 1) : Paleta.primario } ?? Paleta.primario).lineLimit(1)
        }
    }
}

/// O notch fechado em Core Animation puro: silhueta preta; à esquerda um ponto por Mac (redondo) e por servidor
/// (quadradinho) e a seta da sincronização; à direita o ponto do Orca (quando algo espera você), os olhos dos agentes e um
/// anel por conta de IA: máquinas de um lado, inteligências do outro.
/// CAShapeLayer é desenhada pelo servidor de janelas a partir das propriedades da camada; não depende de o SwiftUI
/// redesenhar. (Era o bug: o notch em SwiftUI ficava transparente até um hover forçar o redesenho.)
final class NotchView: NSView {
    var clique: () -> Void = {}
    var passou: (Bool) -> Void = { _ in }  // mouse entrou/saiu: a ilha mostra a legenda depois de um instante
    private let indicadores = CALayer()
    private var pontos: [CAShapeLayer] = [], aneis: [(trilho: CAShapeLayer, arco: CAShapeLayer)] = []
    private let olhos = [CAShapeLayer(), CAShapeLayer()]  // os agentes (dois olhos), à esquerda das contas
    private var ultimaAtividade: String?
    private let seta = CAShapeLayer()  // sincronização, logo depois dos pontos das máquinas
    private let orca = CAShapeLayer()  // Orca: algum agente esperando você
    private var ultimaSeta: String?

    init(tamanho: CGSize) {
        super.init(frame: NSRect(origin: .zero, size: tamanho))
        wantsLayer = true
        let forma = CAShapeLayer()
        forma.path = NotchView.silhueta(tamanho, topo: 6, base: 10)
        forma.fillColor = NSColor.black.cgColor
        layer?.addSublayer(forma)
        indicadores.frame = bounds
        indicadores.opacity = 0.75  // hover sobe pra 1 (sutil; nada abre no hover)
        layer?.addSublayer(indicadores)
        olhos.forEach { indicadores.addSublayer($0) }
        // setinha de 6 × 7: haste e ponta, traço fino arredondado (no Core Animation, y pra cima: a ponta fica em cima)
        let c = CGMutablePath()
        c.move(to: CGPoint(x: 3, y: 0.6)); c.addLine(to: CGPoint(x: 3, y: 6.4))
        c.move(to: CGPoint(x: 0.7, y: 4.1)); c.addLine(to: CGPoint(x: 3, y: 6.4)); c.addLine(to: CGPoint(x: 5.3, y: 4.1))
        seta.path = c
        seta.bounds = CGRect(x: 0, y: 0, width: 6, height: 7)
        seta.fillColor = nil
        seta.lineWidth = 1.3
        seta.lineCap = .round
        seta.lineJoin = .round
        seta.isHidden = true
        indicadores.addSublayer(seta)
        orca.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 4, height: 4), transform: nil)
        orca.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        orca.fillColor = NSColor(Paleta.ciano).cgColor
        orca.isHidden = true
        indicadores.addSublayer(orca)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Mesma silhueta do Notch (SwiftUI), em coordenadas do Core Animation (y pra cima: topo do notch em y = h).
    static func silhueta(_ s: CGSize, topo t: CGFloat, base b: CGFloat) -> CGPath {
        let w = s.width, h = s.height, p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: h))
        p.addQuadCurve(to: CGPoint(x: t, y: h - t), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: t, y: b))
        p.addQuadCurve(to: CGPoint(x: t + b, y: 0), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: w - t - b, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - t, y: b), control: CGPoint(x: w - t, y: 0))
        p.addLine(to: CGPoint(x: w - t, y: h - t))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - t, y: h))
        p.closeSubpath()
        return p
    }

    /// Onde cada indicador está (x do centro), pra legenda desenhar a mesma coisa na mesma ordem.
    static func pior(_ g: [Agente]) -> (nivel: Int, parada: Bool, semAcesso: Bool) {
        let vivos = g.filter { $0.nivel >= 0 }
        return (g.map(\.nivel).max() ?? -1, vivos.contains { !$0.noAr }, !g.isEmpty && vivos.isEmpty)
    }

    /// Normal = branco discreto; offline = ponto vazado; atenção/crítico = âmbar/vermelho. O olho só é puxado pela exceção.
    func atualizar(_ e: Estado, cfg: Config) {
        let ambar = Paleta.nsAmbar.cgColor, verm = Paleta.nsVermelho.cgColor
        let branco = NSColor.white.withAlphaComponent(0.7).cgColor, fraco = NSColor.white.withAlphaComponent(0.35).cgColor
        let meio = bounds.midY, d: CGFloat = 5
        // notch fechado (Ajustes › Aparência): todos os sinais, só o que pede atenção, ou nenhum (o notch puro)
        let so = cfg.visual.notch == "alertas"
        indicadores.isHidden = cfg.visual.notch == "vazio"
        let maqs = (cfg.modulos.macs ? e.maquinas : []).filter { !so || max($0.nivel, $0.alerta?.nivel ?? 0) >= 1 }
        let srvs = (cfg.modulos.servidores ? e.servidores ?? [] : []).filter { !so || !$0.online || max($0.nivel, $0.alerta?.nivel ?? 0) >= 1 }
        let total = maqs.count + srvs.count
        while pontos.count < total {
            let c = CAShapeLayer()
            c.lineWidth = 1
            indicadores.addSublayer(c)
            pontos.append(c)
        }
        let contas = (cfg.modulos.ia ? e.contas ?? [] : []).filter { !so || $0.nivel >= 1 }
        while aneis.count < contas.count {
            let r: CGFloat = 4.5, caminho = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r), transform: nil)
            let trilho = CAShapeLayer(), arco = CAShapeLayer()
            for (l, cor) in [(trilho, NSColor.white.withAlphaComponent(0.18).cgColor), (arco, branco)] {
                l.path = caminho; l.fillColor = nil; l.strokeColor = cor; l.lineWidth = 1.6
                indicadores.addSublayer(l)
            }
            arco.lineCap = .round
            arco.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)  // começa ao meio-dia, horário
            arco.transform = CATransform3DScale(arco.transform, 1, -1, 1)
            aneis.append((trilho, arco))
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Paleta.reduzir ? 0 : 0.4)
        for (i, c) in pontos.enumerated() {
            let servidor = i >= maqs.count && i < total
            let n: Int
            if i < maqs.count {
                let q = maqs[i]
                n = q.nivel < 0 ? -1 : max(q.nivel, q.alerta?.nivel ?? 0)  // carga ou alerta, o que for pior
            } else if servidor {
                let s = srvs[i - maqs.count]
                n = !s.online ? 2 : max(s.nivel, s.alerta?.nivel ?? 0)  // servidor fora do ar é problema (notebook offline não é)
            } else { n = -1 }
            // servidores vêm depois dos Macs, com um respiro de 3 pt; o quadradinho tem cantos levemente arredondados
            c.path = servidor ? CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1), cornerWidth: 1, cornerHeight: 1, transform: nil)
                : CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
            c.frame = CGRect(x: 18 + CGFloat(i) * (d + 4) + (servidor ? 3 : 0), y: meio - d / 2, width: d, height: d)
            c.isHidden = i >= total
            c.fillColor = n < 0 ? nil : n >= 2 ? verm : n == 1 ? ambar : branco
            c.strokeColor = n < 0 ? fraco : nil
        }
        for (i, a) in aneis.enumerated() {
            let ok = i < contas.count, c = ok ? contas[i] : nil, x = bounds.width - 18 - 9 - CGFloat(contas.count - 1 - i) * 13
            for l in [a.trilho, a.arco] {
                l.bounds = CGRect(x: 0, y: 0, width: 9, height: 9); l.position = CGPoint(x: x + 4.5, y: meio); l.isHidden = !ok
            }
            a.arco.strokeEnd = CGFloat(min(c?.pct ?? 0, 100)) / 100
            a.arco.strokeColor = (c?.nivel ?? 0) >= 2 ? verm : (c?.nivel ?? 0) == 1 ? ambar : c.map { NSColor(Paleta.corConta($0)).withAlphaComponent(0.85).cgColor } ?? branco
        }
        // agentes: brancos = todos no ar; âmbar/vermelho = algum pede atenção; fechados (dois traços) = algum parado;
        // vazados = nenhum acessível
        let todos = cfg.modulos.agentes ? e.agentes ?? [] : [], (nh, parada, semAcesso) = NotchView.pior(todos)
        let ags = so && nh < 1 && !parada ? [] : todos
        let x0 = bounds.width - 18 - 9 - CGFloat(max(contas.count - 1, 0)) * 13 - (contas.isEmpty ? -9 : 9) - 9.4
        for (i, o) in olhos.enumerated() {
            o.isHidden = ags.isEmpty
            o.bounds = CGRect(x: 0, y: 0, width: 3.4, height: 3.4)
            o.position = CGPoint(x: x0 + 1.7 + CGFloat(i) * 6, y: meio)
            o.path = parada ? CGPath(roundedRect: CGRect(x: -0.3, y: 1.1, width: 4, height: 1.2), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil)
                : CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 3.4, height: 3.4), transform: nil)
            o.fillColor = semAcesso ? nil : nh >= 2 || parada ? verm : nh == 1 ? ambar : branco
            o.strokeColor = semAcesso ? fraco : nil
            o.lineWidth = 0.8
        }
        // Orca: um ponto ciano discreto à esquerda dos olhos, só quando algum agente do Orca está esperando você
        let esperando = cfg.modulos.orca && (e.orca?.esperando ?? 0) > 0
        orca.isHidden = !esperando
        orca.fillColor = NSColor(Paleta.ciano).cgColor
        orca.position = CGPoint(x: (ags.isEmpty ? x0 + 6 : x0) - 8, y: meio)
        // sincronização: seta branca andando enquanto sobe/desce; parada e âmbar se um backup não rodou; senão, nada
        let sc = cfg.modulos.sincronizacao ? e.sincronizacao : nil, anda = sc?.seta != nil && !so, atencao = sc?.seta == nil && (sc?.nivel ?? 0) >= 1
        seta.position = CGPoint(x: 18 + CGFloat(total) * (d + 4) + (srvs.isEmpty ? 0 : 3) + 5, y: meio)
        seta.isHidden = !anda && !atencao
        seta.strokeColor = atencao ? ambar : NSColor.white.withAlphaComponent(0.8).cgColor
        seta.transform = sc?.seta == "desce" ? CATransform3DMakeScale(1, -1, 1) : CATransform3DIdentity
        CATransaction.commit()
        let chave = "\(sc?.seta ?? "-")\(atencao)\(Paleta.reduzir)"
        if chave != ultimaSeta {  // só mexe na animação quando o estado muda (cada ciclo de 20 s não reinicia o passo)
            seta.removeAnimation(forKey: "anda")
            if anda && !Paleta.reduzir {
                let g = CAAnimationGroup()
                let sobe = CABasicAnimation(keyPath: "transform.translation.y"), some = CABasicAnimation(keyPath: "opacity")
                sobe.fromValue = -1; sobe.toValue = 1.6
                some.fromValue = 1; some.toValue = 0.35
                g.animations = [sobe, some]
                g.duration = 0.9
                g.autoreverses = true
                g.repeatCount = .infinity
                g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                seta.add(g, forKey: "anda")
            }
            ultimaSeta = chave
        }
        // piscam quando algum agente faz alguma coisa nova (a última atividade mudou); com Reduzir movimento, não
        let atv = ags.compactMap { $0.atividade.map { $0.hora + ($0.tipo ?? "") } }.joined(separator: "|")
        if let u = ultimaAtividade, atv != u, !atv.isEmpty, !Paleta.reduzir, !parada {
            let pisca = CAKeyframeAnimation(keyPath: "transform.scale.y")
            pisca.values = [1, 0.1, 1]
            pisca.keyTimes = [0, 0.45, 1]
            pisca.duration = 0.24
            olhos.forEach { $0.add(pisca, forKey: "pisca") }
        }
        ultimaAtividade = atv
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { realce(true); passou(true) }
    override func mouseExited(with event: NSEvent) { realce(false); passou(false) }
    private func realce(_ v: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Paleta.reduzir ? 0 : 0.15)
        indicadores.opacity = v ? 1 : 0.75
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {  // resposta no mouse down
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        passou(false); clique()
    }
    /// Botão direito (ou Control-clique) no notch: o caminho pros Ajustes que não depende do ícone da barra de menus
    /// (num MacBook com a barra cheia, o macOS esconde atrás do notch o que não cabe).
    override func rightMouseDown(with event: NSEvent) {
        passou(false)
        let m = NSMenu()
        for (titulo, acao) in [(t("Ajustes…"), #selector(menuAjustes)), (t("Assistente de configuração…"), #selector(menuAssistente))] {
            m.addItem(withTitle: titulo, action: acao, keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: t("Sair"), action: #selector(menuSair), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
    @objc private func menuAjustes() { abrirAjustesGlobal() }
    @objc private func menuAssistente() {
        DistributedNotificationCenter.default().postNotificationName(.init(ID + ".assistente"), object: nil, userInfo: nil, deliverImmediately: true)
    }
    @objc private func menuSair() { NSApp.terminate(nil) }
}

/// A legenda do notch fechado: o mouse parou em cima dele e cada indicador ganha nome e estado, na mesma ordem e com o
/// mesmo desenho (ponto = Mac, quadradinho = servidor, seta = sincronização, ponto ciano = Orca, olhos = agentes, anel = conta
/// de IA). Âmbar e vermelho dizem o que está errado. Na 1ª vez que o app abre, ela aparece sozinha com uma dica.
struct LegendaNotch: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let e: Estado, cfg: Config, dica: Bool
    var body: some View {
        let maqs = cfg.modulos.macs ? e.maquinas : [], srvs = cfg.modulos.servidores ? e.servidores ?? [] : []
        let ags = cfg.modulos.agentes ? e.agentes ?? [] : [], contas = cfg.modulos.ia ? e.contas ?? [] : []
        VStack(alignment: .leading, spacing: 0) {
            if dica {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("Este é o seu notch")).font(.system(size: 13, weight: .semibold))
                    Text(t("Cada sinal aqui em cima é uma coisa sua. Clique no notch pra abrir tudo; passe o mouse nele pra ver esta legenda de novo."))
                        .font(.system(size: 11)).foregroundStyle(Paleta.secundario).fixedSize(horizontal: false, vertical: true)
                }.padding(.bottom, 10)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(Array(maqs.enumerated()), id: \.offset) { _, q in
                    let n = q.nivel < 0 ? -1 : max(q.nivel, q.alerta?.nivel ?? 0)
                    linha(Ponto(nivel: n, quadrado: false), q.nome ?? "", n < 0 ? t("offline") : q.alerta?.texto ?? (n >= 1 ? t("muito exigido") : t("em ordem")), n)
                }
                ForEach(Array(srvs.enumerated()), id: \.offset) { _, s in
                    let n = !s.online ? -1 : max(s.nivel, s.alerta?.nivel ?? 0)
                    linha(Ponto(nivel: s.online ? n : 2, quadrado: true), s.nome, !s.online ? t("fora do ar") : s.alerta?.texto ?? t("em ordem"), s.online ? n : 2)
                }
                if let sc = cfg.modulos.sincronizacao ? e.sincronizacao : nil, sc.seta != nil || sc.nivel >= 1 {
                    linha(Image(systemName: sc.seta == "desce" ? "arrow.down" : "arrow.up").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(sc.seta == nil ? Paleta.ambar : Paleta.primario), t("Sincronização"),
                          sc.seta == nil ? sc.problema ?? t("backup atrasado") : sc.seta == "sobe" ? t("enviando") : t("baixando"), sc.seta == nil ? 1 : 0)
                }
                if cfg.modulos.orca, let o = e.orca, (o.esperando ?? 0) > 0 {
                    linha(Circle().fill(Paleta.ciano).frame(width: 4, height: 4), "Orca", t("{0} esperando você", o.esperando ?? 0), 0, cor: Paleta.ciano)
                }
                ForEach(Array(ags.enumerated()), id: \.offset) { _, g in
                    linha(Olhos(nivel: g.nivel, parada: g.nivel >= 0 && !g.noAr), g.nome, resumoCurto(g), g.noAr ? g.nivel : max(g.nivel, 2))
                }
                ForEach(Array(contas.enumerated()), id: \.offset) { _, c in
                    linha(Anel(valor: c.nivel < 0 ? 0 : c.pct, cor: Paleta.conta(c.nivel), diametro: 9, linha: 1.6), "\(c.rotulo) · \(c.ferramenta ?? "")",
                          c.semLogin == true ? t("sem login") : c.nivel < 0 ? t("sem dado de uso") : usoJanela(c), c.nivel)
                }
            }
            if maqs.isEmpty && srvs.isEmpty && ags.isEmpty && contas.isEmpty {
                Text(t("Nada configurado ainda: abra os Ajustes no menu da barra.")).font(.system(size: 11)).foregroundStyle(Paleta.secundario)
            }
            Text(t("Clique no notch pra abrir · botão direito: Ajustes")).font(.system(size: 10)).foregroundStyle(Paleta.terciario).padding(.top, 9)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(Paleta.contraste ? 0.35 : 0.14), lineWidth: 1)))
        .foregroundStyle(Paleta.primario)
        .environment(\.colorScheme, .dark)
    }

    func resumoCurto(_ g: Agente) -> String {
        if !g.noAr { return t(g.estado) }
        if let c = (g.canais ?? []).first(where: { $0.nivel >= 1 }) { return "\(c.nome) \(c.estado)" }
        if let p = g.problemas?.first { return problema(p.titulo) }
        return g.atividade.map { t("no ar") + " · " + t("{0} há {1}", $0.tipo ?? t("atividade"), $0.ha) } ?? t("no ar")
    }

    func linha(_ glifo: some View, _ nome: String, _ estado: String, _ nivel: Int, cor: Color? = nil) -> some View {
        GridRow {
            glifo.frame(width: 14, height: 12)
            Text(nome).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(estado).font(.system(size: 11)).foregroundStyle(cor ?? (nivel >= 1 ? Paleta.estado(nivel) : Paleta.terciario)).lineLimit(1)
                .gridColumnAlignment(.leading)
        }
    }
}

struct Ponto: View {
    let nivel: Int, quadrado: Bool
    var body: some View {
        let cor = nivel < 0 ? Color.clear : nivel >= 2 ? Paleta.vermelho : nivel == 1 ? Paleta.ambar : Color.white.opacity(0.7)
        Group {
            if quadrado {
                RoundedRectangle(cornerRadius: 1).fill(cor).overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.white.opacity(nivel < 0 ? 0.35 : 0), lineWidth: 1))
            } else {
                Circle().fill(cor).overlay(Circle().stroke(Color.white.opacity(nivel < 0 ? 0.35 : 0), lineWidth: 1))
            }
        }.frame(width: 5, height: 5)
    }
}

struct Olhos: View {
    let nivel: Int, parada: Bool
    var body: some View {
        let cor = nivel < 0 ? Color.clear : nivel >= 2 || parada ? Paleta.vermelho : nivel == 1 ? Paleta.ambar : Color.white.opacity(0.7)
        HStack(spacing: 2.6) {
            ForEach(0..<2, id: \.self) { _ in
                if parada { Capsule().fill(cor).frame(width: 4, height: 1.2) } else {
                    Circle().fill(cor).overlay(Circle().stroke(Color.white.opacity(nivel < 0 ? 0.35 : 0), lineWidth: 0.8)).frame(width: 3.4, height: 3.4)
                }
            }
        }
    }
}

/// A legenda dentro da janela dela: acompanha o estado da frota e a config.
struct LegendaJanela: View {
    @ObservedObject var m: Modelo
    @ObservedObject var cfg: ConfigStore
    @ObservedObject var ilha: EstadoIlha
    var body: some View { LegendaNotch(e: m.estado, cfg: cfg.c, dica: ilha.dica).fixedSize() }
}

/// Painel sem borda, acima da barra de menus, em todos os Spaces, que nunca ativa o app. Sem a animação do sistema ao
/// entrar/sair da tela: a gaveta anima ela mesma e o notch nunca sai.
final class Painel: NSPanel {
    private let podeSerChave: Bool
    init(chave: Bool) {
        podeSerChave = chave
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { podeSerChave }  // só a gaveta vira chave (pra ouvir o Esc)
    override var canBecomeMain: Bool { false }
}

/// Recebe o 1º clique com o app em 2º plano (app de barra nunca fica ativo) e deixa a ilha decidir: dentro da gaveta
/// segue pro SwiftUI (cards, voltar); fora dela fecha. Hover por área de rastreamento própria (o onHover do SwiftUI não
/// dispara num painel de app em 2º plano).
final class Host<V: View>: NSHostingView<V> {
    var clique: (CGPoint) -> Bool = { _ in false }  // true = a ilha tratou, não repassa
    var movimento: (CGPoint?) -> Void = { _ in }
    private var rastreio: NSTrackingArea?
    /// ponto do evento no espaço do SwiftUI (origem no canto de cima)
    private func ponto(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if !clique(ponto(event)) { super.mouseDown(with: event) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let r = rastreio, trackingAreas.contains(r) { return }
        rastreio = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(rastreio!)
    }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); movimento(ponto(event)) }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); movimento(ponto(event)) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); movimento(nil) }
}

/// A ilha de uma tela são DUAS janelas: o notch (Core Animation, do tamanho exato do notch), que nunca sai da tela nem
/// muda de tamanho, e a gaveta (SwiftUI), outra janela por baixo dele, que só entra na tela enquanto aberta.
/// (Era uma janela só, que crescia/encolhia e era tirada e recolocada na tela no fim de cada fechamento pra devolver o
/// teclado: o notch sumia ~250 ms a cada Esc.)
final class Ilha {
    let estado = EstadoIlha()
    let modelo: Modelo
    let cfg: ConfigStore
    private(set) var tela: NSScreen
    let notch: CGSize
    let area = CGSize(width: 960, height: 900)  // janela da gaveta: cabe a maior página + sombra; nunca muda de tamanho
    let jNotch = Painel(chave: false), jGaveta = Painel(chave: true), jLegenda = Painel(chave: false)
    private var legendaPendente: DispatchWorkItem?
    private var fechando: DispatchWorkItem?
    private var porHover = false  // aberta pelo hover: fecha sozinha quando o mouse sai
    private let nv: NotchView
    private var assinatura: AnyCancellable?
    private var observadores: [Any] = []
    private var monitores: [Any] = []

    /// Notch físico do MacBook quando existe; senão um notch virtual da altura EXATA da barra de menus desta tela
    /// (num monitor externo a barra pode ter 30 pt; um notch fixo de 32 vazava 2 px por cima das janelas).
    static func medida(_ t: NSScreen) -> CGSize {
        if let l = t.auxiliaryTopLeftArea, let r = t.auxiliaryTopRightArea, t.safeAreaInsets.top > 0 {
            return CGSize(width: t.frame.width - l.width - r.width, height: t.safeAreaInsets.top)
        }
        let barra = t.frame.maxY - t.visibleFrame.maxY  // 0 quando a barra se esconde sozinha
        return CGSize(width: 200, height: barra > 0 ? barra : max(NSApp.mainMenu?.menuBarHeight ?? 0, 24))
    }

    init(tela: NSScreen, modelo: Modelo, cfg: ConfigStore) {
        self.tela = tela
        self.modelo = modelo
        self.cfg = cfg
        notch = Ilha.medida(tela)
        nv = NotchView(tamanho: notch)
        nv.clique = { [weak self] in self.map { $0.mudar(!$0.estado.aberta) } }
        nv.passou = { [weak self] dentro in self?.legenda(dentro) }
        jLegenda.ignoresMouseEvents = true  // o conteúdo só existe enquanto ela aparece (escondida, redesenhava a cada dado novo)
        jLegenda.alphaValue = 0
        jNotch.contentView = nv
        // notch UM NÍVEL ACIMA da gaveta: no mesmo nível, um clique dentro da gaveta a trazia pra frente e o filete de
        // luz do pescoço dela passava por cima do notch (uma linha cinza atravessando o notch; sessão de 10 min, 20,2 s)
        jNotch.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        let host = Host(rootView: ComIdioma { [modelo, estado, cfg, notch, area] in IlhaView(m: modelo, e: estado, cfg: cfg, notch: notch, janela: area) })
        host.clique = { [weak self] p in self?.clique(p) ?? true }
        host.movimento = { [weak self] p in self?.passou(p) }
        jGaveta.contentView = host
        jGaveta.ignoresMouseEvents = true
        assinatura = modelo.$estado.combineLatest(cfg.$c).receive(on: DispatchQueue.main).sink { [weak nv] e, c in nv?.atualizar(e, cfg: c) }
        posicionar()
        jNotch.orderFrontRegardless()
        // presença: ao voltar de oclusão/desbloqueio/despertar/troca de Space, reafirma o notch na frente (sem recriar)
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        observadores = [nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: jNotch, queue: .main) { [weak self] _ in self?.reafirmar() },
                        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.reafirmar() },
                        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.reafirmar() },
                        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.reafirmar() }]
    }

    var id: CGDirectDisplayID? { Ilha.id(tela) }
    static func id(_ t: NSScreen) -> CGDirectDisplayID? { t.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }

    /// Notch no topo-centro; gaveta centrada nele, começando `encaixe` pt acima da base do notch (pescoço e filetes).
    func posicionar(_ t: NSScreen? = nil) {
        if let t = t { tela = t }
        let f = tela.frame
        jNotch.setFrame(NSRect(x: (f.midX - notch.width / 2).rounded(), y: f.maxY - notch.height, width: notch.width, height: notch.height), display: true)
        jGaveta.setFrame(NSRect(x: (f.midX - area.width / 2).rounded(), y: f.maxY - notch.height + Medida.encaixe - area.height,
                                width: area.width, height: area.height), display: false)
    }

    func reafirmar() {
        jNotch.orderFrontRegardless()
        if estado.aberta { jGaveta.orderFrontRegardless() }  // nível abaixo do notch: fica sempre embaixo dele
    }

    func encerrar() {
        monitores.forEach(NSEvent.removeMonitor)
        observadores.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        monitores = []
        observadores = []
        assinatura = nil
        jGaveta.close()
        jLegenda.close()
        jNotch.close()
    }

    /// Mouse parado no notch (0,35 s) mostra a legenda embaixo dele; saiu ou clicou, ela some. Nunca com a gaveta aberta.
    /// Com "Abrir a gaveta ao passar o mouse", o hover abre a gaveta (0,25 s) e ela fecha sozinha quando o mouse sai dela,
    /// a não ser que a pessoa clique lá dentro (clicou = ficou).
    func legenda(_ mostrar: Bool) {
        legendaPendente?.cancel()
        if cfg.c.visual.abrirNoHover {
            if mostrar {
                fechando?.cancel()
                guard !estado.aberta else { return }
                let w = DispatchWorkItem { [weak self] in guard let s = self, !s.estado.aberta else { return }; s.mudar(true); s.porHover = true }
                legendaPendente = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
            } else if estado.aberta && porHover {
                agendarFechar()
            }
            return
        }
        guard mostrar, !estado.aberta else { esconderLegenda(); return }
        let t = DispatchWorkItem { [weak self] in self?.mostrarLegenda() }
        legendaPendente = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: t)
    }

    func mostrarLegenda() {
        guard !estado.aberta else { return }
        let v = jLegenda.contentView ?? NSHostingView(rootView: ComIdioma { [modelo, cfg, estado] in LegendaJanela(m: modelo, cfg: cfg, ilha: estado) })
        jLegenda.contentView = v
        let s = v.fittingSize, f = tela.frame
        jLegenda.setFrame(NSRect(x: (f.midX - s.width / 2).rounded(), y: f.maxY - notch.height - 8 - s.height, width: s.width, height: s.height), display: true)
        jLegenda.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = Paleta.reduzir ? 0 : 0.18; jLegenda.animator().alphaValue = 1 }
    }

    func esconderLegenda() {
        NSAnimationContext.runAnimationGroup({ c in c.duration = Paleta.reduzir ? 0 : 0.12; jLegenda.animator().alphaValue = 0 }) { [weak self] in
            guard let s = self, s.jLegenda.alphaValue == 0 else { return }
            s.jLegenda.orderOut(nil)
            s.jLegenda.contentView = nil
            s.estado.dica = false
        }
    }

    /// Primeira vez que o app abre: a legenda aparece sozinha, com a explicação, por 9 s. Uma vez só.
    func dica() {
        estado.dica = true
        mostrarLegenda()
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.esconderLegenda() }
        UserDefaults.standard.set(true, forKey: "dicaNotchVista")
    }

    /// Clique na janela da gaveta: dentro do corpo segue pro SwiftUI; fora dele (sombra, faixa ao lado do notch) fecha.
    func clique(_ p: CGPoint) -> Bool {
        guard estado.aberta else { return true }
        let t = estado.tamanho
        let dentro = noCorpo(p)
        if !dentro { mudar(false) } else { porHover = false; fechando?.cancel() }
        return !dentro
    }

    func noCorpo(_ p: CGPoint) -> Bool {
        let t = estado.tamanho
        return abs(p.x - area.width / 2) <= t.width / 2 && p.y >= Medida.encaixe - 6 && p.y <= Medida.encaixe + t.height
    }

    func agendarFechar() {
        fechando?.cancel()
        let w = DispatchWorkItem { [weak self] in guard let s = self, s.porHover, s.estado.aberta else { return }; s.mudar(false) }
        fechando = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    /// Hover: o alvo sob o mouse, pela geometria que o próprio SwiftUI reportou (AlvosKey).
    func passou(_ p: CGPoint?) {
        estado.mouse = p
        guard porHover, estado.aberta else { return }
        if let p = p, noCorpo(p) { fechando?.cancel() } else { agendarFechar() }
    }

    func mudar(_ abrir: Bool) {
        guard abrir != estado.aberta else { return }
        porHover = false
        fechando?.cancel()
        Feedback.abrir(abrir)  // som e toque, se ligados (Ajustes › Aparência)
        trafego.ligar(abrir, quem: self)  // 1 s com a gaveta aberta; fechada, o timer nem existe
        let reduzir = Paleta.reduzir  // "Reduzir movimento": sem deslizar, cross-fade curto
        // clique não carrega impulso: mola criticamente amortecida (sem quique), interrompível a qualquer instante
        let anim: Animation = reduzir ? .easeInOut(duration: 0.2) : Paleta.mola
        monitores.forEach(NSEvent.removeMonitor)
        monitores = []
        if abrir {
            legendaPendente?.cancel()
            esconderLegenda()
            modelo.olhar()
            estado.montada = true  // monta e mede ainda fechada; abre no ciclo seguinte (os cards já existem e entram em sequência)
            jGaveta.ignoresMouseEvents = false
            jGaveta.orderFrontRegardless()  // um nível abaixo do notch: fica embaixo dele, nunca por cima
            jGaveta.makeKey()  // pro Esc; painel não-ativador: o app da frente continua ativo
            DispatchQueue.main.async { [weak self] in withAnimation(anim) { self?.estado.aberta = true } }
            // clique em outro app fecha; Esc fecha. Só existem com a gaveta aberta (zero custo fechada).
            monitores = [NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.mudar(false) },
                         NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                             if e.keyCode == 53 { self?.mudar(false); return nil }
                             // Enter no campo da pergunta: o SwiftUI do painel trata o Enter como atalho padrão e ele nunca
                             // chegava ao campo; aqui ele vira "enviar" antes disso
                             if e.keyCode == 36 || e.keyCode == 76, let tv = self?.jGaveta.firstResponder as? NSTextView,
                                let c = (tv.delegate as? NSTextField)?.delegate as? CampoPergunta.Coord {
                                 c.pai.enviar()
                                 return nil
                             }
                             return e
                         }].compactMap { $0 }
        } else {
            jGaveta.ignoresMouseEvents = true  // no fim da mola ela é invisível: não pode engolir clique de ninguém
            // até sair da tela a gaveta ainda é a janela-chave: engole as teclas (senão o macOS apita) em vez de perdê-las num bipe
            monitores = [NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in nil }].compactMap { $0 }
            withAnimation(anim, completionCriteria: .logicallyComplete) { estado.aberta = false } completion: { [weak self] in
                guard let s = self, !s.estado.aberta else { return }
                // tirar a GAVETA da tela devolve o teclado pro app da frente; o notch é outra janela e não pisca
                s.jGaveta.orderOut(nil)
                s.monitores.forEach(NSEvent.removeMonitor)
                s.monitores = []
                s.estado.montada = false
                s.estado.pagina = nil
                s.estado.acao = nil
                s.estado.mouse = nil
                s.estado.hover = nil
                s.estado.tamanho = .zero
                UserDefaults.standard.set(true, forKey: "legendaVista")  // a legenda só aparece na primeira vez
            }
        }
    }
}

// MARK: - App

/// Prefixo das notificações de fora (atalhos, scripts, testes): é o próprio bundle id do app (o install.sh escolhe).
let ID = Bundle.main.bundleIdentifier ?? "frota"
var abrirSettings: () -> Void = {}  // preenchido pela ilha e pelo menu (openSettings só existe dentro de uma view SwiftUI)

/// App de barra (LSUIElement) não se ativa sozinho: sem isso os Ajustes e o assistente abrem ATRÁS do app da frente.
func praFrente(_ j: NSWindow?) {
    NSApp.activate(ignoringOtherApps: true)
    j?.makeKeyAndOrderFront(nil)
    j?.orderFrontRegardless()
}

/// Menu "Ajustes…", ⌘, e a notificação <ID>.ajustes: abre a janela dos Ajustes (ou acha a que já existe) e traz pra frente.
func abrirAjustesGlobal() {
    NSApp.activate(ignoringOtherApps: true)
    abrirSettings()
    DispatchQueue.main.async { praFrente(NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }) }
}
var atalhoGlobal: () -> Void = {}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let cfg = ConfigStore()
    let modelo = Modelo()
    let ajustes = EstadoAjustes()
    var ilhas: [Ilha] = []
    var itemBarra: ItemBarra?
    var assistente: NSWindow?
    var passoAssistente: ((Int) -> Void)?
    private var atalho: EventHotKeyRef?
    private var tratadorAtalho = false
    private var obs: [AnyCancellable] = []
    private var coletaAtual: Config?  // a parte da config que o coletor usa: só ela mudando reinicia o coletor
    private var criticos = 0
    private var idiomaObs: AnyCancellable?

    var fundo: NSWindow?, faixa: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        modelo.demo = { [cfg] in cfg.c.demo }
        modelo.iniciar()
        if ProcessInfo.processInfo.environment["FROTA_FUNDO"] != nil, let t = NSScreen.screens.first {
            // só pra gravar o README: um fundo neutro atrás da ilha (no lugar do papel de parede e das janelas de quem grava)
            let j = NSWindow(contentRect: t.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            j.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            j.ignoresMouseEvents = true
            j.collectionBehavior = [.canJoinAllSpaces, .stationary]
            j.contentView = NSHostingView(rootView: ZStack {
                LinearGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.27), Color(red: 0.27, green: 0.18, blue: 0.42), Color(red: 0.55, green: 0.3, blue: 0.5)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.white.opacity(0.18), .clear], center: UnitPoint(x: 0.5, y: 0.75), startRadius: 0, endRadius: 700)
            })
            j.setFrame(t.frame, display: true)
            j.orderFrontRegardless()
            fundo = j
            let barra = t.frame.maxY - t.visibleFrame.maxY
            let f = NSWindow(contentRect: NSRect(x: t.frame.minX, y: t.frame.maxY - barra, width: t.frame.width, height: barra),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            f.level = .statusBar  // por cima dos ícones da barra; o notch (um nível acima) e a gaveta ficam por cima dela
            f.ignoresMouseEvents = true
            f.collectionBehavior = [.canJoinAllSpaces, .stationary]
            f.backgroundColor = NSColor(red: 0.11, green: 0.13, blue: 0.27, alpha: 1)
            f.orderFrontRegardless()
            faixa = f
        }
        aplicarCores()
        Paleta.v = cfg.c.visual
        coletaAtual = AppDelegate.soColeta(cfg.c)
        idiomaObs = Idioma.shared.$codigo.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.modelo.reiniciar()
            self?.assistente?.title = t("Boas-vindas")  // a tabela nova já está carregada quando o código muda
        }
        obs = [cfg.salvo.receive(on: DispatchQueue.main).sink { [weak self] c in
            guard let s = self else { return }
            let coleta = AppDelegate.soColeta(c)
            if coleta != s.coletaAtual { s.coletaAtual = coleta; s.modelo.reiniciar() }  // o coletor relê a config (gosto não reinicia)
            s.aplicarCores()
            s.montarIlhas()
            s.ligarAtalho()
        },
               // o gosto vale na hora (sem esperar a gravação): a ilha, o notch e o painel redesenham com o estilo novo
               cfg.$c.removeDuplicates().sink { [weak self] c in
                   Paleta.v = c.visual
                   self?.modelo.copiados.configurar(ligado: c.modulos.copiados, demo: c.demo, c.visual.copiados)
               },
               // som quando aparece algo crítico novo (Ajustes › Aparência › Tocar um som…)
               modelo.$estado.receive(on: DispatchQueue.main).sink { [weak self] e in
                   let n = atencao(e).filter { $0.nivel >= 2 }.count
                   if let s = self, n > s.criticos, !e.maquinas.isEmpty { Feedback.critico() }
                   self?.criticos = n
               }]
        // uso por modelo: lê os registros uma vez agora, em segundo plano, pra página da conta abrir na hora
        if !cfg.c.demo && cfg.c.modulos.ia && cfg.c.ia.contains(where: { !$0.fonte.isEmpty }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Py.rodar("modelos", ["--aquecer"]) { _ in } }
        }
        montarIlhas()
        ligarAtalho()
        itemBarra = ItemBarra(app: self)
        if !cfg.existe {
            abrirAssistente()
        } else if !UserDefaults.standard.bool(forKey: "dicaNotchVista") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.ilhas.first?.dica() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.montarIlhas()
        }
        let dc = DistributedNotificationCenter.default()
        // abre/fecha a ilha de fora (atalho do Shortcuts, script, print): ver README
        dc.addObserver(forName: .init(ID + ".ilha"), object: nil, queue: .main) { [weak self] _ in self?.ilhas.forEach { $0.mudar(!$0.estado.aberta) } }
        dc.addObserver(forName: .init(ID + ".ajustes"), object: nil, queue: .main) { _ in abrirAjustesGlobal() }
        dc.addObserver(forName: .init(ID + ".assistente"), object: nil, queue: .main) { [weak self] _ in self?.abrirAssistente() }
        dc.addObserver(forName: .init(ID + ".aba"), object: nil, queue: .main) { [weak self] n in  // Ajustes numa aba (prints, atalhos)
            guard let s = self, let aba = n.object as? String else { return }
            let partes = aba.split(separator: ":").map(String.init)  // "macs:2" = aba Macs com o 3º item selecionado
            s.ajustes.aba = partes[0]
            if partes.count > 1, let i = Int(partes[1]) {
                switch partes[0] {
                case "macs": s.ajustes.maquina = s.cfg.c.maquinas.indices.contains(i) ? s.cfg.c.maquinas[i].id : nil
                case "servidores": s.ajustes.servidor = s.cfg.c.servidores.indices.contains(i) ? s.cfg.c.servidores[i].id : nil
                case "ia": s.ajustes.ia = s.cfg.c.ia.indices.contains(i) ? s.cfg.c.ia[i].id : nil
                case "agentes": s.ajustes.agente = s.cfg.c.agentes.indices.contains(i) ? s.cfg.c.agentes[i].id : nil
                default: break
                }
            }
        }
        dc.addObserver(forName: .init(ID + ".passo"), object: nil, queue: .main) { [weak self] n in  // assistente num passo (prints)
            if let p = (n.object as? String).flatMap(Int.init) { self?.passoAssistente?(p) }
        }
        dc.addObserver(forName: .init(ID + ".legenda"), object: nil, queue: .main) { [weak self] n in
            if (n.object as? String) == "dica" { self?.ilhas.first?.dica() } else { self?.ilhas.first?.mostrarLegenda() }
        }
        dc.addObserver(forName: .init(ID + ".pagina"), object: nil, queue: .main) { [weak self] n in  // abre a gaveta numa página (prints, atalhos)
            guard let i = self?.ilhas.first else { return }
            if !i.estado.aberta { i.mudar(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { withAnimation(Paleta.mola) { i.estado.pagina = (n.object as? String).flatMap { $0.isEmpty || $0 == "frota" ? nil : $0 } } }
        }
        // prints e GIF: troca o gosto de fora ("modo=light", "estilo=neon", "notch=alertas", "copiados=1"), com a mesma animação
        dc.addObserver(forName: .init(ID + ".visual"), object: nil, queue: .main) { [weak self] n in
            guard let s = self, let p = (n.object as? String)?.split(separator: "=", maxSplits: 1).map(String.init), p.count == 2 else { return }
            withAnimation(Paleta.reduzir ? nil : Paleta.mola) {
                switch p[0] {
                case "modo": s.cfg.c.visual.modo = p[1]
                case "estilo": if let e = (Presets.todos + s.cfg.c.visual.presets).first(where: { $0.id == p[1] }) { s.cfg.c.visual.estilo = e }
                case "notch": s.cfg.c.visual.notch = p[1]
                case "densidade": s.cfg.c.visual.densidade = p[1]
                case "copiados": s.cfg.c.modulos.copiados = p[1] == "1"
                default: break
                }
            }
        }
        // teste de "troca de tela" e "despertar" sem dormir a tela (com bloqueio imediato, dormir tranca a sessão):
        // dispara as MESMAS notificações que o macOS dispara, então roda exatamente os mesmos tratadores
        dc.addObserver(forName: .init(ID + ".teste"), object: nil, queue: .main) { n in
            if (n.object as? String) == "telas" { NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp) }
            if (n.object as? String) == "despertar" { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared) }
        }
    }

    /// A config sem o que é só da interface: se só isso mudou, o coletor não precisa reiniciar.
    static func soColeta(_ c: Config) -> Config {
        var x = c
        x.visual = CVisual()
        x.precos = []
        x.aparencia.corAtencao = ""; x.aparencia.corCritico = ""; x.aparencia.ilha = true; x.aparencia.todasTelas = false; x.aparencia.atalho = false
        x.modulos.copiados = false; x.modulos.ordem = []; x.modulos.acoes = true; x.modulos.pergunta = true
        x.aparelhos = [:]
        return x
    }

    /// Abre a ilha (da barra de menus): numa página ("mac:<nome>", "conta:<id>"…) ou na frota.
    func abrirPagina(_ p: String?) {
        guard let i = ilhas.first else { return }
        if !i.estado.aberta { i.mudar(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (p == nil ? 0 : 0.35)) { withAnimation(Paleta.reduzir ? nil : Paleta.mola) { i.estado.pagina = p } }
    }

    func aplicarCores() {
        Paleta.ambar = Color(hex: cfg.c.aparencia.corAtencao)
        Paleta.vermelho = Color(hex: cfg.c.aparencia.corCritico)
    }

    /// Uma ilha por tela. Mesma tela com o mesmo notch só é reposicionada: recriar a cada mudança de parâmetro de tela
    /// (despertar, Dock, resolução) tirava o notch da tela e punha de volta.
    func montarIlhas() {
        let ap = cfg.c.aparencia
        let telas = !ap.ilha ? [] : ap.todasTelas ? NSScreen.screens : Array(NSScreen.screens.prefix(1))  // [0] = tela da barra
        var novas: [Ilha] = []
        for t in telas {
            if let i = ilhas.first(where: { $0.id == Ilha.id(t) && $0.notch == Ilha.medida(t) }), !novas.contains(where: { $0 === i }) {
                i.posicionar(t)
                novas.append(i)
            } else {
                novas.append(Ilha(tela: t, modelo: modelo, cfg: cfg))
            }
        }
        for i in ilhas where !novas.contains(where: { $0 === i }) { i.encerrar() }
        ilhas = novas
    }

    /// Atalho global opcional (Ajustes › Geral: as teclas e o que faz): abre a gaveta com o cursor na pergunta rápida, ou
    /// abre e fecha a gaveta. Carbon: não pede permissão de Acessibilidade.
    func ligarAtalho() {
        if let a = atalho { UnregisterEventHotKey(a); atalho = nil }
        let v = cfg.c.visual, gaveta = v.atalhoAcao == "gaveta"
        guard cfg.c.aparencia.atalho, gaveta || cfg.c.modulos.pergunta else { return }
        atalhoGlobal = { [weak self] in
            guard let s = self, let i = s.ilhas.first else { return }
            if gaveta { i.mudar(!i.estado.aberta); return }
            if !i.estado.aberta { i.mudar(true) }
            i.estado.pagina = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { s.modelo.pergunta.foco = true }
        }
        if !tratadorAtalho {  // um tratador só (instalar de novo a cada gravação dispararia o atalho 2×)
            var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in DispatchQueue.main.async { atalhoGlobal() }; return noErr }, 1, &tipo, nil, nil)
            tratadorAtalho = true
        }
        let o = Atalhos.opcoes.first { $0.id == v.atalhoTecla } ?? Atalhos.opcoes[0]
        RegisterEventHotKey(UInt32(o.tecla), UInt32(o.mods), EventHotKeyID(signature: OSType(0x46524F54), id: 1), GetApplicationEventTarget(), 0, &atalho)
    }

    /// O assistente (1ª execução, ou pelos Ajustes): parte da config de agora e grava a que sair dele.
    func abrirAssistente() {
        if let j = assistente, j.isVisible { praFrente(j); return }
        let j = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        j.title = t("Boas-vindas")
        j.titlebarAppearsTransparent = true
        j.isReleasedWhenClosed = false
        let ea = EstadoAssistente(cfg.c)
        passoAssistente = { [weak ea] p in ea?.passo = p }
        j.contentView = NSHostingView(rootView: ComIdioma { AssistenteView(e: ea, a: self.ajustes) { [weak self, weak j] nova in
            guard let s = self else { return }
            s.cfg.c = nova
            s.cfg.gravar()
            j?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { s.ilhas.first?.dica() }
        } })
        j.center()
        assistente = j
        praFrente(j)
    }
}

/// Tela principal com notch físico (MacBook): o que não cabe à direita do notch o macOS simplesmente não desenha.
var telaComNotch: Bool { (NSScreen.screens.first?.safeAreaInsets.top ?? 0) > 0 }

/// O texto do item da barra: monocromático como os itens da Apple (símbolo + o Mac mais exigido; ⚠︎ em texto, sem emoji
/// colorido). Em Mac com notch, no automático, só o símbolo: com texto o item não cabia e sumia (MacBook Air com a barra cheia).
func rotuloBarra(_ e: Estado) -> String {
    let modo = UserDefaults.standard.string(forKey: "barraTexto") ?? "auto"  // auto | texto | icone
    let soIcone = modo == "icone" || (modo == "auto" && telaComNotch)
    return soIcone ? "" : " " + (e.pico ?? "…").replacingOccurrences(of: "⚠️", with: "⚠︎")
}

#if !TESTE  // teste/config.sh compila o app com -D TESTE e o @main dele
@main
#endif
struct FleetNotch: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var app

    var body: some Scene {
        // o item da barra de menus é nosso (ItemBarra, no AppDelegate): o MenuBarExtra em janela parava de abrir depois que
        // os Ajustes apareciam uma vez
        Settings {
            ComIdioma { AjustesView(store: app.cfg, a: app.ajustes, assistente: { app.abrirAssistente() }, modelo: app.modelo) }
        }
    }
}
