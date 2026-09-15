import Combine
import Flutter
import Foundation
import MithraAnalytics
import UIKit
import UserNotifications

/// The iOS half of the `mithra_flutter_sdk` bridge.
///
/// The class is deliberately thin: it decodes the argument map, calls exactly
/// one Narya SDK API, and encodes the reply. All behaviour - batching, storage,
/// the in-app display queue and every pixel of in-app rendering - lives in the
/// native SDK.
///
/// The plugin is also a `FlutterApplicationLifeCycleDelegate`, so it receives
/// the APNs callbacks (`didRegisterForRemoteNotificationsWithDeviceToken`,
/// `didFailToRegisterForRemoteNotificationsWithError`,
/// `didReceiveRemoteNotification:fetchCompletionHandler:`) a `FlutterAppDelegate`
/// forwards to its plugins. That is what lets an iOS host obtain a push token
/// without `firebase_messaging`, exactly as the native `narya-ios` demo does.
///
/// `FlutterAppDelegate` does **not** forward the `UNUserNotificationCenterDelegate`
/// callbacks (`willPresent`, `didReceive(response:)`) to plugins when it is the
/// notification center delegate, and a third-party delegate such as
/// `FLTFirebaseMessagingPlugin` never does, so the plugin takes that role over
/// and forwards every callback to the delegate it replaced (delegate chaining).
/// It does so only once push is in use - when the host registers for push, when
/// it hands a token over, when an APNs token arrives by any other route, and
/// from `application(_:didFinishLaunchingWithOptions:)` on every later launch,
/// all of which run early enough for a cold-start tap - so an analytics-only
/// app never becomes the notification center delegate. See
/// `markPushInUseAndInstallNotificationCenterDelegate` for the full list of
/// entry points, and `installNotificationCenterDelegateIfPushInUse`.
///
/// The application-delegate and launch callbacks are explicitly `@objc`: Swift
/// stopped inferring `@objc` for members of `NSObject` subclasses, and
/// `FlutterPluginAppLifeCycleDelegate` dispatches through `respondsToSelector`,
/// so without the attribute none of them would ever be called.
public class MithraFlutterSdkPlugin: NSObject, FlutterPlugin {

    private enum Channel {
        static let methods = "com.mithra.flutter.sdk/methods"
        static let events = "com.mithra.flutter.sdk/events"
        static let callbacks = "com.mithra.flutter.sdk/callbacks"
    }

    private enum EventType {
        static let pushOpened = "push_opened"
        static let pushToken = "push_token"
        static let pushRegistrationError = "push_registration_error"
        static let inboxMessagesChanged = "inbox_messages_changed"
        static let unreadCountChanged = "unread_count_changed"
        static let inAppDeepLink = "inapp_deep_link"
    }

    private enum CallbackMethod {
        static let onNewMessage = "onNewMessage"
        static let onJsonOnlyMessage = "onJsonOnlyMessage"
        static let onCustomAction = "onCustomAction"
    }

    private let callbackChannel: FlutterMethodChannel
    private let eventSink = NaryaEventSink()

    private var analytics: Analytics?
    private var configurationIdentity: String?

    /// Whether this app uses push, and so whether the plugin should own
    /// `UNUserNotificationCenter.delegate`. See `NaryaPushOwnership`.
    private let pushOwnership = NaryaPushOwnership()

    /// Decisions Dart has answered but the display pump has not consumed yet.
    private var pendingShowDecisions: [String: InAppShowResponse] = [:]
    /// Messages already sent to Dart and still awaiting an answer.
    private var askedShowDecisions: Set<String> = []
    /// Whether Dart has an `onNewMessage` handler attached.
    private var hasDartNewMessageHandler = false

    /// The payload of the notification that cold-started the app, consumed once.
    private var initialPushPayload: [String: Any]?

    /// The taps this plugin has already tracked `push_opened` for, so the host
    /// echoing one back through `push.trackOpened` does not report it twice.
    /// See `NaryaPushOpenLedger`.
    private let pushOpenLedger = NaryaPushOpenLedger()

    /// An APNs token that arrived before `initialize` completed; applied to the
    /// SDK as soon as it exists.
    private var pendingDeviceToken: Data?
    /// A notification tap delivered (via the notification center delegate)
    /// before `initialize` completed - a cold start; replayed on initialize so
    /// it is tracked and reaches `takeInitialPushPayload`.
    private var pendingNotificationResponse: UNNotificationResponse?

    /// The `UNUserNotificationCenter` delegate that was installed when the
    /// plugin took the role over (the host's `FlutterAppDelegate`, in practice).
    /// Every delegate callback is forwarded to it after the plugin's own work.
    /// Weak: the app delegate is owned by `UIApplication`.
    private weak var previousNotificationCenterDelegate: UNUserNotificationCenterDelegate?
    /// Set while a callback is being forwarded to the previous delegate. A
    /// `FlutterAppDelegate` fans notification center callbacks out to every
    /// plugin that implements them - this plugin included - so the flag lets
    /// the echoed call be recognised and answered without handling it twice.
    private var isForwardingToPreviousDelegate = false

    /// Whether this plugin - rather than host code - installed the process-wide
    /// `Analytics.setPushOpenHandler` slot, so `shutdown` only clears a handler
    /// it owns.
    private var installedPushOpenHandler = false

    /// When each `mithra_message_id` was last tracked as `push_delivered`.
    /// A push carrying both an `alert` and `content-available: 1` reaches the
    /// background and the foreground callback, so delivery is deduplicated.
    private var deliveryTrackedAt: [String: Date] = [:]

    private var inboxObservers: [AnyCancellable] = []
    private var messagesObserver: NSObjectProtocol?

