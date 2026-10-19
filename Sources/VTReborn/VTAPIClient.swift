import Foundation

// Direct client for the VisualTime (VT) portal API.
// Ported from src/api.ts.

private let PORTAL_URL = "https://vtportal.visualtime.net/api/portalsvcx.svc"

struct Credentials {
    let user: String
    let password: String
    let companyId: String
}

struct Session: Codable {
    let token: String
    let employeeId: Int
    let employeeName: String
    let guid: String
    let companyId: String
    let presenceStatus: String
    let lastPunchDirection: String
    let lastPunchDate: Date?
}

enum VTAPIError: Error, LocalizedError {
    case message(String)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .sessionExpired: return "Session expired — please log in again"
        }
    }
}

// MARK: - Response models

struct LoginResponse: Decodable {
    struct D: Decodable {
        struct EmployeeStatus: Decodable {
            let EmployeeName: String?
            let LastPunchDate: String?
            let LastPunchDirection: String?
            let PresenceStatus: String?
        }
        let Token: String
        let EmployeeId: Int
        let Status: Int
        let EmployeeStatus: EmployeeStatus
    }
    let d: D
}

struct SetStatusResponse: Decodable {
    struct D: Decodable {
        let Status: Int
        let CustomErrorText: String?
        let PresenceStatus: String?
        let LastPunchDirection: String?
    }
    let d: D
}

struct EmployeePunch: Decodable {
    let actualType: Int
    let dateTime: String
    let id: Int
    let type: Int
    let typeData: Int
    let relatedInfo: String?

    enum CodingKeys: String, CodingKey {
        case actualType = "ActualType"
        case dateTime = "DateTime"
        case id = "ID"
        case type = "Type"
        case typeData = "TypeData"
        case relatedInfo = "RelatedInfo"
    }
}

struct GetMyPunchesResponse: Decodable {
    struct D: Decodable {
        let Punches: [EmployeePunch]?
        let Status: Int?
    }
    let d: D
}

struct SaveForbiddenPunchResponse: Decodable {
    struct D: Decodable {
        let PunchWithoutRequest: Bool?
        let RequestId: Int?
        let Result: Bool?
        let Status: Int?
        let StatusErrorMsg: String?
        let StatusInfoMsg: String?
    }
    let d: D
}

// MARK: - Accruals (vacation balance)

struct HolidayAccrual: Codable, Identifiable, Equatable {
    let name: String
    let available: Int
    let done: Int
    let pending: Int
    let prevision: Int
    let lasting: Int
    let valueFormat: String // "O" = days, "H" = hours
    var id: String { name }

    var isMeaningful: Bool {
        available > 0 || done > 0 || pending > 0 || prevision > 0 || lasting > 0
    }

    /// A concise, human-friendly label for the raw (often Portuguese) accrual
    /// name coming from the portal. The original name stays available via `name`.
    var displayName: String {
        let lower = name.lowercased()
        if lower.contains("ano anterior") { return "Carry-over leave" }
        if lower.contains("férias") || lower.contains("ferias") { return "Vacation leave" }
        return name
    }
}

struct GetAccrualsSummaryResponse: Decodable {
    struct D: Decodable {
        struct HolidaysSummary: Decodable {
            struct Info: Decodable {
                let Name: String?
                let Available: Int?
                let Done: Int?
                let Pending: Int?
                let Prevision: Int?
                let Lasting: Int?
                let ValueFormat: String?
            }
            let HolidaysInfo: [Info]?
        }
        let HolidaysSummary: HolidaysSummary?
    }
    let d: D
}

// MARK: - Calendar

struct CalendarDayData: Identifiable, Codable {
    let date: Date
    let weekday: String
    let dayNumber: Int
    let isHoliday: Bool
    let isBankHoliday: Bool
    let holidayDescription: String
    let isVacation: Bool
    let shiftName: String?
    let shiftShortName: String?
    let shiftId: Int?
    let isAbsenceDay: Bool
    let isAbsenceHours: Bool
    let unexpectedlyAbsent: Bool
    var id: Date { date }
}

