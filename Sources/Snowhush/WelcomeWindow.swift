import AppKit
import QuartzCore

/// Shown on first launch. Getting started crumbles the window into snow that falls onto the desktop.
final class WelcomeController: NSObject {
    /// Receives the pieces of the window as it crumbles, in the overlay's coordinates.
    var scatter: ([ScatterPiece]) -> Void = { _ in }
    var overlayOrigin: () -> CGPoint = { .zero }
    var finished: () -> Void = {}

    private var window: NSWindow?
    private var crumble: Crumble?

    func show() {
        let size = CGSize(width: 440, height: 430)
        let window = WelcomeWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.onCancel = { [weak self] in self?.getStarted() }

        let content = WelcomeView(frame: CGRect(origin: .zero, size: size))
        content.button.target = self
        content.button.action = #selector(getStarted)
        window.contentView = content
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func getStarted() {
        guard crumble == nil, let window, let view = window.contentView as? WelcomeView else { return }
        view.button.isEnabled = false
        guard let crumble = Crumble(view: view) else {
            window.orderOut(nil)
            finished()
            return
        }
        self.crumble = crumble
        let origin = overlayOrigin()
        let windowOrigin = window.frame.origin
        crumble.start { [weak self] cells in
            guard let self else { return }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            self.scatter(cells.map { cell in
                let x = Float(windowOrigin.x + cell.point.x - origin.x)
                let y = Float(windowOrigin.y + cell.point.y - origin.y)
                let outward = Float((cell.point.x - center.x) / view.bounds.width)
                return ScatterPiece(
                    position: SIMD2(x, y),
                    velocity: SIMD2(outward * 140 + .random(in: -70...70), .random(in: 30...150)),
                    color: cell.color
                )
            })
            window.invalidateShadow()
        } completion: { [weak self] in
            window.orderOut(nil)
            self?.crumble = nil
            self?.window = nil
            self?.finished()
        }
    }
}

private final class WelcomeWindow: NSWindow {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

/// Erases a view a few points at a time from the top down, with a ragged edge, handing each erased cell
/// with its colour to `pieces` so the window seems to fall apart into the snow.
private final class Crumble {
    struct Cell {
        let point: CGPoint
        let color: SIMD3<Float>
        let delay: Double
        let column: Int
        let row: Int
    }

    private let view: NSView
    private let cell: CGFloat = 6
    private let columns: Int
    private let rows: Int
    private var cells: [Cell]
    private var next = 0
    private var alpha: [UInt8]
    private let mask = CALayer()
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private let duration: Double

    init?(view: NSView) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        self.view = view
        let bounds = view.bounds
        columns = Int((bounds.width / cell).rounded(.up))
        rows = Int((bounds.height / cell).rounded(.up))
        alpha = Array(repeating: 255, count: columns * rows)
        let scale = CGFloat(rep.pixelsWide) / bounds.width

        var cells: [Cell] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: (CGFloat(column) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell)
                // Bitmap rows run top-down; the view's run bottom-up.
                let px = min(Int(point.x * scale), rep.pixelsWide - 1)
                let py = min(Int((bounds.height - point.y) * scale), rep.pixelsHigh - 1)
                guard let sample = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB), sample.alphaComponent > 0.1 else { continue }
                let fromTop = 1 - Double(point.y / bounds.height)
                let ragged = Double(Crumble.noise(column, row))
                cells.append(Cell(
                    point: point,
                    color: SIMD3(Float(sample.redComponent), Float(sample.greenComponent), Float(sample.blueComponent)),
                    delay: fromTop * 0.52 + ragged * 0.2,
                    column: column,
                    row: row
                ))
            }
        }
        cells.sort { $0.delay < $1.delay }
        self.cells = cells
        duration = (cells.last?.delay ?? 0) + 0.05
    }

    func start(pieces: @escaping ([Cell]) -> Void, completion: @escaping () -> Void) {
        view.wantsLayer = true
        mask.frame = view.bounds
        mask.contentsGravity = .resize
        view.layer?.mask = mask
        updateMask()
        started = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - self.started
            var batch: [Cell] = []
            while self.next < self.cells.count, self.cells[self.next].delay <= elapsed {
                let cell = self.cells[self.next]
                self.alpha[(self.rows - 1 - cell.row) * self.columns + cell.column] = 0
                batch.append(cell)
                self.next += 1
            }
            if !batch.isEmpty {
                self.updateMask()
                pieces(batch)
            }
            if elapsed >= self.duration {
                timer.invalidate()
                completion()
            }
        }
    }

    private func updateMask() {
        var pixels = [UInt8](repeating: 0, count: alpha.count * 4)
        for (i, a) in alpha.enumerated() {
            pixels[i * 4] = a
            pixels[i * 4 + 1] = a
            pixels[i * 4 + 2] = a
            pixels[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.contents = image
        CATransaction.commit()
    }

    private static func noise(_ x: Int, _ y: Int) -> Float {
        func hash(_ x: Int, _ y: Int) -> Float {
            var n = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
            n = (n ^ (n >> 13)) &* 1_274_126_177
            return Float(n & 0xFFFF) / 65535
        }
        let coarse = hash(x / 6, y / 6) * 0.6
        return coarse + hash(x, y) * 0.4
    }
}

/// Drawn rather than built from layer properties, so `cacheDisplay` captures exactly what is on screen.
private final class WelcomeView: NSView {
    let button = GetStartedButton()
    private let background = NSColor(srgbRed: 0.105, green: 0.088, blue: 0.072, alpha: 1)
    private let ink = NSColor(srgbRed: 0.93, green: 0.9, blue: 0.85, alpha: 1)
    private let muted = NSColor(srgbRed: 0.78, green: 0.75, blue: 0.7, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 112), icon.heightAnchor.constraint(equalToConstant: 112)])

        let title = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "IT'S SNOWING\nON YOUR DESKTOP.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .light, width: .condensed),
                .foregroundColor: ink,
                .kern: 0.6,
                .paragraphStyle: Self.paragraph(lineHeight: 0.95),
            ]
        ))

        let body = NSTextField(wrappingLabelWithString: "Snowhush lives in the menu bar. Click the snowflake to change the snowfall, let the drift melt, or keep the snow behind your windows. Sweep it aside with your cursor.")
        body.attributedStringValue = NSAttributedString(string: body.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: muted,
            .paragraphStyle: Self.paragraph(lineHeight: 1.3),
        ])
        body.preferredMaxLayoutWidth = 330

        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(28, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        background.setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.08).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    private static func paragraph(lineHeight: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = lineHeight
        return style
    }
}

private final class GetStartedButton: NSButton {
    private let fill = NSColor(srgbRed: 0.93, green: 0.9, blue: 0.85, alpha: 1)
    private let label = NSColor(srgbRed: 0.09, green: 0.075, blue: 0.06, alpha: 1)

    init() {
        super.init(frame: .zero)
        title = "Get Started"
        isBordered = false
        keyEquivalent = "\r"
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 190), heightAnchor.constraint(equalToConstant: 44)])
        setAccessibilityLabel("Get Started")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        (isHighlighted ? fill.blended(withFraction: 0.12, of: .black) ?? fill : fill).setFill()
        shape.fill()
        let text = NSAttributedString(string: "GET STARTED", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: label,
            .kern: 1.8,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
