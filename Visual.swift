// O que é gosto e o que é novo na 0.3: estilos dos anéis (presets estilo Apple Watch e o editor), modo Light, o uso por
// modelo de cada conta de IA, o histórico do que se copia, o painel da barra de menus e as telas de ajuste que os Ajustes
// e o assistente usam do mesmo jeito. A config mora em CVisual (Ajustes.swift); Paleta.v é o que está valendo agora.
import Carbon
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presets dos anéis

enum Presets {
    static func a(_ cor: String, _ cor2: String = "", espessura: Double = 1, trilho: Double = 0.16, brilho: Double = 0) -> CAnel {
        CAnel(cor: cor, cor2: cor2, espessura: espessura, trilho: trilho, brilho: brilho, redonda: true)
    }
    /// Os prontos. Nome traduzido na hora (nada de t() em let estático).
    static var todos: [CEstilo] {
        [CEstilo(id: "classico", nome: t("Clássico"), aneis: [a("#64D2FF"), a("#A69CFF"), a("#7DDBB8")]),
         CEstilo(id: "atividade", nome: t("Atividade"), aneis: [a("#FA114F", "#FF5DA2", trilho: 0.2), a("#9BF00B", "#D2FF5C", trilho: 0.2), a("#00D8FF", "#7AF3FF", trilho: 0.2)]),
         CEstilo(id: "mono", nome: t("Monocromático"), aneis: [a("#F2F2F7"), a("#AEAEB2"), a("#6E6E73", trilho: 0.22)]),
         CEstilo(id: "pastel", nome: t("Pastel"), aneis: [a("#FFB5C8"), a("#B5DCFF"), a("#C6F2C0")]),
         CEstilo(id: "neon", nome: t("Neon"), aneis: [a("#FF2BD6", "#FF8AEF", espessura: 0.85, trilho: 0.1, brilho: 0.8),
                                                    a("#00F0FF", "#8CFAFF", espessura: 0.85, trilho: 0.1, brilho: 0.8),
                                                    a("#B4FF00", "#E6FF8C", espessura: 0.85, trilho: 0.1, brilho: 0.8)]),
         CEstilo(id: "grafite", nome: t("Grafite"), aneis: [a("#C7C7CC", espessura: 0.75, trilho: 0.1), a("#8E8E93", espessura: 0.75, trilho: 0.1),
                                                           a("#636366", espessura: 0.75, trilho: 0.12)]),
         CEstilo(id: "orgulho", nome: t("Orgulho"), aneis: [a("#FF3B30", "#FF9F0A"), a("#FFD60A", "#30D158"), a("#0A84FF", "#BF5AF2")]),
         CEstilo(id: "marca", nome: t("Cor de cada IA"), aneis: [a("#64D2FF"), a("#A69CFF"), a("#7DDBB8")], contas: "marca")]
    }
}

/// A cor de cada marca de IA (anéis das contas no estilo "Cor de cada IA"). Desconhecida: a cor de destaque.
func corMarca(_ ferramenta: String) -> Color {
    let f = ferramenta.lowercased()
    if f.contains("claude") || f.contains("anthropic") { return Color(hex: "#D97757") }
    if f.contains("gpt") || f.contains("codex") || f.contains("openai") { return Color(hex: "#10A37F") }
    if f.contains("gemini") { return Color(hex: "#4E8DF5") }
    if f.contains("mistral") { return Color(hex: "#FA520F") }
    return Paleta.ciano
}

/// Nome curto de cada métrica que os anéis podem mostrar (Ajustes › Aparência › Anéis do Mac).
func nomeMetrica(_ k: String) -> String {
    ["cpu": "CPU", "gpu": "GPU", "ram": "RAM", "disco": t("Disco"), "temp": t("Temp.")][k] ?? k
}
var metricasDisponiveis: [(String, String)] { [("cpu", "CPU"), ("gpu", "GPU"), ("ram", "RAM"), ("disco", t("Disco do sistema")), ("temp", t("Temperatura"))] }

extension Medidas {
    func valor(_ k: String) -> Int {
        switch k { case "gpu": return gpu; case "ram": return ram; case "disco": return disco ?? 0; case "temp": return min(temp ?? 0, 100); default: return cpu }
    }
    /// "45%" ou, na temperatura, "45 °C".
    func texto(_ k: String) -> String { k == "temp" ? "\(temp ?? 0) °C" : "\(valor(k))%" }
}
extension Niveis {
    func valor(_ k: String) -> Int {
        switch k { case "gpu": return gpu; case "ram": return ram; case "disco": return disco ?? 0; case "temp": return temp ?? 0; default: return cpu }
    }
}

/// Prato com um ponto de estado no canto (o Light usa no lugar dos cartões e dos azulejos).
struct PratoSinal<C: View>: View {
    let sinal: Color?
    @ViewBuilder let conteudo: () -> C
    var body: some View {
        ZStack(alignment: .topTrailing) {
            conteudo().frame(width: 34, height: 34)
            if let s = sinal { Circle().fill(s).frame(width: 8, height: 8).overlay(Circle().stroke(Color.black, lineWidth: 1.5)).offset(x: 2, y: -2) }
        }.frame(width: 38, height: 38)
    }
}

extension String { var nilSeVazio: String? { isEmpty ? nil : self } }

/// Estado local de uma view: o @State do SDK novo é macro e o swiftc solto (sem Xcode) não acha o plugin.
final class Local<T>: ObservableObject { @Published var v: T; init(_ v: T) { self.v = v } }

// MARK: - Atalho global

enum Atalhos {
    static let opcoes: [(id: String, tecla: Int, mods: Int)] = [
        ("ctrl-opt-space", kVK_Space, controlKey | optionKey), ("opt-space", kVK_Space, optionKey), ("shift-cmd-space", kVK_Space, shiftKey | cmdKey),
        ("ctrl-opt-f", kVK_ANSI_F, controlKey | optionKey), ("opt-cmd-n", kVK_ANSI_N, optionKey | cmdKey)]
    static func rotulo(_ id: String) -> String {
        switch id {
        case "opt-space": return "⌥ " + t("Espaço")
        case "shift-cmd-space": return "⇧⌘ " + t("Espaço")
        case "ctrl-opt-f": return "⌃⌥F"
        case "opt-cmd-n": return "⌥⌘N"
        default: return "⌃⌥ " + t("Espaço")
        }
    }
}

// MARK: - Números

/// Tokens: compacto ("1,2 mi", "1.2M") ou completo ("1.234.567"), no idioma da interface.
func tokens(_ n: Int) -> String {
    let d = Double(n)
    if Paleta.v.numeros == "completos" || n < 1000 {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: Idioma.shared.codigo)
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    func um(_ x: Double) -> String { decimal(x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x)) }
    if d < 1e6 { return t("{0} mil", um(d / 1e3)) }
    if d < 1e9 { return t("{0} mi", um(d / 1e6)) }
    return t("{0} bi", um(d / 1e9))
}

