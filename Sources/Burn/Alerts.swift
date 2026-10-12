import Foundation
import UserNotifications

enum Period: String, CaseIterable {
    case day, week, month

    var name: String {
        switch self { case .day: return "daily"; case .week: return "weekly"; case .month: return "monthly" }
    }
    var phrase: String {
        switch self { case .day: return "today"; case .week: return "this week"; case .month: return "this month" }
    }

    /// Weeks follow the calendar's firstWeekday.
    func interval(_ date: Date, _ cal: Calendar = .current) -> DateInterval {
        let unit: Calendar.Component
        switch self { case .day: unit = .day; case .week: unit = .weekOfYear; case .month: unit = .month }
        return cal.dateInterval(of: unit, for: date)!
    }
    func start(_ date: Date, _ cal: Calendar = .current) -> Date { interval(date, cal).start }
}

enum Alerts {
    struct Due: Equatable {
        let key: String
        let period: Period
        let spent: Double
        let threshold: Double
        let unpriced: Bool
        var test = false

        static var sample: Due {
            Due(key: "test", period: .day, spent: 52.10, threshold: 50, unpriced: false, test: true)
        }

        var body: String {
            let limit = threshold.formatted(.currency(code: "USD").precision(.fractionLength(threshold == threshold.rounded() ? 0 : 2)))
            return "\(usd(spent)) \(period.phrase). " + (test ? "Test: over" : "Over") + " your \(limit) \(period.name) alert."
                + (unpriced ? " Plus unpriced usage." : "")
        }
    }

    /// A fired record survives only while its period is current and its amount unchanged, which
    /// both prunes the list and re-arms an alert whose amount changed.
    static func check(now: Date, cal: Calendar, amounts: [Period: Double],
                      spent: [Period: Summary], fired: [String]) -> (due: [Due], fired: [String]) {
        var due: [Due] = []
        var keep: [String] = []
        for p in Period.allCases {
            guard let amount = amounts[p] else { continue }
            let range = p.interval(now, cal)
            let prefix = "\(p.rawValue)|\(Int(range.start.timeIntervalSince1970))|\(amount)|"
            keep += fired.filter { $0.hasPrefix(prefix) }
            // The suffix named the source when there was a choice; kept so records made then stay valid.
            let key = prefix + "claude-code"
            guard let s = spent[p], s.cost >= amount, !fired.contains(key) else { continue }
            keep.append(key)
            due.append(Due(key: key, period: p, spent: s.cost, threshold: amount,
                           unpriced: s.unpricedTokens > 0))
        }
        return (due, keep)
    }
}

/// Main thread only.
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var status: UNAuthorizationStatus?
    @Published var error = ""
    var report: (String) -> Void = { _ in }

    // current() raises outside an app bundle, so a bare `swift run` only dies once alerts are used.
    private lazy var center: UNUserNotificationCenter = {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        return c
    }()

    func refreshStatus() {
        center.getNotificationSettings { s in DispatchQueue.main.async { self.status = s.authorizationStatus } }
    }

    func authorize(then: (() -> Void)? = nil) {
        center.requestAuthorization(options: [.alert]) { _, err in
            DispatchQueue.main.async {
                self.error = err.map { "Authorization failed: \($0.localizedDescription)" } ?? ""
                self.refreshStatus()
                then?()
            }
        }
    }

    func send(_ alert: Alerts.Due) {
        post(alert.key, alert.body) { self.report($0) }
    }

    func test(_ alert: Alerts.Due) {
        authorize { self.post(alert.key, alert.body) { self.error = $0 } }
    }

    private func post(_ id: String, _ body: String, failed: @escaping (String) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Burn"
        // Silent, because Burn plays the chosen sound once per batch itself.
        content.body = body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { err in
            guard let err else { return }
            DispatchQueue.main.async { failed("Notification not sent: \(err.localizedDescription)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
