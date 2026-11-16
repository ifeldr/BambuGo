import AppKit

/// Icona della barra dei menu: la stampante stilizzata dell'app, in versione template
/// (macOS la colora da sé per tema chiaro/scuro). L'oggetto sul piatto cresce con l'avanzamento
/// e un piccolo simbolo in basso a destra indica pausa, fine o problemi.
enum MenuBarIcon {
    enum Badge { case none, pause, done, failed, warning }

    @MainActor
    static func image(for store: PrinterStore) -> NSImage {
        var badge = Badge.none
        var progress: Double?
        var dimmed = false

        switch store.state {
        case .notConfigured, .connecting:
            dimmed = true
        case .error:
            badge = .warning
            dimmed = true
        case .connected:
            if !store.hasData { dimmed = true; break }
            let s = store.status
            switch s.gcodeState {
            case "RUNNING", "PREPARE", "SLICING":
                progress = Double(s.percent) / 100
            case "PAUSE":
                progress = Double(s.percent) / 100
                badge = .pause
            case "FINISH":
                progress = 1
                badge = .done
            case "FAILED":
                badge = .failed
            default:
                break
            }
            if store.hasProblems && badge != .failed { badge = .warning }
        }
        return draw(progress: progress, badge: badge, dimmed: dimmed)
    }

    static func draw(progress: Double?, badge: Badge, dimmed: Bool) -> NSImage {
        let size = NSSize(width: 19, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let alpha: CGFloat = dimmed ? 0.45 : 1
            NSColor.black.withAlphaComponent(alpha).setStroke()
            NSColor.black.withAlphaComponent(alpha).setFill()

            // telaio
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1.25, width: 13.5, height: 13.5),
                                     xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5
            frame.stroke()

            // asse X
            NSBezierPath(rect: NSRect(x: 1.5, y: 4.6, width: 13, height: 1.1)).fill()

            // testina con ugello
            NSBezierPath(roundedRect: NSRect(x: 6.2, y: 3.4, width: 3.6, height: 3.4), xRadius: 0.8, yRadius: 0.8).fill()
            let nozzle = NSBezierPath()
            nozzle.move(to: NSPoint(x: 7.2, y: 6.7))
            nozzle.line(to: NSPoint(x: 8.8, y: 6.7))
            nozzle.line(to: NSPoint(x: 8, y: 8))
            nozzle.close()
            nozzle.fill()

            // piatto
            NSBezierPath(roundedRect: NSRect(x: 3.6, y: 11.4, width: 8.8, height: 1.3), xRadius: 0.65, yRadius: 0.65).fill()

            // oggetto in stampa, alto in proporzione all'avanzamento
            if let progress {
                let height = max(0.8, 2.6 * CGFloat(min(max(progress, 0), 1)))
                NSBezierPath(rect: NSRect(x: 6.3, y: 11.4 - height - 0.2, width: 3.4, height: height)).fill()
            }

            if badge != .none { drawBadge(badge) }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawBadge(_ badge: Badge) {
        let center = NSPoint(x: 14.6, y: 11.6)
        let radius: CGFloat = 4.3

        // Svuota lo spazio attorno al simbolo per staccarlo dal telaio.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: center.x - radius - 0.9, y: center.y - radius - 0.9,
                                    width: (radius + 0.9) * 2, height: (radius + 0.9) * 2)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.black.setFill()
        NSColor.black.setStroke()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()

        // Il simbolo viene "bucato" nel cerchio pieno.
        NSGraphicsContext.current?.compositingOperation = .clear
        switch badge {
        case .pause:
            NSBezierPath(rect: NSRect(x: center.x - 1.9, y: center.y - 2, width: 1.3, height: 4)).fill()
            NSBezierPath(rect: NSRect(x: center.x + 0.6, y: center.y - 2, width: 1.3, height: 4)).fill()
        case .done:
            let check = NSBezierPath()
            check.move(to: NSPoint(x: center.x - 2, y: center.y + 0.1))
            check.line(to: NSPoint(x: center.x - 0.5, y: center.y + 1.6))
            check.line(to: NSPoint(x: center.x + 2.1, y: center.y - 1.6))
            check.lineWidth = 1.3
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        case .failed:
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: center.x - 1.6, y: center.y - 1.6))
            cross.line(to: NSPoint(x: center.x + 1.6, y: center.y + 1.6))
            cross.move(to: NSPoint(x: center.x + 1.6, y: center.y - 1.6))
            cross.line(to: NSPoint(x: center.x - 1.6, y: center.y + 1.6))
            cross.lineWidth = 1.3
            cross.lineCapStyle = .round
            cross.stroke()
        case .warning:
            NSBezierPath(roundedRect: NSRect(x: center.x - 0.65, y: center.y - 2.5, width: 1.3, height: 3),
                         xRadius: 0.65, yRadius: 0.65).fill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 0.7, y: center.y + 1.2, width: 1.4, height: 1.4)).fill()
        case .none:
            break
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
