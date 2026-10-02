import SwiftUI
import TorrentFlingerCore

@main
struct TorrentFlingerPhoneApp: App {
    @State private var store = PhoneStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    store.setActive(phase == .active)
                }
                // magnet: links arrive through the URL scheme; .torrent files
                // through the document type. Both land on the add sheet.
                .onOpenURL { url in
                    if url.scheme?.lowercased() == "magnet" {
                        store.receive(magnet: url.absoluteString)
                    } else if url.isFileURL {
                        store.receive(fileURL: url)
                    }
                }
        }
    }
}
