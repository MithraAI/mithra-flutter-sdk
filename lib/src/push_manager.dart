import 'dart:async';
import 'dart:convert';

import 'channels.dart';
import 'in_app_models.dart';
import 'push_models.dart';

/// Push-notification bridge, reached through `Narya.push`.
///
/// There are two ways to get a device token into the SDK, and a host uses
/// exactly **one** of them per platform:
///
/// * **iOS, no Firebase** - call [registerForRemoteNotifications]. The plugin
///   requests notification permission, registers with APNs natively and
///   delivers the hex token on [onToken] *and* to the native SDK by itself, the
///   same way the native `narya-ios` demo does. This is the Iterable-style
///   path: nothing else is needed.
/// * **`firebase_messaging`** (Android always; iOS optionally) - the host
///   obtains the token from Firebase and hands it to [setToken]. Firebase
///   stays out of this plugin's dependency graph.
///
/// Rendering is split by platform. On Android, Mithra sends **data-only** FCM
/// messages, so the system posts nothing on its own: the host hands every
/// message from `FirebaseMessaging.onMessage` and `onBackgroundMessage` to
/// [handlePushMessage], and the native SDK renders the notification (title,
/// body, image, action buttons, channel) exactly as it does for a native
/// `FirebaseMessagingService`. On iOS rich pushes need a native Notification
/// Service Extension target linking `MithraAnalyticsNotificationService`; that
/// is documented in the README rather than bridged.
class NaryaPushManager {
  /// Creates a manager. The plugin exposes a single instance as `Narya.push`.
  NaryaPushManager(this._platform);

  final NaryaPlatform _platform;

  /// iOS: requests notification permission and registers with APNs natively.
  ///
  /// The plugin asks `UNUserNotificationCenter` for authorization with the
  /// given options. When permission is granted - or was already granted or
  /// provisionally granted - it calls
  /// `UIApplication.registerForRemoteNotifications()` on the main thread. The
  /// resulting APNs token is delivered on [onToken] as a lowercase hex string
  /// and passed to the native SDK (`setPushToken`) without any host code; a
  /// token that arrives before `Narya.initialize` completes is queued and
  /// applied on initialization, so this may be called first. A failure is
  /// reported on [onRegistrationError].
  ///
  /// The plugin also **always** installs itself as the
  /// `UNUserNotificationCenter.current().delegate` (delegate chaining): it
  /// becomes the delegate and forwards every callback to whatever was
  /// installed before - the default `FlutterAppDelegate`, a host object, or a
  /// plugin such as `firebase_messaging`, which registers its own delegate on
  /// iOS even when you only use it for Android. Neither of those forwards
  /// `willPresent` / `didReceive(response:)` to this plugin, so without the
  /// takeover foreground pushes would show no banner and would not be tracked.
  /// As delegate the plugin shows foreground pushes, tracks Mithra ones
  /// (`push_delivered`) and routes taps to [onPushOpened] /
  /// [takeInitialPushPayload] (`push_opened`, with the tapped action); the
  /// previous delegate then receives the same callback (`willPresent` options
  /// are merged, and it owns the completion of `didReceive`), so its behaviour
  /// is preserved. A debug line names the chained class. The delegate is
  /// installed synchronously, before the permission round trip, so call this
  /// early (before or right after `Narya.initialize`) to capture a cold-start
  /// tap; a tap that arrives before initialization is replayed afterwards.
  ///
  /// Call this only if you want the Narya SDK to own APNs registration on iOS.
  /// If `firebase_messaging` should keep owning it, do not call this; feed
  /// [setToken] from `FirebaseMessaging.instance.getAPNSToken()` /
  /// `getToken()` instead and track taps with [trackOpened]. Never combine the
  /// two token paths on the same platform.
  ///
  /// Returns [NaryaPushAuthorizationStatus.unsupported] on Android without
  /// touching the platform: Android tokens come from Firebase Cloud Messaging
  /// and are registered with [setToken].
  ///
  /// Throws a `NaryaException` with code `authorization_failed` when the system
  /// permission request itself errors.
  Future<NaryaPushAuthorizationStatus> registerForRemoteNotifications({
    bool alert = true,
    bool badge = true,
    bool sound = true,
  }) async {
    final String? raw = await _platform.invokeOptional<String>(
      'push.registerForRemoteNotifications',
      <String, Object?>{'alert': alert, 'badge': badge, 'sound': sound},
    );
    return decodeNaryaPushAuthorizationStatus(raw);
  }

