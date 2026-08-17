import Foundation
import AppKit

enum DayStatus {
    case complete
    case partial
    case empty
}

struct Punch: Codable, Hashable, Identifiable {
    let time: String
    let type: String
    var id: String { "\(type)-\(time)" }
}

struct DayData: Hashable, Codable, Identifiable {
    let date: String
    let dmy: String
    let punches: [Punch]
    var id: String { date }

    var hasIn: Bool { punches.contains { $0.type == "in" } }
    var hasOut: Bool { punches.contains { $0.type == "out" } }
    var status: DayStatus {
        if punches.isEmpty { return .empty }
        let inCount = punches.filter { $0.type == "in" }.count
        let outCount = punches.filter { $0.type == "out" }.count
        return inCount == outCount ? .complete : .partial
    }
}

struct WeekData: Codable {
    let employeeName: String
    let presenceStatus: String
    let lastPunchDirection: String
    let lastPunchDate: String?
    let weekStart: String
    let days: [DayData]
}

struct DayVM: Identifiable {
    let index: Int
    let date: Date
    let weekday: String
    let dateLabel: String
    let dmy: String
    let isToday: Bool
    let punches: [Punch]
    let status: DayStatus
    let isVacation: Bool
    let isHoliday: Bool
    let isBankHoliday: Bool
    let shiftShortName: String?
    var id: Int { index }

    var isFuture: Bool {
        Calendar.current.startOfDay(for: Date()) < date
    }
}

struct CalendarDayVM: Identifiable {
    let id: Int
    let date: Date
    let dayNumber: Int
    let weekday: String
    let isHoliday: Bool
    let isBankHoliday: Bool
    let holidayDescription: String
    let isVacation: Bool
    let shiftName: String?
    let shiftShortName: String?
    let isAbsenceDay: Bool
    let isAbsenceHours: Bool
    let isToday: Bool
}

struct LogEntry: Identifiable, Equatable {
    enum Level {
        case info
        case success
        case error
    }

    let id = UUID()
    let timestamp = Date()
    let text: String
    let level: Level
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var week: WeekData?
    @Published var logs: [LogEntry] = []
    @Published var isBusy = false
    @Published var isRefreshing = false
    @Published var isSigningIn = false
    @Published var loginFeedback: String?
    @Published var loginFeedbackIsError = false
    @Published var isStale = false
    @Published var schedulerRunning = false
    @Published var weekStart: Date
    @Published var selectedTab = 0
    @Published var calendarMonthStart: Date
    @Published var accruals: [HolidayAccrual] = []
    @Published var calendarDays: [CalendarDayData] = []
    @Published var vacationDates: Set<Date> = []
    @Published var alerts: [VTAlert] = []
    @Published var isVacationLoading = false
    @Published var isAlertsLoading = false

    /// Calendar months already fetched (key = year * 12 + month - 1), so switching
    /// months never triggers a network round-trip.
    private var calendarFetchedMonths: Set<Int> = []

    private var scheduledTimers: [Timer] = []
    private var dayReArmTimer: Timer?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let sessionKeychainKey = "vtSession"

    private init() {
        weekStart = Self.monday(of: Date())
        calendarMonthStart = Self.firstOfMonth(of: Date())
        week = Self.loadCachedWeek()
    }

    private let api = VTAPIClient()
    private var cachedSession: Session?

