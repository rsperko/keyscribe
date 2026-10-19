import AppKit
import SwiftUI

struct AppChooserMenu<Extra: View>: View {
    struct IDs {
        let menu: String
        let app: (String) -> String
        let chooseFromApplications: String
        let enterBundleID: String
    }

    let title: String
    let ids: IDs
    let onChoose: (InstalledApps.Info) -> Void
    let onEnterBundleID: () -> Void
    @ViewBuilder var extra: () -> Extra
    @State private var runningApps: [InstalledApps.Info] = []

    var body: some View {
        Menu(title) {
            ForEach(runningApps) { app in
                Button { onChoose(app) } label: {
                    Label {
                        Text(app.name)
                    } icon: {
                        if let icon = InstalledApps.menuIcon(forBundleId: app.bundleId) { Image(nsImage: icon) }
                    }
                }
                .accessibilityIdentifier(ids.app(app.bundleId))
            }
            if !runningApps.isEmpty { Divider() }
            Button("Choose from Applications\u{2026}") {
                if let app = InstalledApps.chooseFromApplications() { onChoose(app) }
            }
            .accessibilityIdentifier(ids.chooseFromApplications)
            Button("Enter Bundle ID\u{2026}", action: onEnterBundleID)
                .accessibilityIdentifier(ids.enterBundleID)
            extra()
        }
        .fixedSize()
        .accessibilityIdentifier(ids.menu)
        .onAppear { runningApps = InstalledApps.running() }
    }
}

extension AppChooserMenu where Extra == EmptyView {
    init(title: String, ids: IDs, onChoose: @escaping (InstalledApps.Info) -> Void, onEnterBundleID: @escaping () -> Void) {
        self.init(title: title, ids: ids, onChoose: onChoose, onEnterBundleID: onEnterBundleID) { EmptyView() }
    }
}
