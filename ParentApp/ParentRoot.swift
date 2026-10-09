import SwiftUI

struct ParentRoot: View {
    @EnvironmentObject private var model: ParentModel

    var body: some View {
        Group {
            if model.children.isEmpty {
                NavigationStack { AddChildView(isOnboarding: true) }
            } else {
                TabView {
                    OverviewView()
                        .tabItem { Label("Overview", systemImage: "rectangle.grid.1x2.fill") }
                    InboxView()
                        .tabItem { Label("Requests", systemImage: "tray.fill") }
                        .badge(model.pendingInbox.count)
                    RulesView()
                        .tabItem { Label("Rules", systemImage: "slider.horizontal.3") }
                    InsightsView()
                        .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
                    ChildrenView()
                        .tabItem { Label("Family", systemImage: "person.2.fill") }
                }
            }
        }
        .alert("Heads up", isPresented: Binding(get: { model.lastError != nil },
                                                  set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Picker shown at the top of each tab when more than one child is paired.
struct ChildPicker: View {
    @EnvironmentObject private var model: ParentModel

    var body: some View {
        if model.children.count > 1 {
            Picker("Child", selection: Binding(
                get: { model.selectedChild?.id ?? UUID() },
                set: { model.selectedChildID = $0 })) {
                ForEach(model.children) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
        }
    }
}