/// Dólares: "US$ 3.112,88" (pt) / "$3,112.88" (en). Compacto acima de mil: sem centavos.
func dolares(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.locale = Locale(identifier: ["pt": "pt_BR", "en": "en_US", "es": "es_ES", "fr": "fr_FR"][Idioma.shared.codigo] ?? "en_US")
    if Paleta.v.numeros != "completos" && v >= 1000 { f.maximumFractionDigits = 0 }
    return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
}

// MARK: - Som e toque

enum Feedback {
    static func abrir(_ abrindo: Bool) {
        guard Paleta.v.somAbrir else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        let s = NSSound(named: abrindo ? "Tink" : "Pop")
        s?.volume = 0.25
        s?.play()
    }
    static func critico() {
        guard Paleta.v.somAlerta else { return }
        let s = NSSound(named: "Funk")
        s?.volume = 0.5
        s?.play()
    }
}

// MARK: - Uso por modelo (modelos.py faz a conta; aqui só se mostra)

struct ModeloUso: Decodable, Identifiable, Equatable {
    let id: String, nome: String, entrada: Int, saida: Int, cacheLe: Int, cacheEscreve: Int, respostas: Int, custo: Double?
    var total: Int { entrada + saida + cacheLe + cacheEscreve }
}
struct JanelaUso: Decodable, Equatable { let modelos: [ModeloUso]; let custo: Double; let semPreco: [String]; let tokens: Int }
struct DiaUso: Decodable, Equatable { let dia: String; let tokens: Int; let custo: Double }
struct Uso: Decodable, Equatable {
    var janelas: [String: JanelaUso]? = nil, arquivos: Int? = nil, compartilhado: [String]? = nil, dias: [DiaUso]? = nil, erro: String? = nil
}

final class UsoModelos: ObservableObject {
    @Published var dados: [String: Uso] = [:]
    @Published var lendo: Set<String> = []
    func carregar(_ conta: String, demo: Bool) {
        guard !lendo.contains(conta) else { return }
        lendo.insert(conta)
        Py.rodar("modelos", demo ? ["--demo"] : ["--conta", conta]) { [weak self] r in
            let d = (try? JSONSerialization.data(withJSONObject: r)).flatMap { try? JSONDecoder().decode(Uso.self, from: $0) }
            self?.dados[conta] = d ?? Uso(erro: r["erro"] as? String ?? t("sem resposta"))
            self?.lendo.remove(conta)
        }
    }
}

/// Cor de cada família de modelo (a mesma em toda a página): Fable âmbar, Opus coral, Sonnet lavanda, Haiku menta…
func corModelo(_ id: String) -> Color {
    let s = id.lowercased()
    let mapa: [(String, String)] = [("fable", "#FFB340"), ("mythos", "#FFB340"), ("opus", "#E8875F"), ("sonnet", "#A69CFF"), ("haiku", "#7DDBB8"),
                                    ("sol", "#FFD60A"), ("terra", "#30D158"), ("mini", "#7DDBB8"), ("gpt", "#64D2FF")]
    if let c = mapa.first(where: { s.contains($0.0) }) { return Color(hex: c.1) }
    let resto = ["#FF9F0A", "#64D2FF", "#BF5AF2", "#FF6482"]
    return Color(hex: resto[abs(s.hashValue) % resto.count])
}

/// A página de uma conta de IA: quanto cada modelo gastou (tokens de entrada, saída e cache, custo estimado) hoje, nos
/// últimos 7 dias ou no mês. Só leitura e só local: os números vêm dos registros que o Claude Code e o Codex já gravam.
struct PaginaConta: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let c: Conta, cia: CIA?, voltar: () -> Void
    @ObservedObject var uso: UsoModelos
    let demo: Bool
    @AppStorage("janelaUso") private var janela = "7d"
    var body: some View {
        let id = c.id ?? c.rotulo, d = uso.dados[id]
        VStack(alignment: .leading, spacing: 14) {
            Voltar(acao: voltar)
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Anel(valor: c.nivel < 0 ? 0 : c.pct, cor: Paleta.corConta(c), diametro: 52, linha: 4)
                    Logo(c: c, tamanho: 26)
                }.frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.rotulo).font(.system(size: 15, weight: .semibold))
                    Text([c.ferramenta ?? "", c.nivel >= 0 ? usoJanela(c) : nil, c.reset.map { t("volta {0}", $0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(.system(size: 11)).foregroundStyle(Paleta.terciario)
                }
                Spacer(minLength: 20)
                Segmento(opcoes: [("hoje", t("Hoje")), ("7d", t("7 dias")), ("mes", t("Mês"))], escolha: $janela)
            }
            if let j = d?.janelas?[janela] {
                resumo(j, d!)
                tabela(j)
                rodape(j, d!)
            } else if let e = d?.erro {
                Text(e).font(.system(size: 12)).foregroundStyle(Paleta.terciario).frame(width: 520, alignment: .leading)
            } else {
                Carregando(texto: t("Lendo os registros deste Mac… a primeira vez leva alguns segundos")).frame(height: 120)
            }
        }
        .frame(width: 600, alignment: .leading)
        .animation(Paleta.reduzir ? nil : .easeOut(duration: 0.2), value: janela)
        .onAppear { uso.carregar(id, demo: demo) }
    }

    func resumo(_ j: JanelaUso, _ d: Uso) -> some View {
        let semCusto = !j.modelos.isEmpty && j.modelos.allSatisfy { $0.custo == nil }
        return HStack(alignment: .bottom, spacing: 30) {
            numero(semCusto ? "—" : dolares(j.custo), t("custo estimado"), grande: true)
            numero(tokens(j.tokens), t("tokens"))
            numero(tokens(j.modelos.reduce(0) { $0 + $1.respostas }), t("respostas"))
            Spacer(minLength: 10)
            if janela != "hoje", let dias = d.dias, dias.contains(where: { $0.tokens > 0 }) { Barras7(dias: dias, porCusto: !semCusto) }
        }
    }

    func numero(_ v: String, _ rotulo: String, grande: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: grande ? 26 : 17, weight: .semibold, design: .rounded).monospacedDigit()).contentTransition(.numericText())
            Text(rotulo).font(.system(size: 10)).foregroundStyle(Paleta.terciario)
        }
    }

    func tabela(_ j: JanelaUso) -> some View {
        let total = j.custo > 0 ? j.custo : Double(max(j.tokens, 1))
        return Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 3) {
            GridRow {
                Text(t("Modelo")).gridColumnAlignment(.leading)
                Text(t("Entrada")); Text(t("Saída")); Text(t("Cache lido")); Text(t("Cache escrito")); Text(t("Custo"))
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Paleta.terciario)
            if j.modelos.isEmpty {
                GridRow { Text(t("Nenhum uso neste período.")).font(.system(size: 12)).foregroundStyle(Paleta.terciario).gridCellColumns(6) }
            }
            ForEach(j.modelos) { m in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(corModelo(m.id)).frame(width: 7, height: 7)
                        Text(m.nome).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }.gridColumnAlignment(.leading)
                    Group {
                        Text(tokens(m.entrada)); Text(tokens(m.saida)); Text(tokens(m.cacheLe)); Text(tokens(m.cacheEscreve))
                    }.font(.system(size: 12).monospacedDigit()).foregroundStyle(Paleta.secundario)
                    Text(m.custo.map(dolares) ?? t("sem preço")).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(m.custo == nil ? Paleta.terciario : Paleta.primario)
                }
                GridRow {
                    let parte = (j.custo > 0 ? (m.custo ?? 0) : Double(m.total)) / total
                    Fatia(parte: parte, cor: corModelo(m.id)).gridCellColumns(6).padding(.bottom, 6)
                }
            }
        }
    }

    func rodape(_ j: JanelaUso, _ d: Uso) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !j.semPreco.isEmpty {
                Text(t("Sem preço na tabela: {0}. Dá pra pôr em Ajustes › IA › Preços.", j.semPreco.joined(separator: ", ")))
            }
            if let o = d.compartilhado, !o.isEmpty {
                Text(t("Mesmo histórico de {0}: as duas contas gravam na mesma pasta, então os números são da soma.", o.joined(separator: ", ")))
            }
            Text(t("Estimativa pela tabela de preços local (preço de API, não o da assinatura). Lido de {0} registros deste Mac; nada sai daqui.", tokens(d.arquivos ?? 0)))
        }.font(.system(size: 10)).foregroundStyle(Paleta.terciario).fixedSize(horizontal: false, vertical: true).frame(width: 600, alignment: .leading)
    }
}

