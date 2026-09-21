import Foundation
import MithraAnalytics

/// Thrown when the Dart configuration map cannot produce a native configuration.
struct NaryaConfigurationError: Error {
    /// The code reported to Dart, which becomes `NaryaException.code`.
    let code: String
    /// The human-readable reason.
    let message: String
}

/// Decodes the `NaryaConfiguration.toMap()` wire form into the native
/// `Configuration`.
///
/// Defaults mirror the Dart defaults so an absent key and an explicit default
/// behave identically.
enum NaryaConfigurationCodec {

    static func decode(_ source: [String: Any]?) throws -> Configuration {
        guard let source else {
            throw NaryaConfigurationError(
                code: "invalid_argument",
                message: "initialize was called without a configuration."
            )
        }
        guard
            let writeKey = source["writeKey"] as? String,
            !writeKey.isEmpty
        else {
            throw NaryaConfigurationError(
                code: "missing_write_key",
                message: "NaryaConfiguration.writeKey is required and must not be blank."
            )
        }

        let environment: NaryaEnvironment =
            (source["environment"] as? String) == "staging" ? .staging : .production
        let dataPlaneUrl = (source["dataPlaneUrl"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }

        return Configuration(
            writeKey: writeKey,
            dataPlaneUrl: dataPlaneUrl,
            environment: environment,
            gzipEnabled: source["gzipEnabled"] as? Bool ?? false,
            collectDeviceId: source["collectDeviceId"] as? Bool ?? true,
            startsOptedOut: source["startsOptedOut"] as? Bool ?? false,
            trackApplicationLifecycleEvents:
                source["trackApplicationLifecycleEvents"] as? Bool ?? true,
            // Flutter screen tracking is NaryaRouteObserver; the native option
            // would emit one event for the single FlutterViewController, and it
            // also suppresses manual screen() calls.
            trackApplicationScreens: false,
            trackDeepLinks: source["trackDeepLinks"] as? Bool ?? true,
            sessionConfiguration: decodeSession(source["session"] as? [String: Any]),
            inApp: decodeInApp(source["inApp"] as? [String: Any]),
            logLevel: decodeLogLevel(source["logLevel"] as? String)
        )
    }

    /// `SessionConfiguration` does not expose `automaticSessionTracking` and
    /// `sessionTimeoutInMillis` publicly, so the fallbacks come from the SDK's
    /// public default constants instead of an instance.
    private static var defaultAutomaticSessionTracking: Bool {
        Constants.defaultConfig.automaticSessionTrackingStatus
    }
    private static var defaultSessionTimeoutInMillis: UInt64 {
        Constants.defaultConfig.sessionTimeoutInMillis
    }

    private static func decodeSession(_ source: [String: Any]?) -> SessionConfiguration {
        let defaults = SessionConfiguration()
        guard let source else { return defaults }
        let timeout = (source["sessionTimeoutInMillis"] as? NSNumber)?.uint64Value
        return SessionConfiguration(
            automaticSessionTracking: source["automaticSessionTracking"] as? Bool
                ?? defaultAutomaticSessionTracking,
            sessionTimeoutInMillis: timeout ?? defaultSessionTimeoutInMillis,
            updateSessionOnBackgroundEvents:
                source["updateSessionOnBackgroundEvents"] as? Bool
                ?? defaults.updateSessionOnBackgroundEvents
        )
    }

    private static func decodeInApp(_ source: [String: Any]?) -> InAppConfiguration {
        let defaults = InAppConfiguration()
        guard let source else { return defaults }
        let interval = (source["displayIntervalInSeconds"] as? NSNumber)?.doubleValue
        let colorScheme: InAppColorScheme
        switch source["colorScheme"] as? String {
        case "light": colorScheme = .light
        case "dark": colorScheme = .dark
        default: colorScheme = .system
        }
        return InAppConfiguration(
            enabled: source["enabled"] as? Bool ?? defaults.enabled,
            displayInterval: interval ?? defaults.displayInterval,
            autoDisplayPaused: source["autoDisplayPaused"] as? Bool
                ?? defaults.autoDisplayPaused,
            useInMemoryStorage: source["useInMemoryStorage"] as? Bool
                ?? defaults.useInMemoryStorage,
            colorScheme: colorScheme,
            webViewBaseUrl: (source["webViewBaseUrl"] as? String)
                .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        )
    }

    private static func decodeLogLevel(_ source: String?) -> LogLevel {
        switch source {
        case "verbose": return .verbose
        case "debug": return .debug
        case "info": return .info
        case "warn": return .warn
        case "error": return .error
        default: return .none
        }
    }

    /// A comparison key used to decide whether a repeated `initialize` call is
    /// an idempotent no-op or a genuine reconfiguration attempt.
    static func identity(of source: [String: Any]?) -> String {
        guard let source else { return "" }
        return source.keys.sorted()
            .map { "\($0)=\(String(describing: source[$0]))" }
            .joined(separator: "|")
    }
}
