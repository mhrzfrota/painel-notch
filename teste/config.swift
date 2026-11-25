// Teste da config (Swift): config antiga, sem os campos novos, abre igual; nome e ícone dos periféricos e dos
// servidores vão e voltam do config.json; o nome escolhido entra no lugar do original. Rodar: sh teste/config.sh
import Foundation

@main
struct TesteConfig {
    static func main() {
        let antiga = #"{"versao":1,"maquinas":[{"id":"a","nome":"Studio","host":"studio","icone":""}],"servidores":[{"id":"s","nome":"vps","host":"1.2.3.4"}]}"#
        guard let c = Config.ler(Data(antiga.utf8)) else { fatalError("config antiga não abriu") }
        precondition(c.aparelhos.isEmpty && c.servidores[0].icone == "" && c.maquinas[0].nome == "Studio", "config antiga mudou")

        let nova = #"{"aparelhos":{"bMagic Keyboard":{"nome":"Teclado do Edu"},"mDELL":{"icone":"sf:tv"}},"servidores":[{"id":"s","host":"h","icone":"des:raspberry"}],"maquinas":[{"id":"m","host":"mini","icone":"img:icones/x.png"}]}"#
        guard let n = Config.ler(Data(nova.utf8)) else { fatalError("config nova não abriu") }
        precondition(n.aparelhos["bMagic Keyboard"]?.nome == "Teclado do Edu" && n.aparelhos["bMagic Keyboard"]?.icone == "", "periférico sem ícone")
        precondition(n.aparelhos["mDELL"]?.icone == "sf:tv" && n.servidores[0].icone == "des:raspberry" && n.maquinas[0].icone == "img:icones/x.png")
        precondition(Config.ler(try! JSONEncoder().encode(n)) == n, "ida e volta pelo config.json")

        let a = Aparelho(id: "bMagic Keyboard", tipo: "teclado", nome: "Magic Keyboard", rotulo: "80%", detalhe: "Magic Keyboard · Bluetooth · bateria 80%", bateria: 80)
        let r = renomear(a, n.aparelhos[a.id])
        precondition(r.nome == "Teclado do Edu" && r.detalhe == "Teclado do Edu · Bluetooth · bateria 80%" && r.icone == "", "renomear")
        precondition(renomear(a, nil).nome == "Magic Keyboard" && renomear(a, CAparelho(icone: "sf:keyboard.fill")).nome == "Magic Keyboard")
        // 0.3: config de antes não tem visual, preços nem o bloco "copiados": abre no padrão (Full, Clássico, histórico desligado)
        precondition(c.visual == CVisual() && c.precos.isEmpty && !c.modulos.copiados && c.modulos.ordem.last == "copiados", "0.3: padrões")
        let ordemVelha = ##"{"modulos":{"ordem":["macs","topo"]},"visual":{"modo":"light","estilo":{"id":"neon","aneis":[{"cor":"#FF00FF"}]}},"precos":[{"modelo":"a"},{"modelo":"b","entrada":1}]}"##
        guard let v = Config.ler(Data(ordemVelha.utf8)) else { fatalError("config 0.3 não abriu") }
        precondition(v.modulos.ordem.prefix(2) == ["macs", "topo"] && v.modulos.ordem.contains("copiados"), "ordem: o bloco novo entra no fim")
        precondition(v.visual.modo == "light" && v.visual.estilo.aneis.count == 3 && v.visual.estilo.aneis[0].cor == "#FF00FF" && v.visual.estilo.aneis[0].espessura == 1,
                     "anel pela metade completa com o padrão")
        precondition(Set(v.precos.map(\.id)).count == 2 && v.precos[1].entrada == 1 && v.precos[0].entrada == nil, "preços sem id ganham um")
        precondition(Config.ler(try! JSONEncoder().encode(v)) == v, "0.3 ida e volta")
        print("ok config: antiga abre, nomes e ícones vão e voltam, renomear troca o nome e o detalhe, visual e preços da 0.3")
    }
}
