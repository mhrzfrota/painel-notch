// Dirige a ilha pra teste: eventos sintéticos de mouse/teclado (CGEvent) e lista das janelas do FleetNotch.
// Uso: ctl move X Y | click X Y | rclick X Y | down X Y | up X Y | key CODE | type TEXTO | sleep S | glide X0 Y0 X1 Y1 S | wins
// Coordenadas globais, origem no canto superior esquerdo da tela principal (as do CGEvent).
import CoreGraphics
import Foundation

func post(_ t: CGEventType, _ x: Double, _ y: Double) {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: t == .rightMouseDown || t == .rightMouseUp ? .right : .left)
    // clique de verdade tem clickCount 1 (sem isso um NSButton, como o ícone da barra de menus, ignora o clique)
    if t != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.flags = []  // sem modificador herdado: depois de um ⌘W sintético o clique saía como ⌘-clique (no ícone da barra, = arrastar)
    e?.post(tap: .cghidEventTap)
}

var a = Array(CommandLine.arguments.dropFirst())
func num() -> Double { Double(a.removeFirst())! }
while !a.isEmpty {
    switch a.removeFirst() {
    case "move": let x = num(), y = num(); post(.mouseMoved, x, y)
    case "down": let x = num(), y = num(); post(.leftMouseDown, x, y)
    case "up": let x = num(), y = num(); post(.leftMouseUp, x, y)
    case "click":
        let x = num(), y = num()
        post(.mouseMoved, x, y); usleep(30_000)
        post(.leftMouseDown, x, y); usleep(60_000)
        post(.leftMouseUp, x, y)
    case "rclick":  // botão direito (menu de contexto)
        let x = num(), y = num()
        post(.mouseMoved, x, y); usleep(30_000)
        post(.rightMouseDown, x, y); usleep(60_000)
        post(.rightMouseUp, x, y)
    case "glide":  // movimento contínuo, 60 Hz
        let x0 = num(), y0 = num(), x1 = num(), y1 = num(), s = num()
        let n = max(1, Int(s * 60))
        for i in 0...n { let t = Double(i) / Double(n); post(.mouseMoved, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t); usleep(16_667) }
    case "key":
        let k = CGKeyCode(num())
        CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true)?.post(tap: .cghidEventTap); usleep(40_000)
        CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false)?.post(tap: .cghidEventTap)
    case "ctrlkey":  // ctrl + tecla (troca de Space: ctrl+→ 124, ctrl+← 123)
        let k = CGKeyCode(num())
        for d in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: d); e?.flags = .maskControl; e?.post(tap: .cghidEventTap); usleep(40_000)
        }
    case "type":  // digita um texto (unicode), letra a letra
        for ch in a.removeFirst() {
            for d in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: d)
                var u = Array(String(ch).utf16)
                e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                e?.post(tap: .cghidEventTap)
                usleep(d ? 20_000 : 45_000)
            }
        }
    case "cmd":  // ⌘ + tecla (⌘W = cmd 13)
        let k = CGKeyCode(num())
        for d in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: d); e?.flags = .maskCommand; e?.post(tap: .cghidEventTap); usleep(40_000)
        }
    case "atalho":  // ⌃⌥Espaço (o atalho global da pergunta rápida)
        for d in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: d); e?.flags = [.maskControl, .maskAlternate]; e?.post(tap: .cghidEventTap); usleep(40_000)
        }
    case "notify":  // notificação distribuída: notify NOME OBJETO
        let nome = a.removeFirst(), obj = a.removeFirst()
        DistributedNotificationCenter.default().postNotificationName(.init(nome), object: obj, userInfo: nil, deliverImmediately: true)
        usleep(50_000)
    case "sleep": usleep(useconds_t(num() * 1_000_000))
    case "wins":
        let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in l where ((w[kCGWindowOwnerName as String] as? String) ?? "").hasPrefix("FleetNotch") {
            print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, w[kCGWindowBounds as String]!, w[kCGWindowIsOnscreen as String] ?? "-", w[kCGWindowAlpha as String]!)
        }
    default: break
    }
}
