import AppKit
import Foundation
import Security
import SplytCore

/// An installed application the user can write a rule for.
struct CatalogApp: Identifiable, Hashable, Sendable {
    var signingID: String
    var name: String
    var path: String

    var id: String { path }
}

enum AppCatalog {
    /// Finds applications in the usual install locations.
    static func scan() -> [CatalogApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
        var seen = Set<String>()
        var apps: [CatalogApp] = []
        for root in roots {
            for url in bundles(in: root, depth: 1) {
                guard let app = describe(url), seen.insert(app.path).inserted else {
                    continue
                }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func bundles(in directory: URL, depth: Int) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        return contents.flatMap { url -> [URL] in
            if url.pathExtension == "app" {
                return [url]
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isDirectory && depth > 0 ? bundles(in: url, depth: depth - 1) : []
        }
    }

    /// Describes an app bundle or command-line executable.
    static func describe(_ url: URL) -> CatalogApp? {
        let bundle = url.pathExtension == "app" ? Bundle(url: url) : nil
        let identifier = signingIdentifier(of: url) ?? bundle?.bundleIdentifier ?? ""
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return CatalogApp(signingID: identifier, name: name, path: url.path)
    }

    /// The identifier flows report. It usually equals the bundle identifier, but
    /// not always, which is why it is read from the signature.
    private static func signingIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return nil
        }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }
}