/// Fração de um total, como as barrinhas do widget de Tempo de Uso: trilho apagado, a cor do modelo por cima.
struct Fatia: View {
    let parte: Double, cor: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(Paleta.contraste ? 0.18 : 0.07))
                Capsule().fill(cor).frame(width: max(3, g.size.width * min(max(parte, 0), 1)))
            }
        }.frame(height: 3)
    }
}

/// Os últimos 7 dias em barras; hoje na cor de destaque. O dia da semana na letra do idioma.
struct Barras7: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let dias: [DiaUso], porCusto: Bool
    var body: some View {
        let v = dias.map { porCusto ? $0.custo : Double($0.tokens) }, maior = max(v.max() ?? 1, 0.0001)
        let entra = DateFormatter(), sai = DateFormatter()
        entra.dateFormat = "yyyy-MM-dd"
        sai.locale = Locale(identifier: Idioma.shared.codigo)
        sai.dateFormat = "EEEEE"
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(dias.enumerated()), id: \.offset) { i, x in
                VStack(spacing: 3) {
                    Capsule().fill(i == dias.count - 1 ? Paleta.ciano : Color.white.opacity(0.35))
                        .frame(width: 7, height: max(3, 34 * v[i] / maior))
                    Text(entra.date(from: x.dia).map { sai.string(from: $0) } ?? "").font(.system(size: 8, weight: .medium)).foregroundStyle(Paleta.terciario)
                }.help(x.dia + " · " + (porCusto ? dolares(x.custo) : tokens(x.tokens)))
            }
        }.frame(height: 48, alignment: .bottom)
    }
}

/// Segmentos em cápsula, como o seletor de período do app Saúde (o Picker segmentado do sistema não combina com o preto).
struct Segmento: View {
    let opcoes: [(String, String)]
    @Binding var escolha: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(opcoes, id: \.0) { o in
                Button { escolha = o.0 } label: {
                    Text(o.1).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(escolha == o.0 ? Color.black : Paleta.secundario)
                        .background(Capsule().fill(escolha == o.0 ? Color.white.opacity(0.9) : .clear))
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(2).background(Capsule().fill(Color.white.opacity(Paleta.contraste ? 0.16 : 0.08)))
    }
}

// MARK: - Histórico do que se copia (⌘C)

/// Só com o módulo ligado: lê o NSPasteboard pelo changeCount a cada 0,8 s (nada é lido se nada mudou) e guarda na MEMÓRIA
/// os últimos itens (texto, link, imagem, arquivo). Nunca grava em disco nem em log. Ignora o que o macOS e os gerenciadores
/// de senha marcam como sensível (org.nspasteboard.*) e o que vem dos apps excluídos. No modo demonstração nunca lê nada:
/// mostra itens inventados.
final class Copiados: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let tipo: String       // texto | link | imagem | arquivo
        let texto: String      // o texto, o link, o nome do arquivo ou "Imagem 1200 × 800"
        var miniatura: NSImage? = nil
        var dado: Data? = nil, tipoDado: NSPasteboard.PasteboardType? = nil
        var urls: [URL] = []
        var quando = Date()
        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }
    @Published private(set) var itens: [Item] = []
    @Published var recemCopiado: UUID?
    private var timer: Timer?
    private var ultimo = NSPasteboard.general.changeCount
    private var meu = -1
    private var c = CCopiados()
    private var demo = false
    static let sensiveis: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]

    func configurar(ligado: Bool, demo: Bool, _ c: CCopiados) {
        self.c = c
        if demo != self.demo || !ligado { itens = [] }
        self.demo = demo
        if ligado && demo {
            timer?.invalidate(); timer = nil
            if itens.isEmpty { itens = Copiados.falsos() }
        } else if ligado {
            if timer == nil {
                ultimo = NSPasteboard.general.changeCount  // o que já estava copiado antes de ligar não entra
                let t = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.checar() }
                t.tolerance = 0.4
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            aparar()
        } else {
            timer?.invalidate(); timer = nil
        }
    }

    func limpar() { itens = [] }

    func checar() {
        let pb = NSPasteboard.general
        aparar()
        guard pb.changeCount != ultimo else { return }
        ultimo = pb.changeCount
        guard ultimo != meu, let tipos = pb.types else { return }
        if tipos.contains(where: { Copiados.sensiveis.contains($0.rawValue) }) { return }
        let origem = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if c.excluidos.contains(where: { !$0.isEmpty && origem.caseInsensitiveCompare($0) == .orderedSame }) { return }
        var novo: Item?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            novo = Item(tipo: "arquivo", texto: urls.map(\.lastPathComponent).joined(separator: ", "), miniatura: NSWorkspace.shared.icon(forFile: urls[0].path), urls: urls)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard s.utf8.count < 1_000_000 else { return }
            let link = !s.contains("\n") && (s.hasPrefix("http://") || s.hasPrefix("https://")) && URL(string: s.trimmingCharacters(in: .whitespaces)) != nil
            novo = Item(tipo: link ? "link" : "texto", texto: s)
        } else if let tp = [NSPasteboard.PasteboardType.png, .tiff].first(where: tipos.contains), let d = pb.data(forType: tp), d.count < 25_000_000,
                  let img = NSImage(data: d) {
            novo = Item(tipo: "imagem", texto: t("Imagem {0} × {1}", Int(img.size.width), Int(img.size.height)), miniatura: Copiados.mini(img), dado: d, tipoDado: tp)
        }
        guard let n = novo else { return }
        itens.removeAll { $0.tipo == n.tipo && $0.texto == n.texto && n.tipo != "imagem" }  // copiou de novo: sobe pro começo
        itens.insert(n, at: 0)
        aparar()
    }

    /// Limite e validade (Ajustes › Copiados).
    private func aparar() {
        guard !itens.isEmpty, !demo else { return }
        let antes = itens.count
        var x = itens
        if c.expira > 0 { x.removeAll { Date().timeIntervalSince($0.quando) > Double(c.expira) } }
        if x.count > c.limite { x = Array(x.prefix(max(1, c.limite))) }
        if x.count != antes { itens = x }
    }

    /// Copia de volta. O próprio app não entra no histórico de novo (o changeCount da cópia fica marcado).
    func copiar(_ i: Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch i.tipo {
        case "arquivo": pb.writeObjects(i.urls as [NSURL])
        case "imagem": if let d = i.dado, let tp = i.tipoDado { pb.setData(d, forType: tp) }
        default: pb.setString(i.texto, forType: .string)
        }
        meu = pb.changeCount
        if !demo { ultimo = meu }
        recemCopiado = i.id
        if let k = itens.firstIndex(of: i), !demo { var x = itens[k]; x.quando = Date(); itens.remove(at: k); itens.insert(x, at: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in if self?.recemCopiado == i.id { self?.recemCopiado = nil } }
    }

    static func mini(_ img: NSImage) -> NSImage {
        let lado: CGFloat = 96, s = img.size, k = lado / max(s.width, s.height, 1)
        let r = NSImage(size: NSSize(width: max(1, s.width * k), height: max(1, s.height * k)))
        r.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: r.size), from: .zero, operation: .copy, fraction: 1)
        r.unlockFocus()
        return r
    }

    /// Modo demonstração (prints do README): itens inventados, nunca o que está de verdade na área de transferência.
    static func falsos() -> [Item] {
        let img = NSImage(size: NSSize(width: 96, height: 64), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.35, alpha: 1), NSColor(red: 0.55, green: 0.32, blue: 0.95, alpha: 1)])?.draw(in: r, angle: 35)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 58, y: 34, width: 16, height: 16)).fill()
            return true
        }
        let agora = Date()
        return [Item(tipo: "texto", texto: t("Reunião de produto às 15h, sala 2"), quando: agora.addingTimeInterval(-120)),
                Item(tipo: "link", texto: "https://example.com/roadmap", quando: agora.addingTimeInterval(-600)),
                Item(tipo: "imagem", texto: t("Imagem {0} × {1}", 1200, 800), miniatura: img, quando: agora.addingTimeInterval(-1500)),
                Item(tipo: "texto", texto: "git commit -m \"ship 0.3\"", quando: agora.addingTimeInterval(-3600)),
                Item(tipo: "arquivo", texto: "notas.md", miniatura: NSWorkspace.shared.icon(for: UTType(filenameExtension: "md") ?? .plainText),
                     quando: agora.addingTimeInterval(-7200))]
    }
}