    private init(messenger: FlutterBinaryMessenger) {
        callbackChannel = FlutterMethodChannel(
            name: Channel.callbacks,
            binaryMessenger: messenger
        )
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        let instance = MithraFlutterSdkPlugin(messenger: messenger)
        let methodChannel = FlutterMethodChannel(
            name: Channel.methods,
            binaryMessenger: messenger
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        FlutterEventChannel(name: Channel.events, binaryMessenger: messenger)
            .setStreamHandler(instance.eventSink)
        // Receive the APNs application-delegate and launch callbacks the host's
        // FlutterAppDelegate forwards to plugins.
        registrar.addApplicationDelegate(instance)
        // Own the notification center delegate from the earliest possible
        // moment - but only for an app that uses push: iOS delivers a tap that
        // cold-started the app right after `didFinishLaunchingWithOptions`, and
        // a callback with no delegate installed is dropped and never
        // redelivered. A host whose app delegate does not forward
        // `didFinishLaunchingWithOptions` is covered by this call alone. An
        // analytics-only app never registers for push, so the role is left
        // alone there. See `installNotificationCenterDelegateIfPushInUse`.
        instance.installNotificationCenterDelegateIfPushInUse()
    }

    // MARK: - Method dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initialize":
            initialize(arguments: arguments, result: result)

        // A traits-only identify must leave the identity alone, which is what
        // the Dart API promises; `NaryaIdentity.resolveUserId` is where that
        // rule lives, and where it is tested.
        case "identify":
            withAnalytics(result) { instance in
                instance.identify(
                    userId: NaryaIdentity.resolveUserId(
                        requested: arguments["userId"] as? String,
                        current: instance.userId
                    ),
                    traits: NaryaCodec.properties(from: arguments["traits"])
                )
                result(nil)
            }

        case "track":
            withAnalytics(result) { instance in
                guard let name = arguments["name"] as? String else {
                    return self.missingArgument("name", call: call, result: result)
                }
                instance.track(
                    name: name,
                    properties: NaryaCodec.properties(from: arguments["properties"])
                )
                result(nil)
            }

        case "screen":
            withAnalytics(result) { instance in
                guard let name = arguments["name"] as? String else {
                    return self.missingArgument("name", call: call, result: result)
                }
                instance.screen(
                    screenName: name,
                    category: arguments["category"] as? String,
                    properties: NaryaCodec.properties(from: arguments["properties"])
                )
                result(nil)
            }

        case "group":
            withAnalytics(result) { instance in
                guard let groupId = arguments["groupId"] as? String else {
                    return self.missingArgument("groupId", call: call, result: result)
                }
                instance.group(
                    groupId: groupId,
                    traits: NaryaCodec.properties(from: arguments["traits"])
                )
                result(nil)
            }

        case "alias":
            withAnalytics(result) { instance in
                guard let newId = arguments["newId"] as? String else {
                    return self.missingArgument("newId", call: call, result: result)
                }
                instance.alias(
                    newId: newId,
                    previousId: arguments["previousId"] as? String
                )
                result(nil)
            }

        case "flush":
            withAnalytics(result) {
                $0.flush()
                result(nil)
            }

        case "reset":
            withAnalytics(result) {
                $0.reset()
                result(nil)
            }

        case "startSession":
            withAnalytics(result) {
                $0.startSession(
                    sessionId: (arguments["sessionId"] as? NSNumber)?.uint64Value
                )
                result(nil)
            }

        case "endSession":
            withAnalytics(result) {
                $0.endSession()
                result(nil)
            }

        case "anonymousId":
            withAnalytics(result) { result($0.anonymousId) }

        case "userId":
            withAnalytics(result) { result($0.userId) }

        case "traits":
            withAnalytics(result) { result($0.traits) }

        case "sessionId":
            withAnalytics(result) {
                result($0.sessionId.map { Int(bitPattern: UInt(truncatingIfNeeded: $0)) })
            }

        case "openUrl":
            withAnalytics(result) { instance in
                guard
                    let raw = arguments["url"] as? String,
                    let url = URL(string: raw)
                else {
                    return self.missingArgument("url", call: call, result: result)
                }
                instance.open(url: url, options: arguments["options"] as? [String: Any])
                result(nil)
            }

        case "shutdown":
            withAnalytics(result) {
                $0.shutdown()
                self.teardownObservers()
                self.analytics = nil
                self.configurationIdentity = nil
                result(nil)
            }

        default:
            handlePushOrInApp(call, arguments: arguments, result: result)
        }
    }

    private func handlePushOrInApp(
        _ call: FlutterMethodCall,
        arguments: [String: Any],
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "push.registerForRemoteNotifications":
            // Deliberately not gated on `withAnalytics`: registration may run
            // before `initialize`, and the token is queued until then.
            registerForRemoteNotifications(arguments: arguments, result: result)

        // The other explicit push-registration entry point: a host that gets
        // its token elsewhere (`firebase_messaging`, say) hands it over here
        // instead of calling `push.registerForRemoteNotifications`, and needs
        // the notification center delegate just as much.
        case "push.setToken":
            withAnalytics(result) { instance in
                guard let token = arguments["token"] as? String else {
                    return self.missingArgument("token", call: call, result: result)
                }
                instance.setPushToken(token)
                self.markPushInUseAndInstallNotificationCenterDelegate(from: .dartSetToken)
                result(nil)
            }

        case "push.clearToken":
            withAnalytics(result) {
                $0.clearPushToken()
                result(nil)
            }

        // Not gated on `withAnalytics`: setting the badge is a UIKit /
        // UNUserNotificationCenter operation that needs no SDK instance, and a
        // host may want to clear a stale badge before `initialize` runs.
        case "push.setBadgeCount":
            guard let count = arguments["count"] as? Int else {
                return missingArgument("count", call: call, result: result)
            }
            NaryaBadge.setCount(count) { error in
                // FlutterResult must be invoked on the platform thread; the
                // iOS 16+ completion handler arrives on an arbitrary queue.
                DispatchQueue.main.async {
                    if let error {
                        result(FlutterError(
                            code: "badge_failed",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    } else {
                        result(nil)
                    }
                }
            }

        case "push.trackReceived":
            withAnalytics(result) {
                $0.trackPushNotificationReceived(
                    userInfo: NaryaCodec.userInfo(from: arguments["payload"])
                )
                result(nil)
            }

        case "push.trackOpened":
            // A tap the bridge itself reported is already tracked by the time
            // Dart sees it, and a host that listens on `onPushOpened` or claims
            // `takeInitialPushPayload` naturally hands that same payload back
            // here. That echo is recognised by the token the payload carries
            // and dropped, so one tap stays one `push_opened`; anything else -
            // a notification the host rendered and routed itself - is tracked.
            // See `NaryaPushOpenLedger`.
            let openedPayload = NaryaCodec.userInfo(from: arguments["payload"])
            if pushOpenLedger.consumeEcho(openedPayload) {
                NSLog(
                    "[mithra_flutter_sdk] push.trackOpened ignored: the bridge "
                        + "already tracked this tap."
                )
                result(nil)
                return
            }
            withAnalytics(result) {
                $0.trackPushNotificationOpened(
                    userInfo: NaryaPushOpenLedger.withoutTapToken(openedPayload)
                )
                result(nil)
            }

        case "push.deepLinkFrom":
            let url = Analytics.pushDeepLink(
                from: NaryaCodec.userInfo(from: arguments["payload"])
            )
            result(url?.absoluteString)

        case "push.handleBackgroundNotification":
            withAnalytics(result) { instance in
                // The closure parameter is typed on purpose. The SDK also
                // offers a `(UIBackgroundFetchResult) -> Void` overload,
                // `FlutterResult` accepts `Any?` so both type-check, and
                // overload ranking would pick the non-optional
                // `UIBackgroundFetchResult` one - sending a Swift enum over the
                // channel, which the standard codec cannot encode and which
                // crashes the host. Dart expects a `bool`.
                let onHandled: (Bool) -> Void = { handled in result(handled) }
                instance.handleBackgroundNotification(
                    userInfo: NaryaCodec.userInfo(from: arguments["payload"]),
                    completionHandler: onHandled
                )
            }

        case "push.takeInitialPushPayload":
            let payload = initialPushPayload
            initialPushPayload = nil
            result(payload)

        // Android only: on iOS the system (or the Notification Service
        // Extension) renders every push, so there is nothing to draw here.
        // Dart reads `false` as "no notification was posted by this call".
        case "push.handlePushMessage":
            result(false)

        default:
            handleInApp(call, arguments: arguments, result: result)
        }
    }

    private func handleInApp(
        _ call: FlutterMethodCall,
        arguments: [String: Any],
        result: @escaping FlutterResult
    ) {
        // Every in-app method needs a messageId except the collection reads.
        func messageId() -> String? { arguments["messageId"] as? String }

        switch call.method {
        case "inApp.messages":
            withInApp(result) { result(NaryaInAppBridge.encodeAll($0.messages)) }

        case "inApp.inboxMessages":
            withInApp(result) { result(NaryaInAppBridge.encodeAll($0.inboxMessages)) }

        case "inApp.unreadInboxMessageCount":
            withInApp(result) { result($0.unreadInboxMessageCount) }

        case "inApp.message":
            withInApp(result) { manager in
                guard let id = messageId() else {
                    return self.missingArgument("messageId", call: call, result: result)
                }
                result(manager.message(id: id).map { NaryaInAppBridge.encode($0) })
            }

        case "inApp.setRead":
            withInApp(result) { manager in
                guard let id = messageId() else {
                    return self.missingArgument("messageId", call: call, result: result)
                }
                manager.setRead(id, read: arguments["read"] as? Bool ?? false)
                result(nil)
            }

        case "inApp.removeMessage":
            withInApp(result) { manager in
                guard let id = messageId() else {
                    return self.missingArgument("messageId", call: call, result: result)
                }
                manager.removeMessage(
                    id,
                    source: NaryaInAppBridge.decodeDeleteSource(
                        arguments["source"] as? String
                    )
                )
                result(nil)
            }

        case "inApp.showMessage":
            withInApp(result) { manager in
                guard let id = messageId() else {
                    return self.missingArgument("messageId", call: call, result: result)
                }
                manager.showMessage(
                    id,
                    consume: arguments["consume"] as? Bool ?? true,
                    location: NaryaInAppBridge.decodeLocation(
                        arguments["location"] as? String
                    )
                )
                result(nil)
            }

        case "inApp.syncMessages":
            withInApp(result) {
                $0.syncInAppMessages()
                result(nil)
            }

        case "inApp.autoDisplayPaused":
            withInApp(result) { result($0.autoDisplayPaused) }

        case "inApp.setAutoDisplayPaused":
            withInApp(result) {
                $0.autoDisplayPaused = arguments["paused"] as? Bool ?? false
                result(nil)
            }

        case "inApp.resumeDisplay":
            withInApp(result) {
                $0.resumeInAppDisplay()
                result(nil)
            }

        case "inApp.unhandledJsonOnlyMessages":
            withInApp(result) {
                result(NaryaInAppBridge.encodeAll($0.unhandledJsonOnlyMessages))
            }

        case "inApp.markJsonOnlyMessageHandled":
            withInApp(result) { manager in
                guard let id = messageId() else {
                    return self.missingArgument("messageId", call: call, result: result)
                }
                result(manager.markJsonOnlyMessageHandled(id))
            }

        case "inApp.clearUnhandledJsonOnlyMessages":
            withInApp(result) {
                $0.clearUnhandledJsonOnlyMessages()
                result(nil)
            }

        case "inApp.startInboxSession":
            withInApp(result) {
                $0.startInboxSession()
                result(nil)
            }

        case "inApp.startInboxImpression":
            withInApp(result) { manager in
                guard let id = messageId() else {
                    return self.missingArgument("messageId", call: call, result: result)
                }
                manager.startInboxImpression(messageId: id)
                result(nil)
            }

        case "inApp.endInboxImpression":
            withInApp(result) { manager in
                guard let id = messageId() else {
                    return self.missingArgument("messageId", call: call, result: result)
                }
                manager.endInboxImpression(messageId: id)
                result(nil)
            }

        case "inApp.endInboxSession":
            withInApp(result) {
                $0.endInboxSession()
                result(nil)
            }

        case "inApp.notifyNewMessageHandler":
            hasDartNewMessageHandler = arguments["attached"] as? Bool ?? false
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - initialize

    private func initialize(arguments: [String: Any], result: @escaping FlutterResult) {
        let source = arguments["configuration"] as? [String: Any]
        let identity = NaryaConfigurationCodec.identity(of: source)

        if analytics != nil {
            if identity == configurationIdentity {
                result(nil)
            } else {
                result(FlutterError(
                    code: "already_initialized",
                    message: "Narya is already initialized with a different "
                        + "configuration. Call Narya.shutdown() before initializing again.",
                    details: nil
                ))
            }
            return
        }

        do {
            let configuration = try NaryaConfigurationCodec.decode(source)
            let instance = Analytics(configuration: configuration)
            analytics = instance
            configurationIdentity = identity
            // `shutdown` hands the notification center delegate back to whoever
            // held it, so re-initializing has to claim the role again; this is
            // a no-op when the plugin already holds it, and for an app that has
            // never registered for push there is nothing to claim.
            installNotificationCenterDelegateIfPushInUse()
            installObservers(for: instance)
            replayPendingPushState(on: instance)
            result(nil)
        } catch let error as NaryaConfigurationError {
            result(FlutterError(code: error.code, message: error.message, details: nil))
        } catch {
            result(FlutterError(
                code: "native_error",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }

    // MARK: - native to Dart observers

    private func installObservers(for instance: Analytics) {
        // Reading `inApp` starts the feature, so do it once here.
        let manager = instance.inApp
        manager.delegate = self
        manager.setCustomActionHandler { [weak self] name, message in
            self?.invokeCallback(
                CallbackMethod.onCustomAction,
                arguments: [
                    "name": name,
                    "message": NaryaInAppBridge.encode(message),
                ]
            )
        }

        manager.unreadInboxMessageCountPublisher
            .sink { [weak self] count in
                self?.eventSink.send(
                    type: EventType.unreadCountChanged,
                    payload: ["count": count]
                )
            }
            .store(in: &inboxObservers)

        messagesObserver = NotificationCenter.default.addObserver(
            forName: InAppManager.messagesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak manager] _ in
            guard let manager else { return }
            self?.eventSink.send(
                type: EventType.inboxMessagesChanged,
                payload: ["messages": NaryaInAppBridge.encodeAll(manager.inboxMessages)]
            )
        }

        installPushOpenHandler()
    }

    /// The only `userInfo` key `Analytics.routeInAppDeepLink` writes
    /// (`PushNotificationPayload.messageIdProperty`).
    private static let messageIdPayloadKey = "message_id"

    /// Whether a push-open handler invocation actually came from a link inside
    /// an in-app message.
    ///
    /// The native SDK funnels in-app links through the push-open handler and
    /// builds a synthetic `PushOpenContext` whose `userInfo` is either empty or
    /// holds only `message_id`. A real push open can never look like that: the
    /// handler only fires after `pushDeepLink(from:)` resolved a URL, which
    /// requires an `open_action` / `deep_link` / `actions` / `CustomData` /
    /// `mithra` key, and a real APNs payload also always carries `aps`.
    private static func isInAppLinkContext(_ context: PushOpenContext) -> Bool {
        context.userInfo.keys.allSatisfy { ($0 as? String) == messageIdPayloadKey }
    }

    /// Routes in-app message links - which the native SDK funnels through the
    /// push-open handler - to Dart.
    ///
    /// Push opens are **not** emitted from here. The SDK only invokes this
    /// handler once `pushDeepLink(from:actionIdentifier:)` resolved a URL, so an
    /// `open_app` action, a payload with no `open_action` at all and a
    /// dismissal would never reach Dart even though the native `push_opened`
    /// event is tracked for them. `push_opened` is therefore emitted from the
    /// plugin's own `userNotificationCenter(_:didReceive:)`, where the payload
    /// and the action identifier are both at hand; see `emitPushOpened`.
    ///
    /// Returning `true` tells the SDK the link was claimed, so it does not also
    /// open the URL itself - Dart owns routing, as the contract requires.
    private func installPushOpenHandler() {
        installedPushOpenHandler = true
        Analytics.setPushOpenHandler { [weak self] url, context in
            guard let self else { return false }
            guard Self.isInAppLinkContext(context) else {
                // A push open: already reported to Dart from the notification
                // center delegate. Claim it so the SDK stops here.
                return true
            }
            // An in-app message link: emit a distinct event so hosts can tell
            // the two apart, and never record it as a cold-start push payload.
            self.eventSink.send(
                type: EventType.inAppDeepLink,
                payload: [
                    "url": url.absoluteString,
                    "messageId": context.messageId ?? "",
                ]
            )
            return true
        }
    }

    /// Reports a Mithra notification tap to Dart.
    ///
    /// Dismissals are skipped: the native SDK tracks those as `push_dismissed`,
    /// and `onPushOpened` documents opens only. That covers the system dismiss
    /// gesture and a tap on an action button whose route is `dismiss`, which
    /// iOS reports under the button's own identifier rather than the system
    /// one. Android needs no equivalent check: a dismiss button there is a
    /// broadcast that never reaches the tap activity, so it was never a Dart
    /// open event.
    ///
    /// A tap processed before the Flutter engine subscribed to the event
    /// channel is a cold start. It is then handed over through
    /// `takeInitialPushPayload` **only**: the sink replays its backlog to the
    /// first subscriber, so also sending the envelope would deliver the same
    /// tap twice and route the deep link twice.
    private func emitPushOpened(for response: UNNotificationResponse) {
        guard !NaryaPushGate.isDismissal(response) else {
            return
        }

        let userInfo = response.notification.request.content.userInfo
        let payload = NaryaCodec.payload(from: userInfo)

        if !eventSink.hasListener {
            if initialPushPayload == nil { initialPushPayload = pushOpenLedger.stamp(payload) }
            return
        }

        let context = PushOpenContext(
            userInfo: userInfo,
            actionIdentifier: response.actionIdentifier
        )
        eventSink.send(
            type: EventType.pushOpened,
            payload: [
                "payload": pushOpenLedger.stamp(payload),
                "deepLink": Analytics.pushDeepLink(from: response)?.absoluteString,
                "messageId": context.messageId,
                "actionIdentifier": context.actionIdentifier,
                "isBodyTap": context.isBodyTap,
                "isActionButtonTap": context.isActionButtonTap,
            ]
        )
    }

    /// Applies APNs state that arrived while `analytics` was still `nil`.
    ///
    /// Must run after `installObservers`, so a replayed in-app link resolved
    /// from the tap still reaches the push-open handler. The Dart side of the
    /// tap was already reported by `emitPushOpened` when it arrived, so this
    /// only completes the native tracking.
    private func replayPendingPushState(on instance: Analytics) {
        if let token = pendingDeviceToken {
            pendingDeviceToken = nil
            instance.setPushToken(deviceToken: token)
        }
        if let response = pendingNotificationResponse {
            pendingNotificationResponse = nil
            instance.trackPushNotificationOpened(response: response)
        }
    }

    // MARK: - native APNs registration

    /// Requests notification permission and, when granted, registers with APNs.
    ///
    /// Mirrors the native demo's `PushManager.ensureAuthorizedAndRegistered`:
    /// `notDetermined` shows the system prompt; `authorized` / `provisional` /
    /// `ephemeral` re-register so a fresh token is delivered; `denied` only
    /// reports.
    ///
    /// This is one of the places the plugin claims the `UNUserNotificationCenter`
    /// delegate and marks push as in use for every later launch, so that the
    /// role can then be claimed at plugin registration - early enough
    /// for a tap that cold-started the app. On this very first launch no such
    /// tap is possible, because the app has no token yet; a tap that arrives
    /// before `initialize` completes is replayed into the SDK by
    /// `pendingNotificationResponse`. See
    /// `installNotificationCenterDelegateIfPushInUse` for the ownership rule.
    private func registerForRemoteNotifications(
        arguments: [String: Any],
        result: @escaping FlutterResult
    ) {
        var options: UNAuthorizationOptions = []
        if arguments["alert"] as? Bool ?? true { options.insert(.alert) }
        if arguments["badge"] as? Bool ?? true { options.insert(.badge) }
        if arguments["sound"] as? Bool ?? true { options.insert(.sound) }

        markPushInUseAndInstallNotificationCenterDelegate(
            from: .dartRegisterForRemoteNotifications
        )

        let center = UNUserNotificationCenter.current()
        // FlutterResult must be invoked on the platform thread; the
        // UNUserNotificationCenter callbacks arrive on a background queue.
        let reply: (Any?) -> Void = { value in
            DispatchQueue.main.async { result(value) }
        }
        let replyStatus: (UNAuthorizationStatus) -> Void = { status in
            reply(Self.authorizationStatusName(status))
        }

        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: options) { granted, error in
                    if let error {
                        reply(FlutterError(
                            code: "authorization_failed",
                            message: error.localizedDescription,
                            details: nil
                        ))
                        return
                    }
                    guard granted else {
                        replyStatus(.denied)
                        return
                    }
                    self?.registerWithAPNs()
                    // Re-read rather than assume `.authorized`: granting a
                    // request that included `.provisional` yields `.provisional`.
                    center.getNotificationSettings { replyStatus($0.authorizationStatus) }
                }

            case .denied:
                replyStatus(.denied)

            default:
                self?.registerWithAPNs()
                replyStatus(settings.authorizationStatus)
            }
        }
    }

    private func registerWithAPNs() {
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Makes the plugin the `UNUserNotificationCenter` delegate and chains to
    /// whatever was installed before.
    ///
    /// The role is taken only by an app that uses push, and only through
    /// `installNotificationCenterDelegateIfPushInUse` or
    /// `markPushInUseAndInstallNotificationCenterDelegate`; a host that only
    /// sends analytics never becomes the notification center delegate. Once
    /// push is in use the role is taken as early as possible (unless the plugin
    /// already holds it): at plugin registration, again from
    /// `application(_:didFinishLaunchingWithOptions:)` - which runs after every
    /// plugin has registered, so a delegate installed by one of them is chained
    /// rather than lost - and again from `initialize`. A cold-start tap is
    /// delivered right after `didFinishLaunchingWithOptions` returns and is
    /// dropped for good when no delegate is installed yet, which is why
    /// claiming the role from the `registerForRemoteNotifications` method
    /// channel alone would be too late - hence the persisted flag rather than a
    /// per-launch one.
    ///
    /// The default `FlutterAppDelegate` forwards
    /// only the `UIApplicationDelegate` APNs callbacks to plugins - never
    /// `willPresent` / `didReceive(response:)` - and a third-party delegate
    /// such as `FLTFirebaseMessagingPlugin` (which `firebase_messaging` still
    /// registers on iOS even when the host only uses it for Android) forwards
    /// nothing at all, so leaving either in place silently loses
    /// `push_delivered` and `push_opened` and shows no foreground banner.
    ///
    /// The replaced delegate is kept (weakly) and receives every callback after
    /// the plugin has handled it (`willPresent` options are unioned, the
    /// previous delegate owns the completion of `didReceive`, `openSettingsFor`
    /// is forwarded only), so host code in the app delegate and other
    /// notification plugins keep working. A debug line names the class that
    /// was chained.
    ///
    /// Must run on the main thread; the method-channel handler does.
    private func installNotificationCenterDelegate() {
        let center = UNUserNotificationCenter.current()
        let current = center.delegate
        if current === self { return }
        if let current {
            NSLog(
                "[mithra_flutter_sdk] Taking over UNUserNotificationCenter.delegate "
                    + "from %@; every callback is forwarded to it after the plugin's "
                    + "own handling.",
                String(describing: type(of: current))
            )
        }
        previousNotificationCenterDelegate = current
        center.delegate = self
    }

    /// Claims the notification center delegate, but only for a host for which
    /// push is in use (in this launch or an earlier one) - that is, one that
    /// registered for push through either Dart entry point or received an APNs
    /// token by any route. See
    /// `markPushInUseAndInstallNotificationCenterDelegate` for the full list.
    ///
    /// Called from the launch paths - plugin registration,
    /// `didFinishLaunchingWithOptions`, `initialize` - none of which can tell
    /// on their own whether the app uses push, which is why
    /// `markPushInUseAndInstallNotificationCenterDelegate` persists the answer.
    private func installNotificationCenterDelegateIfPushInUse() {
        guard pushOwnership.shouldClaimDelegateOnLaunch else { return }
        installNotificationCenterDelegate()
    }

    /// Records that this app uses push and claims the notification center
    /// delegate straight away.
    ///
    /// `NaryaPushOwnership.Entry` is the complete list of callers - every way
    /// push can start being used, and why
    /// `didFailToRegisterForRemoteNotificationsWithError` is not one of them.
    /// The flag it writes persists across launches, so the launch paths above
    /// can claim the role before iOS delivers a cold-start tap.
    private func markPushInUseAndInstallNotificationCenterDelegate(
        from entry: NaryaPushOwnership.Entry
    ) {
        pushOwnership.recordPushInUse(from: entry)
        installNotificationCenterDelegate()
    }

    /// Hands the notification center delegate back to whoever held it before.
    ///
    /// Called from `shutdown`: an inert plugin must not keep intercepting
    /// notifications, and a tap it stored while `analytics` was `nil` would
    /// otherwise be replayed as a live `push_opened` by the next `initialize`,
    /// with a timestamp and a session that no longer match.
    private func restoreNotificationCenterDelegate() {
        let center = UNUserNotificationCenter.current()
        if center.delegate === self {
            center.delegate = previousNotificationCenterDelegate
        }
        previousNotificationCenterDelegate = nil
    }

    /// Runs `body` against the delegate the plugin replaced when it implements
    /// `selector`, with the re-entrancy flag raised. Returns whether the call
    /// was forwarded, so the caller knows whether it must complete itself.
    @discardableResult
    private func forwardToPreviousDelegate(
        _ selector: Selector,
        _ body: (UNUserNotificationCenterDelegate) -> Void
    ) -> Bool {
        guard !isForwardingToPreviousDelegate,
              let previous = previousNotificationCenterDelegate,
              previous.responds(to: selector) else {
            return false
        }
        isForwardingToPreviousDelegate = true
        defer { isForwardingToPreviousDelegate = false }
        body(previous)
        return true
    }

    /// The wire value Dart decodes into `NaryaPushAuthorizationStatus`.
    private static func authorizationStatusName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .ephemeral:
            return "authorized"
        case .provisional:
            return "provisional"
        case .denied:
            return "denied"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "notDetermined"
        }
    }

    /// Lowercase hex form of an APNs token, the same encoding the native SDK's
    /// `setPushToken(deviceToken:)` applies.
    private static func hexString(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    /// Undoes everything `installObservers` and the delegate takeover put in
    /// place, and drops every piece of deferred state, so a later `initialize`
    /// starts clean instead of replaying stale taps and tokens.
    private func teardownObservers() {
        inboxObservers.removeAll()
        if let messagesObserver {
            NotificationCenter.default.removeObserver(messagesObserver)
        }
        messagesObserver = nil
        // `setPushOpenHandler` is a process-wide slot: clearing it
        // unconditionally would silently remove a native handler the host
        // installed itself.
        if installedPushOpenHandler {
            Analytics.setPushOpenHandler(nil)
            installedPushOpenHandler = false
        }
        restoreNotificationCenterDelegate()
        pendingShowDecisions.removeAll()
        askedShowDecisions.removeAll()
        hasDartNewMessageHandler = false
        deliveryTrackedAt.removeAll()
        initialPushPayload = nil
        pushOpenLedger.clear()
        pendingDeviceToken = nil
        pendingNotificationResponse = nil
    }

    /// Whether a `push_delivered` event should be tracked for this payload.
    ///
    /// A push carrying both an `alert` and `content-available: 1` reaches both
    /// `didReceiveRemoteNotification` and `willPresent` while the app is in the
    /// foreground; without this gate it would be counted twice. Payloads with
    /// no `mithra_message_id` cannot be deduplicated and are always tracked.
    private func shouldTrackDelivery(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let messageId = NaryaPushGate.messageId(userInfo) else { return true }
        let now = Date()
        deliveryTrackedAt = deliveryTrackedAt.filter {
            now.timeIntervalSince($0.value) < Self.deliveryDedupWindow
        }
        if deliveryTrackedAt[messageId] != nil { return false }
        deliveryTrackedAt[messageId] = now
        return true
    }

    /// How long a tracked `push_delivered` suppresses a repeat for the same
    /// message. Long enough to cover the two callbacks of a single delivery,
    /// short enough not to swallow a genuine resend.
    private static let deliveryDedupWindow: TimeInterval = 30

    // MARK: - helpers

    private func withAnalytics(
        _ result: @escaping FlutterResult,
        _ body: (Analytics) -> Void
    ) {
        guard let analytics else {
            result(FlutterError(
                code: "not_initialized",
                message: "Narya.initialize() must complete before any other "
                    + "Narya API is called.",
                details: nil
            ))
            return
        }
        body(analytics)
    }

    private func withInApp(
        _ result: @escaping FlutterResult,
        _ body: (InAppManager) -> Void
    ) {
        withAnalytics(result) { body($0.inApp) }
    }

    private func missingArgument(
        _ name: String,
        call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        result(FlutterError(
            code: "invalid_argument",
            message: "\(call.method) requires the \"\(name)\" argument.",
            details: nil
        ))
    }

    fileprivate func invokeCallback(
        _ method: String,
        arguments: [String: Any?],
        onReply: ((Any?, Bool) -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let onReply else {
                self.callbackChannel.invokeMethod(method, arguments: arguments)
                return
            }
            self.callbackChannel.invokeMethod(method, arguments: arguments) { reply in
                if let error = reply as? FlutterError {
                    _ = error
                    onReply(nil, false)
                } else if reply is NSObject, FlutterMethodNotImplemented.isEqual(reply) {
                    onReply(nil, true)
                } else {
                    onReply(reply, false)
                }
            }
        }
    }
}

// MARK: - FlutterApplicationLifeCycleDelegate (APNs)

extension MithraFlutterSdkPlugin {

    /// Claims the notification center delegate - for a host that uses push -
    /// before iOS can deliver a cold-start tap.
    ///
    /// `FlutterPluginAppLifeCycleDelegate` fans this out after every plugin has
    /// registered, so a delegate one of them installed is chained instead of
    /// being lost, and it runs before the `didReceive(response:)` that follows
    /// a launch from a notification. Always returns `true`: a `false` from any
    /// plugin aborts the fan-out for the rest.
    @objc
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any]?
    ) -> Bool {
        installNotificationCenterDelegateIfPushInUse()
        return true
    }

    /// Hands the APNs token to the SDK and to Dart (`push_token`, hex).
    ///
    /// Fires after `registerForRemoteNotifications` and whenever the system
    /// rotates the token. Before `initialize` the token is queued; the Dart
    /// event is buffered by the sink until the engine subscribes.
    ///
    /// This is also the third entry point that marks push as in use, and the
    /// only one that is not a Dart call: `FlutterPluginAppLifeCycleDelegate`
    /// fans this callback out to every plugin, so it fires whenever *anything*
    /// in the process registered with APNs - host code in the app delegate, or
    /// `firebase_messaging`, which owns APNs registration on iOS. Such a host
    /// never calls `push.registerForRemoteNotifications` or `push.setToken`,
    /// yet its device is registered with gwaihir through the token below and
    /// does receive Narya pushes; without marking push in use here the plugin
    /// would never become the notification center delegate, and every
    /// `push_delivered` / `push_opened` event plus every `open_action` and deep
    /// link would be lost silently. An APNs token in hand is the ground truth
    /// for "this app uses push", and an analytics-only app never receives this
    /// callback, so marking it here does not regress to claiming the role on
    /// every launch. Marked in both branches: the token exists either way.
    @objc
    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        markPushInUseAndInstallNotificationCenterDelegate(from: .apnsDeviceTokenReceived)
        if let analytics {
            analytics.setPushToken(deviceToken: deviceToken)
        } else {
            pendingDeviceToken = deviceToken
        }
        eventSink.send(
            type: EventType.pushToken,
            payload: ["token": Self.hexString(deviceToken)]
        )
    }

    /// Reports an APNs registration failure to Dart (`push_registration_error`).
    ///
    /// The stored token is dropped as well: the native SDK asks for
    /// `clearPushToken()` here, and leaving a token that APNs has stopped
    /// honouring on `context.device.token` keeps gwaihir pushing to a dead
    /// device.
    ///
    /// Push is deliberately *not* marked in use here: a registration that
    /// failed yields no token and no deliverable push, so there is nothing for
    /// the notification center delegate to handle.
    @objc
    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        let nsError = error as NSError
        pendingDeviceToken = nil
        analytics?.clearPushToken()
        eventSink.send(
            type: EventType.pushRegistrationError,
            payload: [
                "code": "\(nsError.domain):\(nsError.code)",
                "message": nsError.localizedDescription,
            ]
        )
    }

    /// Silent / background remote notifications.
    ///
    /// Forwards to the SDK's `handleBackgroundNotification`, which performs the
    /// in-app sync wake and always completes the fetch handler. A visible
    /// Mithra push that reaches this callback is tracked as `push_delivered`;
    /// the silent `inapp_sync` wake is not, matching the native SDK's rule, and
    /// neither is one a Notification Service Extension already tracked or one
    /// already counted through `willPresent`.
    ///
    /// `FlutterPluginAppLifeCycleDelegate` walks its plugins in registration
    /// order and stops at the first one that returns `true`, so the plugin
    /// claims a payload only when it is Mithra's and it can actually act on it.
    /// Anything else returns `false` **without touching the completion
    /// handler**, leaving the callback to the plugins registered after this one
    /// - `FLTFirebaseMessagingPlugin` and its `onBackgroundMessage`, typically.
    /// Registration order is not guaranteed, and claiming every payload would
    /// break silent-push delivery for every plugin behind this one whichever
    /// order they happen to register in.
    @objc
    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) -> Bool {
        guard NaryaPushGate.isNaryaPush(userInfo) else { return false }
        guard let analytics else { return false }

        if !NaryaPushGate.isInAppSyncWake(userInfo),
           !NaryaPushGate.isTrackedByServiceExtension(userInfo),
           shouldTrackDelivery(userInfo) {
            analytics.trackPushNotificationReceived(userInfo: userInfo)
        }
        analytics.handleBackgroundNotification(
            userInfo: userInfo,
            completionHandler: completionHandler
        )
        return true
    }
}

