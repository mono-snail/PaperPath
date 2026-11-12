import SwiftUI

/// Bundled information remains readable when the device is offline.
struct PrivacyInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PPSpacing.large) {
                    information(
                        "Works offline",
                        "Merge, split, compress, and recognize text on this device. No document uploads or PaperPath processing server. App Store downloads, optional iCloud metadata sync, and support conversations use the internet. Sharing or exporting may send files to the destination you choose."
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
                        "Support conversations",
                        "When you send feedback, your email and message go to Monoware Support. App and OS versions are optional. Conversation credentials stay in this device’s Keychain and do not sync through iCloud."
                    )
                    information(
                        "Permissions you control",
                        "Camera scans documents, Face ID locks the app, and notifications show due dates."
                    )
                    information(
                        "Purchases and tracking",
                        "PaperPath is a one-time paid download from the App Store. All PDF tools are included, with no subscription or in-app purchases. Apple handles payment; PaperPath does not receive your payment card details. Core PDF processing works offline. PaperPath has no ads or third-party analytics."
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