/// O que foi copiado, na gaveta: uma fileira de miniaturas. Clique copia de volta; o hover mostra o texto na legenda.
struct BlocoCopiados: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    @ObservedObject var c: Copiados
    let luz: (String) -> Double
    var body: some View {
        HStack(spacing: 8) {
            if c.itens.isEmpty {
                Image(systemName: "doc.on.clipboard").font(.system(size: 13)).foregroundStyle(Paleta.terciario).frame(width: 30)
                Text(t("Nada copiado ainda. O que você copiar (⌘C) aparece aqui.")).font(.system(size: 11)).foregroundStyle(Paleta.terciario)
                Spacer(minLength: 0)
            } else {
                ForEach(c.itens.prefix(Paleta.leve ? 10 : 7)) { i in
                    ItemCopiado(i: i, copiado: c.recemCopiado == i.id).opacity(luz("clip:" + i.id.uuidString)).contentShape(Rectangle())
                        .alvo("clip:" + i.id.uuidString).onTapGesture { c.copiar(i) }
                }
                Spacer(minLength: 0)
                Button { withAnimation(Paleta.mola) { c.limpar() } } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .medium)).foregroundStyle(Paleta.terciario).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help(t("Limpar o histórico"))
            }
        }.frame(height: Paleta.leve ? 44 : 52)
    }
}

struct ItemCopiado: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let i: Copiados.Item, copiado: Bool
    var body: some View {
        let leve = Paleta.leve, w: CGFloat = leve ? 44 : 70, h: CGFloat = leve ? 44 : 52
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(Paleta.contraste ? 0.14 : 0.07))
            if let m = i.miniatura, i.tipo == "imagem" {
                Image(nsImage: m).resizable().scaledToFill().frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let m = i.miniatura {
                Image(nsImage: m).resizable().scaledToFit().frame(width: leve ? 26 : 24, height: leve ? 26 : 24).padding(.bottom, leve ? 0 : 14)
            } else if leve {
                Image(systemName: i.tipo == "link" ? "link" : "text.alignleft").font(.system(size: 14, weight: .medium)).foregroundStyle(Paleta.secundario)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: i.tipo == "link" ? "link" : "text.alignleft").font(.system(size: 9, weight: .semibold)).foregroundStyle(Paleta.terciario)
                    Text(i.tipo == "link" ? (URL(string: i.texto)?.host ?? i.texto) : i.texto.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 9.5)).foregroundStyle(Paleta.secundario).lineLimit(2)
                }.frame(width: w - 12, height: h - 10, alignment: .topLeading)
            }
            if !leve && i.tipo == "arquivo" {
                Text(i.texto).font(.system(size: 9)).foregroundStyle(Paleta.secundario).lineLimit(1).padding(.horizontal, 4).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 5)
            }
            if copiado {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.6))
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Paleta.ciano)
            }
        }
        .frame(width: w, height: h)
        .animation(Paleta.reduzir ? nil : .easeOut(duration: 0.15), value: copiado)
    }
}

/// O texto do hover na legenda: o que é, há quanto tempo, e o começo do conteúdo numa linha.
func legendaCopiado(_ i: Copiados.Item) -> String {
    let min = Int(Date().timeIntervalSince(i.quando) / 60)
    let ha = min < 1 ? t("agora") : min < 60 ? t("há {0} min", min) : t("há {0} h", min / 60)
    let um = i.texto.replacingOccurrences(of: "\n", with: " ").prefix(90)
    return "\(um)  ·  \(ha)  ·  " + t("clique pra copiar de novo")
}

// MARK: - Painel da barra de menus

