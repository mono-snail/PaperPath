import ImageIO
import PDFKit
import PhotosUI
import SwiftUI

private enum PDFPhotoPreparation {
    static func preparedData(
        from data: Data,
        maximumPixelSize: Int,
        jpegQuality: CGFloat
    ) -> Data? {
        guard !Task.isCancelled,
              data.count <= 64 * 1_024 * 1_024,
              (256...4_096).contains(maximumPixelSize),
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary
              )
        else { return nil }
        return preparedData(
            from: source,
            maximumPixelSize: maximumPixelSize,
            jpegQuality: jpegQuality
        )
    }

    static func preparedData(
        from fileURL: URL,
        maximumPixelSize: Int,
        jpegQuality: CGFloat
    ) -> Data? {
        let values = try? fileURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard !Task.isCancelled,
              values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let fileSize = values?.fileSize,
              fileSize > 0,
              Int64(fileSize)
                <= ProtectedPhotoTransfer.maximumEncodedByteCount,
              let source = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary
              )
        else { return nil }
        return preparedData(
            from: source,
            maximumPixelSize: maximumPixelSize,
            jpegQuality: jpegQuality
        )
    }

    private static func preparedData(
        from source: CGImageSource,
        maximumPixelSize: Int,
        jpegQuality: CGFloat
    ) -> Data? {
        guard !Task.isCancelled,
              (256...4_096).contains(maximumPixelSize),
              CGImageSourceGetCount(source) == 1,
              let sourceProperties =
                CGImageSourceCopyPropertiesAtIndex(
                    source,
                    0,
                    nil
                ) as? [CFString: Any],
              let sourceWidth = (
                  sourceProperties[kCGImagePropertyPixelWidth]
                    as? NSNumber
              )?.int64Value,
              let sourceHeight = (
                  sourceProperties[kCGImagePropertyPixelHeight]
                    as? NSNumber
              )?.int64Value,
              sourceWidth > 0,
              sourceHeight > 0,
              sourceWidth <= 100_000,
              sourceHeight <= 100_000
        else { return nil }
        let sourcePixels = sourceWidth.multipliedReportingOverflow(
            by: sourceHeight
        )
        guard !sourcePixels.overflow,
              sourcePixels.partialValue <= 200_000_000
        else { return nil }

        var attemptedEdges: Set<Int> = []
        let edges = [
            maximumPixelSize,
            max(256, Int(Double(maximumPixelSize) * 0.82)),
            max(256, Int(Double(maximumPixelSize) * 0.68))
        ]
        for edge in edges where attemptedEdges.insert(edge).inserted {
            guard !Task.isCancelled else { return nil }
            let encoded: Data? = autoreleasepool {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: edge
                ]
                guard let cgImage =
                        CGImageSourceCreateThumbnailAtIndex(
                            source,
                            0,
                            options as CFDictionary
                        )
                else { return nil }
                let preservesAlpha: Bool
                switch cgImage.alphaInfo {
                case .first, .last, .premultipliedFirst,
                     .premultipliedLast, .alphaOnly:
                    preservesAlpha = true
                case .none, .noneSkipFirst, .noneSkipLast:
                    preservesAlpha = false
                @unknown default:
                    preservesAlpha = false
                }
                let image = UIImage(cgImage: cgImage)
                return preservesAlpha
                    ? image.pngData()
                    : image.jpegData(compressionQuality: jpegQuality)
            }
            guard !Task.isCancelled else { return nil }
            if let encoded,
               !encoded.isEmpty,
               encoded.count <= 12 * 1_024 * 1_024 {
                return encoded
            }
        }
        return nil
    }
}

private struct PDFWebAddressField: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var address: String
    let accessibilityIdentifier: String
    let validationMessage: String?

    var body: some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                )
            )
            : AnyLayout(
                HStackLayout(
                    alignment: .center,
                    spacing: PPSpacing.xSmall
                )
            )

        layout {
            TextField("https://", text: $address)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityHint(validationMessage ?? "")
                .onChange(of: address) { _, value in
                    guard value.count > 4_096 else { return }
                    address = String(value.prefix(4_096))
                }

            PasteButton(payloadType: String.self) { values in
                guard let value = values.first else { return }
                address = String(value.prefix(4_096))
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint(
                "Pastes a web address without storing it in PaperPath"
            )
        }
    }
}

struct PDFContentEditorView: View {
    private enum ContentKind: String, CaseIterable, Identifiable {
        case text
        case photo
        case link

        var id: String { rawValue }

        var title: String {
            switch self {
            case .text: return "Text"
            case .photo: return "Photo"
            case .link: return "Link"
            }
        }

        var symbol: String {
            switch self {
            case .text: return "textformat"
            case .photo: return "photo"
            case .link: return "link"
            }
        }
    }

    private enum TextColor: String, CaseIterable, Identifiable {
        case black
        case blue
        case red

        var id: String { rawValue }

        var title: String {
            switch self {
            case .black: return "Black"
            case .blue: return "Blue"
            case .red: return "Red"
            }
        }

        var value: Color {
            switch self {
            case .black: return .black
            case .blue: return .blue
            case .red: return .red
            }
        }

