import AppKit

@MainActor
final class NotchHoverMonitor {
    private let onEnter: (NSScreen) -> Void
    private let onHover: (NSScreen) -> Void
    private let onExit: () -> Void

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var activeScreen: NSScreen?
    private var hoverTask: Task<Void, Never>?
    private var lastRefreshAt: TimeInterval = -.infinity

    init(
        onEnter: @escaping (NSScreen) -> Void,
        onHover: @escaping (NSScreen) -> Void,
        onExit: @escaping () -> Void
    ) {
        self.onEnter = onEnter
        self.onHover = onHover
        self.onExit = onExit

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved(at: NSEvent.mouseLocation, timestamp: event.timestamp)
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved(at: NSEvent.mouseLocation, timestamp: event.timestamp)
            }
            return event
        }
    }

    isolated deinit {
        hoverTask?.cancel()
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
    }

    private func handleMouseMoved(at point: NSPoint, timestamp: TimeInterval) {
        guard let screen = screen(containing: point),
              isInsideNotchHotZone(point, on: screen)
        else {
            leaveNotchIfNeeded()
            return
        }

        guard activeScreen !== screen else { return }
        leaveNotchIfNeeded()
        activeScreen = screen

        // Refresh once on entry. The short cooldown prevents edge jitter from
        // repeatedly starting Codex app-server requests.
        if timestamp - lastRefreshAt >= 15 {
            lastRefreshAt = timestamp
            onEnter(screen)
        }

        hoverTask = Task { [weak self, weak screen] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  let self,
                  let screen,
                  self.activeScreen === screen,
                  self.isInsideNotchHotZone(NSEvent.mouseLocation, on: screen)
            else { return }
            self.onHover(screen)
        }
    }

    private func leaveNotchIfNeeded() {
        guard activeScreen != nil else { return }
        activeScreen = nil
        hoverTask?.cancel()
        hoverTask = nil
        onExit()
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let frame = screen.frame
            return point.x >= frame.minX
                && point.x <= frame.maxX
                && point.y >= frame.minY
                && point.y <= frame.maxY
        }
    }

    private func isInsideNotchHotZone(_ point: NSPoint, on screen: NSScreen) -> Bool {
        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0 else { return false }

        let leftEdge: CGFloat
        let rightEdge: CGFloat
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            leftEdge = leftArea.maxX
            rightEdge = rightArea.minX
        } else {
            leftEdge = screen.frame.midX - 110
            rightEdge = screen.frame.midX + 110
        }

        let bottomEdge = screen.frame.maxY - notchHeight
        return point.x >= leftEdge
            && point.x <= rightEdge
            && point.y >= bottomEdge
            && point.y <= screen.frame.maxY
    }
}
