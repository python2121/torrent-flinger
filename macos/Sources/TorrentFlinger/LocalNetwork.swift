#if os(macOS)
import Foundation
import Network

/// Forces macOS to register this app for the Local Network privacy permission.
///
/// macOS gates connections to LAN addresses (private IP ranges, `.local`
/// names) behind that permission. The catch: a plain `URLSession` request to a
/// private address is *blocked* when the grant is missing — it fails with
/// `NSURLErrorNotConnectedToInternet` (-1009), the same code you'd get with no
/// Wi-Fi — but it does **not** cause the system to prompt, and the app never
/// appears under System Settings → Privacy & Security → Local Network, so
/// there's nothing to switch on either. The app just looks permanently
/// "Disconnected" while the very same URL loads in a browser.
///
/// Starting a Bonjour browse is the operation the permission is actually keyed
/// to: it's what makes the system prompt and list the app. We start one at
/// launch purely for that side effect — the results are ignored, and it's
/// cancelled once it has served its purpose.
enum LocalNetwork {
    private static var browser: NWBrowser?

    /// Kick the permission machinery. Safe to call more than once.
    ///
    /// `onReady` fires once the browse is live, which is the first moment LAN
    /// requests can actually succeed — the caller uses it to retry immediately
    /// instead of showing "Disconnected" until the next poll comes round.
    static func requestAccess(onReady: (@MainActor () -> Void)? = nil) {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("local network: browse ready (permission granted or prompt shown)")
                // The browse runs on .main (see `start` below), so this is the
                // main actor — state it, rather than relying on it implicitly.
                MainActor.assumeIsolated { onReady?() }
            case .waiting(let error):
                Log.error("local network: browse waiting — \(error.localizedDescription)")
            case .failed(let error):
                Log.error("local network: browse failed — \(error.localizedDescription)")
            case .cancelled:
                Log.info("local network: browse cancelled")
            default:
                break
            }
        }
        browser.start(queue: .main)
        Self.browser = browser

        // The browse only has to run long enough for the system to register the
        // request; leaving an mDNS browse running forever would be rude.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            browser.cancel()
            Self.browser = nil
        }
    }
}
#endif
