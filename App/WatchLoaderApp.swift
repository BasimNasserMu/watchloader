import SwiftUI

@main
struct WatchLoaderApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear {
                    model.refresh()
                    model.loadAccount()
                }
                .onChange(of: phase) { _, p in if p == .active { model.refresh() } }
                .sensoryFeedback(.success, trigger: model.successTick)
                .sensoryFeedback(.error, trigger: model.failureTick)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""

    var body: some View {
        tabs
            .alert(
                "Two-factor code",
                isPresented: Binding(get: { model.twoFactor != nil }, set: { _ in }),
                presenting: model.twoFactor
            ) { prompt in
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Verify") {
                    model.answerTwoFactor(code)
                    code = ""
                }
                if !prompt.viaSMS && !prompt.phones.isEmpty {
                    Button("Text me a code (\(prompt.phones))") {
                        model.answerTwoFactor("sms")
                        code = ""
                    }
                }
                Button("Cancel", role: .cancel) {
                    model.answerTwoFactor(nil)
                    code = ""
                }
            } message: { prompt in
                Text(prompt.viaSMS
                     ? "Enter the code sent by text message."
                     : "Enter the code shown on your other Apple devices.")
            }
    }

    private var tabs: some View {
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
