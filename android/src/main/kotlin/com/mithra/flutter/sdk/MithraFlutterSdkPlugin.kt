package com.mithra.flutter.sdk

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.mithra.sdk.kotlin.android.Analytics
import com.mithra.sdk.kotlin.inapp.InAppDelegate
import com.mithra.sdk.kotlin.inapp.InAppManager
import com.mithra.sdk.kotlin.inapp.InAppMessage
import com.mithra.sdk.kotlin.inapp.InAppShowResponse
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

/**
 * The Android half of the `mithra_flutter_sdk` bridge.
 *
 * The class is deliberately thin: it decodes the argument map, calls exactly
 * one Narya SDK API, and encodes the reply. All behaviour - batching, storage,
 * the in-app display queue, notification rendering and every pixel of in-app
 * rendering - lives in the native SDK.
 *
 * The native [Analytics] instance is **not** owned by the plugin instance:
 * `firebase_messaging` runs its background handler on a second Flutter engine
 * with its own plugin instance, so the SDK lives in the process-wide
 * [NaryaAnalyticsHolder] and every engine in the process shares it.
 */
class MithraFlutterSdkPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var callbackChannel: MethodChannel
    private lateinit var applicationContext: Context

    private val eventSink = NaryaEventSink()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var activityBinding: ActivityPluginBinding? = null

    /** The process-wide SDK instance, when one exists; see [NaryaAnalyticsHolder]. */
    private val analytics: Analytics?
        get() = NaryaAnalyticsHolder.analytics

    /**
     * The tap payload of the notification that cold-started the app, consumed
     * once by `push.takeInitialPushPayload`.
     */
    private val initialPushPayload = AtomicReference<Map<String, Any?>?>(null)

    private var delegateInstalled = false

    /** Decisions Dart has answered but the display pump has not consumed yet. */
    private val pendingShowDecisions = ConcurrentHashMap<String, InAppShowResponse>()

    /** Messages already sent to Dart and still awaiting an answer. */
    private val askedShowDecisions = ConcurrentHashMap.newKeySet<String>()

    /**
     * Whether Dart appears to have an `onNewMessage` handler attached.
     *
     * Dart only installs a callback-channel handler once the host registers
     * one, so before that the channel answers `notImplemented`. The first such
     * answer clears this flag and the bridge stops paying for a deferred round
     * trip per message; registering a handler later sets it again through
     * `inApp.notifyNewMessageHandler`.
     */
    @Volatile
    private var hasDartNewMessageHandler = true

    /**
     * Scope for the inbox state collectors.
     *
     * Cancelled on engine detach and rebuilt on the next attach: the same
     * plugin instance can legitimately be attached again (add-to-app, a manual
     * `FlutterEngineGroup` registration, a widget test), and a cancelled
     * [SupervisorJob] would make every later `launch` a silent no-op.
     */
    private var observerScope = newObserverScope()

    /** The two inbox collectors, kept so they can be cancelled individually. */
    private var inboxMessagesJob: Job? = null
    private var unreadCountJob: Job? = null

    // --- FlutterPlugin -------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        if (!observerScope.isActive) {
            observerScope = newObserverScope()
        }
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL_METHODS)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, CHANNEL_EVENTS)
        eventChannel.setStreamHandler(eventSink)
        callbackChannel = MethodChannel(binding.binaryMessenger, CHANNEL_CALLBACKS)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink.clear()
        // The in-app manager is process-wide, so a delegate left registered by
        // a detached engine would keep answering DEFER over a dead messenger
        // and no in-app message would ever be displayed again.
        analytics?.let { uninstallInAppObservers(it) }
        observerScope.cancel()
    }

    private fun newObserverScope(): CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // --- ActivityAware -------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        handleIntent(binding.activity.intent, isColdStart = true)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        handleIntent(intent, isColdStart = false)
        // Never claim the intent: the host activity may have its own handling.
        return false
    }

    /**
     * Reports one notification tap: tracks `push_opened` and emits the tap to
     * Dart.
     *
     * Two guards keep one tap to one event. The tap extras live on the activity
     * intent for as long as that intent does, and `onAttachedToActivity` runs
     * again whenever the activity is recreated, so a handled intent is marked
     * and skipped on later passes; the marker is an extra of this plugin's own,
     * and the SDK's extras are left untouched so host code can still read them.
     * The tap is additionally remembered by its own identity, which is what
     * lets `push.trackOpened` recognise - and ignore - the host handing the
     * very same tap payload straight back, the shape every `onPushOpened` /
     * `takeInitialPushPayload` listener that also tracks the open has.
     */
    private fun handleIntent(intent: Intent?, isColdStart: Boolean) {
        if (intent == null || !NaryaPushBridge.isPushOpen(intent)) return
        if (NaryaPushBridge.isTapReported(intent)) return
        val instance = analytics
        if (instance == null) {
            // The engine can attach before initialize() completes. Keep the raw
            // tap so takeInitialPushPayload can still answer, and leave the
            // intent unmarked so initialize() reports it.
            if (isColdStart) {
                initialPushPayload.compareAndSet(null, emptyMap())
            }
            return
        }
        NaryaPushBridge.markTapReported(intent)
        NaryaPushBridge.rememberReportedTap(intent)
        val encoded = NaryaPushBridge.encodeTap(instance, intent)
        if (isColdStart) {
            @Suppress("UNCHECKED_CAST")
            initialPushPayload.set(encoded["payload"] as? Map<String, Any?> ?: emptyMap())
        }
        // iOS tracks the open inside `didReceive(response:)`, so the bridge
        // owns this on both platforms; a host that also calls trackOpened with
        // the payload it is about to receive is de-duplicated there.
        instance.trackPushNotificationOpened(intent)
        eventSink.send(EVENT_PUSH_OPENED, encoded)
    }

    // --- MethodCallHandler ---------------------------------------------------

    @Suppress("CyclomaticComplexMethod", "LongMethod")
    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "initialize" -> initialize(call, result)

                // A traits-only identify must leave the identity alone, which
                // is what the Dart API promises and what iOS does by passing
                // `nil`. The native SDK resets the anonymous id, the user id
                // and the traits whenever the user id it is handed differs
                // from a non-empty current one, so a bare "" is only safe for
                // an anonymous user - never for an identified one. The three
                // cases are therefore kept apart, and "" is never synthesised
                // here.
                "identify" -> withAnalytics(result) {
                    val requestedUserId = argument<String>(call, "userId")
                    val traits = jsonArgument(call, "traits")
                    val currentUserId = it.userId
                    when {
                        // An explicit user id identifies, or re-identifies,
                        // the user; the SDK resets first when it changes.
                        requestedUserId != null -> it.identify(
                            userId = requestedUserId,
                            traits = traits,
                        )

                        // Traits-only for an identified user: echoing the
                        // current id back keeps the reset guard quiet and
                        // takes the SDK's traits-merge path.
                        !currentUserId.isNullOrEmpty() -> it.identify(
                            userId = currentUserId,
                            traits = traits,
                        )

                        // Traits-only for an anonymous user: the native
                        // traits-only call, with the user id left to the SDK's
                        // own default rather than one synthesised here. That
                        // default is the empty string the anonymous identity
                        // already holds, so the reset guard never fires, the
                        // anonymous id survives and the traits are merged into
                        // the existing ones.
                        else -> it.identify(traits = traits)
                    }
                    result.success(null)
                }

                "track" -> withAnalytics(result) {
                    it.track(
                        name = requiredArgument(call, "name"),
                        properties = jsonArgument(call, "properties"),
                    )
                    result.success(null)
                }

                "screen" -> withAnalytics(result) {
                    it.screen(
                        screenName = requiredArgument(call, "name"),
                        category = argument<String>(call, "category") ?: "",
                        properties = jsonArgument(call, "properties"),
                    )
                    result.success(null)
                }

                "group" -> withAnalytics(result) {
                    it.group(
                        groupId = requiredArgument(call, "groupId"),
                        traits = jsonArgument(call, "traits"),
                    )
                    result.success(null)
                }

                "alias" -> withAnalytics(result) {
                    it.alias(
                        newId = requiredArgument(call, "newId"),
                        previousId = argument<String>(call, "previousId") ?: "",
                    )
                    result.success(null)
                }

                "flush" -> withAnalytics(result) {
                    it.flush()
                    result.success(null)
                }

                "reset" -> withAnalytics(result) {
                    it.reset()
                    result.success(null)
                }

                "startSession" -> withAnalytics(result) {
                    it.startSession((call.argument("sessionId") as? Number)?.toLong())
                    result.success(null)
                }

                "endSession" -> withAnalytics(result) {
                    it.endSession()
                    result.success(null)
                }

                "anonymousId" -> withAnalytics(result) { result.success(it.anonymousId) }
                "userId" -> withAnalytics(result) { result.success(it.userId) }
                "traits" -> withAnalytics(result) {
                    result.success(NaryaCodec.fromJsonObject(it.traits))
                }
                "sessionId" -> withAnalytics(result) { result.success(it.sessionId) }

                "openUrl" -> withAnalytics(result) {
                    // The Android SDK tracks deep links through its own
                    // activity-intent plugin and exposes no imperative entry
                    // point, so the bridge emits the same event shape the
                    // plugin does.
                    it.track(EVENT_DEEP_LINK_OPENED, deepLinkProperties(call))
                    result.success(null)
                }

                "shutdown" -> withAnalytics(result) {
                    uninstallInAppObservers(it)
                    // Nothing may survive into the next SDK lifetime, least of
                    // all a tap record that would swallow the first trackOpened
                    // of a freshly initialized instance.
                    NaryaPushBridge.clearReportedTaps()
                    NaryaAnalyticsHolder.clear(applicationContext)
                    it.shutdown()
                    result.success(null)
                }

                else -> onPushOrInAppMethodCall(call, result)
            }
        } catch (error: NaryaConfigurationException) {
            result.error(error.code, error.message, null)
        } catch (error: IllegalArgumentException) {
            result.error("invalid_argument", error.message, null)
        }
    }

    private fun onPushOrInAppMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // iOS only: Android tokens come from Firebase Cloud Messaging and
            // reach the SDK through `push.setToken`, so there is nothing to
            // register natively here. The Dart side decodes this reply into
            // `NaryaPushAuthorizationStatus.unsupported`.
            "push.registerForRemoteNotifications" -> result.success("unsupported")

            "push.setToken" -> withAnalytics(result) {
                it.setPushToken(requiredArgument(call, "token"))
                result.success(null)
            }

            "push.clearToken" -> withAnalytics(result) {
                it.clearPushToken()
                result.success(null)
            }

            // Documented no-op. Android has no platform app-icon badge API:
            // launchers derive the dot or count from the notifications the app
            // currently has posted, so a badge is cleared by dismissing or
            // cancelling those, never by an SDK call. The method exists on
            // both platforms only so host code needs no `Platform.isIOS`
            // branch, and it deliberately needs no SDK instance. Negatives are
            // clamped here as well as in Dart, so the logged value is the one
            // iOS would have applied. The count is read as a Number because
            // the standard message codec decodes a Dart int that does not fit
            // in 32 bits as a Long.
            "push.setBadgeCount" -> {
                val count = requiredArgument<Number>(call, "count")
                    .toLong()
                    .coerceAtLeast(0L)
                Log.d(
                    TAG,
                    "setBadgeCount($count) ignored: Android has no app icon " +
                        "badge API; the launcher derives it from posted " +
                        "notifications.",
                )
                result.success(null)
            }

            // The two tracking calls and handlePushMessage are the ones a host
            // makes from the firebase_messaging background isolate, where
            // Narya.initialize never ran; they restore the SDK from the
            // persisted configuration when this process has none yet.
            "push.trackReceived" -> withRestoredAnalytics(result) {
                it.trackPushNotificationReceived(payloadArgument(call))
                result.success(null)
            }

            // A tap the bridge itself reported is already tracked, and the
            // payload `onPushOpened` / `takeInitialPushPayload` hands the host
            // is the tap intent's own extras - so a host that tracks the open
            // it was just told about would double-count it. That echo is
            // recognised by the tap's identity and dropped; a notification the
            // host rendered and tracks itself carries no tap extras and is
            // unaffected.
            "push.trackOpened" -> withRestoredAnalytics(result) {
                val payload = payloadArgument(call)
                if (NaryaPushBridge.consumeReportedTapEcho(payload)) {
                    Log.d(
                        TAG,
                        "push.trackOpened ignored: the bridge already tracked this tap.",
                    )
                    result.success(null)
                    return@withRestoredAnalytics
                }
                it.trackPushNotificationOpened(payload)
                result.success(null)
            }

            // Renders the data-only FCM message through the SDK's own pipeline,
            // exactly as a native FirebaseMessagingService would. The SDK
            // returns Unit and swallows its own failures, so the reply is a
            // predicate over the payload - "this payload asks for a
            // notification" - and not a delivery receipt: it is false for
            // silent payloads such as the in-app wake push (the SDK still
            // syncs in-app messages for that one), and true even when the
            // platform then drops the notification because the user revoked
            // POST_NOTIFICATIONS or disabled the channel.
            "push.handlePushMessage" -> withRestoredAnalytics(result) {
                val data = payloadArgument(call)
                val options = NaryaPushBridge.decodeDisplayOptions(
                    applicationContext,
                    call.argument<Map<*, *>>("options"),
                )
                it.handlePushMessage(applicationContext, data, options)
                result.success(NaryaPushBridge.postsNotification(data))
            }

            "push.deepLinkFrom" -> result.success(
                NaryaPushBridge.deepLinkFrom(call.argument<Map<*, *>>("payload")),
            )

            // iOS only: an Android silent push reaches the host's
            // FirebaseMessagingService directly, so there is nothing to hand to
            // the SDK here.
            "push.handleBackgroundNotification" -> result.success(false)

            "push.takeInitialPushPayload" ->
                result.success(initialPushPayload.getAndSet(null))

            else -> onInAppMethodCall(call, result)
        }
    }

    @Suppress("CyclomaticComplexMethod", "LongMethod")
    private fun onInAppMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "inApp.messages" -> withInApp(result) {
                result.success(NaryaInAppBridge.encodeAll(it.messages))
            }

            "inApp.inboxMessages" -> withInApp(result) {
                result.success(NaryaInAppBridge.encodeAll(it.inboxMessages))
            }

            "inApp.unreadInboxMessageCount" -> withInApp(result) {
                result.success(it.unreadInboxMessageCount)
            }

            "inApp.message" -> withInApp(result) { manager ->
                val message = manager.message(requiredArgument(call, "messageId"))
                result.success(message?.let { NaryaInAppBridge.encode(it) })
            }

            "inApp.setRead" -> withInApp(result) {
                it.setRead(
                    messageId = requiredArgument(call, "messageId"),
                    read = call.argument<Boolean>("read") ?: false,
                )
                result.success(null)
            }

            "inApp.removeMessage" -> withInApp(result) {
                it.removeMessage(
                    messageId = requiredArgument(call, "messageId"),
                    source = NaryaInAppBridge.decodeDeleteSource(
                        call.argument<String>("source"),
                    ),
                )
                result.success(null)
            }

            "inApp.showMessage" -> withInApp(result) {
                it.showMessage(
                    messageId = requiredArgument(call, "messageId"),
                    consume = call.argument<Boolean>("consume") ?: true,
                    location = NaryaInAppBridge.decodeLocation(
                        call.argument<String>("location"),
                    ),
                )
                result.success(null)
            }

            "inApp.syncMessages" -> withInApp(result) {
                it.syncInAppMessages()
                result.success(null)
            }

            "inApp.autoDisplayPaused" -> withInApp(result) {
                result.success(it.autoDisplayPaused)
            }

            "inApp.setAutoDisplayPaused" -> withInApp(result) {
                it.autoDisplayPaused = call.argument<Boolean>("paused") ?: false
                result.success(null)
            }

            "inApp.resumeDisplay" -> withInApp(result) {
                it.resumeInAppDisplay()
                result.success(null)
            }

            "inApp.unhandledJsonOnlyMessages" -> withInApp(result) {
                result.success(NaryaInAppBridge.encodeAll(it.unhandledJsonOnlyMessages))
            }

            "inApp.markJsonOnlyMessageHandled" -> withInApp(result) { manager ->
                val messageId = requiredArgument<String>(call, "messageId")
                // The Kotlin API returns Unit; report whether the store held
                // the message so Dart matches the iOS Bool return.
                val existed = manager.message(messageId) != null
                manager.markJsonOnlyMessageHandled(messageId)
                result.success(existed)
            }

            "inApp.clearUnhandledJsonOnlyMessages" -> withInApp(result) {
                it.clearUnhandledJsonOnlyMessages()
                result.success(null)
            }

            "inApp.startInboxSession" -> withInApp(result) {
                it.startInboxSession()
                result.success(null)
            }

            "inApp.startInboxImpression" -> withInApp(result) {
                it.startInboxImpression(requiredArgument(call, "messageId"))
                result.success(null)
            }

            "inApp.endInboxImpression" -> withInApp(result) {
                it.endInboxImpression(requiredArgument(call, "messageId"))
                result.success(null)
            }

            "inApp.endInboxSession" -> withInApp(result) {
                it.endInboxSession()
                result.success(null)
            }

            // Sent by Dart when a delegate handler is registered or cleared, so
            // the bridge knows whether asking Dart is worth a deferred pass.
            // Registering a handler is also host usage of the feature, so it
            // starts in-app messaging exactly like any other inApp.* call.
            "inApp.notifyNewMessageHandler" -> {
                val attached = call.argument<Boolean>("attached") ?: false
                hasDartNewMessageHandler = attached
                if (attached) {
                    analytics?.let { instance ->
                        NaryaInAppBridge.managerOf(instance)?.let(::installInAppObservers)
                    }
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // --- initialize ----------------------------------------------------------

    private fun initialize(call: MethodCall, result: Result) {
        val source = call.argument<Map<*, *>>("configuration")
        val identity = NaryaConfigurationCodec.identityOf(source)
        val existing = analytics
        if (existing != null && identity != NaryaAnalyticsHolder.configurationIdentity) {
            result.error(
                "already_initialized",
                "Narya is already initialized with a different configuration. " +
                    "Call Narya.shutdown() before initializing again.",
                null,
            )
            return
        }
        if (existing == null) {
            val application = applicationContext as? Application
                ?: throw NaryaConfigurationException(
                    "native_error",
                    "The plugin was attached to a context that is not an Application.",
                )
            // Constructs the SDK and persists the configuration map so a fresh
            // process (the firebase_messaging background engine) can rebuild
            // it. The check above is not the authority: two engines can reach
            // it concurrently, so the holder re-checks under its own lock and
            // reports `already_initialized` for the loser of a race that
            // carried a different configuration, rather than silently handing
            // it the first engine's instance.
            NaryaAnalyticsHolder.create(application, source)
        }
        // In-app messaging is deliberately NOT started here: creating the
        // manager starts the feature (fetching, storage, the display pump),
        // which a host that never uses in-app messages should not pay for and
        // which `inApp.enabled = false` must be able to switch off. The
        // observers are installed on the first inApp.* call from Dart.

        // A tap may have arrived before initialize() completed.
        activityBinding?.activity?.intent?.let { handleIntent(it, isColdStart = true) }
        result.success(null)
    }

    // --- native to Dart observers -------------------------------------------

    /**
     * Points the process-wide in-app manager's host hooks at this engine's Dart
     * side. Called lazily, from the first in-app call Dart makes, so the plugin
     * never starts in-app messaging on behalf of a host that does not use it.
     */
    private fun installInAppObservers(manager: InAppManager) {
        if (delegateInstalled) return
        manager.setDelegate(BridgeInAppDelegate())
        manager.setCustomActionHandler { name, message ->
            invokeCallback(
                CALLBACK_ON_CUSTOM_ACTION,
                mapOf("name" to name, "message" to NaryaInAppBridge.encode(message)),
            )
        }
        // Without a handler the SDK only logs the resolved destination and the
        // link is lost. The SDK never opens it; Dart owns routing, so hand the
        // URI over as a distinct event rather than folding it into push opens.
        manager.setDeepLinkHandler { uri, message ->
            eventSink.send(
                EVENT_INAPP_DEEP_LINK,
                mapOf("url" to uri.toString(), "messageId" to message.messageId),
            )
        }
        // The StateFlows replay their current value on collection; drop it so
        // Dart sees changes rather than an immediate synthetic event.
        inboxMessagesJob = observerScope.launch {
            manager.inboxMessagesFlow.drop(1).collect { messages ->
                eventSink.send(
                    EVENT_INBOX_MESSAGES_CHANGED,
                    mapOf("messages" to NaryaInAppBridge.encodeAll(messages)),
                )
            }
        }
        unreadCountJob = observerScope.launch {
            manager.unreadInboxMessageCountFlow.drop(1).collect { count ->
                eventSink.send(EVENT_UNREAD_COUNT_CHANGED, mapOf("count" to count))
            }
        }
        delegateInstalled = true
    }

    /**
     * Clears everything [installInAppObservers] registered so a torn-down
     * engine never emits into a stale sink, and so a shutdown / re-initialize
     * cycle cannot accumulate collectors.
     *
     * The collectors are cancelled explicitly: they live in the plugin's own
     * [observerScope], which `Analytics.shutdown()` knows nothing about, so
     * leaving them running would deliver every inbox event once per completed
     * cycle and would keep the old manager alive. The manager is only looked
     * up when one already exists, so tearing down never starts the feature.
     */
    private fun uninstallInAppObservers(instance: Analytics) {
        if (!delegateInstalled) return
        delegateInstalled = false
        inboxMessagesJob?.cancel()
        inboxMessagesJob = null
        unreadCountJob?.cancel()
        unreadCountJob = null
        pendingShowDecisions.clear()
        askedShowDecisions.clear()
        NaryaInAppBridge.installedManagerOf(instance)?.let { manager ->
            manager.setDeepLinkHandler(null)
            manager.setCustomActionHandler(null)
            manager.setDelegate(null)
        }
    }

    /**
     * Bridges the native in-app delegate to Dart.
     *
     * The native delegate is synchronous and runs on the main thread (the
     * display pump posts to it), so the bridge cannot block waiting for a
     * platform-channel reply without deadlocking. Instead it uses the SDK's own
     * `DEFER` semantics: the first time a message is offered the bridge asks
     * Dart and returns `DEFER`, which leaves the message queued; when Dart
     * answers, the decision is cached and the display queue is pumped again, so
     * the next pass returns the real answer. No message is lost and no
     * behaviour is reimplemented here.
     */
    private inner class BridgeInAppDelegate : InAppDelegate {

        override fun onNew(message: InAppMessage): InAppShowResponse {
            if (!hasDartNewMessageHandler) return InAppShowResponse.SHOW

            val messageId = message.messageId
            pendingShowDecisions.remove(messageId)?.let { return it }
            if (!askedShowDecisions.add(messageId)) {
                // Already asked and still waiting; keep it queued.
                return InAppShowResponse.DEFER
            }

            invokeCallback(
                CALLBACK_ON_NEW_MESSAGE,
                mapOf("message" to NaryaInAppBridge.encode(message)),
            ) { reply, isMissing ->
                askedShowDecisions.remove(messageId)
                if (isMissing) {
                    // No Dart handler: the early return above now answers SHOW
                    // for every message, so caching a decision would leave an
                    // entry nobody ever consumes. Pumping the queue is still
                    // needed to unstick the message that was deferred.
                    hasDartNewMessageHandler = false
                    resumeDisplayPump()
                    return@invokeCallback
                }
                val decision = NaryaInAppBridge.decodeShowResponse(reply)
                if (decision == InAppShowResponse.DEFER) {
                    // DEFER already means "ask again on the next display pass",
                    // so it is neither cached nor pumped. Pumping it would be
                    // wrong twice over: `resumeInAppDisplay()` also clears a
                    // host's `setAutoDisplayPaused(true)`, and with two or more
                    // deferred messages queued each answer would re-ask the
                    // other one forever.
                    return@invokeCallback
                }
                cacheShowDecision(messageId, decision)
                resumeDisplayPump()
            }
            return InAppShowResponse.DEFER
        }

        override fun onJsonOnlyMessage(payload: JsonObject, message: InAppMessage): Boolean {
            // Returning false leaves the message in the SDK's replay buffer, so
            // nothing is lost while Dart is consulted. When Dart reports the
            // payload handled, the bridge marks it handled explicitly.
            val messageId = message.messageId
            invokeCallback(
                CALLBACK_ON_JSON_ONLY_MESSAGE,
                mapOf(
                    "payload" to NaryaCodec.fromJsonObject(payload),
                    "message" to NaryaInAppBridge.encode(message),
                ),
            ) { reply, _ ->
                if (reply == true) {
                    analytics?.let {
                        NaryaInAppBridge.installedManagerOf(it)
                            ?.markJsonOnlyMessageHandled(messageId)
                    }
                }
            }
            return false
        }
    }

    /**
     * Caches one answered decision for the next display pass.
     *
     * The map is bounded: a decision is only consumed when the pump offers the
     * same message again, which a message removed, expired or superseded in the
     * meantime never is, so unconsumed entries would otherwise accumulate for
     * the life of the process. Once the cache grows past what a display backlog
     * can plausibly need, entries are evicted in the map's own iteration order
     * - arbitrary, since this is a [ConcurrentHashMap] - which is acceptable
     * because everything in there is a decision the pump has already declined
     * to ask for again. An evicted message is simply asked once more.
     */
    private fun cacheShowDecision(messageId: String, decision: InAppShowResponse) {
        if (pendingShowDecisions.size >= MAX_PENDING_SHOW_DECISIONS) {
            val stale = pendingShowDecisions.keys.take(
                pendingShowDecisions.size - MAX_PENDING_SHOW_DECISIONS + 1,
            )
            stale.forEach { pendingShowDecisions.remove(it) }
        }
        pendingShowDecisions[messageId] = decision
    }

    /**
     * Asks the display pump to try again, without starting in-app messaging:
     * a decision can only have been answered for a manager that already exists.
     */
    private fun resumeDisplayPump() {
        analytics?.let { NaryaInAppBridge.installedManagerOf(it)?.resumeInAppDisplay() }
    }

    private fun invokeCallback(method: String, arguments: Map<String, Any?>) {
        invokeCallback(method, arguments, onReply = null)
    }

    /**
     * Invokes a Dart callback. [onReply] receives the answer, plus whether the
     * Dart side had no handler attached at all.
     */
    private fun invokeCallback(
        method: String,
        arguments: Map<String, Any?>,
        onReply: ((Any?, Boolean) -> Unit)?,
    ) {
        mainHandler.post {
            if (onReply == null) {
                callbackChannel.invokeMethod(method, arguments)
                return@post
            }
            callbackChannel.invokeMethod(
                method,
                arguments,
                object : Result {
                    override fun success(value: Any?) = onReply(value, false)
                    override fun error(code: String, message: String?, details: Any?) =
                        onReply(null, false)

                    override fun notImplemented() = onReply(null, true)
                },
            )
        }
    }

    // --- argument helpers ----------------------------------------------------

    private inline fun withAnalytics(result: Result, body: (Analytics) -> Unit) {
        val instance = analytics
        if (instance == null) {
            result.error(
                "not_initialized",
                "Narya.initialize() must complete before any other Narya API is called.",
                null,
            )
            return
        }
        body(instance)
    }

    /**
     * Like [withAnalytics], but first tries to rebuild the SDK from the
     * configuration persisted by the last successful `initialize`. Used by the
     * push entry points a `firebase_messaging` background isolate calls in a
     * process where `Narya.initialize` never ran. Fails with `not_initialized`
     * only when no persisted configuration exists.
     */
    private inline fun withRestoredAnalytics(result: Result, body: (Analytics) -> Unit) {
        val instance = NaryaAnalyticsHolder.obtain(applicationContext)
        if (instance == null) {
            result.error(
                "not_initialized",
                "Narya.initialize() has never completed in this app, so there is no " +
                    "configuration to restore. Call Narya.initialize() in the main isolate first.",
                null,
            )
            return
        }
        body(instance)
    }

    /**
     * Runs [body] with the in-app manager, starting the feature on the first
     * such call and pointing its host hooks at this engine.
     *
     * Creating the manager is what starts in-app messaging, so it happens here
     * - when Dart actually uses the feature - and never during `initialize`.
     * A configuration with `inApp.enabled = false` never creates one: the call
     * is refused with `in_app_disabled` unless native host code already
     * started a manager for this instance.
     */
    private inline fun withInApp(result: Result, body: (InAppManager) -> Unit) {
        withAnalytics(result) { instance ->
            val manager = NaryaInAppBridge.managerOf(instance)
            if (manager == null) {
                result.error(
                    "in_app_disabled",
                    "In-app messaging is disabled by this Narya configuration " +
                        "(NaryaInAppConfiguration.enabled is false).",
                    null,
                )
                return@withAnalytics
            }
            installInAppObservers(manager)
            body(manager)
        }
    }

    private inline fun <reified T> argument(call: MethodCall, name: String): T? =
        call.argument<T>(name)

    private inline fun <reified T> requiredArgument(call: MethodCall, name: String): T =
        call.argument<T>(name)
            ?: throw IllegalArgumentException(
                "${call.method} requires the \"$name\" argument.",
            )

    private fun jsonArgument(call: MethodCall, name: String): JsonObject =
        NaryaCodec.toJsonObject(call.argument<Map<*, *>>(name))

    private fun payloadArgument(call: MethodCall): Map<String, String> =
        NaryaCodec.toStringMap(call.argument<Map<*, *>>("payload"))

    private fun deepLinkProperties(call: MethodCall): JsonObject {
        val properties = LinkedHashMap<String, Any?>()
        properties["url"] = call.argument<String>("url")
        call.argument<Map<*, *>>("options")?.forEach { (key, value) ->
            if (key != null) properties[key.toString()] = value
        }
        return NaryaCodec.toJsonObject(properties)
    }

    private companion object {
        const val CHANNEL_METHODS = "com.mithra.flutter.sdk/methods"
        const val CHANNEL_EVENTS = "com.mithra.flutter.sdk/events"
        const val CHANNEL_CALLBACKS = "com.mithra.flutter.sdk/callbacks"

        const val EVENT_PUSH_OPENED = "push_opened"
        const val EVENT_INBOX_MESSAGES_CHANGED = "inbox_messages_changed"
        const val EVENT_UNREAD_COUNT_CHANGED = "unread_count_changed"
        const val EVENT_INAPP_DEEP_LINK = "inapp_deep_link"

        const val CALLBACK_ON_NEW_MESSAGE = "onNewMessage"
        const val CALLBACK_ON_JSON_ONLY_MESSAGE = "onJsonOnlyMessage"
        const val CALLBACK_ON_CUSTOM_ACTION = "onCustomAction"

        /** The name the Android SDK's own deep-link plugin tracks. */
        const val EVENT_DEEP_LINK_OPENED = "Deep Link Opened"

        /** Matches the tag [NaryaAnalyticsHolder] logs under. */
        const val TAG = "MithraFlutterSdk"

        /** Upper bound on the answered-but-unconsumed decision cache. */
        const val MAX_PENDING_SHOW_DECISIONS = 64
    }
}
