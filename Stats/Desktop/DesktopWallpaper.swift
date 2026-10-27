import AppKit
import Kit
import UniformTypeIdentifiers

/// Desktop video owned by the Stats app. This is separate from the Stats
/// menu-bar pause (`Store` key "pause"), which only hides modules.
@MainActor
final class DesktopWallpaper {
    static let shared = DesktopWallpaper()
    static let liveDesktopBundleID = "com.maple.livedesktop"

    private enum Key {
        static let enabled = "desktop_enabled"
        static let scene = "desktop_scene"
        static let shortcut = "desktop_shortcut"
        static let custom = "desktop_custom"
    }

    private let stage = DesktopStage()
    private var customPaths: [String] = []
    private var started = false
    private var blockedByOtherApp = false
    private var waitingForToggle = false
    private var playbackError: String?
    private var shortcutError: String?
    private var observers: [NSObjectProtocol] = []

    private(set) var enabled = false
    private(set) var paused = false
    private(set) var sceneID = ""
    private(set) var scenes: [AerialScene] = []
    private(set) var shortcut: DesktopShortcut?
    private(set) var status = "已关闭，桌面是原来的壁纸"

    var onChange: (() -> Void)?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        loadSettings()
        reloadScenes()
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

    func setScene(_ id: String) {
        sceneID = id
        Store.shared.set(key: Key.scene, value: id)
        waitingForToggle = false
        guard enabled else {
            refreshStatus()
            publish()
            return
        }
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

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "选择循环播放的视频"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !customPaths.contains(url.path) {
            customPaths.append(url.path)
            Store.shared.set(key: Key.custom, value: customPaths)
        }
        reloadScenes()
        sceneID = "file:" + url.path
        Store.shared.set(key: Key.scene, value: sceneID)
        waitingForToggle = false
        if enabled {
            apply()
        } else {
            refreshStatus()
            publish()
        }
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
        guard let scene = scenes.first(where: { $0.id == sceneID }) else {
            paused = false
            playbackError = "没有可播放的视频"
            stage.stop()
            _ = HotKeyCenter.update(nil)
            refreshStatus()
            publish()
            return
        }
        playbackError = nil
        paused = false
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
        enabled && !blockedByOtherApp && !waitingForToggle && scenes.contains(where: { $0.id == sceneID })
    }

    private var liveDesktopIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.liveDesktopBundleID }
    }

    private func loadSettings() {
        let store = Store.shared
        if store.exist(key: Key.enabled) {
            enabled = store.bool(key: Key.enabled, defaultValue: false)
            sceneID = store.string(key: Key.scene, defaultValue: "")
            customPaths = store.array(key: Key.custom, defaultValue: []).compactMap { $0 as? String }
            if let data = store.data(key: Key.shortcut) {
                shortcut = try? JSONDecoder().decode(DesktopShortcut.self, from: data)
            }
            return
        }

        let domain = UserDefaults.standard.persistentDomain(forName: Self.liveDesktopBundleID) ?? [:]
        enabled = Self.bool(domain["enabled"]) ?? false
        sceneID = domain["sceneID"] as? String ?? ""
        if let paths = domain["customPaths"] as? [String] {
            customPaths = paths
        }
        store.set(key: Key.enabled, value: enabled)
        if !sceneID.isEmpty {
            store.set(key: Key.scene, value: sceneID)
        }
        if !customPaths.isEmpty {
            store.set(key: Key.custom, value: customPaths)
        }
        if let data = domain["shortcut"] as? Data {
            shortcut = try? JSONDecoder().decode(DesktopShortcut.self, from: data)
            store.set(key: Key.shortcut, value: data)
        }
    }

    private func reloadScenes() {
        scenes = AerialLibrary.load(customPaths: customPaths)
        if scenes.contains(where: { $0.id == sceneID }) { return }
        if scenes.contains(where: { $0.id == AerialLibrary.preferredID }) {
            sceneID = AerialLibrary.preferredID
        } else {
            sceneID = scenes.first?.id ?? ""
        }
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
        } else if !scenes.contains(where: { $0.id == sceneID }) {
            status = "没有可播放的视频"
        } else {
            status = "正在播放。快捷键只暂停当前画面"
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
