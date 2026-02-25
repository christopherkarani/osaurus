//
//  OpenClawSessionManager.swift
//  osaurus
//

import Foundation
import OpenClawProtocol

extension Notification.Name {
    static let openClawSessionsChanged = Notification.Name("openClawSessionsChanged")
}

@MainActor
public final class OpenClawSessionManager: ObservableObject {
    public struct GatewaySession: Identifiable, Sendable, Equatable {
        public let id: String
        public let key: String
        public let title: String?
        public let lastMessage: String?
        public let lastActiveAt: Date?
        public let model: String?
        public let contextTokens: Int?

        public init(
            key: String,
            title: String?,
            lastMessage: String?,
            lastActiveAt: Date?,
            model: String?,
            contextTokens: Int?
        ) {
            self.id = key
            self.key = key
            self.title = title
            self.lastMessage = lastMessage
            self.lastActiveAt = lastActiveAt
            self.model = model
            self.contextTokens = contextTokens
        }
    }

    public static let shared = OpenClawSessionManager()

    @Published public private(set) var sessions: [GatewaySession] = []
    @Published public private(set) var activeSessionKey: String?

    private let connection: OpenClawGatewayConnection
    private static let allowlistRecoveryPatchRetryAttempts = 3

    public init(connection: OpenClawGatewayConnection = .shared) {
        self.connection = connection
    }

