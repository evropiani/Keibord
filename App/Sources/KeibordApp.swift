import SwiftUI
import KeibordCore

@main
struct KeibordApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var appearance = SystemAppearance()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(appearance.scheme)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        appearance.update()
                        model.refresh()
                    case .inactive, .background:
                        // The keyboard reads the files when it appears: never leave edits unsaved.
                        model.saveNow()
                    @unknown default:
                        break
                    }
                }
        }
    }
}

/// The iPhone's own light/dark setting, which the app follows explicitly. Coming back to the app, iOS
/// sometimes left it light in dark mode, or a mix of both: it renders apps in both styles for the app
/// switcher when they go to the background and did not always switch back.
@MainActor
final class SystemAppearance: ObservableObject {
    @Published private(set) var scheme: ColorScheme?
    private var registration: (any UITraitChangeRegistration)?

    func update() {
        // The screen's traits are the iPhone's setting; the app's own traits are what went wrong.
        let style = UIScreen.main.traitCollection.userInterfaceStyle
        let current: ColorScheme? = style == .dark ? .dark : (style == .light ? .light : nil)
        if current != scheme { scheme = current }
        observeChanges()
    }

    /// The iPhone switching between light and dark while the app is open (automatic appearance,
    /// Control Center): the window scene's traits follow the iPhone, not the app's override.
    private func observeChanges() {
        guard registration == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
            self?.update()
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
            NavigationStack { DataView() }
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var testText = ""

    private var keyboardSeen: Bool { model.state.lastActive != nil }

    private var fullAccessDetail: String {
        if model.state.hasFullAccess { return "Learning, sync with this app and haptics work" }
        if keyboardSeen { return "Off: settings and details changed here cannot reach the keyboard" }
        return "Not confirmed yet. Without Full Access, nothing you change here reaches the keyboard. "
            + "Turn it on below, then open the keyboard once. Still orange? See Shared storage."
    }

    private var sharedStorageDetail: String {
        if !model.store.isShared { return "This app has no app group: reinstall Keibord with app groups (Data → Diagnostics)" }
        if keyboardSeen { return "App and keyboard share data" }
        return "Not confirmed: the keyboard has not reported here yet. If Full Access is on and this stays "
            + "orange, your installer gave the app and the keyboard different app groups: reinstall with app groups kept."
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keibord").font(.title2.bold())
                        Text("Private, on-device keyboard").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Status") {
                StatusRow(title: "Keyboard enabled", ok: keyboardSeen,
                          detail: model.state.lastActive.map { "Last used \($0.formatted(date: .abbreviated, time: .shortened))" }
                            ?? "Not used yet (without Full Access the keyboard cannot report here)")
                StatusRow(title: "Full Access", ok: model.state.hasFullAccess, detail: fullAccessDetail)
                // Only the keyboard's own report proves that both use the same folder.
                StatusRow(title: "Shared storage", ok: model.store.isShared && keyboardSeen, detail: sharedStorageDetail)
            }

            Section("Set up") {
                Label("Open Settings → General → Keyboard → Keyboards", systemImage: "1.circle")
                Label("Add New Keyboard… → Keibord → pick a language (Keibord Deutsch, English, Shqip, Italiano); repeat for each language", systemImage: "2.circle")
                Label("Tap each Keibord keyboard → Allow Full Access", systemImage: "3.circle")
                Label("In any text field, tap 🌐 to switch between them, hold it to pick one", systemImage: "4.circle")
                Button("Open Keibord in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }

            Section("Try it") {
                TextField("Type here…", text: $testText, axis: .vertical)
                    .lineLimit(3...8)
            }

            Section {
                Text("Passwords, one-time codes from Messages/Mail and Wallet cards are only available in Apple's keyboard. In code fields Keibord shows a one-tap switch to the iOS keyboard; password fields switch automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keibord")
        .refreshable { model.refresh() }
    }
}

struct StatusRow: View {
    let title: String
    let ok: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
