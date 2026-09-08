import Foundation

public enum AIBarProvider: String, CaseIterable, Codable, Sendable {
    case codex
    case claude
    case grok

    public var displayName: String {
        switch self {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        case .grok: "SpaceXAI"
        }
    }

    public var badge: String {
        switch self {
        case .codex: "O"
        case .claude: "A"
        case .grok: "S"
        }
    }

    public static let dashboardOrder: [AIBarProvider] = [.claude, .codex, .grok]
}

public enum AIBarSeverity: String, Codable, Sendable {
    case normal
    case stale
    case warning
    case critical
    case error
}

public enum AIBarAccessState: String, Codable, Sendable {
    case available
    case stale
    case unavailable
    case loginRequired = "login_required"
    case subscriptionExpired = "subscription_expired"

    public var statusLabel: String? {
        switch self {
        case .available: nil
        case .stale: "Temporarily unavailable — showing cached usage"
        case .unavailable: "Usage unavailable"
        case .loginRequired: "Login required"
        case .subscriptionExpired: "Subscription expired"
        }
    }

    public var showsLoginAction: Bool {
        self == .loginRequired
    }

    public var isCompactEligible: Bool {
        self == .available || self == .stale
    }
}

public struct AIBarUsagePacing: Decodable, Equatable, Sendable {
    public let expectedPercentage: Double
}

public struct AIBarUsageRow: Decodable, Equatable, Sendable {
    public let label: String
    public let percentage: Double
    public let resetText: String
    public let severity: AIBarSeverity
    public let pacing: AIBarUsagePacing?
}

public struct AIBarResetCredit: Decodable, Equatable, Sendable {
    public let title: String
    public let expiresAt: Double?

    public var expiryText: String {
        guard let expiresAt, expiresAt.isFinite else { return "Expiry unavailable" }
        let expiry = Date(timeIntervalSince1970: expiresAt)
            .formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "Expires \(expiry)"
    }

    public var displayText: String {
        "\(title)\n\(expiryText)"
    }
}

public enum AIBarExpiryUrgency: Int, Comparable, Sendable {
    case warning
    case critical

