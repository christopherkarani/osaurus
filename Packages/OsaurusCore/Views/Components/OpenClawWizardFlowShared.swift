//
//  OpenClawWizardFlowShared.swift
//  osaurus
//

import OpenClawProtocol
import SwiftUI

@MainActor
final class OpenClawWizardStepFormState: ObservableObject {
    @Published var textValue = ""
    @Published var confirmValue = false
    @Published var selectedIndex = 0
    @Published var selectedIndices: Set<Int> = []

    func apply(step: OpenClawWizardStep, preferredSelectIndex: Int? = nil) {
        switch step.type {
        case .text:
            textValue = Self.stringValue(step.initialValue?.value) ?? ""

        case .confirm:
            confirmValue = Self.boolValue(step.initialValue?.value)

        case .select:
            if let preferredSelectIndex {
                selectedIndex = preferredSelectIndex
            } else {
                selectedIndex = indexForInitialValue(step)
            }

        case .multiselect:
            selectedIndices = indicesForInitialValues(step)

        default:
            break
        }
    }

    func answerValue(for step: OpenClawWizardStep) -> OpenClawProtocol.AnyCodable? {
        switch step.type {
        case .text:
            return OpenClawProtocol.AnyCodable(textValue)

        case .confirm:
            return OpenClawProtocol.AnyCodable(confirmValue)

        case .select:
            let options = step.options ?? []
            guard selectedIndex >= 0, selectedIndex < options.count else {
                return nil
            }
            return options[selectedIndex].value

        case .multiselect:
            let options = step.options ?? []
            let values = selectedIndices
                .sorted()
                .compactMap { index -> OpenClawProtocol.AnyCodable? in
                    guard index >= 0, index < options.count else { return nil }
                    return options[index].value
                }
            return OpenClawProtocol.AnyCodable(values)

        default:
            return OpenClawWizardFlowLogic.implicitAnswerValue(for: step.type)
        }
    }

    private func indexForInitialValue(_ step: OpenClawWizardStep) -> Int {
        guard let initial = step.initialValue else { return 0 }
        guard let options = step.options else { return 0 }
        return options.firstIndex(where: { option in
            Self.areEqual(option.value, initial)
        }) ?? 0
    }

    private func indicesForInitialValues(_ step: OpenClawWizardStep) -> Set<Int> {
        guard let options = step.options else { return [] }
        guard let initial = step.initialValue?.value as? [OpenClawProtocol.AnyCodable] else {
            return []
        }

        return Set(options.enumerated().compactMap { index, option in
            initial.contains(where: { Self.areEqual($0, option.value) }) ? index : nil
        })
    }

    static func boolValue(_ raw: Any?) -> Bool {
        if let raw = raw as? Bool {
            return raw
        }
        if let raw = raw as? String {
            return ["true", "1", "yes", "y"].contains(raw.lowercased())
        }
        if let raw = raw as? Int {
            return raw != 0
        }
        return false
    }

    static func stringValue(_ raw: Any?) -> String? {
        if let raw = raw as? String {
            return raw
        }
        return nil
    }

    static func areEqual(_ lhs: OpenClawProtocol.AnyCodable, _ rhs: OpenClawProtocol.AnyCodable) -> Bool {
        let encoder = JSONEncoder()
        guard
            let lhsData = try? encoder.encode(lhs),
            let rhsData = try? encoder.encode(rhs)
        else {
            return false
        }
        return lhsData == rhsData
    }
}

enum OpenClawWizardFlowLogic {
    static func primaryActionTitle(isComplete: Bool, stepType: OpenClawWizardStepType?) -> String {
        if isComplete {
            return "Done"
        }
        if stepType == .action {
            return "Run"
        }
        return "Continue"
    }

    static func isPrimaryActionBlocked(step: OpenClawWizardStep?) -> Bool {
        guard let step else { return true }
        switch step.type {
        case .select, .multiselect:
            return (step.options ?? []).isEmpty
        default:
            return false
        }
    }

    static func emptyOptionsMessage(for step: OpenClawWizardStep) -> String? {
        switch step.type {
        case .select, .multiselect:
            if (step.options ?? []).isEmpty {
                return "No options are available for this onboarding stage yet."
            }
            return nil
        default:
            return nil
        }
    }

    static func fallbackMessage(for step: OpenClawWizardStep) -> String? {
        let title = step.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = step.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasContext = !title.isEmpty || !message.isEmpty
        guard !hasContext else { return nil }

        switch step.type {
        case .note:
            return "Review this onboarding step, then continue."
        case .action:
            return "Run this onboarding action to continue."
        default:
            return nil
        }
    }

    static func implicitAnswerValue(for stepType: OpenClawWizardStepType) -> OpenClawProtocol.AnyCodable? {
        switch stepType {
        case .action:
            return OpenClawProtocol.AnyCodable(true)
        default:
            return nil
        }
    }
}

struct OpenClawWizardStepEditor: View {
    let step: OpenClawWizardStep
    @ObservedObject var formState: OpenClawWizardStepFormState

    @Environment(\.theme) private var theme

    var body: some View {
        switch step.type {
        case .note:
            if let message = OpenClawWizardFlowLogic.fallbackMessage(for: step) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .padding(.vertical, 2)
            }

        case .progress:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .tint(theme.accentColor)

        case .action:
            if let message = OpenClawWizardFlowLogic.fallbackMessage(for: step) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .padding(.vertical, 2)
            }

        case .text:
            if step.sensitive == true {
                SecureField(step.placeholder ?? "", text: $formState.textValue)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(step.placeholder ?? "", text: $formState.textValue)
                    .textFieldStyle(.roundedBorder)
            }

        case .confirm:
            Toggle("Confirm", isOn: $formState.confirmValue)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))

        case .select:
            if let message = OpenClawWizardFlowLogic.emptyOptionsMessage(for: step) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((step.options ?? []).enumerated()), id: \.offset) { index, option in
                        Button {
                            formState.selectedIndex = index
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: formState.selectedIndex == index ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(theme.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.primaryText)
                                    if let hint = option.hint, !hint.isEmpty {
                                        Text(hint)
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.secondaryText)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

        case .multiselect:
            if let message = OpenClawWizardFlowLogic.emptyOptionsMessage(for: step) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((step.options ?? []).enumerated()), id: \.offset) { index, option in
                        Button {
                            if formState.selectedIndices.contains(index) {
                                formState.selectedIndices.remove(index)
                            } else {
                                formState.selectedIndices.insert(index)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: formState.selectedIndices.contains(index) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(theme.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.primaryText)
                                    if let hint = option.hint, !hint.isEmpty {
                                        Text(hint)
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.secondaryText)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
    }
}