    /// Returns the cached session, or a previously persisted one, or logs in once.
    /// Persisted tokens may be stale; callers retry via `withSession` on auth failure.
    private func requireSession() async throws -> Session {
        if let cachedSession { return cachedSession }
        if let data = Keychain.load(key: Self.sessionKeychainKey),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            cachedSession = session
            return session
        }
        return try await loginAndCache()
    }

    private func loginAndCache() async throws -> Session {
        appendLog("Logging in...", level: .info)
        let session = try await api.login(try ProjectFiles.loadCredentials())
        appendLog("Logged in as: \(session.employeeName) · \(session.presenceStatus)", level: .success)
        cachedSession = session
        if let data = try? JSONEncoder().encode(session) {
            _ = Keychain.save(key: Self.sessionKeychainKey, data: data)
        }
        return session
    }

    private func invalidateSession() {
        cachedSession = nil
        Keychain.delete(key: Self.sessionKeychainKey)
    }

    /// Runs `operation` with a session, re-logging in once after an early failure
    /// (expired token). Only used for read-only operations — never for punches,
    /// which must not be retried.
    private func withSession<T>(_ operation: (Session) async throws -> T) async throws -> T {
        do {
            return try await operation(try await requireSession())
        } catch {
            invalidateSession()
            return try await operation(try await requireSession())
        }
    }

    // MARK: - Week data

    var dayVMs: [DayVM] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = Self.monday(of: weekStart)
        let fmtWeekday = { (d: Date) -> String in
            Self.dateFormatter.dateFormat = "EEE"
            return Self.dateFormatter.string(from: d)
        }
        let fmtDate = { (d: Date) -> String in
            Self.dateFormatter.dateFormat = "d MMM"
            return Self.dateFormatter.string(from: d)
        }
        let dmy = { (d: Date) -> String in
            let c = cal.dateComponents([.day, .month, .year], from: d)
            return String(format: "%02d/%02d/%04d", c.day!, c.month!, c.year!)
        }

        let punchByDate: [String: [Punch]] = Dictionary(
            uniqueKeysWithValues: (week?.days ?? []).map { ($0.date, $0.punches) }
        )

        let calendarByDate: [Date: CalendarDayData] = Dictionary(
            uniqueKeysWithValues: calendarDays.map { (cal.startOfDay(for: $0.date), $0) }
        )

        return (0..<5).map { i in
            let date = cal.date(byAdding: .day, value: i, to: start)!
            let iso = Self.dateFormatter.ymd(from: date)
            let punches = punchByDate[iso] ?? []
            let calendarDay = calendarByDate[cal.startOfDay(for: date)]
            return DayVM(
                index: i,
                date: date,
                weekday: fmtWeekday(date),
                dateLabel: fmtDate(date),
                dmy: dmy(date),
                isToday: cal.isDate(date, inSameDayAs: today),
                punches: punches,
                status: DayStatus(from: punches),
                isVacation: vacationDates.contains(cal.startOfDay(for: date)),
                isHoliday: calendarDay?.isHoliday ?? false,
                isBankHoliday: calendarDay?.isBankHoliday ?? false,
                shiftShortName: calendarDay?.shiftShortName
            )
        }
    }

    var weekRangeLabel: String {
        let cal = Calendar.current
        let start = Self.monday(of: weekStart)
        let end = cal.date(byAdding: .day, value: 4, to: start)!
        Self.dateFormatter.dateFormat = "d MMM yyyy"
        let s = Self.dateFormatter.string(from: start)
        let e = Self.dateFormatter.string(from: end)
        let startYear = cal.component(.year, from: start)
        let endYear = cal.component(.year, from: end)
        if startYear == endYear {
            Self.dateFormatter.dateFormat = "d MMM"
            return "\(Self.dateFormatter.string(from: start)) – \(e)"
        }
        return "\(s) – \(e)"
    }

    // MARK: - Navigation

    func goToday() {
        weekStart = Self.monday(of: Date())
        Task { await refresh() }
    }

    func goPreviousWeek() {
        weekStart = Calendar.current.date(byAdding: .day, value: -7, to: Self.monday(of: weekStart))!
        Task { await refresh() }
    }

    func goNextWeek() {
        weekStart = Calendar.current.date(byAdding: .day, value: 7, to: Self.monday(of: weekStart))!
        Task { await refresh() }
    }

    // MARK: - Week refresh

    func refresh() async {
        let cal = Calendar.current
        let start = Self.monday(of: weekStart)
        let c = cal.dateComponents([.day, .month, .year], from: start)
        let dmy = "\(c.day!)/\(c.month!)/\(c.year!)"

        do {
            isRefreshing = true
            appendLog("Refreshing \(dmy)…")

            let (session, days, calDays, requests): (Session, [DayData], [CalendarDayData], [VacationRequest]) = try await withSession { session in
                var days: [DayData] = []
                var monthStarts: [Date] = []
                for i in 0..<5 {
                    let day = cal.date(byAdding: .day, value: i, to: start)!
                    let dayDMY = Self.dmyString(day)
                    monthStarts.append(Self.firstOfMonth(of: day))
                    let punches = try await api.getMyPunches(session, date: dayDMY)
                    days.append(DayData(
                        date: Self.dateFormatter.ymd(from: day),
                        dmy: dayDMY,
                        punches: punches
                            .sorted { PunchFormat.ms($0.dateTime) < PunchFormat.ms($1.dateTime) }
                            .map { Punch(time: PunchFormat.wallTime($0.dateTime), type: $0.actualType == 1 ? "in" : "out") }
                    ))
                }
                let weekMonthStarts = Array(Set(monthStarts))
                async let calDays = self.fetchCalendarMonths(session, months: weekMonthStarts)
                async let requests = self.api.getMyRequests(session, selectedDate: Self.dmyString(start))
                return (session, days, try await calDays, try await requests)
            }

            let fresh = WeekData(
                employeeName: session.employeeName,
                presenceStatus: session.presenceStatus,
                lastPunchDirection: session.lastPunchDirection,
                lastPunchDate: session.lastPunchDate.map { $0.description },
                weekStart: Self.dateFormatter.ymd(from: start),
                days: days
            )
            week = fresh
            isStale = false
            mergeCalendarDays(calDays)
            vacationDates = Self.parseVacationDates(from: requests)
            Self.saveCachedWeek(fresh)
        } catch {
            appendLog(error.localizedDescription, level: .error)
            if week != nil {
                isStale = true
            }
        }
        isRefreshing = false
    }

    // MARK: - Punch in/out

    func punch(_ direction: String) {
        isBusy = true
        appendLog("Clocking \(direction)...")
        Task {
            do {
                let session = try await requireSession()
                let result = try await api.punch(session, direction: direction)
                appendLog("Clocked \(direction)! Status: \(result.status)", level: .success)
            } catch {
                invalidateSession()
                appendLog("Clock \(direction) failed: \(error.localizedDescription)", level: .error)
            }
            isBusy = false
            await refresh()
        }
    }

    // MARK: - Sign in

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        loginFeedback = nil
        appendLog("Logging in...", level: .info)
        Task { @MainActor in
            do {
                let session = try await loginAndCache()
                loginFeedback = "Signed in — \(session.employeeName) · \(session.presenceStatus)"
                loginFeedbackIsError = false
                appendLog("Signed in", level: .success)
                await refresh()
            } catch {
                invalidateSession()
                loginFeedback = "Sign-in failed: \(error.localizedDescription)"
                loginFeedbackIsError = true
                appendLog("Sign-in failed: \(error.localizedDescription)", level: .error)
            }
            isSigningIn = false
        }
    }

    func clearLoginFeedback() {
        loginFeedback = nil
        loginFeedbackIsError = false
    }

    // MARK: - Vacation / Alerts

    var calendarMonthLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: calendarMonthStart)
    }

    /// Calendar cells for the displayed month, one per day, aligned to a Sunday-first grid.
    var monthDayVMs: [CalendarDayVM] {
        let cal = Calendar.current
        // Portal PlanDates resolve to 23:00 local (encoded one hour ahead of the
        // local zone), so key by start-of-day to match the grid's midnight dates.
        let byDate = Dictionary(uniqueKeysWithValues: calendarDays.map { (cal.startOfDay(for: $0.date), $0) })
        let daysInMonth = cal.range(of: .day, in: .month, for: calendarMonthStart)?.count ?? 30
        let leadingBlanks = (cal.component(.weekday, from: calendarMonthStart) - 1 + 7) % 7
        let trailingBlanks = (7 - ((leadingBlanks + daysInMonth) % 7)) % 7

        let today = cal.startOfDay(for: Date())
        let total = leadingBlanks + daysInMonth + trailingBlanks

        return (0..<total).map { index in
            let dayNumber = index - leadingBlanks + 1
            if dayNumber < 1 || dayNumber > daysInMonth {
                return CalendarDayVM(
                    id: index, date: calendarMonthStart, dayNumber: 0, weekday: "",
                    isHoliday: false, isBankHoliday: false, holidayDescription: "", isVacation: false,
                    shiftName: nil, shiftShortName: nil,
                    isAbsenceDay: false, isAbsenceHours: false, isToday: false
                )
            }
            let date = cal.date(byAdding: .day, value: dayNumber - 1, to: calendarMonthStart)!
            let day = byDate[cal.startOfDay(for: date)]
            return CalendarDayVM(
                id: index,
                date: date,
                dayNumber: dayNumber,
                weekday: day?.weekday ?? "",
                isHoliday: day?.isHoliday ?? false,
                isBankHoliday: day?.isBankHoliday ?? false,
                holidayDescription: day?.holidayDescription ?? "",
                isVacation: vacationDates.contains(cal.startOfDay(for: date)),
                shiftName: day?.shiftName,
                shiftShortName: day?.shiftShortName,
                isAbsenceDay: day?.isAbsenceDay ?? false,
                isAbsenceHours: day?.isAbsenceHours ?? false,
                isToday: cal.isDate(date, inSameDayAs: today)
            )
        }
    }

    func refreshVacation() async {
        guard !isVacationLoading else { return }
        isVacationLoading = true
        defer { isVacationLoading = false }
        do {
            let dateString = Self.dmyString(calendarMonthStart)
            let (accruals, days, requests): ([HolidayAccrual], [CalendarDayData], [VacationRequest]) = try await withSession { session in
                async let a = self.api.getAccrualsSummary(session, selectedDate: dateString)
                async let c = self.fetchCalendarMonths(session)
                async let r = self.api.getMyRequests(session, selectedDate: dateString)
                return (try await a, try await c, try await r)
            }
            self.accruals = accruals
            self.mergeCalendarDays(days)
            self.vacationDates = Self.parseVacationDates(from: requests)
        } catch {
            appendLog("Vacation refresh failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// Fetches every calendar month from January of the current year through
    /// December of the next year (one parallel request per month) so the whole
    /// booked-vacation picture is available without per-month reloads.
    private func fetchCalendarMonths(_ session: Session) async throws -> [CalendarDayData] {
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        let monthsToFetch: [Date] = (thisYear...(thisYear + 1)).flatMap { year in
            (1...12).map { month in
                cal.date(from: DateComponents(year: year, month: month, day: 1))!
            }
        }
        return try await fetchCalendarMonths(session, months: monthsToFetch)
    }

    /// Fetches the calendar for the given month starts (skipping months already
    /// fetched) and returns only the newly retrieved days.
    private func fetchCalendarMonths(_ session: Session, months: [Date]) async throws -> [CalendarDayData] {
        var fetched: [CalendarDayData] = []
        try await withThrowingTaskGroup(of: (Int, [CalendarDayData]).self) { group in
            for monthStart in months {
                let key = calendarMonthKey(monthStart)
                if calendarFetchedMonths.contains(key) { continue }
                group.addTask { [api] in
                    do {
                        let days = try await api.getMyCalendar(session, selectedDate: Self.dmyString(monthStart))
                        return (key, days)
                    } catch {
                        return (key, [])
                    }
                }
            }
            for try await (key, days) in group {
                if !days.isEmpty {
                    fetched.append(contentsOf: days)
                    calendarFetchedMonths.insert(key)
                }
            }
        }
        return fetched
    }

    /// Merges newly fetched calendar days into `calendarDays`, replacing any day
    /// already present for the same date.
    private func mergeCalendarDays(_ new: [CalendarDayData]) {
        guard !new.isEmpty else { return }
        var byDate = Dictionary(uniqueKeysWithValues: calendarDays.map { ($0.date, $0) })
        for day in new { byDate[day.date] = day }
        calendarDays = byDate.values.sorted { $0.date < $1.date }
    }

    private func calendarMonthKey(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.year, from: date) * 12 + cal.component(.month, from: date) - 1
    }

    /// Whether the currently displayed month already has calendar data in memory.
    private func hasCalendarData(for monthStart: Date) -> Bool {
        calendarFetchedMonths.contains(calendarMonthKey(monthStart))
    }

    func goPreviousMonth() {
        calendarMonthStart = Self.firstOfMonth(
            of: Calendar.current.date(byAdding: .month, value: -1, to: calendarMonthStart)!
        )
        if !hasCalendarData(for: calendarMonthStart) {
            Task { await refreshVacation() }
        }
    }

    func goNextMonth() {
        calendarMonthStart = Self.firstOfMonth(
            of: Calendar.current.date(byAdding: .month, value: 1, to: calendarMonthStart)!
        )
        if !hasCalendarData(for: calendarMonthStart) {
            Task { await refreshVacation() }
        }
    }
    func goCurrentMonth() {
        calendarMonthStart = Self.firstOfMonth(of: Date())
        if !hasCalendarData(for: calendarMonthStart) {
            Task { await refreshVacation() }
        }
    }

    func refreshAlerts() async {
        guard !isAlertsLoading else { return }
        isAlertsLoading = true
        defer { isAlertsLoading = false }
        do {
            let alerts = try await withSession { try await self.api.getUserNotifications($0) }
            self.alerts = alerts
        } catch {
            appendLog("Alerts refresh failed: \(error.localizedDescription)", level: .error)
        }
    }

    /// Alerts minus incomplete-punch notifications already handled via this app.
    var visibleAlerts: [VTAlert] {
        let handled = AppSettings.shared.handledPunchDates
        return alerts.filter { alert in
            guard let date = alert.backfillDate else { return true }
            return !handled.contains(Self.dateFormatter.ymd(from: date))
        }
    }

    /// Hides an incomplete-punch notification (used after manual backfill or manual dismiss).
    func dismissAlert(_ alert: VTAlert) {
        guard let date = alert.backfillDate else { return }
        AppSettings.shared.handledPunchDates.insert(Self.dateFormatter.ymd(from: date))
    }

    var urgentAlertCount: Int {
        visibleAlerts.filter { $0.isUrgent || $0.isCritic }.count
    }

// MARK: - Backfill

struct BackfillPlan: Identifiable {
    let id = UUID()
    let expectedTime: String    // "07:00"
    let direction: String       // "in" or "out"
    let status: Status
    var existingPunch: Punch?
    let isSubmittable: Bool     // only first IN + last OUT for portal justification
    let isDueNow: Bool          // time has passed (or past day)

    enum Status {
        case missing     // no punch near this time
        case covered     // existing punch matches
        case conflict    // existing punch nearby but different type
    }

    var display: String {
        let prefix = isSubmittable ? "" : "ℹ️ "
        let timeStatus = isSubmittable ? (isDueNow ? "⬜ Will submit now" : "⏳ Pending (after \(expectedTime))") : "⏭️ Skipped (not needed for justification)"
        switch status {
        case .missing:   return "\(prefix)\(timeStatus) \(direction.uppercased()) at \(expectedTime)"
        case .covered:   return "\(prefix)✅ \(direction.uppercased()) at \(expectedTime) already exists"
        case .conflict:  return "\(prefix)⚠️ Conflict at \(expectedTime): \(existingPunch?.type.uppercased() ?? "?") exists, would submit \(direction.uppercased())"
        }
    }

    var canSubmit: Bool { isSubmittable && status == .missing && isDueNow }
    var isProblem: Bool { isSubmittable && status == .conflict }
}

private func buildBackfillPlan(for date: Date, existing: [EmployeePunch], configs: [PunchConfig]) -> [BackfillPlan] {
    let cal = Calendar.current
    let isToday = cal.isDateInToday(date)
    let now = Date()
    let nowMins = isToday ? hourMinToMins(timeHM(now)) : Int.max  // past days = all due

    // Convert existing portal punches to local wall times
    let existingWall: [(time: String, type: String)] = existing.compactMap { p in
        guard let (ms, offset) = PunchFormat.wallClockDate(p.dateTime) else { return nil }
        let local = Date(timeIntervalSince1970: ms / 1000.0 + offset)
        let hm = String(PunchFormat.timeFormatter.string(from: local).prefix(5))
        let dir = p.actualType == 1 ? "in" : "out"
        return (hm, dir)
    }

    // Match each config to nearest existing punch (within 30 min)
    var usedExisting = Set<Int>()
    var plans: [BackfillPlan] = []

    // Only first (in) and last (out) are submittable for "forgot to punch" justification
    let firstIdx = configs.firstIndex { $0.type == "in" } ?? 0
    let lastIdx = configs.lastIndex { $0.type == "out" } ?? (configs.count - 1)
    let submittable = Set([firstIdx, lastIdx])

    for (configIdx, config) in configs.enumerated() {
        let expected = config.time
        let expectedMins = hourMinToMins(expected)
        let isSubmittable = submittable.contains(configIdx)
        let isDueNow = isSubmittable && expectedMins <= nowMins

        var bestIdx: Int?
        var bestDiff = 30

        for (i, ex) in existingWall.enumerated() {
            if usedExisting.contains(i) { continue }
            let exMins = hourMinToMins(ex.time)
            let diff = abs(exMins - expectedMins)
            if diff < bestDiff {
                bestDiff = diff
                bestIdx = i
            }
        }

        if let idx = bestIdx {
            let ex = existingWall[idx]
            usedExisting.insert(idx)
            if ex.type == config.type {
                plans.append(BackfillPlan(expectedTime: expected, direction: config.type, status: .covered, existingPunch: Punch(time: ex.time, type: ex.type), isSubmittable: isSubmittable, isDueNow: isDueNow))
            } else {
                plans.append(BackfillPlan(expectedTime: expected, direction: config.type, status: .conflict, existingPunch: Punch(time: ex.time, type: ex.type), isSubmittable: isSubmittable, isDueNow: isDueNow))
            }
        } else {
            let status: BackfillPlan.Status = isSubmittable ? .missing : .covered
            plans.append(BackfillPlan(expectedTime: expected, direction: config.type, status: status, existingPunch: nil, isSubmittable: isSubmittable, isDueNow: isDueNow))
        }
    }
    return plans
}

private func hourMinToMins(_ hm: String) -> Int {
    let parts = hm.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return 0 }
    return h * 60 + m
}

private func timeHM(_ date: Date) -> String {
    PunchFormat.timeFormatter.string(from: date)
}

@MainActor
private func showBackfillPreview(_ plans: [BackfillPlan], date: Date, dmy: String, onConfirm: @escaping ([BackfillPlan]) -> Void) {
    let alert = NSAlert()
    alert.messageText = "Backfill plan for \(dmy)"
    alert.informativeText = plans.map { $0.display }.joined(separator: "\n")
    let submitBtn = plans.contains { $0.canSubmit } ? "Submit due now" : "Nothing due yet"
    alert.addButton(withTitle: submitBtn)
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .informational

    // Add checkboxes for conflicts
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 120))
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    accessory.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
        stack.topAnchor.constraint(equalTo: accessory.topAnchor),
        stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
    ])

    var conflictCheckboxes: [(BackfillPlan, NSButton)] = []
    for plan in plans where plan.isProblem {
        let cb = NSButton(checkboxWithTitle: "Force submit \(plan.direction.uppercased()) at \(plan.expectedTime) despite conflict", target: nil, action: nil)
        cb.state = .off
        stack.addArrangedSubview(cb)
        conflictCheckboxes.append((plan, cb))
    }

    if !conflictCheckboxes.isEmpty {
        alert.accessoryView = accessory
    }

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        var toSubmit = plans.filter { $0.canSubmit }
        for (plan, cb) in conflictCheckboxes {
            if cb.state == .on { toSubmit.append(plan) }
        }
        if !toSubmit.isEmpty {
            onConfirm(toSubmit)
        }
    }
}

