import AVFoundation
import SwiftUI

/// Compose tab: an 8-step beat sequencer whose tempo follows the runner,
/// plus hold-to-record to turn a whistle or tapping pattern into a new row.
struct ComposeView: View {
    @EnvironmentObject private var sequencer: StepSequencerEngine
    @EnvironmentObject private var tempo: TempoController
    @EnvironmentObject private var locationManager: LocationManager
    @StateObject private var recorder = SoundRecorder()

    @State private var instrument: Instrument = .drums
    @State private var pending: PendingRecording?
    @State private var isHolding = false
    @State private var analyzing = false
    @State private var message: String?

    private let accent = Color("AccentColor")

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [accent.opacity(0.35), .black, .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    TransportHeader()
                    Picker("Instrument", selection: $instrument) {
                        ForEach(Instrument.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    ScrollView {
                        VStack(spacing: 18) {
                            StepGridView(rows: sequencer.rows(in: .instrument(instrument)))
                            recordedSection
                        }
                        .padding(.bottom, 12)
                    }

                    recordBar
                }
                .padding(.horizontal)
            }
            .navigationTitle("Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear all pads", systemImage: "trash", role: .destructive) { sequencer.clearAll() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $pending) { recording in
            SuggestionSheet(recording: recording) { suggestion in
                addRow(from: recording, suggestion: suggestion)
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            // Switch to play-and-record ahead of time (if allowed) so the first
            // recording doesn't cause an audio route change mid-take.
            if AVAudioSession.sharedInstance().recordPermission == .granted {
                try? SoundRecorder.enableRecordingSession()
            }
        }
    }

    // MARK: - Recorded rows

    @ViewBuilder
    private var recordedSection: some View {
        let recorded = sequencer.rows(in: .recorded)
        VStack(alignment: .leading, spacing: 8) {
            Label("My sounds", systemImage: "waveform")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            if recorded.isEmpty {
                Text("Hold the mic button and whistle, hum, clap or tap a rhythm. It becomes a new row here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
            } else {
                StepGridView(rows: recorded)
            }
        }
    }

    // MARK: - Record bar

    private var recordBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recordTitle).font(.subheadline.bold())
                Text(recordSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: recorder.elapsed / SoundRecorder.maxDuration)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(recorder.isRecording ? Color.red : accent)
                    .padding(8)
                    .scaleEffect(recorder.isRecording ? 1 + CGFloat(recorder.level) * 0.15 : 1)
                if analyzing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        beginRecording()
                    }
                    .onEnded { _ in
                        isHolding = false
                        finishRecording()
                    }
            )
            .accessibilityLabel("Hold to record a sound")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
        .padding(.bottom, 8)
    }

    private var recordTitle: String {
        if recorder.isRecording { return String(format: "Recording… %.1fs", recorder.elapsed) }
        if analyzing { return "Listening to your sound…" }
        return "Hold to record"
    }

    private var recordSubtitle: String {
        if let message { return message }
        if recorder.isRecording {
            return sequencer.isPlaying && recorder.isUsingSpeaker
                ? "Tip: headphones keep the beat out of the mic."
                : "Release to finish (max \(Int(SoundRecorder.maxDuration))s)."
        }
        return sequencer.isPlaying
            ? "Play along with the beat — up to \(Int(SoundRecorder.maxDuration)) seconds."
            : "Whistle or tap up to \(Int(SoundRecorder.maxDuration)) seconds."
    }

    // MARK: - Recording flow

    private func beginRecording() {
        guard !recorder.isRecording, !analyzing else { return }
        message = nil
        recorder.requestPermission { granted in
            guard granted else {
                message = SoundRecorder.RecorderError.permissionDenied.errorDescription
                return
            }
            // Permission prompt may have taken the touch; only record while still held.
            guard isHolding else {
                message = "Microphone ready — hold the button to record."
                return
            }
            do {
                try recorder.start(onAutoStop: finishRecording)
                if sequencer.isPlaying && recorder.isUsingSpeaker { sequencer.setDucked(true) }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func finishRecording() {
        guard recorder.isRecording else { return }
        sequencer.setDucked(false)
        guard let recording = recorder.stop() else { return }

        // Grid position of the recording's first sample, captured now while the
        // tempo is known. nil → sequencer wasn't playing; align to the first hit.
        let startPosition = sequencer.stepPosition(atHostSeconds: recording.startHostSeconds)
        let stepDuration = StepGrid.stepDuration(bpm: sequencer.tempo)
        analyzing = true

        DispatchQueue.global(qos: .userInitiated).async {
            let analysis = SoundAnalyzer.analyze(samples: recording.samples, sampleRate: recording.sampleRate)
            DispatchQueue.main.async {
                analyzing = false
                guard let analysis, let firstHit = analysis.hits.first else {
                    message = "Didn't catch a clear sound. Try again a bit louder, closer to the mic."
                    return
                }
                let pattern = PatternBuilder.steps(for: analysis.hits) { time in
                    if let startPosition { return startPosition + time / stepDuration }
                    return (time - firstHit.time) / stepDuration
                }
                pending = PendingRecording(
                    analysis: analysis, steps: pattern.steps, notes: pattern.notes,
                    suggestions: PatternBuilder.suggestions(for: analysis, notes: pattern.notes))
            }
        }
    }

    private func addRow(from recording: PendingRecording, suggestion: SoundSuggestion) {
        let index = sequencer.rows(in: .recorded).count + 1
        sequencer.addRecordedRow(name: "\(suggestion.name) \(index)", symbol: suggestion.symbol,
                                 sound: suggestion.sound, steps: recording.steps, rates: suggestion.rates)
        pending = nil
        message = "Added to My sounds."
        if !sequencer.isPlaying { sequencer.play() }
    }
}

struct PendingRecording: Identifiable {
    let id = UUID()
    let analysis: SoundAnalysis
    let steps: [Bool]
    let notes: [Double?]
    let suggestions: [SoundSuggestion]
}

// MARK: - Header

private struct TransportHeader: View {
    @EnvironmentObject private var sequencer: StepSequencerEngine
    @EnvironmentObject private var tempo: TempoController
    @EnvironmentObject private var locationManager: LocationManager

    private let accent = Color("AccentColor")

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(tempo.currentTempo))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("BPM").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Base \(Int(tempo.baseTempo)) · \(locationManager.speedKilometersPerHour, specifier: "%.1f") km/h")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                smallButton("plus") { tempo.nudgeBaseTempo(by: 2) }
                smallButton("minus") { tempo.nudgeBaseTempo(by: -2) }
            }
            Spacer()
            transportButton(sequencer.isPlaying ? "pause.fill" : "play.fill", filled: true) {
                sequencer.togglePlayPause()
            }
            transportButton("stop.fill", filled: false) { sequencer.stop() }
                .disabled(sequencer.transport == .stopped)
                .opacity(sequencer.transport == .stopped ? 0.4 : 1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.bold())
                .frame(width: 30, height: 26)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
        }
        .tint(.white)
    }

    private func transportButton(_ symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.bold())
                .frame(width: 54, height: 54)
                .background(filled ? accent : Color.white.opacity(0.12))
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
    }
}

