// Grava (ou fotografa) um retângulo da tela principal SÓ com a ilha, a barra de menus e o papel de parede:
// todo outro app sai do quadro (ScreenCaptureKit, filtro por app). Assim o vídeo não mostra chat, finanças nem diálogos.
// Uso: grava video saida.mp4 SEGUNDOS X Y W H [escala]  |  grava foto saida.png X Y W H [escala]  |  grava janela saida.png TITULO
// (janela: só aquela janela do app, com sombra, fundo transparente; TITULO = pedaço do título, ou "*" pra mais da frente)
// Rodar pelo Terminal.app (ele tem a permissão de Gravação de Tela).
import AVFoundation
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// SEM_FUNDO=1: tira também o papel de parede (com.apple.WindowManager); o app de teste põe um fundo neutro (FROTA_FUNDO=1)
let manter: Set<String> = ProcessInfo.processInfo.environment["SEM_FUNDO"] != nil ? [] : ["com.apple.WindowManager"]
let prefixo = ProcessInfo.processInfo.environment["PREFIXO"] ?? "-"  // bundle id do app (sem ele, nenhum app entra no quadro)
let semIlha = ProcessInfo.processInfo.environment["SEM_ILHA"] != nil  // SEM_ILHA=1: tira até a ilha (pra ver o que tem embaixo dela)
let tudo = ProcessInfo.processInfo.environment["TUDO"] != nil  // TUDO=1: não filtra nada (calibrar com menus do sistema)

final class Saida: NSObject, SCStreamOutput {
    let w: AVAssetWriter, inp: AVAssetWriterInput
    var inicio: CMTime?, quadros = 0
    init(url: URL, largura: Int, altura: Int) throws {
        try? FileManager.default.removeItem(at: url)
        w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        inp = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: largura, AVVideoHeightKey: altura,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoExpectedSourceFrameRateKey: 60]])
        inp.expectsMediaDataInRealTime = true
        w.add(inp)
        super.init()
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let st = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), st == .complete else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb)
        if inicio == nil { w.startWriting(); w.startSession(atSourceTime: t); inicio = t }
        if inp.isReadyForMoreMediaData { inp.append(sb); quadros += 1 }
    }
}

func filtro() async throws -> (SCContentFilter, SCDisplay) {
    let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let d = c.displays.first { $0.displayID == CGMainDisplayID() }!
    let fora = tudo ? [] : c.applications.filter { !(manter.contains($0.bundleIdentifier) || ($0.bundleIdentifier.hasPrefix(prefixo) && !semIlha)) }
    return (SCContentFilter(display: d, excludingApplications: fora, exceptingWindows: []), d)
}

let a = CommandLine.arguments
let modo = a[1], url = URL(fileURLWithPath: a[2])
let n = a.dropFirst(3).compactMap(Double.init)
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        if modo == "janela" {
            _ = CGMainDisplayID()  // inicializa a sessão do CoreGraphics (sem isso o filtro de janela aborta)
            let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let t = a[3]
            // "@pedaço": qualquer camada (o painel da barra de menus não fica na camada 0)
            let qualquer = t.hasPrefix("@"), p = qualquer ? String(t.dropFirst()) : t
            guard let w = c.windows.first(where: { ($0.owningApplication?.bundleIdentifier ?? "").hasPrefix(prefixo) && (qualquer || $0.windowLayer == 0)
                                                   && (p == "*" || ($0.title ?? "").contains(p)) }) else { print("erro: janela não achada"); sem.signal(); return }
            let cf = SCStreamConfiguration()
            cf.width = Int(w.frame.width); cf.height = Int(w.frame.height)
            cf.ignoreShadowsSingleWindow = false
            cf.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cf)
            let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, img, nil)
            CGImageDestinationFinalize(dst)
            print("janela ok", w.title ?? "", img.width, img.height)
            sem.signal()
            return
        }
        let (f, _) = try await filtro()
        let cfg = SCStreamConfiguration()
        let (x, y, w, h) = modo == "video" ? (n[1], n[2], n[3], n[4]) : (n[0], n[1], n[2], n[3])
        let esc = modo == "video" ? (n.count > 5 ? n[5] : 1) : (n.count > 4 ? n[4] : 1)
        cfg.sourceRect = CGRect(x: x, y: y, width: w, height: h)
        cfg.width = Int(w * esc); cfg.height = Int(h * esc)
        cfg.showsCursor = modo == "video" && ProcessInfo.processInfo.environment["SEM_CURSOR"] == nil
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        if modo == "foto" {
            let img = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
            let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, img, nil)
            CGImageDestinationFinalize(dst)
            print("foto ok", img.width, img.height)
        } else {
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 8
            let s = try Saida(url: url, largura: cfg.width, altura: cfg.height)
            let st = SCStream(filter: f, configuration: cfg, delegate: nil)
            try st.addStreamOutput(s, type: .screen, sampleHandlerQueue: DispatchQueue(label: "grava"))
            try await st.startCapture()
            try await Task.sleep(nanoseconds: UInt64(n[0] * 1e9))
            try await st.stopCapture()
            s.inp.markAsFinished()
            await s.w.finishWriting()
            print("video ok", s.quadros, "quadros", s.w.status.rawValue, s.w.error.map { "\($0)" } ?? "")
        }
    } catch { print("erro", error) }
    sem.signal()
}
sem.wait()
