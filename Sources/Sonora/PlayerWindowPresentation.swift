import SwiftUI

struct WindowSizeConstraints {
    enum Change: Equatable {
        case minimum(NSSize), maximum(NSSize)
    }

    let minimum: NSSize
    let maximum: NSSize

    // Expand the old maximum before raising the minimum when leaving mini.
    // On unchanged updates, return no writes and avoid another layout pass.
    func changes(fromMinimum currentMinimum: NSSize, maximum currentMaximum: NSSize) -> [Change] {
        var changes: [Change] = []
        var updatedMaximum = currentMaximum
        if currentMaximum.width < minimum.width || currentMaximum.height < minimum.height {
            changes.append(.maximum(maximum))
            updatedMaximum = maximum
        }
        if currentMinimum != minimum { changes.append(.minimum(minimum)) }
        if updatedMaximum != maximum { changes.append(.maximum(maximum)) }
        return changes
    }
}

extension Scene {
    func sonoraWindowConfiguration() -> some Scene {
        self.windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1160, height: 770)
            .windowResizability(.contentSize)
    }
}

/// Resize the existing window so switching presentation keeps playback and window identity.
@MainActor
struct PlayerWindowPresentation: NSViewRepresentable {
    var isMiniMode: Bool
    var fullMinimumWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.onAttach = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
            coordinator?.scheduleUpdate()
        }
        return view
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        context.coordinator.update(isMiniMode: isMiniMode, fullMinimumWidth: fullMinimumWidth)
    }

    final class WindowProbe: NSView {
        var onAttach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onAttach?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var window: NSWindow?
        var isMiniMode = false
        var fullMinimumWidth: CGFloat = 980
        private var appliedMiniMode = false
        private var fullFrame: NSRect?
        private var fullWasResizable = false
        private var capturedFullFrameForMini = false
        private var beforeFullScreenFrame: NSRect?
        private var beforeFullScreenWasResizable = false
        private var exitingFullScreen = false
        private var updateScheduled = false

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(willEnterFullScreen(_:)), name: NSWindow.willEnterFullScreenNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(didExitFullScreen(_:)), name: NSWindow.didExitFullScreenNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func willEnterFullScreen(_ notification: Notification) {
            guard let sender = notification.object as? NSWindow, sender === window, !isMiniMode else { return }
            beforeFullScreenFrame = sender.frame
            beforeFullScreenWasResizable = sender.styleMask.contains(.resizable)
        }

        @objc private func didExitFullScreen(_ notification: Notification) {
            guard let sender = notification.object as? NSWindow, sender === window else { return }
            exitingFullScreen = false
            scheduleUpdate()
        }

        func update(isMiniMode requestedMiniMode: Bool, fullMinimumWidth: CGFloat) {
            if requestedMiniMode && !isMiniMode && !appliedMiniMode {
                capturedFullFrameForMini = false
                if let window {
                    if window.styleMask.contains(.fullScreen), let frame = beforeFullScreenFrame {
                        fullFrame = frame
                        fullWasResizable = beforeFullScreenWasResizable
                        capturedFullFrameForMini = true
                    } else if !window.styleMask.contains(.fullScreen) {
                        rememberFullWindow(window)
                    }
                }
            }
            isMiniMode = requestedMiniMode
            self.fullMinimumWidth = fullMinimumWidth
            scheduleUpdate()
        }

        private func rememberFullWindow(_ window: NSWindow) {
            // SwiftUI can resize to the mini content before the deferred apply runs.
            fullFrame = window.frame
            fullWasResizable = window.styleMask.contains(.resizable)
            capturedFullFrameForMini = true
        }

        func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            // Apply after SwiftUI has installed the new content and its size constraints.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.apply()
            }
        }

        private func apply() {
            guard let window else { return }
            if isMiniMode && window.styleMask.contains(.fullScreen) {
                if !exitingFullScreen {
                    exitingFullScreen = true
                    window.toggleFullScreen(nil)
                }
                return
            }

            let miniSize = MiniPlayerView.windowSize
            let minimum = isMiniMode ? miniSize : NSSize(width: fullMinimumWidth, height: 700)
            if isMiniMode && !appliedMiniMode && !capturedFullFrameForMini { rememberFullWindow(window) }
            let constraints = WindowSizeConstraints(minimum: minimum, maximum: isMiniMode ? miniSize : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            for change in constraints.changes(fromMinimum: window.contentMinSize, maximum: window.contentMaxSize) {
                switch change {
                case .minimum(let size): window.contentMinSize = size
                case .maximum(let size): window.contentMaxSize = size
                }
            }
            if isMiniMode {
                // Fixed content alone does not remove the native window's resize border.
                if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
            } else if appliedMiniMode && window.styleMask.contains(.resizable) != fullWasResizable {
                if fullWasResizable { window.styleMask.insert(.resizable) }
                else { window.styleMask.remove(.resizable) }
            }
            if let zoom = window.standardWindowButton(.zoomButton), zoom.isEnabled == isMiniMode {
                zoom.isEnabled = !isMiniMode
            }

            if isMiniMode != appliedMiniMode {
                var frame: NSRect
                if isMiniMode {
                    frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: miniSize))
                    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
                } else {
                    frame = fullFrame ?? window.frame
                    let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum))
                    frame.size.width = max(frame.width, minimumFrame.width)
                    frame.size.height = max(frame.height, minimumFrame.height)
                }
                window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
                appliedMiniMode = isMiniMode
            }
        }
    }
}
