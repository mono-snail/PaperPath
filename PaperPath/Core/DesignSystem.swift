import SwiftUI

enum AppBrand {
    static let name = "PaperPath"
    static let title = "PaperPath: Secure PDF Studio"
    static let subtitle = "Finish privately. Verify before sharing."
}

enum PPColor {
    static let canvas = Color(
        light: UIColor(red: 0.952, green: 0.961, blue: 0.968, alpha: 1),
        dark: UIColor(red: 0.048, green: 0.054, blue: 0.06, alpha: 1)
    )
    static let surface = Color(
        light: UIColor(red: 0.992, green: 0.995, blue: 0.997, alpha: 1),
        dark: UIColor(red: 0.082, green: 0.091, blue: 0.1, alpha: 1)
    )
    static let elevated = Color(
        light: UIColor(red: 0.922, green: 0.938, blue: 0.949, alpha: 1),
        dark: UIColor(red: 0.118, green: 0.13, blue: 0.142, alpha: 1)
    )
    static let surfaceMuted = Color(
        light: UIColor(red: 0.89, green: 0.91, blue: 0.924, alpha: 1),
        dark: UIColor(red: 0.064, green: 0.071, blue: 0.079, alpha: 1)
    )
    static let border = Color(
        light: UIColor(red: 0.7, green: 0.735, blue: 0.76, alpha: 1),
        dark: UIColor(red: 0.23, green: 0.245, blue: 0.26, alpha: 1)
    )
    static let textPrimary = Color(
        light: UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.948, blue: 0.956, alpha: 1)
    )
    static let textSecondary = Color(
        light: UIColor(red: 0.315, green: 0.34, blue: 0.365, alpha: 1),
        dark: UIColor(red: 0.66, green: 0.68, blue: 0.7, alpha: 1)
    )
    static let accent = Color(
        light: UIColor(red: 0.08, green: 0.28, blue: 0.5, alpha: 1),
        dark: UIColor(red: 0.31, green: 0.65, blue: 0.93, alpha: 1)
    )
    static let cyan = Color(
        light: UIColor(red: 0.08, green: 0.42, blue: 0.55, alpha: 1),
        dark: UIColor(red: 0.3, green: 0.72, blue: 0.8, alpha: 1)
    )
    static let mint = Color(
        light: UIColor(red: 0.12, green: 0.42, blue: 0.3, alpha: 1),
        dark: UIColor(red: 0.38, green: 0.78, blue: 0.58, alpha: 1)
    )
    static let amber = Color(
        light: UIColor(red: 0.68, green: 0.27, blue: 0.13, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.52, blue: 0.3, alpha: 1)
    )
    static let rose = Color(
        light: UIColor(red: 0.56, green: 0.16, blue: 0.25, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.43, blue: 0.55, alpha: 1)
    )
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

enum PPSpacing {
    static let hairline: CGFloat = 2
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 24
    static let section: CGFloat = 32
}

enum PPRadius {
    static let control: CGFloat = 7
    static let surface: CGFloat = 10
    static let document: CGFloat = 12
}

enum LocalFileSecurity {
    static func applyCompleteProtection(
        to url: URL,
        fileManager: FileManager = .default
    ) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    static func requireCompleteProtection(
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    static func prepareProtectedDirectory(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try requireCompleteProtection(
            to: url,
            fileManager: fileManager
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

struct PPCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    var body: some View {
        ZStack {
            PPColor.canvas

            StudioPaperGrid(
                lineOpacity: reduceTransparency
                    ? 0.045
                    : (colorScheme == .dark ? 0.075 : 0.11)
            )

            if !reduceTransparency {
                PaperGrain(
                    opacity: colorScheme == .dark ? 0.026 : 0.038
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct StudioPaperGrid: View {
    let lineOpacity: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            let baseline: CGFloat = 44
            var rules = Path()
            var y = baseline
            while y < size.height {
                rules.move(to: CGPoint(x: 0, y: y))
                rules.addLine(to: CGPoint(x: size.width, y: y))
                y += baseline
            }
            context.stroke(
                rules,
                with: .color(PPColor.border.opacity(lineOpacity)),
                lineWidth: 0.35
            )

            let marginX = min(max(size.width * 0.055, 20), 54)
            var margin = Path()
            margin.move(to: CGPoint(x: marginX, y: 0))
            margin.addLine(to: CGPoint(x: marginX, y: size.height))
            context.stroke(
                margin,
                with: .color(PPColor.rose.opacity(lineOpacity * 0.85)),
                lineWidth: 0.45
            )

            for point in [
                CGPoint(x: marginX, y: baseline),
                CGPoint(x: size.width - marginX, y: baseline)
            ] {
                let rect = CGRect(
                    x: point.x - 3,
                    y: point.y - 3,
                    width: 6,
                    height: 6
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(
                        PPColor.textSecondary.opacity(lineOpacity)
                    ),
                    lineWidth: 0.45
                )
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct PaperGrain: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            for index in 0..<32 {
                let seed = Double(index + 1)
                let x = CGFloat(
                    abs(sin(seed * 12.9898)) * Double(size.width)
                )
                let y = CGFloat(
                    abs(sin(seed * 78.233)) * Double(size.height)
                )
                let length = CGFloat(5 + Int(seed * 17) % 18)
                let angle = CGFloat(sin(seed * 4.13)) * 0.18
                var fiber = Path()
                fiber.move(to: CGPoint(x: x, y: y))
                fiber.addLine(
                    to: CGPoint(
                        x: x + cos(angle) * length,
                        y: y + sin(angle) * length
                    )
                )
                context.stroke(
                    fiber,
                    with: .color(PPColor.textPrimary.opacity(opacity)),
                    lineWidth: index.isMultiple(of: 5) ? 0.45 : 0.25
                )
            }
        }
        .blendMode(.softLight)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct PPCardModifier: ViewModifier {
    var padding: CGFloat = PPSpacing.regular
    var emphasized = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.surface,
                    bottomTrailingRadius: PPRadius.surface,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .fill(emphasized ? PPColor.elevated : PPColor.surface)
            }
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.surface,
                    bottomTrailingRadius: PPRadius.surface,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .stroke(
                        emphasized
                            ? PPColor.accent.opacity(0.28)
                            : PPColor.border.opacity(0.66),
                        lineWidth: 0.6
                    )
            }
            .shadow(
                color: emphasized ? .black.opacity(0.08) : .clear,
                radius: emphasized ? 6 : 0,
                y: emphasized ? 2 : 0
            )
    }
}

struct PPPaperSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = PPRadius.surface
    var shadow = true

    func body(content: Content) -> some View {
        content
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                .fill(PPColor.surface)
                .overlay {
                    PaperGrain(opacity: 0.018)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 2,
                                bottomLeadingRadius: cornerRadius,
                                bottomTrailingRadius: cornerRadius,
                                topTrailingRadius: 2,
                                style: .continuous
                            )
                        )
                }
            }
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: cornerRadius,
                    bottomTrailingRadius: cornerRadius,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                .stroke(PPColor.border.opacity(0.48), lineWidth: 0.55)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    Rectangle()
                        .fill(PPColor.accent.opacity(0.55))
                        .frame(width: 15, height: 1)
                    Circle()
                        .fill(PPColor.amber.opacity(0.72))
                        .frame(width: 3, height: 3)
                }
                .padding(.leading, 7)
                .padding(.top, 5)
            }
            .shadow(
                color: shadow ? .black.opacity(0.08) : .clear,
                radius: shadow ? 6 : 0,
                y: shadow ? 3 : 0
            )
    }
}

