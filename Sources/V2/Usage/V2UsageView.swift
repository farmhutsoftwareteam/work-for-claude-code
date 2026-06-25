// Usage view — full-width main-column surface, swapped in by V2AppState
// when the user taps the Usage tile in the workbench. Mirrors the
// Atelier app.dc.html spec: header with back + date range, four-stat grid,
// daily spend sparkline, by-model + by-project bars, recent-sessions table.
//
// Data sources:
//   - Store.usageTotals (TokenUsage aggregates per project / session / day)
//   - AnthropicPricing.cost(...) for $-amount estimates from token counts
//   - Store.projects → project display names
//
// We never fabricate sessions or projects; the table is filtered to entries
// that have at least one token recorded.

import SwiftUI
import Inject

struct V2UsageView: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
        .enableInjection()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Button { appState.mainView = .chat } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .medium))
                    Text("back")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(v2.mute)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Text("Usage")
                .font(.system(size: 18, weight: .medium))
                .kerning(-0.18)

            Text(periodLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)

            Spacer()

            Text(billingNote)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            statRow
            dailySparkline
            HStack(alignment: .top, spacing: 16) {
                byModel
                byProject
            }
            recentSessions
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
    }

    // MARK: - Stat row

    private var statRow: some View {
        HStack(spacing: 1) {
            statCard(
                label: "TOTAL SPEND",
                value: AnthropicPricing.formatUSD(monthlyCost),
                hint: "estimated · current month"
            )
            statCard(
                label: "TOTAL TOKENS",
                value: formatTokens(currentMonthTotal.total),
                hint: "input + output + cache"
            )
            statCard(
                label: "SESSIONS",
                value: "\(sessionCountCurrentMonth)",
                hint: "across \(projectCount) project\(projectCount == 1 ? "" : "s")"
            )
            statCard(
                label: "AVG / SESSION",
                value: avgPerSessionFormatted,
                hint: avgTokensFormatted
            )
        }
        .background(v2.line2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func statCard(label: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .kerning(1.5)
                .foregroundColor(v2.faint)
            Text(value)
                .font(.system(size: 30, weight: .medium))
                .kerning(-0.75)
                .foregroundColor(v2.ink)
            Text(hint)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.mute)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.paper2)
    }

    // MARK: - Daily sparkline

    private var dailySparkline: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DAILY SPEND — \(monthYearLabel)")
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .kerning(1.5)
                .foregroundColor(v2.faint)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(dailyBars, id: \.day) { bar in
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(bar.isToday ? v2.ink : v2.paper3)
                            .frame(height: max(2, CGFloat(bar.heightPx)))
                        Text("\(bar.day)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(bar.isToday ? v2.ink : v2.faint)
                            .fontWeight(bar.isToday ? .medium : .regular)
                    }
                    .frame(maxWidth: .infinity)
                    .help(AnthropicPricing.formatUSD(bar.cost))
                }
            }
            .frame(height: 70)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    // MARK: - By model / by project

    private var byModel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BY MODEL")
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .kerning(1.5)
                .foregroundColor(v2.faint)
            VStack(spacing: 11) {
                ForEach(modelBars, id: \.label) { row in
                    barRow(label: row.label, costText: row.costText, fraction: row.fraction)
                }
                if modelBars.isEmpty {
                    Text("No model data yet.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var byProject: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BY PROJECT")
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .kerning(1.5)
                .foregroundColor(v2.faint)
            VStack(spacing: 9) {
                ForEach(projectBars, id: \.label) { row in
                    barRow(label: row.label, costText: row.costText, fraction: row.fraction, slim: true)
                }
                if projectBars.isEmpty {
                    Text("No project data yet.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func barRow(label: String, costText: String, fraction: Double, slim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(costText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(v2.line2)
                        .frame(height: slim ? 2 : 3)
                    Rectangle()
                        .fill(v2.ink)
                        .frame(width: proxy.size.width * fraction, height: slim ? 2 : 3)
                }
            }
            .frame(height: slim ? 2 : 3)
        }
    }

    // MARK: - Recent sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT SESSIONS")
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .kerning(1.5)
                .foregroundColor(v2.faint)

            VStack(spacing: 0) {
                tableHeader
                ForEach(Array(recentRows.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 {
                        Divider().background(v2.line)
                    }
                    sessionRow(row, isTop: idx == 0)
                }
                if recentRows.isEmpty {
                    Text("No sessions in this period.")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("SESSION").frame(maxWidth: .infinity, alignment: .leading)
            Text("PROJECT").frame(width: 140, alignment: .leading)
            Text("MODEL").frame(width: 130, alignment: .leading)
            Text("TOKENS").frame(width: 76, alignment: .trailing)
            Text("COST").frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
        .kerning(1.2)
        .foregroundColor(v2.faint)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line2).frame(height: 1)
        }
    }

    private func sessionRow(_ row: V2UsageSessionRow, isTop: Bool) -> some View {
        HStack(spacing: 12) {
            Text(row.title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.ink)
                .fontWeight(isTop ? .medium : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1).truncationMode(.tail)
            Text(row.projectName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
                .frame(width: 140, alignment: .leading)
                .lineLimit(1).truncationMode(.middle)
            Text(row.modelLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1).truncationMode(.tail)
            Text(formatTokens(row.tokens))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
                .frame(width: 76, alignment: .trailing)
            Text(AnthropicPricing.formatUSD(row.cost))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.ink)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .background(isTop ? v2.card : Color.clear)
        .overlay(alignment: .leading) {
            if isTop {
                Rectangle().fill(v2.ink).frame(width: 2)
            }
        }
    }

    // MARK: - Derived data

    private var totals: UsageTotals { store.usageTotals }

    private var currentMonthTotal: TokenUsage {
        // Sum byDay entries whose date is in the current calendar month.
        let cal = Calendar.current
        let now = Date()
        guard let interval = cal.dateInterval(of: .month, for: now) else {
            return totals.total
        }
        var sum: TokenUsage = .zero
        for (day, usage) in totals.byDay where interval.contains(day) {
            sum += usage
        }
        return sum
    }

    private var monthlyCost: Double {
        AnthropicPricing.totalCost(currentMonthTotal)
    }

    private var sessionCountCurrentMonth: Int {
        // Count sessions whose lastActivity falls in the current month.
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: Date()) else { return 0 }
        return store.projects.reduce(0) { acc, project in
            acc + project.sessions.filter { interval.contains($0.lastActivity) }.count
        }
    }

    private var projectCount: Int {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: Date()) else { return 0 }
        return store.projects.filter { project in
            project.sessions.contains { interval.contains($0.lastActivity) }
        }.count
    }

    private var avgPerSessionFormatted: String {
        guard sessionCountCurrentMonth > 0 else { return "—" }
        return AnthropicPricing.formatUSD(monthlyCost / Double(sessionCountCurrentMonth))
    }

    private var avgTokensFormatted: String {
        guard sessionCountCurrentMonth > 0 else { return "no sessions yet" }
        return "\(formatTokens(currentMonthTotal.total / sessionCountCurrentMonth)) tokens avg"
    }

    private var periodLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let cal = Calendar.current
        let now = Date()
        guard let interval = cal.dateInterval(of: .month, for: now) else { return "" }
        return "\(f.string(from: interval.start)) – \(f.string(from: now)), \(yearFormatter.string(from: now))"
    }

    private var monthYearLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: Date()).lowercased()
    }

    private var billingNote: String {
        // First day of next month — useful anchor; we don't actually know
        // the user's Anthropic billing date.
        let cal = Calendar.current
        let now = Date()
        guard let nextMonth = cal.date(byAdding: .month, value: 1, to: now),
              let firstOfNext = cal.dateInterval(of: .month, for: nextMonth)?.start else {
            return ""
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "month resets \(f.string(from: firstOfNext))"
    }

    private var yearFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }

    // Daily bars for the current month, mapped to a 0-56pt height range.
    private var dailyBars: [DailyBar] {
        let cal = Calendar.current
        let now = Date()
        guard let interval = cal.dateInterval(of: .month, for: now) else { return [] }
        let dayCount = cal.dateComponents([.day], from: interval.start, to: now).day ?? 0
        let today = cal.startOfDay(for: now)

        let costsByDay: [Date: Double] = totals.byDay.reduce(into: [:]) { acc, pair in
            acc[cal.startOfDay(for: pair.key)] = AnthropicPricing.totalCost(pair.value)
        }
        let maxCost = max(0.001, costsByDay.values.max() ?? 0)

        return (0...dayCount).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
            let startOfDay = cal.startOfDay(for: day)
            let cost = costsByDay[startOfDay] ?? 0
            let dayNum = cal.component(.day, from: day)
            return DailyBar(
                day: dayNum,
                cost: cost,
                heightPx: cost / maxCost * 56,
                isToday: cal.isDate(startOfDay, inSameDayAs: today)
            )
        }
    }

    private var modelBars: [Bar] {
        let byModel = currentMonthByModel
        let total = byModel.values.reduce(0.0, +)
        guard total > 0 else { return [] }
        return byModel
            .map { (label, cost) in
                Bar(
                    label: label,
                    costText: "\(AnthropicPricing.formatUSD(cost)) · \(Int(round(cost / total * 100)))%",
                    fraction: cost / total
                )
            }
            .sorted { $0.fraction > $1.fraction }
    }

    private var currentMonthByModel: [String: Double] {
        // Aggregate per-model tokens from byDay restricted to current month,
        // then cost them through AnthropicPricing.
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: Date()) else { return [:] }
        var totalsByModel: [String: TokenUsage] = [:]
        for (day, usage) in totals.byDay where interval.contains(day) {
            for (model, sub) in usage.byModel {
                let folded = String(model.split(separator: "[").first ?? Substring(model))
                totalsByModel[folded, default: .zero] += sub
            }
        }
        var costsByModel: [String: Double] = [:]
        for (model, usage) in totalsByModel {
            costsByModel[model] = AnthropicPricing.cost(for: model, tokens: usage) ?? 0
        }
        return costsByModel.filter { $0.value > 0 }
    }

    private var projectBars: [Bar] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: Date()) else { return [] }

        // Aggregate cost per project by going through the project's session
        // ids and matching against bySession.
        var costsByProject: [(name: String, cost: Double)] = []
        for project in store.projects {
            var projectCost = 0.0
            for session in project.sessions where interval.contains(session.lastActivity) {
                let key = "\(project.cwd)::\(session.id)"
                if let usage = totals.bySession[key]?.usage {
                    projectCost += AnthropicPricing.totalCost(usage)
                }
            }
            if projectCost > 0 {
                costsByProject.append((project.displayName, projectCost))
            }
        }
        let total = costsByProject.reduce(0) { $0 + $1.cost }
        guard total > 0 else { return [] }

        let sorted = costsByProject.sorted { $0.cost > $1.cost }
        let top = sorted.prefix(4)
        let rest = sorted.dropFirst(4).reduce(0) { $0 + $1.cost }

        var bars: [Bar] = top.map { (name, cost) in
            Bar(label: name, costText: AnthropicPricing.formatUSD(cost), fraction: cost / total)
        }
        if rest > 0 {
            bars.append(Bar(
                label: "others",
                costText: AnthropicPricing.formatUSD(rest),
                fraction: rest / total
            ))
        }
        return bars
    }

    private var recentRows: [V2UsageSessionRow] {
        // Pull the most recent N sessions across all projects, costed.
        var rows: [V2UsageSessionRow] = []
        for project in store.projects {
            for session in project.sessions {
                let key = "\(project.cwd)::\(session.id)"
                guard let usage = totals.bySession[key]?.usage else { continue }
                rows.append(V2UsageSessionRow(
                    id: key,
                    title: V2HistoryEntry.titleFor(session: session),
                    projectName: project.displayName,
                    modelLabel: shortModel(usage: usage),
                    tokens: usage.total,
                    cost: AnthropicPricing.totalCost(usage),
                    lastActivity: session.lastActivity
                ))
            }
        }
        return rows
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(8)
            .map { $0 }
    }

    private func shortModel(usage: TokenUsage) -> String {
        // Pick the model with the most tokens in this session and trim the
        // "claude-" prefix for table density.
        guard let dominant = usage.byModel.max(by: { $0.value.total < $1.value.total })?.key,
              !dominant.isEmpty else { return "—" }
        let bare = String(dominant.split(separator: "[").first ?? Substring(dominant))
        return bare.replacingOccurrences(of: "claude-", with: "")
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}

// MARK: - Row types

private struct DailyBar: Equatable {
    let day: Int
    let cost: Double
    let heightPx: Double
    let isToday: Bool
}

private struct Bar: Equatable {
    let label: String
    let costText: String
    let fraction: Double
}

private struct V2UsageSessionRow: Identifiable, Equatable {
    let id: String
    let title: String
    let projectName: String
    let modelLabel: String
    let tokens: Int
    let cost: Double
    let lastActivity: Date
}

