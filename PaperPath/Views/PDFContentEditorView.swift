import PDFKit
import PhotosUI
import SwiftUI

struct PDFContentEditorView: View {
    private enum ContentKind: String, CaseIterable, Identifiable {
        case text
        case photo
        case link

        var id: String { rawValue }

        var title: String {
            rawValue.capitalized
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
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var bounds = PDFNormalizedRect(
        x: 0.19,
        y: 0.72,
        width: 0.62,
        height: 0.16
    )
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var operationTask: Task<Void, Never>?
    @State private var photoLoadGeneration = 0
    @GestureState private var translation = CGSize.zero
    @GestureState private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if model.url(for: recordID) != nil {
                    editorSurface(availableSize: proxy.size)
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
                    Button((isSaving ? "Stop" : "Cancel").localizedUI) {
                        if isSaving {
                            operationTask?.cancel()
                            operationTask = nil
                            isSaving = false
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Copy") {
                        createCopy()
                    }
                    .disabled(!canCreate || isSaving)
                }
            }
            .task {
                guard let url = model.url(for: recordID) else { return }
                let preview = await PDFEditorPreviewLoader.shared.preview(
                    url: url,
                    pageIndex: pageIndex,
                    revision: model.refreshToken(for: recordID)
                )
                guard !Task.isCancelled, let preview else { return }
                pageAspectRatio = CGFloat(preview.aspectRatio)
                pagePreview = preview.image
            }
            .onChange(of: kind) { _, newKind in
                bounds = defaultBounds(for: newKind)
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                loadPhoto(item)
            }
            .interactiveDismissDisabled(isSaving)
            .onDisappear {
                operationTask?.cancel()
                operationTask = nil
                photoLoadGeneration += 1
            }
        }
    }

    private var precisionContextBar: some View {
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
            Spacer(minLength: 0)
            OnDeviceBadge(compact: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, PPSpacing.regular)
        .frame(minHeight: 38)
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
                } else {
                    ProgressView()
                }

