import AppKit
import SwiftUI

// A hidden window has no screen. Preserve the proposed frame in that case so
// this test can check restoration without opening a visible window.
private final class OffscreenWindow: NSWindow {
    var simulatesFullScreen = false

    override var styleMask: NSWindow.StyleMask {
        get {
            var mask = super.styleMask
            if simulatesFullScreen { mask.insert(.fullScreen) }
            return mask
        }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen else { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    override func toggleFullScreen(_ sender: Any?) {
        guard simulatesFullScreen else { return }
        simulatesFullScreen = false
        // Simulate SwiftUI applying mini content constraints during full-screen exit.
        setFrame(NSRect(x: frame.minX, y: frame.maxY - 156, width: 380, height: 156), display: false)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: self)
    }
}

@main
struct MiniWindowTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        let model = PlayerModel(storageURL: storage, enableSystemControls: false)
        let track = Track(url: URL(fileURLWithPath: "/tmp/sonora-window-test.mp3"), title: "Song", artist: "Artist", album: "Album", duration: 120)
        model.tracks = [track]
        model.queue = PlaybackQueue(ids: [track.id])
        model.elapsed = 37
        model.isPlaying = true

        let host = NSHostingView(rootView: RootView(model: model))
        let window = OffscreenWindow(contentRect: NSRect(x: 100, y: 100, width: 1160, height: 770),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host

        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL: \(message)") }
        }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
        }

        settle()
        let fullFrame = window.frame
        expect(window.styleMask.contains(.resizable), "full player must allow resizing")
        model.isMiniMode = true
        settle()
        let miniFrame = window.frame
        let miniSize = MiniPlayerView.windowSize
        expect(!window.styleMask.contains(.resizable), "mini window still has a resize border")
        expect(abs(miniFrame.width - miniSize.width) < 1 && miniFrame.height <= miniSize.height + 40,
               "mini window should fit its fixed content, got \(miniFrame.size)")
        expect(window.contentMinSize == window.contentMaxSize, "mini content size should remain fixed")
        expect(window.standardWindowButton(.zoomButton)?.isEnabled != true, "mini zoom button should be disabled")

        model.search = "refresh the view"
        settle()
        expect(!window.styleMask.contains(.resizable), "view update restored the mini resize border")
        expect(window.frame.size == miniFrame.size, "mini window size changed after a view update")
        expect(window.isMovable, "mini window should still be movable")
        let movedOrigin = NSPoint(x: miniFrame.origin.x + 40, y: miniFrame.origin.y + 30)
        window.setFrameOrigin(movedOrigin)
        settle()
        expect(window.frame.origin == movedOrigin, "mini window should still move")
        expect(window.frame.size == miniFrame.size, "moving the mini window changed its size")

        model.isMiniMode = false
        settle()
        expect(window.styleMask.contains(.resizable), "full player should regain its resize border")
        expect(window.standardWindowButton(.zoomButton)?.isEnabled == true, "full player zoom button should be enabled")
        expect(window.frame == fullFrame, "full player should restore its previous frame: expected \(fullFrame), got \(window.frame)")
        expect(model.queue.currentID == track.id && model.elapsed == 37 && model.isPlaying,
               "switching views must not change playback state")

        model.isMiniMode = true
        settle()
        expect(!window.styleMask.contains(.resizable) && window.frame.size == miniFrame.size,
               "re-entering mini should stay compact and non-resizable")
        model.isMiniMode = false
        settle()
        expect(window.styleMask.contains(.resizable) && window.frame == fullFrame,
               "repeated switching should preserve the full window")

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.simulatesFullScreen = true
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
        model.isMiniMode = true
        settle()
        settle()
        expect(!window.styleMask.contains(.fullScreen) && !window.styleMask.contains(.resizable),
               "entering mini from full screen should exit full screen and disable resizing")
        model.isMiniMode = false
        settle()
        expect(window.styleMask.contains(.resizable) && window.frame == fullFrame,
               "mini entered from full screen should restore the previous regular window")

        print(failures == 0 ? "PASS: mini window resizing and full-window restoration" : "\(failures) mini window checks failed")
        if failures != 0 { exit(1) }
    }
}
