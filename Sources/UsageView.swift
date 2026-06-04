import SwiftUI
import Charts

// MARK: - Usage view — token totals across sessions and projects

struct UsageView: View {
    @EnvironmentObject var store: Store
    @State private var range: UsageRange = .week

    /// Cached results — recomputed via `.onChange` only when the underlying
    /// data shifts. Without this both `cachedTopProjects.sorted` and
    /// `heatmapCells` ran on every body re-eval (window drag, tab switch),
    /// triggering visible jank for power users.
    @State private var cachedTopProjects: [ProjectUsage] = []
    @State private var cachedHeatmapCells: [HeatmapCell] = []

    private var hasData: Bool { store.usageTotals.total.total > 0 }
    private var showSkeleton: Bool { store.isLoadingUsage && !hasData }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("USAGE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.tertiary)
                    Text("Token usage across all your Claude Code sessions")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                if showSkeleton {
                    skeletonCards
                } else {
                    // Today's counter — what users open the page to see first
                    todayHero

                    // Activity over time (range picker + chart)
                    activityCard

                    // GitHub-style daily contribution heatmap
                    heatmapCard

                    // Total summary card (all-time)
                    totalSummary

                    // Breakdown by token type
                    breakdownCard

                    // Per-project totals
                    if !cachedTopProjects.isEmpty {
                        projectBreakdown
                    }
                }

                // Caveat
                Text("Counts are derived from your local session logs. If you're on a Claude Max or Pro subscription, usage is included in your plan — this view is informational only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .padding(28)
        }
        .navigationTitle("Usage")
        // Refresh memoized derivations only when the underlying data shifts.
        .onAppear { rebuildCaches() }
        .onChange(of: store.usageTotals.byProject) { _, _ in rebuildCaches() }
        .onChange(of: store.usageTotals.byDay) { _, _ in rebuildHeatmap() }
    }

    private func rebuildCaches() {
        cachedTopProjects = store.usageTotals.byProject.values
            .sorted { $0.usage.total > $1.usage.total }
        rebuildHeatmap()
    }

    private func rebuildHeatmap() {
        cachedHeatmapCells = heatmapCells(byDay: store.usageTotals.byDay)
    }

    // MARK: - Today hero

    /// UTC start-of-day, aligned with how the aggregator buckets.
    private static func utcStartOfDay(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal.startOfDay(for: date)
    }

    private var todayUsage: TokenUsage {
        store.usageTotals.byDay[Self.utcStartOfDay(Date())] ?? .zero
    }

    private var yesterdayUsage: TokenUsage {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let y = cal.date(byAdding: .day, value: -1, to: Self.utcStartOfDay(Date())) else { return .zero }
        return store.usageTotals.byDay[y] ?? .zero
    }

