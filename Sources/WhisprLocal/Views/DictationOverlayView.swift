import SwiftUI

struct NotchOverlayLayout: Equatable {
    static let fallback = NotchOverlayLayout(
        width: 220,
        topInset: 0,
        dropDownHeight: 44
    )

    let width: CGFloat
    let topInset: CGFloat
    let dropDownHeight: CGFloat

    init(
        width: CGFloat,
        topInset: CGFloat,
        dropDownHeight: CGFloat = 38
    ) {
        self.width = max(180, width)
        self.topInset = max(0, topInset)
        self.dropDownHeight = max(32, dropDownHeight)
    }

    var size: CGSize {
        CGSize(width: width, height: topInset + dropDownHeight)
    }
}

struct DictationOverlayView: View {
    static let pillSize = CGSize(width: 260, height: 56)
    static let contentSize = pillSize

    let state: DictationState
    var style: IndicatorStyle = .floatingPill
    var notchLayout: NotchOverlayLayout = .fallback

    var body: some View {
        Group {
            switch style {
            case .floatingPill:
                pill
            case .notch:
                notch
            }
        }
        .frame(width: currentSize.width, height: currentSize.height)
    }

    static func size(
        for style: IndicatorStyle,
        notchLayout: NotchOverlayLayout = .fallback
    ) -> CGSize {
        style == .notch ? notchLayout.size : pillSize
    }

    private var currentSize: CGSize {
        Self.size(for: style, notchLayout: notchLayout)
    }

    private var pill: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
            Text(state.label)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 176, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(
            width: Self.pillSize.width,
            height: Self.pillSize.height
        )
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14)))
        .clipShape(Capsule())
    }

    private var notch: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: notchLayout.topInset)
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Text(state.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: notchLayout.dropDownHeight)
        }
        .frame(width: notchLayout.width, height: notchLayout.size.height)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 16
            )
            .fill(.black)
        )
    }

    private var color: Color {
        switch state {
        case .preparing: .yellow
        case .listening: .red
        case .transcribing, .correcting, .pasting: .blue
        case .succeeded: .green
        case .failed: .orange
        case .cancelled: .secondary
        case .idle: .secondary
        }
    }

    private var symbol: String {
        switch state {
        case .preparing: "mic.badge.plus"
        case .listening: "waveform"
        case .transcribing: "text.bubble"
        case .correcting: "wand.and.stars"
        case .pasting: "doc.on.clipboard"
        case .succeeded: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        case .idle: "mic"
        }
    }
}
