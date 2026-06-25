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

    enum Range: String, CaseIterable, Identifiable {
        case month, last30, year, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .month:  return "month"
            case .last30: return "last 30d"
            case .year:   return "year"
            case .all:    return "all time"
            }
        }
    }

    @State private var range: Range = .all
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(v2.paper)
        .task {
            // The first time this view appears: if Store hasn't loaded usage
            // yet (dev build skipping v1's path, fresh launch race, etc.),
            // kick it off. cheap no-op when usageTotals is already populated.
            if store.usageTotals.total.total == 0 {
                await store.load()
            }
        }
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

            rangeSelector

            Button { refresh() } label: {
                HStack(spacing: 5) {
                    Image(systemName: refreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                    Text(refreshing ? "scanning…" : "refresh")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(v2.mute)
            }
            .buttonStyle(.plain)
            .disabled(refreshing)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private var rangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(Range.allCases) { r in
                Button { range = r } label: {
                    Text(r.label)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(range == r ? v2.paper : v2.mute)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(range == r ? v2.ink : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await store.load()
            refreshing = false
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
                value: AnthropicPricing.formatUSD(rangedCost),
                hint: "estimated · \(range.label)"
            )
            statCard(
                label: "TOTAL TOKENS",
                value: formatTokens(rangedTotal.total),
                hint: "input + output + cache"
            )
            statCard(
                label: "SESSIONS",
                value: "\(sessionCountInRange)",
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
            Text("DAILY SPEND — \(range.label.uppercased())")
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

    /// Lower bound for the selected range; nil = no lower bound (.all).
    private var rangeStart: Date? {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        switch range {
        case .month:  return cal.dateInterval(of: .month, for: now)?.start
        case .last30: return cal.date(byAdding: .day, value: -29, to: startOfToday)
        case .year:   return cal.date(byAdding: .day, value: -364, to: startOfToday)
        case .all:    return nil
        }
    }

    private func inRange(_ date: Date) -> Bool {
        guard let start = rangeStart else { return true }
        return date >= start
    }

    private var rangedTotal: TokenUsage {
        var sum: TokenUsage = .zero
        for (day, usage) in totals.byDay where inRange(day) {
            sum += usage
        }
        return sum
    }

    private var rangedCost: Double {
        AnthropicPricing.totalCost(rangedTotal)
    }

    private var sessionCountInRange: Int {
        store.projects.reduce(0) { acc, project in
            acc + project.sessions.filter { inRange($0.lastActivity) }.count
        }
    }

    private var projectCount: Int {
        store.projects.filter { project in
            project.sessions.contains { inRange($0.lastActivity) }
        }.count
    }

    private var avgPerSessionFormatted: String {
        guard sessionCountInRange > 0 else { return "—" }
        return AnthropicPricing.formatUSD(rangedCost / Double(sessionCountInRange))
    }

    private var avgTokensFormatted: String {
        guard sessionCountInRange > 0 else { return "no sessions yet" }
        return "\(formatTokens(rangedTotal.total / sessionCountInRange)) tokens avg"
    }

    private var periodLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        let now = Date()
        guard let start = rangeStart else {
            // .all — show the earliest activity date as a true range.
            if let earliest = totals.byDay.keys.min() {
                return "\(f.string(from: earliest)) – \(f.string(from: now))"
            }
            return "all time"
        }
        return "\(f.string(from: start)) – \(f.string(from: now))"
    }

    private var monthYearLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: Date()).lowercased()
    }

    // Daily bars for the selected range, mapped to a 0-56pt height range.
    // For long ranges (year / all), we still emit one bar per day; the
    // HStack stretches so each bar gets a sliver.
    private var dailyBars: [DailyBar] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        let costsByDay: [Date: Double] = totals.byDay.reduce(into: [:]) { acc, pair in
            let day = cal.startOfDay(for: pair.key)
            guard inRange(day) else { return }
            acc[day, default: 0] += AnthropicPricing.totalCost(pair.value)
        }
        guard let earliest = costsByDay.keys.min() else { return [] }
        let maxCost = max(0.001, costsByDay.values.max() ?? 0)

        let totalDays = cal.dateComponents([.day], from: earliest, to: today).day ?? 0
        // Cap rendered bars at 90 — beyond that the chart gets too dense to
        // read. Bucket into weeks instead when the range is huge.
        let stride = max(1, (totalDays + 1) / 90)

        var bars: [DailyBar] = []
        var idx = 0
        while idx <= totalDays {
            guard let bucketStart = cal.date(byAdding: .day, value: idx, to: earliest) else { break }
            var bucketCost = 0.0
            for j in 0..<stride {
                if let day = cal.date(byAdding: .day, value: j, to: bucketStart),
                   day <= today {
                    bucketCost += costsByDay[day] ?? 0
                }
            }
            let isToday = cal.isDate(bucketStart, inSameDayAs: today)
                || (idx + stride > totalDays)
            bars.append(DailyBar(
                day: cal.component(.day, from: bucketStart),
                cost: bucketCost,
                heightPx: bucketCost / maxCost * 56,
                isToday: isToday
            ))
            idx += stride
        }
        return bars
    }

    private var modelBars: [Bar] {
        let byModel = rangedByModel
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

    private var rangedByModel: [String: Double] {
        var totalsByModel: [String: TokenUsage] = [:]
        for (day, usage) in totals.byDay where inRange(day) {
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
        // Aggregate cost per project by going through the project's session
        // ids and matching against bySession.
        var costsByProject: [(name: String, cost: Double)] = []
        for project in store.projects {
            var projectCost = 0.0
            for session in project.sessions where inRange(session.lastActivity) {
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
        let top = sorted.prefix(5)
        let rest = sorted.dropFirst(5).reduce(0) { $0 + $1.cost }

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
        // Filtered to the selected range so the table doesn't show old
        // sessions when scoping to e.g. "month".
        var rows: [V2UsageSessionRow] = []
        for project in store.projects {
            for session in project.sessions where inRange(session.lastActivity) {
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
            .prefix(10)
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