        var payload: PDFInkColor {
            switch self {
            case .black:
                return PDFInkColor(red: 0, green: 0, blue: 0, alpha: 1)
            case .blue:
                return PDFInkColor(
                    red: 0.04,
                    green: 0.36,
                    blue: 0.88,
                    alpha: 1
                )
            case .red:
                return PDFInkColor(
                    red: 0.88,
                    green: 0.12,
                    blue: 0.16,
                    alpha: 1
                )
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let pageIndex: Int
    let onCreated: (DocumentRoute) -> Void

    @State private var kind: ContentKind = .text
    @State private var text = ""
    @State private var textColor: TextColor = .black
    @State private var fontSize = 18.0
    @State private var linkTitle = ""
    @State private var linkAddress = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var photoPreview: UIImage?
    @State private var pagePreview: UIImage?
    @State private var previewErrorMessage: String?
    @State private var isLoadingPagePreview = true
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var bounds = PDFNormalizedRect(
        x: 0.19,
        y: 0.72,
        width: 0.62,
        height: 0.16
    )
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var operationStopRequested = false
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var photoLoadGeneration = 0
    @State private var pagePreviewGeneration = 0
    @State private var pagePreviewReloadToken = UUID()
    @State private var isConfirmingDiscard = false
    @State private var sourceContentRevisionID: UUID?
    @GestureState private var translation = CGSize.zero
    @GestureState private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if model.url(for: recordID) != nil {
                    editorSurface(availableSize: proxy.size)
                } else {
                    PPEmptyState(
                        kind: .workspace,
                        title: "Working copy unavailable",
                        message: "Close this editor and reopen the document from the library."
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                }
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                precisionContextBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
            }
            .navigationTitle("Add Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationStopRequested
                                ? "Stopping"
                                : isSaving
                                ? "Stop"
                                : "Cancel"
                        ).localizedUI
                    ) {
                        if isSaving {
                            stopCreatingCopy()
                        } else {
                            requestDismissal()
                        }
                    }
                    .disabled(operationStopRequested)
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Copy") {
                        createCopy()
                    }
                    .disabled(!canCreate || isSaving)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("contentCreateCopy")
                }
            }
            .task(id: pagePreviewRequestID) {
                pagePreviewGeneration += 1
                let generation = pagePreviewGeneration
                pagePreview = nil
                previewErrorMessage = nil
                isLoadingPagePreview = true
                guard let requestedRevisionID =
                        model.record(id: recordID)?
                            .contentRevisionID,
                      let url = model.url(for: recordID)
                else {
                    isLoadingPagePreview = false
                    previewErrorMessage =
                        "The private working copy could not be opened."
                    return
                }
                if sourceContentRevisionID == nil {
                    sourceContentRevisionID = requestedRevisionID
                }
                guard sourceContentRevisionID
                        == requestedRevisionID
                else { return }
                let preview = await PDFEditorPreviewLoader.shared.preview(
                    url: url,
                    pageIndex: pageIndex,
                    revision: model.refreshToken(for: recordID)
                )
                guard !Task.isCancelled,
                      generation == pagePreviewGeneration,
                      model.record(id: recordID)?
                        .contentRevisionID
                        == requestedRevisionID
                else { return }
                guard let preview else {
                    isLoadingPagePreview = false
                    previewErrorMessage =
                        "The page preview could not be loaded. Try again."
                    return
                }
                pageAspectRatio = CGFloat(preview.aspectRatio)
                pagePreview = preview.image
                isLoadingPagePreview = false
            }
            .onChange(of: kind) { _, newKind in
                bounds = defaultBounds(for: newKind)
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
            .onChange(
                of: model.record(id: recordID)?
                    .contentRevisionID
            ) { _, revisionID in
                guard let sourceContentRevisionID,
                      revisionID != sourceContentRevisionID
                else { return }
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptProtectedContentEditing()
                dismiss()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if pagePreview == nil {
                        pagePreviewReloadToken = UUID()
                    }
                    if photoPreview == nil,
                       let photoData {
                        photoPreview = UIImage(data: photoData)
                    }
                } else if phase == .background {
                    interruptProtectedContentEditing()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedContentEditing()
            }
            .confirmationDialog(
                "Discard content draft?".localizedUI,
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(
                    "Discard Draft".localizedUI,
                    role: .destructive
                ) {
                    dismiss()
                }
                Button("Keep Editing".localizedUI, role: .cancel) {}
            } message: {
                Text(
                    "The text, link, or selected photo has not been added to a PDF copy."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(isSaving || hasDraftContent)
            .accessibilityAction(.escape) {
                if isSaving {
                    stopCreatingCopy()
                } else {
                    requestDismissal()
                }
            }
            .onDisappear {
                stopCreatingCopy(invalidateResult: true)
                photoLoadTask?.cancel()
                photoLoadTask = nil
                photoLoadGeneration += 1
                pagePreviewGeneration += 1
                pagePreview = nil
                previewErrorMessage = nil
                photoPreview = nil
                photoData = nil
                text = ""
                linkTitle = ""
                linkAddress = ""
            }
            .sensoryFeedback(.error, trigger: previewErrorMessage)
            .sensoryFeedback(.selection, trigger: kind)
        }
    }

    private var precisionContextBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.medium) {
                Label(
                    "Page \(pageIndex + 1)",
                    systemImage: "doc.text"
                )
                Label(kind.title, systemImage: kind.symbol)
                Label(
                    "\(Int(bounds.width * 100))×\(Int(bounds.height * 100))%",
                    systemImage: "arrow.up.left.and.arrow.down.right"
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PPSpacing.regular)
        }
        .scrollIndicators(.hidden)
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .lineLimit(1)
        .frame(minHeight: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func editorSurface(
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        return ZStack {
            PPColor.canvas

            ZStack {
                Color.white
                if let pagePreview {
                    Image(uiImage: pagePreview)
                        .resizable()
                        .scaledToFit()
                    contentOverlay(pageSize: pageSize)
                } else if isLoadingPagePreview {
                    previewLoadingState
                } else if let previewErrorMessage {
                    contentPreviewFailure(previewErrorMessage)
                } else {
                    contentPreviewFailure(
                        "The page preview stopped before it was ready. Try again."
                            .localizedUI
                    )
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
    }

    private var previewLoadingState: some View {
        VStack(spacing: PPSpacing.small) {
            ProgressView()
            Text("Loading page preview".localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func contentPreviewFailure(
        _ message: String
    ) -> some View {
        VStack(spacing: PPSpacing.medium) {
            Label(
                message.localizedUI,
                systemImage: "doc.questionmark"
            )
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            Button {
                retryPagePreview()
            } label: {
                Label(
                    "Load Preview Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(PPQuietButtonStyle())
            .accessibilityIdentifier(
                "retryContentEditorPreview"
            )
        }
        .padding(PPSpacing.regular)
    }

    private func contentOverlay(pageSize: CGSize) -> some View {
        let rect = displayRect(pageSize: pageSize)
        return Group {
            switch kind {
            case .text:
                Text(text.isEmpty ? "Text" : text)
                    .font(.system(size: previewFontSize))
                    .foregroundStyle(textColor.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            case .photo:
                if let photoPreview {
                    Image(uiImage: photoPreview)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.title)
                        .foregroundStyle(PPColor.textSecondary)
                }
            case .link:
                HStack(spacing: 5) {
                    Image(systemName: "link")
                    Text(linkTitle.isEmpty ? "Link" : linkTitle)
                        .lineLimit(2)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background(Color.white.opacity(kind == .photo ? 0 : 0.08))
        .overlay {
            Rectangle()
                .stroke(PPColor.accent, lineWidth: 1.4)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(PPColor.accent)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .offset(x: 7, y: 7)
                .accessibilityHidden(true)
        }
        .frame(
            width: max(44, rect.width),
            height: max(44, rect.height)
        )
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($translation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    move(by: value.translation, pageSize: pageSize)
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .updating($scale) { value, state, _ in
                    state = value
                }
                .onEnded(resize(by:))
        )
        .accessibilityLabel(
            AppLocalization.format(
                "%@ placement",
                kind.title.localizedUI
            )
        )
        .accessibilityHint(
            "Drag to move or pinch to resize".localizedUI
        )
    }

    private var controls: some View {
        VStack(spacing: PPSpacing.small) {
            if isSaving {
                copyCommitStatus(
                    isStopping: operationStopRequested
                )
            }

            OperationBoundaryNotice(
                title: "Document extras may not carry into the copy",
                detail: "Embedded files, bookmarks, and custom page labels may not be preserved. The source PDF stays unchanged.",
                identifier: "addContentStructureBoundary"
            )

            let picker = Picker("Content type", selection: $kind) {
                ForEach(ContentKind.allCases) { item in
                    Label(
                        item.title.localizedUI,
                        systemImage: item.symbol
                    )
                        .tag(item)
                }
            }
            if dynamicTypeSize.ppPrefersExpandedLayout {
                picker
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("contentKindPicker")
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44,
                        alignment: .leading
                    )
            } else {
                picker
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("contentKindPicker")
            }

            PrecisionPlacementRail(
                bounds: $bounds,
                tint: PPColor.accent,
                title: kind.title
            )

            Group {
                switch kind {
                case .text:
                    textControls
                case .photo:
                    photoControls
                case .link:
                    linkControls
                }
            }
        }
        .disabled(isSaving)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func copyCommitStatus(
        isStopping: Bool
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(
                (
                    isStopping
                        ? "Finishing current file commit"
                        : "Creating private copy"
                ).localizedUI
            )
            .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            OnDeviceBadge(compact: true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var textControls: some View {
        VStack(spacing: PPSpacing.small) {
            TextField("Text", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .accessibilityIdentifier("contentText")
                .disabled(isSaving)
                .onChange(of: text) { _, value in
                    guard value.count > 2_000 else { return }
                    text = String(value.prefix(2_000))
                }
            HStack(spacing: PPSpacing.small) {
                Text("\(text.count)/2000")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityLabel("Text length")
                    .accessibilityValue(
                        AppLocalization.format(
                            "%lld of %lld",
                            text.count,
                            2_000
                        )
                    )
                Spacer(minLength: PPSpacing.small)
                PasteButton(payloadType: String.self) { values in
                    guard let value = values.first else { return }
                    text = String(value.prefix(2_000))
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isSaving)
                .accessibilityLabel("Paste content text".localizedUI)
            }

            HStack(spacing: PPSpacing.medium) {
                ForEach(TextColor.allCases) { color in
                    Button {
                        textColor = color
                    } label: {
                        Circle()
                            .fill(color.value)
                            .frame(width: 24, height: 24)
                            .overlay {
                                Circle()
                                    .stroke(
                                        textColor == color
                                            ? PPColor.textPrimary
                                            : PPColor.border,
                                        lineWidth: textColor == color ? 2 : 0.8
                                    )
                                    .padding(-4)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        AppLocalization.format(
                            "%@ text",
                            color.title.localizedUI
                        )
                    )
                    .accessibilityAddTraits(
                        textColor == color ? .isSelected : []
                    )
                }

                Slider(value: $fontSize, in: 10...42) {
                    Text("Text size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
            }
        }
    }

    private var photoControls: some View {
        let title = isLoadingPhoto
            ? "Preparing Photo"
            : photoData == nil
                ? "Choose Photo"
                : "Replace Photo"
        let symbol = photoData == nil
            ? "photo.badge.plus"
            : "photo.badge.arrow.down"
        return PhotosPicker(selection: $photoItem, matching: .images) {
            Label(title.localizedUI, systemImage: symbol)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPQuietButtonStyle())
        .disabled(isLoadingPhoto)
    }

    private var linkControls: some View {
        VStack(spacing: PPSpacing.small) {
            TextField("Link label", text: $linkTitle)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.next)
                .onChange(of: linkTitle) { _, value in
                    guard value.count > 240 else { return }
                    linkTitle = String(value.prefix(240))
                }
            PDFWebAddressField(
                address: $linkAddress,
                accessibilityIdentifier: "newLinkAddress",
                validationMessage: linkValidationMessage
            )
            if let linkValidationMessage {
                Label(
                    linkValidationMessage,
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.rose)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var canCreate: Bool {
        guard pagePreview != nil,
              previewErrorMessage == nil
        else { return false }
        switch kind {
        case .text:
            return !text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        case .photo:
            return photoData != nil && !isLoadingPhoto
        case .link:
            return !linkTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty && validatedURL != nil
        }
    }

    private var hasDraftContent: Bool {
        !text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            || photoItem != nil
            || photoData != nil
            || !linkTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            || !linkAddress.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    private func requestDismissal() {
        if hasDraftContent {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func retryPagePreview() {
        pagePreview = nil
        previewErrorMessage = nil
        isLoadingPagePreview = true
        pagePreviewReloadToken = UUID()
    }

    private var validatedURL: URL? {
        let trimmed = linkAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://")
            ? trimmed
            : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host,
              !host.isEmpty,
              host.utf8.count <= 253,
              url.user == nil,
              url.password == nil,
              url.absoluteString.utf8.count <= 4_096
        else { return nil }
        return url
    }

    private var linkValidationMessage: String? {
        let trimmed = linkAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, validatedURL == nil else {
            return nil
        }
        return "Enter a valid HTTP or HTTPS address.".localizedUI
    }

    private var previewFontSize: CGFloat {
        min(max(CGFloat(fontSize) * 0.72, 10), 30)
    }

    private func createCopy() {
        guard canCreate,
              let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID
        else { return }
        let overlay: PDFContentOverlay
        switch kind {
        case .text:
            overlay = .text(
                pageIndex: pageIndex,
                bounds: bounds,
                text: text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                fontSize: fontSize,
                color: textColor.payload
            )
        case .photo:
            guard let photoData else { return }
            overlay = .image(
                pageIndex: pageIndex,
                bounds: bounds,
                data: photoData
            )
        case .link:
            guard let validatedURL else { return }
            overlay = .link(
                pageIndex: pageIndex,
                bounds: bounds,
                title: linkTitle.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                url: validatedURL
            )
        }
        isSaving = true
        operationStopRequested = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createEditedCopy(
                    recordID: recordID,
                    overlays: [overlay],
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            isSaving = false
            operationTask = nil
            operationStopRequested = false
            guard !wasStopped else {
                model[noticeFor: paperPathSceneID] = created == nil
                    ? "Copy creation stopped".localizedUI
                    : "Copy finished before stopping · copy kept in Library"
                        .localizedUI
                return
            }
            guard let created else { return }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        photoLoadTask?.cancel()
        photoLoadGeneration += 1
        let generation = photoLoadGeneration
        isLoadingPhoto = true
        photoData = nil
        photoPreview = nil
        photoLoadTask = Task { @MainActor in
            defer {
                if generation == photoLoadGeneration {
                    isLoadingPhoto = false
                    photoLoadTask = nil
                    photoItem = nil
                }
            }
            let transfer: ProtectedPhotoTransfer?
            do {
                transfer = try await item.loadTransferable(
                    type: ProtectedPhotoTransfer.self
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      generation == photoLoadGeneration,
                      scenePhase == .active,
                      UIApplication.shared.isProtectedDataAvailable
                else { return }
                if LocalFileSecurity.isInsufficientStorageError(error) {
                    model.present(
                        PaperPathError.insufficientStorage,
                        in: paperPathSceneID
                    )
                    return
                }
                model[noticeFor: paperPathSceneID] = "The selected photo could not be opened"
                    .localizedUI
                return
            }
            guard !Task.isCancelled,
                  generation == photoLoadGeneration,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            guard let transfer else {
                model[noticeFor: paperPathSceneID] =
                    "The selected photo could not be opened".localizedUI
                return
            }
            defer { transfer.discard() }
            guard transfer.byteCount <= 32 * 1_024 * 1_024,
                  let prepared = await Self.preparePhoto(
                    transfer.fileURL
                  )
            else {
                guard generation == photoLoadGeneration else {
                    return
                }
                model[noticeFor: paperPathSceneID] = "The selected photo could not be opened"
                    .localizedUI
                return
            }
            guard !Task.isCancelled,
                  generation == photoLoadGeneration,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            photoData = prepared
            photoPreview = UIImage(data: prepared)
        }
    }

    private static func preparePhoto(_ fileURL: URL) async -> Data? {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return autoreleasepool {
                PDFPhotoPreparation.preparedData(
                    from: fileURL,
                    maximumPixelSize: 1_800,
                    jpegQuality: 0.86
                )
            }
        }
        return try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private var pagePreviewRequestID: String {
        [
            recordID.uuidString,
            String(pageIndex),
            String(model.refreshToken(for: recordID)),
            pagePreviewReloadToken.uuidString
        ].joined(separator: "-")
    }

    private func interruptProtectedContentWork() {
        pagePreviewGeneration += 1
        photoLoadGeneration += 1
        photoLoadTask?.cancel()
        photoLoadTask = nil
        isLoadingPhoto = false
        photoItem = nil
        stopCreatingCopy(invalidateResult: true)
        pagePreview = nil
        previewErrorMessage = nil
        isLoadingPagePreview = false
        photoPreview = nil
        photoData = nil
    }

    private func interruptProtectedContentEditing() {
        interruptProtectedContentWork()
        text = ""
        linkTitle = ""
        linkAddress = ""
        dismiss()
    }

    private func stopCreatingCopy(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
        } else {
            guard operationTask != nil,
                  !operationStopRequested
            else { return }
            operationStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            isSaving = false
            operationStopRequested = false
        }
    }

    private func fittedPageSize(in availableSize: CGSize) -> CGSize {
        let maximum = CGSize(
            width: max(1, availableSize.width - 32),
            height: max(1, availableSize.height - 24)
        )
        guard maximum.width / maximum.height > pageAspectRatio else {
            return CGSize(
                width: maximum.width,
                height: maximum.width / pageAspectRatio
            )
        }
        return CGSize(
            width: maximum.height * pageAspectRatio,
            height: maximum.height
        )
    }

    private func displayRect(pageSize: CGSize) -> CGRect {
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale
        let centerX = bounds.x + bounds.width / 2
        let centerY = bounds.y + bounds.height / 2
        return CGRect(
            x: (
                centerX - scaledWidth / 2
                    + translation.width / pageSize.width
            ) * pageSize.width,
            y: (
                centerY - scaledHeight / 2
                    + translation.height / pageSize.height
            ) * pageSize.height,
            width: scaledWidth * pageSize.width,
            height: scaledHeight * pageSize.height
        )
    }

    private func move(by value: CGSize, pageSize: CGSize) {
        let x = bounds.x + value.width / pageSize.width
        let y = bounds.y + value.height / pageSize.height
        bounds = PDFNormalizedRect(
            x: min(max(0, x), 1 - bounds.width),
            y: min(max(0, y), 1 - bounds.height),
            width: bounds.width,
            height: bounds.height
        )
    }

    private func resize(by value: CGFloat) {
        let newWidth = min(max(bounds.width * value, 0.14), 0.9)
        let newHeight = min(max(bounds.height * value, 0.06), 0.62)
        let centerX = bounds.x + bounds.width / 2
        let centerY = bounds.y + bounds.height / 2
        bounds = PDFNormalizedRect(
            x: min(
                max(0, centerX - newWidth / 2),
                1 - newWidth
            ),
            y: min(
                max(0, centerY - newHeight / 2),
                1 - newHeight
            ),
            width: newWidth,
            height: newHeight
        )
    }

    private func defaultBounds(
        for contentKind: ContentKind
    ) -> PDFNormalizedRect {
        switch contentKind {
        case .text:
            return PDFNormalizedRect(
                x: 0.19,
                y: 0.72,
                width: 0.62,
                height: 0.16
            )
        case .photo:
            return PDFNormalizedRect(
                x: 0.27,
                y: 0.34,
                width: 0.46,
                height: 0.3
            )
        case .link:
            return PDFNormalizedRect(
                x: 0.19,
                y: 0.76,
                width: 0.62,
                height: 0.1
            )
        }
    }

}

struct PDFLinkEditorView: View {
    private enum PendingDraftAction {
        case dismiss
        case selectLink(String)
        case switchPage(Int)
    }

    private enum TargetKind: String, CaseIterable, Identifiable {
        case web
        case page

        var id: String { rawValue }

        var title: String {
            switch self {
            case .web: return "Web"
            case .page: return "Page"
            }
        }

        var symbol: String {
            switch self {
            case .web: return "globe"
            case .page: return "doc.text"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let pageIndex: Int
    let onCreated: (DocumentRoute) -> Void

    @State private var allLinks: [PDFLinkAnnotationSnapshot] = []
    @State private var activePageIndex: Int
    @State private var selectedLinkID: String?
    @State private var linkTitle = ""
    @State private var targetKind: TargetKind = .web
    @State private var webAddress = ""
    @State private var destinationPageIndex = 0
    @State private var bounds = PDFNormalizedRect(
        x: 0.18,
        y: 0.74,
        width: 0.64,
        height: 0.08
    )
    @State private var pagePreview: UIImage?
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadMessage: String?
    @State private var isConfirmingRemoval = false
    @State private var selectionFeedback = 0
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var pageLoadTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    @State private var didLoadDocument = false
    @State private var loadRequestToken = UUID()
    @State private var pendingDraftAction: PendingDraftAction?
    @State private var sourceContentRevisionID: UUID?
    @GestureState private var translation = CGSize.zero
    @GestureState private var scale: CGFloat = 1

    init(
        recordID: UUID,
        pageIndex: Int,
        onCreated: @escaping (DocumentRoute) -> Void
    ) {
        self.recordID = recordID
        self.pageIndex = pageIndex
        self.onCreated = onCreated
        _activePageIndex = State(initialValue: max(0, pageIndex))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                editorSurface(availableSize: proxy.size)
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
            }
            .navigationTitle("Edit Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationStopRequested
                                ? "Stopping"
                                : isSaving
                                ? "Stop"
                                : "Cancel"
                        ).localizedUI
                    ) {
                        if isSaving {
                            stopSavingLinkCopy()
                        } else {
                            requestDraftAction(.dismiss)
                        }
                    }
                    .disabled(operationStopRequested)
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Copy") {
                        createUpdatedCopy()
                    }
                    .disabled(!canCreate || isSaving)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("createLinkEditedCopy")
                }
            }
            .task(id: loadRequestToken) {
                await loadDocument()
            }
            .onChange(
                of: model.record(id: recordID)?
                    .contentRevisionID
            ) { _, revisionID in
                guard let sourceContentRevisionID,
                      revisionID != sourceContentRevisionID
                else { return }
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptProtectedLinkEditing()
            }
            .onChange(of: selectedLinkID) { _, identifier in
                guard let identifier,
                      let link = links.first(where: {
                          $0.id == identifier
                      })
                else { return }
                loadDraft(from: link)
                selectionFeedback += 1
            }
            .onChange(of: linkTitle) { _, value in
                if value.count > 240 {
                    linkTitle = String(value.prefix(240))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, pagePreview == nil {
                    resumeLinkPreview()
                } else if phase == .background {
                    interruptProtectedLinkEditing()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedLinkEditing()
            }
            .confirmationDialog(
                "Remove this link?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove from New Copy", role: .destructive) {
                    createRemovedCopy()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current PDF stays unchanged.")
            }
            .confirmationDialog(
                "Discard link edits?".localizedUI,
                isPresented: Binding(
                    get: { pendingDraftAction != nil },
                    set: {
                        if !$0 {
                            pendingDraftAction = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(
                    "Discard Changes".localizedUI,
                    role: .destructive
                ) {
                    performPendingDraftAction()
                }
                Button("Keep Editing".localizedUI, role: .cancel) {
                    pendingDraftAction = nil
                }
            } message: {
                Text(
                    "The current link title, destination, or position has not been applied."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(isSaving || hasDraftChanges)
            .accessibilityAction(.escape) {
                if isSaving {
                    stopSavingLinkCopy()
                } else {
                    requestDraftAction(.dismiss)
                }
            }
            .sensoryFeedback(.selection, trigger: selectionFeedback)
            .sensoryFeedback(.error, trigger: loadMessage)
            .onDisappear {
                stopSavingLinkCopy(invalidateResult: true)
                pageLoadTask?.cancel()
                pageLoadTask = nil
                loadGeneration += 1
                pagePreview = nil
                allLinks.removeAll(keepingCapacity: false)
                selectedLinkID = nil
                linkTitle = ""
                webAddress = ""
                loadMessage = nil
                pendingDraftAction = nil
            }
        }
    }

    private func editorSurface(
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        return ZStack {
            PPColor.canvas

            ZStack {
                Color.white
                if let pagePreview {
                    Image(uiImage: pagePreview)
                        .resizable()
                        .scaledToFit()
                    linkOverlays(pageSize: pageSize)
                } else if isLoading {
                    previewLoadingState(
                        title: "Loading link preview"
                    )
                } else {
                    linkLoadFailure(
                        loadMessage
                            ?? "The page preview stopped before it was ready. Try again."
                                .localizedUI
                    )
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
    }

    private func linkOverlays(
        pageSize: CGSize
    ) -> some View {
        ForEach(links) { link in
            linkOverlay(link, pageSize: pageSize)
        }
    }

    private func linkOverlay(
        _ link: PDFLinkAnnotationSnapshot,
        pageSize: CGSize
    ) -> some View {
        let isSelected = selectedLinkID == link.id
        let displayBounds = isSelected
            ? bounds
            : link.normalizedBounds
        let rect = isSelected
            ? interactiveRect(
                displayBounds,
                pageSize: pageSize
            )
            : displayRect(
                displayBounds,
                pageSize: pageSize
            )
        let tint = isSelected
            ? PPColor.mint
            : link.target.isEditable
                ? PPColor.accent
                : PPColor.amber
        return ZStack(alignment: .topLeading) {
            Color.clear
            Rectangle()
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2.2 : 1.4,
                        dash: link.target.isEditable ? [] : [5, 3]
                    )
                )
            Image(
                systemName: link.target.isEditable
                    ? "link"
                    : "exclamationmark.link"
            )
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint)
        }
        .frame(width: rect.width, height: rect.height)
        .frame(
            width: max(44, rect.width),
            height: max(44, rect.height)
        )
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onTapGesture {
            requestDraftAction(.selectLink(link.id))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($translation) { value, state, _ in
                    guard isSelected,
                          link.target.isEditable
                    else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard isSelected,
                          link.target.isEditable
                    else { return }
                    move(
                        by: value.translation,
                        pageSize: pageSize
                    )
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .updating($scale) { value, state, _ in
                    guard isSelected,
                          link.target.isEditable
                    else { return }
                    state = value
                }
                .onEnded { value in
                    guard isSelected,
                          link.target.isEditable
                    else { return }
                    resize(by: value)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppLocalization.format(
                "%@, %@",
                link.title,
                link.target.title.localizedUI
            )
        )
        .accessibilityHint(
            link.target.isEditable
                ? "Select, then drag to move or pinch to resize"
                    .localizedUI
                : "This link action can be removed but not edited"
                    .localizedUI
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(
            isSelected ? .isSelected : []
        )
        .accessibilityAction {
            requestDraftAction(.selectLink(link.id))
        }
        .accessibilityIdentifier(
            "existingLink-\(link.pageIndex)-\(link.annotationIndex)"
        )
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            if isSaving {
                linkCommitStatus
            }

            if isLoading {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting links in this document")
                        .font(.subheadline.weight(.semibold))
                }
            } else if allLinks.isEmpty {
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    Label(
                        loadMessage ?? "No links in this document",
                        systemImage: loadMessage == nil
                            ? "link.badge.plus"
                            : "exclamationmark.link"
                    )
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("noExistingLinks")

                    if loadMessage != nil {
                        Button {
                            retryLinkInspection()
                        } label: {
                            Label(
                                "Inspect Again",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(PPQuietButtonStyle())
                        .accessibilityIdentifier(
                            "retryLinkInspection"
                        )
                    }
                }
            } else {
                linkPageHeader

                if let selectedLink {
                    linkSelectionHeader(selectedLink)

                    if selectedLink.target.isEditable {
                        editableControls
                    } else {
                        Label(
                            selectedLink.target.title,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.subheadline)
                        .foregroundStyle(PPColor.amber)
                    }

                    HStack {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Label("Remove Link", systemImage: "trash")
                        }
                        .disabled(!canRemove)
                        .accessibilityIdentifier("removeExistingLink")

                        Spacer()

                        Text("Page \(activePageIndex + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }
        }
        .disabled(isSaving)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var linkCommitStatus: some View {
        HStack(spacing: PPSpacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(
                (
                    operationStopRequested
                        ? "Finishing current file commit"
                        : "Creating private copy"
                ).localizedUI
            )
            .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            OnDeviceBadge(compact: true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var linkPageHeader: some View {
        HStack(spacing: PPSpacing.small) {
            Label(
                "\(allLinks.count) link\(allLinks.count == 1 ? "" : "s")",
                systemImage: "doc.text.magnifyingglass"
            )
            .font(.caption.smallCaps().weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)

            Spacer()

            Menu {
                ForEach(linkPages, id: \.self) { candidatePageIndex in
                    Button {
                        requestDraftAction(
                            .switchPage(candidatePageIndex)
                        )
                    } label: {
                        Label(
                            pageMenuTitle(candidatePageIndex),
                            systemImage: candidatePageIndex == activePageIndex
                                ? "checkmark"
                                : "doc.text"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(
                        AppLocalization.format(
                            "Page %lld",
                            activePageIndex + 1
                        )
                    )
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("Page with links")
            .accessibilityValue(
                AppLocalization.format(
                    "Page %lld",
                    activePageIndex + 1
                )
            )
            .accessibilityIdentifier("linkPageMenu")
        }
    }

    private func linkSelectionHeader(
        _ link: PDFLinkAnnotationSnapshot
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Label(
                "\(links.count) on page",
                systemImage: "link"
            )
            .font(.caption.smallCaps().weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)

            Spacer()

            Menu {
                ForEach(links) { option in
                    Button {
                        requestDraftAction(.selectLink(option.id))
                    } label: {
                        Label(
                            option.title,
                            systemImage: option.target.isEditable
                                ? "link"
                                : "exclamationmark.link"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(link.title)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("Selected link")
            .accessibilityValue(link.title)
            .accessibilityIdentifier("selectedLinkMenu")
        }
    }

    private var editableControls: some View {
        VStack(spacing: PPSpacing.small) {
            TextField("Link label", text: $linkTitle)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.next)
                .accessibilityIdentifier("existingLinkLabel")
                .onChange(of: linkTitle) { _, value in
                    guard value.count > 240 else { return }
                    linkTitle = String(value.prefix(240))
                }

            let picker = Picker("Link target", selection: $targetKind) {
                ForEach(TargetKind.allCases) { kind in
                    Label(
                        kind.title.localizedUI,
                        systemImage: kind.symbol
                    )
                        .tag(kind)
                }
            }
            if dynamicTypeSize.ppPrefersExpandedLayout {
                picker
                    .pickerStyle(.menu)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44,
                        alignment: .leading
                    )
                    .accessibilityIdentifier(
                        "existingLinkTarget"
                    )
            } else {
                picker
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(
                        "existingLinkTarget"
                    )
            }

            PrecisionPlacementRail(
                bounds: $bounds,
                tint: PPColor.mint,
                title: "Link"
            )

            switch targetKind {
            case .web:
                PDFWebAddressField(
                    address: $webAddress,
                    accessibilityIdentifier: "existingLinkAddress",
                    validationMessage: webLinkValidationMessage
                )
                if let webLinkValidationMessage {
                    Label(
                        webLinkValidationMessage,
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.rose)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .page:
                Stepper(
                    value: $destinationPageIndex,
                    in: 0...max(0, pageCount - 1)
                ) {
                    HStack {
                        Text("Destination")
                        Spacer()
                        Text("Page \(destinationPageIndex + 1)")
                            .monospacedDigit()
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
                .accessibilityIdentifier("existingLinkPage")
            }
        }
    }

    private var selectedLink: PDFLinkAnnotationSnapshot? {
        guard let selectedLinkID else { return nil }
        return links.first { $0.id == selectedLinkID }
    }

    private var hasDraftChanges: Bool {
        guard let selectedLink,
              selectedLink.target.isEditable
        else { return false }
        guard linkTitle == selectedLink.title,
              bounds == selectedLink.normalizedBounds
        else { return true }
        return draftTarget != selectedLink.target
    }

    private func requestDraftAction(
        _ action: PendingDraftAction
    ) {
        guard !isSaving else { return }
        switch action {
        case .selectLink(let identifier):
            guard identifier != selectedLinkID else { return }
        case .switchPage(let pageIndex):
            guard pageIndex != activePageIndex else { return }
        case .dismiss:
            break
        }
        if hasDraftChanges {
            pendingDraftAction = action
        } else {
            performDraftAction(action)
        }
    }

    private func performPendingDraftAction() {
        guard let action = pendingDraftAction else { return }
        pendingDraftAction = nil
        performDraftAction(action)
    }

    private func performDraftAction(
        _ action: PendingDraftAction
    ) {
        switch action {
        case .dismiss:
            dismiss()
        case .selectLink(let identifier):
            selectedLinkID = identifier
        case .switchPage(let pageIndex):
            switchToPage(pageIndex)
        }
    }

    private var links: [PDFLinkAnnotationSnapshot] {
        allLinks.filter { $0.pageIndex == activePageIndex }
    }

    private var linkPages: [Int] {
        Array(Set(allLinks.map(\.pageIndex))).sorted()
    }

    private var pageCount: Int {
        max(1, model.record(id: recordID)?.profile.pageCount ?? 1)
    }

    private var draftTarget: PDFLinkTarget? {
        switch targetKind {
        case .web:
            guard let url = validatedWebURL else { return nil }
            return .web(url)
        case .page:
            guard (0..<pageCount).contains(destinationPageIndex)
            else { return nil }
            return .page(destinationPageIndex)
        }
    }

    private var validatedWebURL: URL? {
        let trimmed = webAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://")
            ? trimmed
            : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              host.utf8.count <= 253,
              url.user == nil,
              url.password == nil,
              url.absoluteString.utf8.count <= 4_096
        else { return nil }
        return url
    }

    private var webLinkValidationMessage: String? {
        guard targetKind == .web else { return nil }
        let trimmed = webAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, validatedWebURL == nil else {
            return nil
        }
        return "Enter a valid HTTP or HTTPS address.".localizedUI
    }

    private var canCreate: Bool {
        guard !isLoading,
              pagePreview != nil,
              loadMessage == nil,
              selectedLink?.target.isEditable == true,
              !linkTitle.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              draftTarget != nil
        else { return false }
        return true
    }

    private var canRemove: Bool {
        !isLoading
            && !isSaving
            && pagePreview != nil
            && loadMessage == nil
            && selectedLink != nil
    }

    private func loadDocument() async {
        guard let requestedRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else {
            isLoading = false
            loadMessage = "The working copy is unavailable."
            return
        }
        if sourceContentRevisionID == nil {
            sourceContentRevisionID = requestedRevisionID
        }
        guard sourceContentRevisionID == requestedRevisionID else {
            interruptProtectedLinkEditing()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadMessage = nil
        guard let url = model.url(for: recordID) else {
            isLoading = false
            loadMessage = "The working copy is unavailable."
            return
        }
        do {
            let loadedLinks = try await model.links(
                recordID: recordID
            )
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  model.record(id: recordID)?.contentRevisionID
                    == requestedRevisionID
            else { return }
            allLinks = loadedLinks
            if !allLinks.contains(where: {
                $0.pageIndex == activePageIndex
            }), let nearestPage = linkPages.min(by: {
                abs($0 - activePageIndex) < abs($1 - activePageIndex)
            }) {
                activePageIndex = nearestPage
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            loadMessage = AppLocalization
                .userFacingErrorDescription(error)
        }
        guard !Task.isCancelled,
              generation == loadGeneration,
              model.record(id: recordID)?.contentRevisionID
                == requestedRevisionID
        else { return }
        await loadActivePage(url: url, generation: generation)
        guard !Task.isCancelled,
              generation == loadGeneration,
              model.record(id: recordID)?.contentRevisionID
                == requestedRevisionID
        else { return }
        didLoadDocument = true
    }

    private func loadActivePage(
        url: URL,
        generation: Int
    ) async {
        let requestedPageIndex = activePageIndex
        async let preview = PDFEditorPreviewLoader.shared.preview(
            url: url,
            pageIndex: requestedPageIndex,
            revision: model.refreshToken(for: recordID)
        )
        if let initial = links.first(where: {
            $0.target.isEditable
        }) ?? links.first {
            selectedLinkID = initial.id
            loadDraft(from: initial)
        } else {
            selectedLinkID = nil
        }
        let loadedPreview = await preview
        guard !Task.isCancelled,
              generation == loadGeneration,
              requestedPageIndex == activePageIndex
        else { return }
        guard let loadedPreview else {
            loadMessage = loadMessage
                ?? "The page preview could not be loaded. Try again."
            isLoading = false
            return
        }
        pagePreview = loadedPreview.image
        pageAspectRatio = CGFloat(loadedPreview.aspectRatio)
        isLoading = false
    }

    private func switchToPage(_ requestedPageIndex: Int) {
        guard requestedPageIndex != activePageIndex,
              linkPages.contains(requestedPageIndex)
        else { return }
        guard let url = model.url(for: recordID) else {
            pagePreview = nil
            isLoading = false
            loadMessage = "The working copy is unavailable.".localizedUI
            return
        }
        activePageIndex = requestedPageIndex
        loadGeneration += 1
        let generation = loadGeneration
        selectedLinkID = nil
        pagePreview = nil
        loadMessage = nil
        isLoading = true
        pageLoadTask?.cancel()
        pageLoadTask = Task { @MainActor in
            await loadActivePage(
                url: url,
                generation: generation
            )
            guard !Task.isCancelled,
                  generation == loadGeneration
            else { return }
            pageLoadTask = nil
        }
    }

    private func resumeLinkPreview() {
        guard pageLoadTask == nil else { return }
        if !didLoadDocument {
            let expectedGeneration = loadGeneration + 1
            pageLoadTask = Task { @MainActor in
                await loadDocument()
                guard !Task.isCancelled,
                      loadGeneration == expectedGeneration
                else { return }
                pageLoadTask = nil
            }
            return
        }
        guard let url = model.url(for: recordID) else {
            isLoading = false
            loadMessage = "The working copy is unavailable.".localizedUI
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let requestedPageIndex = activePageIndex
        isLoading = true
        pageLoadTask = Task { @MainActor in
            let loaded = await PDFEditorPreviewLoader.shared.preview(
                url: url,
                pageIndex: requestedPageIndex,
                revision: model.refreshToken(for: recordID)
            )
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  requestedPageIndex == activePageIndex
            else { return }
            if let loaded {
                pagePreview = loaded.image
                pageAspectRatio = CGFloat(loaded.aspectRatio)
                if !allLinks.isEmpty {
                    loadMessage = nil
                }
            } else {
                loadMessage =
                    "The page preview could not be loaded. Try again."
            }
            isLoading = false
            pageLoadTask = nil
        }
    }

    private func retryLinkInspection() {
        loadGeneration += 1
        pageLoadTask?.cancel()
        pageLoadTask = nil
        allLinks.removeAll(keepingCapacity: false)
        selectedLinkID = nil
        pagePreview = nil
        loadMessage = nil
        isLoading = true
        didLoadDocument = false
        loadRequestToken = UUID()
    }

    private func linkLoadFailure(
        _ message: String
    ) -> some View {
        VStack(spacing: PPSpacing.medium) {
            Label(
                message.localizedUI,
                systemImage: "exclamationmark.link"
            )
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            Button {
                retryLinkInspection()
            } label: {
                Label(
                    "Inspect Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(PPQuietButtonStyle())
        }
        .padding(PPSpacing.regular)
    }

    private func previewLoadingState(
        title: String
    ) -> some View {
        VStack(spacing: PPSpacing.small) {
            ProgressView()
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func interruptProtectedLinkWork() {
        loadGeneration += 1
        pageLoadTask?.cancel()
        pageLoadTask = nil
        stopSavingLinkCopy(invalidateResult: true)
        pagePreview = nil
        isLoading = false
    }

    private func interruptProtectedLinkEditing() {
        interruptProtectedLinkWork()
        allLinks.removeAll(keepingCapacity: false)
        selectedLinkID = nil
        linkTitle = ""
        webAddress = ""
        loadMessage = nil
        isConfirmingRemoval = false
        pendingDraftAction = nil
        dismiss()
    }

    private func stopSavingLinkCopy(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
        } else {
            guard operationTask != nil,
                  !operationStopRequested
            else { return }
            operationStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            isSaving = false
            operationStopRequested = false
        }
    }

    private func pageMenuTitle(_ candidatePageIndex: Int) -> String {
        let linkCount = allLinks.filter {
            $0.pageIndex == candidatePageIndex
        }.count
        return "Page \(candidatePageIndex + 1) · \(linkCount)"
    }

    private func loadDraft(
        from link: PDFLinkAnnotationSnapshot
    ) {
        linkTitle = link.title
        bounds = link.normalizedBounds
        switch link.target {
        case .web(let url):
            targetKind = .web
            webAddress = url.absoluteString
        case .page(let targetPageIndex):
            targetKind = .page
            destinationPageIndex = min(
                max(0, targetPageIndex),
                pageCount - 1
            )
        case .unsupported:
            break
        }
    }

    private func createUpdatedCopy() {
        guard canCreate,
              let selectedLink,
              let draftTarget
        else { return }
        let mutation = PDFLinkMutation.update(
            PDFLinkEditPayload(
                pageIndex: selectedLink.pageIndex,
                annotationIndex: selectedLink.annotationIndex,
                normalizedBounds: bounds,
                title: linkTitle.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                target: draftTarget
            )
        )
        createCopy(mutation)
    }

    private func createRemovedCopy() {
        guard canRemove,
              let selectedLink
        else { return }
        createCopy(
            .remove(
                pageIndex: selectedLink.pageIndex,
                annotationIndex: selectedLink.annotationIndex
            )
        )
    }

    private func createCopy(
        _ mutation: PDFLinkMutation
    ) {
        guard let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID
        else { return }
        isSaving = true
        operationStopRequested = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createLinkEditedCopy(
                    recordID: recordID,
                    mutation: mutation,
                    expectedLink: selectedLink,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            isSaving = false
            operationTask = nil
            operationStopRequested = false
            guard !wasStopped else {
                model[noticeFor: paperPathSceneID] = created == nil
                    ? "Copy creation stopped".localizedUI
                    : "Copy finished before stopping · copy kept in Library"
                        .localizedUI
                return
            }
            guard let created else { return }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func fittedPageSize(
        in availableSize: CGSize
    ) -> CGSize {
        let maximum = CGSize(
            width: max(1, availableSize.width - 32),
            height: max(1, availableSize.height - 24)
        )
        guard maximum.width / maximum.height > pageAspectRatio else {
            return CGSize(
                width: maximum.width,
                height: maximum.width / pageAspectRatio
            )
        }
        return CGSize(
            width: maximum.height * pageAspectRatio,
            height: maximum.height
        )
    }

    private func displayRect(
        _ normalized: PDFNormalizedRect,
        pageSize: CGSize
    ) -> CGRect {
        CGRect(
            x: normalized.x * pageSize.width,
            y: normalized.y * pageSize.height,
            width: normalized.width * pageSize.width,
            height: normalized.height * pageSize.height
        )
    }

    private func interactiveRect(
        _ normalized: PDFNormalizedRect,
        pageSize: CGSize
    ) -> CGRect {
        let scaledWidth = normalized.width * scale
        let scaledHeight = normalized.height * scale
        let centerX = normalized.x + normalized.width / 2
        let centerY = normalized.y + normalized.height / 2
        return CGRect(
            x: (
                centerX - scaledWidth / 2
                    + translation.width / pageSize.width
            ) * pageSize.width,
            y: (
                centerY - scaledHeight / 2
                    + translation.height / pageSize.height
            ) * pageSize.height,
            width: scaledWidth * pageSize.width,
            height: scaledHeight * pageSize.height
        )
    }

    private func move(
        by value: CGSize,
        pageSize: CGSize
    ) {
        let x = bounds.x + value.width / pageSize.width
        let y = bounds.y + value.height / pageSize.height
        bounds = PDFNormalizedRect(
            x: min(max(0, x), 1 - bounds.width),
            y: min(max(0, y), 1 - bounds.height),
            width: bounds.width,
            height: bounds.height
        )
    }

    private func resize(by value: CGFloat) {
        let newWidth = min(max(bounds.width * value, 0.08), 0.94)
        let newHeight = min(max(bounds.height * value, 0.04), 0.7)
        let centerX = bounds.x + bounds.width / 2
        let centerY = bounds.y + bounds.height / 2
        bounds = PDFNormalizedRect(
            x: min(
                max(0, centerX - newWidth / 2),
                1 - newWidth
            ),
            y: min(
                max(0, centerY - newHeight / 2),
                1 - newHeight
            ),
            width: newWidth,
            height: newHeight
        )
    }

}

struct PDFImageReplacementView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let pageIndex: Int
    let onCreated: (DocumentRoute) -> Void

    @State private var objects: [PDFImageObjectSnapshot] = []
    @State private var selectedObjectID: String?
    @State private var replacementItem: PhotosPickerItem?
    @State private var replacementData: Data?
    @State private var replacementPreview: UIImage?
    @State private var originalPreview: UIImage?
    @State private var pagePreview: UIImage?
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var isInspecting = true
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var inspectionMessage: String?
    @State private var inspectionFailed = false
    @State private var isConfirmingSharedReplacement = false
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var operationStopRequested = false
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var originalPreviewTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    @State private var photoLoadGeneration = 0
    @State private var originalPreviewGeneration = 0
    @State private var didLoadDocument = false
    @State private var previewReloadToken = UUID()
    @State private var isConfirmingDiscard = false
    @State private var sourceContentRevisionID: UUID?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                replacementSurface(availableSize: proxy.size)
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                replacementContextBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
            }
            .navigationTitle("Replace PDF Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            operationStopRequested
                                ? "Stopping"
                                : isSaving
                                ? "Stop"
                                : "Cancel"
                        ).localizedUI
                    ) {
                        if isSaving {
                            stopReplacingImage()
                        } else {
                            requestImageDismissal()
                        }
                    }
                    .disabled(operationStopRequested)
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Copy") {
                        if selectedObject?.replacesMultipleUses == true {
                            isConfirmingSharedReplacement = true
                        } else {
                            createCopy()
                        }
                    }
                    .disabled(!canCreate || isSaving)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .task(id: previewReloadToken) {
                if didLoadDocument {
                    await reloadImagePagePreview()
                } else {
                    await loadImageDocument()
                }
            }
            .onChange(
                of: model.record(id: recordID)?
                    .contentRevisionID
            ) { _, revisionID in
                guard let sourceContentRevisionID,
                      revisionID != sourceContentRevisionID
                else { return }
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptProtectedImageEditing()
            }
            .onChange(of: replacementItem) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
            .onChange(of: selectedObjectID) { _, _ in
                loadOriginalPreview()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if pagePreview == nil {
                        previewReloadToken = UUID()
                    }
                    if originalPreview == nil {
                        loadOriginalPreview()
                    }
                    if replacementPreview == nil,
                       let replacementData {
                        replacementPreview = UIImage(
                            data: replacementData
                        )
                    }
                } else if phase == .background {
                    interruptProtectedImageEditing()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedImageEditing()
            }
            .confirmationDialog(
                "Replace every use of this image?",
                isPresented: $isConfirmingSharedReplacement,
                titleVisibility: .visible
            ) {
                if let selectedObject {
                    Button(
                        "Replace All \(selectedObject.usageCount) Uses"
                    ) {
                        createCopy()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This PDF reuses one image object in several places. The new private copy will update every reference together."
                )
            }
            .confirmationDialog(
                "Discard replacement photo?".localizedUI,
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(
                    "Discard Photo".localizedUI,
                    role: .destructive
                ) {
                    dismiss()
                }
                Button("Keep Editing".localizedUI, role: .cancel) {}
            } message: {
                Text(
                    "The selected photo has not been applied to a PDF copy."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(isSaving || hasDraftReplacement)
            .accessibilityAction(.escape) {
                if isSaving {
                    stopReplacingImage()
                } else {
                    requestImageDismissal()
                }
            }
            .sensoryFeedback(.error, trigger: inspectionFailed)
            .sensoryFeedback(
                .selection,
                trigger: selectedObjectID
            )
            .onDisappear {
                stopReplacingImage(invalidateResult: true)
                photoLoadTask?.cancel()
                photoLoadTask = nil
                originalPreviewTask?.cancel()
                originalPreviewTask = nil
                loadGeneration += 1
                photoLoadGeneration += 1
                originalPreviewGeneration += 1
                pagePreview = nil
                originalPreview = nil
                replacementPreview = nil
                replacementData = nil
                objects.removeAll(keepingCapacity: false)
                selectedObjectID = nil
                inspectionMessage = nil
                inspectionFailed = false
            }
        }
    }

    private var replacementContextBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.medium) {
                Label(
                    "Page \(pageIndex + 1)",
                    systemImage: "doc.text"
                )
                Label(
                    "\(objects.count)",
                    systemImage: "photo.stack"
                )
                if let selectedObject {
                    Label(
                        "\(selectedObject.pixelWidth)×\(selectedObject.pixelHeight)",
                        systemImage: "photo"
                    )
                    if selectedObject.replacesMultipleUses {
                        Label(
                            "\(selectedObject.usageCount) uses",
                            systemImage: "square.stack.3d.up"
                        )
                        .foregroundStyle(PPColor.amber)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PPSpacing.regular)
        }
        .scrollIndicators(.hidden)
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .lineLimit(1)
        .frame(minHeight: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func replacementSurface(
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        return ZStack {
            PPColor.canvas

            ZStack {
                Color.white
                if let pagePreview {
                    Image(uiImage: pagePreview)
                        .resizable()
                        .scaledToFit()
                    objectOverlays(pageSize: pageSize)
                } else if isInspecting {
                    imagePreviewLoadingState
                } else {
                    imageInspectionFailure(
                        inspectionMessage
                            ?? "The page preview stopped before it was ready. Try again."
                                .localizedUI
                    )
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
    }

    private func objectOverlays(pageSize: CGSize) -> some View {
        ForEach(objects) { object in
            let rect = displayRect(
                object.normalizedBounds,
                pageSize: pageSize
            )
            Button {
                guard object.isSafelyReplaceable else { return }
                selectedObjectID = object.id
            } label: {
                Color.clear
                    .frame(width: rect.width, height: rect.height)
                    .overlay {
                        Rectangle()
                            .stroke(
                                selectedObjectID == object.id
                                    ? PPColor.mint
                                    : object.replacesMultipleUses
                                        ? PPColor.amber
                                        : PPColor.accent,
                                style: StrokeStyle(
                                    lineWidth: selectedObjectID == object.id
                                        ? 2.2
                                        : 1.4,
                                    dash: object.replacesMultipleUses
                                        ? [5, 3]
                                        : []
                                )
                            )
                    }
                    .overlay(alignment: .topLeading) {
                        Image(
                            systemName: object.replacesMultipleUses
                                ? "square.stack.3d.up"
                                : "photo"
                        )
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(
                            object.replacesMultipleUses
                                ? PPColor.amber
                                : PPColor.accent
                        )
                    }
                    .frame(
                        width: max(44, rect.width),
                        height: max(44, rect.height)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityLabel(
                object.replacesMultipleUses
                    ? AppLocalization.format(
                        "Shared image used %lld times",
                        object.usageCount
                    )
                    : AppLocalization.format(
                        "Replaceable image %lld by %lld pixels",
                        object.pixelWidth,
                        object.pixelHeight
                    )
            )
        }
    }

    private var controls: some View {
        let pickerTitle = isLoadingPhoto
            ? "Preparing Photo"
            : replacementData == nil
                ? "Choose Replacement"
                : "Choose Another Photo"
        let pickerSymbol = replacementData == nil
            ? "photo.badge.plus"
            : "photo.badge.arrow.down"
        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            if isSaving {
                imageCommitStatus
            }

            if isInspecting {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting page objects")
                        .font(.subheadline.weight(.semibold))
                }
            } else if let inspectionMessage {
                Label(
                    inspectionMessage,
                    systemImage: objects.isEmpty
                        ? "photo.badge.exclamationmark"
                        : "arrow.triangle.branch"
                )
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)

                if inspectionFailed {
                    Button {
                        retryImageInspection()
                    } label: {
                        Label(
                            "Inspect Again",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(PPQuietButtonStyle())
                    .accessibilityIdentifier(
                        "retryImageInspection"
                    )
                }
            }

            if !isInspecting, !objects.isEmpty {
                HStack(spacing: PPSpacing.medium) {
                    Label(
                        AppLocalization.format(
                            "%lld found",
                            objects.count
                        ),
                        systemImage: "photo.stack"
                    )
                    Label(
                        AppLocalization.format(
                            "%lld replaceable",
                            objects.filter(\.isSafelyReplaceable).count
                        ),
                        systemImage: "checkmark.circle"
                    )
                    if objects.contains(where: \.replacesMultipleUses) {
                        Label(
                            "Shared assets",
                            systemImage: "square.stack.3d.up"
                        )
                        .foregroundStyle(PPColor.amber)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                )
            }

            if let selectedObject {
                let summaryLayout =
                    dynamicTypeSize.ppPrefersExpandedLayout
                    ? AnyLayout(
                        VStackLayout(
                            alignment: .leading,
                            spacing: PPSpacing.small
                        )
                    )
                    : AnyLayout(
                        HStackLayout(spacing: PPSpacing.regular)
                    )
                summaryLayout {
                    HStack(spacing: PPSpacing.small) {
                        imagePreview(
                            originalPreview,
                            label: "Original"
                        )
                        Image(systemName: "arrow.right")
                            .foregroundStyle(PPColor.textSecondary)
                        imagePreview(
                            replacementPreview,
                            label: "Replacement"
                        )
                    }
                    imageObjectDetails(selectedObject)
                }

                if selectedObject.replacesMultipleUses {
                    Label(
                        "Used \(selectedObject.usageCount) times · all references will change",
                        systemImage: "square.stack.3d.up"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .fixedSize(horizontal: false, vertical: true)
                }

                PhotosPicker(
                    selection: $replacementItem,
                    matching: .images
                ) {
                    Label(
                        pickerTitle,
                        systemImage: pickerSymbol
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPQuietButtonStyle())
                .disabled(isLoadingPhoto || isSaving)
            }
        }
        .disabled(isSaving)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var imageCommitStatus: some View {
        HStack(spacing: PPSpacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(
                (
                    operationStopRequested
                        ? "Finishing current file commit"
                        : "Creating private copy"
                ).localizedUI
            )
            .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            OnDeviceBadge(compact: true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func imagePreview(
        _ image: UIImage?,
        label: String
    ) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(PPColor.textSecondary)
                }
            }
            .frame(width: 56, height: 48)
            .clipped()
            Text(label.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func imageObjectDetails(
        _ object: PDFImageObjectSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(object.pixelWidth) × \(object.pixelHeight)")
                .font(.caption.monospacedDigit())
            Text("Image \(object.resourceName)")
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
            Text(object.storage.detail.localizedUI)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(
                    object.storage == .flateWithSoftMask
                        ? PPColor.mint
                        : PPColor.textSecondary
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedObject: PDFImageObjectSnapshot? {
        objects.first { $0.id == selectedObjectID }
    }

    private var canCreate: Bool {
        pagePreview != nil
            && !isInspecting
            && !inspectionFailed
            && selectedObject?.isSafelyReplaceable == true
            && replacementData != nil
            && !isLoadingPhoto
    }

    private var hasDraftReplacement: Bool {
        replacementItem != nil || replacementData != nil
    }

    private func requestImageDismissal() {
        if hasDraftReplacement {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func loadImageDocument() async {
        guard let requestedRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else {
            isInspecting = false
            inspectionMessage = "The working copy is unavailable."
            inspectionFailed = true
            return
        }
        if sourceContentRevisionID == nil {
            sourceContentRevisionID = requestedRevisionID
        }
        guard sourceContentRevisionID == requestedRevisionID else {
            interruptProtectedImageEditing()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isInspecting = true
        inspectionMessage = nil
        inspectionFailed = false
        guard let url = model.url(for: recordID) else {
            isInspecting = false
            inspectionMessage = "The working copy is unavailable."
            inspectionFailed = true
            return
        }
        async let preview = PDFEditorPreviewLoader.shared.preview(
            url: url,
            pageIndex: pageIndex,
            revision: model.refreshToken(for: recordID)
        )
        do {
            let inspectedObjects = try await model.imageObjects(
                recordID: recordID,
                pageIndex: pageIndex
            )
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  model.record(id: recordID)?.contentRevisionID
                    == requestedRevisionID
            else { return }
            objects = inspectedObjects
            selectedObjectID = objects.first(
                where: \.isSafelyReplaceable
            )?.id
            if objects.isEmpty {
                inspectionMessage =
                    "No safely replaceable image object was found on this page."
            }
        } catch {
            guard !Task.isCancelled,
                  generation == loadGeneration
            else { return }
            inspectionMessage = AppLocalization
                .userFacingErrorDescription(error)
            inspectionFailed = true
        }
        let loadedPreview = await preview
        guard !Task.isCancelled,
              generation == loadGeneration,
              model.record(id: recordID)?.contentRevisionID
                == requestedRevisionID
        else { return }
        if let loadedPreview {
            pagePreview = loadedPreview.image
            pageAspectRatio = CGFloat(loadedPreview.aspectRatio)
        } else {
            inspectionMessage =
                "The page preview could not be loaded. Try again."
            inspectionFailed = true
        }
        didLoadDocument = true
        isInspecting = false
    }

    private func reloadImagePagePreview() async {
        loadGeneration += 1
        let generation = loadGeneration
        isInspecting = true
        inspectionFailed = false
        guard let url = model.url(for: recordID) else {
            inspectionMessage = "The working copy is unavailable."
            inspectionFailed = true
            isInspecting = false
            return
        }
        let loaded = await PDFEditorPreviewLoader.shared.preview(
            url: url,
            pageIndex: pageIndex,
            revision: model.refreshToken(for: recordID)
        )
        guard !Task.isCancelled,
              generation == loadGeneration
        else { return }
        guard let loaded else {
            inspectionMessage =
                "The page preview could not be loaded. Try again."
            inspectionFailed = true
            isInspecting = false
            return
        }
        pagePreview = loaded.image
        pageAspectRatio = CGFloat(loaded.aspectRatio)
        inspectionMessage = objects.isEmpty
            ? "No safely replaceable image object was found on this page."
            : nil
        isInspecting = false
    }

    private func retryImageInspection() {
        loadGeneration += 1
        originalPreviewGeneration += 1
        originalPreviewTask?.cancel()
        originalPreviewTask = nil
        objects.removeAll(keepingCapacity: false)
        selectedObjectID = nil
        pagePreview = nil
        originalPreview = nil
        inspectionMessage = nil
        inspectionFailed = false
        isInspecting = true
        didLoadDocument = false
        previewReloadToken = UUID()
    }

    private func imageInspectionFailure(
        _ message: String
    ) -> some View {
        VStack(spacing: PPSpacing.medium) {
            Label(
                message.localizedUI,
                systemImage: "photo.badge.exclamationmark"
            )
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            Button {
                retryImageInspection()
            } label: {
                Label(
                    "Inspect Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(PPQuietButtonStyle())
        }
        .padding(PPSpacing.regular)
    }

    private var imagePreviewLoadingState: some View {
        VStack(spacing: PPSpacing.small) {
            ProgressView()
            Text("Loading image preview".localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func createCopy() {
        guard canCreate,
              let selectedObject,
              let replacementData,
              let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID
        else { return }
        isSaving = true
        operationStopRequested = false
        let generation = UUID()
        operationGeneration = generation
        operationTask = Task {
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createImageReplacementCopy(
                    recordID: recordID,
                    snapshot: selectedObject,
                    replacementData: replacementData,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard operationGeneration == generation else { return }
            let wasStopped =
                operationStopRequested || Task.isCancelled
            isSaving = false
            operationTask = nil
            operationStopRequested = false
            guard !wasStopped else {
                model[noticeFor: paperPathSceneID] = created == nil
                    ? "Copy creation stopped".localizedUI
                    : "Copy finished before stopping · copy kept in Library"
                        .localizedUI
                return
            }
            guard let created else { return }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        photoLoadTask?.cancel()
        photoLoadGeneration += 1
        let generation = photoLoadGeneration
        isLoadingPhoto = true
        replacementData = nil
        replacementPreview = nil
        photoLoadTask = Task { @MainActor in
            defer {
                if generation == photoLoadGeneration {
                    isLoadingPhoto = false
                    photoLoadTask = nil
                    replacementItem = nil
                }
            }
            let transfer: ProtectedPhotoTransfer?
            do {
                transfer = try await item.loadTransferable(
                    type: ProtectedPhotoTransfer.self
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      generation == photoLoadGeneration,
                      scenePhase == .active,
                      UIApplication.shared.isProtectedDataAvailable
                else { return }
                if LocalFileSecurity.isInsufficientStorageError(error) {
                    model.present(
                        PaperPathError.insufficientStorage,
                        in: paperPathSceneID
                    )
                    return
                }
                model[noticeFor: paperPathSceneID] =
                    "The selected photo could not be opened".localizedUI
                return
            }
            guard !Task.isCancelled,
                  generation == photoLoadGeneration,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            guard let transfer else {
                model[noticeFor: paperPathSceneID] =
                    "The selected photo could not be opened".localizedUI
                return
            }
            defer { transfer.discard() }
            guard transfer.byteCount <= 32 * 1_024 * 1_024,
                  let prepared = await Self.preparePhoto(
                    transfer.fileURL
                  )
            else {
                guard generation == photoLoadGeneration else {
                    return
                }
                model[noticeFor: paperPathSceneID] =
                    "The selected photo could not be opened".localizedUI
                return
            }
            guard !Task.isCancelled,
                  generation == photoLoadGeneration,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            replacementData = prepared
            replacementPreview = UIImage(data: prepared)
        }
    }

    private func loadOriginalPreview() {
        originalPreviewTask?.cancel()
        originalPreviewGeneration += 1
        let generation = originalPreviewGeneration
        originalPreview = nil
        guard let data = selectedObject?.jpegData else { return }
        let selectedID = selectedObjectID
        originalPreviewTask = Task { @MainActor in
            defer {
                if originalPreviewGeneration == generation {
                    originalPreviewTask = nil
                }
            }
            let worker = Task.detached(priority: .utility) {
                autoreleasepool {
                    PDFPhotoPreparation.preparedData(
                        from: data,
                        maximumPixelSize: 320,
                        jpegQuality: 0.8
                    )
                }
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  generation == originalPreviewGeneration,
                  selectedObjectID == selectedID,
                  let prepared
            else { return }
            originalPreview = UIImage(data: prepared)
        }
    }

    private func fittedPageSize(in availableSize: CGSize) -> CGSize {
        let maximum = CGSize(
            width: max(1, availableSize.width - 32),
            height: max(1, availableSize.height - 24)
        )
        guard maximum.width / maximum.height > pageAspectRatio else {
            return CGSize(
                width: maximum.width,
                height: maximum.width / pageAspectRatio
            )
        }
        return CGSize(
            width: maximum.height * pageAspectRatio,
            height: maximum.height
        )
    }

    private func displayRect(
        _ bounds: PDFNormalizedRect,
        pageSize: CGSize
    ) -> CGRect {
        CGRect(
            x: bounds.x * pageSize.width,
            y: bounds.y * pageSize.height,
            width: bounds.width * pageSize.width,
            height: bounds.height * pageSize.height
        )
    }

    private static func preparePhoto(_ fileURL: URL) async -> Data? {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return autoreleasepool {
                PDFPhotoPreparation.preparedData(
                    from: fileURL,
                    maximumPixelSize: 2_400,
                    jpegQuality: 0.9
                )
            }
        }
        return try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func interruptProtectedImageWork() {
        loadGeneration += 1
        photoLoadGeneration += 1
        originalPreviewGeneration += 1
        photoLoadTask?.cancel()
        photoLoadTask = nil
        originalPreviewTask?.cancel()
        originalPreviewTask = nil
        stopReplacingImage(invalidateResult: true)
        replacementItem = nil
        isLoadingPhoto = false
        pagePreview = nil
        originalPreview = nil
        replacementPreview = nil
        replacementData = nil
    }

    private func interruptProtectedImageEditing() {
        interruptProtectedImageWork()
        objects.removeAll(keepingCapacity: false)
        selectedObjectID = nil
        inspectionMessage = nil
        isConfirmingSharedReplacement = false
        isConfirmingDiscard = false
        dismiss()
    }

    private func stopReplacingImage(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
        } else {
            guard operationTask != nil,
                  !operationStopRequested
            else { return }
            operationStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            isSaving = false
            operationStopRequested = false
        }
    }

}
