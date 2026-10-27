import AppKit
import AVFoundation

/// Looping video above the system wallpaper and below the desktop icons.
/// Pausing freezes the current frame. Only `stop()` removes the window.
@MainActor
final class DesktopStage {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var windows: [DesktopWindow] = []
    private var activity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var wantsPlayback = false
    private var playingURL: URL?
    private var userPaused = false
    private var displaySleeping = false
    private var screenLocked = false
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    var onPlaybackError: ((String?) -> Void)?

    init() {
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.automaticallyWaitsToMinimizeStalling = false

        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaySleeping = true; self?.syncPlayback() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaySleeping = false; self?.syncPlayback() }
        }
        let distributed = DistributedNotificationCenter.default()
        lockObserver = distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = true; self?.syncPlayback() }
        }
        unlockObserver = distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = false; self?.syncPlayback() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsPlayback else { return }
                self.rebuildWindows()
            }
        }
    }

    /// Freeze the current frame. The wallpaper window stays up.
    func togglePause() -> Bool {
        guard wantsPlayback else { return false }
        userPaused.toggle()
        syncPlayback()
        return userPaused
    }

    func play(url: URL) {
        if wantsPlayback, playingURL == url, !windows.isEmpty {
            userPaused = false
            syncPlayback()
            return
        }
        wantsPlayback = true
        userPaused = false
        playingURL = url
        let item = AVPlayerItem(url: url)
        if let screen = NSScreen.main {
            let scale = screen.backingScaleFactor
            item.preferredMaximumResolution = CGSize(
                width: screen.frame.width * scale,
                height: screen.frame.height * scale
            )
        }
        looper?.disableLooping()
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: item)
        rebuildWindows()
        beginActivityIfNeeded()
        syncPlayback()
        watchPlayback()
    }

    func stop() {
        wantsPlayback = false
        userPaused = false
        playingURL = nil
        syncPlayback()
        windows.forEach {
            ($0.contentView as? PlayerHostView)?.playerLayer.player = nil
            $0.orderOut(nil)
        }
        windows.removeAll()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func watchPlayback() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.wantsPlayback else { return }
            guard let item = self.player.currentItem, item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "无法播放这段视频"
            self.onPlaybackError?(message)
        }
    }

    private func syncPlayback() {
        let moving = wantsPlayback && !userPaused && !displaySleeping && !screenLocked
        if moving {
            player.play()
        } else {
            player.pause()
        }
    }

    private func beginActivityIfNeeded() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Stats desktop video"
        )
    }

    private func rebuildWindows() {
        windows.forEach {
            ($0.contentView as? PlayerHostView)?.playerLayer.player = nil
            $0.orderOut(nil)
        }
        windows = NSScreen.screens.map { screen in
            let window = DesktopWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            // Wallpaper sits near -2147483624. Finder icons sit at desktopIconWindow
            // (-2147483603). One level under the icons covers the wallpaper and
            // still lets clicks land on icons, widgets, and the desktop.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.isMovable = false
            let host = PlayerHostView(frame: screen.frame)
            host.playerLayer.player = player
            window.contentView = host
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
    }
}

private final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Keep the video under the menu bar. AppKit would otherwise push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class PlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