  /// iOS: emits the APNs device token as a lowercase hex string.
  ///
  /// Fires after [registerForRemoteNotifications] succeeds and again whenever
  /// the system rotates the token. The plugin has already registered the token
  /// with the native SDK by the time this emits; listen to display it, log it
  /// or forward it to your own backend. Android never emits.
  Stream<String> get onToken {
    return _platform
        .eventsOfType(NaryaEventType.pushToken)
        .map((Map<String, Object?> payload) => payload['token'])
        .where((Object? token) => token is String && token.isNotEmpty)
        .cast<String>();
  }

  /// iOS: emits when APNs registration fails after
  /// [registerForRemoteNotifications] requested it. Android never emits.
  Stream<NaryaPushRegistrationError> get onRegistrationError {
    return _platform
        .eventsOfType(NaryaEventType.pushRegistrationError)
        .map(NaryaPushRegistrationError.fromMap);
  }

  /// Registers a device token obtained by the host with the native SDK.
  ///
  /// Use this on Android (FCM token from `firebase_messaging`) and on iOS when
  /// the app uses `firebase_messaging` for APNs. On iOS without Firebase, call
  /// [registerForRemoteNotifications] instead; it feeds the token to the SDK by
  /// itself.
  Future<void> setToken(String token) {
    return _platform.invoke('push.setToken', <String, Object?>{'token': token});
  }

  /// Clears any previously registered device token.
  Future<void> clearToken() => _platform.invoke('push.clearToken');

  /// iOS: sets the app icon badge number. Android: a no-op.
  ///
  /// Every alert push gwaihir sends carries `badge = 1`, so iOS lights the app
  /// icon badge on the first notification and **nothing ever turns it off
  /// again**: APNs only changes the badge when a payload sets it, and no
  /// payload ever sets it back to zero. Clearing the badge is therefore the
  /// host's job. The usual place is when the app comes to the foreground:
  ///
  /// ```dart
  /// @override
  /// void didChangeAppLifecycleState(AppLifecycleState state) {
  ///   if (state == AppLifecycleState.resumed) Narya.push.clearBadge();
  /// }
  /// ```
  ///
  /// A negative [count] is clamped to `0`; `0` clears the badge, which is what
  /// [clearBadge] does.
  ///
  /// The SDK deliberately **never** changes the badge on its own - not when it
  /// renders a push, not when the app starts, and not when the inbox unread
  /// count changes. An app whose badge should follow the mobile inbox wires
  /// that itself, by feeding
  /// `Narya.inApp.unreadInboxMessageCount` /
  /// `Narya.inApp.onUnreadInboxMessageCountChanged` into this method:
  ///
  /// ```dart
  /// Narya.inApp.onUnreadInboxMessageCountChanged.listen(
  ///   Narya.push.setBadgeCount,
  /// );
  /// ```
  ///
  /// **Android does nothing** and returns normally: Android has no platform
  /// app-icon badge API. Launchers derive the dot or count from the
  /// notifications the app currently has posted, so a badge is cleared by
  /// dismissing or cancelling those notifications, not by an SDK call. The
  /// method exists on both platforms so host code needs no `Platform.isIOS`
  /// branch.
  Future<void> setBadgeCount(int count) {
    return _platform.invoke('push.setBadgeCount', <String, Object?>{
      'count': count < 0 ? 0 : count,
    });
  }

  /// Clears the app icon badge. Identical to `setBadgeCount(0)`.
  ///
  /// See [setBadgeCount] for why this is the host's responsibility and for
  /// Android's no-op behaviour.
  Future<void> clearBadge() => setBadgeCount(0);

