import Foundation

/// A File Provider cloud folder in `~/Library/CloudStorage` (OneDrive, Google Drive, Dropbox, Box…), listed in
/// LOCATIONS after iCloud Drive. macOS names each folder `<Provider>-<account>` (e.g. `OneDrive-Personal`,
/// `GoogleDrive-me@example.com`); a provider with a single domain may use just `<Provider>` (`Dropbox`).
struct CloudStorageFolder: Hashable {
    var url: URL
    var name: String

    init(url: URL) {
        self.url = url
        self.name = Self.displayName(folderName: url.lastPathComponent)
    }

    static func containerURL(home: URL) -> URL {
        home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    }

    /// `OneDrive-amazon.com` → `OneDrive – amazon.com`, `GoogleDrive-me@x.com` → `Google Drive – me@x.com`,
    /// `Box-Box` → `Box`, `Dropbox` → `Dropbox`.
    static func displayName(folderName: String) -> String {
        guard let dash = folderName.firstIndex(of: "-") else { return providerName(folderName) }
        let provider = providerName(String(folderName[..<dash]))
        let account = String(folderName[folderName.index(after: dash)...])
        guard !account.isEmpty, account.caseInsensitiveCompare(provider) != .orderedSame else { return provider }
        return "\(provider) – \(account)"
    }

    private static func providerName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "googledrive": "Google Drive"
        case "onedrive": "OneDrive"
        default: raw
        }
    }

    /// The folders in `container` (hidden entries and plain files skipped), sorted by display name. Blocking: call on
    /// a lane.
    static func list(in container: URL) -> [CloudStorageFolder] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { CloudStorageFolder(url: $0.standardizedFileURL) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
