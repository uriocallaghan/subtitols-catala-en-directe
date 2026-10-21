import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Downloads the Apple-hosted language packs. The app asks for a pack only after the
/// reader has chosen it, so every pack the system offers here is wanted.
@main
struct AssetDownloader: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        true
    }
}
