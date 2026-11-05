import BackgroundAssets

/// F-04b §12 item 7 (T-013f): Apple's managed downloader for the Apple-hosted speaker model pack. No own logic:
/// the system downloads essential packs at install and update; this extension only lets it do so.
@main
struct DownloaderExtension: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool { true }
}