/// O item da barra de menus, agora um painel (MenuBarExtra em janela) no mesmo desenho da ilha: o estado da frota numa
/// frase, cada Mac como um mostradorzinho preto com os anéis, as contas de IA, o que pede atenção e os atalhos. Segue o
/// modo Light/Full e o estilo dos anéis; o resto acompanha o tema claro/escuro do sistema. Teclado: ⌘O abre a ilha,
/// ⌘, os Ajustes, ⌘Q sai; Tab percorre os botões (com "Navegação pelo teclado" ligada no macOS).
struct PainelBarra: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    @ObservedObject var m: Modelo
    @ObservedObject var cfg: ConfigStore
    let app: AppDelegate
    @Environment(\.openSettings) private var abrirAjustes
    var body: some View {
        let e = m.estado, leve = cfg.c.visual.modo == "light"
        let on = (cfg.c.modulos.macs ? e.maquinas : []).filter { $0.medidas != nil }, off = (cfg.c.modulos.macs ? e.maquinas : []).filter { $0.medidas == nil }
        let contas = cfg.c.modulos.ia ? e.contas ?? [] : [], a = atencao(e)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(a.first.map { Paleta.estado($0.nivel) } ?? Color.green.opacity(0.85)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.isEmpty ? t("Tudo em ordem") : a.count == 1 ? t("1 coisa pede atenção") : t("{0} coisas pedem atenção", a.count))
                        .font(.system(size: 13, weight: .semibold))
                    Text(t("Atualizado às {0}", e.atualizado ?? "—") + (cfg.c.demo ? " · " + t("demonstração") : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { abrir() } label: { Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 14)) }
                    .buttonStyle(.borderless).help(t("Abrir a ilha") + " (⌘O)").keyboardShortcut("o")
            }
            if !on.isEmpty || !off.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: leve ? 5 : 4), alignment: .leading, spacing: 10) {
                    ForEach(on, id: \.nome) { q in
                        Button { abrir("mac:" + (q.nome ?? "")) } label: { MiniMac(q: q, leve: leve) }.buttonStyle(.plain).help(dica(q))
                    }
                    ForEach(off, id: \.nome) { q in MiniMac(q: q, leve: leve).opacity(0.45).help(t("{0} offline", q.nome ?? "")) }
                }
            }
            if !contas.isEmpty {
                HStack(spacing: 12) {
                    ForEach(contas, id: \.rotulo) { c in
                        Button { abrir("conta:" + (c.id ?? c.rotulo)) } label: {
                            VStack(spacing: 3) {
                                ZStack {
                                    Circle().fill(Color.black)
                                    Anel(valor: c.nivel < 0 ? 0 : c.pct, cor: Paleta.corConta(c), diametro: 34, linha: 3)
                                    Logo(c: c, tamanho: 17)
                                }.frame(width: 38, height: 38)
                                if !leve {
                                    Text(c.semLogin == true ? t("sem login") : c.nivel < 0 ? "—" : "\(c.pct)%").font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                                        .foregroundStyle(c.nivel >= 1 ? Paleta.estado(c.nivel) : .secondary)
                                }
                            }
                        }.buttonStyle(.plain).help(dica(c))
                    }
                    Spacer(minLength: 0)
                }
            }
            if !leve && !a.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(a.prefix(4).enumerated()), id: \.offset) { _, x in
                        HStack(spacing: 7) {
                            Circle().fill(Paleta.estado(x.nivel)).frame(width: 6, height: 6)
                            Text(x.texto).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                if let u = e.painel, let url = URL(string: u) {
                    BotaoBarra(t("Painel"), "safari") { NSWorkspace.shared.open(url) }
                }
                BotaoBarra(t("Ajustes…"), "gearshape") { fechar(); abrirSettings = { abrirAjustes() }; abrirAjustesGlobal() }.keyboardShortcut(",")
                BotaoBarra(t("Assistente…"), "wand.and.stars") { fechar(); app.abrirAssistente() }
                Spacer()
                BotaoBarra(t("Sair"), "power") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: leve ? 300 : 340)
        .background(MaterialMenu().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
    }

    /// Fora do body: inline, o type-checker do Swift das Command Line Tools mais antigas estourava o tempo.
    func dica(_ q: Maquina) -> String {
        let nums: [String] = Paleta.v.metricas.map { (k: String) -> String in nomeMetrica(k) + " " + (q.medidas?.texto(k) ?? "") }
        return (q.nome ?? "") + "  ·  " + nums.joined(separator: "  ")
    }
    func dica(_ c: Conta) -> String { [c.rotulo, c.ferramenta ?? "", c.nivel < 0 ? c.card.joined(separator: " · ") : usoJanela(c)].joined(separator: " · ") }
    func fechar() { app.itemBarra?.fechar() }
    func abrir(_ pagina: String? = nil) { fechar(); app.abrirPagina(pagina) }
}

/// O material dos menus do sistema (vibrancy), que acompanha o claro/escuro e o Aumentar contraste.
struct MaterialMenu: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// O ícone da barra de menus e o painel dele: NSStatusItem + um NSPanel nosso, sem ativar o app (como um menu do sistema).
/// Abre e fecha no clique do ícone; fecha com Esc, clique fora ou num botão do painel. O tamanho acompanha o conteúdo
/// (Full/Light) com o topo preso embaixo do ícone.
final class ItemBarra: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let painel: Painel
    private weak var app: AppDelegate?
    private var conteudo: NSHostingView<ComIdioma<PainelBarra>>?  // só existe aberto: escondido, redesenhava a cada dado novo
    private var monitores: [Any] = []
    private var obs: [AnyCancellable] = []

    init(app: AppDelegate) {
        painel = Painel(chave: true)
        self.app = app
        super.init()
        painel.level = .popUpMenu
        painel.hasShadow = true
        painel.title = ConfigStore.nomeApp + " · painel"  // invisível (sem barra): é por ele que o teste/grava.swift acha o painel
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: ConfigStore.nomeApp)
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(clique)
        }
        obs = [app.modelo.$estado.receive(on: DispatchQueue.main).sink { [weak self] e in
                   self?.item.button?.title = rotuloBarra(e)
                   DispatchQueue.main.async { self?.ajustar() }  // aberto: o tamanho acompanha o conteúdo (linha de atenção nova…)
               },
               app.cfg.$c.receive(on: DispatchQueue.main).sink { [weak self] _ in DispatchQueue.main.async { self?.ajustar() } },
               NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
                   .sink { [weak self, weak app] _ in if let e = app?.modelo.estado { self?.item.button?.title = rotuloBarra(e) } }]
    }

    @objc func clique() { painel.isVisible ? fechar() : abrir() }

    func ajustar() {
        guard painel.isVisible, let conteudo = conteudo else { return }
        let s = conteudo.fittingSize
        if s != painel.frame.size { painel.setContentSize(s) }
        posicionar()
    }

    func abrir() {
        guard let app = app else { return }
        let c = NSHostingView(rootView: ComIdioma { PainelBarra(m: app.modelo, cfg: app.cfg, app: app) })
        c.sizingOptions = []  // o tamanho é medido na hora (fittingSize): restrição automática + reposicionar dava laço de layout
        conteudo = c
        painel.contentView = c
        painel.setContentSize(c.fittingSize)
        posicionar()
        painel.alphaValue = 0
        painel.orderFrontRegardless()
        painel.makeKey()
        NSAnimationContext.runAnimationGroup { c in c.duration = Paleta.reduzir ? 0 : 0.12; painel.animator().alphaValue = 1 }
        item.button?.highlight(true)
        monitores = [NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.fechar() },
                     NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                         if e.keyCode == 53 { self?.fechar(); return nil }
                         return e
                     }].compactMap { $0 }
    }

    func fechar() {
        monitores.forEach(NSEvent.removeMonitor)
        monitores = []
        item.button?.highlight(false)
        painel.orderOut(nil)
        painel.contentView = nil
        conteudo = nil
    }

    /// Embaixo do ícone, centrado nele e dentro da tela; o topo fica preso quando o tamanho muda.
    func posicionar() {
        guard let b = item.button, let w = b.window else { return }
        let r = w.convertToScreen(b.convert(b.bounds, to: nil)), s = painel.frame.size
        let tela = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(r.midX - s.width / 2, tela.minX + 8), tela.maxX - s.width - 8)
        painel.setFrameTopLeftPoint(NSPoint(x: x.rounded(), y: r.minY - 5))
    }
}

