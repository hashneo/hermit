import SwiftUI

// MARK: - hermit-bja: WaveformView

/// Animated amplitude bar chart visualising live mic input.
/// Driven by VoiceEngine.amplitude (0–1).
struct WaveformView: View {
    var amplitude: Float         // 0–1
    var barCount: Int = 20
    var color: Color = .accentColor

    @State private var bars: [Float] = []

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.85))
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.easeInOut(duration: 0.08), value: bars.isEmpty ? 0 : bars[safe: i] ?? 0)
            }
        }
        .frame(height: 48)
        .onChange(of: amplitude) { _, newVal in
            updateBars(amplitude: newVal)
        }
        .onAppear {
            bars = Array(repeating: 0, count: barCount)
        }
    }

    private func barHeight(index: Int) -> CGFloat {
        let val = bars.isEmpty ? 0 : (bars[safe: index] ?? 0)
        let base: CGFloat = 4
        let max: CGFloat  = 44
        return base + CGFloat(val) * (max - base)
    }

    private func updateBars(amplitude: Float) {
        guard !bars.isEmpty else { return }
        // Shift bars left and append new sample
        bars.removeFirst()
        // Add slight random variation for a natural-looking waveform
        let jitter = Float.random(in: -0.05...0.05)
        bars.append(min(max(amplitude + jitter, 0), 1))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// Preview available in Xcode canvas only.
// struct WaveformView_Preview: PreviewProvider { ... }