                contentOverlay(pageSize: pageSize)
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
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
        .accessibilityLabel("\(kind.title) placement")
        .accessibilityHint("Drag to move or pinch to resize")
    }

    private var controls: some View {
        VStack(spacing: PPSpacing.small) {
            Picker("Content type", selection: $kind) {
                ForEach(ContentKind.allCases) { item in
                    Label(
                        item.title.localizedUI,
                        systemImage: item.symbol
                    )
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)

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
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var textControls: some View {
        VStack(spacing: PPSpacing.small) {
            TextField("Text", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)

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
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(color.rawValue) text")
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
            TextField("https://", text: $linkAddress)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
    }

    private var canCreate: Bool {
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
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private var previewFontSize: CGFloat {
        min(max(CGFloat(fontSize) * 0.72, 10), 30)
    }

    private func createCopy() {
        guard canCreate else { return }
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
        operationTask = Task {
            let created = await model.createEditedCopy(
                recordID: recordID,
                overlays: [overlay]
            )
            guard !Task.isCancelled else {
                isSaving = false
                operationTask = nil
                return
            }
            isSaving = false
            operationTask = nil
            guard let created else { return }
            dismiss()
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        photoLoadGeneration += 1
        let generation = photoLoadGeneration
        isLoadingPhoto = true
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let prepared = await Self.preparePhoto(data)
            else {
                guard generation == photoLoadGeneration else {
                    return
                }
                isLoadingPhoto = false
                model.noticeMessage = "The selected photo could not be opened"
                return
            }
            guard !Task.isCancelled,
                  generation == photoLoadGeneration
            else { return }
            photoData = prepared
            photoPreview = UIImage(data: prepared)
            isLoadingPhoto = false
        }
    }

    private static func preparePhoto(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let longestEdge = max(image.size.width, image.size.height)
            let scale = min(1, 1_800 / max(1, longestEdge))
            let size = CGSize(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let normalized = UIGraphicsImageRenderer(
                size: size,
                format: format
            ).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            return normalized.jpegData(compressionQuality: 0.86)
        }.value
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
    @State private var loadGeneration = 0
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
                    Button((isSaving ? "Stop" : "Cancel").localizedUI) {
                        if isSaving {
                            operationTask?.cancel()
                            operationTask = nil
                            isSaving = false
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Copy") {
                        createUpdatedCopy()
                    }
                    .disabled(!canCreate || isSaving)
                    .accessibilityIdentifier("createLinkEditedCopy")
                }
            }
            .task {
                await loadDocument()
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
            .interactiveDismissDisabled(isSaving)
            .sensoryFeedback(.selection, trigger: selectionFeedback)
            .onDisappear {
                operationTask?.cancel()
                operationTask = nil
                loadGeneration += 1
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
                } else {
                    ProgressView()
                }
                linkOverlays(pageSize: pageSize)
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
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedLinkID = link.id
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
            "\(link.title), \(link.target.title)"
        )
        .accessibilityHint(
            link.target.isEditable
                ? "Select, then drag to move or pinch to resize"
                : "This link action can be removed but not edited"
        )
        .accessibilityAddTraits(
            isSelected ? .isSelected : []
        )
        .accessibilityIdentifier(
            "existingLink-\(link.pageIndex)-\(link.annotationIndex)"
        )
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            if isLoading {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting links in this document")
                        .font(.subheadline.weight(.semibold))
                }
            } else if allLinks.isEmpty {
                Label(
                    loadMessage ?? "No links in this document",
                    systemImage: "link.badge.plus"
                )
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("noExistingLinks")
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
                        .disabled(isSaving)
                        .accessibilityIdentifier("removeExistingLink")

                        Spacer()

                        Text("Page \(activePageIndex + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
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
                        switchToPage(candidatePageIndex)
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
                    Text("Page \(activePageIndex + 1)")
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("Page with links")
            .accessibilityValue("Page \(activePageIndex + 1)")
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
                        selectedLinkID = option.id
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
                .accessibilityIdentifier("existingLinkLabel")

            Picker("Link target", selection: $targetKind) {
                ForEach(TargetKind.allCases) { kind in
                    Label(
                        kind.title.localizedUI,
                        systemImage: kind.symbol
                    )
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("existingLinkTarget")

            PrecisionPlacementRail(
                bounds: $bounds,
                tint: PPColor.mint,
                title: "Link"
            )

            switch targetKind {
            case .web:
                TextField("https://", text: $webAddress)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("existingLinkAddress")
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
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private var canCreate: Bool {
        guard !isLoading,
              selectedLink?.target.isEditable == true,
              !linkTitle.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              draftTarget != nil
        else { return false }
        return true
    }

    private func loadDocument() async {
        loadGeneration += 1
        let generation = loadGeneration
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
                  generation == loadGeneration
            else { return }
            allLinks = loadedLinks
            if !allLinks.contains(where: {
                $0.pageIndex == activePageIndex
            }), let nearestPage = linkPages.min(by: {
                abs($0 - activePageIndex) < abs($1 - activePageIndex)
            }) {
                activePageIndex = nearestPage
            }
        } catch {
            loadMessage = error.localizedDescription
        }
        await loadActivePage(url: url, generation: generation)
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
        guard !Task.isCancelled,
              generation == loadGeneration,
              let loadedPreview = await preview,
              requestedPageIndex == activePageIndex
        else { return }
        pagePreview = loadedPreview.image
        pageAspectRatio = CGFloat(loadedPreview.aspectRatio)
        isLoading = false
    }

    private func switchToPage(_ requestedPageIndex: Int) {
        guard requestedPageIndex != activePageIndex,
              linkPages.contains(requestedPageIndex),
              let url = model.url(for: recordID)
        else { return }
        activePageIndex = requestedPageIndex
        loadGeneration += 1
        let generation = loadGeneration
        selectedLinkID = nil
        pagePreview = nil
        isLoading = true
        Task {
            await loadActivePage(
                url: url,
                generation: generation
            )
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
        guard let selectedLink,
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
        guard let selectedLink else { return }
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
        isSaving = true
        operationTask = Task {
            let created = await model.createLinkEditedCopy(
                recordID: recordID,
                mutation: mutation
            )
            guard !Task.isCancelled else {
                isSaving = false
                operationTask = nil
                return
            }
            isSaving = false
            operationTask = nil
            guard let created else { return }
            dismiss()
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

    let recordID: UUID
    let pageIndex: Int
    let onCreated: (DocumentRoute) -> Void

    @State private var objects: [PDFImageObjectSnapshot] = []
    @State private var selectedObjectID: String?
    @State private var replacementItem: PhotosPickerItem?
    @State private var replacementData: Data?
    @State private var replacementPreview: UIImage?
    @State private var pagePreview: UIImage?
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var isInspecting = true
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var inspectionMessage: String?
    @State private var isConfirmingSharedReplacement = false
    @State private var operationTask: Task<Void, Never>?
    @State private var loadGeneration = 0
    @State private var photoLoadGeneration = 0

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
                    Button((isSaving ? "Stop" : "Cancel").localizedUI) {
                        if isSaving {
                            operationTask?.cancel()
                            operationTask = nil
                            isSaving = false
                        } else {
                            dismiss()
                        }
                    }
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
                }
            }
            .task {
                loadGeneration += 1
                let generation = loadGeneration
                guard let url = model.url(for: recordID) else { return }
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
                          generation == loadGeneration
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
                    guard generation == loadGeneration else { return }
                    inspectionMessage = error.localizedDescription
                }
                if let loadedPreview = await preview,
                   !Task.isCancelled,
                   generation == loadGeneration {
                    pagePreview = loadedPreview.image
                    pageAspectRatio = CGFloat(
                        loadedPreview.aspectRatio
                    )
                }
                isInspecting = false
            }
            .onChange(of: replacementItem) { _, item in
                guard let item else { return }
                loadPhoto(item)
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
            .interactiveDismissDisabled(isSaving)
            .onDisappear {
                operationTask?.cancel()
                operationTask = nil
                loadGeneration += 1
                photoLoadGeneration += 1
            }
        }
    }

    private var replacementContextBar: some View {
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
            Spacer(minLength: 0)
            OnDeviceBadge(compact: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, PPSpacing.regular)
        .frame(minHeight: 38)
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
                } else {
                    ProgressView()
                }
                objectOverlays(pageSize: pageSize)
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
            }
            .buttonStyle(.plain)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityLabel(
                object.replacesMultipleUses
                    ? "Shared image used \(object.usageCount) times"
                    : "Replaceable image \(object.pixelWidth) by \(object.pixelHeight) pixels"
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
                .lineLimit(1)
            }

            if let selectedObject {
                HStack(spacing: PPSpacing.regular) {
                    imagePreview(
                        UIImage(data: selectedObject.jpegData),
                        label: "Original"
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(PPColor.textSecondary)
                    imagePreview(
                        replacementPreview,
                        label: "Replacement"
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "\(selectedObject.pixelWidth) × \(selectedObject.pixelHeight)"
                        )
                        .font(.caption.monospacedDigit())
                        Text("Image \(selectedObject.resourceName)")
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                        Text(selectedObject.storage.detail.localizedUI)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(
                                selectedObject.storage
                                    == .flateWithSoftMask
                                    ? PPColor.mint
                                    : PPColor.textSecondary
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
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

    private var selectedObject: PDFImageObjectSnapshot? {
        objects.first { $0.id == selectedObjectID }
    }

    private var canCreate: Bool {
        selectedObject?.isSafelyReplaceable == true
            && replacementData != nil
            && !isLoadingPhoto
    }

    private func createCopy() {
        guard let selectedObject,
              let replacementData
        else { return }
        isSaving = true
        operationTask = Task {
            let created = await model.createImageReplacementCopy(
                recordID: recordID,
                snapshot: selectedObject,
                replacementData: replacementData
            )
            guard !Task.isCancelled else {
                isSaving = false
                operationTask = nil
                return
            }
            isSaving = false
            operationTask = nil
            guard let created else { return }
            dismiss()
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        photoLoadGeneration += 1
        let generation = photoLoadGeneration
        isLoadingPhoto = true
        Task {
            guard let data = try? await item.loadTransferable(
                type: Data.self
            ),
                  let prepared = await Self.preparePhoto(data)
            else {
                guard generation == photoLoadGeneration else {
                    return
                }
                isLoadingPhoto = false
                model.noticeMessage =
                    "The selected photo could not be opened"
                return
            }
            guard !Task.isCancelled,
                  generation == photoLoadGeneration
            else { return }
            replacementData = prepared
            replacementPreview = UIImage(data: prepared)
            isLoadingPhoto = false
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

    private static func preparePhoto(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let longestEdge = max(image.size.width, image.size.height)
            let scale = min(1, 2_400 / max(1, longestEdge))
            let size = CGSize(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let preservesAlpha: Bool
            if let cgImage = image.cgImage {
                preservesAlpha = switch cgImage.alphaInfo {
                case .first, .last, .premultipliedFirst,
                     .premultipliedLast, .alphaOnly:
                    true
                case .none, .noneSkipFirst, .noneSkipLast:
                    false
                @unknown default:
                    false
                }
            } else {
                preservesAlpha = false
            }
            format.opaque = !preservesAlpha
            let normalized = UIGraphicsImageRenderer(
                size: size,
                format: format
            ).image { context in
                if !preservesAlpha {
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            return preservesAlpha
                ? normalized.pngData()
                : normalized.jpegData(compressionQuality: 0.9)
        }.value
    }

}
