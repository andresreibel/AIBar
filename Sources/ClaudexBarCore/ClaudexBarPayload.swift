import Foundation

public enum ClaudexBarProvider: String, CaseIterable, Codable, Sendable {
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

    public static let dashboardOrder: [ClaudexBarProvider] = [.claude, .codex, .grok]
}

public enum ClaudexBarSeverity: String, Codable, Sendable {
    case normal
    case stale
    case warning
    case critical
    case error
}

public enum ClaudexBarAccessState: String, Codable, Sendable {
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

public struct ClaudexBarUsagePacing: Decodable, Equatable, Sendable {
    public let expectedPercentage: Double
}

public struct ClaudexBarUsageRow: Decodable, Equatable, Sendable {
    public let label: String
    public let percentage: Double
    public let resetText: String
    public let severity: ClaudexBarSeverity
    public let pacing: ClaudexBarUsagePacing?
}

public struct ClaudexBarResetCredit: Decodable, Equatable, Sendable {
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

public enum ClaudexBarExpiryUrgency: Int, Comparable, Sendable {
    case warning
    case critical

    public static func < (lhs: ClaudexBarExpiryUrgency, rhs: ClaudexBarExpiryUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public func claudexBarExpiryUrgency(
    expiresAt: Double?,
    now: Double = Date().timeIntervalSince1970
) -> ClaudexBarExpiryUrgency? {
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


public struct ClaudexBarPayload: Decodable, Equatable, Sendable {
    public let text: String
    public let tooltip: String
    public let classes: [String]
    public let percentage: Double?
    public let percentageLabel: String?
    public let resetCredits: Double?
    public let resetCreditDetails: [ClaudexBarResetCredit]
    public let updatedAt: String?
    public let accessState: ClaudexBarAccessState
    public let usageRows: [ClaudexBarUsageRow]

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
        resetCreditDetails: [ClaudexBarResetCredit] = [],
        updatedAt: String? = nil,
        accessState: ClaudexBarAccessState = .available,
        usageRows: [ClaudexBarUsageRow] = []
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
            [ClaudexBarResetCredit].self,
            forKey: .resetCreditDetails
        ) ?? []
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        accessState = try container.decode(ClaudexBarAccessState.self, forKey: .accessState)
        usageRows = try container.decodeIfPresent([ClaudexBarUsageRow].self, forKey: .usageRows) ?? []

        if let values = try? container.decode([String].self, forKey: .classes) {
            classes = values
        } else if let value = try? container.decode(String.self, forKey: .classes) {
            classes = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        } else {
            classes = []
        }
    }

    public var severity: ClaudexBarSeverity {
        if classes.contains("error") { return .error }
        if classes.contains("critical") { return .critical }
        if classes.contains("warning") { return .warning }
        if classes.contains("stale") { return .stale }
        return .normal
    }

    public var macOSDetail: String {
        var lines = tooltip.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "ClaudexBar" {
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

public struct ClaudexBarProviderPayload: Decodable, Equatable, Sendable {
    public let provider: ClaudexBarProvider
    public let weeklyPace: Double?
    public let payload: ClaudexBarPayload

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

    public var menuBarBadgeSeverity: ClaudexBarSeverity {
        guard let weeklyUsagePercentage else { return .normal }
        if weeklyUsagePercentage >= 90 { return .critical }
        if weeklyUsagePercentage >= 75 { return .warning }
        return .normal
    }

    public var menuBarText: String {
        "\(provider.badge) \(paceText)"
    }
}

public struct ClaudexBarAggregatePayload: Decodable, Equatable, Sendable {
    public let providers: [ClaudexBarProviderPayload]

    public func payload(for provider: ClaudexBarProvider) -> ClaudexBarProviderPayload? {
        providers.first { $0.provider == provider }
    }

    public var compactEntries: [ClaudexBarProviderPayload] {
        ClaudexBarProvider.dashboardOrder.compactMap { provider in
            guard let entry = payload(for: provider), entry.isCompactEligible else { return nil }
            return entry
        }
    }

    public var menuBarText: String {
        let values = compactEntries.map(\.menuBarText)
        return values.isEmpty ? "ClaudexBar" : values.joined(separator: "  ")
    }
}
