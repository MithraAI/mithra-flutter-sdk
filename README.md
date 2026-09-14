<!-- GENERATED CONTENT - DO NOT EDIT BY HAND. -->

> **This repository is generated.** `mithra_flutter_sdk` is developed in
> [MithraAI/narya-flutter](https://github.com/MithraAI/narya-flutter); every
> file here is written by that repository's release workflow on each release
> and any manual edit is overwritten by the next one. Bug reports and feature
> requests are welcome in this repository's issues; code changes go to
> `narya-flutter`.

<div align="center">

# Narya

### _The Ring of Fire for Mobile_

<img src="assets/narya.jpg" alt="Narya - The Ring of Fire" width="720" />

<br />

> _"Take now this Ring, for thy labours and thy cares will be heavy,
> but in all it will support thee and defend thee from weariness."_
> _-- Cirdan the Shipwright, giving Narya to Gandalf_
>
> **Narya, the Ring of Fire**, kindles courage and action --
> and here it burns on iOS and Android from a single Dart call.

<br />

[![Dart](https://img.shields.io/badge/Dart-3.11+-0175C2?style=for-the-badge&logo=dart&logoColor=white)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-3.41+-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](./LICENSE)

---

**Mithra's Flutter SDK -- a thin bridge over the Narya native SDKs for
analytics, push notifications, in-app messages and the mobile inbox.**

</div>

---

## What this package is

`mithra_flutter_sdk` is a **bridge, not a re-implementation**. Every Dart call maps
to exactly one call on the native SDK underneath:

| Platform | Native SDK                                                             |
| -------- | ---------------------------------------------------------------------- |
| iOS      | [`narya-ios`](https://github.com/MithraAI/narya-ios) 1.3.x (Swift)     |
| Android  | [`narya-android`](https://github.com/MithraAI/narya-android) 1.3.x (Kotlin) |

Event batching, storage, session bookkeeping, in-app fetching, the display
queue and inbox persistence all stay native. In particular **in-app messages
are never rendered by Flutter**: the native SDKs already present them the
reference way -- a transparent web view whose HTML paints its own background
and draws its own close control -- and this package only asks the native SDK to
show a message and observes what happened. There is no Flutter widget that
renders message HTML.

The Dart public API is frozen by `docs/api-contract.md`. That file is
deliberately not linked and not shipped: it lives in Mithra's internal source
repository, so no URL for it resolves for readers outside the organisation. It
is the source of truth for the API shape; this README is the guide, and it
documents the same surface.

## Install

The package is not on pub.dev yet. Until the first release is published,
depend on the repository:

```yaml
dependencies:
  mithra_flutter_sdk:
    git:
      url: https://github.com/MithraAI/mithra-flutter-sdk.git
      ref: main
```

Once the first version is published, a hosted dependency replaces it -- use the
version pub.dev shows for the release you want:

```yaml
dependencies:
  mithra_flutter_sdk: ^<published version>
```

Then `flutter pub get`.

### Supported Flutter versions

```yaml
environment:
  sdk: ^3.11.0
  flutter: '>=3.41.0'
```

The plugin supports the **current Flutter stable release and the two stable
releases before it**. Today that means Flutter **3.47.x** (current, Dart
3.13.x), **3.44.x** (Dart 3.12.x) and **3.41.x** (Dart 3.11.x), which is where
the floor above comes from. The floor moves forward as new stables ship: when
Flutter 3.50 becomes stable, the supported window becomes 3.50 / 3.47 / 3.44
and the constraint is raised to `flutter: '>=3.44.0'` / `sdk: ^3.12.0` in a
minor release. Older Flutter versions are not tested and are not supported.

### iOS

Minimum deployment target is **iOS 15**, matching the native SDK. Set it in
`ios/Podfile`:

```ruby
platform :ios, '15.0'
```

#### CocoaPods -- the default, and there is nothing to configure

**You do not need to install or configure any native package manager.**
Everything arrives through pub. `flutter run` (and `flutter build ios`) runs
`pod install` for you, and the plugin's podspec `prepare_command` then
downloads `MithraAnalytics-1.4.0.zip` from `https://sdk.mithra.com/ios/`,
verifies it against the published `checksums-1.4.0.txt`, and unpacks the
XCFramework into `ios/Frameworks/`. So the whole iOS setup is:

```yaml
dependencies:
  mithra_flutter_sdk:
    git:
      url: https://github.com/MithraAI/mithra-flutter-sdk.git
      ref: main
```

(or the hosted dependency, once the package is published -- see
[Install](#install))

```bash
flutter pub get
flutter run
```

The only requirements are the iOS 15 deployment target above and network
access on the first install (the download is skipped on later installs when
the framework is already present).

#### Swift Package Manager -- opt-in

If your team has enabled [Flutter's Swift Package Manager
support](https://docs.flutter.dev/packages-and-plugins/swift-package-manager),
the plugin also ships an SwiftPM path and Flutter will use it instead of the
pod. `ios/mithra_flutter_sdk/Package.swift` resolves the hosted Swift package
[`MithraAI/mithra-ios-sdk`](https://github.com/MithraAI/mithra-ios-sdk)
`from: "1.4.0"`, product `MithraAnalytics`. Nothing to add on your side --
enabling SwiftPM in your Flutter tooling is the whole opt-in.

Both paths pin the **same native SDK version** (1.4.0), and the Swift sources
are shared: the podspec and the Swift package both compile
`ios/mithra_flutter_sdk/Sources/mithra_flutter_sdk/`.

### Android

`minSdk 21`, JDK 17. The plugin declares the Mithra Maven repository itself, so
no app-side repository configuration is required. It resolves
`com.mithra.sdk:android:1.4.2`.

`com.mithra.sdk:inapp-ui` is **not** a dependency: that artifact is the native
Compose inbox UI, and a Flutter app builds its inbox from Flutter widgets over
`Narya.inApp.inboxMessages`.

## Initialize

A Mithra Flutter client key is **cross-platform**: one key (`msdk_flutter_...`,
created for the `FLUTTER` SDK platform in the Mithra dashboard) works for both
your iOS and your Android build, so there is a single required `writeKey`.

```dart
import 'package:mithra_flutter_sdk/mithra_flutter_sdk.dart';

await Narya.initialize(
  const NaryaConfiguration(
    writeKey: '<MITHRA_FLUTTER_WRITE_KEY>',
    environment: NaryaEnvironment.production,
    inApp: NaryaInAppConfiguration(enabled: true),
  ),
);
```

Call it once, as early as possible. Any other API called before `initialize`
completes throws a `NaryaException` with code `not_initialized`. A repeated
call with an identical configuration is a no-op; with a different one it throws
`already_initialized`.

### Environments and write keys

`NaryaEnvironment.production` and `.staging` map to the Argonath SDK gateways
inside the native SDKs. Dart never hardcodes a gateway URL.

`writeKey` is required. Passing an empty key throws a `NaryaException` with
code `missing_write_key` -- identically on both platforms, since both native
sides receive the same key.

### Local-development override

To point a debug build at a gateway running on your machine, set
`dataPlaneUrl` -- it always wins over `environment`:

```dart
await Narya.initialize(
  NaryaConfiguration(
    writeKey: writeKey,
    dataPlaneUrl: 'http://10.0.2.2:8080', // Android emulator host loopback
    logLevel: NaryaLogLevel.debug,
  ),
);
```

## Identify and track

```dart
await Narya.identify(userId: 'user-123', traits: {'email': 'a@b.com'});
await Narya.track('button_clicked', properties: {'id': 'checkout'});
await Narya.group('acme-inc', traits: {'plan': 'enterprise'});
await Narya.alias('new-id', previousId: 'old-id');

await Narya.flush();
await Narya.reset(); // on sign-out

final String? anonymousId = await Narya.anonymousId;
final String? userId = await Narya.userId;
final Map<String, Object?>? traits = await Narya.traits;
```

Sessions are automatic by default. Drive them manually by setting
`NaryaSessionConfiguration(automaticSessionTracking: false)` and calling
`Narya.startSession()` / `Narya.endSession()`.

## Screen tracking

Install `NaryaRouteObserver` on your navigator:

```dart
MaterialApp(
  navigatorObservers: [NaryaRouteObserver()],
  // ...
);
```

or, with `go_router`, pass it in `observers:`. The default screen name is
`route.settings.name`, and unnamed routes are skipped; supply
`screenNameResolver` / `propertiesResolver` to change that.

Track a screen your navigator does not model as a route by hand:

```dart
await Narya.screen('Product Detail', properties: {'sku': 'ABC'});
```

> The native automatic screen-tracking options (iOS `trackApplicationScreens`,
> Android `trackActivities`) are deliberately forced **off** by the bridge. A
> Flutter app is a single `FlutterViewController` / `FlutterActivity`, so native
> auto-tracking would emit one meaningless screen event for the whole app -- and
> on iOS it also suppresses manual `screen()` calls.

## Push notifications

There are two ways to get a device token into the SDK. Pick **one per
platform**; never combine them.

| Platform | Option | Token source |
| -------- | ------ | ------------ |
| iOS | **A. Native APNs registration** (no Firebase) | `Narya.push.registerForRemoteNotifications()` -- the plugin does everything |
| iOS | **B. `firebase_messaging`** | `FirebaseMessaging.instance.getAPNSToken()` / `getToken()` -> `Narya.push.setToken` |
| Android | `firebase_messaging` (always) | FCM token -> `Narya.push.setToken` |

### iOS option A: native APNs registration (no Firebase)

Like Iterable's SDKs, the plugin can take the APNs device token natively, so an
iOS app that does not otherwise need Firebase adds **no** Firebase dependency:

```dart
Narya.push.onToken.listen((String token) {
  // Lowercase hex APNs token. Already registered with the SDK; log or mirror it.
});
Narya.push.onRegistrationError.listen((NaryaPushRegistrationError error) {
  debugPrint('APNs registration failed: $error');
});

final NaryaPushAuthorizationStatus status =
    await Narya.push.registerForRemoteNotifications(); // alert, badge, sound
switch (status) {
  case NaryaPushAuthorizationStatus.authorized:
  case NaryaPushAuthorizationStatus.provisional:
    break; // token arrives on onToken
  case NaryaPushAuthorizationStatus.denied:
    break; // offer a jump to the system Settings app
  case NaryaPushAuthorizationStatus.notDetermined:
  case NaryaPushAuthorizationStatus.unsupported:
    break; // unsupported == Android; see below
}
```

What happens natively:

1. `UNUserNotificationCenter` authorization is requested with the options you
   pass (all three default to `true`). Already-granted and provisional grants
   skip the prompt; a denial only reports `denied`.
2. When authorized, `UIApplication.registerForRemoteNotifications()` runs on
   the main thread. The resulting token is handed to the native SDK
   (`setPushToken(deviceToken:)`) **without any host code** and emitted on
   `onToken`. A token that arrives before `Narya.initialize` completes is
   queued and applied on initialization, so the call order does not matter.
   Token refreshes emit again.
3. The plugin becomes the `UNUserNotificationCenter` delegate and chains to
   whatever was installed before. It takes that role only once push is in use
   -- `registerForRemoteNotifications`, `setToken`, or an APNs device token
   arriving by any other route (host code in your app delegate, or
   `firebase_messaging`, which owns APNs registration on iOS), in this launch
   or an earlier one -- so an app that only sends analytics never becomes the
   notification center delegate. A *failed* APNs registration does not count.
   From the next launch on, the role
   is taken during plugin registration, early enough for a tap that
   cold-started the app. The delegate it replaces is: the default `FlutterAppDelegate`
   (which forwards the APNs `UIApplicationDelegate` callbacks to plugins but
   not `willPresent` / `didReceive(response:)`), a host object, or another
   notification plugin's delegate - including `firebase_messaging`, whose iOS
   plugin registers itself as the delegate even when you link it only for
   Android. As delegate it shows foreground pushes (banner, list, sound,
   badge), tracks Mithra pushes as delivered, and routes taps through the SDK
   so they arrive on `Narya.push.onPushOpened` (or `takeInitialPushPayload`
   for a cold start) with the tapped action. The previous delegate still
   receives every callback afterwards - `willPresent` options are merged into
   the plugin's, `didReceive` completion stays with it, `openSettingsFor` is
   simply forwarded - so notification code you keep in `AppDelegate` or in
   another plugin works unchanged. A debug line names the delegate class that
   was chained. Call `registerForRemoteNotifications` early (before or right
   after `Narya.initialize`): the delegate is installed synchronously, and a
   tap that cold-started the app is delivered to it and replayed after
   initialization.
4. Silent in-app-sync pushes delivered to the app delegate are forwarded to the
   SDK automatically; you do not need `handleBackgroundNotification` on this
   path.

Requirements: your `AppDelegate` must subclass `FlutterAppDelegate` (the
default Flutter template does), the Push Notifications capability must be on,
and for silent pushes the `remote-notification` background mode.

> **Call `registerForRemoteNotifications` only if you want the Narya SDK to
> own APNs registration on iOS.** It always takes the notification center
> delegate and forwards to whatever was installed before, `firebase_messaging`
> included - so it is safe in an app that links Firebase for Android - but if
> `firebase_messaging` should keep owning APNs on iOS, use option B instead.
> Never feed tokens through both paths: that would register twice and could
> double-count tracking.

### iOS option B / Android: `firebase_messaging`

The plugin does not depend on Firebase. Your app obtains the token with
`firebase_messaging` and hands it over:

```dart
await Narya.push.setToken(token);
await Narya.push.clearToken(); // on sign-out, if you stop targeting the device

await Narya.push.trackReceived(message.data);
```

> **Do not call `trackOpened` for a tap the SDK reported to you.** The bridge
> tracks `push_opened` itself, from the notification tap, and *then* hands you
> the payload - so `onPushOpened` and `takeInitialPushPayload` deliver taps
> that are already tracked. Handing one of those payloads back to `trackOpened`
> is recognised and ignored rather than counted twice, but do not write it:
> listen and route, nothing more (see "Routing is yours" below).
>
> `trackOpened` is for a tap the SDK never saw - a notification your own code
> posted and routed, from a raw `firebase_messaging` payload. Gate that call on
> `isNaryaPush`.

On Android, tracking alone is not enough: Mithra pushes are **data-only** FCM
messages, so nothing appears unless you call `handlePushMessage` (see
"Android: rendering the notification" below).

On Android `registerForRemoteNotifications()` returns
`NaryaPushAuthorizationStatus.unsupported` and `onToken` /
`onRegistrationError` never emit: Android tokens always come from FCM.

### Is this a Mithra push?

`firebase_messaging` delivers every push your app receives, not only Mithra's.
Gate on `isNaryaPush` before tracking, exactly as you would with the reference
SDK's `isIterablePush`:

```dart
FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
  if (!Narya.push.isNaryaPush(message.data)) return;
  await Narya.push.trackReceived(message.data);
});

@pragma('vm:entry-point')
Future<void> onBackgroundMessage(RemoteMessage message) async {
  // Background isolate: Narya is not initialised here, and that is fine.
  if (!Narya.push.isNaryaPush(message.data)) return;
  // ...
}
```

The check is pure Dart -- synchronous, no platform channel, no
`Narya.initialize` -- so it also works in the background isolate and in unit
tests. It applies the same rule the native SDKs use: the top-level keys, the
`CustomData` value and the `mithra` envelope value (each a map or a JSON string
decoding to an object) are inspected on their own, and the push is Mithra's
when any level has a non-empty `tracking`, a truthy `inapp_sync` (`true`, a
non-zero number, or `"true"` / `"1"` / `"yes"`, case-insensitive, not trimmed),
a non-empty `mithra_message_id`, or when the top-level `mithra` key holds an
object (`{}` counts; a bare string, number, list or malformed JSON does not). A
bare `message_id` / `gcm.message_id` is not enough, because Firebase stamps
`gcm.message_id` on every message. The cross-platform parity table is in
`docs/api-contract.md`. `trackReceived`, `trackOpened` and
`handleBackgroundNotification` do not filter on their own. Key names follow
gwaihir's `docs/push-payload-contract.md`.

Routing is yours. The SDK resolves the destination but never opens it:

```dart
Narya.push.onPushOpened.listen((event) {
  final Uri? link = event.deepLink;
  if (link != null) router.go(link.path);
});

// The Flutter engine attaches after a cold-start tap is processed natively,
// so read that one separately, once.
final payload = await Narya.push.takeInitialPushPayload();
if (payload != null) {
  final link = await Narya.push.deepLinkFrom(payload);
  if (link != null) router.go(link.path);
}
```

Attaching an `onPushOpened` listener tells the native handler that Dart owns
routing, so the native layer will not also open the URL.

> **Do not gate SDK-delivered events with `isNaryaPush`.** `onPushOpened`,
> `takeInitialPushPayload` and `Narya.inApp.onDeepLink` are produced by the
> native SDK only for notifications and messages it recognises, so they are
> already Mithra-originated. `isNaryaPush` is for the *raw* payloads
> `firebase_messaging` hands you; running it on `event.payload` can drop valid
> events (an in-app link, for instance, carries no push payload at all).

### iOS: the Notification Service Extension

Rich media (images) in push requires a **native** Notification Service
Extension target. It is not bridged, and it cannot be, because the extension is
a separate process that Flutter never runs in.

1. In Xcode, **File > New > Target > Notification Service Extension**, name it
   e.g. `NaryaNotificationService`. Set its deployment target to iOS 15.
2. Link `MithraAnalyticsNotificationService` to that target:
   - **SwiftPM**: add the `mithra-ios-sdk` package to the extension target and
     select the `MithraAnalyticsNotificationService` product.
   - **CocoaPods**: the plugin's podspec does not vendor the extension
     framework. Download `MithraAnalyticsNotificationService-1.4.0.zip` from
     `https://sdk.mithra.com/ios/` (verify it against
     `checksums-1.4.0.txt`) and embed the XCFramework in the extension target.
3. Make the extension's principal class subclass the SDK's service class, per
   [`narya-ios`](https://github.com/MithraAI/narya-ios)'s README.

Silent, in-app-sync pushes reach the SDK from your app delegate or background
handler:

```dart
final handled = await Narya.push.handleBackgroundNotification(message.data);
```

This returns `false` on Android, where a silent push reaches your
`FirebaseMessagingService` directly instead.

### Android: rendering the notification

Mithra sends **data-only** FCM messages on Android. Firebase never posts a
notification for those by itself, so **you MUST call
`Narya.push.handlePushMessage` from both `FirebaseMessaging.onMessage` and your
`FirebaseMessaging.onBackgroundMessage` handler**. Without it a Flutter Android
app shows nothing for a Mithra push. The call hands the payload to the native
Narya SDK, which does exactly what the native Android demo's
`FirebaseMessagingService` does: tracks `push_delivered`, creates the
notification channel, posts the notification with title, body, image and
action buttons, and wires the tap so it arrives on `onPushOpened` /
`takeInitialPushPayload`. Buttons and images are rendered by the native SDK;
there is nothing to draw in Dart.

```dart
const NaryaPushDisplayOptions pushOptions = NaryaPushDisplayOptions(
  smallIcon: 'ic_notification', // res/drawable*/ic_notification.xml, monochrome
  // tapActivity, channelId and channelName are optional; see the API docs.
);

// Foreground.
FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
  if (!Narya.push.isNaryaPush(message.data)) return;
  final bool posted = await Narya.push.handlePushMessage(
    message.data,
    options: pushOptions,
  );
  // posted == false for a silent payload, e.g. the in-app wake push, which
  // the SDK has already turned into an in-app sync.
});

// Background and terminated. Must be a top-level function annotated with
// @pragma('vm:entry-point'): Firebase runs it in a separate isolate.
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(RemoteMessage message) async {
  if (!Narya.push.isNaryaPush(message.data)) return;
  await Narya.push.handlePushMessage(message.data, options: pushOptions);
}

FirebaseMessaging.onBackgroundMessage(onBackgroundMessage);
```

`Narya.initialize` never runs in the background isolate, and after FCM
cold-starts the process no Dart code has initialized anything. That is fine:
the Android bridge keeps the native SDK instance process-wide, shared by every
Flutter engine, and persists the configuration of the last successful
`Narya.initialize`, from which it rebuilds the SDK when `handlePushMessage`
(or `trackReceived` / `trackOpened`) is called first. Only an app that has
never completed `Narya.initialize` on the device gets a `NaryaException` with
code `not_initialized` here. On iOS `handlePushMessage` is a no-op returning
`false`: the system, or your Notification Service Extension, renders the push.

`smallIcon` is the **name** of a drawable or mipmap resource; when omitted the
application icon is used, which renders as a silhouette but always works.
`tapActivity` defaults to your launcher activity (the `FlutterActivity`).
Unknown names throw `NaryaException` with code `invalid_argument`. The channel
defaults to `narya_default` / "Notifications".

Taps are handled by the plugin: it reads the SDK's tap-intent extras from the
launch intent and from `onNewIntent`, and emits them on
`Narya.push.onPushOpened`. On Android 13+ remember to request
`POST_NOTIFICATIONS` at runtime. You do **not** need your own
`FirebaseMessagingService`: `firebase_messaging` registers one. The native
`setNotificationCustomizer` hook is not bridged; if you need it, keep a native
service instead.

### App icon badge

gwaihir stamps `badge = 1` on **every** alert push it sends, and no payload
ever sets the badge back to zero. On iOS that means the app icon badge lights
up on the first notification and then **stays lit forever** - APNs only changes
the badge when a payload sets it, so nothing clears it on its own. Clearing it
is the host app's job:

```dart
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Narya.push.clearBadge();
  }
}
```

`Narya.push.setBadgeCount(int count)` sets an explicit number and
`clearBadge()` is exactly `setBadgeCount(0)`. A negative count is clamped to
zero. Neither call needs `Narya.initialize`: the badge is platform state, not
SDK state, so a badge left over from a previous launch can be cleared before
the SDK is configured. A system failure surfaces as a `NaryaException` with
code `badge_failed`.

**Android does nothing** and returns normally. Android has no platform
app-icon badge API: launchers derive the dot or the count from the
notifications your app currently has posted, so a badge goes away when those
notifications are dismissed or cancelled, not through an SDK call. The method
exists on both platforms only so your code needs no `Platform.isIOS` branch.

The SDK **never** touches the badge by itself - not when it renders a push, not
at start-up, and not when the mobile inbox unread count changes. If your app
wants the badge to follow the inbox instead of being cleared on resume, wire
that yourself:

```dart
Narya.inApp.onUnreadInboxMessageCountChanged.listen(Narya.push.setBadgeCount);
// and once at start-up, since the stream only emits on change:
Narya.push.setBadgeCount(await Narya.inApp.unreadInboxMessageCount);
```

Pick one of the two behaviours: a resume-clear and a badge that follows the
unread count will otherwise fight each other.

## In-app messages and the mobile inbox

Automatic display needs no code beyond `initialize`. Pause it around flows that
must not be interrupted:

```dart
await Narya.inApp.setAutoDisplayPaused(true);
// ... checkout ...
await Narya.inApp.setAutoDisplayPaused(false);
```

Build the inbox from Flutter widgets and let the native SDK render the message:

```dart
final messages = await Narya.inApp.inboxMessages;
final unread = await Narya.inApp.unreadInboxMessageCount;

Narya.inApp.onInboxMessagesChanged.listen((messages) => setState(...));
Narya.inApp.onUnreadInboxMessageCountChanged.listen((count) => setState(...));

await Narya.inApp.setRead(id, read: true);
await Narya.inApp.removeMessage(id, source: NaryaInAppDeleteSource.inboxSwipe);
await Narya.inApp.showMessage(id, location: NaryaInAppLocation.inbox);
```

Report inbox visibility so engagement metrics are attributed correctly:

```dart
await Narya.inApp.startInboxSession();
await Narya.inApp.startInboxImpression(id);
await Narya.inApp.endInboxImpression(id);
await Narya.inApp.endInboxSession();
```

Decide per message whether it should be shown:

```dart
Narya.inApp.setOnNewMessage((message) {
  if (message.priorityLevel > 500) return NaryaInAppShowResponse.skip;
  return NaryaInAppShowResponse.show;
});

Narya.inApp.setCustomActionHandler((name, message) => handleAction(name));
```

### Links inside a message

When the user taps an ordinary link (anything that is not `narya://` or
`action://`) in a message, the native SDK resolves it, closes the message and
hands the destination to you. **The SDK never opens the URL** -- routing is
yours, exactly as for a push deep link:

```dart
Narya.inApp.onDeepLink.listen((NaryaInAppDeepLinkEvent event) {
  // event.url is the resolved destination, event.messageId the message.
  router.go(event.url.path);
});
```

The stream is a broadcast stream, so several screens may listen. Its events are
already Mithra-originated; do not run `Narya.push.isNaryaPush` on them. Without
a listener the link is simply dropped (the Android SDK logs "no deep link
handler registered"), so attach one early in your app.

> **How the handler is answered.** The native delegate is synchronous and runs
> on the platform's main thread, so the bridge cannot block on a
> platform-channel reply without deadlocking. Instead it uses the SDK's own
> `defer` semantics: the first time a message is offered, the bridge asks Dart
> and defers the message, which leaves it queued; when Dart answers, the
> decision is cached and the display queue is pumped again. Nothing is lost, but
> a decision costs one extra display pass.

### json-only messages

A json-only message never renders; it carries a payload for your app to act on.
Return `true` to tell the SDK it was handled:

```dart
Narya.inApp.setOnJsonOnlyMessage((payload, message) {
  applyPromo(payload);
  return true;
});
```

Payloads delivered before your handler was registered are not lost -- the native
SDK buffers them:

```dart
for (final message in await Narya.inApp.unhandledJsonOnlyMessages) {
  if (handle(message.customPayload)) {
    await Narya.inApp.markJsonOnlyMessageHandled(message.messageId);
  }
}
```

## Local development against the native SDKs

While the bridge and a native SDK change together, build against local
checkouts.

**Android** -- the plugin resolves the published artifact by default. To
substitute a local `narya-android`, set the flag (the same property name
`narya-demo-android` uses, so one machine-wide override serves both) in your
app's `android/gradle.properties` or `~/.gradle/gradle.properties`:

```properties
naryaUseLocalSdk=true
naryaSdkPath=../../narya-android
```

and add the composite build to your app's `android/settings.gradle`. The exact
snippet is documented in [`android/build.gradle`](./android/build.gradle).

**iOS** -- drop a prebuilt `MithraAnalytics.xcframework` into `ios/Frameworks/`
inside the plugin before `pod install`; the podspec's `prepare_command` skips
the download when the framework is already there. With SwiftPM, add a local
package override pointing at your `narya-ios` checkout.

## Errors

Every `PlatformException` from a channel is translated into `NaryaException`:

```dart
try {
  await Narya.initialize(configuration);
} on NaryaException catch (error) {
  debugPrint('${error.code}: ${error.message}');
}
```

Codes you can branch on: `not_initialized`, `missing_write_key`,
`already_initialized`, `invalid_argument`, `unsupported_platform`,
`native_error`.

## Example

[`example/`](./example) is a deliberately minimal host that calls
`initialize` / `track` / `screen`. The full-featured demo -- push, in-app
messages, the inbox and json-only handling -- lives in the separate
`narya-demo-flutter` repository.

## Contributing

Development happens in the internal source repository
[**MithraAI/narya-flutter**](https://github.com/MithraAI/narya-flutter): all
code, CI, git hooks, release-please configuration and `docs/api-contract.md`
live there, and every pull request targets it. The public repository
[**MithraAI/mithra-flutter-sdk**](https://github.com/MithraAI/mithra-flutter-sdk)
is generated - it receives one commit and one `v<version>` tag per release and
must never be edited by hand. It is a content-only mirror: the repo customers
see linked from the pub.dev page and where they file issues, but nothing runs
there. See [Releasing](#releasing) for the mechanics.

Install the local git hooks once after cloning:

```bash
sh scripts/setup-hooks.sh
```

That points this repo's `core.hooksPath` at `scripts/git-hooks/` (chaining any
global hooks, so Gitleaks keeps running) and activates:

| Hook         | What it enforces                                                         |
|--------------|--------------------------------------------------------------------------|
| `commit-msg` | Conventional Commits subject line -- the same rule CI applies to PR titles |
| `pre-commit` | `dart format` on staged Dart files, then `flutter analyze --fatal-infos`  |
| `pre-push`   | Branch name, then `flutter analyze --fatal-infos`                         |

The script is idempotent -- re-run it whenever a hook is added or changed.

### Tests

```bash
flutter test                    # the Dart side: lib/ and the method-channel wire format
swift test --package-path ios   # the iOS bridge's pure-Swift logic
```

`ios/Package.swift` is a **host test harness, not the plugin package** -- the
plugin's own package is `ios/mithra_flutter_sdk/Package.swift` and is the only
one Flutter or a consumer ever resolves. The plugin target cannot host
command-line tests: it imports Flutter, which is not a Swift package
dependency but a framework the iOS build supplies through its search paths, so
the module does not exist on a host toolchain (UIKit and `MithraAnalytics` do
not build for macOS either), and `swift test` builds every target in a package
rather than only the test target's dependencies. The harness therefore
compiles the Flutter-free files under
`ios/mithra_flutter_sdk/Sources/mithra_flutter_sdk/Core/` -- the same files
both the Swift Package Manager and the CocoaPods path compile into the plugin,
so there is no copy to drift -- as a plain Swift module and tests those.
Anything added to `Core/` must stay pure Foundation. The rest of the iOS
bridge is covered by the Dart tests, by `pod lib lint` and by the example app
builds in CI.

The hooks deliberately stop at the analyzer. Running the test suite on every
push duplicates what CI already does on the pull request, on both supported
Flutter versions, and it is the slowest possible place to find out -- so
`flutter test` is CI's job. Use `git push --no-verify` if a hook is in the way
of a work-in-progress branch.

Commit messages and PR titles must follow Conventional Commits
(`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`,
`chore`, `revert`), because release-please derives the next version and the
changelog from them: `feat` bumps the minor, `fix` the patch, and `!` or a
`BREAKING CHANGE:` footer bumps the major -- except that while the package is
pre-1.0 (`bump-minor-pre-major`), a breaking change bumps the minor instead.

## Releasing

### The two repositories

| Repository | Visibility | Role |
|------------|------------|------|
| [`MithraAI/narya-flutter`](https://github.com/MithraAI/narya-flutter) | internal, issues off | **Source.** All code, CI, hooks, `docs/`, release-please. Every PR lands here. |
| [`MithraAI/mithra-flutter-sdk`](https://github.com/MithraAI/mithra-flutter-sdk) | public, issues on | **Distribution.** Generated content-only mirror: one commit + one `v<version>` tag per release. No workflows, no publishing. |

This is the same split narya-ios uses (internal `narya-ios` generating the
public `mithra-ios-sdk`), and it is why the pub.dev package name is
`mithra_flutter_sdk` -- customer-facing Mithra branding, with the platform in
the middle so it reads the same way as `mithra-ios-sdk` -- while the source
repo carries the Narya product name.

The distribution repo holds **exactly** what a consumer needs and nothing
else: the file set `dart pub publish` would ship (so, whatever `.pubignore`
does not exclude). None of this repo's CI, git hooks, release-please
configuration or `docs/` is copied there, and no workflow file is written into
it either - the pub.dev publish runs here, in `narya-flutter`.

### The release chain

Releases are automated end to end. A maintainer never edits `version` in
`pubspec.yaml` or `CHANGELOG.md` by hand.

1. **Merge to `main`.** `release-please.yml` runs and maintains a rolling
   release PR titled `chore(main): release <version>`.
2. **Merge the release PR.** release-please (release type `dart`) bumps
   `version` in `pubspec.yaml`, prepends the new section to `CHANGELOG.md`,
   updates `.release-please-manifest.json`, pushes the `v<version>` tag and
   creates the GitHub Release. The hand-written changelog history is
   preserved -- release-please only prepends. It uses the Mithra bot App token
   precisely so that this tag push can trigger the next step.
3. **`release.yml` fires on the `v<version>` tag** (in this repo) and does the
   rest in two ordered jobs.

   The `release` job builds the snapshot with
   `scripts/build-dist-snapshot.sh` (in the source repository; `scripts/` is
   not part of the published package, so this is a reference, not a link),
   validates it with `dart pub publish --dry-run`, then force-replaces the
   content of `MithraAI/mithra-flutter-sdk` with it, commits
   `chore: release <version>` on `main` and pushes the tag `v<version>`.
   Cross-repo write access comes from a short-lived
   `actions/create-github-app-token` installation token for the Mithra bot App
   -- the identical mechanism `narya-ios`' `release.yml` uses to push its
   generated `Package.swift` to `mithra-ios-sdk`.

   The `publish` job (`needs: release`) then publishes to
   [pub.dev](https://pub.dev/packages/mithra_flutter_sdk): it re-checks that
   `pubspec.yaml` matches the version this run released, runs
   `dart pub publish --dry-run`, then `dart pub publish --force`, and
   authenticates with a GitHub Actions OIDC token (`id-token: write`) rather
   than any stored credential.

### Why the pub.dev publish runs in this repo

pub.dev's automated publishing binds a package to exactly one `<org>/<repo>`
plus a tag pattern, and requires the publishing workflow to live in the
repository where the tag is pushed -- it verifies the OIDC token of that
workflow run. It does **not** require that repository to be public, and it
does **not** require it to match `pubspec.yaml`'s `repository` field (see
[Automated publishing](https://dart.dev/tools/pub/automated-publishing)).

release-please already pushes the `v<version>` tag here, so pub.dev is
configured against `MithraAI/narya-flutter`. That keeps the whole release in
one workflow and removes two things from the distribution repo: a publish
workflow and an OIDC trust relationship. The mirror is left as pure content.

**The publishing repo and the linked repository differ on purpose.**
`pubspec.yaml`'s `repository` / `issue_tracker` still point at
`MithraAI/mithra-flutter-sdk`, because `narya-flutter` is internal and a
package page linking a repository nobody outside the org can open is useless.
pub.dev allows this split, so the public mirror exists solely to make that
link resolve (and to give customers a place to file issues), while the archive
is published from the source repo.

### Why the publish is a job, not its own workflow

A separate `publish.yml` triggered by the same `v*.*.*` tag would start
concurrently with `release.yml`, so the pub.dev publish could win the race
against the mirror push -- publishing a version whose public repository link
points at a mirror that does not have it yet, or, if the mirror push then
failed, never will. Making it a job with `needs: release` fixes the order:
**mirror first, publish second.** A failed mirror push skips the publish
entirely, so there is never a published version without a matching public
mirror; the reverse failure (mirror pushed, publish failed) is the recoverable
one -- re-dispatch `release.yml`.

The snapshot's `README.md` is prefixed with a generated notice, in the same
spirit as the `GENERATED FILE - DO NOT EDIT BY HAND` header `narya-ios` stamps
on the `Package.swift` it publishes to `mithra-ios-sdk`.

The supported Flutter range is a release decision, not a build detail: see
[Supported Flutter versions](#supported-flutter-versions). Raising the floor is
a minor release, and CI proves the floor still works by running the analyzer
and the tests on both the floor and current stable.

### One-time pub.dev setup (manual, required)

Publishing uses **pub.dev automated publishing over GitHub Actions OIDC**, so
no pub.dev credential is stored anywhere -- `release.yml`'s `publish` job
requests a short-lived OIDC token (`id-token: write`) that pub.dev verifies.
That trust has to be established once, by hand, and it cannot be done from
code:

1. The **first publish must be manual.** pub.dev can only configure automated
   publishing for a package that already exists, so the very first version has
   to go up from a maintainer's machine once.

   The version itself is still produced by the pipeline, not chosen by hand:
   `.release-please-manifest.json` starts at `0.0.0` (a baseline, never
   published), so the first release PR resolves to `0.1.0` from the `feat`
   commits and tags it. Merge that PR, then check out its tag and publish that
   exact tree -- do not hand-edit `version` in `pubspec.yaml`:

   ```bash
   git fetch --tags
   git checkout <the tag that release PR created>
   dart pub publish
   ```

   `release.yml` still runs on that tag and mirrors the snapshot to
   `mithra-flutter-sdk`; only its `publish` job is redundant this one time, and
   it fails harmlessly because the version already exists on pub.dev.

2. Then, on pub.dev: open the package, go to the **Admin** tab, and under
   **Automated publishing** enable *Publishing from GitHub Actions* with

   | Field        | Value                     |
   |--------------|---------------------------|
   | Repository   | `MithraAI/narya-flutter`  |
   | Tag pattern  | `v{{version}}`            |

   This is **this** repository -- the one whose `release.yml` runs the publish
   and pushes the tag -- *not* the `mithra-flutter-sdk` repository that
   `pubspec.yaml` links to. pub.dev does not require the two to match, and it
   does not require the publishing repository to be public. The tag pattern
   matches release-please's version tag verbatim
   (`include-component-in-tag: false` -> `v1.2.3`).

   Optionally also tick *Require GitHub Actions environment* and enter
   `release`; the `publish` job runs in that environment, so pub.dev will then
   reject an OIDC token from any run that does not.

3. Ask an org admin to **install the Mithra bot GitHub App on
   `MithraAI/mithra-flutter-sdk`** with *Contents: Read and write*. Without it,
   `release.yml` cannot push the snapshot to the public mirror -- and because
   the publish job depends on that step, nothing is published either.

4. Create the **`release` GitHub environment** in `narya-flutter` (and add any
   required reviewers). Only `release.yml`'s `publish` job runs in it, so its
   protection rules gate the pub.dev publish -- the one irreversible step, and
   the only job whose environment pub.dev's OIDC check can see. The mirror push
   is intentionally not gated: gating both made one release need two approvals,
   the second of them after the mirror was already pushed and tagged.

Until steps 2 and 3 are done, a release fails: `release.yml` cannot push to
the distribution repo, or the publish job fails with an authorization error
even though everything else is green.

### CI

| Workflow                   | Trigger                        | What it does                                                                    |
|----------------------------|--------------------------------|---------------------------------------------------------------------------------|
| `ci.yml`                   | PRs (same base branches as the title check) and pushes to `main` | `dart format` (current stable), `flutter analyze --fatal-infos` and `flutter test` on the floor and current stable; `dart pub publish --dry-run`; the distribution snapshot built and validated the way `release.yml` builds it; `swift test` over the bridge core; `pod lib lint` on the podspec; example builds for Android (debug APK) and iOS (unsigned simulator), each on the floor and current stable |
| `pr-title-validation.yml`  | PR opened/reopened/edited      | Conventional Commits check on the PR title                                       |
| `codeql.yml`               | PRs, pushes to `main`, weekly  | CodeQL for `actions`, `java-kotlin` and `swift` (CodeQL has no Dart extractor)   |
| `release-please.yml`       | pushes to `main`               | maintains the release PR, tags, GitHub Release                                   |
| `release.yml`              | `v*.*.*` tag                   | job `release`: builds and validates the distribution snapshot, then pushes it plus the `v<version>` tag to `MithraAI/mithra-flutter-sdk`; job `publish` (`needs: release`): `dart pub publish` to pub.dev over OIDC |

`codeql.yml` is pinned to `workflow_dispatch` because `narya-flutter` is an
internal repository without GitHub Code Security enabled, so scheduled and
pull-request runs could not upload their results -- the same reason
`narya-ios` and `narya-android` pin theirs.

The CocoaPods and Swift Package Manager paths are covered by different jobs on
purpose. The example app resolves the plugin through SwiftPM, so `build-ios`
never touches `ios/mithra_flutter_sdk.podspec` -- and CocoaPods is what a
consumer gets by default. `pod lib lint` closes that gap: it builds the
plugin's Swift sources against the CocoaPods `Flutter` pod and, because
CocoaPods runs `prepare_command` for local (`:path`) pods as well, it exercises
the pinned XCFramework download and its checksum verification.

All release automation lives here; the distribution repo runs no workflows at
all. See [Why the pub.dev publish runs in this
repo](#why-the-pubdev-publish-runs-in-this-repo).

`dart pub publish --dry-run` exits non-zero on **warnings** as well as errors,
so package-layout warnings break CI. `.pubignore` keeps the published archive
to the package itself (~637 KB, dominated by `assets/narya.jpg` and the
example app's launcher icons); because `.pubignore` fully replaces
`.gitignore` for publishing, its first block intentionally repeats the
`.gitignore` build exclusions.

### Secrets

| Secret                          | Used by                              | Why                                                                                        |
|---------------------------------|--------------------------------------|--------------------------------------------------------------------------------------------|
| `MITHRA_BOT_APP_ID`             | `release-please.yml`, `release.yml`  | GitHub App token, so the release tag can trigger `release.yml`, and so `release.yml` can write to `MithraAI/mithra-flutter-sdk` |
| `MITHRA_BOT_PRIVATE_KEY`        | `release-please.yml`, `release.yml`  | same                                                                                       |
| `MITHRA_BOT_INSTALLATION_ID`    | not referenced                       | exists at org level; `actions/create-github-app-token` derives the installation from `owner`/`repositories`, so neither workflow passes it -- matching `narya-ios` |

**Nothing has to be added.** All three are **organization-level** secrets,
already shared with `narya-ios` and already visible to this repository, so no
repository secrets are needed. Publishing to pub.dev needs no secret at all:
the `publish` job authenticates with a short-lived GitHub Actions OIDC token.

## License

MIT. See [`LICENSE`](./LICENSE), which retains the upstream attribution carried
by the native SDKs. The filename is the one pub.dev's package validator looks
for, so there is a single license file rather than a copy under a second name.