struct GetMyCalendarResponse: Decodable {
    struct D: Decodable {
        struct Period: Decodable {
            struct Day: Decodable {
                struct Alerts: Decodable {
                    let OnAbsenceDays: Bool?
                    let OnAbsenceHours: Bool?
                    let UnexpectedlyAbsent: Bool?
                }
                struct Shift: Decodable {
                    let ID: Int?
                    let Name: String?
                    let ShortName: String?
                }
                let PlanDate: String?
                let Feast: Bool?
                let FeastDescription: String?
                let IsHoliday: Bool?
                let Alerts: Alerts?
                let ShiftUsed: Shift?
                let MainShift: Shift?
            }
            let DayData: [Day]?
        }
        let oCalendar: Period?
    }
    let d: D
}

// MARK: - Requests (booked vacations)

/// A submitted request as returned by GetMyRequests. Booked vacation days are
/// encoded in the human-readable `description` (e.g. "Schedule PT Férias, from
/// the 7/15/2026 until the 7/15/2026"), so we parse the dates out of it.
struct VacationRequest: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: Int
    let idRequestType: Int
    let description: String

    var isAccepted: Bool { status == 2 }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case status = "Status"
        case idRequestType = "IdRequestType"
        case description = "Description"
    }
}

struct GetMyRequestsResponse: Decodable {
    struct D: Decodable {
        let Requests: [VacationRequest]?
    }
    let d: D
}

// MARK: - SaveRequestHolidays (booking)

struct SaveRequestHolidaysResponse: Decodable {
    struct D: Decodable {
        let Result: Bool?
        let RequestId: Int?
        let Status: Int?
        let StatusErrorMsg: String?
        let StatusInfoMsg: String?
    }
    let d: D
}

// MARK: - GetRequestAvailableHolidaysDays

struct AvailableHolidayDay: Decodable {
    let Date: String?
    let Available: Bool?

    enum CodingKeys: String, CodingKey {
        case Date
        case Available
    }
}

/// Matches the real portal response for GetRequestAvailableHolidaysDays:
/// `d.Value.AvailableDaysOrTime` (a number of days, e.g. "1.000", or a
/// duration "00:00" for hour-based concepts) plus `d.Value.IDConceptBalance`.
struct GetRequestAvailableHolidaysDaysResponse: Decodable {
    struct D: Decodable {
        struct Value: Decodable {
            let AvailableDaysOrTime: String?
            let IDConceptBalance: Int?
        }
        let Value: Value?
        let Status: Int?
    }
    let d: D
}

struct GenericListResponse: Decodable {
    struct D: Decodable {
        let SelectFields: [GenericListOption]?
        let Status: Int?
    }
    let d: D
}

/// A single option returned by `GetGenericList`. `RelatedInfo` is "S" for
/// shift-based concepts (full days) and "C" for cause-based concepts
/// (hour-based / half days); "employees.fullList", "documents", etc. are used
/// for other dropdown lists.
struct GenericListOption: Decodable {
    let FieldName: String?
    let FieldValue: String?
    let RelatedInfo: String?

    var intValue: Int? {
        guard let raw = FieldValue else { return nil }
        return Int(raw)
    }
}

// MARK: - Notifications

struct VTAlert: Identifiable {
    enum Kind {
        case incompletePunch(date: Date)
        case request(type: Int)
    }

    let id: UUID = UUID()
    let subject: String
    let description: String
    let date: Date
    let isUrgent: Bool
    let isCritic: Bool
    let kind: Kind

    var backfillDate: Date? {
        if case .incompletePunch(let date) = kind { return date }
        return nil
    }

    var requestType: Int? {
        if case .request(let type) = kind { return type }
        return nil
    }
}

