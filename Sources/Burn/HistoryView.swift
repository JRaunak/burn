import Charts
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var h: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            HStack(spacing: 24) {
                stat("Total", usd(h.summary.cost))
                stat("Tokens", tokens(h.summary.tokens))
                stat("Active days", "\(h.chart.activeDays)")
                if h.summary.unpricedTokens > 0 {
                    VStack(alignment: .leading) {
                        Label("Unpriced tokens", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(tokens(h.summary.unpricedTokens)).font(.title2).monospacedDigit()
                    }
                    .help("No price for \(h.summary.unpricedModels.joined(separator: ", ")). Add them to pricing.json.")
                }
                if model.scanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading transcripts, totals partial").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .opacity(h.loaded ? 1 : 0.5)

            if h.loaded && h.summary.tokens == 0 {
                ContentUnavailableView("No usage", systemImage: "chart.bar", description: Text(range))
            } else {
                Group {
                    if h.loaded && h.chart.rows.isEmpty {
                        ContentUnavailableView("No prices", systemImage: "exclamationmark.triangle",
                                               description: Text("Every model in \(range) is unpriced: \(h.summary.unpricedModels.joined(separator: ", ")). Add them to pricing.json."))
                    } else {
                        DailyChart(h: h)
                    }
                }
                .frame(height: 220)
                sessions
            }

            Text(Sources.caveat + " A \"+\" means some tokens have no price.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 600)
        .onAppear(perform: load)
        .onChange(of: h.filter) { load() }
        .onChange(of: h.filter.agent) { h.columns[visibility: "subagent"] = h.filter.agent == .all ? .automatic : .hidden }
        .onChange(of: model.today.cost) { load() }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if h.sessionCount > h.sessions.count {
                Text("Top \(h.sessions.count) of \(h.sessionCount) sessions").font(.caption).foregroundStyle(.secondary)
            }
            Table(h.sessions, sortOrder: $h.sortOrder, columnCustomization: $h.columns) {
                TableColumn("First in range", value: \.start) { Text($0.start, format: .dateTime.day().month().hour().minute()) }
                    .width(min: 110, ideal: 120)
                TableColumn("Project", value: \.project)
                TableColumn("Session") { s in
                    Button(String(s.id.prefix(8))) { h.filter.session = h.filter.session == s.id ? "" : s.id }
                        .buttonStyle(.link)
                }
                .width(80)
                TableColumn("Messages", value: \.messages) { Text($0.messages, format: .number).monospacedDigit() }
                    .width(70).alignment(.numeric)
                TableColumn("Subagent share") { s in
                    Text(s.cost > 0 ? s.subagentShare.formatted(.percent.precision(.fractionLength(0))) : "–").monospacedDigit()
                }
                .width(95).alignment(.numeric).customizationID("subagent")
                TableColumn("Cost", value: \.cost) { s in
                    HStack(spacing: 0) {
                        Text(usd(s.cost))
                        Text("+").opacity(s.unpricedTokens > 0 ? 1 : 0).accessibilityHidden(s.unpricedTokens == 0)
                    }
                    .monospacedDigit()
                }
                .width(80).alignment(.numeric)
            }
        }
        .opacity(h.loaded ? 1 : 0.5)
    }

    private var range: String {
        let cal = Calendar.current
        return (cal.startOfDay(for: h.filter.from)..<cal.startOfDay(for: h.filter.to ?? Date()))
            .formatted(.interval.day().month(.abbreviated).year())
    }

    private var filters: some View {
        HStack {
            dateButton("From", $h.filter.from, in: .distantPast...(h.filter.to ?? Date()), shown: $h.pickingFrom)
            dateButton("To", toDate, in: h.filter.from...Date(), shown: $h.pickingTo)
            Picker("Project", selection: $h.filter.project) {
                Text("All").tag("")
                ForEach(h.projects, id: \.self) { Text($0).tag($0) }
            }
            Picker("Model", selection: $h.filter.model) {
                Text("All").tag("")
                ForEach(h.models, id: \.self) { Text($0).tag($0) }
            }
            Picker("Agent", selection: $h.filter.agent) {
                ForEach(Filter.Agent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if !h.filter.session.isEmpty {
                Button("Session \(h.filter.session.prefix(8)) ✕") { h.filter.session = "" }
            }
        }
        .controlSize(.small)
    }

    /// Picking today stores nil, so the range keeps following today.
    private var toDate: Binding<Date> {
        Binding(get: { h.filter.to ?? Date() },
                set: { h.filter.to = Calendar.current.isDateInToday($0) ? nil : $0 })
    }

    /// A calendar in a popover, because NSDatePicker's text field clips two-digit days and fills the edited segment with the accent colour.
    private func dateButton(_ title: String, _ date: Binding<Date>, in range: ClosedRange<Date>, shown: Binding<Bool>) -> some View {
        LabeledContent(title) {
            Button { shown.wrappedValue = true } label: {
                Text(date.wrappedValue, format: .dateTime.day().month(.abbreviated).year()).monospacedDigit()
            }
            .popover(isPresented: shown) {
                DatePicker(title, selection: Binding(get: { date.wrappedValue }, set: { date.wrappedValue = $0; shown.wrappedValue = false }),
                           in: range, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().padding(8)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
        }
    }

    private func load() { h.load(model.db) }
}

struct DailyChart: View {
    @ObservedObject var h: HistoryModel

    var body: some View {
        let c = h.chart
        Chart {
            ForEach(c.rows) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("USD", d.cost))
                    .foregroundStyle(by: .value("Model", d.model))
            }
            ForEach(c.unpricedDays, id: \.self) { day in
                PointMark(x: .value("Day", day, unit: .day), y: .value("USD", c.totals[day] ?? 0))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 2) {
                        Text("+").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Has unpriced tokens")
                    }
            }
            if let day = h.selectedDay.map(Calendar.current.startOfDay), let total = c.totals[day] {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        DayDetail(day: day, rows: c.rows.filter { $0.day == day }, total: total, unpriced: c.unpricedDays.contains(day))
                    }
            }
        }
        .chartXScale(domain: c.domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: c.span <= 14 ? 1 : 7)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks {
                AxisGridLine()
                // Whole dollars would repeat labels on a chart whose ticks are under $1 apart.
                AxisValueLabel(format: .currency(code: "USD").precision(.fractionLength(c.maxTotal >= 10 ? 0 : 2)))
            }
        }
        .chartForegroundStyleScale(domain: c.models, range: c.models.indices.map { $0 < palette.count ? palette[$0] : Color(nsColor: .systemGray) })
        .chartLegend(position: .top, alignment: .leading)
        .chartXSelection(value: $h.selectedDay)
    }
}

