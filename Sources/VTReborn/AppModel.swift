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
    var status: DayStatus { DayStatus(from: punches) }
}

struct WeekData: Codable {
    let employeeName: String
    let presenceStatus: String
    let lastPunchDirection: String
    let lastPunchDate: String?
    let weekStart: String
    var days: [DayData]
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

    /// Vacation, holiday and bank-holiday days need no punches.
    var isNonWorking: Bool { isVacation || isHoliday || isBankHoliday }

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
    let shiftId: Int?
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
    @Published var sessionExpired = false
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
    @Published var isBookingVacation = false
    @Published var vacationBookingFeedback: String?
    @Published var vacationBookingFeedbackIsError = false
    @Published var selectedShiftId: Int?
    @Published var shiftDataLoadFailed = false
    /// Available days ("PT Férias" concept, day-based) shown by the portal as
    /// "Tem à sua disposição X dias para esta aplicação".
    @Published var availableHolidayDays: Double?

    /// Maximum number of vacation days that can still be booked this year.
    /// Portal-authoritative number when known; otherwise accrual minus already
    /// scheduled days.
    var availableBookableDays: Int? {
        if let available = availableHolidayDays {
            return max(Int(available.rounded(.down)), 0)
        }
        guard let accrual = accruals.first(where: {
            $0.name.localizedCaseInsensitiveContains("Férias pendentes")
                && !$0.name.localizedCaseInsensitiveContains("ano anterior")
        }) else { return nil }
        return max(accrual.available - scheduledVacationDaysThisYear, 0)
    }