struct PPRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .onAppear {
                guard !visible else { return }
                if reduceMotion {
                    visible = true
                } else {
                    withAnimation(
                        .spring(response: 0.5, dampingFraction: 0.88)
                            .delay(delay)
                    ) {
                        visible = true
                    }
                }
            }
    }
}

extension View {
    func ppCard(
        padding: CGFloat = PPSpacing.regular,
        emphasized: Bool = false
    ) -> some View {
        modifier(PPCardModifier(padding: padding, emphasized: emphasized))
    }

    func ppReveal(delay: Double = 0) -> some View {
        modifier(PPRevealModifier(delay: delay))
    }

    func ppPaper(
        cornerRadius: CGFloat = PPRadius.surface,
        shadow: Bool = true
    ) -> some View {
        modifier(
            PPPaperSurfaceModifier(
                cornerRadius: cornerRadius,
                shadow: shadow
            )
        )
    }

    func ppCanvas() -> some View {
        background { PPCanvas() }
    }
}

struct PPPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(PPColor.accent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .stroke(.white.opacity(0.14), lineWidth: 0.6)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.985 : 1
            )
            .opacity(isEnabled ? 1 : 0.42)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
    }
}

struct PPQuietButtonStyle: ButtonStyle {
    var tint: Color = PPColor.textPrimary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, PPSpacing.regular)
            .frame(minHeight: 44)
            .background(
                PPColor.elevated.opacity(configuration.isPressed ? 0.72 : 1)
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: PPRadius.control,
                    bottomTrailingRadius: PPRadius.control,
                    topTrailingRadius: 2,
                    style: .continuous
                )
                    .stroke(PPColor.border.opacity(0.68), lineWidth: 0.6)
            }
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.98 : 1
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

struct OnDeviceBadge: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : PPSpacing.small) {
            Image(systemName: "iphone")
                .font(
                    compact
                        ? .caption2.weight(.bold)
                        : .caption.weight(.bold)
                )
                .foregroundStyle(PPColor.mint)
                .frame(
                    width: compact ? 18 : 27,
                    height: compact ? 18 : 27
                )
                .background(
                    Circle()
                        .fill(PPColor.mint.opacity(0.1))
                )
                .overlay {
                    Circle()
                        .stroke(
                            PPColor.mint.opacity(0.54),
                            lineWidth: 0.8
                        )
                }

            if compact {
                Text("ON DEVICE".localizedUI)
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(PPColor.mint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ON DEVICE".localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                    Text("Private workspace".localizedUI)
                        .font(.caption2)
                }
                .foregroundStyle(PPColor.textSecondary)
            }
        }
        .padding(.horizontal, compact ? 7 : 0)
        .padding(.vertical, compact ? 4 : 0)
        .background {
            if compact {
                Capsule()
                    .fill(PPColor.mint.opacity(0.09))
            }
        }
        .overlay {
            if compact {
                Capsule()
                    .stroke(PPColor.mint.opacity(0.38), lineWidth: 0.7)
            }
        }
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing stays on this device".localizedUI)
    }
}
