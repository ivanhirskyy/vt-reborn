import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var expandedGroups: Set<String> = ["incomplete"]
    @State private var showDismissed = false
    @State private var isBookingMode = false
    @State private var bookingStart: Date?
    @State private var bookingEnd: Date?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if model.sessionExpired {
                sessionExpiredBanner
            }
            Divider()
            tabBar
            Divider()
            tabContent
        }
        .padding(12)
        .frame(width: 760, height: 520)
    }

    // MARK: - Session expired banner

    private var sessionExpiredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("Session expired — punches won't update until you sign in again.")
                .font(.subheadline)
            Spacer()
            Button("Re-login") {
                model.reLogin()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 8)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Label("VT Reborn", systemImage: "clock.badge.checkmark")
                .font(.title3.bold())

            Spacer()

            if let week = model.week {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(week.employeeName)
                    presenceChip(week.presenceStatus)
                }
                .font(.subheadline)
            } else if model.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.bottom, 8)
    }

    private func presenceChip(_ status: String) -> some View {
        let inside = status.lowercased().contains("in") || status.lowercased().contains("present") || status.lowercased().contains("entered")
        let outside = status.lowercased().contains("out") || status.lowercased().contains("exit") || status.lowercased().contains("absent")
        let color: Color = inside ? .green : (outside ? .orange : .secondary)
        return Text(status)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 8) {
            TabButton(title: "Week", icon: "calendar", isSelected: model.selectedTab == 0) {
                model.selectedTab = 0
            }
            TabButton(title: "Vacation", icon: "sun.max", isSelected: model.selectedTab == 1) {
                model.selectedTab = 1
            }
            TabButton(title: "Alerts", icon: "bell", isSelected: model.selectedTab == 2, badgeCount: model.urgentAlertCount) {
                model.selectedTab = 2
            }
            TabButton(title: "Settings", icon: "gearshape", isSelected: model.selectedTab == 3) {
                model.selectedTab = 3
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch model.selectedTab {
        case 0:
            weekTab
        case 1:
            vacationTab
        case 2:
            alertsTab
        default:
            settingsTab
        }
    }

    private var weekTab: some View {
        VStack(spacing: 0) {
            weekHeader
            weekGrid
            Divider()
            actionBar
            Divider()
            logView
        }
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Credentials
                SettingsSection(title: "Credentials") {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledField("VT_USER") {
                            TextField("Employee ID", text: $settings.vtUser)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }
                        labeledField("VT_PASSWORD") {
                            PasswordField(text: $settings.vtPassword, placeholder: "Password (base64)")
                                .frame(width: 220)
                        }
                        labeledField("VT_COMPANY_ID") {
                            TextField("Company ID", text: $settings.vtCompanyId)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }
                        HStack(spacing: 8) {
                            Button {
                                model.signIn()
                            } label: {
                                if model.isSigningIn {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Sign In")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isSigningIn || !settings.hasValidCredentials)

                            if !settings.hasValidCredentials {
                                Text("Fill in all three fields to log in.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        if let feedback = model.loginFeedback {
                            Text(feedback)
                                .font(.caption)
                                .foregroundStyle(model.loginFeedbackIsError ? .red : .green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .onChange(of: settings.vtUser) { _ in model.clearLoginFeedback() }
                    .onChange(of: settings.vtPassword) { _ in model.clearLoginFeedback() }
                    .onChange(of: settings.vtCompanyId) { _ in model.clearLoginFeedback() }
                }

                // Scheduler
                SettingsSection(title: "Scheduler") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Stop scheduler when app quits", isOn: $settings.stopSchedulerOnQuit)
                        Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    }
                }

                // Punch schedule
                SettingsSection(title: "Punch schedule") {
                    VStack(alignment: .leading, spacing: 12) {
                        if settings.punchConfigs.isEmpty {
                            Text("No punches configured")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(settings.punchConfigs.indices, id: \.self) { index in
                                PunchConfigRow(index: index, config: $settings.punchConfigs[index], onDelete: {
                                    settings.punchConfigs.remove(at: index)
                                })
                            }
                        }

                        Button {
                            settings.punchConfigs.append(PunchConfig(time: "09:00", type: "in"))
                        } label: {
                            Label("Add punch", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.punchConfigs.count >= 4)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        }
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Vacation tab

    private var vacationTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isVacationLoading && model.calendarDays.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading vacation data…")
                        Spacer()
                    }
                    .padding(.vertical, 40)
                } else {
                    accrualSection
                    calendarSection
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        }
        .onAppear {
            if !model.vacationIsFresh || model.accruals.isEmpty || model.calendarDays.isEmpty {
                Task { await model.refreshVacation() }
            }
        }
    }

    private var accrualSection: some View {
        let meaningful = model.accruals.filter(\.isMeaningful)
        return SettingsSection(title: "Vacation balance") {
            if model.isVacationLoading && meaningful.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading balance…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 22)
            } else if meaningful.isEmpty {
                Text("No accrual data available")
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    balanceCard
                    let others = meaningful.filter { $0.id != currentYearAccrual?.id }
                    if !others.isEmpty {
                        ForEach(others) { accrual in
                            secondaryAccrualCard(accrual)
                        }
                    }
                }
            }
        }
    }

    private var bookingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(bookingHint, systemImage: "hand.tap.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    exitBookingMode()
                    model.vacationBookingFeedback = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                if let start = bookingStart {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.green)
                        Text(shortDate(start))
                            .font(.subheadline.bold())
                        if let end = bookingEnd {
                            Text("→")
                                .foregroundStyle(.secondary)
                            Text(shortDate(end))
                                .font(.subheadline.bold())
                        }
                        Text("(\(selectedWorkingDates.count) \(selectedWorkingDates.count == 1 ? "day" : "days"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") {
                        bookingStart = nil
                        bookingEnd = nil
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                } else {
                    Text("No days selected yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                Button {
                    Task {
                        await model.submitVacationRequest(dates: selectedWorkingDates, comments: "")
                        if model.vacationBookingFeedbackIsError == false, model.vacationBookingFeedback != nil {
                            exitBookingMode()
                        }
                    }
                } label: {
                    if model.isBookingVacation {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Submit Request", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .fixedSize()
                .disabled(model.isBookingVacation || bookingStart == nil || selectedWorkingDates.count > bookableThisYear)
            }

            if let feedback = model.vacationBookingFeedback {
                Label(feedback, systemImage: model.vacationBookingFeedbackIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(model.vacationBookingFeedbackIsError ? .red : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func enterBookingMode() {
        isBookingMode = true
        bookingStart = nil
        bookingEnd = nil
        model.vacationBookingFeedback = nil
    }

    private func exitBookingMode() {
        isBookingMode = false
        bookingStart = nil
        bookingEnd = nil
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    /// All working days in the selected range (weekends and bank holidays excluded).
    /// A single tapped day with no end yet books just that one day.
    private var selectedWorkingDates: [Date] {
        guard let start = bookingStart else { return [] }
        if let end = bookingEnd, end > start {
            return workingDates(from: start, through: end)
        }
        return [start]
    }

    private func workingDates(from start: Date, through end: Date) -> [Date] {
        let cal = Calendar.current
        var dates: [Date] = []
        var d = cal.startOfDay(for: start)
        let last = cal.startOfDay(for: end)
        while d <= last {
            let weekday = cal.component(.weekday, from: d)
            if weekday != 1, weekday != 7, !isBankHoliday(d) {
                dates.append(d)
            }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return dates
    }

    private func isBankHoliday(_ date: Date) -> Bool {
        let cal = Calendar.current
        let key = cal.startOfDay(for: date)
        return model.calendarDays.contains { day in
            cal.startOfDay(for: day.date) == key && (day.isBankHoliday || day.isHoliday)
        }
    }

    /// The main current-year balance (e.g. "PT Férias pendentes").
    private var currentYearAccrual: HolidayAccrual? {
        model.accruals.first { accrual in
            accrual.name.localizedCaseInsensitiveContains("Férias pendentes")
                && !accrual.name.localizedCaseInsensitiveContains("ano anterior")
        }
    }

    /// Days still free to book this year: current balance minus already-scheduled days.
    private var bookableThisYear: Int {
        max(model.availableBookableDays ?? 0, 0)
    }

    /// Scheduled (already booked) vacation days this year, from today onwards.
    /// Counts the same future days the calendar already renders.
    private var plannedThisYear: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thisYear = cal.component(.year, from: today)
        return model.vacationDates.reduce(into: 0) { count, date in
            let d = cal.startOfDay(for: date)
            if d >= today, cal.component(.year, from: d) == thisYear {
                count += 1
            }
        }
    }

    private var balanceCard: some View {
        let accrual = currentYearAccrual
        let taken = max(accrual?.done ?? 0, 0)
        let planned = plannedThisYear
        let bookable = bookableThisYear
        let total = max(taken + planned + bookable, 1)

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(bookable)")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                Text("free to book")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                segmentBar(taken: taken, planned: planned, bookable: bookable, total: total)

                HStack(spacing: 10) {
                    segmentLegend(color: .secondary.opacity(0.6), label: "Taken \(taken)")
                    segmentLegend(color: .orange, label: "Planned \(planned)")
                    segmentLegend(color: .green, label: "Free \(bookable)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A stacked horizontal bar showing how the total entitlement splits into
    /// taken / planned / still-free-to-book days.
    private func segmentBar(taken: Int, planned: Int, bookable: Int, total: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                if taken > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: geo.size.width * CGFloat(taken) / CGFloat(total))
                }
                if planned > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange)
                        .frame(width: geo.size.width * CGFloat(planned) / CGFloat(total))
                }
                if bookable > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(bookable) / CGFloat(total))
                }
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.3), value: total)
    }

    private func segmentLegend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func secondaryAccrualCard(_ accrual: HolidayAccrual) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(accrual.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(accrual.name)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(accrual.available)")
                    .font(.title3.bold())
                    .monospacedDigit()
                Text(accrual.valueFormat == "H" ? "h" : "days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Taken: \(accrual.done)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 168, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var calendarSection: some View {
        SettingsSection(title: "Shift calendar") {
            VStack(spacing: 8) {
                bookingBar

                HStack(spacing: 8) {
                    Button {
                        model.goPreviousMonth()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous month")

                    Spacer()

                    Text(model.calendarMonthLabel)
                        .font(.headline)

                    Spacer()

                    Button("Today") {
                        model.goCurrentMonth()
                    }
                    .help("Go to current month")

                    Button {
                        model.goNextMonth()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next month")
                }

                if model.isVacationLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                calendarGrid
                calendarLegend
            }
        }
    }

    /// Booking state machine shown right above the calendar grid: idle offers a
    /// "Book vacation" entry point, active hosts the inline selection controls.
    @ViewBuilder
    private var bookingBar: some View {
        if model.selectedShiftId == nil {
            if model.isVacationLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading shift data…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            } else if model.shiftDataLoadFailed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Couldn't load your shift. \(model.calendarDays.isEmpty ? "Check your connection and retry." : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        Task { await model.refreshVacation() }
                    }
                    .font(.caption)
                }
                .padding(10)
            }
        } else if isBookingMode {
            bookingControls
        } else {
            HStack(spacing: 12) {
                Label("Book vacation days", systemImage: "calendar.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if bookableThisYear > 0 {
                    Text("\(bookableThisYear) day\(bookableThisYear == 1 ? "" : "s") available")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Select dates") {
                        enterBookingMode()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                } else {
                    Text("No days available")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(10)
            .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var bookingHint: String {
        if bookingStart == nil {
            return "Tap a vacation day to book it (tap a second one to make a range)."
        } else if bookingEnd == nil {
            return "\(selectedWorkingDates.count) day(s) selected — tap a second day to extend or submit now."
        } else {
            return "\(selectedWorkingDates.count) day(s) selected — submit when ready."
        }
    }

    private var calendarGrid: some View {
        let weekdayHeader = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        return VStack(spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(weekdayHeader, id: \.self) { label in
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(model.monthDayVMs) { day in
                    calendarCell(day)
                }
            }
        }
    }

    private func calendarCell(_ day: CalendarDayVM) -> some View {
        Group {
            if day.dayNumber == 0 {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 38)
            } else {
                VStack(spacing: 2) {
                    Text("\(day.dayNumber)")
                        .font(.caption.bold())
                        .foregroundStyle(cellTextColor(day))

                    Text(day.shiftShortName ?? "—")
                        .font(.caption2)
                        .foregroundStyle(cellTextColor(day).opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(4)
                .background(cellBackground(day))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(cellStroke(day), lineWidth: 1.5)
                )
                .overlay(alignment: .topLeading) {
                    if day.isVacation {
                        Text("Vacation")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.green, in: RoundedRectangle(cornerRadius: 3))
                            .padding(2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    if isBookingMode {
                        handleDayTap(day)
                    }
                }
                .help(cellHelp(day))
            }
        }
    }

    /// Skyscanner-style range selection: first tap sets the start, second sets the
    /// end; tapping again restarts the range. Weekends and bank holidays are skipped.
    private func handleDayTap(_ day: CalendarDayVM) {
        guard isBookableDay(day) else { return }
        let cal = Calendar.current
        let date = cal.startOfDay(for: day.date)

        if let start = bookingStart {
            if let end = bookingEnd {
                // Range complete → start a fresh range with this day.
                bookingStart = date
                bookingEnd = nil
            } else if date < start {
                // Tapped before the start → move the start.
                bookingStart = date
            } else if date == start {
                bookingStart = nil
            } else {
                // End tap: only accept if it stays within the available days.
                let count = workingDates(from: start, through: date).count
                guard count <= bookableThisYear else { return }
                bookingEnd = date
            }
        } else {
            bookingStart = date
        }
    }

    private func cellStroke(_ day: CalendarDayVM) -> Color {
        if isBookingMode, isDaySelected(day) || isDayInRange(day) {
            return Color.green.opacity(0.6)
        } else if day.isToday {
            return Color.blue
        } else {
            return Color.clear
        }
    }

    private func cellTextColor(_ day: CalendarDayVM) -> Color {
        if isBookingMode, !isBookableDay(day) {
            return .secondary.opacity(0.35)
        } else if day.isToday {
            return .primary
        } else {
            return .secondary
        }
    }

    private func isDaySelected(_ day: CalendarDayVM) -> Bool {
        let cal = Calendar.current
        let date = cal.startOfDay(for: day.date)
        return date == bookingStart || date == bookingEnd
    }

    private func isDayInRange(_ day: CalendarDayVM) -> Bool {
        guard isBookableDay(day) else { return false }
        guard let start = bookingStart, let end = bookingEnd else { return false }
        let cal = Calendar.current
        let date = cal.startOfDay(for: day.date)
        guard date > start, date < end else { return false }
        return true
    }

    /// Whether a calendar day can be picked as part of a vacation booking:
    /// no past days, weekends, bank holidays or days already marked as vacation.
    private func isBookableDay(_ day: CalendarDayVM) -> Bool {
        guard !day.isVacation, !day.isBankHoliday else { return false }
        let cal = Calendar.current
        let date = cal.startOfDay(for: day.date)
        let weekday = cal.component(.weekday, from: date)
        guard weekday != 1, weekday != 7 else { return false }
        return date >= cal.startOfDay(for: Date())
    }

    @ViewBuilder
    private func cellBackground(_ day: CalendarDayVM) -> some View {
        if isBookingMode, isDaySelected(day) {
            Color.green.opacity(0.45)
        } else if isBookingMode, isDayInRange(day) {
            Color.green.opacity(0.18)
        } else if day.isBankHoliday {
            Color.gray.opacity(0.28)
        } else if isBookingMode, !isBookableDay(day) {
            Color.gray.opacity(0.1)
        } else if day.isVacation || day.isHoliday {
            Color.green.opacity(0.18)
        } else if day.isAbsenceDay || day.isAbsenceHours {
            Color.orange.opacity(0.2)
        } else if day.isToday {
            Color.blue.opacity(0.12)
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private func cellHelp(_ day: CalendarDayVM) -> String {
        var parts: [String] = []
        if day.isVacation { parts.append("Vacation") }
        if day.isBankHoliday { parts.append("Bank holiday") }
        if day.isHoliday { parts.append("Holiday" + (day.holidayDescription.isEmpty ? "" : ": \(day.holidayDescription)")) }
        if day.isAbsenceDay { parts.append("Absent (full day)") }
        if day.isAbsenceHours { parts.append("Absent (partial)") }
        if let shiftName = day.shiftName { parts.append(shiftName) }
        return parts.joined(separator: " · ")
    }

    private var calendarLegend: some View {
        HStack(spacing: 14) {
            legendItem(color: .green, label: "Vacation")
            legendItem(color: .gray, label: "Bank holiday")
            legendItem(color: .orange, label: "Absence")
            legendItem(color: .blue, label: "Today")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.5))
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Alerts tab

    private var alertsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(model.urgentAlertCount > 0
                         ? "\(model.urgentAlertCount) urgent alert\(model.urgentAlertCount == 1 ? "" : "s")"
                         : "No urgent alerts")
                        .font(.subheadline)
                        .foregroundStyle(model.urgentAlertCount > 0 ? .orange : .secondary)
                    Spacer()
                    if !model.alerts.isEmpty {
                        Toggle("Show dismissed", isOn: $showDismissed)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("Show incomplete-punch notifications already handled by this app")
                    }
                    if model.isAlertsLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await model.refreshAlerts() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh alerts")
                    }
                }

                if model.isAlertsLoading && model.alerts.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading alerts…")
                        Spacer()
                    }
                    .padding(.vertical, 40)
                } else if model.visibleAlerts.isEmpty {
                    Text("No alerts right now. Everything is up to date.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    ForEach(alertGroups) { group in
                        alertGroupCard(group)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        }
        .onAppear {
            if model.alerts.isEmpty {
                Task { await model.refreshAlerts() }
            }
        }
    }

    private var alertGroups: [AlertGroup] {
        let source = showDismissed ? model.alerts : model.visibleAlerts
        let incomplete = source.filter { $0.backfillDate != nil }
        let requests = source.filter { $0.requestType != nil }

        var groups: [AlertGroup] = []
        if !incomplete.isEmpty {
            groups.append(AlertGroup(
                id: "incomplete",
                title: "Incomplete punches",
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                alerts: incomplete
            ))
        }
        let grouped = Dictionary(grouping: requests) { $0.requestType! }
        for type in grouped.keys.sorted() {
            groups.append(AlertGroup(
                id: "type-\(type)",
                title: requestTypeLabel(type),
                icon: "doc.text",
                tint: .accentColor,
                alerts: grouped[type] ?? []
            ))
        }
        return groups
    }

    private func requestTypeLabel(_ type: Int) -> String {
        switch type {
        case 2: return "Missed punches"
        case 6: return "Vacation requests"
        default: return "Requests (type \(type))"
        }
    }

    private func alertGroupCard(_ group: AlertGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)

        return SettingsSection(title: group.title) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            expandedGroups.remove(group.id)
                        } else {
                            expandedGroups.insert(group.id)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: group.icon)
                            .foregroundStyle(group.tint)
                        Text("\(group.alerts.count) alert\(group.alerts.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Expand")

                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(group.alerts.enumerated()), id: \.element.id) { index, alert in
                            alertRow(alert)
                            if index < group.alerts.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func alertRow(_ alert: VTAlert) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(alert.subject)
                    .font(.subheadline.bold())
                urgencyBadges(alert)
                Spacer()
                if let date = alert.backfillDate, !Calendar.current.isDateInToday(date) {
                    Button {
                        model.backfill(date: date)
                    } label: {
                        Label("Backfill", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("Submit a request for this day's missing punches")
                }
                if alert.backfillDate != nil {
                    Button {
                        model.dismissAlert(alert)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss this notification (already handled)")
                }
            }
            Text(alert.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.fullDateFormatter.string(from: alert.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func urgencyBadges(_ alert: VTAlert) -> some View {
        if alert.isCritic {
            Text("CRITICAL")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.2), in: Capsule())
                .foregroundStyle(.red)
        }
        if alert.isUrgent {
            Text("Urgent")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    private static var fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Week header

    private var weekHeader: some View {
        HStack(spacing: 10) {
            Button {
                model.goPreviousWeek()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous week")

            Spacer()

            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.weekRangeLabel)
                        .font(.headline)
                    if model.isStale {
                        Text("Stale")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("Showing cached data — last refresh failed")
                    }
                }
                Text("Tap a day to backfill, or refresh to re-check status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.goNextWeek()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next week")

            Button("Today") {
                model.goToday()
            }
            .help("Go to this week")

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .help("Refreshing…")
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh week status")
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Week grid

    private var weekGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(model.dayVMs) { day in
                DayCard(day: day, isBusy: model.isBusy, isLoading: model.isRefreshing) {
                    model.backfill(day)
                }
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                model.punch("in")
            } label: {
                Label("Clock In", systemImage: "arrow.down.circle.fill")
            }
            .disabled(model.isBusy)
            .help("Punch in right now")

            Button {
                model.punch("out")
            } label: {
                Label("Clock Out", systemImage: "arrow.up.circle.fill")
            }
            .disabled(model.isBusy)
            .help("Punch out right now")

            Spacer()

            if model.schedulerRunning {
                Button {
                    model.stopScheduler()
                } label: {
                    Label("Stop Scheduler", systemImage: "stop.circle.fill")
                }
                .disabled(model.isBusy)
            } else {
                Button {
                    model.startScheduler()
                } label: {
                    Label("Start Scheduler", systemImage: "play.circle.fill")
                }
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Log

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Output")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.clearLog()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear log")
            }
            .padding(.top, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.logs) { entry in
                            Text(entry.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(entry.level.color)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: 110)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.logs.count) { count in
                    if count > 0 {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(model.logs[count - 1].id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Helper views

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var badgeCount: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }
}

struct AlertGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
    let alerts: [VTAlert]
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct PunchConfigRow: View {
    let index: Int
    @Binding var config: PunchConfig
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $config.type) {
                Text("In").tag("in")
                Text("Out").tag("out")
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .offset(x: -8)

            TextField("HH:MM", text: $config.time)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove")

            Spacer(minLength: 0)
        }
        .padding(0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PasswordField: View {
    @Binding var text: String
    var placeholder: String
    @State private var isVisible = false

    var body: some View {
        ZStack(alignment: .trailing) {
            if isVisible {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { isVisible = false }
            } else {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .help(isVisible ? "Hide password" : "Show password")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
    }
}

extension LogEntry.Level {
    var color: Color {
        switch self {
        case .info: return .white
        case .success: return .green
        case .error: return .red
        }
    }
}