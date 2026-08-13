import Foundation
import ServiceManagement

struct PunchConfig: Codable, Equatable {
    var time: String
    var type: String
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let stopSchedulerOnQuit = "stopSchedulerOnQuit"
        static let launchAtLogin = "launchAtLogin"
        static let punchConfigs = "punchConfigs"
        static let vtUser = "vtUser"
        static let vtPassword = "vtPassword"
        static let vtCompanyId = "vtCompanyId"
        static let handledPunchDates = "handledPunchDates"
    }

    @Published var stopSchedulerOnQuit: Bool {
        didSet { defaults.set(stopSchedulerOnQuit, forKey: Keys.stopSchedulerOnQuit) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            setLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var punchConfigs: [PunchConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(punchConfigs) {
                defaults.set(data, forKey: Keys.punchConfigs)
            }
        }
    }
    @Published var vtUser: String {
        didSet { defaults.set(vtUser, forKey: Keys.vtUser) }
    }
    @Published var vtPassword: String {
        didSet { defaults.set(vtPassword, forKey: Keys.vtPassword) }
    }
    @Published var vtCompanyId: String {
        didSet { defaults.set(vtCompanyId, forKey: Keys.vtCompanyId) }
    }

    /// ISO dates ("yyyy-MM-dd") whose missing punch was already submitted via this app,
    /// so stale "Incomplete punches" notifications for them can be hidden.
    @Published var handledPunchDates: Set<String> {
        didSet { defaults.set(Array(handledPunchDates), forKey: Keys.handledPunchDates) }
    }

    private let defaults = UserDefaults.standard

    init() {
        stopSchedulerOnQuit = defaults.object(forKey: Keys.stopSchedulerOnQuit) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false

        handledPunchDates = Set(defaults.stringArray(forKey: Keys.handledPunchDates) ?? [])

        if let data = defaults.data(forKey: Keys.punchConfigs),
           let configs = try? JSONDecoder().decode([PunchConfig].self, from: data) {
            punchConfigs = configs
        } else {
            punchConfigs = [
                PunchConfig(time: "07:00", type: "in"),
                PunchConfig(time: "12:00", type: "out"),
                PunchConfig(time: "13:00", type: "in"),
                PunchConfig(time: "16:00", type: "out")
            ]
        }

        vtUser = defaults.string(forKey: Keys.vtUser) ?? ""
        vtPassword = defaults.string(forKey: Keys.vtPassword) ?? ""
        vtCompanyId = defaults.string(forKey: Keys.vtCompanyId) ?? ""

        // One-time import from the legacy ~/Dachdev/vt-puncher/.env file.
        if !hasValidCredentials {
            moveCredentialsFromEnvFile()
        }
    }

    /// Reads VT_USER / VT_PASSWORD / VT_COMPANY_ID from the default .env file
    /// (once) so existing users keep their credentials without entering them again.
    private func moveCredentialsFromEnvFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envURL = URL(fileURLWithPath: home)
            .appendingPathComponent("Dachdev/vt-puncher")
            .appendingPathComponent(".env")

        guard let content = try? String(contentsOf: envURL, encoding: .utf8) else { return }

        var values: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                values[key] = value
            }
        }

        vtUser = values["VT_USER"] ?? ""
        vtPassword = values["VT_PASSWORD"] ?? ""
        vtCompanyId = values["VT_COMPANY_ID"] ?? ""
    }

    var hasValidCredentials: Bool {
        !vtUser.isEmpty && !vtPassword.isEmpty && !vtCompanyId.isEmpty
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            }
        }
    }
}

extension AppSettings {
    var hasValidPunchConfig: Bool {
        !punchConfigs.isEmpty && punchConfigs.allSatisfy { config in
            config.time.count == 5 && (config.type == "in" || config.type == "out")
        }
    }
}