private struct DayDetail: View {
    let day: Date
    let rows: [DayCost]
    let total: Double
    let unpriced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day, format: .dateTime.weekday().day().month(.abbreviated)).bold()
            ForEach(rows) { r in
                HStack { Text(r.model); Spacer(); Text(usd(r.cost)).monospacedDigit() }
            }
            Divider()
            HStack { Text("Total"); Spacer(); Text(usd(total) + (unpriced ? "+" : "")).monospacedDigit() }.bold()
        }
        .font(.caption)
        .frame(width: 200)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Fixed per rank, so a model keeps its colour while hovering and across reloads of the same range.
private let palette: [Color] = [
    (0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70), (0xeda100, 0xc98500), (0xe87ba4, 0xd55181),
].map { light, dark in
    Color(nsColor: NSColor(name: nil) { a in
        let v = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat(v >> 16) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    })
}

/// Chart rows with everything past the top five models merged into "Other".
struct DailyData {
    var rows: [DayCost] = []
    var models: [String] = []
    var totals: [Date: Double] = [:]
    var unpricedDays: [Date] = []
    var domain = Date()...Date()
    var span = 1
    var maxTotal = 0.0
    var activeDays: Int { Set(totals.keys).union(unpricedDays).count }

    init() {}

    init(_ daily: [DayCost], unpriced: Set<Date>, _ f: Filter) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: f.from)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: f.to ?? Date()))!
        domain = start...end
        span = cal.dateComponents([.day], from: start, to: end).day ?? 1

        let ranked = Dictionary(daily.map { ($0.model, $0.cost) }, uniquingKeysWith: +).sorted { $0.value > $1.value }.map(\.key)
        let top = Array(ranked.prefix(5))
        var other: [Date: Double] = [:]
        for d in daily where !top.contains(d.model) { other[d.day, default: 0] += d.cost }
        models = top + (other.isEmpty ? [] : ["Other"])
        rows = top.flatMap { m in daily.filter { $0.model == m } }
            + other.sorted { $0.key < $1.key }.map { DayCost(day: $0.key, model: "Other", cost: $0.value) }
        totals = Dictionary(daily.map { ($0.day, $0.cost) }, uniquingKeysWith: +)
        maxTotal = totals.values.max() ?? 0
        unpricedDays = unpriced.sorted()
    }
}

/// Holds view state in an ObservableObject because the CLT SDK lacks the plugin behind SwiftUI's @State macro.
final class HistoryModel: ObservableObject {
    @Published var filter = Filter()
    @Published var selectedDay: Date?
    @Published var pickingFrom = false
    @Published var pickingTo = false
    @Published var sortOrder = [KeyPathComparator(\SessionRow.cost, order: .reverse)] {
        didSet { sessions.sort(using: sortOrder) }
    }
    @Published var columns = TableColumnCustomization<SessionRow>()
    @Published var summary = Summary()
    @Published var chart = DailyData()
    @Published var sessions: [SessionRow] = []
    @Published var sessionCount = 0
    @Published var projects: [String] = []
    @Published var models: [String] = []
    /// The filter the data above was loaded for.
    @Published private var shown: Filter?

    var loaded: Bool { shown == filter }

    func load(_ db: DB) {
        let f = filter
        DispatchQueue.global(qos: .userInitiated).async {
            let r = db.queue.sync {
                (Q.summary(db, f), Q.daily(db, f), Q.unpricedDays(db, f), Q.sessions(db, f), Q.sessionCount(db, f),
                 Q.distinct(db, "project"), Q.distinct(db, "model"))
            }
            let chart = DailyData(r.1, unpriced: r.2, f)
            DispatchQueue.main.async {
                guard f == self.filter else { return }
                if self.shown != f { self.selectedDay = nil }
                (self.summary, self.chart, self.sessionCount, self.projects, self.models) = (r.0, chart, r.4, r.5, r.6)
                self.sessions = r.3.sorted(using: self.sortOrder)
                self.shown = f
            }
        }
    }
}
