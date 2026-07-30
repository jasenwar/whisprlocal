import SwiftUI

struct DictationOverlayView: View {
    static let contentSize = CGSize(width: 260, height: 56)

    let state: DictationState

    var body: some View {
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
            width: Self.contentSize.width,
            height: Self.contentSize.height
        )
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
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