// MARK: - UNUserNotificationCenterDelegate

/// Installed by `registerForRemoteNotifications`, replacing whatever delegate
/// was there before (see `installNotificationCenterDelegate`).
/// Each callback does the plugin's work first and then forwards to the replaced
/// delegate when it implements the method; when it does not, the plugin
/// completes the call itself. A `FlutterAppDelegate` forwards these callbacks
/// back to every plugin, so a call that arrives while forwarding is an echo of
/// one already handled and is only completed, never handled again.
extension MithraFlutterSdkPlugin: UNUserNotificationCenterDelegate {

    /// How the plugin presents a foreground notification. Merged (union) with
    /// whatever the replaced delegate asks for.
    private static let presentationOptions: UNNotificationPresentationOptions =
        [.banner, .list, .sound, .badge]

    /// How long a forwarded callback waits for the chained delegate to complete
    /// it before the plugin completes it with its own answer. A delegate that
    /// only responds to payloads it recognises never calls back at all, and an
    /// uncompleted notification callback hangs the interaction.
    private static let forwardedCompletionTimeout: TimeInterval = 2

    /// Shows foreground notifications and tracks Mithra ones as delivered,
    /// unless a Notification Service Extension already did.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if isForwardingToPreviousDelegate {
            // Echoed back by the previous delegate; the outer call merges.
            completionHandler([])
            return
        }

        let userInfo = notification.request.content.userInfo
        if let analytics,
           NaryaPushGate.isNaryaPush(userInfo),
           !NaryaPushGate.isTrackedByServiceExtension(userInfo),
           shouldTrackDelivery(userInfo) {
            analytics.trackPushNotificationReceived(userInfo: userInfo)
        }

        let ours = Self.presentationOptions
        // A fan-out delegate may complete once per plugin, and a chained
        // delegate may answer from any queue, so the one-shot guard is locked.
        let once = NaryaOneShot()
        let complete: (UNNotificationPresentationOptions) -> Void = { theirs in
            guard once.claim() else { return }
            completionHandler(theirs.union(ours))
        }
        let forwarded = forwardToPreviousDelegate(
            #selector(UNUserNotificationCenterDelegate.userNotificationCenter(
                _:willPresent:withCompletionHandler:))
        ) { previous in
            previous.userNotificationCenter?(
                center,
                willPresent: notification,
                withCompletionHandler: complete
            )
        }
        if forwarded {
            // A third-party delegate that only answers for payloads it knows
            // would otherwise leave the banner unpresented and the completion
            // handler outstanding, which iOS warns about.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.forwardedCompletionTimeout) {
                complete([])
            }
        } else {
            complete([])
        }
    }

    /// Routes a notification tap into the SDK.
    ///
    /// `trackPushNotificationOpened(response:)` records `push_opened` (or
    /// `push_dismissed`) with the selected action; a tap that arrives before
    /// `initialize` is replayed once the SDK exists. `emitPushOpened` reports
    /// the tap to Dart - `push_opened`, or the cold-start payload for
    /// `takeInitialPushPayload` - independently of the SDK's push-open handler,
    /// which only fires for taps that resolve to a URL. Non-Mithra
    /// notifications are not tracked, as the native SDK documents, but are
    /// still forwarded.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if isForwardingToPreviousDelegate {
            completionHandler()
            return
        }

        if NaryaPushGate.isNaryaPush(response) {
            if let analytics {
                analytics.trackPushNotificationOpened(response: response)
            } else {
                pendingNotificationResponse = response
            }
            emitPushOpened(for: response)
        }

        // A chained delegate may answer from any queue, so the one-shot guard
        // is locked rather than a captured `Bool`.
        let once = NaryaOneShot()
        let complete: () -> Void = {
            guard once.claim() else { return }
            completionHandler()
        }
        let forwarded = forwardToPreviousDelegate(
            #selector(UNUserNotificationCenterDelegate.userNotificationCenter(
                _:didReceive:withCompletionHandler:))
        ) { previous in
            previous.userNotificationCenter?(
                center,
                didReceive: response,
                withCompletionHandler: complete
            )
        }
        if forwarded {
            // A delegate that never completes would leave the app stuck in the
            // notification response state; fall back to completing it here.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.forwardedCompletionTimeout) {
                complete()
            }
        } else {
            complete()
        }
    }

    /// The plugin has no settings UI of its own; the call belongs to the
    /// replaced delegate.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        if isForwardingToPreviousDelegate { return }
        forwardToPreviousDelegate(
            #selector(UNUserNotificationCenterDelegate.userNotificationCenter(
                _:openSettingsFor:))
        ) { previous in
            previous.userNotificationCenter?(center, openSettingsFor: notification)
        }
    }
}