    private var todayHero: some View {
        let today = todayUsage
        let yesterday = yesterdayUsage
        let delta: Int? = {
            guard yesterday.total > 0 else { return nil }
            return today.total - yesterday.total
        }()

        return HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.accentColor)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(UsageAggregator.format(today.total))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("tokens")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    if let delta = delta {
                        deltaBadge(delta: delta)
                    }
                }

                Text(todayFootnote(today: today, yesterday: yesterday))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Inline split — input vs output vs cache
            VStack(alignment: .trailing, spacing: 6) {
                miniStat("Input", UsageAggregator.format(today.inputTokens), .blue)
                miniStat("Output", UsageAggregator.format(today.outputTokens), .green)
                miniStat("Cache", UsageAggregator.format(today.cacheReadTokens + today.cacheCreationTokens), .purple)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.09),
                            Color.accentColor.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.5)
                )
        )
    }

    private func deltaBadge(delta: Int) -> some View {
        let positive = delta >= 0
        let symbol = positive ? "arrow.up" : "arrow.down"
        let color: Color = positive ? .orange : .green  // up = more burn, down = saved
        let label = UsageAggregator.format(Swift.abs(delta))
        return HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
    }

    private func todayFootnote(today: TokenUsage, yesterday: TokenUsage) -> String {
        if today.total == 0 { return "No tokens yet today" }
        if yesterday.total == 0 { return "First activity in a day or more" }
        let delta = today.total - yesterday.total
        if delta == 0 { return "Same as yesterday" }
        let pct = Int((Double(Swift.abs(delta)) / Double(yesterday.total)) * 100)
        let direction = delta > 0 ? "more than" : "less than"
        return "\(pct)% \(direction) yesterday (\(UsageAggregator.format(yesterday.total)))"
    }

    private func miniStat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: - Total summary

    private var totalSummary: some View {
        let total = store.usageTotals.total
        return HStack(spacing: 20) {
            bigStat(label: "Total tokens", value: UsageAggregator.format(total.total))
            Divider().frame(height: 48)
            bigStat(label: "Sessions", value: "\(store.usageTotals.bySession.count)")
            Divider().frame(height: 48)
            bigStat(label: "Projects", value: "\(store.usageTotals.byProject.count)")
            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func bigStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }

    // MARK: - Breakdown

    private var breakdownCard: some View {
        let t = store.usageTotals.total
        return VStack(alignment: .leading, spacing: 14) {
            Text("Breakdown")
                .font(.system(size: 14, weight: .semibold))

            breakdownRow(label: "Input", value: t.inputTokens, color: .blue)
            breakdownRow(label: "Output", value: t.outputTokens, color: .green)
            breakdownRow(label: "Cache write", value: t.cacheCreationTokens, color: .orange)
            breakdownRow(label: "Cache read", value: t.cacheReadTokens, color: .purple)

            Text("Cache reads are billed at ~10% of input rate — they cost less despite appearing alongside other tokens here.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func breakdownRow(label: String, value: Int, color: Color) -> some View {
        let total = max(store.usageTotals.total.total, 1)
        let pct = Double(value) / Double(total)
        return HStack(spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 13))
                .frame(width: 100, alignment: .leading)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.2))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.opacity(0.7))
                            .frame(width: geo.size.width * pct)
                    }
            }
            .frame(height: 6)
            Text(UsageAggregator.format(value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: - Skeleton (loading state)

    @ViewBuilder
    private var skeletonCards: some View {
        VStack(alignment: .leading, spacing: 24) {
            skeletonCard(height: 220)  // Activity card placeholder
            skeletonCard(height: 110)  // Totals placeholder
            skeletonCard(height: 180)  // Breakdown placeholder
        }
    }

    private func skeletonCard(height: CGFloat) -> some View {
        ShimmerBox()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(alignment: .center) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning session logs…")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                }
                .opacity(height > 150 ? 1 : 0)  // only on the tallest skeleton
            }
    }

    // MARK: - Activity (per-week / month / year)

    private var activityCard: some View {
        let buckets = bucketsForChart(range: range, byDay: store.usageTotals.byDay)
        let periodTotal = buckets.reduce(0) { $0 + $1.usage.total }
        let avgLabel = range == .year ? "Monthly avg" : "Daily avg"
        let peakLabel = range == .year ? "Peak month" : "Peak day"

        return VStack(alignment: .leading, spacing: 14) {
            activityHeader
            activityStats(periodTotal: periodTotal, buckets: buckets, avgLabel: avgLabel, peakLabel: peakLabel)
            if periodTotal > 0 {
                activityChart(buckets: buckets)
            } else {
                Text("No usage in this range yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private var activityHeader: some View {
        HStack(alignment: .center) {
            Text("Activity")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Picker("", selection: $range) {
                ForEach([UsageRange.week, .month, .year]) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private func activityStats(periodTotal: Int, buckets: [ChartBucket], avgLabel: String, peakLabel: String) -> some View {
        HStack(spacing: 18) {
            bigStat(label: "Tokens this \(range.rawValue.lowercased())", value: UsageAggregator.format(periodTotal))
            Divider().frame(height: 36)
            bigStat(label: avgLabel, value: UsageAggregator.format(periodAverage(buckets)))
            Divider().frame(height: 36)
            bigStat(label: peakLabel, value: UsageAggregator.format(buckets.map(\.usage.total).max() ?? 0))
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func activityChart(buckets: [ChartBucket]) -> some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Period", bucket.label),
                y: .value("Tokens", bucket.usage.total),
                width: .ratio(0.65)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(4)
        }
        .frame(height: 160)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let n = value.as(Int.self) {
                        Text(UsageAggregator.format(n))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: buckets.count)) { _ in
                AxisValueLabel()
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Heatmap (GitHub-style 52-week grid)

    private var heatmapCard: some View {
        let cells = cachedHeatmapCells
        let activeDays = cells.filter { $0.tokens > 0 }.count
        let streakInfo = computeStreaks(cells: cells)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily activity")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Last 52 weeks")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
            }

            HStack(spacing: 18) {
                bigStat(label: "Active days", value: "\(activeDays)")
                Divider().frame(height: 36)
                bigStat(label: "Current streak", value: "\(streakInfo.current)")
                Divider().frame(height: 36)
                bigStat(label: "Longest streak", value: "\(streakInfo.longest)")
                Spacer()
            }
            .padding(.bottom, 4)

            heatmapGrid(cells: cells)

            heatmapLegend
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func heatmapGrid(cells: [HeatmapCell]) -> some View {
        HeatmapCanvasView(cells: cells)
    }

    private var heatmapLegend: some View {
        HStack(spacing: 6) {
            Spacer()
            Text("Less")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(heatmapColor(level: level))
                    .frame(width: 11, height: 11)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
            }
            Text("More")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private func heatmapColor(level: Int) -> Color {
        switch level {
        case 0: return Color.primary.opacity(0.06)
        case 1: return Color.accentColor.opacity(0.25)
        case 2: return Color.accentColor.opacity(0.45)
        case 3: return Color.accentColor.opacity(0.7)
        default: return Color.accentColor
        }
    }

    /// Build 52 weeks worth of cells, oldest first, padded to start on Monday.
    private func heatmapCells(byDay: [Date: TokenUsage]) -> [HeatmapCell] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        cal.firstWeekday = 2  // Monday

        let today = cal.startOfDay(for: Date())
        let earliest = cal.date(byAdding: .day, value: -363, to: today)! // ~52 weeks

        // Pad to start on a Monday so the grid columns align
        let weekdayOfEarliest = cal.component(.weekday, from: earliest) // Sun=1...Sat=7
        let isoWeekday = (weekdayOfEarliest + 5) % 7  // Mon=0...Sun=6
        let padDays = isoWeekday

        var cells: [HeatmapCell] = []
        for i in 0..<padDays {
            cells.append(HeatmapCell(id: "pad-pre-\(i)", date: .distantPast, tokens: 0, level: 0, isPlaceholder: true))
        }

        // Compute thresholds from non-zero days for adaptive color binning
        let visibleTokens: [Int] = (0..<364).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: earliest) else { return nil }
            let usage = byDay[day]?.total ?? 0
            return usage > 0 ? usage : nil
        }
        let thresholds = quartiles(visibleTokens.sorted())

        for offset in 0..<364 {
            guard let day = cal.date(byAdding: .day, value: offset, to: earliest) else { continue }
            if day > today { break }
            let tokens = byDay[day]?.total ?? 0
            cells.append(HeatmapCell(
                id: UsageCacheDateCoder.string(from: day),
                date: day,
                tokens: tokens,
                level: levelFor(tokens: tokens, thresholds: thresholds),
                isPlaceholder: false
            ))
        }

        // Pad the trailing week so the final column has 7 cells
        var padIdx = 0
        while cells.count % 7 != 0 {
            cells.append(HeatmapCell(id: "pad-post-\(padIdx)", date: .distantFuture, tokens: 0, level: 0, isPlaceholder: true))
            padIdx += 1
        }

        return cells
    }

    private func quartiles(_ sorted: [Int]) -> (q25: Int, q50: Int, q75: Int) {
        guard !sorted.isEmpty else { return (0, 0, 0) }
        func at(_ pct: Double) -> Int {
            let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count) * pct)))
            return sorted[idx]
        }
        return (at(0.25), at(0.5), at(0.75))
    }

    private func levelFor(tokens: Int, thresholds: (q25: Int, q50: Int, q75: Int)) -> Int {
        if tokens == 0 { return 0 }
        if tokens <= thresholds.q25 { return 1 }
        if tokens <= thresholds.q50 { return 2 }
        if tokens <= thresholds.q75 { return 3 }
        return 4
    }

    private func computeStreaks(cells: [HeatmapCell]) -> (current: Int, longest: Int) {
        let real = cells.filter { !$0.isPlaceholder }
        var longest = 0
        var current = 0
        var running = 0
        for cell in real {
            if cell.tokens > 0 {
                running += 1
                longest = max(longest, running)
            } else {
                running = 0
            }
        }
        // Current streak = trailing run of active days from the end
        for cell in real.reversed() {
            if cell.tokens > 0 { current += 1 } else { break }
        }
        return (current, longest)
    }

    struct HeatmapCell: Identifiable {
        let id: String          // stable — derived from date or pad index
        let date: Date
        let tokens: Int
        let level: Int
        let isPlaceholder: Bool
    }

    private func periodAverage(_ buckets: [ChartBucket]) -> Int {
        let nonZero = buckets.filter { $0.usage.total > 0 }
        guard !nonZero.isEmpty else { return 0 }
        let sum = nonZero.reduce(0) { $0 + $1.usage.total }
        return sum / nonZero.count
    }

    // MARK: - Bucket builder for the chart

    /// One bar in the chart. `label` is what shows on the X axis ("Mon", "Apr 12", "Jan").
    struct ChartBucket: Identifiable {
        let id: String
        let label: String
        let usage: TokenUsage
    }

    /// Build the trailing buckets for the selected range.
    /// Week → 7 daily bars; Month → 30 daily bars; Year → 12 monthly bars.
    private func bucketsForChart(range: UsageRange, byDay: [Date: TokenUsage]) -> [ChartBucket] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = Date()
        let today = cal.startOfDay(for: now)

        let dayLabel: DateFormatter = {
            let f = DateFormatter()
            f.timeZone = cal.timeZone
            f.dateFormat = "MMM d"
            return f
        }()
        let weekdayLabel: DateFormatter = {
            let f = DateFormatter()
            f.timeZone = cal.timeZone
            f.dateFormat = "EEE"
            return f
        }()
        let monthLabel: DateFormatter = {
            let f = DateFormatter()
            f.timeZone = cal.timeZone
            f.dateFormat = "MMM"
            return f
        }()

        switch range {
        case .week:
            // 7 daily bars — Mon, Tue, Wed…
            return (0..<7).reversed().map { offset in
                let day = cal.date(byAdding: .day, value: -offset, to: today)!
                let usage = byDay[day] ?? .zero
                return ChartBucket(
                    id: ISO8601DateFormatter().string(from: day),
                    label: weekdayLabel.string(from: day),
                    usage: usage
                )
            }
        case .month:
            // 5 weekly bars — last 5 weeks aggregated by ISO week.
            // Each bar's label is the week's start date ("Mar 24", "Mar 31"…),
            // which gives breathing room and a real signal vs 30 thin daily bars.
            let weekRangeFmt: DateFormatter = {
                let f = DateFormatter()
                f.timeZone = cal.timeZone
                f.dateFormat = "MMM d"
                return f
            }()
            return (0..<5).reversed().map { offset in
                let weekStart = cal.date(byAdding: .day, value: -offset * 7 - 6, to: today)!
                let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart)!
                var usage = TokenUsage.zero
                for (day, dayUsage) in byDay where day >= weekStart && day <= weekEnd {
                    usage += dayUsage
                }
                return ChartBucket(
                    id: ISO8601DateFormatter().string(from: weekStart),
                    label: weekRangeFmt.string(from: weekStart),
                    usage: usage
                )
            }
        case .year:
            // 12 monthly bars
            return (0..<12).reversed().map { offset in
                let monthStart = cal.date(byAdding: .month, value: -offset, to: today)!
                let comps = cal.dateComponents([.year, .month], from: monthStart)
                let firstOfMonth = cal.date(from: comps)!
                let nextMonth = cal.date(byAdding: .month, value: 1, to: firstOfMonth)!
                var usage = TokenUsage.zero
                for (day, dayUsage) in byDay where day >= firstOfMonth && day < nextMonth {
                    usage += dayUsage
                }
                return ChartBucket(
                    id: ISO8601DateFormatter().string(from: firstOfMonth),
                    label: monthLabel.string(from: firstOfMonth),
                    usage: usage
                )
            }
        case .all:
            return []
        }
    }

    // MARK: - Per-project

    private var projectBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top projects")
                .font(.system(size: 14, weight: .semibold))
                .padding(.bottom, 12)

            ForEach(cachedTopProjects) { project in
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text((project.projectCwd as NSString).lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                        Text("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text(UsageAggregator.format(project.usage.total))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 10)

                if project.id != cachedTopProjects.last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Heatmap helpers

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// Cached formatters for the heatmap. Marked nonisolated(unsafe) for the same
/// reason as elsewhere — DateFormatter is read-safe but not Sendable in the SDK.
enum HeatmapDateFormatter {
    nonisolated(unsafe) static let full: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.dateFormat = "EEE, MMM d yyyy"
        return f
    }()
    nonisolated(unsafe) static let month: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.dateFormat = "MMM"
        return f
    }()
}

// MARK: - Canvas-rendered heatmap (one draw call, fully responsive)

/// Renders all 364 day cells + month/weekday labels as a single Canvas paint.
/// Sizes itself to whatever width the parent gives it — never overflows, never
/// pushes siblings, and re-renders are O(1) regardless of cell count.
private struct HeatmapCanvasView: View {
    let cells: [UsageView.HeatmapCell]

    private let cellGap: CGFloat = 3
    private let weekdayLabelWidth: CGFloat = 26
    private let monthLabelHeight: CGFloat = 14
    private let labelGap: CGFloat = 6
    private let weekdayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]

    var body: some View {
        Canvas { context, size in
            let weeks = cells.chunked(into: 7)
            let weekCount = weeks.count
            guard weekCount > 0 else { return }

            // Available drawing area for the squares
            let gridLeft = weekdayLabelWidth + labelGap
            let gridTop = monthLabelHeight
            let gridWidth = max(0, size.width - gridLeft)
            let gridHeight = max(0, size.height - gridTop)

            // Cell side: divide width across all weeks (gaps included), then clamp
            let totalGaps = CGFloat(weekCount - 1) * cellGap
            let widthByWeeks = (gridWidth - totalGaps) / CGFloat(weekCount)
            let heightByDays = (gridHeight - 6 * cellGap) / 7
            let cellSize = max(4, min(widthByWeeks, heightByDays))

            // — Day cells —
            for (wIdx, week) in weeks.enumerated() {
                let x = gridLeft + CGFloat(wIdx) * (cellSize + cellGap)
                for (dIdx, cell) in week.enumerated() {
                    if cell.isPlaceholder { continue }
                    let y = gridTop + CGFloat(dIdx) * (cellSize + cellGap)
                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    context.fill(path, with: .color(Self.color(for: cell.level)))
                }
            }

            // — Weekday labels (Mon, Wed, Fri) —
            for (i, label) in weekdayLabels.enumerated() where !label.isEmpty {
                let y = gridTop + CGFloat(i) * (cellSize + cellGap) + cellSize / 2
                let text = Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                context.draw(text, at: CGPoint(x: 0, y: y), anchor: .leading)
            }

            // — Month labels above the first week of each month —
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            var lastMonth = -1
            for (wIdx, week) in weeks.enumerated() {
                guard let firstReal = week.first(where: { !$0.isPlaceholder }) else { continue }
                let month = cal.component(.month, from: firstReal.date)
                if month != lastMonth {
                    lastMonth = month
                    let label = HeatmapDateFormatter.month.string(from: firstReal.date)
                    let x = gridLeft + CGFloat(wIdx) * (cellSize + cellGap)
                    let text = Text(label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    context.draw(text, at: CGPoint(x: x, y: monthLabelHeight - 4), anchor: .bottomLeading)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 124)  // fixed height keeps the card layout stable
    }

    /// Resolved into concrete colors so they survive Canvas rendering
    /// (which can't always evaluate dynamic Color materials).
    private static func color(for level: Int) -> Color {
        switch level {
        case 0: return Color.gray.opacity(0.18)
        case 1: return Color.accentColor.opacity(0.35)
        case 2: return Color.accentColor.opacity(0.55)
        case 3: return Color.accentColor.opacity(0.78)
        default: return Color.accentColor
        }
    }
}

// MARK: - Shimmer placeholder (shared loading affordance)

/// A subtle horizontal-sweep gradient that signals "data is loading here".
/// Cheap and cohesive with the rest of the dark UI.
private struct ShimmerBox: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.04))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color.primary.opacity(0.06), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: phase * geo.size.width * 1.4)
                }
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