  /// Tracks that a notification arrived on the device.
  ///
  /// Call it from your foreground or background message handler. [payload] is
  /// the raw APNs `userInfo` or FCM data map. On Android prefer
  /// [handlePushMessage], which tracks the delivery **and** renders the
  /// notification; use this alone only when something else already posted
  /// one. Like [handlePushMessage], this works in the Android background
  /// isolate from the persisted configuration.
  Future<void> trackReceived(Map<String, Object?> payload) {
    return _platform.invoke('push.trackReceived', <String, Object?>{
      'payload': payload,
    });
  }

  /// Android: tracks `push_delivered` and renders the system notification for
  /// a data-only FCM message through the native SDK.
  ///
  /// Mithra pushes reach Android as **data-only** FCM messages, so Firebase
  /// posts nothing by itself. Call this with `RemoteMessage.data` from **both**
  /// `FirebaseMessaging.onMessage` (foreground) and the top-level
  /// `FirebaseMessaging.onBackgroundMessage` handler (background and
  /// terminated), after gating with [isNaryaPush]. The native SDK then does
  /// everything the native Android demo's `FirebaseMessagingService` does:
  /// tracks `push_delivered`, creates the notification channel, posts the
  /// notification with title, body, image and action buttons, and wires the
  /// tap so it arrives on [onPushOpened] / [takeInitialPushPayload].
  ///
  /// Silent payloads (`is_silent` = `true` / `1` / `yes`) post nothing. A
  /// silent payload that carries `inapp_sync` is the gwaihir in-app wake push:
  /// the SDK consumes it, syncs the in-app messages and deliberately does not
  /// report `push_delivered` for it, so no extra wiring is needed. Every other
  /// silent payload is still tracked as delivered.
  ///
  /// The call is safe in the `firebase_messaging` **background isolate**, where
  /// `Narya.initialize` never ran: the Android bridge keeps the native SDK
  /// instance process-wide and, in a fresh process, rebuilds it from the
  /// configuration persisted by the last successful `Narya.initialize`. It
  /// throws `NaryaException` with code `not_initialized` only when the app has
  /// never initialized Narya on this device. Remember to mark the handler
  /// `@pragma('vm:entry-point')`.
  ///
  /// [options] configures the status-bar icon, the tap activity and the
  /// notification channel; the defaults use the application icon, the launcher
  /// activity and the `narya_default` channel. A [NaryaPushDisplayOptions.smallIcon]
  /// or [NaryaPushDisplayOptions.tapActivity] that does not resolve throws
  /// `NaryaException` with code `invalid_argument`.
  ///
  /// Returns `true` when a notification was posted and `false` for a silent
  /// payload (including the in-app wake push). **iOS always returns `false`
  /// and does nothing**: there the system, or the Notification Service
  /// Extension for rich pushes, renders the notification.
  ///
  /// ```dart
  /// @pragma('vm:entry-point')
  /// Future<void> onBackgroundMessage(RemoteMessage message) async {
  ///   if (!Narya.push.isNaryaPush(message.data)) return;
  ///   await Narya.push.handlePushMessage(
  ///     message.data,
  ///     options: const NaryaPushDisplayOptions(smallIcon: 'ic_notification'),
  ///   );
  /// }
  /// ```
  Future<bool> handlePushMessage(
    Map<Object?, Object?> data, {
    NaryaPushDisplayOptions options = const NaryaPushDisplayOptions(),
  }) {
    return _platform.invokeRequired<bool>(
      'push.handlePushMessage',
      <String, Object?>{'payload': data, 'options': options.toMap()},
    );
  }

  /// Tracks that the user opened a notification.
  ///
  /// Call it for a notification your own code posted and routed. A tap the SDK
  /// itself reported - the payload of an [onPushOpened] event or of
  /// [takeInitialPushPayload] - has already been tracked when you receive it,
  /// and handing that same payload back here is recognised and ignored rather
  /// than counted twice, so listening and tracking cannot double-report one
  /// tap.
  Future<void> trackOpened(Map<String, Object?> payload) {
    return _platform.invoke('push.trackOpened', <String, Object?>{
      'payload': payload,
    });
  }

