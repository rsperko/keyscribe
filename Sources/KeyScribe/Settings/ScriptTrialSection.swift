import SwiftUI
import KeyScribeKit

struct ScriptTrialSection: View {
    let script: VoiceCommandScript
    let blockedBy: String?
    let example: VoiceCommandExample?
    @Binding var sample: String
    @ObservedObject var trial: ScriptTrialModel
    @State private var detailsExpanded = false

    var body: some View {
        Section("Try it") {
            VStack(alignment: .leading, spacing: 8) {
                if script.takesText {
                    TextField("Sample words", text: $sample, prompt: Text(VoiceCommandExample.sampleWords))
                        .formFieldLabel("Sample words")
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptTrialSample)
                }
                if let example {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You say \u{201C}\(example.heard)\u{201D}")
                            .font(.caption).foregroundStyle(.secondary)
                        if let conflict = example.conflict {
                            if missingSample == nil { IssueText(conflict, severity: .advisory) }
                        } else {
                            Text(example.result)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(example.result)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptExample)
                }
                HStack {
                    Button("Run Once") { Task { await trial.run(script, sample: sample) } }
                        .disabled(blockedBy != nil || missingSample != nil || trial.isRunning)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptTrialRun)
                    if trial.isRunning { ProgressView().controlSize(.small) }
                }
                Text(caption).font(.caption).foregroundStyle(.secondary)
                if let missingSample { IssueText(missingSample, severity: .advisory) }
            }
            if let result = trial.result {
                outcome(result)
                    .id(AccessibilityID.Mode.VoiceCommands.scriptTrialResult)
                    .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptTrialResult)
                DisclosureSection(isExpanded: $detailsExpanded) {
                    DisclosureSummaryLabel(title: "Details", summary: "Exit status, output, and environment")
                } content: {
                    details(result)
                }
                .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptTrialDetails)
            }
        }
    }

    private var caption: String {
        let input = script.takesText ? " with these sample words" : ""
        return "Really runs this script\(input), with all its usual effects. Closing this editor does not stop it."
    }

    private var missingSample: String? { ScriptTrialModel.missingSample(script, sample: sample) }

    @ViewBuilder
    private func outcome(_ result: ScriptTrialModel.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result.outcome {
            case .done(let summary, _, let report):
                switch report?.level {
                case .info: IssueText(report?.text ?? summary, severity: .advisory)
                case .done: Label(report?.text ?? summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case nil: Label("Ran \(summary)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .started(let summary, _):
                Label("\(summary): \(HUDState.commandStillRunningDetail)", systemImage: "clock")
            case .failed(let message, _, _, _):
                IssueText(message)
            case .needsChoice(let pending):
                Text("Would ask \u{201C}\(pending.choice.title)\u{201D}. Pick one to run it again with that choice:")
                ForEach(pending.rows, id: \.identity) { row in
                    Button("\(row.number). \(row.name)") { Task { await trial.choose(row.identity) } }
                        .disabled(trial.isRunning)
                        .accessibilityIdentifier(AccessibilityID.Mode.VoiceCommands.scriptTrialChoice(row.number))
                }
            case .abandoned:
                Text("Stopped before it finished.").foregroundStyle(.secondary)
            }
            if result.finishedLate {
                Text("When spoken, \u{201C}\(HUDState.commandStillRunningDetail)\u{201D} shows first, and this result follows when the script ends.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func details(_ result: ScriptTrialModel.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Program", ScriptLauncher.expandedPath(result.script.program))
            field("Working folder", ScriptLauncher.workingDirectory.path)
            field("PATH", ScriptLauncher.searchPath ?? "Not set")
            field("Exit status", result.statusText)
            stream("Output", result.output.output)
            stream("Errors", result.output.errors)
        }
        .font(.caption)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func stream(_ title: String, _ captured: CappedOutput) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            if captured.data.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(captured.text).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            if captured.truncated {
                Text("Showing the first \(captured.limit / 1024) KB.").foregroundStyle(.secondary)
            }
        }
    }
}
