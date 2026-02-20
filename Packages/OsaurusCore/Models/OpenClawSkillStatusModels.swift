//
//  OpenClawSkillStatusModels.swift
//  osaurus
//

import Foundation

public struct OpenClawSkillStatusReport: Codable, Sendable {
    public let workspaceDir: String
    public let managedSkillsDir: String
    public let skills: [OpenClawSkillStatus]

    public init(workspaceDir: String, managedSkillsDir: String, skills: [OpenClawSkillStatus]) {
        self.workspaceDir = workspaceDir
        self.managedSkillsDir = managedSkillsDir
        self.skills = skills
    }
}

public struct OpenClawSkillStatus: Codable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let source: String
    public let filePath: String
    public let baseDir: String
    public let skillKey: String
    public let bundled: Bool
    public let primaryEnv: String?
    public let emoji: String?
    public let homepage: String?
    public let always: Bool
    public let disabled: Bool
    public let blockedByAllowlist: Bool
    public let eligible: Bool
    public let requirements: OpenClawSkillRequirementSet
    public let missing: OpenClawSkillRequirementSet
    public let configChecks: [OpenClawSkillConfigCheck]
    public let install: [OpenClawSkillInstallOption]

    public var id: String { skillKey }

    public init(
        name: String,
        description: String,
        source: String,
        filePath: String,
        baseDir: String,
        skillKey: String,
        bundled: Bool,
        primaryEnv: String?,
        emoji: String?,
        homepage: String?,
        always: Bool,
        disabled: Bool,
        blockedByAllowlist: Bool,
        eligible: Bool,
        requirements: OpenClawSkillRequirementSet,
        missing: OpenClawSkillRequirementSet,
        configChecks: [OpenClawSkillConfigCheck],
        install: [OpenClawSkillInstallOption]
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.filePath = filePath
        self.baseDir = baseDir
        self.skillKey = skillKey
        self.bundled = bundled
        self.primaryEnv = primaryEnv
        self.emoji = emoji
        self.homepage = homepage
        self.always = always
        self.disabled = disabled
        self.blockedByAllowlist = blockedByAllowlist
        self.eligible = eligible
        self.requirements = requirements
        self.missing = missing
        self.configChecks = configChecks
        self.install = install
    }

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case source
        case filePath
        case baseDir
        case skillKey
        case bundled
        case primaryEnv
        case emoji
        case homepage
        case always
        case disabled
        case blockedByAllowlist
        case eligible
        case requirements
        case missing
        case configChecks
        case install
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown Skill"
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        baseDir = try container.decodeIfPresent(String.self, forKey: .baseDir) ?? ""
        skillKey = try container.decodeIfPresent(String.self, forKey: .skillKey) ?? name
        bundled = try container.decodeIfPresent(Bool.self, forKey: .bundled) ?? false
        primaryEnv = try container.decodeIfPresent(String.self, forKey: .primaryEnv)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        always = try container.decodeIfPresent(Bool.self, forKey: .always) ?? false
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        blockedByAllowlist = try container.decodeIfPresent(Bool.self, forKey: .blockedByAllowlist) ?? false
        eligible = try container.decodeIfPresent(Bool.self, forKey: .eligible) ?? true
        requirements =
            try container.decodeIfPresent(OpenClawSkillRequirementSet.self, forKey: .requirements)
            ?? OpenClawSkillRequirementSet()
        missing =
            try container.decodeIfPresent(OpenClawSkillRequirementSet.self, forKey: .missing)
            ?? OpenClawSkillRequirementSet()
        configChecks = try container.decodeIfPresent([OpenClawSkillConfigCheck].self, forKey: .configChecks) ?? []
        install = try container.decodeIfPresent([OpenClawSkillInstallOption].self, forKey: .install) ?? []
    }

    public var hasMissingRequirements: Bool {
        !missing.bins.isEmpty || !missing.env.isEmpty || !missing.config.isEmpty || !missing.os.isEmpty
    }
}

public struct OpenClawSkillRequirementSet: Codable, Sendable {
    public let bins: [String]
    public let env: [String]
    public let config: [String]
    public let os: [String]

    public init(
        bins: [String] = [],
        env: [String] = [],
        config: [String] = [],
        os: [String] = []
    ) {
        self.bins = bins
        self.env = env
        self.config = config
        self.os = os
    }

    enum CodingKeys: String, CodingKey {
        case bins
        case env
        case config
        case os
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bins = try container.decodeIfPresent([String].self, forKey: .bins) ?? []
        env = try container.decodeIfPresent([String].self, forKey: .env) ?? []
        config = try container.decodeIfPresent([String].self, forKey: .config) ?? []
        os = try container.decodeIfPresent([String].self, forKey: .os) ?? []
    }
}

public struct OpenClawSkillConfigCheck: Codable, Sendable, Identifiable {
    public let path: String
    public let satisfied: Bool

    public var id: String { path }
}

public struct OpenClawSkillInstallOption: Codable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let label: String
    public let bins: [String]

    public init(id: String, kind: String, label: String, bins: [String]) {
        self.id = id
        self.kind = kind
        self.label = label
        self.bins = bins
    }
}

public struct OpenClawSkillBinsResponse: Codable, Sendable {
    public let bins: [String]
}

public struct OpenClawSkillInstallResult: Codable, Sendable {
    public let ok: Bool
    public let message: String?
    public let stdout: String?
    public let stderr: String?
    public let code: Int?
}

public struct OpenClawSkillUpdateResult: Codable, Sendable {
    public let ok: Bool
    public let skillKey: String
}
