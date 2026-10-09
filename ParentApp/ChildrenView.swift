import SwiftUI
import CoreImage.CIFilterBuiltins

struct ChildrenView: View {
    @EnvironmentObject private var model: ParentModel
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("Children") {
                    ForEach(model.children) { child in
                        NavigationLink {
                            PairingDetail(childID: child.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(child.name)
                                Text(child.lastStatus == nil ? "Waiting to connect" : "Connected")
                                    .font(.footnote)
                                    .foregroundStyle(child.lastStatus == nil ? .orange : .green)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { model.removeChild(model.children[i].id) }
                    }
                    Button { showAdd = true } label: { Label("Add a child", systemImage: "plus") }
                }
                Section("About") {
                    Text("Limits are enforced on each child's own phone by Apple's Screen Time system. This app only sends rules and receives updates, end-to-end encrypted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Family")
            .sheet(isPresented: $showAdd) {
                NavigationStack { AddChildView(isOnboarding: false) }
            }
        }
    }
}

struct AddChildView: View {
    @EnvironmentObject private var model: ParentModel
    @Environment(\.dismiss) private var dismiss
    let isOnboarding: Bool
    @State private var name = ""
    @State private var createdID: UUID?

    var body: some View {
        Group {
            if let createdID {
                PairingDetail(childID: createdID)
            } else {
                Form {
                    Section {
                        if isOnboarding {
                            Text("Welcome! Let's set up your first child. You'll install **OpenControls Kid** on their phone and pair it with a QR code.")
                        }
                        TextField("Child's name", text: $name)
                            .textContentType(.givenName)
                    }
                    Section {
                        Button("Continue") {
                            let trimmed = name.trimmingCharacters(in: .whitespaces)
                            if model.addChild(name: trimmed) != nil {
                                createdID = model.selectedChildID
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .navigationTitle(createdID == nil ? "Add a child" : "Pair phone")
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) { Button(createdID == nil ? "Cancel" : "Done") { dismiss() } }
            }
        }
    }
}

struct PairingDetail: View {
    @EnvironmentObject private var model: ParentModel
    let childID: UUID

    var body: some View {
        if let child = model.child(childID), let invite = model.invite(for: childID) {
            Form {
                Section {
                    if let image = QRCode.image(for: invite.url.absoluteString) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 240)
                            .padding(.vertical, 8)
                            .accessibilityLabel("Pairing QR code")
                    }
                    ShareLink(item: invite.url) {
                        Label("Send pairing link", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Pair \(child.name)'s phone")
                } footer: {
                    Text("On \(child.name)'s phone, install OpenControls Kid, then scan this code with the Camera app and tap the banner. Treat the code like a password: anyone who has it can pair a phone.")
                }
                Section("Then, on their phone") {
                    Label("Open Setup and turn on Screen Time access (you'll sign in with your Apple ID).", systemImage: "1.circle")
                    Label("Choose which apps belong to each group.", systemImage: "2.circle")
                    Label("Set a parent PIN under Rules → More options.", systemImage: "3.circle")
                }
                if let status = child.lastStatus {
                    Section {
                        Label("Connected — last update \(status.sentAt.formatted(.relative(presentation: .named)))",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle(child.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