struct BotaoBarra: View {
    let titulo: String, simbolo: String, acao: () -> Void
    init(_ titulo: String, _ simbolo: String, _ acao: @escaping () -> Void) { self.titulo = titulo; self.simbolo = simbolo; self.acao = acao }
    var body: some View {
        Button(action: acao) { Label(titulo, systemImage: simbolo).font(.system(size: 12)) }.buttonStyle(.borderless).controlSize(.small)
    }
}

/// Um Mac no painel da barra: mostradorzinho preto (como uma complicação do Watch) com os anéis e o desenho do Mac.
struct MiniMac: View {
    var visual = Paleta.v  // o gosto como entrada: quem cria a view com a config nova muda a entrada, e ela redesenha
    let q: Maquina, leve: Bool
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.black)
                if let md = q.medidas { Aneis(md: md, nv: q.niveis, diametro: 46, linha: 3) }
                IconeDispositivo(valor: q.modelo ?? "", tamanho: 20, prato: false)
                if let a = q.alerta { Circle().fill(Paleta.estado(a.nivel)).frame(width: 9, height: 9).overlay(Circle().stroke(Color.black, lineWidth: 1.5)).offset(x: 18, y: -18) }
            }.frame(width: 52, height: 52)
            if !leve {
                Text(q.curto ?? q.nome ?? "").font(.system(size: 10, weight: .medium)).lineLimit(1)
                if let md = q.medidas {
                    Text(Paleta.v.metricas.map { "\(md.valor($0))" }.joined(separator: " · ")).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Peças dos Ajustes e do assistente (as mesmas nos dois lugares)

/// Os três anéis de amostra de um estilo (galeria e prévia), sobre preto como no notch.
struct AmostraAneis: View {
    let estilo: CEstilo, diametro: CGFloat, linha: CGFloat
    var valores = [78, 52, 88]
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Anel(valor: valores[i], cor: Color(hex: estilo.aneis[i].cor), diametro: diametro - CGFloat(i) * 2 * (linha + 2), linha: linha, estilo: estilo.aneis[i])
            }
        }.frame(width: diametro, height: diametro)
    }
}

/// Light × Full: dois cartões com a ilha desenhada em miniatura; o escolhido fica com a borda na cor de destaque.
struct SeletorModo: View {
    @Binding var modo: String
    let estilo: CEstilo
    var body: some View {
        HStack(spacing: 14) {
            cartao("light", t("Light"), t("Só ícones e anéis. Os números aparecem no hover ou no clique."))
            cartao("full", t("Full"), t("Tudo à vista: nomes, números e cartões."))
        }
    }
    func cartao(_ id: String, _ titulo: String, _ texto: String) -> some View {
        let sel = modo == id
        return Button { withAnimation(Paleta.reduzir ? nil : .spring(response: 0.4, dampingFraction: 0.9)) { modo = id } } label: {
            VStack(alignment: .leading, spacing: 6) {
                MiniIlha(leve: id == "light", estilo: estilo).frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Image(systemName: sel ? "checkmark.circle.fill" : "circle").foregroundStyle(sel ? Color.accentColor : .secondary)
                    Text(titulo).font(.system(size: 13, weight: .semibold))
                }
                Text(texto).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(sel ? 0.06 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(sel ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: sel ? 2 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// A gaveta em miniatura: o mostrador com os anéis; no Full, as linhas de texto embaixo dos Macs e os cartões.
struct MiniIlha: View {
    let leve: Bool, estilo: CEstilo
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black)
            Capsule().fill(Color.black).frame(width: 60, height: 10).offset(y: -4)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().stroke(Color(hex: estilo.aneis[i].cor), lineWidth: 1.5).frame(width: 8, height: 8)
                    }
                    Spacer()
                    if !leve { Capsule().fill(Color.white.opacity(0.25)).frame(width: 26, height: 3) }
                }.padding(.horizontal, 12)
                HStack(alignment: .center, spacing: 10) {
                    AmostraAneis(estilo: estilo, diametro: 22, linha: 2)
                    AmostraAneis(estilo: estilo, diametro: 40, linha: 3.2, valores: [64, 40, 82])
                    AmostraAneis(estilo: estilo, diametro: 22, linha: 2, valores: [30, 70, 50])
                }
                if !leve {
                    VStack(spacing: 3) {
                        Capsule().fill(Color.white.opacity(0.35)).frame(width: 46, height: 3)
                        Capsule().fill(Color.white.opacity(0.18)).frame(width: 70, height: 3)
                        HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)).frame(width: 34, height: 10) } }
                    }
                } else {
                    HStack(spacing: 6) { ForEach(0..<5, id: \.self) { _ in Circle().fill(Color.white.opacity(0.14)).frame(width: 8, height: 8) } }
                }
            }.padding(.top, 10)
        }
        .frame(width: 170, height: 96)
        .animation(Paleta.reduzir ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: leve)
    }
}

