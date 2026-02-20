//
//  OpenClawWizardModels.swift
//  osaurus
//

import Foundation
import OpenClawProtocol

public enum OpenClawWizardRunStatus: String, Codable, Sendable {
    case running
    case done
    case cancelled
    case error
}

public enum OpenClawWizardStepType: String, Codable, Sendable {
    case note
    case select
    case text
    case confirm
    case multiselect
    case progress
    case action
}

public struct OpenClawWizardStepOption: Codable, Sendable, Identifiable {
    public let value: OpenClawProtocol.AnyCodable
    public let label: String
    public let hint: String?

    public var id: String {
        if let hint, !hint.isEmpty {
            return "\(label)::\(hint)"
        }
        return label
    }

    public init(value: OpenClawProtocol.AnyCodable, label: String, hint: String?) {
        self.value = value
        self.label = label
        self.hint = hint
    }
}

public struct OpenClawWizardStep: Codable, Sendable {
    public let id: String
    public let type: OpenClawWizardStepType
    public let title: String?
    public let message: String?
    public let options: [OpenClawWizardStepOption]?
    public let initialValue: OpenClawProtocol.AnyCodable?
    public let placeholder: String?
    public let sensitive: Bool?
}

public struct OpenClawWizardStartResult: Codable, Sendable {
    public let sessionId: String
    public let done: Bool
    public let step: OpenClawWizardStep?
    public let status: OpenClawWizardRunStatus?
    public let error: String?
}

public struct OpenClawWizardNextResult: Codable, Sendable {
    public let done: Bool
    public let step: OpenClawWizardStep?
    public let status: OpenClawWizardRunStatus?
    public let error: String?
}

public struct OpenClawWizardStatusResult: Codable, Sendable {
    public let status: OpenClawWizardRunStatus
    public let error: String?
}