func backfill(_ day: DayVM) {
    backfillCore(date: day.date, dmy: day.dmy, isFuture: day.isFuture)
}

func backfill(date: Date) {
    backfillCore(date: date, dmy: Self.dmyString(date), isFuture: false)
}

private func backfillCore(date: Date, dmy: String, isFuture: Bool) {
    guard !isFuture else {
        appendLog("Cannot backfill a future day.", level: .error)
        return
    }
    let settings = AppSettings.shared
    guard settings.hasValidPunchConfig else {
        appendLog("No valid punch schedule configured. Open Settings to add punch times.", level: .error)
        return
    }
    isBusy = true
    appendLog("Analyzing \(dmy)...")
    Task {
        do {
            let session = try await requireSession()
            let existingPortal = try await api.getMyPunches(session, date: dmy)
            let plans = buildBackfillPlan(for: date, existing: existingPortal, configs: settings.punchConfigs)

            let missingCount = plans.filter { $0.canSubmit }.count
            let conflictCount = plans.filter { $0.isProblem }.count

            if missingCount == 0 && conflictCount == 0 {
                appendLog("All punches already submitted. Nothing to do.", level: .info)
                AppSettings.shared.handledPunchDates.insert(Self.dateFormatter.ymd(from: date))
                isBusy = false
                return
            }

            await MainActor.run {
                showBackfillPreview(plans, date: date, dmy: dmy) { confirmed in
                    Task { await self.executeBackfill(confirmed, date: date, dmy: dmy, session: session) }
                }
            }
        } catch {
            invalidateSession()
            appendLog("Backfill failed: \(error.localizedDescription)", level: .error)
            isBusy = false
        }
    }
}

