import AppKit
import ClaudexBarCore
import Combine
import Foundation
import SwiftUI
private let cosmicOrange = Color(
    red: 1.0,
    green: 158.0 / 255.0,
    blue: 100.0 / 255.0
)


private enum EngineError: LocalizedError {
    case missingBun
    case missingScript
    case failed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingBun:
            "Bun was not found. Install Bun at ~/.bun/bin/bun."
        case .missingScript:
            "The shared claudexbar.ts engine was not found."
        case .failed(let message):
            message
        case .invalidOutput(let output):
            "ClaudexBar returned invalid output: \(output)"
        }
    }
}

private struct EngineRunner: Sendable {
    let bunURL: URL
    let scriptURL: URL

    static func resolve() throws -> EngineRunner {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser

        let bunCandidates = [
            environment["CLAUDEXBAR_BUN"].map(URL.init(fileURLWithPath:)),
            home.appendingPathComponent(".bun/bin/bun"),
            URL(fileURLWithPath: "/opt/homebrew/bin/bun"),
            URL(fileURLWithPath: "/usr/local/bin/bun")
        ].compactMap { $0 }

        guard let bunURL = bunCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw EngineError.missingBun
        }

        let scriptCandidates = [
            environment["CLAUDEXBAR_SCRIPT"].map(URL.init(fileURLWithPath:)),
            Bundle.main.resourceURL?.appendingPathComponent("claudexbar.ts"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("claudexbar.ts"),
            home.appendingPathComponent("code/ClaudexBar/claudexbar.ts"),
            home.appendingPathComponent("Code/ClaudexBar/claudexbar.ts")
        ].compactMap { $0 }

        guard let scriptURL = scriptCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw EngineError.missingScript
        }

        return EngineRunner(bunURL: bunURL, scriptURL: scriptURL)
    }

    func payloads() async throws -> ClaudexBarAggregatePayload {
        let output = try await run(arguments: ["--all"])
        guard let data = output.data(using: .utf8) else {
            throw EngineError.invalidOutput(output)
        }
        do {
            return try JSONDecoder().decode(ClaudexBarAggregatePayload.self, from: data)
        } catch {
            throw EngineError.invalidOutput(output)
        }
    }

    func reconnect(_ provider: ClaudexBarProvider) async throws {
        if provider == .grok {
            let output = try await run(arguments: ["--login", "grok"])
            guard output == "grok" else {
                throw EngineError.invalidOutput(output)
            }
            return
        }

        let command = provider == .claude ? "claude auth login" : "codex login"
        try await runLoginCommand(command)
    }

    private func runLoginCommand(_ command: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lic", command]
            process.standardOutput = Pipe()
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw EngineError.failed("Could not start provider sign-in: \(error.localizedDescription)")
            }

            process.waitUntilExit()
            let errorOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0 else {
                throw EngineError.failed(
                    errorOutput.isEmpty ? "Provider sign-in failed." : errorOutput
                )
            }
        }.value
    }

    private func run(arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var environment = ProcessInfo.processInfo.environment
            let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

            environment["PATH"] = "\(home)/.bun/bin:/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
            process.environment = environment
            process.executableURL = bunURL
            process.arguments = [scriptURL.path] + arguments
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw EngineError.failed("Could not start ClaudexBar: \(error.localizedDescription)")
            }

            process.waitUntilExit()
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                throw EngineError.failed(errorOutput.isEmpty ? "ClaudexBar exited with status \(process.terminationStatus)." : errorOutput)
            }
            return output
        }.value
    }
}

@MainActor
private final class ClaudexBarModel: ObservableObject {
    @Published var aggregate: ClaudexBarAggregatePayload?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var hasLoaded = false

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    var statusTitle: String {
        aggregate?.menuBarText ?? "A --  O --  S --"
    }

    var statusTooltip: String {
        guard let aggregate else {
            return errorMessage ?? "ClaudexBar"
        }
        return ClaudexBarProvider.dashboardOrder.map { provider in
            guard let entry = aggregate.payload(for: provider) else {
                return "\(provider.displayName): Usage unavailable"
            }
            if let status = entry.payload.accessState.statusLabel {
                return "\(provider.displayName): \(status)"
            }
            return "\(provider.displayName): \(entry.paceText) weekly pace"
        }.joined(separator: "\n")
    }

