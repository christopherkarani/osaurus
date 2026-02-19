//
//  OpenClawSessionManager.swift
//  osaurus
//

import Foundation
import OpenClawProtocol

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
    }

    public func createSession(model: String?) async throws -> String {
        let key = try await connection.sessionsCreate(model: model)
        activeSessionKey = key
        try await loadSessions()
        return key
    }

    public func deleteSession(key: String) async throws {
        try await connection.sessionsDelete(key: key)
        sessions.removeAll { $0.key == key }
        if activeSessionKey == key {
            activeSessionKey = nil
        }
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
}
