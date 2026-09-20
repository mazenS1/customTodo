import Foundation

/// Public, non-secret application settings loaded from the configuration bundled at build time.
///
/// The checked-in example deliberately contains generic values. A contributor who needs local
/// organization names, paths, or identifiers copies it to `Config/AppConfig.plist`; that override
/// is ignored by Git and embedded only in their local build. Credentials do not belong in either
/// file because the configuration is copied into the application bundle as a readable resource.
struct AppConfig: Decodable {
    let appName: String
    let bundleIdentifier: String
    let bundleVersion: String
    let executableName: String
    let marketingVersion: String
    let minimumSystemVersion: String
    let storageDirectoryName: String
    let projectRootPath: String
    let projectDirectoryPrefix: String
    let legacyTodoFilename: String
    let defaultCodexExecutable: String
    let defaultDailyReviewLimit: Int
    let maximumDailyReviewLimit: Int
    let quickReviewMinutes: Int
    let deepReviewMinutes: Int
    let categories: [String]

    enum CodingKeys: String, CodingKey {
        case appName = "AppName"
        case bundleIdentifier = "BundleIdentifier"
        case bundleVersion = "BundleVersion"
        case executableName = "ExecutableName"
        case marketingVersion = "MarketingVersion"
        case minimumSystemVersion = "MinimumSystemVersion"
        case storageDirectoryName = "StorageDirectoryName"
        case projectRootPath = "ProjectRootPath"
        case projectDirectoryPrefix = "ProjectDirectoryPrefix"
        case legacyTodoFilename = "LegacyTodoFilename"
        case defaultCodexExecutable = "DefaultCodexExecutable"
        case defaultDailyReviewLimit = "DefaultDailyReviewLimit"
        case maximumDailyReviewLimit = "MaximumDailyReviewLimit"
        case quickReviewMinutes = "QuickReviewMinutes"
        case deepReviewMinutes = "DeepReviewMinutes"
        case categories = "Categories"
    }

    static let current: AppConfig = {
        let url: URL
#if SELF_TESTS
        // The test executable is intentionally built outside an app bundle. The build script
        // supplies the selected config path explicitly; production builds never trust this
        // environment variable, preventing launch-time configuration injection.
        guard let path = ProcessInfo.processInfo.environment["TODO_INBOX_TEST_CONFIG"], !path.isEmpty else {
            fatalError("TODO_INBOX_TEST_CONFIG is required by the standalone test executable.")
        }
        url = URL(fileURLWithPath: path)
#else
        guard let bundled = Bundle.main.url(forResource: "AppConfig", withExtension: "plist") else {
            fatalError("AppConfig.plist is missing from the application bundle.")
        }
        url = bundled
#endif

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 64 * 1024 else { throw ConfigError.oversized }
            let config = try PropertyListDecoder().decode(AppConfig.self, from: data)
            try config.validate()
            return config
        } catch {
            fatalError("Invalid application configuration: \(error.localizedDescription)")
        }
    }()

    /// Expands only a leading `~` into the current user's home directory. No shell is involved,
    /// so command substitutions and other shell syntax remain inert text.
    func expandedPath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let suffix = path == "~" ? "" : String(path.dropFirst(2))
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(suffix).standardizedFileURL.path
    }

    private func validate() throws {
        let required = [appName, bundleIdentifier, bundleVersion, executableName,
                        marketingVersion, minimumSystemVersion, storageDirectoryName,
                        projectRootPath, projectDirectoryPrefix, legacyTodoFilename,
                        defaultCodexExecutable]
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConfigError.emptyRequiredValue
        }
        guard bundleIdentifier.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#,
                                     options: .regularExpression) != nil else {
            throw ConfigError.invalidBundleIdentifier
        }
        guard executableName.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ConfigError.invalidExecutableName
        }
        guard expandedPath(projectRootPath).hasPrefix("/"),
              expandedPath(defaultCodexExecutable).hasPrefix("/") else {
            throw ConfigError.nonAbsolutePath
        }
        guard (1...maximumDailyReviewLimit).contains(defaultDailyReviewLimit),
              maximumDailyReviewLimit <= 10_000,
              (1...120).contains(quickReviewMinutes),
              (quickReviewMinutes...240).contains(deepReviewMinutes) else {
            throw ConfigError.invalidNumericRange
        }
        guard !categories.isEmpty,
              categories.count <= 100,
              Set(categories).count == categories.count,
              categories.allSatisfy({ !$0.isEmpty && $0.count <= 80 && $0 != "Auto" }) else {
            throw ConfigError.invalidCategories
        }
    }

    private enum ConfigError: LocalizedError {
        case oversized, emptyRequiredValue, invalidBundleIdentifier, invalidExecutableName, nonAbsolutePath
        case invalidNumericRange, invalidCategories

        var errorDescription: String? {
            switch self {
            case .oversized: return "the file exceeds 64 KiB"
            case .emptyRequiredValue: return "a required string is empty"
            case .invalidBundleIdentifier: return "BundleIdentifier is malformed"
            case .invalidExecutableName: return "ExecutableName contains unsupported characters"
            case .nonAbsolutePath: return "configured paths must be absolute or begin with ~/"
            case .invalidNumericRange: return "a numeric value is outside its safe range"
            case .invalidCategories: return "Categories must contain unique, non-empty public labels"
            }
        }
    }
}