    public func loadSessions(
        limit: Int? = 50,
        includeGlobal: Bool = false,
        includeUnknown: Bool = false
    ) async throws {
        let payload = try await connection.sessionsList(
            limit: limit,
            includeTitles: true,
            includeLastMessage: true,
            includeGlobal: includeGlobal,
            includeUnknown: includeUnknown
        )

        sessions = payload
            .map { item in
                GatewaySession(
                    key: item.key,
                    title: preferredTitle(for: item),
                    lastMessage: item.lastMessagePreview,
                    lastActiveAt: parseGatewayTimestamp(item.updatedAt),
                    model: item.model,
                    contextTokens: item.contextTokens
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastActiveAt ?? .distantPast
                let rhsDate = rhs.lastActiveAt ?? .distantPast
                return lhsDate > rhsDate
            }

        if let activeSessionKey,
            sessions.contains(where: { $0.key == activeSessionKey }) == false
        {
            self.activeSessionKey = nil
        }
        postSessionsChanged()
    }

    public func createSession(model: String?) async throws -> String {
        await migrateLegacyKimiCodingProviderEndpointIfNeeded()

        let requestedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedModel = await qualifyKnownKimiModelReferenceIfNeeded(requestedModel)
        await emitSessionDiagnostic(
            level: .debug,
            event: "session.create.begin",
            context: [
                "requestedModel": requestedModel.isEmpty ? "<none>" : requestedModel,
                "resolvedModel": resolvedModel?.isEmpty == false ? resolvedModel! : "<none>"
            ]
        )

        do {
            let key = try await createAndLoadSession(model: resolvedModel)
            await emitSessionDiagnostic(
                level: .info,
                event: "session.create.success",
                context: [
                    "requestedModel": requestedModel.isEmpty ? "<none>" : requestedModel,
                    "resolvedModel": resolvedModel?.isEmpty == false ? resolvedModel! : "<none>",
                    "sessionKey": key,
                ]
            )
            return key
        } catch {
            if shouldAttemptAllowlistRecovery(for: error, requestedModel: requestedModel) {
                do {
                    let recovered = try await recoverAllowlistModelIfNeeded(requestedModel: requestedModel)
                    if recovered {
                        let key = try await createAndLoadSession(model: resolvedModel)
                        await emitSessionDiagnostic(
                            level: .info,
                            event: "session.create.successAfterAllowlistRecovery",
                            context: [
                                "requestedModel": requestedModel,
                                "resolvedModel": resolvedModel?.isEmpty == false ? resolvedModel! : "<none>",
                                "sessionKey": key,
                            ]
                        )
                        return key
                    }
                } catch {
                    await emitSessionDiagnostic(
                        level: .warning,
                        event: "session.create.allowlistRecovery.failed",
                        context: [
                            "requestedModel": requestedModel,
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }
            await emitSessionDiagnostic(
                level: .error,
                event: "session.create.failed",
                context: [
                    "requestedModel": requestedModel.isEmpty ? "<none>" : requestedModel,
                    "error": error.localizedDescription,
                ]
            )
            throw error
        }
    }

    public func deleteSession(key: String) async throws {
        try await connection.sessionsDelete(key: key)
        sessions.removeAll { $0.key == key }
        if activeSessionKey == key {
            activeSessionKey = nil
        }
        postSessionsChanged()
    }

    public func resetSession(key: String) async throws {
        try await connection.sessionsReset(key: key, reason: "new")
    }

    public func patchSession(
        key: String,
        sendPolicy: String? = nil,
        model: String? = nil
    ) async throws {
        var params: [String: OpenClawProtocol.AnyCodable] = [:]
        if let sendPolicy, !sendPolicy.isEmpty {
            params["sendPolicy"] = OpenClawProtocol.AnyCodable(sendPolicy)
        }
        if let model, !model.isEmpty {
            params["model"] = OpenClawProtocol.AnyCodable(model)
        }
        try await connection.sessionsPatch(key: key, params: params)
    }

    public func compactSession(key: String, maxLines: Int? = nil) async throws {
        try await connection.sessionsCompact(key: key, maxLines: maxLines)
    }

    public func setActiveSessionKey(_ key: String?) {
        activeSessionKey = key
    }

    private func postSessionsChanged() {
        NotificationCenter.default.post(name: .openClawSessionsChanged, object: nil)
    }

    private func preferredTitle(for item: OpenClawSessionListItem) -> String? {
        if let displayName = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !displayName.isEmpty
        {
            return displayName
        }
        if let derivedTitle = item.derivedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !derivedTitle.isEmpty
        {
            return derivedTitle
        }
        return nil
    }

    private func parseGatewayTimestamp(_ value: Double?) -> Date? {
        guard let value else { return nil }
        if value > 9_999_999_999 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return Date(timeIntervalSince1970: value)
    }

    private func createAndLoadSession(model: String?) async throws -> String {
        let key = try await connection.sessionsCreate(model: model)
        activeSessionKey = key
        try await loadSessions()
        return key
    }

    private func shouldAttemptAllowlistRecovery(for error: Error, requestedModel: String) -> Bool {
        guard !requestedModel.isEmpty, requestedModel.contains("/") else {
            return false
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("model not allowed")
            && message.contains("sessions.patch")
    }

    private func recoverAllowlistModelIfNeeded(requestedModel: String) async throws -> Bool {
        let normalizedModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty, normalizedModel.contains("/") else {
            return false
        }

        await emitSessionDiagnostic(
            level: .debug,
            event: "session.create.allowlistRecovery.begin",
            context: ["requestedModel": normalizedModel]
        )

        var lastError: Error?
        for attempt in 1...Self.allowlistRecoveryPatchRetryAttempts {
            do {
                let configResult = try await connection.configGetFull()
                guard let baseHash = configResult.baseHash else {
                    await emitSessionDiagnostic(
                        level: .warning,
                        event: "session.create.allowlistRecovery.skipped",
                        context: [
                            "requestedModel": normalizedModel,
                            "reason": "missingBaseHash",
                        ]
                    )
                    return false
                }

                let allowlistKeys = Self.allowlistModelKeys(from: configResult.config)
                guard !allowlistKeys.isEmpty else {
                    await emitSessionDiagnostic(
                        level: .debug,
                        event: "session.create.allowlistRecovery.skipped",
                        context: [
                            "requestedModel": normalizedModel,
                            "reason": "allowlistInactive",
                        ]
                    )
                    return false
                }

                let normalizedAllowlistKeys = Set(
                    allowlistKeys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                )
                let targetKey = normalizedModel.lowercased()
                guard !normalizedAllowlistKeys.contains(targetKey) else {
                    await emitSessionDiagnostic(
                        level: .debug,
                        event: "session.create.allowlistRecovery.skipped",
                        context: [
                            "requestedModel": normalizedModel,
                            "reason": "alreadyAllowlisted",
                        ]
                    )
                    return false
                }

                let patch: [String: Any] = [
                    "agents": [
                        "defaults": [
                            "models": [
                                normalizedModel: [:]
                            ]
                        ]
                    ]
                ]
                let patchData = try JSONSerialization.data(withJSONObject: patch)
                let patchJSON = String(data: patchData, encoding: .utf8) ?? "{}"
                _ = try await connection.configPatch(raw: patchJSON, baseHash: baseHash)

                await emitSessionDiagnostic(
                    level: .info,
                    event: "session.create.allowlistRecovery.patched",
                    context: [
                        "requestedModel": normalizedModel,
                        "attempt": "\(attempt)",
                    ]
                )
                return true
            } catch {
                lastError = error
                guard attempt < Self.allowlistRecoveryPatchRetryAttempts,
                    Self.isStaleBaseHashError(error)
                else {
                    throw error
                }
            }
        }

        if let lastError {
            throw lastError
        }
        return false
    }

    private static func allowlistModelKeys(from config: [String: OpenClawProtocol.AnyCodable]?) -> [String] {
        guard let config,
            let agents = config["agents"]?.value as? [String: OpenClawProtocol.AnyCodable],
            let defaults = agents["defaults"]?.value as? [String: OpenClawProtocol.AnyCodable],
            let models = defaults["models"]?.value as? [String: OpenClawProtocol.AnyCodable]
        else {
            return []
        }
        return models.keys.map { $0 }
    }

    private static func isStaleBaseHashError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 409 {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("basehash") && (message.contains("stale") || message.contains("mismatch"))
    }

    private func emitSessionDiagnostic(
        level: StartupDiagnosticsLevel,
        event: String,
        context: [String: String]
    ) async {
        await StartupDiagnostics.shared.emit(
            level: level,
            component: "openclaw-session-manager",
            event: event,
            context: context
        )
    }

    private func migrateLegacyKimiCodingProviderEndpointIfNeeded() async {
        let manager = OpenClawManager.shared
        guard manager.isConnected || manager.gatewayStatus == .running else {
            return
        }

        do {
            let migrated = try await manager.migrateLegacyKimiCodingProviderEndpointIfNeeded()
            guard migrated else { return }
            await emitSessionDiagnostic(
                level: .info,
                event: "session.create.kimiCodingEndpointMigrated",
                context: ["baseUrl": "https://api.kimi.com/coding"]
            )
        } catch {
            await emitSessionDiagnostic(
                level: .warning,
                event: "session.create.kimiCodingEndpointMigrationFailed",
                context: ["error": error.localizedDescription]
            )
        }
    }

    private func qualifyKnownKimiModelReferenceIfNeeded(_ requestedModel: String) async -> String? {
        let normalized = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard !normalized.contains("/") else { return normalized }

        let normalizedLower = normalized.lowercased()
        let isKnownKimiIdentifier = normalizedLower == "kimi-k2.5"
            || normalizedLower == "k2p5"
            || normalizedLower == "k2t2"
            || normalizedLower == "kimi-k2-thinking"
        guard isKnownKimiIdentifier else {
            return normalized
        }

        guard let config = try? await connection.configGet(),
              let models = config["models"]?.value as? [String: OpenClawProtocol.AnyCodable],
              let providers = models["providers"]?.value as? [String: OpenClawProtocol.AnyCodable]
        else {
            return normalized
        }

        let hasMoonshot = providers["moonshot"] != nil
        let hasKimiCoding = providers["kimi-coding"] != nil
        if normalizedLower == "kimi-k2.5" || normalizedLower == "k2p5" {
            if hasKimiCoding {
                return "kimi-coding/k2p5"
            }
            if hasMoonshot {
                return "moonshot/kimi-k2.5"
            }
            return normalized
        }

        if normalizedLower == "k2t2"
            || normalizedLower == "kimi-k2-thinking"
            || normalizedLower == "kimi-k2-thinking-turbo"
        {
            let moonshotModel = normalizedLower == "k2t2" ? "kimi-k2-thinking" : normalized
            if hasMoonshot {
                return "moonshot/\(moonshotModel)"
            }
            // Kimi Coding API keys are intended for k2p5.
            if hasKimiCoding {
                return "kimi-coding/k2p5"
            }
            return normalized
        }

        return normalized
    }
}