    public static func < (lhs: AIBarExpiryUrgency, rhs: AIBarExpiryUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public func aiBarExpiryUrgency(
    expiresAt: Double?,
    now: Double = Date().timeIntervalSince1970
) -> AIBarExpiryUrgency? {
    guard let expiresAt, expiresAt.isFinite else { return nil }
    let remaining = expiresAt - now
    if remaining <= 7 * 24 * 60 * 60 {
        return .critical
    }
    if remaining <= 14 * 24 * 60 * 60 {
        return .warning
    }
    return nil
}


public struct AIBarPayload: Decodable, Equatable, Sendable {
    public let text: String
    public let tooltip: String
    public let classes: [String]
    public let percentage: Double?
    public let percentageLabel: String?
    public let resetCredits: Double?
    public let resetCreditDetails: [AIBarResetCredit]
    public let updatedAt: String?
    public let accessState: AIBarAccessState
    public let usageRows: [AIBarUsageRow]

    private enum CodingKeys: String, CodingKey {
        case text
        case tooltip
        case classes = "class"
        case percentage
        case percentageLabel
        case resetCredits
        case resetCreditDetails
        case updatedAt
        case accessState
        case usageRows
    }

    public init(
        text: String,
        tooltip: String,
        classes: [String] = [],
        percentage: Double? = nil,
        percentageLabel: String? = nil,
        resetCredits: Double? = nil,
        resetCreditDetails: [AIBarResetCredit] = [],
        updatedAt: String? = nil,
        accessState: AIBarAccessState = .available,
        usageRows: [AIBarUsageRow] = []
    ) {
        self.text = text
        self.tooltip = tooltip
        self.classes = classes
        self.percentage = percentage
        self.percentageLabel = percentageLabel
        self.resetCredits = resetCredits
        self.resetCreditDetails = resetCreditDetails
        self.updatedAt = updatedAt
        self.accessState = accessState
        self.usageRows = usageRows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        tooltip = try container.decode(String.self, forKey: .tooltip)
        percentage = try container.decodeIfPresent(Double.self, forKey: .percentage)
        percentageLabel = try container.decodeIfPresent(String.self, forKey: .percentageLabel)
        resetCredits = try container.decodeIfPresent(Double.self, forKey: .resetCredits)
        resetCreditDetails = try container.decodeIfPresent(
            [AIBarResetCredit].self,
            forKey: .resetCreditDetails
        ) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        accessState = try container.decode(AIBarAccessState.self, forKey: .accessState)
        usageRows = try container.decodeIfPresent([AIBarUsageRow].self, forKey: .usageRows) ?? []

        if let values = try? container.decode([String].self, forKey: .classes) {
            classes = values
        } else if let value = try? container.decode(String.self, forKey: .classes) {
            classes = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        } else {
            classes = []
        }
    }

    public var severity: AIBarSeverity {
        if classes.contains("error") { return .error }
        if classes.contains("critical") { return .critical }
        if classes.contains("warning") { return .warning }
        if classes.contains("stale") { return .stale }
        return .normal
    }

    public var macOSDetail: String {
        var lines = tooltip.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "AIBar" {
            lines.removeFirst()
            if lines.first?.allSatisfy({ $0 == "-" }) == true {
                lines.removeFirst()
            }
            while lines.first?.isEmpty == true {
                lines.removeFirst()
            }
        }
        if !usageRows.isEmpty {
            let labels = Set(usageRows.map(\.label))
            let hasWeekly = labels.contains("Weekly") || labels.contains("GrokBot (Weekly)")
            lines.removeAll { line in
                (labels.contains("Session") && line.hasPrefix("Session "))
                    || (hasWeekly && (line.hasPrefix("Week ") || line.hasPrefix("Weekly ")))
            }
        }
        if resetCredits != nil {
            lines.removeAll {
                $0.hasPrefix("Credits ") || $0.hasPrefix("Free reset credits:")
            }
        }
        if let updatedIndex = lines.firstIndex(where: { $0.hasPrefix("Updated:") }) {
            lines.remove(at: updatedIndex)
            if updatedIndex > 0, lines[updatedIndex - 1].isEmpty {
                lines.remove(at: updatedIndex - 1)
            }
        }
        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    public var updatedTimeText: String? {
        guard let updatedAt else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractionalFormatter.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt) else {
            return nil
        }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

public struct AIBarProviderPayload: Decodable, Equatable, Sendable {
    public let provider: AIBarProvider
    public let weeklyPace: Double?
    public let payload: AIBarPayload

    public var isCompactEligible: Bool {
        payload.accessState.isCompactEligible
    }

    public var paceText: String {
        guard let weeklyPace else { return "--" }
        let rounded = Int(weeklyPace.rounded())
        return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
    }

    public var weeklyUsagePercentage: Double? {
        let label = provider == .grok ? "GrokBot (Weekly)" : "Weekly"
        return payload.usageRows.first { $0.label == label }?.percentage
    }

    public var menuBarBadgeSeverity: AIBarSeverity {
        guard let weeklyUsagePercentage else { return .normal }
        if weeklyUsagePercentage >= 90 { return .critical }
        if weeklyUsagePercentage >= 75 { return .warning }
        return .normal
    }

    public var menuBarText: String {
        "\(provider.badge) \(paceText)"
    }
}

public struct AIBarAggregatePayload: Decodable, Equatable, Sendable {
    public let providers: [AIBarProviderPayload]

    public func payload(for provider: AIBarProvider) -> AIBarProviderPayload? {
        providers.first { $0.provider == provider }
    }

    public var compactEntries: [AIBarProviderPayload] {
        AIBarProvider.dashboardOrder.compactMap { provider in
            guard let entry = payload(for: provider), entry.isCompactEligible else { return nil }
            return entry
        }
    }

    public var menuBarText: String {
        let values = compactEntries.map(\.menuBarText)
        return values.isEmpty ? "AIBar" : values.joined(separator: "  ")
    }
}
