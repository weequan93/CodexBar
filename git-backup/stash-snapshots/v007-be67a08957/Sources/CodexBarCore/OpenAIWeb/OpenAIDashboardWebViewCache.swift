#if os(macOS)
import AppKit
import Foundation
import WebKit

struct OpenAIDashboardWebViewLease {
    let webView: WKWebView
    let log: (String) -> Void
    let release: () -> Void

    init(webView: WKWebView, log: @escaping (String) -> Void, release: @escaping () -> Void) {
        self.webView = webView
        self.log = log
        self.release = release
    }
}

@MainActor
final class OpenAIDashboardWebViewCache {
    static let shared = OpenAIDashboardWebViewCache()

    private final class Entry {
        let webView: WKWebView
        let host: OffscreenWebViewHost
        var lastUsedAt: Date
        var isBusy: Bool
        var usageCount: Int

        init(webView: WKWebView, host: OffscreenWebViewHost, lastUsedAt: Date, isBusy: Bool) {
            self.webView = webView
            self.host = host
            self.lastUsedAt = lastUsedAt
            self.isBusy = isBusy
            self.usageCount = 0
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private let idleTimeout: TimeInterval = 10 * 60
    private let maxUsageCount = 1

    func acquire(
        websiteDataStore: WKWebsiteDataStore,
        usageURL: URL,
        logger: ((String) -> Void)?) async throws -> OpenAIDashboardWebViewLease
    {
        let now = Date()
        self.prune(now: now)

        let log: (String) -> Void = { message in
            logger?("[webview] \(message)")
        }
        let key = ObjectIdentifier(websiteDataStore)

        if !websiteDataStore.isPersistent {
            log("Leasing temporary WebView for non-persistent store.")
            let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
            host.show()
            do {
                try await self.prepareWebView(webView, usageURL: usageURL)
            } catch {
                host.close()
                throw error
            }
            return OpenAIDashboardWebViewLease(
                webView: webView,
                log: log,
                release: {
                    host.close()
                })
        }

        if let entry = self.entries[key] {
            if entry.isBusy {
                log("Cached WebView busy; using a temporary WebView.")
                let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
                host.show()
                do {
                    try await self.prepareWebView(webView, usageURL: usageURL)
                } catch {
                    host.close()
                    throw error
                }
                return OpenAIDashboardWebViewLease(
                    webView: webView,
                    log: log,
                    release: {
                        host.close()
                    })
            }

            // Recycling logic: if used too many times, close and create fresh.
            if entry.usageCount >= self.maxUsageCount {
                log("Cached WebView usage limit reached (\(entry.usageCount)); recycling.")
                entry.host.close()
                self.entries.removeValue(forKey: key)
            } else {
                entry.isBusy = true
                entry.lastUsedAt = now
                entry.usageCount += 1
                entry.host.show()
                do {
                    try await self.prepareWebView(entry.webView, usageURL: usageURL)
                } catch {
                    entry.isBusy = false
                    entry.lastUsedAt = Date()
                    entry.host.hide()
                    throw error
                }

                return OpenAIDashboardWebViewLease(
                    webView: entry.webView,
                    log: log,
                    release: { [weak self, weak entry] in
                        guard let self, let entry else { return }
                        entry.isBusy = false
                        entry.lastUsedAt = Date()
                        entry.host.hide()
                        self.prune(now: Date())
                    })
            }
        }

        let (webView, host) = self.makeWebView(websiteDataStore: websiteDataStore)
        let entry = Entry(webView: webView, host: host, lastUsedAt: now, isBusy: true)
        entry.usageCount = 1
        self.entries[key] = entry
        host.show()

        do {
            try await self.prepareWebView(webView, usageURL: usageURL)
        } catch {
            self.entries.removeValue(forKey: key)
            host.close()
            throw error
        }

        return OpenAIDashboardWebViewLease(
            webView: webView,
            log: log,
            release: { [weak self, weak entry] in
                guard let self, let entry else { return }
                entry.isBusy = false
                entry.lastUsedAt = Date()
                entry.host.hide()
                self.prune(now: Date())
            })
    }

    func evict(websiteDataStore: WKWebsiteDataStore) {
        let key = ObjectIdentifier(websiteDataStore)
        guard let entry = self.entries.removeValue(forKey: key) else { return }
        entry.host.close()
    }

    private func prune(now: Date) {
        let expired = self.entries.filter { _, entry in
            !entry.isBusy && now.timeIntervalSince(entry.lastUsedAt) > self.idleTimeout
        }
        for (key, entry) in expired {
            entry.host.close()
            self.entries.removeValue(forKey: key)
        }
    }

    private func makeWebView(websiteDataStore: WKWebsiteDataStore) -> (WKWebView, OffscreenWebViewHost) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore
        // Use a dedicated process pool for each WebView to ensure the WebContent process
        // terminates when the WebView is deallocated (recycled).
        config.processPool = WKProcessPool()

        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .suspend
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        let host = OffscreenWebViewHost(webView: webView)
        return (webView, host)
    }

    private func prepareWebView(_ webView: WKWebView, usageURL: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = NavigationDelegate { result in
                cont.resume(with: result)
            }
            webView.navigationDelegate = delegate
            webView.codexNavigationDelegate = delegate
            _ = webView.load(URLRequest(url: usageURL))
        }
    }
}

@MainActor
private final class OffscreenWebViewHost {
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    deinit {
        let webView = self.webView
        Task { @MainActor [webView] in
            // Detach only if still attached
            if let webView, webView.superview == SharedOffscreenWindow.shared.contentView {
                webView.removeFromSuperview()
            }
            // Aggressively clear content to force WebContent process memory release
            webView?.load(URLRequest(url: URL(string: "about:blank")!))
            webView?.navigationDelegate = nil
            webView?.stopLoading()
        }
    }

    func show() {
        guard let webView = self.webView else { return }
        SharedOffscreenWindow.shared.attach(webView)
    }

    func hide() {
        guard let webView = self.webView else { return }
        if webView.superview == SharedOffscreenWindow.shared.contentView {
            webView.removeFromSuperview()
        }
    }

    func close() {
        self.hide()
        // No window to close; shared window persists.
    }
}

@MainActor
private final class SharedOffscreenWindow: NSWindow {
    static let shared = SharedOffscreenWindow()

    init() {
        // Keep a transparent (mouse-ignoring) window technically "on-screen" while scraping, but
        // place it almost entirely off-screen so we never ghost-render dashboard UI over the desktop.
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let frame = OpenAIDashboardFetcher.offscreenHostWindowFrame(for: visibleFrame)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        
        self.isReleasedWhenClosed = false
        self.backgroundColor = .clear
        self.isOpaque = false
        // Keep it effectively invisible, but non-zero alpha so WebKit treats it as "visible" and doesn't
        // stall hydration (we've observed a head-only HTML shell for minutes at alpha=0).
        self.alphaValue = OpenAIDashboardFetcher.offscreenHostAlphaValue()
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isExcludedFromWindowsMenu = true
        
        // Ensure we have a container view
        self.contentView = NSView(frame: frame)
        
        // Always keep it "ordered front" so WebKit thinks it's visible.
        // Since it's transparent and offscreen/click-through, it shouldn't interfere.
        self.orderFrontRegardless()
    }

    func attach(_ webView: WKWebView) {
        guard let container = self.contentView else { return }
        if webView.superview != container {
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
    }
}

#endif