    /// Scheduled (already booked) vacation days this year, from today onwards.
    private var scheduledVacationDaysThisYear: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thisYear = cal.component(.year, from: today)
        return vacationDates.reduce(into: 0) { count, date in
            let d = cal.startOfDay(for: date)
            if d >= today, cal.component(.year, from: d) == thisYear {
                count += 1
            }
        }
    }

    /// Calendar months already fetched (key = year * 12 + month - 1), so switching
    /// months never triggers a network round-trip.
    private var calendarFetchedMonths: Set<Int> = []

    /// When the loaded week was last confirmed against the portal.
    private var lastWeekRefresh: Date?
    /// A week refreshed this recently is trusted for the backfill preview.
    private static let freshWeekWindow: TimeInterval = 120

    /// Past days whose bookends are recorded. They can never change again, so
    /// they're persisted permanently and never re-fetched.
    private var settledDays: [String: DayData] = [:]

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
        loadCachedCalendar()
        loadSettledDays()
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

    /// Returns true when the API signalled that the session is no longer valid
    /// (e.g. it was stolen by a login elsewhere on the portal).
    private func isSessionExpiredError(_ error: Error) -> Bool {
        if case VTAPIError.sessionExpired = error { return true }
        return false
    }

    /// Clears the cached session and surfaces a re-login prompt so the user
    /// knows punches are failing because the session expired — not the network.
    private func handleSessionExpiry() {
        sessionExpired = true
        invalidateSession()
        appendLog("Session expired — please sign in again", level: .error)
    }

    func reLogin() {
        signIn()
    }

    /// Runs `operation` with a session, re-logging in once when the cached
    /// token has expired/stolen. Only used for read-only operations — never for
    /// punches, which must not be retried. Other errors propagate as-is.
    private func withSession<T>(_ operation: (Session) async throws -> T) async throws -> T {
        do {
            return try await operation(try await requireSession())
        } catch let error where isSessionExpiredError(error) {
            appendLog("Session expired — re-logging in...", level: .info)
            sessionExpired = false
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
            let nonWorking = isNonWorkingDay(date)
            return DayVM(
                index: i,
                date: date,
                weekday: fmtWeekday(date),
                dateLabel: fmtDate(date),
                dmy: dmy(date),
                isToday: cal.isDate(date, inSameDayAs: today),
                punches: punches,
                status: nonWorking && punches.isEmpty && date <= today
                    ? .complete
                    : DayStatus(from: punches, isToday: cal.isDate(date, inSameDayAs: today)),
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
        if showSettledWeekIfPossible() { return }
        let cal = Calendar.current
        let start = Self.monday(of: weekStart)
        let c = cal.dateComponents([.day, .month, .year], from: start)
        let dmy = "\(c.day!)/\(c.month!)/\(c.year!)"

        do {
            isRefreshing = true
            appendLog("Refreshing \(dmy)…")

            let (session, days, calDays, requests): (Session, [DayData], [CalendarDayData], [VacationRequest]) = try await withSession { session in
                let dates = (0..<5).map { cal.date(byAdding: .day, value: $0, to: start)! }
                let weekMonthStarts = Array(Set(dates.map { Self.firstOfMonth(of: $0) }))
                // Punches, calendar and requests are independent: run them all
                // concurrently so the refresh costs one round trip, not seven.
                async let calDays = self.fetchCalendarMonths(session, months: weekMonthStarts)
                async let requests = self.api.getMyRequests(session, selectedDate: Self.dmyString(start))
                let days = try await self.fetchDays(session, dates: dates)
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
            recordSettled(days)
            isStale = false
            lastWeekRefresh = Date()
            mergeCalendarDays(calDays)
            vacationDates = Self.parseVacationDates(from: requests)
            Self.saveCachedWeek(fresh)
        } catch {
            appendLog(error.localizedDescription, level: .error)
            if isSessionExpiredError(error) {
                handleSessionExpiry()
            }
            if week != nil {
                isStale = true
            }
        }
        isRefreshing = false
    }

    /// Fetches the given days' punches in parallel, returned in input order.
    /// Settled past days come straight from the local store with no request.
    private func fetchDays(_ session: Session, dates: [Date]) async throws -> [DayData] {
        try await withThrowingTaskGroup(of: (Int, DayData).self) { group in
            for (i, date) in dates.enumerated() {
                // Formatters are main-actor state; resolve labels before forking.
                let dmy = Self.dmyString(date)
                let iso = Self.dateFormatter.ymd(from: date)
                if let settled = settledDays[iso] {
                    group.addTask { (i, settled) }
                    continue
                }
                // Future days can't have punches yet; nothing to ask the portal.
                if date > Calendar.current.startOfDay(for: Date()) {
                    let empty = DayData(date: iso, dmy: dmy, punches: [])
                    group.addTask { (i, empty) }
                    continue
                }
                group.addTask { [api] in
                    let punches = try await api.getMyPunches(session, date: dmy)
                    return (i, DayData(
                        date: iso,
                        dmy: dmy,
                        punches: punches
                            .sorted { PunchFormat.ms($0.dateTime) < PunchFormat.ms($1.dateTime) }
                            .map { Punch(time: PunchFormat.wallTime($0.dateTime), type: $0.actualType == 1 ? "in" : "out") }
                    ))
                }
            }
            var result: [(Int, DayData)] = []
            for try await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// True once `day` is in the past with its bookends recorded.
    private func isSettled(_ day: DayData, today: Date = Date()) -> Bool {
        guard day.date < Self.dateFormatter.ymd(from: today) else { return false }
        return DayStatus(from: day.punches, isToday: false) == .complete
    }

    /// Adds newly settled days to the permanent store.
    private func recordSettled(_ days: [DayData]) {
        var changed = false
        for day in days where settledDays[day.date] == nil && isSettled(day) {
            settledDays[day.date] = day
            changed = true
        }
        guard changed, let url = Self.settledCacheURL() else { return }
        let snapshot = settledDays
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadSettledDays() {
        guard let url = Self.settledCacheURL(),
              let data = try? Data(contentsOf: url),
              let days = try? JSONDecoder().decode([String: DayData].self, from: data) else { return }
        settledDays = days
    }

    private static func settledCacheURL() -> URL? {
        cacheURL()?.deletingLastPathComponent().appendingPathComponent("settled-days.json")
    }

    /// Vacation, holiday or bank holiday according to the loaded requests/calendar.
    private func isNonWorkingDay(_ date: Date) -> Bool {
        let day = Calendar.current.startOfDay(for: date)
        if vacationDates.contains(day) { return true }
        guard let c = calendarDays.first(where: { Calendar.current.startOfDay(for: $0.date) == day }) else { return false }
        return c.isVacation || c.isHoliday || c.isBankHoliday
    }

    /// If every weekday of the displayed week is settled, shows it from the
    /// local store and returns true — no network involved.
    private func showSettledWeekIfPossible() -> Bool {
        let cal = Calendar.current
        let start = Self.monday(of: weekStart)
        let today = cal.startOfDay(for: Date())
        var days: [DayData] = []
        for i in 0..<5 {
            let date = cal.date(byAdding: .day, value: i, to: start)!
            let iso = Self.dateFormatter.ymd(from: date)
            if let settled = settledDays[iso] {
                days.append(settled)
            } else if date < today && isNonWorkingDay(date) {
                // No punches expected, nothing to fetch.
                days.append(DayData(date: iso, dmy: Self.dmyString(date), punches: []))
            } else if date > today && hasCalendarData(for: Self.firstOfMonth(of: date)) {
                // Future day: no punches yet, and the calendar already knows
                // whether it's a holiday/vacation.
                days.append(DayData(date: iso, dmy: Self.dmyString(date), punches: []))
            } else {
                return false
            }
        }
        week = WeekData(
            employeeName: week?.employeeName ?? "",
            presenceStatus: week?.presenceStatus ?? "",
            lastPunchDirection: week?.lastPunchDirection ?? "",
            lastPunchDate: week?.lastPunchDate,
            weekStart: Self.dateFormatter.ymd(from: start),
            days: days
        )
        isStale = false
        return true
    }

    /// Re-fetches a single day and patches it into the loaded week, instead of
    /// reloading the whole week after a one-day change (e.g. a backfill).
    private func refreshDay(_ date: Date) async {
        do {
            let fresh = try await withSession { try await fetchDays($0, dates: [date]) }
            guard let day = fresh.first, var current = week,
                  let idx = current.days.firstIndex(where: { $0.date == day.date }) else { return }
            current.days[idx] = day
            recordSettled([day])
            week = current
            isStale = false
            lastWeekRefresh = Date()
            Self.saveCachedWeek(current)
        } catch {
            appendLog(error.localizedDescription, level: .error)
            if isSessionExpiredError(error) { handleSessionExpiry() }
        }
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
                if isSessionExpiredError(error) {
                    appendLog("Clock \(direction) failed: session expired", level: .error)
                    handleSessionExpiry()
                } else {
                    invalidateSession()
                    appendLog("Clock \(direction) failed: \(error.localizedDescription)", level: .error)
                }
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
                sessionExpired = false
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

    func submitVacationRequest(dates: [Date], comments: String) async {
        guard !isBookingVacation else { return }
        guard let shiftId = selectedShiftId else {
            vacationBookingFeedback = "Shift data not loaded yet. Please wait."
            vacationBookingFeedbackIsError = true
            return
        }
        guard !dates.isEmpty else {
            vacationBookingFeedback = "No dates selected."
            vacationBookingFeedbackIsError = true
            return
        }
        if let limit = availableBookableDays {
            guard dates.count <= limit else {
                vacationBookingFeedback = "That's \(dates.count) day\(dates.count == 1 ? "" : "s"), but only \(limit) day\(limit == 1 ? "" : "s") are available to book."
                vacationBookingFeedbackIsError = true
                return
            }
        }

        let cal = Calendar.current
        let sorted = dates.sorted()
        let first = cal.startOfDay(for: sorted.first!)
        guard first >= cal.startOfDay(for: Date()) else {
            vacationBookingFeedback = "Cannot book dates in the past."
            vacationBookingFeedbackIsError = true
            return
        }

        isBookingVacation = true
        vacationBookingFeedback = nil

        let strDates = sorted.map { date -> String in
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        }.joined(separator: "/")

        appendLog("Submitting vacation request for \(dates.count) day(s)...")
        do {
            var result = try await withSession { session in
                try await api.saveRequestHolidays(
                    session,
                    strDates: strDates,
                    idHolidays: shiftId,
                    comments: comments,
                    acceptWarning: false
                )
            }

            // Retry with acceptWarning if the first attempt returned a warning status.
            if let status = result.d.Status, status < 0, let res = result.d.Result, !res {
                appendLog("Warning received, retrying with confirmation...", level: .info)
                result = try await withSession { session in
                    try await api.saveRequestHolidays(
                        session,
                        strDates: strDates,
                        idHolidays: shiftId,
                        comments: comments,
                        acceptWarning: true
                    )
                }
            }

            guard let res = result.d.Result, res else {
                let errorMsg = result.d.StatusErrorMsg ?? "unknown error"
                throw VTAPIError.message("Rejected (status \(result.d.Status ?? -1)): \(errorMsg)")
            }

            let requestId = result.d.RequestId ?? 0
            appendLog("Vacation request submitted (ID: \(requestId)).", level: .success)
            vacationBookingFeedback = "Request submitted successfully."
            vacationBookingFeedbackIsError = false
        } catch {
            appendLog("Vacation request failed: \(error.localizedDescription)", level: .error)
            if isSessionExpiredError(error) {
                handleSessionExpiry()
            }
            vacationBookingFeedback = "Failed: \(error.localizedDescription)"
            vacationBookingFeedbackIsError = true
        }
        isBookingVacation = false
        await refreshVacation()
    }

    /// Looks up the *vacation* concept shift (e.g. "PT Férias" → 947) from the
    /// `plannedholiday` generic list. This is the shift the portal uses for
    /// `GetRequestAvailableHolidaysDays` and `SaveRequestHolidays` — NOT the
    /// work shift from the calendar (which returns 0 available days).
    func refreshVacationShift() async {
        do {
            let options = try await withSession { session in
                try await api.getGenericList(session, requestType: "plannedholiday")
            }
            // Prefer shift-based concepts (RelatedInfo "S" = full days).
            let shiftBased = options.filter { $0.RelatedInfo == "S" }
            guard let concept = shiftBased.first, let shift = concept.intValue else {
                appendLog("No shift-based vacation concept found in plannedholiday list.", level: .info)
                selectedShiftId = nil
                return
            }
            selectedShiftId = shift
            await fetchAvailableHolidaysDays()
        } catch {
            appendLog("Failed to load vacation shift: \(error.localizedDescription)", level: .error)
            if isSessionExpiredError(error) {
                handleSessionExpiry()
            }
        }
    }

    /// Reads the days (or hours) the portal says are available to book for the
    /// user's vacation concept, e.g. `AvailableDaysOrTime: "1.000"`.
    func fetchAvailableHolidaysDays() async {
        guard let shiftId = selectedShiftId else { return }
        do {
            let result = try await withSession { session in
                try await api.getRequestAvailableHolidaysDays(
                    session,
                    employeeId: session.employeeId,
                    shiftId: shiftId
                )
            }
            if let days = result.days {
                availableHolidayDays = days
                appendLog("Available holidays: \(Self.formatAvailableDays(days)) day(s) for shift \(shiftId).", level: .info)
            } else if let hours = result.hours {
                availableHolidayDays = 0
                appendLog("Available holidays: \(hours) (hour-based) for shift \(shiftId).", level: .info)
            } else {
                availableHolidayDays = 0
                appendLog("Available holidays: no value for shift \(shiftId).", level: .info)
            }
        } catch {
            appendLog("Failed to fetch available holidays: \(error.localizedDescription)", level: .error)
            if isSessionExpiredError(error) {
                handleSessionExpiry()
            }
        }
    }

    static func formatAvailableDays(_ days: Double) -> String {
        let rounded = days.rounded()
        if abs(days - rounded) < 0.0001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.2f", days)
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
                    shiftName: nil, shiftShortName: nil, shiftId: nil,
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
                shiftId: day?.shiftId,
                isAbsenceDay: day?.isAbsenceDay ?? false,
                isAbsenceHours: day?.isAbsenceHours ?? false,
                isToday: cal.isDate(date, inSameDayAs: today)
            )
        }
    }

    func refreshVacation() async {
        guard !isVacationLoading else { return }
        isVacationLoading = true
        shiftDataLoadFailed = false
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
            self.selectedShiftId = nil
            await self.refreshVacationShift()
            if self.selectedShiftId == nil {
                shiftDataLoadFailed = true
            }
        } catch {
            appendLog("Vacation refresh failed: \(error.localizedDescription)", level: .error)
            shiftDataLoadFailed = true
            if isSessionExpiredError(error) {
                handleSessionExpiry()
            }
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
    /// fetched) and returns only the newly retrieved days. Partial failures are
    /// tolerated (empty arrays for failed months) but the month is not cached so
    /// future refreshes can retry. Session-expired errors propagate so
    /// `withSession` can re-login.
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
                    } catch let error as VTAPIError {
                        throw error  // propagate sessionExpired etc.
                    } catch {
                        return (key, [])  // network/decode errors → retryable
                    }
                }
            }
            for try await (key, days) in group {
                if !days.isEmpty {
                    fetched.append(contentsOf: days)
                    calendarFetchedMonths.insert(key)
                }
                // Empty arrays leave the key OUT of calendarFetchedMonths,
                // so a future refresh will retry this month.
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
        Self.saveCachedCalendar(calendarDays)
    }

    /// Restores the calendar from disk so the vacation tab renders instantly.
    /// Months before the current one no longer change, so they count as fetched
    /// and are never requested again; the current and future months are still
    /// refreshed once per launch.
    private func loadCachedCalendar() {
        guard let url = Self.calendarCacheURL(),
              let data = try? Data(contentsOf: url),
              let days = try? JSONDecoder().decode([CalendarDayData].self, from: data) else { return }
        calendarDays = days
        let currentKey = calendarMonthKey(Self.firstOfMonth(of: Date()))
        calendarFetchedMonths = Set(days.map { calendarMonthKey($0.date) }.filter { $0 < currentKey })
    }

    private static func calendarCacheURL() -> URL? {
        cacheURL()?.deletingLastPathComponent().appendingPathComponent("calendar.json")
    }

    private static func saveCachedCalendar(_ days: [CalendarDayData]) {
        guard let url = calendarCacheURL() else { return }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(days) else { return }
            try? data.write(to: url, options: .atomic)
        }
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
            if isSessionExpiredError(error) {
                handleSessionExpiry()
            }
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
    var preselect = false       // default checkbox state in the preview

    enum Status {
        case missing     // no punch near this time
        case covered     // existing punch matches
        case conflict    // existing punch nearby but different type
    }

    var timeLabel: String { "\(expectedTime) \(direction.uppercased())" }

    var detailText: String {
        switch status {
        case .missing:
            guard isSubmittable else { return "not needed" }
            return isDueNow ? "due now" : "not due yet"
        case .covered:
            return "recorded"
        case .conflict:
            return isSubmittable ? "conflict" : "conflict, not needed"
        }
    }

    var canSubmit: Bool { isSubmittable && status == .missing && isDueNow }
    var isProblem: Bool { isSubmittable && status == .conflict }

    /// Only these rows get a live checkbox; the rest are shown as fixed state.
    var isSelectable: Bool { canSubmit || isProblem }
}

private func buildBackfillPlan(for date: Date, existingWall: [(time: String, type: String)], configs: [PunchConfig]) -> [BackfillPlan] {
    let cal = Calendar.current
    let isToday = cal.isDateInToday(date)
    let now = Date()
    let nowMins = isToday ? hourMinToMins(timeHM(now)) : Int.max  // past days = all due

    var usedExisting = Set<Int>()
    var plans: [BackfillPlan] = []

    // Every configured slot is now submittable as a "forgot to punch" backfill.
    // "Due now" (the expected time has already passed) is what actually gates
    // the checkbox, so a future slot (e.g. the 16:00 OUT before it's reached)
    // stays unselectable instead of being offered too early.
    for (configIdx, config) in configs.enumerated() {
        let expected = config.time
        let expectedMins = hourMinToMins(expected)
        let isSubmittable = true
        let isDueNow = isSubmittable && expectedMins <= nowMins

        var bestIdx: Int?

        if isSubmittable {
            // Nearest unused punch of the same type, bounded only by this
            // slot's own tolerance. Because a punch can satisfy at most one
            // slot (usedExisting) and every slot carries its own expected
            // time, a lunch "OUT" (e.g. 12:07) can never satisfy the
            // end-of-day "OUT" (16:00) -- 12:07 falls ~240 minutes short,
            // outside the 120-minute tolerance -- so a genuinely missed
            // afternoon stays due. Conversely a missed 13:00 IN with no
            // near punch stays "missing" and is offered for backfill.
            var bestDiff = Int.max
            for (i, ex) in existingWall.enumerated() where !usedExisting.contains(i) && ex.type == config.type {
                let exMins = hourMinToMins(ex.time)
                guard abs(exMins - expectedMins) <= punchMatchToleranceMinutes else { continue }
                let diff = abs(exMins - expectedMins)
                if diff < bestDiff {
                    bestDiff = diff
                    bestIdx = i
                }
            }
        }

        if bestIdx == nil {
            // Nearby-match search: used for lunch punches (informational only),
            // and as a conflict fallback for bookends with no same-type match.
            var bestDiff = 30
            for (i, ex) in existingWall.enumerated() where !usedExisting.contains(i) {
                let diff = abs(hourMinToMins(ex.time) - expectedMins)
                if diff <= bestDiff {
                    bestDiff = diff
                    bestIdx = i
                }
            }
        }

        if let idx = bestIdx {
            let ex = existingWall[idx]
            usedExisting.insert(idx)
            let status: BackfillPlan.Status = ex.type == config.type ? .covered : .conflict
            plans.append(BackfillPlan(expectedTime: expected, direction: config.type, status: status, existingPunch: Punch(time: ex.time, type: ex.type), isSubmittable: isSubmittable, isDueNow: isDueNow))
        } else {
            plans.append(BackfillPlan(expectedTime: expected, direction: config.type, status: .missing, existingPunch: nil, isSubmittable: isSubmittable, isDueNow: isDueNow))
        }
    }

    // Pre-selection is time-aware. Mid-day, tick every slot that is already due
    // (e.g. at 14:00: 07:30 IN, 12:00 OUT, 13:00 IN; the 16:30 OUT stays
    // disabled until it passes). Once the whole schedule has elapsed (end of day
    // or a past day) only the first IN and last OUT are ticked; lunch punches
    // stay available but unticked.
    let dayEnded = !plans.isEmpty && plans.allSatisfy { $0.isDueNow }
    let times = plans.map { hourMinToMins($0.expectedTime) }
    let firstIdx = times.indices.min { times[$0] < times[$1] }
    let lastIdx = times.indices.max { times[$0] < times[$1] }
    for i in plans.indices where plans[i].canSubmit {
        plans[i].preselect = !dayEnded || i == firstIdx || i == lastIdx
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
private func showBackfillPreview(_ plans: [BackfillPlan], date: Date, dmy: String) -> [BackfillPlan]? {
    let alert = NSAlert()
    alert.messageText = "Backfill \(dmy)"
    alert.informativeText = "Checked rows will be submitted."
    let hasSelectable = plans.contains { $0.isSelectable }
    alert.addButton(withTitle: hasSelectable ? "Submit selected" : "Nothing to do")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .informational

    let rowWidth: CGFloat = 260
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false

    var checkboxes: [(BackfillPlan, NSButton)] = []

    for plan in plans {
        let title = "\(plan.timeLabel) — \(plan.detailText)"
        let cb = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        cb.font = .systemFont(ofSize: 11.5)
        cb.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

        if plan.isSelectable {
            cb.state = plan.preselect ? .on : .off
        } else {
            cb.state = (plan.status == .covered) ? .on : .off  // fixed state, just reflects reality
            cb.isEnabled = false
        }

        stack.addArrangedSubview(cb)
        checkboxes.append((plan, cb))
    }

    // NSAlert reads accessoryView.frame before Auto Layout gets a pass, so a
    // stray zero-height frame here would overlap the informative text instead
    // of reserving space for it — force layout and size the frame explicitly.
    stack.layoutSubtreeIfNeeded()
    stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
    alert.accessoryView = stack

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        let toSubmit = checkboxes.filter { $0.1.isEnabled && $0.1.state == .on }.map { $0.0 }
        if !toSubmit.isEmpty {
            return toSubmit
        }
    }
    return nil
}

func backfill(_ day: DayVM) {
    backfillCore(date: day.date, dmy: day.dmy, isFuture: day.isFuture)
}

func backfill(date: Date) {
    backfillCore(date: date, dmy: Self.dmyString(date), isFuture: false)
}

/// Punches for `date` from the loaded week, only when the week was refreshed
/// within `freshWeekWindow` (so a stale cache can't cause a duplicate submit).
private func freshCachedPunches(for date: Date) -> [Punch]? {
    guard let last = lastWeekRefresh, Date().timeIntervalSince(last) < Self.freshWeekWindow,
          let day = week?.days.first(where: { $0.date == Self.dateFormatter.ymd(from: date) }) else { return nil }
    return day.punches
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
    if isNonWorkingDay(date) {
        appendLog("\(dmy) is a vacation/holiday. Nothing to do.", level: .info)
        return
    }
    if let day = week?.days.first(where: { $0.date == Self.dateFormatter.ymd(from: date) }),
       !Calendar.current.isDateInToday(date),
       DayStatus(from: day.punches, isToday: false) == .complete {
        appendLog("\(dmy) is already complete. Nothing to do.", level: .info)
        return
    }
    isBusy = true
    appendLog("Analyzing \(dmy)...")
    Task {
        do {
            let session = try await requireSession()
            let existingWall: [(time: String, type: String)]
            if let cached = freshCachedPunches(for: date) {
                // The week was confirmed moments ago; skip the round trip.
                existingWall = cached.map { ($0.time, $0.type) }
            } else {
                let portal = try await api.getMyPunches(session, date: dmy)
                existingWall = portal.map { (PunchFormat.wallTime($0.dateTime), $0.actualType == 1 ? "in" : "out") }
            }
            if !Calendar.current.isDateInToday(date),
               DayStatus(from: existingWall.map { Punch(time: $0.time, type: $0.type) }, isToday: false) == .complete {
                appendLog("\(dmy) is already complete. Nothing to do.", level: .info)
                isBusy = false
                return
            }
            let plans = buildBackfillPlan(for: date, existingWall: existingWall, configs: settings.punchConfigs)

            let missingCount = plans.filter { $0.canSubmit }.count
            let conflictCount = plans.filter { $0.isProblem }.count

            if missingCount == 0 && conflictCount == 0 {
                appendLog("All punches already submitted. Nothing to do.", level: .info)
                AppSettings.shared.handledPunchDates.insert(Self.dateFormatter.ymd(from: date))
                isBusy = false
                return
            }

            let confirmed = await MainActor.run { showBackfillPreview(plans, date: date, dmy: dmy) }

            if let confirmed, !confirmed.isEmpty {
                await executeBackfill(confirmed, date: date, dmy: dmy, session: session)
            } else {
                appendLog("Backfill cancelled — nothing was submitted.", level: .info)
                isBusy = false
            }
        } catch {
            if isSessionExpiredError(error) {
                appendLog("Backfill failed: session expired", level: .error)
                handleSessionExpiry()
            } else {
                invalidateSession()
                appendLog("Backfill failed: \(error.localizedDescription)", level: .error)
            }
            isBusy = false
        }
    }
}

private func executeBackfill(_ plans: [BackfillPlan], date: Date, dmy: String, session: Session) async {
    isBusy = true
    appendLog("Submitting \(plans.count) punch(es) for \(dmy)...")
    do {
        let delayNs: UInt64 = 3_000_000_000
        let isoDate = Self.dateFormatter.ymd(from: date)
        for (i, plan) in plans.enumerated() {
            if i > 0 {
                appendLog("waiting 3s...", level: .info)
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
        if isSessionExpiredError(error) {
            appendLog("Backfill failed: session expired", level: .error)
            handleSessionExpiry()
        } else {
            invalidateSession()
            appendLog("Backfill failed: \(error.localizedDescription)", level: .error)
        }
    }
    isBusy = false
    await refreshDay(date)
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
            if isSessionExpiredError(error) {
                appendLog("Scheduled punch failed: session expired", level: .error)
                handleSessionExpiry()
            } else {
                invalidateSession()
                appendLog("Scheduled punch error: \(error.localizedDescription)", level: .error)
            }
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
    init(from punches: [Punch], configs: [PunchConfig] = AppSettings.shared.punchConfigs, isToday: Bool = false) {
        if punches.isEmpty {
            self = .empty
        } else {
            // "Complete" is schedule-aware *and* due-aware: a day only counts as
            // done when its punches cover every configured slot that is required
            // right now. A future slot (e.g. the 16:30 OUT before it's reached
            // at 13:19) is not yet required, so it can't flip a finished morning
            // to "partial" and light the backfill button early. Conversely a
            // genuinely missed 13:00 IN (already due) keeps the day on "partial"
            // so the afternoon can still be backfilled instead of being silently
            // marked "Done".
            self = dayCoversConfiguredSchedule(punches: punches, configs: configs, isToday: isToday) ? .complete : .partial
        }
    }
}

/// A punch within this many minutes of its configured slot counts as covering it.
let punchMatchToleranceMinutes = 120

/// True when the day's punches plausibly cover the whole configured schedule,
/// checked **per configured slot** and **due-aware**: a slot only counts as
/// required once its expected time has arrived. This mirrors exactly how
/// `buildBackfillPlan` decides which slots are eligible, so "Complete" and the
/// backfill button can never disagree about which slots still matter.
///
/// Concretely:
///  - a future slot (e.g. the 16:30 OUT reached at 13:19) is *not* required
///    yet, so a finished 07:30/12:00/13:00 morning stays "Complete" and the
///    button stays off;
///  - a genuinely missed, already-due slot (e.g. a 13:00 IN at 14:30) flips
///    the day back to "Partial" so it can still be backfilled instead of
///    being silently marked done;
///  - each punch is consumed at most once)Skip, so a lone early OUT can never
///    masquerade as the final OUT and silently hide a missed afternoon.
/// When no schedule is configured we fall back to "any IN and any OUT".
func dayCoversConfiguredSchedule(punches: [Punch], configs: [PunchConfig], isToday: Bool = false) -> Bool {
    func mins(_ hm: String) -> Int {
        let parts = hm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }
    // A past day is finished: it only needs its bookends (first IN near the
    // first configured slot, last OUT near the last). Lunch punches don't
    // matter once the day is over, so such a day is complete and never
    // offered for backfill again.
    if !isToday, let first = configs.min(by: { mins($0.time) < mins($1.time) }),
       let last = configs.max(by: { mins($0.time) < mins($1.time) }) {
        let sorted = punches.sorted { mins($0.time) < mins($1.time) }
        guard let firstPunch = sorted.first, let lastPunch = sorted.last else { return false }
        return firstPunch.type == "in" && lastPunch.type == "out"
            && abs(mins(firstPunch.time) - mins(first.time)) <= punchMatchToleranceMinutes
            && abs(mins(lastPunch.time) - mins(last.time)) <= punchMatchToleranceMinutes
    }

    // Only today's slots are gated by "now".
    let nowMins: Int
    if isToday {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        nowMins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    } else {
        nowMins = Int.max
    }

    var usedPunchIndices = Set<Int>()
    for config in configs {
        let expectedMins = mins(config.time)
        guard expectedMins <= nowMins else { continue } // not due yet, skip

        // The slot is required now: find a matching-type unused punch within
        // tolerance. A punch of the other type is never acceptable.
        var best: (index: Int, diff: Int)?
        for (i, punch) in punches.enumerated() where !usedPunchIndices.contains(i) && punch.type == config.type {
            let diff = abs(mins(punch.time) - expectedMins)
            if diff <= punchMatchToleranceMinutes && (best == nil || diff < best!.diff) {
                best = (i, diff)
            }
        }
        guard let match = best else { return false } // a due slot is uncovered
        usedPunchIndices.insert(match.index)
    }
    return true
}

extension DateFormatter {
    func ymd(from date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
