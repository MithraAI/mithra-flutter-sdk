/// The Mithra environment the SDK sends events to.
///
/// Each case maps to a dedicated Argonath SDK gateway inside the native SDKs.
/// Dart never hardcodes a gateway URL; supply
/// [NaryaConfiguration.dataPlaneUrl] to override the mapping.
enum NaryaEnvironment {
  /// The Mithra production environment. This is the default.
  production,

  /// The Mithra pre-production (staging) environment.
  staging,
}

/// How much the native SDK logs.
enum NaryaLogLevel {
  /// Log everything, including per-event payload detail.
  verbose,

  /// Log debug-level diagnostics and above.
  debug,

  /// Log informational messages and above.
  info,

  /// Log warnings and errors only.
  warn,

  /// Log errors only.
  error,

  /// Log nothing. This is the default.
  none,
}

/// The appearance forced on the in-app message web view.
enum NaryaInAppColorScheme {
  /// Follow the device appearance.
  system,

  /// Always render in light appearance.
  light,

  /// Always render in dark appearance.
  dark,
}

/// Session-tracking settings passed to the native SDKs.
class NaryaSessionConfiguration {
  /// Creates a session configuration.
  const NaryaSessionConfiguration({
    this.automaticSessionTracking = true,
    this.sessionTimeout = const Duration(minutes: 5),
    this.updateSessionOnBackgroundEvents = false,
  });

  /// Whether the SDK starts and renews sessions on its own.
  ///
  /// When `false`, drive sessions with `Narya.startSession` and
  /// `Narya.endSession`.
  final bool automaticSessionTracking;

  /// The idle window after which the next foreground event starts a new
  /// session.
  ///
  /// Sent to both native SDKs as whole milliseconds.
  final Duration sessionTimeout;

  /// Whether events tracked while the app is backgrounded refresh the session
  /// timeout.
  final bool updateSessionOnBackgroundEvents;

  /// The wire form sent over the method channel.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'automaticSessionTracking': automaticSessionTracking,
      'sessionTimeoutInMillis': sessionTimeout.inMilliseconds,
      'updateSessionOnBackgroundEvents': updateSessionOnBackgroundEvents,
    };
  }
}

/// In-app message and mobile inbox settings passed to the native SDKs.
class NaryaInAppConfiguration {
  /// Creates an in-app configuration.
  const NaryaInAppConfiguration({
    this.enabled = true,
    this.displayInterval = const Duration(seconds: 30),
    this.autoDisplayPaused = false,
    this.useInMemoryStorage = false,
    this.colorScheme = NaryaInAppColorScheme.system,
    this.webViewBaseUrl,
  });

  /// Whether the in-app and inbox feature is active at all.
  final bool enabled;

  /// The minimum delay between two automatically displayed messages.
  ///
  /// Sent to both native SDKs as fractional seconds.
  final Duration displayInterval;

  /// Whether automatic display starts paused.
  ///
  /// Toggle it later with `NaryaInAppManager.setAutoDisplayPaused`.
  final bool autoDisplayPaused;

  /// Whether the native message store lives in memory only.
  final bool useInMemoryStorage;

  /// The appearance forced on the message web view.
  final NaryaInAppColorScheme colorScheme;

  /// The document base URL the message HTML is loaded with.
  ///
  /// Leave `null` to let the native SDK choose.
  final String? webViewBaseUrl;

  /// The wire form sent over the method channel.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'enabled': enabled,
      'displayIntervalInSeconds': displayInterval.inMilliseconds / 1000.0,
      'autoDisplayPaused': autoDisplayPaused,
      'useInMemoryStorage': useInMemoryStorage,
      'colorScheme': colorScheme.name,
      'webViewBaseUrl': webViewBaseUrl,
    };
  }
}

/// Everything the native SDK needs in order to start.
///
/// A Mithra Flutter client key is cross-platform: the single [writeKey] issued
/// for your Flutter app is used by both the iOS and the Android build, so
/// there is nothing platform-specific to configure here.
class NaryaConfiguration {
  /// Creates a configuration.
  const NaryaConfiguration({
    required this.writeKey,
    this.environment = NaryaEnvironment.production,
    this.dataPlaneUrl,
    this.trackApplicationLifecycleEvents = true,
    this.trackDeepLinks = true,
    this.collectDeviceId = true,
    this.gzipEnabled = false,
    this.session = const NaryaSessionConfiguration(),
    this.inApp = const NaryaInAppConfiguration(),
    this.logLevel = NaryaLogLevel.none,
    this.startsOptedOut = false,
  });

  /// The Mithra Flutter client write key, used on both iOS and Android.
  ///
  /// `Narya.initialize` throws `NaryaException` with code `missing_write_key`
  /// when it is empty.
  final String writeKey;

  /// Which Argonath gateway receives events when [dataPlaneUrl] is `null`.
  final NaryaEnvironment environment;

  /// An explicit gateway URL that wins over [environment].
  ///
  /// Use it to point a debug build at a gateway on the development machine.
  final String? dataPlaneUrl;

  /// Whether the native SDK tracks application install, open and update
  /// lifecycle events.
  final bool trackApplicationLifecycleEvents;

  /// Whether the native SDK tracks deep-link opens automatically.
  final bool trackDeepLinks;

  /// Whether the native SDK collects the device identifier.
  ///
  /// Honoured on Android; the iOS SDK follows its own default on this path.
  final bool collectDeviceId;

  /// Whether event uploads are GZip compressed.
  final bool gzipEnabled;

  /// Session-tracking settings.
  final NaryaSessionConfiguration session;

  /// In-app message and inbox settings.
  final NaryaInAppConfiguration inApp;

  /// How much the native SDK logs.
  final NaryaLogLevel logLevel;

  /// Whether the SDK starts opted out, collecting nothing until
  /// `Narya.setOptOut(false)`.
  ///
  /// Set it behind a consent prompt: `Narya.initialize` can then run at app
  /// start — so the native lifecycle hooks are installed and a cold-start push
  /// is handled — while nothing is persisted, requested or sent until the user
  /// has answered.
  ///
  /// Only the first launch reads it. After that the persisted decision wins, so
  /// a user who granted consent is not asked to grant it again.
  final bool startsOptedOut;

  /// The wire form sent over the method channel.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'writeKey': writeKey,
      'environment': environment.name,
      'dataPlaneUrl': dataPlaneUrl,
      'trackApplicationLifecycleEvents': trackApplicationLifecycleEvents,
      'trackDeepLinks': trackDeepLinks,
      'collectDeviceId': collectDeviceId,
      'gzipEnabled': gzipEnabled,
      'session': session.toMap(),
      'inApp': inApp.toMap(),
      'logLevel': logLevel.name,
      'startsOptedOut': startsOptedOut,
    };
  }
}
