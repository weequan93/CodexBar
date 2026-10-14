import AppKit
import CodexBarCore

@MainActor
enum ProviderBrandIcon {
    private static let size = NSSize(width: 16, height: 16)

    /// Lazy-loaded resource bundle for provider icons.
    private static let resourceBundle: Bundle? = {
        // SwiftPM creates a CodexBar_CodexBar.bundle for resources in the CodexBar target.
        if let bundleURL = Bundle.main.url(forResource: "CodexBar_CodexBar", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        // Fallback to main bundle for development/testing.
        return Bundle.main
    }()

    private static var iconCache: [String: NSImage] = [:]

    static func image(for provider: UsageProvider) -> NSImage? {
        let baseName = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        if let cached = self.iconCache[baseName] {
            return cached
        }

        guard let bundle = self.resourceBundle,
              let url = bundle.url(forResource: baseName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.size = self.size
        image.isTemplate = true
        self.iconCache[baseName] = image
        return image
    }
}
