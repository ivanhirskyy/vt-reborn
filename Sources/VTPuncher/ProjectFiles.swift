import Foundation

// Credentials now come from the app's own settings, not from a project .env file.

enum ProjectFiles {
    static func loadCredentials() throws -> Credentials {
        let settings = AppSettings.shared
        guard settings.hasValidCredentials else {
            throw VTAPIError.message(
                "Missing VT credentials. Open Settings and fill in VT_USER, VT_PASSWORD, VT_COMPANY_ID."
            )
        }
        return Credentials(
            user: settings.vtUser,
            password: settings.vtPassword,
            companyId: settings.vtCompanyId
        )
    }
}