// MARK: - Grid

private struct StepGridView: View {
    @EnvironmentObject private var sequencer: StepSequencerEngine
    let rows: [SequencerRow]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    rowLabel(row)
                    HStack(spacing: 4) {
                        ForEach(0..<StepGrid.stepCount, id: \.self) { step in
                            pad(row: row, step: step)
                            // Small gap between the two halves of the bar.
                            if step == StepGrid.stepCount / 2 - 1 { Spacer().frame(width: 4) }
                        }
                    }
                }
            }
        }
    }

    private func rowLabel(_ row: SequencerRow) -> some View {
        Menu {
            Button("Clear row", systemImage: "eraser") { sequencer.clear(rowID: row.id) }
            Button("Preview sound", systemImage: "speaker.wave.2") { sequencer.preview(row.sound, rate: row.rates.first ?? 1) }
            if row.group == .recorded {
                Button("Delete row", systemImage: "trash", role: .destructive) { sequencer.remove(rowID: row.id) }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: row.symbol).font(.body)
                Text(row.name).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(row.color)
            .frame(width: 52, height: 40)
        }
    }

    private func pad(row: SequencerRow, step: Int) -> some View {
        let isOn = row.steps[step]
        let isPlayhead = sequencer.currentStep == step
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOn ? row.color : row.color.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(isPlayhead ? 0.9 : 0), lineWidth: 2)
            )
            .shadow(color: isOn && isPlayhead ? row.color : .clear, radius: 8)
            .brightness(isOn && isPlayhead ? 0.15 : 0)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { sequencer.toggle(rowID: row.id, step: step) }
            .accessibilityLabel("\(row.name) step \(step + 1)")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Suggestions

private struct SuggestionSheet: View {
    @EnvironmentObject private var sequencer: StepSequencerEngine
    @Environment(\.dismiss) private var dismiss
    let recording: PendingRecording
    let onPick: (SoundSuggestion) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(summary).font(.subheadline)
                        HStack(spacing: 4) {
                            ForEach(0..<StepGrid.stepCount, id: \.self) { step in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(recording.steps[step] ? Color("AccentColor") : Color.white.opacity(0.12))
                                    .frame(height: 22)
                                    .overlay(
                                        Text(recording.notes[step].map { PatternBuilder.noteName($0) } ?? "")
                                            .font(.system(size: 8, weight: .bold))
                                    )
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(recording.analysis.kind == .melody ? "Melody detected" : "Rhythm detected")
                }

                Section("Play it with") {
                    ForEach(recording.suggestions) { suggestion in
                        HStack(spacing: 12) {
                            Image(systemName: suggestion.symbol)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.1))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.name).font(.headline)
                                Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                let firstOn = recording.steps.firstIndex(of: true) ?? 0
                                sequencer.preview(suggestion.sound, rate: suggestion.rates[firstOn])
                            } label: {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderless)
                            Button("Add") { onPick(suggestion) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle("New sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var summary: String {
        let count = recording.steps.filter { $0 }.count
        switch recording.analysis.kind {
        case .rhythm: return "\(count) hit\(count == 1 ? "" : "s") on the beat grid. Pick a sound for this pattern:"
        case .melody: return "\(count) note\(count == 1 ? "" : "s") on the beat grid. Pick an instrument to play your melody:"
        }
    }
}
