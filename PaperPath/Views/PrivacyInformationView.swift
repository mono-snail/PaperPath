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
                        "Documents and recognition",
                        "PDF editing, scanning, OCR, and privacy detection run on your device. PaperPath does not require an account and does not upload your PDF content to a PaperPath server."
                    )
                    information(
                        "Optional iCloud metadata",
                        "Off by default. If enabled, reading position, bookmarks, tags, workflow state, file fingerprints, and receipt metadata can sync through your iCloud account. PDF files and extracted text are not included. Tags and receipt metadata may still contain information you consider private."
                    )
                    information(
                        "Keep a copy outside PaperPath",
                        "PaperPath excludes its private document library from automatic device backups. iCloud metadata sync does not back up PDFs. Export documents you want to keep to Files or another location before deleting the app or replacing your device."
                    )
                    information(
                        "Sharing and diagnostics",
                        "Files leave PaperPath when you choose to share or export them. The destination app or service then handles that copy. Private diagnostics include app, device, and library counts, but exclude PDF contents, file names, extracted text, passwords, and signatures."
                    )
                    information(
                        "Permissions you control",
                        "Camera access is used for document and identity-code scanning. Face ID is used for App Lock. Notifications are optional due-date reminders. You can change system permissions in Settings."
                    )
                    information(
                        "Purchases and tracking",
                        "Apple handles payments and purchase restoration. PaperPath uses the verified purchase status to unlock Verified Output. PaperPath includes no advertising or third-party analytics SDK."
                    )
                    information(
                        "Delete and protect your data",
                        "Manage working copies and Trash in PaperPath. Delete All Local Data in Settings removes local documents and related data, while your imported originals stay untouched. Synced metadata has a separate Delete Synced Metadata action. Copies already shared or exported are managed separately."
                    )
                    information(
                        "Before sending a document",
                        "Automatic privacy detection can miss information. Review the PDF before sharing. Permanent redaction cannot be undone in the resulting copy. Verified Output checks files and pages; it does not certify content accuracy, identity, or legal compliance."
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
