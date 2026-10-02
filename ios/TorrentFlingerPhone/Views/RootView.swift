import SwiftUI
import TorrentFlingerCore

struct RootView: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.hasConfig {
                // The list is the app. Statistics and Settings are pushed from
                // its overflow menu rather than living in a tab bar.
                TorrentListView()
            } else {
                NavigationStack { SettingsView(mode: .setup) }
            }
        }
        // One add sheet at a time; the next pending link follows the dismiss.
        .sheet(item: pendingAdd) { pending in
            AddTorrentSheet(pending: pending)
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { store.toast = nil }
            }
        }
        .animation(.snappy, value: store.toast)
        .onAppear(perform: applyDebugMagnet)
    }

    /// Debug builds honour `-debugMagnet <link>`: feeds a magnet in as if the
    /// system had opened it, so the add sheet can be captured without tapping
    /// through iOS's "Open in Torrent Flinger?" confirmation. `-debugScreen`
    /// is handled by `TorrentListView`. No-op in release.
    private func applyDebugMagnet() {
        #if DEBUG
        if let magnet = UserDefaults.standard.string(forKey: "debugMagnet") {
            store.receive(magnet: magnet)
        }
        #endif
    }

    private var pendingAdd: Binding<PhoneStore.PendingAdd?> {
        Binding(
            get: { store.pendingAdds.first },
            set: { value in
                if value == nil, let first = store.pendingAdds.first {
                    store.dismissPending(first.id)
                }
            })
    }
}
