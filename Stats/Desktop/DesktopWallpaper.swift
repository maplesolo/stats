import AppKit
import Kit

/// Desktop video owned by the Stats app. This is separate from the Stats
/// menu-bar pause (`Store` key "pause"), which only hides modules.
@MainActor
final class DesktopWallpaper {
    static let shared = DesktopWallpaper()
    static let liveDesktopBundleID = "com.maple.livedesktop"

    private enum Key {
        static let enabled = "desktop_enabled"
        static let shortcut = "desktop_shortcut"
    }

    private let stage = DesktopStage()
    private var started = false
    private var blockedByOtherApp = false
    private var waitingForToggle = false
    private var playbackError: String?
    private var shortcutError: String?
    private var observers: [NSObjectProtocol] = []
    private var wallpaperSource: DispatchSourceFileSystemObject?
    private var playingID: String?

    private(set) var enabled = false
    private(set) var paused = false
    private(set) var wallpaperName = "系统设置里的墙纸"
    private(set) var shortcut: DesktopShortcut?
    private(set) var status = "已关闭，桌面是原来的壁纸"

    var onChange: (() -> Void)?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        loadSettings()
        refreshWallpaperName()
        watchSystemWallpaper()
        stage.onPlaybackError = { [weak self] message in
            self?.playbackError = message
            self?.refreshStatus()
            self?.publish()
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.noteOtherApp(note, launched: true)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.noteOtherApp(note, launched: false)
            }
        })
        apply()
    }

    func stop() {
        _ = HotKeyCenter.update(nil)
        stage.stop()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        paused = false
        waitingForToggle = false
        Store.shared.set(key: Key.enabled, value: value)
        apply()
    }

    func setShortcut(_ value: DesktopShortcut?) {
        shortcut = value
        if let value, let data = try? JSONEncoder().encode(value) {
            Store.shared.set(key: Key.shortcut, value: data)
        } else {
            Store.shared.remove(Key.shortcut)
        }
        registerHotKeyIfPlaying()
        refreshStatus()
        publish()
    }

    func suspendHotKey() {
        _ = HotKeyCenter.update(nil)
    }

    func restoreHotKey() {
        registerHotKeyIfPlaying()
        refreshStatus()
        publish()
    }

    func toggleFromHotKey() {
        guard enabled, !blockedByOtherApp, !waitingForToggle else { return }
        paused = stage.togglePause()
        refreshStatus()
        publish()
    }

    private func noteOtherApp(_ note: Notification, launched: Bool) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == Self.liveDesktopBundleID else { return }
        if launched {
            waitingForToggle = false
            apply()
            return
        }
        guard blockedByOtherApp else { return }
        blockedByOtherApp = false
        waitingForToggle = true
        refreshStatus()
        publish()
    }

    private func apply() {
        if liveDesktopIsRunning {
            blockedByOtherApp = true
            waitingForToggle = false
            paused = false
            playbackError = nil
            shortcutError = nil
            stage.stop()
            _ = HotKeyCenter.update(nil)
            refreshStatus()
            publish()
            return
        }
        blockedByOtherApp = false
        if waitingForToggle || !enabled {
            paused = false
            playbackError = nil
            shortcutError = nil
            stage.stop()
            _ = HotKeyCenter.update(nil)
            refreshStatus()
            publish()
            return
        }
        guard let scene = AerialLibrary.systemWallpaper() else {
            paused = false
            playbackError = "系统设置里的墙纸不是已下载的动态航拍"
            playingID = nil
            stage.stop()
            _ = HotKeyCenter.update(nil)
            refreshWallpaperName()
            refreshStatus()
            publish()
            return
        }
        refreshWallpaperName()
        playbackError = nil
        paused = false
        playingID = scene.id
        shortcutError = HotKeyCenter.update(shortcut)
        stage.play(url: scene.url)
        refreshStatus()
        publish()
    }

    private func registerHotKeyIfPlaying() {
        guard enabled, !blockedByOtherApp, !waitingForToggle, stageIsPlaying else {
            return
        }
        shortcutError = HotKeyCenter.update(shortcut)
    }

    private var stageIsPlaying: Bool {
        enabled && !blockedByOtherApp && !waitingForToggle && AerialLibrary.systemWallpaper() != nil
    }

    private var liveDesktopIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.liveDesktopBundleID }
    }

    private func loadSettings() {
        let store = Store.shared
        if store.exist(key: Key.enabled) {
            enabled = store.bool(key: Key.enabled, defaultValue: false)
            if let data = store.data(key: Key.shortcut) {
                shortcut = try? JSONDecoder().decode(DesktopShortcut.self, from: data)
            }
            return
        }

        let domain = UserDefaults.standard.persistentDomain(forName: Self.liveDesktopBundleID) ?? [:]
        enabled = Self.bool(domain["enabled"]) ?? false
        store.set(key: Key.enabled, value: enabled)
        if let data = domain["shortcut"] as? Data {
            shortcut = try? JSONDecoder().decode(DesktopShortcut.self, from: data)
            store.set(key: Key.shortcut, value: data)
        }
    }

    private func watchSystemWallpaper() {
        let directory = AerialLibrary.wallpaperIndexURL.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.systemWallpaperChanged()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        wallpaperSource = source
        source.resume()
    }

    private func systemWallpaperChanged() {
        let scene = AerialLibrary.systemWallpaper()
        refreshWallpaperName()
        guard enabled, !blockedByOtherApp, !waitingForToggle else {
            publish()
            return
        }
        guard scene?.id != playingID else { return }
        apply()
    }

    private func refreshWallpaperName() {
        wallpaperName = AerialLibrary.systemWallpaper()?.name ?? "系统设置里的墙纸不是动态航拍"
    }

    private func refreshStatus() {
        if blockedByOtherApp {
            status = "桌面动态.app 正在播放，这里先不播"
        } else if waitingForToggle {
            status = "把开关关一次再打开，才会在这里播放"
        } else if !enabled {
            status = "已关闭，桌面是原来的壁纸"
        } else if let shortcutError {
            status = shortcutError
        } else if let playbackError {
            status = playbackError
        } else if paused {
            status = "已暂停在当前画面"
        } else if AerialLibrary.systemWallpaper() == nil {
            status = "系统设置里的墙纸不是已下载的动态航拍"
        } else {
            status = "正在循环系统墙纸。快捷键只暂停当前画面"
        }
    }

    private func publish() {
        onChange?()
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}