/// Galeria dos estilos: os prontos, os que a pessoa salvou e o "Personalizado" (o que está no editor agora).
struct GaleriaPresets: View {
    @Binding var v: CVisual
    var colunas = 4
    var body: some View {
        let lista = Presets.todos + v.presets + (v.estilo.id == "personalizado" ? [v.estilo] : [])
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: colunas), spacing: 12) {
            ForEach(lista) { p in
                let sel = v.estilo.id == p.id
                Button { withAnimation(Paleta.reduzir ? nil : .spring(response: 0.45, dampingFraction: 0.85)) { v.estilo = p } } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                            AmostraAneis(estilo: p, diametro: 46, linha: 4.5)
                        }
                        .frame(width: 64, height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(sel ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
                        Text(p.id == "personalizado" ? t("Personalizado") : p.nome).font(.system(size: 11, weight: sel ? .semibold : .regular))
                            .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.85).frame(height: 28, alignment: .top)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .contextMenu {
                        if v.presets.contains(where: { $0.id == p.id }) { Button(t("Apagar este preset"), role: .destructive) { v.presets.removeAll { $0.id == p.id } } }
                    }
                    .accessibilityLabel(t("Estilo {0}", p.id == "personalizado" ? t("Personalizado") : p.nome))
            }
        }
    }
}

/// O editor de cada anel, com a prévia ao vivo: cor ou degradê, espessura, fundo do trilho, brilho e ponta. Qualquer
/// mudança vira o estilo "Personalizado"; "Salvar como preset…" guarda com um nome.
struct EditorAneis: View {
    @Binding var v: CVisual
    @StateObject private var sel = Local(0)
    @StateObject private var salvando = Local(false)
    @StateObject private var nomeNovo = Local("")
    var anel: Int { sel.v }
    var body: some View {
        let a = v.estilo.aneis[anel]
        HStack(alignment: .top, spacing: 20) {
            PreviaViva(estilo: v.estilo, anel: anel)
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $sel.v) {
                    Text(t("Anel de fora")).tag(0); Text(t("Do meio")).tag(1); Text(t("De dentro")).tag(2)
                }.pickerStyle(.segmented).labelsHidden()
                HStack {
                    ColorPicker(t("Cor"), selection: Binding(get: { Color(hex: a.cor) }, set: { c in mudar { $0.cor = c.hex } }), supportsOpacity: false)
                    Spacer()
                    Toggle(t("Degradê"), isOn: Binding(get: { !a.cor2.isEmpty }, set: { on in mudar { $0.cor2 = on ? Color(hex: $0.cor).hex : "" } }))
                    if !a.cor2.isEmpty {
                        ColorPicker(t("até"), selection: Binding(get: { Color(hex: a.cor2) }, set: { c in mudar { $0.cor2 = c.hex } }), supportsOpacity: false)
                    }
                }
                deslizar(t("Espessura"), a.espessura, 0.5...1.8) { x in mudar { $0.espessura = x } }
                deslizar(t("Fundo do trilho"), a.trilho, 0...0.5) { x in mudar { $0.trilho = x } }
                deslizar(t("Brilho"), a.brilho, 0...1) { x in mudar { $0.brilho = x } }
                Toggle(t("Ponta arredondada"), isOn: Binding(get: { a.redonda }, set: { on in mudar { $0.redonda = on } }))
                Picker(t("Anéis das contas de IA"), selection: Binding(get: { v.estilo.contas }, set: { x in var e = v.estilo; e.contas = x; marcar(&e); v.estilo = e })) {
                    Text(t("Brancos")).tag("neutro"); Text(t("Cor de cada IA")).tag("marca"); Text(t("Cor de destaque")).tag("destaque")
                }
                HStack {
                    Button(t("Salvar como preset…")) { nomeNovo.v = ""; salvando.v = true }
                    Button(t("Voltar ao padrão")) { withAnimation { v.estilo = CEstilo() } }
                }
            }.frame(maxWidth: 360)
        }
        .alert(t("Salvar este estilo"), isPresented: $salvando.v) {
            TextField(t("Nome"), text: $nomeNovo.v)
            Button(t("Salvar")) {
                var e = v.estilo
                e.id = UUID().uuidString
                e.nome = nomeNovo.v.trimmingCharacters(in: .whitespaces).isEmpty ? t("Meu estilo") : nomeNovo.v
                v.presets.append(e)
                v.estilo = e
            }
            Button(t("Cancelar"), role: .cancel) {}
        }
    }

    func marcar(_ e: inout CEstilo) { e.id = "personalizado"; e.nome = t("Personalizado") }
    func mudar(_ f: (inout CAnel) -> Void) {
        var e = v.estilo
        f(&e.aneis[anel])
        marcar(&e)
        v.estilo = e
    }
    func deslizar(_ titulo: String, _ valor: Double, _ faixa: ClosedRange<Double>, _ set: @escaping (Double) -> Void) -> some View {
        LabeledContent(titulo) { Slider(value: Binding(get: { valor }, set: set), in: faixa).frame(width: 190) }
    }
}

/// A prévia ao vivo: os anéis do estilo enchendo devagar (Reduzir movimento: parados) e o anel em edição em destaque.
struct PreviaViva: View {
    let estilo: CEstilo, anel: Int
    @StateObject private var cheio = Local(false)
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black)
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Anel(valor: cheio.v ? [78, 52, 88][i] : [62, 38, 70][i], cor: Color(hex: estilo.aneis[i].cor), diametro: 130 - CGFloat(i) * 2 * 14, linha: 12,
                         estilo: estilo.aneis[i]).opacity(i == anel ? 1 : 0.78)
                }
            }.frame(width: 130, height: 130)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color(hex: estilo.aneis[i].cor)).frame(width: 5, height: 5).opacity(i == anel ? 1 : 0.5)
                }
            }.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 12)
        }
        .frame(width: 170, height: 180)
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard !Paleta.reduzir else { cheio.v = true; return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { cheio.v = true }
        }
    }
}

/// O resto do gosto: destaque, densidade, o que os anéis do Mac mostram, números, notch fechado, som e atalho.
struct OpcoesVisuais: View {
    @Binding var v: CVisual
    var basico = true  // false: sem destaque e densidade (o assistente mostra os dois no passo anterior)
    var body: some View {
        Group {
            if basico { destaque }
            metricas
        }
    }
    @ViewBuilder var destaque: some View {
            HStack {
                ColorPicker(t("Cor de destaque"), selection: Binding(get: { Color(hex: v.destaque) }, set: { v.destaque = $0.hex }), supportsOpacity: false)
                Button(t("Padrão")) { v.destaque = CVisual().destaque }.controlSize(.small)
            }
            Picker(t("Densidade"), selection: $v.densidade) {
                Text(t("Compacta")).tag("compacta"); Text(t("Padrão")).tag("padrao"); Text(t("Arejada")).tag("arejada")
            }.pickerStyle(.segmented)
    }
    @ViewBuilder var metricas: some View {
            LabeledContent(t("Anéis do Mac, de fora pra dentro")) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Picker("", selection: Binding(get: { v.metricas.indices.contains(i) ? v.metricas[i] : "cpu" }, set: { x in
                            while v.metricas.count < 3 { v.metricas.append("ram") }
                            v.metricas[i] = x
                        })) { ForEach(metricasDisponiveis, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 96)
                    }
                }
            }
            Picker(t("Números"), selection: $v.numeros) {
                Text(t("Compactos (1,2 mi)")).tag("compactos"); Text(t("Completos (1.234.567)")).tag("completos")
            }
            Picker(t("Notch fechado"), selection: $v.notch) {
                Text(t("Todos os sinais")).tag("completo"); Text(t("Só o que pede atenção")).tag("alertas"); Text(t("Só o notch, sem sinais")).tag("vazio")
            }
            Toggle(t("Abrir a gaveta ao passar o mouse no notch"), isOn: $v.abrirNoHover)
            Toggle(t("Som e toque ao abrir e fechar"), isOn: $v.somAbrir)
            Toggle(t("Tocar um som quando algo ficar crítico"), isOn: $v.somAlerta)
    }
}