    func payload(for provider: ClaudexBarProvider) -> ClaudexBarProviderPayload? {
        aggregate?.payload(for: provider)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        isRefreshing = true

        do {
            let runner = try EngineRunner.resolve()
            aggregate = try await runner.payloads()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        await waitForMinimumSpinner(since: startedAt)
        isRefreshing = false
        hasLoaded = true
    }

    func reconnect(_ provider: ClaudexBarProvider) async {
        guard !isRefreshing else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        isRefreshing = true
        errorMessage = nil

        do {
            let runner = try EngineRunner.resolve()
            try await runner.reconnect(provider)
            aggregate = try await runner.payloads()
        } catch {
            errorMessage = error.localizedDescription
        }

        await waitForMinimumSpinner(since: startedAt)
        isRefreshing = false
        hasLoaded = true
    }

    private func waitForMinimumSpinner(since startedAt: UInt64) async {
        let minimumDuration: UInt64 = 1_000_000_000
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        if elapsed < minimumDuration {
            try? await Task.sleep(nanoseconds: minimumDuration - elapsed)
        }
    }
}

private enum DashboardNoticeTone: String {
    case neutral
    case warning
    case critical
}

private struct DashboardNotice: Identifiable {
    let id: String
    let title: String
    let message: String
    let tone: DashboardNoticeTone
    let loginProvider: ClaudexBarProvider?
}

private struct ClaudexBarMenu: View {
    @ObservedObject var model: ClaudexBarModel
    @State private var showsResetCreditExpiries = false
    @State private var showsUsageGuide = false
    @State private var showsNotifications = false
    @AppStorage("dismissedNotificationSignature") private var dismissedNotificationSignature = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ClaudexBar")
                    .font(.headline)
                Button {
                    showsUsageGuide.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .help("How usage pacing works")
                .popover(isPresented: $showsUsageGuide, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Usage pacing")
                            .font(.headline)
                        Text("Expected shows where usage would be at an even pace through the current quota window.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 6) {
                            pacingGuideRow(color: .green, text: "Green is capacity remaining before expected.")
                            pacingGuideRow(color: cosmicOrange, text: "Orange is slightly above expected.")
                            pacingGuideRow(color: .red, text: "Red is 10 points or more above expected.")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("+  Below expected")
                            Text("−  Above expected")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(14)
                    .frame(width: 250, alignment: .leading)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .disabled(model.isRefreshing)
                .help("Refresh all providers")
            }

            Group {
                if model.isRefreshing || !model.hasLoaded {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Loading usage…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let aggregate = model.aggregate {
                    VStack(alignment: .leading, spacing: 12) {
                        let usageProviders = aggregate.compactEntries.map(\.provider)

                        if !usageProviders.isEmpty {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(usageProviders, id: \.rawValue) { provider in
                                    providerColumn(provider)
                                }
                            }
                        }
                    }
                } else {
                    Text("Usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if !dashboardNotices.isEmpty {
                Button {
                    showsNotifications.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("\(dashboardNotices.count) \(dashboardNotices.count == 1 ? "notice" : "notices")")
                        Spacer()
                        Text("Open")
                        Image(systemName: "chevron.up")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 3)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open notifications")
                .popover(isPresented: $showsNotifications, arrowEdge: .bottom) {
                    notificationPopover()
                }
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .frame(width: 620, height: 450, alignment: .topLeading)
        .task {
            await model.refresh()
        }
        .onChange(of: notificationSignature, initial: true) { _, signature in
            if signature.isEmpty || (
                !dismissedNotificationSignature.isEmpty
                    && signature != dismissedNotificationSignature
            ) {
                dismissedNotificationSignature = ""
            }
        }
    }

    private var accessWarningProviders: [ClaudexBarProvider] {
        guard let aggregate = model.aggregate else { return [] }
        return ClaudexBarProvider.dashboardOrder.filter {
            aggregate.payload(for: $0)?.isCompactEligible != true
        }
    }


    private var allDashboardNotices: [DashboardNotice] {
        var notices = accessWarningProviders.map { provider in
            let state = model.payload(for: provider)?.payload.accessState ?? .unavailable
            return DashboardNotice(
                id: "access-\(provider.rawValue)-\(state.rawValue)",
                title: provider.displayName,
                message: state.statusLabel ?? "Usage unavailable",
                tone: state == .loginRequired || state == .subscriptionExpired ? .critical : .neutral,
                loginProvider: state.showsLoginAction ? provider : nil
            )
        }

        for provider in ClaudexBarProvider.dashboardOrder {
            guard let payload = model.payload(for: provider)?.payload,
                  payload.accessState.isCompactEligible else {
                continue
            }
            let details = providerDetails(payload.macOSDetail)
            for quota in details.unavailableQuotas {
                notices.append(DashboardNotice(
                    id: "quota-\(provider.rawValue)-\(quota)",
                    title: "\(provider.displayName) \(quota.lowercased()) usage",
                    message: "Unavailable from the provider response.",
                    tone: .neutral,
                    loginProvider: nil
                ))
            }
            for (index, credit) in payload.resetCreditDetails.enumerated() {
                guard let urgency = claudexBarExpiryUrgency(expiresAt: credit.expiresAt) else { continue }
                notices.append(DashboardNotice(
                    id: "credit-\(provider.rawValue)-\(index)-\(credit.expiresAt ?? 0)",
                    title: "\(provider.displayName) reset credit",
                    message: credit.expiryText,
                    tone: urgency == .critical ? .critical : .warning,
                    loginProvider: nil
                ))
            }
        }
        return notices
    }

    private var notificationSignature: String {
        allDashboardNotices.map {
            "\($0.id):\($0.tone.rawValue):\($0.message)"
        }.joined(separator: "|")
    }

    private var dashboardNotices: [DashboardNotice] {
        guard notificationSignature != dismissedNotificationSignature else { return [] }
        return allDashboardNotices
    }

    @ViewBuilder
    private func notificationPopover() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notifications")
                .font(.headline)

            ForEach(dashboardNotices) { notice in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(noticeColor(notice.tone))
                        .frame(width: 5, height: 5)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.title)
                            .font(.caption.weight(.semibold))
                        Text(notice.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if let provider = notice.loginProvider {
                        Button("Login") {
                            Task { await model.reconnect(provider) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isRefreshing)
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Clear notifications") {
                    dismissedNotificationSignature = notificationSignature
                    showsNotifications = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }

    private func noticeColor(_ tone: DashboardNoticeTone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .warning: cosmicOrange
        case .critical: .red
        }
    }

    private func resetCreditUrgency(_ payload: ClaudexBarPayload) -> ClaudexBarExpiryUrgency? {
        payload.resetCreditDetails.compactMap {
            claudexBarExpiryUrgency(expiresAt: $0.expiresAt)
        }.max()
    }

    @ViewBuilder
    private func providerColumn(_ provider: ClaudexBarProvider) -> some View {
        let entry = model.payload(for: provider)
        let payload = entry?.payload

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(provider.badge)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.09)))
                Text(provider.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if let payload {
                if let status = payload.accessState.statusLabel {
                    Text(status)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accessStateColor(payload.accessState))
                        .fixedSize(horizontal: false, vertical: true)
                }

                let details = providerDetails(payload.macOSDetail)
                if payload.accessState.isCompactEligible {
                    if payload.usageRows.isEmpty {
                        if let percentage = payload.percentage {
                            usageRow(
                                label: payload.percentageLabel ?? "Usage",
                                percentage: percentage,
                                resetText: nil,
                                pacing: nil,
                                tint: usageColor(for: payload.severity)
                            )
                        }
                    } else {
                        ForEach(Array(payload.usageRows.enumerated()), id: \.offset) { _, row in
                            usageRow(
                                label: row.label,
                                percentage: row.percentage,
                                resetText: row.resetText,
                                pacing: row.pacing,
                                tint: usageColor(for: row.severity)
                            )
                        }
                    }

                    if let credits = payload.resetCredits {
                        let creditUrgency = resetCreditUrgency(payload)
                        Button {
                            if !payload.resetCreditDetails.isEmpty {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showsResetCreditExpiries.toggle()
                                }
                            }
                        } label: {
                            HStack {
                                Text("Reset credits")
                                    .foregroundStyle(
                                        creditUrgency.map {
                                            noticeColor($0 == .critical ? .critical : .warning)
                                        } ?? Color.secondary
                                    )
                                Spacer()
                                Text(credits.formatted(.number.precision(.fractionLength(0...2))))
                                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                                    .foregroundStyle(
                                        creditUrgency.map {
                                            noticeColor($0 == .critical ? .critical : .warning)
                                        } ?? Color.primary
                                    )
                                if !payload.resetCreditDetails.isEmpty {
                                    Image(systemName: showsResetCreditExpiries ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(
                                            creditUrgency.map {
                                                noticeColor($0 == .critical ? .critical : .warning)
                                            } ?? Color.secondary
                                        )
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .help(
                            payload.resetCreditDetails.isEmpty
                                ? "Expiry details unavailable"
                                : payload.resetCreditDetails.map(\.displayText).joined(separator: "\n\n")
                        )

                        if showsResetCreditExpiries {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(payload.resetCreditDetails.enumerated()), id: \.offset) { _, credit in
                                    let urgency = claudexBarExpiryUrgency(expiresAt: credit.expiresAt)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(credit.title)
                                            .fontWeight(.semibold)
                                        Text(credit.expiryText)
                                    }
                                    .foregroundStyle(
                                        urgency.map {
                                            noticeColor($0 == .critical ? .critical : .warning)
                                        } ?? Color.secondary
                                    )
                                }
                            }
                            .font(.caption2)
                            .padding(.leading, 4)
                        }
                    }

                    if !details.visible.isEmpty {
                        Text(details.visible)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(payload.severity == .error ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if let updatedTime = payload.updatedTimeText {
                        Text("Updated \(updatedTime)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if payload.accessState.showsLoginAction {
                    Button("Login") {
                        Task { await model.reconnect(provider) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRefreshing)
                }
            } else {
                Text("Loading usage…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func providerDetails(_ detail: String) -> (visible: String, unavailableQuotas: [String]) {
        var visibleLines: [String] = []
        var unavailableQuotas: [String] = []

        for line in detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            switch line.trimmingCharacters(in: .whitespaces) {
            case "Session unavailable":
                unavailableQuotas.append("Session")
            case "Week unavailable", "Weekly unavailable":
                unavailableQuotas.append("Weekly")
            case "Cursor monthly unavailable":
                unavailableQuotas.append("Cursor monthly")
            case "Other monthly unavailable":
                unavailableQuotas.append("Other monthly")
            default:
                visibleLines.append(line)
            }
        }

        while visibleLines.first?.isEmpty == true {
            visibleLines.removeFirst()
        }
        while visibleLines.last?.isEmpty == true {
            visibleLines.removeLast()
        }

        return (visibleLines.joined(separator: "\n"), unavailableQuotas)
    }

    private func unavailableQuotaExplanation(
        _ quota: String,
        provider: ClaudexBarProvider
    ) -> String {
        "\(provider.displayName) did not provide \(quota.lowercased()) usage, so that quota is not shown."
    }

    private func accessStateColor(_ state: ClaudexBarAccessState) -> Color {
        switch state {
        case .loginRequired, .subscriptionExpired: .red
        case .stale, .unavailable: cosmicOrange
        case .available: .secondary
        }
    }

    private func usageColor(for severity: ClaudexBarSeverity) -> Color {
        switch severity {
        case .critical, .error: .red
        case .warning: cosmicOrange
        case .normal, .stale: .accentColor
        }
    }

    @ViewBuilder
    private func usageRow(
        label: String,
        percentage: Double,
        resetText: String?,
        pacing: ClaudexBarUsagePacing?,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let pacing {
                let expected = pacing.expectedPercentage
                let common = min(percentage, expected)

                HStack {
                    Text("Expected")
                    Spacer(minLength: 4)
                    Text("\(formatPercentage(expected))%")
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                comparisonMeter(
                    neutralThrough: common,
                    highlightThrough: expected,
                    highlight: .green
                )

                HStack {
                    Text(compactLabel(label))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let delta = signedDeltaText(expected: expected, actual: percentage) {
                        Text(delta)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(deltaColor(expected: expected, actual: percentage).opacity(0.88))
                            .monospacedDigit()
                    }
                    Text("\(formatPercentage(percentage))%")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                comparisonMeter(
                    neutralThrough: common,
                    highlightThrough: percentage,
                    highlight: overageColor(expected: expected, actual: percentage)
                )
            } else {
                HStack {
                    Text(compactLabel(label))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(formatPercentage(percentage))%")
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                ProgressView(value: min(max(percentage, 0), 100), total: 100)
                    .tint(tint)
                    .controlSize(.small)
            }

            if let resetText {
                Text("Resets \(resetText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    private func pacingGuideRow(color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func comparisonMeter(
        neutralThrough: Double,
        highlightThrough: Double,
        highlight: Color
    ) -> some View {
        let neutral = min(max(neutralThrough, 0), 100)
        let highlighted = min(max(highlightThrough, neutral), 100)

        return GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: width * neutral / 100)
                Rectangle()
                    .fill(highlight)
                    .frame(width: width * (highlighted - neutral) / 100)
                    .offset(x: width * neutral / 100)
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private func signedDeltaText(expected: Double, actual: Double) -> String? {
        let delta = expected - actual
        guard delta != 0 else { return nil }
        let sign = delta > 0 ? "+" : "−"
        return "\(sign)\(formatPercentage(abs(delta)))%"
    }

    private func deltaColor(expected: Double, actual: Double) -> Color {
        expected > actual ? .green : overageColor(expected: expected, actual: actual)
    }

    private func overageColor(expected: Double, actual: Double) -> Color {
        actual - expected >= 10 ? .red : cosmicOrange
    }

    private func compactLabel(_ label: String) -> String {
        switch label {
        case "Cursor Models (Monthly)": "Cursor monthly"
        case "Other Models (Monthly)": "Other monthly"
        case "GrokBot (Weekly)": "GrokBot weekly"
        default: label
        }
    }

    private func formatPercentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

@MainActor
private final class ClaudexBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = ClaudexBarModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var lastStatusTitle = "A --  O --  S --"
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ClaudexBarMenu(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }

        model.$aggregate
            .combineLatest(model.$errorMessage)
            .sink { [weak self] aggregate, errorMessage in
                self?.updateStatusItem(aggregate: aggregate, errorMessage: errorMessage)
            }
            .store(in: &cancellables)

        Task { await model.refresh() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        updateStatusItem(aggregate: model.aggregate, errorMessage: model.errorMessage)
    }

    private func updateStatusItem(
        aggregate: ClaudexBarAggregatePayload?,
        errorMessage: String?
    ) {
        guard let button = statusItem.button else { return }

        if let aggregate {
            lastStatusTitle = aggregate.menuBarText
        }
        guard !popover.isShown else { return }
        let title = aggregate?.menuBarText ?? lastStatusTitle
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributedTitle = NSMutableAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: baseFont,
            ]
        )
        if let aggregate {
            let connected = aggregate.compactEntries
            var location = 0
            for (index, entry) in connected.enumerated() {
                if index > 0 {
                    location += 2
                }
                let badgeColor: NSColor
                switch entry.menuBarBadgeSeverity {
                case .warning:
                    badgeColor = NSColor(cosmicOrange)
                case .critical:
                    badgeColor = .red
                case .normal, .stale, .error:
                    badgeColor = .labelColor
                }
                attributedTitle.addAttribute(
                    .foregroundColor,
                    value: badgeColor,
                    range: NSRange(location: location, length: 1)
                )
                location += (entry.menuBarText as NSString).length
            }
        }
        button.attributedTitle = attributedTitle
        button.toolTip = model.statusTooltip
        button.setAccessibilityLabel("ClaudexBar, \(title)")
    }
}

@main
private struct ClaudexBarApp: App {
    @NSApplicationDelegateAdaptor(ClaudexBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