  /// Resolves the destination a notification payload asks the host to open.
  ///
  /// Returns `null` when the campaign set no deep link. The SDK never opens the
  /// URI; routing is the app's job.
  Future<Uri?> deepLinkFrom(Map<String, Object?> payload) async {
    final String? link = await _platform.invokeOptional<String>(
      'push.deepLinkFrom',
      <String, Object?>{'payload': payload},
    );
    return link == null ? null : Uri.tryParse(link);
  }

  /// Lets the native SDK act on a silent notification.
  ///
  /// Returns whether the SDK recognised and handled the payload, which for
  /// Mithra means an in-app sync request. Always returns `false` on Android,
  /// where silent pushes reach your `FirebaseMessagingService` directly.
  Future<bool> handleBackgroundNotification(Map<String, Object?> payload) {
    return _platform.invokeRequired<bool>(
      'push.handleBackgroundNotification',
      <String, Object?>{'payload': payload},
    );
  }

  /// Reports whether a raw push payload was sent by Mithra.
  ///
  /// This is the Narya equivalent of the reference SDK's `isIterablePush`
  /// gate. A host that receives pushes through `firebase_messaging` sees every
  /// message its app is sent, including ones from other providers, so it needs
  /// a way to decide whether a `RemoteMessage.data` map is one Mithra produced
  /// before handing it to [trackReceived], [trackOpened] or
  /// [handleBackgroundNotification]. None of those methods filter on their own.
  ///
  /// The predicate is **pure Dart**: it is synchronous, never touches a
  /// platform channel and does not require `Narya.initialize`. That makes it
  /// safe to call from the `firebase_messaging` background isolate, where the
  /// Narya bridge is not initialised, and from unit tests.
  ///
  /// ## Rule
  ///
  /// Three payload levels are inspected independently, exactly as the native
  /// SDKs do: the top-level keys, the `CustomData` value (a `Map`, or a JSON
  /// string decoding to an object) and the `mithra` envelope value (likewise a
  /// `Map` or a JSON string decoding to an object). The payload is a Mithra
  /// push when **any** level satisfies **any** of these:
  ///
  /// 1. `tracking` is present and non-empty: a non-empty string or a non-empty
  ///    map. Any other non-null value (a number, a boolean, a list) counts as
  ///    present too.
  /// 2. `inapp_sync` is truthy: `true`, a non-zero number, or one of the
  ///    strings `"true"`, `"1"`, `"yes"` compared case-insensitively and
  ///    **without** trimming (`" yes "` is not truthy).
  /// 3. `mithra_message_id` is a non-empty string.
  /// 4. The top-level `mithra` key holds an object: a `Map`, or a string that
  ///    decodes to a JSON object. `{}` counts; a bare string such as `"yes"`, a
  ///    number, a list or malformed JSON does not.
  ///
  /// Because each level is checked on its own, a blank marker at one level
  /// never masks a valid one at another. Whitespace is significant: `"   "` is
  /// a non-empty `tracking`. A `mithra` map nested inside `CustomData` is not
  /// the envelope and is not descended into.
  ///
  /// A bare `message_id` (or the `gcm.message_id` Firebase adds to every
  /// message) is deliberately **not** enough: those keys are not specific to
  /// Mithra. The key names come from gwaihir's push payload contract
  /// (`gwaihir/docs/push-payload-contract.md`), which both native SDKs and this
  /// predicate implement identically; the parity table is in
  /// `docs/api-contract.md`.
  ///
  /// ## Example
  ///
  /// ```dart
  /// FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
  ///   if (!Narya.push.isNaryaPush(message.data)) return;
  ///   await Narya.push.trackReceived(message.data);
  /// });
  ///
  /// @pragma('vm:entry-point')
  /// Future<void> onBackgroundMessage(RemoteMessage message) async {
  ///   // Runs in a separate isolate: Narya is NOT initialised here, but the
  ///   // gate is pure Dart and works anyway.
  ///   if (!Narya.push.isNaryaPush(message.data)) return;
  ///   // Hand off to native, or defer tracking to the main isolate.
  /// }
  ///
  /// FirebaseMessaging.onBackgroundMessage(onBackgroundMessage);
  /// ```
  ///
  /// [payload] accepts the loosely-typed `Map<String, dynamic>` that
  /// `firebase_messaging` yields as well as an APNs `userInfo` dictionary.
  bool isNaryaPush(Map<Object?, Object?> payload) {
    if (payload.isEmpty) return false;

    final Map<Object?, Object?>? customData = _asMap(payload[_customDataKey]);
    final Map<Object?, Object?>? overlay = _asMap(payload[_mithraKey]);
    final List<Map<Object?, Object?>> levels = <Map<Object?, Object?>>[
      payload,
      ?customData,
      ?overlay,
    ];

    for (final Map<Object?, Object?> level in levels) {
      if (_isNonEmptyValue(level[_trackingKey])) return true;
      if (_isTruthy(level[_inAppSyncKey])) return true;
      if (_isNonEmptyString(level[_mithraMessageIdKey])) return true;
    }

    return _hasMithraEnvelope(payload);
  }

