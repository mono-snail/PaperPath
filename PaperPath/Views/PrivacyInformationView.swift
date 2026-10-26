import SwiftUI

/// Bundled information remains readable when the device is offline.
struct PrivacyInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PPSpacing.large) {
                    Label("Your files, under your control".localizedUI, systemImage: "hand.raised")
                        .font(.title2.bold())
                        .foregroundStyle(PPColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    information(
                        "Works offline",
                        "Merge, split, compress, and recognize text on this device. No document uploads or PaperPath processing server. Apple purchases and optional iCloud metadata sync use the internet. Sharing or exporting may send files to the destination you choose."
                    )
                    information(
                        "Documents and recognition",
                        "Editing, OCR, and privacy detection stay on your device. No account needed."
                    )
                    information(
                        "Optional iCloud metadata",
                        "Optional metadata can sync through iCloud. PDFs and extracted text do not."
                    )
                    information(
                        "Keep a copy outside PaperPath",
                        "PDFs are not backed up. Export them before deleting the app or changing devices."
                    )
                    information(
                        "Sharing and diagnostics",
                        "Files leave only when shared or exported. Diagnostics exclude document content."
                    )
                    information(
                        "Permissions you control",
                        "Camera scans documents, Face ID locks the app, and notifications show due dates."
                    )
                    information(
                        "Purchases and tracking",
                        "Apple handles payments. PaperPath has no ads or third-party analytics."
                    )
                    information(
                        "Delete and protect your data",
                        "Delete local data and iCloud metadata separately. Exported files are unaffected."
                    )
                    information(
                        "Before sending a document",
                        "Detection can miss details. Review before sharing. Redaction cannot be undone."
                    )
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(PPSpacing.large)
                .frame(maxWidth: .infinity)
            }
            .background(PPColor.canvas)
            .navigationTitle("Privacy & Data".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .accessibilityIdentifier("privacyInformation")
        }
    }

    private func information(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text(title.localizedUI)
                .font(.headline)
                .foregroundStyle(PPColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(detail.localizedUI)
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
