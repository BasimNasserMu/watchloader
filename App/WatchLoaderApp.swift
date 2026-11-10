import SwiftUI

@main
struct WatchLoaderApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear { model.refresh() }
                .onChange(of: phase) { _, p in if p == .active { model.refresh() } }
                .sensoryFeedback(.success, trigger: model.successTick)
                .sensoryFeedback(.error, trigger: model.failureTick)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Apps", systemImage: "applewatch") {
                AppsView()
            }
            Tab("Devices", systemImage: "antenna.radiowaves.left.and.right") {
                DevicesView()
            }
            .badge(model.setupIssues)
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
