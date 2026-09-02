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

enum DictationOverlayPresentation: Equatable, Sendable {
    case dictation(DictationState)
    case dictionaryLearning(DictionaryLearningEvent)

    var dictationState: DictationState? {
        guard case .dictation(let state) = self else { return nil }
        return state
    }

    var learningEvent: DictionaryLearningEvent? {
        guard case .dictionaryLearning(let event) = self else { return nil }
        return event
    }

    var isLearningNotice: Bool {
        learningEvent != nil
    }
}

struct DictationOverlayView: View {
    static let pillSize = CGSize(width: 260, height: 56)
    static let learningPillSize = CGSize(width: 320, height: 64)
    static let contentSize = pillSize

    let presentation: DictationOverlayPresentation
    var style: IndicatorStyle = .floatingPill
    var notchLayout: NotchOverlayLayout = .fallback

    init(
        presentation: DictationOverlayPresentation,
        style: IndicatorStyle = .floatingPill,
        notchLayout: NotchOverlayLayout = .fallback
    ) {
        self.presentation = presentation
        self.style = style
        self.notchLayout = notchLayout
    }

    init(
        state: DictationState,
        style: IndicatorStyle = .floatingPill,
        notchLayout: NotchOverlayLayout = .fallback
    ) {
        self.init(
            presentation: .dictation(state),
            style: style,
            notchLayout: notchLayout
        )
    }

    init(
        learningEvent: DictionaryLearningEvent,
        style: IndicatorStyle = .floatingPill,
        notchLayout: NotchOverlayLayout = .fallback
    ) {
        self.init(
            presentation: .dictionaryLearning(learningEvent),
            style: style,
            notchLayout: notchLayout
        )
    }

    var state: DictationState {
        presentation.dictationState ?? .idle
    }

    var learningEvent: DictionaryLearningEvent? {
        presentation.learningEvent
    }

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

    static func size(
        for presentation: DictationOverlayPresentation,
        style: IndicatorStyle,
        notchLayout: NotchOverlayLayout = .fallback
    ) -> CGSize {
        guard style == .floatingPill else { return notchLayout.size }
        return presentation.isLearningNotice ? learningPillSize : pillSize
    }

    private var currentSize: CGSize {
        Self.size(
            for: presentation,
            style: style,
            notchLayout: notchLayout
        )
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
            pillText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(
            width: currentSize.width,
            height: currentSize.height
        )
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14)))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pillText: some View {
        switch presentation {
        case .dictation(let state):
            Text(state.label)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 176, alignment: .leading)
        case .dictionaryLearning(let event):
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(event.detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 224, alignment: .leading)
        }
    }

    private var notch: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: notchLayout.topInset)
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                notchText
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
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var notchText: some View {
        switch presentation {
        case .dictation(let state):
            Text(state.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        case .dictionaryLearning(let event):
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(event.detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    private var color: Color {
        switch presentation {
        case .dictionaryLearning:
            .green
        case .dictation(let state):
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
    }

    private var symbol: String {
        switch presentation {
        case .dictionaryLearning:
            "text.book.closed.fill"
        case .dictation(let state):
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
}
