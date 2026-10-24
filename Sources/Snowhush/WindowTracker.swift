import AppKit

struct WindowUpdate {
    let surfaces: [WindowSurface]
    /// Seconds since the previous poll.
    let interval: Float
    /// Windows that left the list but still exist off screen (minimized, hidden, or on another Space), as opposed to closed.
    let parked: Set<CGWindowID>
}

struct WindowSurface: Equatable {
    let id: CGWindowID
    /// Overlay coordinates: origin at the bottom-left of the primary screen.
    let frame: CGRect
    /// Frames of windows in front of this one, in overlay coordinates.
    let blockers: [CGRect]
    /// Top corners as a superellipse quadrant: macOS windows are close to exponent 2.5, Spotlight's capsule is a circle.
    let cornerRadius: CGFloat
    let cornerExponent: CGFloat
}

/// Polls the on-screen window list: a few times a second when nothing moves, every frame while something does.
final class WindowTracker {
    var screen: CGRect = .zero
    var menuBarHeight: CGFloat = 0

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let maxLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
    private let ignoredOwners: Set<String> = ["Window Server"]
    /// The Dock's windows (the Dock itself, the ⌘Tab switcher) hide snow behind them but don't collect any.
    private let coverOnlyOwners: Set<String> = ["Dock"]
    private var previous: [WindowSurface] = []
    private var lastQuery: CFTimeInterval = 0
    private var lastChange: CFTimeInterval = -10

    /// Returns the windows when they changed since the last poll.
    /// `eager` polls every frame, e.g. while a mouse button is down and a drag may be starting.
    func poll(now: CFTimeInterval, eager: Bool) -> WindowUpdate? {
        let interval = now - lastQuery
        guard interval >= (eager || now - lastChange < 0.6 ? 0 : 0.2) else { return nil }
        lastQuery = now
        let surfaces = query()
        guard surfaces != previous else { return nil }
        let vanished = Set(previous.map(\.id)).subtracting(surfaces.map(\.id))
        previous = surfaces
        lastChange = now
        return WindowUpdate(surfaces: surfaces, interval: Float(min(interval, 0.25)), parked: offscreen(among: vanished))
    }

    /// Polls every frame for a moment, for changes the mouse doesn't announce (app switching, Spaces).
    func watchClosely(now: CFTimeInterval) {
        lastChange = now
    }

    func reset() {
        previous = []
    }

    private func offscreen(among ids: Set<CGWindowID>) -> Set<CGWindowID> {
        guard !ids.isEmpty else { return [] }
        // CGWindowListCreateDescriptionFromArray takes window numbers stored as raw pointer values.
        var pointers: [UnsafeRawPointer?] = ids.filter { $0 != 0 }.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
              let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [] }
        return Set(info.compactMap { entry in
            entry[kCGWindowIsOnscreen as String] as? Bool == true ? nil : entry[kCGWindowNumber as String] as? CGWindowID
        })
    }

    private func query() -> [WindowSurface] {
        guard screen.width > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let visibleArea = screen.width * (screen.height - menuBarHeight)
        var blockers: [CGRect] = []
        var surfaces: [WindowSurface] = []

        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer >= 0, layer < maxLayer,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.3,
                  !ignoredOwners.contains(entry[kCGWindowOwnerName as String] as? String ?? "")
            else { continue }

            // Screen-sized windows above the normal layer (Notification Center, Siri) are transparent overlays.
            if layer > 0 && bounds.width * bounds.height >= screen.width * screen.height * 0.9 { continue }

            let frame = CGRect(x: bounds.minX, y: screen.height - bounds.maxY, width: bounds.width, height: bounds.height)
            let roomAbove = bounds.minY >= menuBarHeight + 6 && frame.maxY < screen.height
            let onScreen = frame.maxX > 0 && frame.minX < screen.width && frame.maxY > 0
            let fillsScreen = bounds.width * bounds.height >= visibleArea * 0.9

            let coverOnly = coverOnlyOwners.contains(entry[kCGWindowOwnerName as String] as? String ?? "")
            if roomAbove && onScreen && !fillsScreen && !coverOnly && bounds.width >= 80 && bounds.height >= 40,
               let id = entry[kCGWindowNumber as String] as? CGWindowID {
                let owner = (entry[kCGWindowOwnerName as String] as? String ?? "").lowercased()
                // Search bars like Spotlight are capsules: low and wide, with fully rounded ends.
                let capsule = owner.contains("spotlight") || (bounds.height <= 90 && bounds.width >= bounds.height * 3)
                let radius = min(capsule ? min(bounds.height / 2, 32) : 18, bounds.width / 2, bounds.height / 2)
                let region = CGRect(x: frame.minX, y: frame.maxY - radius, width: frame.width, height: 40 + radius)
                surfaces.append(WindowSurface(
                    id: id,
                    frame: frame,
                    blockers: blockers.filter { $0.intersects(region) },
                    cornerRadius: radius,
                    cornerExponent: capsule ? 2 : 2.5
                ))
            }
            blockers.append(frame)
        }
        return surfaces
    }
}