private func executeBackfill(_ plans: [BackfillPlan], date: Date, dmy: String, session: Session) async {
    isBusy = true
    appendLog("Submitting \(plans.count) punch(es) for \(dmy)...")
    do {
        let delayNs: UInt64 = 4_000_000_000
        let isoDate = Self.dateFormatter.ymd(from: date)
        for (i, plan) in plans.enumerated() {
            if i > 0 {
                appendLog("waiting 4s...", level: .info)
                try await Task.sleep(nanoseconds: delayNs)
            }
            let punchDateTime = "\(isoDate) \(plan.expectedTime)"
            appendLog("[\(plan.direction.uppercased())] \(punchDateTime) ...", level: .info)
            let requestId = try await api.saveForbiddenPunch(session, punchDateTime: punchDateTime, direction: plan.direction)
            appendLog("OK (requestId: \(requestId))", level: .success)
        }
        appendLog("Done! All punches submitted for \(dmy).", level: .success)
        AppSettings.shared.handledPunchDates.insert(Self.dateFormatter.ymd(from: date))
    } catch {
        invalidateSession()
        appendLog("Backfill failed: \(error.localizedDescription)", level: .error)
    }
    isBusy = false
    await refresh()
    await refreshAlerts()
}

    // MARK: - Scheduler

    func startScheduler() {
        guard !schedulerRunning else {
            appendLog("Scheduler is already running.", level: .info)
            return
        }
        let settings = AppSettings.shared
        guard settings.hasValidPunchConfig else {
            appendLog("No valid punch schedule configured. Open Settings to add punch times.", level: .error)
            return
        }
        armDayScheduler(punches: settings.punchConfigs)
        schedulerRunning = true
        appendLog(
            "Scheduler started: \(settings.punchConfigs.count) punches/day, jitter up to 5 min.",
            level: .success
        )
    }

    func stopScheduler() {
        scheduledTimers.forEach { $0.invalidate() }
        dayReArmTimer?.invalidate()
        scheduledTimers.removeAll()
        dayReArmTimer = nil
        schedulerRunning = false
        appendLog("Scheduler stopped.", level: .info)
    }

    func shutdown() {
        if AppSettings.shared.stopSchedulerOnQuit {
            stopScheduler()
        }
    }

    private func armDayScheduler(punches: [PunchConfig]) {
        scheduledTimers.forEach { $0.invalidate() }
        dayReArmTimer?.invalidate()
        scheduledTimers.removeAll()

        let cal = Calendar.current
        let now = Date()
        let jitterMinutes = 5

        for punch in punches {
            guard punch.time.count == 5, let hour = Int(punch.time.prefix(2)), let minute = Int(punch.time.suffix(2)) else {
                appendLog("Skipping malformed punch time: \(punch.time)", level: .error)
                continue
            }
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let scheduled = cal.date(from: comps) else { continue }

            let jitterSeconds = TimeInterval.random(in: 0...(Double(jitterMinutes) * 60))
            let fireAt = scheduled.addingTimeInterval(jitterSeconds)
            guard fireAt > now else { continue }

            let timer = Timer(fireAt: fireAt, interval: 0, target: self, selector: #selector(schedulerFire(_:)), userInfo: punch, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            scheduledTimers.append(timer)
            appendLog("Scheduled \(punch.type.uppercased()) at \(punch.time) (jitter up to \(jitterMinutes) min).", level: .info)
        }

        // Re-arm at the start of each day.
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let rearm = Timer(fireAt: tomorrow.addingTimeInterval(60), interval: 0, target: self, selector: #selector(dayRollover(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(rearm, forMode: .common)
        dayReArmTimer = rearm
    }

    @objc private func schedulerFire(_ timer: Timer) {
        guard let punch = timer.userInfo as? PunchConfig else { return }
        appendLog("Executing punch \(punch.type.uppercased())...", level: .info)
        Task { [weak self] in
            await self?.executeScheduledPunch(punch)
        }
    }

    @objc private func dayRollover(_ timer: Timer) {
        guard schedulerRunning else { return }
        let settings = AppSettings.shared
        guard settings.hasValidPunchConfig else {
            appendLog("No valid punch schedule configured. Scheduler stopped.", level: .error)
            stopScheduler()
            return
        }
        armDayScheduler(punches: settings.punchConfigs)
    }

    private func executeScheduledPunch(_ punch: PunchConfig) async {
        do {
            let session = try await requireSession()
            let result = try await api.punch(session, direction: punch.type)
            appendLog("Punch \(punch.type.uppercased()) successful (status: \(result.status))", level: .success)
            await refresh()
        } catch {
            invalidateSession()
            appendLog("Scheduled punch error: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Log

    func clearLog() {
        logs.removeAll()
    }

    func appendLog(_ text: String, level: LogEntry.Level = .info) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for line in trimmed.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            logs.append(LogEntry(text: l, level: level))
        }
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    // MARK: - Formatting helpers

    static func monday(of date: Date) -> Date {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: startOfDay)
        let offset = (weekday + 5) % 7
        return cal.date(byAdding: .day, value: -offset, to: startOfDay)!
    }

    static func firstOfMonth(of date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps)!
    }

    static func dmyString(_ date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d/%02d/%04d", c.day!, c.month!, c.year!)
    }

    /// Builds the set of booked vacation days from GetMyRequests. The API does
    /// not return structured dates, so we parse the description text:
    ///   type 6  "Schedule PT Férias, from the 7/15/2026 until the 7/15/2026"
    ///   type 11 "Cancel PT Férias within the following period: 6/11/2026 and 6/12/2026"
    ///   type 13 "…the 1/30/2026 all the time" (half day)
    /// Accepted requests only (Status == 2). Bookings are unioned first, then
    /// cancellations subtract from that union.
    static func parseVacationDates(from requests: [VacationRequest]) -> Set<Date> {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "M/d/yyyy"

        func parse(_ token: String) -> Date? {
            fmt.date(from: token.trimmingCharacters(in: .whitespaces))
        }

        func range(_ a: Date, _ b: Date) -> [Date] {
            var dates: [Date] = []
            var d = Calendar.current.startOfDay(for: a)
            let end = Calendar.current.startOfDay(for: b)
            while d <= end {
                dates.append(d)
                d = Calendar.current.date(byAdding: .day, value: 1, to: d)!
            }
            return dates
        }

        let accepted = requests.filter(\.isAccepted)

        var booked: Set<Date> = []

        for r in accepted where r.idRequestType == 6 || r.idRequestType == 13 {
            let tokens = Self.dateTokens(in: r.description)
            if r.idRequestType == 6 {
                var i = 0
                while i + 1 < tokens.count {
                    if let a = parse(tokens[i]), let b = parse(tokens[i + 1]) {
                        booked.formUnion(range(a, b))
                    }
                    i += 2
                }
            } else if let token = tokens.first, let d = parse(token) {
                booked.insert(Calendar.current.startOfDay(for: d))
            }
        }

        for r in accepted where r.idRequestType == 11 {
            let tokens = Self.dateTokens(in: r.description)
            if tokens.count >= 2, let a = parse(tokens[0]), let b = parse(tokens[1]) {
                booked.subtract(range(a, b))
            }
        }

        return booked
    }

    /// Extracts every M/d/yyyy token from a request description, in order.
    static func dateTokens(in text: String) -> [String] {
        let pattern = #"\d{1,2}/\d{1,2}/\d{4}"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex?.matches(in: text, range: range) ?? []
        return matches.compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Week cache (disk)

    private static func cacheURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("VTReborn", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("week.json")
    }

    static func saveCachedWeek(_ week: WeekData) {
        guard let url = cacheURL(),
              let data = try? JSONEncoder().encode(week) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadCachedWeek() -> WeekData? {
        guard let url = cacheURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WeekData.self, from: data)
    }
}

extension DayStatus {
    init(from punches: [Punch]) {
        if punches.isEmpty {
            self = .empty
        } else {
            let inCount = punches.filter { $0.type == "in" }.count
            let outCount = punches.filter { $0.type == "out" }.count
            self = inCount == outCount ? .complete : .partial
        }
    }
}

extension DateFormatter {
    func ymd(from date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
