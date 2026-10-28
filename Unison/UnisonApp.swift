import SwiftUI

@main
struct UnisonApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .onOpenURL { url in
                    if let route = Route(url: url) { delegate.model.route = route }
                }
        }
    }
}
