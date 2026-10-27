import Foundation

struct AerialScene: Hashable {
    let id: String
    let name: String
    let url: URL
}

enum AerialLibrary {
    static let preferredID = "F07CC61B-30FC-4614-BDAD-3240B61F6793"

    private static let videosDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
    private static let catalogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")

    private static let names = [
        "Palau Coral": "帕劳珊瑚",
        "Tahiti Waves": "大溪地海浪",
        "Dubai": "迪拜",
        "Bumpheads": "隆头鹦哥鱼",
        "California Kelp Forest": "加州海藻林",
        "Jacks": "杰克鱼群",
        "Gray Reef Sharks": "灰礁鲨",
        "Hong Kong": "香港",
        "Los Angeles": "洛杉矶",
        "London": "伦敦",
        "New York": "纽约",
        "San Francisco": "旧金山",
        "Liwa": "利瓦沙漠",
        "Monument Valley": "纪念碑谷",
        "Hawaii": "夏威夷",
        "Greenland": "格陵兰",
        "Iceland": "冰岛",
        "Patagonia": "巴塔哥尼亚",
        "Grand Canyon": "大峡谷",
        "China": "中国",
    ]

    static func load(customPaths: [String]) -> [AerialScene] {
        var scenes = downloadedAerials()
        for path in customPaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard !scenes.contains(where: { $0.url.path == url.path }) else { continue }
            scenes.append(AerialScene(id: "file:" + path, name: url.deletingPathExtension().lastPathComponent, url: url))
        }
        return scenes
    }

    private static func downloadedAerials() -> [AerialScene] {
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return looseFiles()
        }
        var scenes: [AerialScene] = []
        var seen = Set<String>()
        for asset in catalog.assets.sorted(by: { ($0.preferredOrder ?? 999) < ($1.preferredOrder ?? 999) }) {
            let url = videosDir.appendingPathComponent(asset.id).appendingPathExtension("mov")
            guard seen.insert(asset.id).inserted else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            scenes.append(AerialScene(id: asset.id, name: displayName(asset), url: url))
        }
        return scenes.isEmpty ? looseFiles() : scenes
    }

    private static func looseFiles() -> [AerialScene] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: videosDir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { AerialScene(id: $0.deletingPathExtension().lastPathComponent, name: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }

    private static func displayName(_ asset: RawAsset) -> String {
        if let shot = asset.shotID {
            if shot.hasPrefix("GG_LM") { return "金门（浅色）" }
            if shot.hasPrefix("GG_DM") { return "金门（深色）" }
        }
        let label = asset.accessibilityLabel ?? asset.id
        return names[label] ?? label
    }
}

private struct Catalog: Decodable {
    let assets: [RawAsset]
}

private struct RawAsset: Decodable {
    let id: String
    let accessibilityLabel: String?
    let shotID: String?
    let preferredOrder: Int?
}