struct GetUserNotificationsResponse: Decodable {
    struct D: Decodable {
        struct Schedule: Decodable {
            struct IncompletePunch: Decodable {
                let AlertDescription: String?
                let AlertSubject: String?
                let DateTime: String?
                let IsCritic: Bool?
                let IsUrgent: Bool?
            }
            struct RequestAlert: Decodable {
                let AlertSubject: String?
                let DateTime: String?
                let Description: String?
                let IdRequest: Int?
                let IdRequestType: Int?
                let IsCritic: Bool?
                let IsUrgent: Bool?
                let Status: Int?
            }
            let IncompletePunches: [IncompletePunch]?
            let RequestAlerts: [RequestAlert]?
        }
        let ScheduleStatus: Schedule?
    }
    let d: D
}

// MARK: - Client

struct VTAPIClient {
    private let httpSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 30
        httpSession = URLSession(configuration: config)
    }

    // MARK: Authenticate

    func login(_ credentials: Credentials) async throws -> Session {
        let guid = UUID().uuidString

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "user", value: credentials.user),
            URLQueryItem(name: "password", value: credentials.password),
            URLQueryItem(name: "language", value: "ENG"),
            URLQueryItem(name: "accessFromApp", value: "false"),
            URLQueryItem(name: "appVersion", value: "3.46.0"),
            URLQueryItem(name: "validationCode", value: ""),
            URLQueryItem(name: "timeZone", value: "Europe/Lisbon"),
            URLQueryItem(name: "buttonLogin", value: "true"),
        ]

        var request = URLRequest(url: URL(string: "\(PORTAL_URL)/Authenticate")!)
        request.httpMethod = "POST"
        request.setValue(guid, forHTTPHeaderField: "roAuth")
        request.setValue(credentials.companyId, forHTTPHeaderField: "roCompanyID")
        request.setValue("VTPortal", forHTTPHeaderField: "roApp")
        request.setValue("false", forHTTPHeaderField: "roSrc")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response) = try await httpSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("Login failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard decoded.d.Status == 0 else {
            throw VTAPIError.message("Login failed with status: \(decoded.d.Status)")
        }

        let status = decoded.d.EmployeeStatus
        return Session(
            token: decoded.d.Token,
            employeeId: decoded.d.EmployeeId,
            employeeName: status.EmployeeName ?? "Unknown",
            guid: guid,
            companyId: credentials.companyId,
            presenceStatus: status.PresenceStatus ?? "Unknown",
            lastPunchDirection: status.LastPunchDirection ?? "Unknown",
            lastPunchDate: Self.parseMSDate(status.LastPunchDate)
        )
    }

    // MARK: SetStatus (punch in/out)

    func punch(_ session: Session, direction: String) async throws -> (status: String, direction: String) {
        let apiDirection = direction == "in" ? "E" : "S"

        var comps = URLComponents(string: "\(PORTAL_URL)/SetStatus")!
        comps.queryItems = [
            URLQueryItem(name: "causeId", value: "0"),
            URLQueryItem(name: "direction", value: apiDirection),
            URLQueryItem(name: "latitude", value: "-1"),
            URLQueryItem(name: "longitude", value: "-1"),
            URLQueryItem(name: "identifier", value: ""),
            URLQueryItem(name: "locationZone", value: ""),
            URLQueryItem(name: "fullAddress", value: ""),
            URLQueryItem(name: "reliable", value: "true"),
            URLQueryItem(name: "nfcTag", value: ""),
            URLQueryItem(name: "tcType", value: ""),
            URLQueryItem(name: "reliableZone", value: "true"),
            URLQueryItem(name: "selectedZone", value: "-1"),
            URLQueryItem(name: "timeZone", value: "Europe/Lisbon"),
            URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("Punch failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(SetStatusResponse.self, from: data)
        guard decoded.d.Status == 0 else {
            let detail = decoded.d.CustomErrorText ?? "unknown error"
            throw VTAPIError.message("Punch failed with status: \(decoded.d.Status) (\(detail))")
        }

        return (
            decoded.d.PresenceStatus ?? "Unknown",
            decoded.d.LastPunchDirection ?? "Unknown"
        )
    }

    // MARK: GetMyPunches

    func getMyPunches(_ session: Session, date: String) async throws -> [EmployeePunch] {
        var comps = URLComponents(string: "\(PORTAL_URL)/GetMyPunches")!
        comps.queryItems = [
            URLQueryItem(name: "selectedDate", value: date),
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("GetMyPunches failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(GetMyPunchesResponse.self, from: data)
        return decoded.d.Punches ?? []
    }

    // MARK: SaveRequestForbiddenPunch (backfill)

    func saveForbiddenPunch(_ session: Session, punchDateTime: String, direction: String) async throws -> Int {
        let apiDirection = direction == "in" ? "E" : "S"

        var data = try await doSaveForbiddenPunch(
            session,
            punchDateTime: punchDateTime,
            apiDirection: apiDirection,
            acceptWarning: false
        )

        // A negative status indicates a warning (e.g. nearby punch exists).
        // Retry with acceptWarning: true to confirm and push through.
        if let result = data.d.Result, !result, let status = data.d.Status, status < 0 {
            data = try await doSaveForbiddenPunch(
                session,
                punchDateTime: punchDateTime,
                apiDirection: apiDirection,
                acceptWarning: true
            )
        }

        guard let result = data.d.Result, result else {
            let errorMsg = data.d.StatusErrorMsg ?? "unknown"
            throw VTAPIError.message(
                "SaveForbiddenPunch rejected (status: \(data.d.Status ?? -1))\nStatusErrorMsg: \(errorMsg)"
            )
        }

        return data.d.RequestId ?? 0
    }

    private func doSaveForbiddenPunch(
        _ session: Session,
        punchDateTime: String,
        apiDirection: String,
        acceptWarning: Bool
    ) async throws -> SaveForbiddenPunchResponse {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "punchDate", value: punchDateTime),
            URLQueryItem(name: "idCause", value: "144"), // PT esquecimento de picagem
            URLQueryItem(name: "comments", value: ""),
            URLQueryItem(name: "direction", value: apiDirection),
            URLQueryItem(name: "acceptWarning", value: acceptWarning ? "true" : "false"),
            URLQueryItem(name: "tcType", value: "0"),
        ]

        var request = URLRequest(url: URL(string: "\(PORTAL_URL)/SaveRequestForbiddenPunch")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("SaveForbiddenPunch failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try JSONDecoder().decode(SaveForbiddenPunchResponse.self, from: data)
    }

    // MARK: GetAccrualsSummary (vacation balance)

    func getAccrualsSummary(_ session: Session, selectedDate: String) async throws -> [HolidayAccrual] {
        var comps = URLComponents(string: "\(PORTAL_URL)/GetAccrualsSummary")!
        comps.queryItems = [
            URLQueryItem(name: "selectedDate", value: selectedDate),
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("GetAccrualsSummary failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(GetAccrualsSummaryResponse.self, from: data)
        return (decoded.d.HolidaysSummary?.HolidaysInfo ?? []).map { info in
            HolidayAccrual(
                name: info.Name ?? "",
                available: info.Available ?? 0,
                done: info.Done ?? 0,
                pending: info.Pending ?? 0,
                prevision: info.Prevision ?? 0,
                lasting: info.Lasting ?? 0,
                valueFormat: info.ValueFormat ?? "O"
            )
        }
    }

    // MARK: GetMyCalendar

    func getMyCalendar(_ session: Session, selectedDate: String) async throws -> [CalendarDayData] {
        var comps = URLComponents(string: "\(PORTAL_URL)/GetMyCalendar")!
        comps.queryItems = [
            URLQueryItem(name: "selectedDate", value: selectedDate),
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("GetMyCalendar failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(GetMyCalendarResponse.self, from: data)
        guard let days = decoded.d.oCalendar?.DayData else { return [] }

        let cal = Calendar.current
        let fmtWeekday: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE"
            return f
        }()

        return days.map { day in
            // The portal encodes every PlanDate as 00:00 in an offset one hour
            // ahead of the employee's zone (summer +0200, winter +0100), so each
            // entry resolves to 23:00 the previous evening. Add a day to land on
            // the intended civil date.
            let parsed = Self.parseMSDate(day.PlanDate) ?? Date()
            let date = Calendar.current.date(byAdding: .day, value: 1, to: parsed) ?? parsed
            // Booked vacations arrive as a shift whose name contains "Férias".
            let shiftName = day.ShiftUsed?.Name ?? day.MainShift?.Name
            let isVacation = (shiftName ?? "").localizedCaseInsensitiveContains("férias")
            // Bank holidays arrive as "PT Feriado Nacional" with IsHoliday == false.
            let isBankHoliday = (shiftName ?? "").localizedCaseInsensitiveContains("feriado")
            // Feast is always present (0 = no feast), so it must not shadow IsHoliday
            // (which is 1 on booked vacation days). Keep bank holidays separate so the
            // calendar can render them distinctly.
            let isHoliday = (day.Feast ?? false) || (day.IsHoliday ?? false)
            let holidayDescription: String
            if let feast = day.FeastDescription, !feast.isEmpty {
                holidayDescription = feast
            } else if isBankHoliday {
                holidayDescription = shiftName ?? ""
            } else {
                holidayDescription = ""
            }
            return CalendarDayData(
                date: date,
                weekday: fmtWeekday.string(from: date),
                dayNumber: cal.component(.day, from: date),
                isHoliday: isHoliday,
                isBankHoliday: isBankHoliday,
                holidayDescription: holidayDescription,
                isVacation: isVacation,
                shiftName: shiftName,
                shiftShortName: day.ShiftUsed?.ShortName ?? day.MainShift?.ShortName,
                shiftId: day.ShiftUsed?.ID ?? day.MainShift?.ID,
                isAbsenceDay: day.Alerts?.OnAbsenceDays ?? false,
                isAbsenceHours: day.Alerts?.OnAbsenceHours ?? false,
                unexpectedlyAbsent: day.Alerts?.UnexpectedlyAbsent ?? false
            )
        }
    }

    // MARK: GetUserNotifications

    func getUserNotifications(_ session: Session) async throws -> [VTAlert] {
        var comps = URLComponents(string: "\(PORTAL_URL)/GetUserNotifications")!
        comps.queryItems = [
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("GetUserNotifications failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(GetUserNotificationsResponse.self, from: data)
        guard let schedule = decoded.d.ScheduleStatus else { return [] }

        let incomplete = (schedule.IncompletePunches ?? []).map { raw in
            let date = Self.parseMSDate(raw.DateTime) ?? Date()
            return VTAlert(
                subject: raw.AlertSubject ?? "",
                description: raw.AlertDescription ?? "",
                date: date,
                isUrgent: raw.IsUrgent ?? false,
                isCritic: raw.IsCritic ?? false,
                kind: .incompletePunch(date: date)
            )
        }

        let requests = (schedule.RequestAlerts ?? []).map { raw in
            VTAlert(
                subject: raw.AlertSubject ?? "",
                description: Self.stripHTML(raw.Description ?? ""),
                date: Self.parseMSDate(raw.DateTime) ?? Date(),
                isUrgent: raw.IsUrgent ?? false,
                isCritic: raw.IsCritic ?? false,
                kind: .request(type: raw.IdRequestType ?? 0)
            )
        }

        return incomplete + requests
    }

    // MARK: GetMyRequests

    func getMyRequests(_ session: Session, selectedDate: String) async throws -> [VacationRequest] {
        var comps = URLComponents(string: "\(PORTAL_URL)/GetMyRequests")!
        comps.queryItems = [
            URLQueryItem(name: "selectedDate", value: selectedDate),
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("GetMyRequests failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(GetMyRequestsResponse.self, from: data)
        return decoded.d.Requests ?? []
    }

    // MARK: SaveRequestHolidays (book vacation)

    func saveRequestHolidays(
        _ session: Session,
        strDates: String,
        idHolidays: Int,
        comments: String,
        acceptWarning: Bool
    ) async throws -> SaveRequestHolidaysResponse {
        let boundary = "WebKitFormBoundary\(UUID().uuidString.prefix(16))"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField("strDates", strDates)
        appendField("idHolidays", "\(idHolidays)")
        appendField("comments", comments)
        appendField("acceptWarning", acceptWarning ? "true" : "false")
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "\(PORTAL_URL)/SaveRequestHolidays")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        setAuthHeaders(&request, session: session)
        request.httpBody = body

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("SaveRequestHolidays failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try JSONDecoder().decode(SaveRequestHolidaysResponse.self, from: data)
    }

    // MARK: GetRequestAvailableHolidaysDays

    /// Available vacation days (or hours) for the given shift, parsed from the
    /// portal's `AvailableDaysOrTime` value. Day-based values like "1.000" are
    /// returned in `days`; hour-based values like "00:00" are returned in `hours`.
    func getRequestAvailableHolidaysDays(
        _ session: Session,
        employeeId: Int,
        shiftId: Int
    ) async throws -> (days: Double?, hours: String?) {
        var comps = URLComponents(string: "\(PORTAL_URL)/GetRequestAvailableHolidaysDays")!
        comps.queryItems = [
            URLQueryItem(name: "IDEmployee", value: "\(employeeId)"),
            URLQueryItem(name: "IDShift", value: "\(shiftId)"),
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("GetRequestAvailableHolidaysDays failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(GetRequestAvailableHolidaysDaysResponse.self, from: data)
        guard let raw = decoded.d.Value?.AvailableDaysOrTime, !raw.isEmpty else {
            return (nil, nil)
        }
        if raw.contains(":") {
            return (nil, raw)
        }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        return (Double(normalized), nil)
    }

    /// Fetches the list of selectable options for a dropdown. The vacation
    /// booking view passes `requestType: "plannedholiday"` and returns the
    /// concept shifts (e.g. "PT Férias" → FieldValue 947, RelatedInfo "S").
    func getGenericList(_ session: Session, requestType: String) async throws -> [GenericListOption] {
        var comps = URLComponents(string: "\(PORTAL_URL)/GetGenericList")!
        comps.queryItems = [
            URLQueryItem(name: "requestType", value: requestType),
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&request, session: session)

        let (data, response) = try await httpSession.data(for: request)
        try checkAuthenticated(response, data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VTAPIError.message("GetGenericList failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let decoded = try JSONDecoder().decode(GenericListResponse.self, from: data)
        return decoded.d.SelectFields ?? []
    }

    // MARK: Helpers

    /// Throws `.sessionExpired` when the portal signals this token is no longer valid.
    /// Two signals exist: HTTP 401/403, or (for every authenticated endpoint) a body
    /// with `d.Status == -74` — the sentinel returned when the session was stolen by
    /// a login elsewhere (e.g. on the phone).
    private func checkAuthenticated(_ response: URLResponse?, _ data: Data) throws {
        if let http = response as? HTTPURLResponse,
           http.statusCode == 401 || http.statusCode == 403 {
            throw VTAPIError.sessionExpired
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["d"] as? [String: Any],
              d["Status"] as? Int == -74 else { return }
        throw VTAPIError.sessionExpired
    }

    private func setAuthHeaders(_ request: inout URLRequest, session: Session) {
        request.setValue(session.guid, forHTTPHeaderField: "roAuth")
        request.setValue(session.token, forHTTPHeaderField: "roToken")
        request.setValue("false", forHTTPHeaderField: "roSrc")
        request.setValue(session.companyId, forHTTPHeaderField: "roCompanyID")
        request.setValue("VTPortal", forHTTPHeaderField: "roApp")
        request.setValue("ro_VtportalTokenID=\(session.token)", forHTTPHeaderField: "Cookie")
    }

    /// Converts a "/Date(1716000000000+0100)/" string into a Date.
    static func parseMSDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.replacingOccurrences(of: #".*/Date\("#, with: "", options: .regularExpression)
        let digits = trimmed.prefix { $0.isNumber }
        guard let ms = Double(digits) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }

    /// Removes <b>…</b> style markup from notification descriptions.
    static func stripHTML(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
