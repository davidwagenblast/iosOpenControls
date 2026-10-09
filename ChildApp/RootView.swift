import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: ChildModel

    var body: some View {
        if model.pairing == nil {
            PairView()
        } else {
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "hourglass") }
                ChoresView()
                    .tabItem { Label("Earn time", systemImage: "star.fill") }
                SetupView()
                    .tabItem { Label("Setup", systemImage: "gearshape.fill") }
            }
        }
    }
}

struct PairView: View {
    @EnvironmentObject private var model: ChildModel
    @State private var text = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Ask a parent to open **OpenControls Parent**, add you as a child, and show you the pairing QR code.")
                    Label("Scan it with the Camera app, then tap the banner.", systemImage: "qrcode.viewfinder")
                        .foregroundStyle(.secondary)
                }
                Section("Or paste the pairing link") {
                    TextField("opencontrolskid://pair?i=…", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                    Button("Pair") {
                        failed = !model.pair(with: text)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if failed {
                        Text("That doesn't look like a valid pairing link.").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair with a parent")
        }
    }
}
