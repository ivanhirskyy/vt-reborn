import SwiftUI

@main
struct VTRebornApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(model: AppModel.shared)
        mainWindowController = MainWindowController.shared

        // First launch with no credentials: open the window on the Settings tab
        // so the user knows where to configure the app.
        if !AppSettings.shared.hasValidCredentials {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppModel.shared.selectedTab = 3
                self.mainWindowController?.show()
            }
        }

        if CommandLine.arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.statusBarController?.openPopover()
            }
        }

        if CommandLine.arguments.contains("--open-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.mainWindowController?.show()
            }
        }

        if CommandLine.arguments.contains("--api-test") {
            Task { await runAPITest() }
        }
    }

    /// Dev hook: verify the API port against the live portal and exit.
    private func runAPITest() async {
        do {
            let client = VTAPIClient()
            let session = try await client.login(try ProjectFiles.loadCredentials())
            var out: [String] = []

            // Dump full JSON of vacation-type requests to find structured date fields.
            var url = URLComponents(string: "https://vtportal.visualtime.net/api/portalsvcx.svc/GetMyRequests")!
            url.queryItems = [URLQueryItem(name: "selectedDate", value: "01/08/2026"), URLQueryItem(name: "timestamp", value: "0"), URLQueryItem(name: "_", value: "0")]
            var request = URLRequest(url: url.url!)
            request.httpMethod = "GET"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(session.guid, forHTTPHeaderField: "roAuth")
            request.setValue(session.token, forHTTPHeaderField: "roToken")
            request.setValue("false", forHTTPHeaderField: "roSrc")
            request.setValue(session.companyId, forHTTPHeaderField: "roCompanyID")
            request.setValue("VTPortal", forHTTPHeaderField: "roApp")
            request.setValue("ro_VtportalTokenID=\(session.token)", forHTTPHeaderField: "Cookie")
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["d"] as? [String: Any],
               let reqs = d["Requests"] as? [[String: Any]] {
                for r in reqs {
                    let rt = r["IdRequestType"] as? Int ?? -1
                    guard [6, 11, 13].contains(rt) else { continue }
                    let name = r["Name"] as? String ?? ""
                    let status = r["NameStatus"] as? String ?? ""
                    let desc = r["Description"] as? String ?? ""
                    out.append("REQ type=\(rt) name=[\(name)] status=[\(status)]\n\(desc)\n--- all keys ---\n\(r.keys.sorted().joined(separator: ","))\n--- full ---\n\(String(data: try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted]), encoding: .utf8) ?? "")\n=====")
                }
            } else {
                out.append("GetMyRequests: parse fail")
            }

            try? out.joined(separator: "\n").write(toFile: "/tmp/vt-api-test.txt", atomically: true, encoding: .utf8)
        } catch {
            try? ("ERROR: \(error.localizedDescription)").write(toFile: "/tmp/vt-api-test.txt", atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }

    /// Clicking the Dock icon opens the app window (centered on screen).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController?.show()
        return true
    }

    /// The app stays alive in the menu bar when the window or popover closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