// MARK: - InAppDelegate

extension MithraFlutterSdkPlugin: InAppDelegate {

    /// Asks Dart whether a newly fetched message should be shown.
    ///
    /// The native delegate is synchronous and runs on the main thread (the
    /// display pump dispatches to it), so the bridge cannot block waiting for a
    /// platform-channel reply without deadlocking. Instead it uses the SDK's
    /// own `defer` semantics: the first time a message is offered the bridge
    /// asks Dart and returns `.defer`, which leaves the message queued; when
    /// Dart answers, the decision is cached and the display queue is pumped
    /// again, so the next pass returns the real answer. No message is lost and
    /// no behaviour is reimplemented here.
    ///
    /// A `.defer` answer is the exception: it is neither cached nor resumed, so
    /// the message simply stays queued until the host resumes display itself.
    public func onNew(_ message: InAppMessage) -> InAppShowResponse {
        guard hasDartNewMessageHandler else { return .show }

        let messageId = message.messageId
        if let decision = pendingShowDecisions.removeValue(forKey: messageId) {
            return decision
        }
        guard !askedShowDecisions.contains(messageId) else {
            // Already asked and still waiting; keep it queued.
            return .defer
        }
        askedShowDecisions.insert(messageId)

        invokeCallback(
            CallbackMethod.onNewMessage,
            arguments: ["message": NaryaInAppBridge.encode(message)]
        ) { [weak self] reply, isMissing in
            guard let self else { return }
            self.askedShowDecisions.remove(messageId)
            if isMissing {
                self.hasDartNewMessageHandler = false
            }
            let decision = NaryaInAppBridge.decodeShowResponse(reply)
            guard decision != .defer else {
                // Dart asked to hold the message back, so nothing is cached and
                // nothing is resumed. Caching `.defer` would make the next pass
                // consume it, return `.defer` again, find no decision on the
                // pass after that and re-ask Dart - an unbounded ask/resume
                // loop for a host that defers during onboarding. Resuming would
                // also clear an `autoDisplayPaused` the host set. The message
                // stays queued and Dart is asked again the next time the host
                // resumes display.
                return
            }
            self.pendingShowDecisions[messageId] = decision
            self.analytics?.inApp.resumeInAppDisplay()
        }
        return .defer
    }

    /// Hands a json-only payload to Dart.
    ///
    /// Returning `false` leaves the message in the SDK's replay buffer, so
    /// nothing is lost while Dart is consulted. When Dart reports the payload
    /// handled, the bridge marks it handled explicitly.
    public func onJsonOnlyMessage(
        _ payload: [String: Any],
        message: InAppMessage
    ) -> Bool {
        let messageId = message.messageId
        invokeCallback(
            CallbackMethod.onJsonOnlyMessage,
            arguments: [
                "payload": payload,
                "message": NaryaInAppBridge.encode(message),
            ]
        ) { [weak self] reply, _ in
            if reply as? Bool == true {
                _ = self?.analytics?.inApp.markJsonOnlyMessageHandled(messageId)
            }
        }
        return false
    }
}
