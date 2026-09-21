import 'dart:async';

import 'channels.dart';
import 'configuration.dart';
import 'exception.dart';
import 'in_app_manager.dart';
import 'push_manager.dart';

/// The entry point of the Narya Flutter SDK.
///
/// `Narya` is a thin bridge over the Narya native SDKs. Every call below maps to
/// exactly one native call: batching, storage, session bookkeeping, in-app
/// fetching and rendering, and inbox persistence all stay native.
///
/// Call [initialize] once, as early as possible, before any other member:
///
/// ```dart
/// await Narya.initialize(
///   const NaryaConfiguration(
///     writeKey: '<MITHRA_FLUTTER_WRITE_KEY>',
///     environment: NaryaEnvironment.production,
///   ),
/// );
/// ```
abstract final class Narya {
  static final NaryaPlatform _platform = NaryaPlatform.instance;
  static final NaryaPushManager _push = NaryaPushManager(_platform);
  static final NaryaInAppManager _inApp = NaryaInAppManager(_platform);

  static bool _initialized = false;

  /// Starts the native SDK.
  ///
  /// The call is idempotent: repeating it with an identical [configuration] is
  /// a no-op. Repeating it with a *different* configuration throws a
  /// [NaryaException] with code `already_initialized`, because the native SDKs
  /// cannot be reconfigured in place.
  ///
  /// Throws a [NaryaException] with code `missing_write_key` when
  /// [NaryaConfiguration.writeKey] is empty.
  static Future<void> initialize(NaryaConfiguration configuration) async {
    await _platform.invoke('initialize', <String, Object?>{
      'configuration': configuration.toMap(),
    });
    _initialized = true;
  }

  /// Whether [initialize] has completed successfully in this isolate.
  ///
  /// Calling any other member while this is `false` throws a [NaryaException]
  /// with code `not_initialized`.
  static bool get isInitialized => _initialized;

  /// Associates the current device with a user, and merges [traits] into that
  /// user's profile.
  ///
  /// Passing no [userId] updates traits for whoever is currently identified.
  static Future<void> identify({String? userId, Map<String, Object?>? traits}) {
    return _platform.invoke('identify', <String, Object?>{
      'userId': userId,
      'traits': traits,
    });
  }

  /// Records that something happened.
  static Future<void> track(String name, {Map<String, Object?>? properties}) {
    return _platform.invoke('track', <String, Object?>{
      'name': name,
      'properties': properties,
    });
  }

  /// Records that the user looked at a screen.
  ///
  /// Prefer installing `NaryaRouteObserver` over calling this by hand; use this
  /// for screens your navigator does not model as a route. The native
  /// automatic screen-tracking options are intentionally left off, because a
  /// Flutter app is a single native view controller or activity and would emit
  /// one meaningless screen event.
  static Future<void> screen(
    String name, {
    String? category,
    Map<String, Object?>? properties,
  }) {
    return _platform.invoke('screen', <String, Object?>{
      'name': name,
      'category': category,
      'properties': properties,
    });
  }

  /// Associates the current user with a group, such as an account or company.
  static Future<void> group(String groupId, {Map<String, Object?>? traits}) {
    return _platform.invoke('group', <String, Object?>{
      'groupId': groupId,
      'traits': traits,
    });
  }

  /// Records that the user is now known by [newId].
  static Future<void> alias(String newId, {String? previousId}) {
    return _platform.invoke('alias', <String, Object?>{
      'newId': newId,
      'previousId': previousId,
    });
  }

  /// Uploads everything currently buffered, without waiting for a flush
  /// policy.
  static Future<void> flush() => _platform.invoke('flush');

  /// Clears the identified user, their traits and the anonymous id.
  ///
  /// Call it on sign-out.
  static Future<void> reset() => _platform.invoke('reset');

  /// Stops or resumes collection.
  ///
  /// While opted out, every event API is a no-op, no batch is uploaded, no
  /// source config is fetched, no push token is registered and the in-app
  /// module stops syncing. Unlike [shutdown] this is reversible, which is what
  /// a consent prompt needs: a user who withdraws consent can grant it again.
  ///
  /// The decision is persisted natively, so it survives relaunches. On the very
  /// first launch it starts at [NaryaConfiguration.startsOptedOut].
  ///
  /// **Opting out discards whatever is still queued on the device.** Events
  /// collected while consent was in force are not delivered after it is
  /// withdrawn: sending a backlog after a user has said stop is the behaviour
  /// that would surprise them. Call [flush] first if you need them delivered.
  ///
  /// ```dart
  /// // Behind a consent prompt
  /// await Narya.initialize(
  ///   const NaryaConfiguration(writeKey: '…', startsOptedOut: true),
  /// );
  ///
  /// // …once the person has chosen
  /// await Narya.setOptOut(!consentGranted);
  /// ```
  ///
  /// This does not delete data already delivered to Mithra. Handle erasure
  /// requests through Mithra rather than through the SDK.
  // The positional parameter keeps one vocabulary across the three SDKs:
  // `analytics.optOut = true` on iOS and Android, `Narya.setOptOut(true)` here.
  // Same reasoning as NaryaInAppManager.setAutoDisplayPaused.
  // ignore: avoid_positional_boolean_parameters
  static Future<void> setOptOut(bool optOut) {
    return _platform.invoke('setOptOut', <String, Object?>{'optOut': optOut});
  }

  /// Whether the SDK has stopped collecting.
  ///
  /// Read from the native instance, so it reflects a decision persisted on an
  /// earlier launch as well as one made in this one. See [setOptOut].
  ///
  /// Because the value is the native instance's, and no instance exists before
  /// [initialize] completes, a read before then answers `false` -- "collecting"
  /// -- rather than the persisted choice. A consent toggle bound straight to
  /// this getter would therefore flash the wrong state on launch; read it after
  /// [initialize] has completed.
  static Future<bool> get optOut async =>
      await _platform.invokeOptional<bool>('optOut') ?? false;

  /// Starts a session, optionally with a caller-supplied [sessionId].
  ///
  /// Only useful when
  /// [NaryaSessionConfiguration.automaticSessionTracking] is `false`.
  static Future<void> startSession({int? sessionId}) {
    return _platform.invoke('startSession', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  /// Ends the current session.
  static Future<void> endSession() => _platform.invoke('endSession');

  /// The device-scoped anonymous identifier.
  static Future<String?> get anonymousId =>
      _platform.invokeOptional<String>('anonymousId');

  /// The identifier of the currently identified user, when there is one.
  static Future<String?> get userId =>
      _platform.invokeOptional<String>('userId');

  /// The traits of the currently identified user, when there are any.
  static Future<Map<String, Object?>?> get traits =>
      _platform.invokeMap('traits');

  /// The current session identifier, when a session is active.
  static Future<int?> get sessionId =>
      _platform.invokeOptional<int>('sessionId');

  /// Records that the app was opened through [url].
  ///
  /// Use it for deep links your app receives outside the native SDK's
  /// automatic tracking, for example from a Flutter link-handling plugin.
  static Future<void> openUrl(Uri url, {Map<String, Object?>? options}) {
    return _platform.invoke('openUrl', <String, Object?>{
      'url': url.toString(),
      'options': options,
    });
  }

  /// Flushes and tears down the native instance.
  ///
  /// After this, [initialize] must be called again before any other member.
  static Future<void> shutdown() async {
    await _platform.invoke('shutdown');
    _initialized = false;
  }

  /// The push-notification bridge.
  static NaryaPushManager get push => _push;

  /// The in-app message and mobile inbox bridge.
  static NaryaInAppManager get inApp => _inApp;
}