  /// Returns the payload of the notification that cold-started the app, once.
  ///
  /// The Flutter engine attaches after the native tap is processed, so a
  /// cold-start open cannot arrive on [onPushOpened]. Call this during startup;
  /// a second call returns `null`.
  Future<Map<String, Object?>?> takeInitialPushPayload() {
    return _platform.invokeMap('push.takeInitialPushPayload');
  }

  /// Emits once for every notification the user opens while the app is running.
  ///
  /// Attaching a listener tells the native push-open handler that Dart owns
  /// routing, so the native layer will not also open the URL itself.
  Stream<NaryaPushOpenEvent> get onPushOpened {
    return _platform
        .eventsOfType(NaryaEventType.pushOpened)
        .map(NaryaPushOpenEvent.fromMap);
  }
}

// Wire keys shared with the native SDKs and gwaihir's push payload contract.
const String _trackingKey = 'tracking';
const String _inAppSyncKey = 'inapp_sync';
const String _mithraMessageIdKey = 'mithra_message_id';
const String _customDataKey = 'CustomData';
const String _mithraKey = 'mithra';

/// Values the native SDKs read as an enabled flag, after lower-casing (but not
/// trimming) a string value.
const Set<String> _truthyStrings = <String>{'true', '1', 'yes'};

/// Rule 4 of [NaryaPushManager.isNaryaPush]: the top-level `mithra` key holds
/// an object, mirroring iOS `hasMithraEnvelope`. Accepts exactly what [_asMap]
/// accepts: a `Map`, or a string decoding to a JSON object.
bool _hasMithraEnvelope(Map<Object?, Object?> payload) {
  return _asMap(payload[_mithraKey]) != null;
}

/// Normalises a `CustomData` / `mithra` value into a map: a `Map` is returned
/// as is, a string is JSON-decoded and accepted only when it yields an object.
/// Blank strings, malformed JSON and non-object documents give `null`.
Map<Object?, Object?>? _asMap(Object? raw) {
  if (raw is Map<Object?, Object?>) return raw;
  if (raw is! String || raw.trim().isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(raw);
    return decoded is Map<Object?, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Whether [value] is present and carries content, mirroring iOS
/// `isNonEmptyValue`.
///
/// A string must be non-empty (whitespace counts as content). A map must be
/// non-empty; that covers a caller that already decoded the `tracking` blob.
/// Any other non-null value (a number, a boolean, a list, even an empty one)
/// counts as present.
bool _isNonEmptyValue(Object? value) {
  if (value == null) return false;
  if (value is String) return value.isNotEmpty;
  if (value is Map<Object?, Object?>) return value.isNotEmpty;
  return true;
}

/// Whether [value] is a string with at least one character, mirroring iOS
/// `nonEmptyString`. Non-string values never match.
bool _isNonEmptyString(Object? value) {
  return value is String && value.isNotEmpty;
}

/// Interprets a payload value as a boolean flag, mirroring iOS `isTruthy`.
///
/// iOS accepts `Bool`, a non-zero `NSNumber` and the strings `"1"`, `"true"`,
/// `"yes"` lower-cased but not trimmed; Android sees FCM's string-only data and
/// accepts the same strings the same way.
bool _isTruthy(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return _truthyStrings.contains(value.toLowerCase());
  return false;
}