/// Atalho global: liga/desliga, a combinação e o que ele faz.
struct OpcoesAtalho: View {
    @Binding var ligado: Bool
    @Binding var v: CVisual
    var body: some View {
        Group {
            Toggle(t("Atalho global"), isOn: $ligado)
            if ligado {
                Picker(t("Teclas"), selection: $v.atalhoTecla) { ForEach(Atalhos.opcoes, id: \.id) { Text(Atalhos.rotulo($0.id)).tag($0.id) } }
                Picker(t("O atalho"), selection: $v.atalhoAcao) {
                    Text(t("Abre a gaveta na pergunta rápida")).tag("pergunta"); Text(t("Abre e fecha a gaveta")).tag("gaveta")
                }
            }
        }
    }
}

/// Ajustes › Copiados: o histórico do ⌘C, desligado até a pessoa ligar, com as regras de privacidade à vista.
struct AbaCopiados: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var copiados: Copiados
    var body: some View {
        Form {
            Section {
                Toggle(t("Guardar o histórico do que você copia (⌘C)"), isOn: $store.c.modulos.copiados)
            } footer: {
                Text(t("Fica só na memória deste Mac e some quando o app fecha: nada vai pra disco, log ou internet. Nunca guarda o que o macOS e os gerenciadores de senha marcam como sensível, nem o que vem dos apps abaixo. No modo demonstração mostra itens de exemplo, nunca os seus."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("Limites")) {
                Stepper(value: $store.c.visual.copiados.limite, in: 5...100, step: 5) { Text(t("Guardar os últimos {0} itens", store.c.visual.copiados.limite)) }
                Picker(t("Apagar depois de"), selection: $store.c.visual.copiados.expira) {
                    Text(t("15 minutos")).tag(900); Text(t("1 hora")).tag(3600); Text(t("8 horas")).tag(28800); Text(t("1 dia")).tag(86400); Text(t("1 semana")).tag(604800)
                }
                HStack {
                    Text(copiados.itens.count == 1 ? t("{0} item agora", 1) : t("{0} itens agora", copiados.itens.count)).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Limpar o histórico"), role: .destructive) { copiados.limpar() }.disabled(copiados.itens.isEmpty)
                }
            }
            Section(t("Nunca guardar o que vem destes apps")) {
                ForEach(store.c.visual.copiados.excluidos, id: \.self) { b in
                    HStack {
                        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Image(systemName: "app.dashed").frame(width: 18)
                            Text(verbatim: b).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.c.visual.copiados.excluidos.removeAll { $0 == b } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button(t("Adicionar app…")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.application]
                    p.directoryURL = URL(fileURLWithPath: "/Applications")
                    if p.runModal() == .OK, let u = p.url, let b = Bundle(url: u)?.bundleIdentifier, !store.c.visual.copiados.excluidos.contains(b) {
                        store.c.visual.copiados.excluidos.append(b)
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

/// Ajustes › IA › Preços: a tabela local (USD por milhão de tokens) que estima o custo por modelo. Vazia na config = a
/// padrão do app; a primeira edição copia a padrão pra config.
struct TabelaPrecos: View {
    @ObservedObject var store: ConfigStore
    let fechar: () -> Void
    @StateObject private var p = Local<[CPreco]>([])
    @StateObject private var s = Local<CPreco.ID?>(nil)
    var padrao: [CPreco] { p.v }
    var body: some View {
        let lista = store.c.precos.isEmpty ? padrao : store.c.precos
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Preços por modelo")).font(.headline)
            Text(t("Dólares por milhão de tokens. O modelo casa pelo começo do nome (o mais longo ganha). Fica só neste Mac; o app nunca busca preço na internet."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Table(lista, selection: $s.v) {
                TableColumn(t("Modelo")) { p in TextField("", text: campoTexto(p.id), prompt: Text(verbatim: "claude-opus-5-5")) }.width(min: 150)
                TableColumn(t("Entrada")) { p in campoNumero(p.id, \.entrada) }
                TableColumn(t("Saída")) { p in campoNumero(p.id, \.saida) }
                TableColumn(t("Cache lido")) { p in campoNumero(p.id, \.cacheLe) }
                TableColumn(t("Cache 5 min")) { p in campoNumero(p.id, \.cache5m) }
                TableColumn(t("Cache 1 h")) { p in campoNumero(p.id, \.cache1h) }
            }.frame(minHeight: 260)
            HStack {
                Button { copiarSePreciso(); let n = CPreco(); store.c.precos.append(n); s.v = n.id } label: { Image(systemName: "plus") }
                Button { copiarSePreciso(); store.c.precos.removeAll { $0.id == s.v } } label: { Image(systemName: "minus") }.disabled(s.v == nil)
                Spacer()
                Button(t("Voltar ao padrão")) { store.c.precos = [] }.disabled(store.c.precos.isEmpty)
                Button(t("OK"), action: fechar).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 760, height: 440)
        .onAppear {
            Py.rodar("modelos", ["--precos"]) { r in
                p.v = (r["precos"] as? [[String: Any]] ?? []).map { d in
                    CPreco(modelo: d["modelo"] as? String ?? "", entrada: d["entrada"] as? Double, saida: d["saida"] as? Double, cacheLe: d["cacheLe"] as? Double,
                           cache5m: d["cache5m"] as? Double, cache1h: d["cache1h"] as? Double)
                }
            }
        }
    }
    func copiarSePreciso() { if store.c.precos.isEmpty { store.c.precos = padrao } }
    func campoTexto(_ id: String) -> Binding<String> {
        Binding(get: { (store.c.precos.isEmpty ? padrao : store.c.precos).first { $0.id == id }?.modelo ?? "" },
                set: { x in copiarSePreciso(); if let i = store.c.precos.firstIndex(where: { $0.id == id }) { store.c.precos[i].modelo = x } })
    }
    func campoNumero(_ id: String, _ k: WritableKeyPath<CPreco, Double?>) -> some View {
        TextField("", value: Binding(get: { (store.c.precos.isEmpty ? padrao : store.c.precos).first { $0.id == id }?[keyPath: k] },
                                     set: { x in copiarSePreciso(); if let i = store.c.precos.firstIndex(where: { $0.id == id }) { store.c.precos[i][keyPath: k] = x } }),
                  format: .number, prompt: Text("—")).multilineTextAlignment(.trailing)
    }
}
