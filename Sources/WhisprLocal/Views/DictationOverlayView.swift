import SwiftUI

struct DictationOverlayView: View {
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
                    .symbolEffect(.pulse, isActive: state.isBusy)
            }
            Text(state.label)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .fixedSize()
    }

    private var color: Color {
        switch state {
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
