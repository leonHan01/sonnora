import AppKit
import SwiftUI

private final class SceneTestDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The scene requires a working WindowServer. Fail instead of hanging if unavailable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("FAIL: mini scene test timed out")
            exit(2)
        }
    }
}

private struct HideSceneTestWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.alphaValue = 0
            window?.ignoresMouseEvents = true
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}

@main
private struct MiniWindowSceneTests: App {
    @NSApplicationDelegateAdaptor(SceneTestDelegate.self) private var delegate
    @StateObject private var model = PlayerModel(
        storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json"),
        enableSystemControls: false
    )
    @LocalState private var started = false

    var body: some Scene {
        Window("Sonora Mini Window Check", id: "mini-window-check") {
            RootView(model: model).background(HideSceneTestWindow()).onAppear {
                guard !started else { return }
                started = true
                guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else {
                    print("FAIL: test scene did not create a window")
                    exit(1)
                }
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                runTests(window)
            }
        }
        // The production scene configuration is part of the regression test.
        .sonoraWindowConfiguration()
    }

    @MainActor
    private func runTests(_ window: NSWindow) {
        var failures = 0
        let song = Track(url: URL(fileURLWithPath: "/tmp/sonora-scene-test.mp3"), title: "Song", artist: "Artist", album: "Album", duration: 120)
        model.tracks = [song]
        model.queue = PlaybackQueue(ids: [song.id])
        model.elapsed = 37
        model.isPlaying = true

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL: \(message)") }
        }
        func later(_ seconds: Double = 0.6, _ action: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { action() }
        }
        func positionFullWindow(width: CGFloat) -> NSRect {
            let area = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let frame = NSRect(x: area.midX - width / 2, y: area.midY - 385, width: width, height: 770)
            window.setFrame(frame, display: false)
            return window.frame
        }
        func exerciseMini(restoring fullFrame: NSRect, completion: @escaping () -> Void) {
            model.isMiniMode = true
            later {
                let miniFrame = window.frame
                expect(!window.styleMask.contains(.resizable), "SwiftUI re-enabled mini window resizing")
                expect(window.contentMinSize == window.contentMaxSize, "SwiftUI removed the fixed mini size")
                expect(abs(miniFrame.width - MiniPlayerView.windowSize.width) < 1 && miniFrame.height <= MiniPlayerView.windowSize.height + 40,
                       "mini content no longer fits its window: \(miniFrame.size)")
                expect(window.standardWindowButton(.zoomButton)?.isEnabled != true, "mini zoom button should be disabled")
                model.search = "refresh"
                let movedOrigin = NSPoint(x: miniFrame.origin.x + 20, y: miniFrame.origin.y - 20)
                window.setFrameOrigin(movedOrigin)
                later {
                    expect(!window.styleMask.contains(.resizable), "view update re-enabled mini window resizing")
                    expect(window.frame.origin == movedOrigin, "mini window should still be movable")
                    expect(window.frame.size == miniFrame.size, "mini size changed when moving the window")
                    model.isMiniMode = false
                    later {
                        expect(window.styleMask.contains(.resizable), "full window did not regain resizing")
                        expect(window.frame == fullFrame, "full window did not regain its previous frame: \(window.frame) instead of \(fullFrame)")
                        expect(model.queue.currentID == song.id && model.elapsed == 37 && model.isPlaying,
                               "switching windows changed playback state")
                        completion()
                    }
                }
            }
        }

        later {
            let normalFrame = positionFullWindow(width: 1160)
            later {
                expect(window.styleMask.contains(.resizable), "full window should initially allow resizing")
                expect(abs(normalFrame.width - 1160) < 1, "full window should allow a larger size")
                exerciseMini(restoring: normalFrame) {
                    model.showQueue = true
                    later {
                        let queueFrame = positionFullWindow(width: 1280)
                        later {
                            expect(abs(queueFrame.width - 1280) < 1, "full window with queue should allow a larger size")
                            exerciseMini(restoring: queueFrame) {
                                print(failures == 0 ? "PASS: SwiftUI scene keeps mini fixed and restores full windows" : "\(failures) scene window checks failed")
                                exit(failures == 0 ? 0 : 1)
                            }
                        }
                    }
                }
            }
        }
    }
}
