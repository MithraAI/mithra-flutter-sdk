package com.mithra.flutter.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import com.mithra.sdk.kotlin.android.Analytics
import com.mithra.sdk.kotlin.android.pushnotification.DEFAULT_CHANNEL_ID
import com.mithra.sdk.kotlin.android.pushnotification.DEFAULT_CHANNEL_NAME
import com.mithra.sdk.kotlin.android.pushnotification.EXTRA_ACTION_ID
import com.mithra.sdk.kotlin.android.pushnotification.EXTRA_ACTION_ROUTE_TYPE
import com.mithra.sdk.kotlin.android.pushnotification.EXTRA_MESSAGE_ID
import com.mithra.sdk.kotlin.android.pushnotification.EXTRA_PUSH_OPENED
import com.mithra.sdk.kotlin.android.pushnotification.PushDisplayOptions
import com.mithra.sdk.kotlin.android.pushnotification.REMOTE_INPUT_RESULT_KEY
import com.mithra.sdk.kotlin.android.resolvePushDeepLink
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/**
 * Reads notification tap intents and push payloads into the shapes the Dart
 * side expects, and decodes the display options `push.handlePushMessage`
 * hands to the SDK's own renderer.
 *
 * Rendering itself is never reimplemented here: `Analytics.handlePushMessage`
 * draws the notification exactly as it does for a native
 * `FirebaseMessagingService`. The bridge only resolves resource names and class
 * names, which Dart cannot express as Android ids, into a [PushDisplayOptions].
 */
internal object NaryaPushBridge {

    private const val WIRE_KEY_OPEN_ACTION = "open_action"
    private const val WIRE_KEY_DEEP_LINK = "deep_link"
    private const val WIRE_KEY_LEGACY_LINK = "link"
    private const val WIRE_KEY_TYPE = "type"
    private const val WIRE_KEY_DATA = "data"
    private const val WIRE_VALUE_DEEP_LINK = "deep_link"
    private const val WIRE_KEY_IS_SILENT = "is_silent"
    private const val WIRE_KEY_CUSTOM_DATA = "CustomData"
    private const val WIRE_KEY_MITHRA = "mithra"

    /**
     * Key the text typed into a text-input action button is reported under.
     * Mirrors the native SDK's `USER_TEXT_PROPERTY`, which is internal, and the
     * key the iOS SDK uses for the same reply.
     */
    private const val WIRE_KEY_USER_TEXT = "user_text"

    /**
     * Marks a tap intent whose tap this plugin has already reported.
     *
     * The SDK's own extras stay on the activity intent for as long as that
     * intent lives, so they cannot tell a fresh tap from a re-read of the same
     * one. This extra is the plugin's own and is deliberately not one of the
     * SDK's, so host code reading the tap extras sees exactly what it did
     * before.
     */
    private const val EXTRA_TAP_REPORTED = "com.mithra.flutter.sdk.TAP_REPORTED"

    /**
     * Payload keys a tap's message identity is read from, most specific first.
     *
     * `narya_message_id` is the SDK's own tap extra; `mithra_message_id` is the
     * gwaihir payload key it is derived from, and the Firebase ids are the last
     * resort for a payload that carried no Mithra id at all.
     */
    private val MESSAGE_ID_KEYS = listOf(
        EXTRA_MESSAGE_ID,
        "mithra_message_id",
        "google.message_id",
        "gcm.message_id",
    )

    /**
     * How long a tracked tap stays matchable by its echo.
     *
     * The echo follows the `push_opened` event within milliseconds while the
     * app runs; the slowest path by far is a cold start, where the host only
     * claims the tap through `takeInitialPushPayload` once its Dart side is up.
     * Minutes of head room cost nothing - a record can suppress at most the one
     * `trackOpened` call that matches it - and the cap below bounds the memory.
     */
    private const val TAP_ECHO_WINDOW_MS = 5L * 60L * 1000L

    /** Hard cap on remembered taps; a host that never echoes must not grow this. */
    private const val MAX_REPORTED_TAPS = 16

    private data class ReportedTap(val identity: String, val reportedAt: Long)

    /** Taps tracked by the bridge and not yet echoed back. Guarded by its own monitor. */
    private val reportedTaps = ArrayDeque<ReportedTap>()

    /** Time source, overridable from tests so the expiry window is testable. */
    internal var clock: () -> Long = { System.currentTimeMillis() }

    private const val OPTION_SMALL_ICON = "smallIcon"
    private const val OPTION_TAP_ACTIVITY = "tapActivity"
    private const val OPTION_CHANNEL_ID = "channelId"
    private const val OPTION_CHANNEL_NAME = "channelName"

    /**
     * Flag values the SDK reads as enabled, after trimming and lower-casing.
     *
     * Shared by the `is_silent` payload flag and the string tap marker the SDK
     * stamps on its tap intents, which the SDK parses the same way.
     */
    private val TRUTHY_VALUES = setOf("true", "1", "yes")

    /**
     * Decodes the `NaryaPushDisplayOptions.toMap()` wire form.
     *
     * Absent keys take the native defaults: the application icon, the package's
     * launcher activity and the SDK's default channel. A `smallIcon` that names
     * no drawable or mipmap resource, or a `tapActivity` that names no
     * [Activity] class, throws [IllegalArgumentException], which the plugin
     * reports to Dart as `invalid_argument`.
     */
    fun decodeDisplayOptions(context: Context, source: Map<*, *>?): PushDisplayOptions {
        return PushDisplayOptions(
            smallIcon = resolveSmallIcon(context, source?.get(OPTION_SMALL_ICON) as? String),
            tapActivity = resolveTapActivity(context, source?.get(OPTION_TAP_ACTIVITY) as? String),
            channelId = (source?.get(OPTION_CHANNEL_ID) as? String)?.takeIf { it.isNotBlank() }
                ?: DEFAULT_CHANNEL_ID,
            channelName = (source?.get(OPTION_CHANNEL_NAME) as? String)?.takeIf { it.isNotBlank() }
                ?: DEFAULT_CHANNEL_NAME,
        )
    }

    /**
     * Whether `Analytics.handlePushMessage` posts a notification for [data].
     *
     * The SDK's own parser is internal and its `handlePushMessage` returns
     * `Unit`, so the reply to Dart mirrors the rule it applies: a payload whose
     * `is_silent` flag is truthy posts nothing. That covers the gwaihir in-app
     * wake push (`inapp_sync` + silent) as well as any other silent payload.
     * `is_silent` is read with the SDK's flattening precedence: a top-level
     * value wins over the `mithra` overlay, which wins over `CustomData`.
     */
    fun postsNotification(data: Map<String, String>): Boolean {
        val flag = flatten(data)[WIRE_KEY_IS_SILENT]
        return flag?.trim()?.lowercase() !in TRUTHY_VALUES
    }

    /**
     * Whether [intent] carries Narya notification-tap extras.
     *
     * The SDK writes [EXTRA_PUSH_OPENED] as the **string** `"true"`, because a
     * tap intent's extras are the payload's own string-valued FCM data map plus
     * a few string markers (`PushNotificationRenderer.tapIntentExtras`). Reading
     * it as a boolean therefore never matched: `Intent.getBooleanExtra` refuses
     * the stored `String` and falls back to the default, logging
     * `Key narya_push_opened expected Boolean but value was a java.lang.String`,
     * so every Android tap was dropped before reaching Dart.
     *
     * The raw extra is read and both encodings are accepted: the string form is
     * the SDK's current contract, and tolerating a boolean means a future SDK
     * that stamps a real `Boolean` cannot silently break tap reporting a second
     * time. String truthiness matches the SDK's own flag parsing
     * ([TRUTHY_VALUES]): trimmed, lower-cased, `true` / `1` / `yes`.
     */
    fun isPushOpen(intent: Intent?): Boolean {
        @Suppress("DEPRECATION")
        val marker = intent?.extras?.get(EXTRA_PUSH_OPENED)
        return isPushOpenMarker(marker)
    }

    /** Reads one [EXTRA_PUSH_OPENED] extra value as the tap marker it encodes. */
    private fun isPushOpenMarker(value: Any?): Boolean = when (value) {
        is Boolean -> value
        is String -> value.trim().lowercase() in TRUTHY_VALUES
        else -> false
    }

    /** Whether this plugin has already reported the tap [intent] carries. */
    fun isTapReported(intent: Intent): Boolean =
        intent.getBooleanExtra(EXTRA_TAP_REPORTED, false)

    /**
     * Marks the tap [intent] carries as reported, so an activity recreated
     * while the process lives does not deliver the same tap - and the same
     * `push_opened` event - a second time.
     */
    fun markTapReported(intent: Intent) {
        intent.putExtra(EXTRA_TAP_REPORTED, true)
    }

    /**
     * Records that the bridge has tracked `push_opened` for the tap [intent]
     * carries, so the host echoing that same tap back through
     * `push.trackOpened` does not track it a second time.
     *
     * The intent marker above cannot cover this: the echo arrives over the
     * method channel as a plain map, with no intent at all. The tap is
     * therefore remembered by its own identity - see [tapIdentityOf] - rather
     * than by the object that carried it.
     */
    fun rememberReportedTap(intent: Intent) {
        val identity = tapIdentityOf(tapPayloadKeysOf(intent)) ?: return
        synchronized(reportedTaps) {
            dropExpiredTaps(clock())
            reportedTaps.addLast(ReportedTap(identity, clock()))
            while (reportedTaps.size > MAX_REPORTED_TAPS) {
                reportedTaps.removeFirst()
            }
        }
    }

    /**
     * Whether [payload] is the echo of a tap this bridge has already tracked,
     * in which case the record is consumed and the caller must not track it
     * again.
     *
     * Consuming, rather than merely matching, is what keeps a genuine second
     * tap on the same notification reportable: every tap the bridge tracks adds
     * its own record, and every echo removes exactly one. A host that never
     * echoes leaves records behind, which expire after [TAP_ECHO_WINDOW_MS] and
     * are capped at [MAX_REPORTED_TAPS], and a host tracking a notification the
     * bridge never reported - one it rendered itself - carries no tap extras at
     * all and so never matches.
     */
    fun consumeReportedTapEcho(payload: Map<String, String>): Boolean {
        val identity = tapIdentityOf(payload) ?: return false
        synchronized(reportedTaps) {
            val now = clock()
            dropExpiredTaps(now)
            val index = reportedTaps.indexOfFirst { it.identity == identity }
            if (index < 0) return false
            reportedTaps.removeAt(index)
            return true
        }
    }

    /** Forgets every remembered tap. Test seam; also used when the SDK is shut down. */
    fun clearReportedTaps() {
        synchronized(reportedTaps) { reportedTaps.clear() }
    }

    /**
     * The identity of the tap a tap-intent payload describes, or `null` when
     * the payload does not describe one.
     *
     * Only a payload carrying the SDK's own tap marker qualifies, which is what
     * separates an echoed tap payload from the raw FCM data map a host hands to
     * `trackOpened` for a notification it rendered itself: the marker rides tap
     * intents only. The identity is the message the notification belongs to
     * plus the action button that was tapped, so a body tap and a button tap on
     * the same notification stay distinct taps. `narya_message_id` is the SDK's
     * own extra; the FCM message id is the fallback for a payload that carried
     * no Mithra message id.
     */
    private fun tapIdentityOf(payload: Map<String, String>): String? {
        if (!isPushOpenMarker(payload[EXTRA_PUSH_OPENED])) return null
        val messageId = MESSAGE_ID_KEYS
            .firstNotNullOfOrNull { key -> payload[key]?.trim()?.takeIf { it.isNotEmpty() } }
            ?: return null
        return messageId + "\u0000" + (payload[EXTRA_ACTION_ID]?.trim().orEmpty())
    }

    /**
     * The few extras a tap identity is read from, as strings.
     *
     * Read one key at a time rather than by walking the whole bundle: the tap
     * marker is the only value that may be a non-string, and
     * [Intent.getStringExtra] answers `null` for it without the log line a
     * bundle-wide cast would produce.
     */
    private fun tapPayloadKeysOf(intent: Intent): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        @Suppress("DEPRECATION")
        intent.extras?.get(EXTRA_PUSH_OPENED)?.let { result[EXTRA_PUSH_OPENED] = it.toString() }
        for (key in MESSAGE_ID_KEYS + EXTRA_ACTION_ID) {
            intent.getStringExtra(key)?.let { result[key] = it }
        }
        return result
    }

    private fun dropExpiredTaps(now: Long) {
        while (reportedTaps.isNotEmpty()) {
            if (now - reportedTaps.first().reportedAt <= TAP_ECHO_WINDOW_MS) return
            reportedTaps.removeFirst()
        }
    }

    /**
     * Builds the `push_opened` event payload for a tap intent.
     *
     * `payload` carries every string extra the notification tap intent holds,
     * which is what the SDK itself preserved from the original FCM data map,
     * plus `user_text` when the tap came from a text-input action button. The
     * action's route type is one of those extras, so a host that needs the
     * `open_app` / `deep_link` discriminator still finds it there.
     */
    fun encodeTap(analytics: Analytics, intent: Intent): Map<String, Any?> {
        val actionId = intent.getStringExtra(EXTRA_ACTION_ID)
        val isActionButtonTap = actionId != null ||
            intent.getStringExtra(EXTRA_ACTION_ROUTE_TYPE) != null
        return mapOf(
            "payload" to pushDataOf(intent),
            "deepLink" to analytics.resolvePushDeepLink(intent)?.toString(),
            "messageId" to intent.getStringExtra(EXTRA_MESSAGE_ID),
            // The button's own id, which is what iOS reports as the action
            // identifier. The route type would not do: two buttons of one
            // notification routinely share it, so Dart could not tell them
            // apart.
            "actionIdentifier" to actionId,
            "isBodyTap" to !isActionButtonTap,
            "isActionButtonTap" to isActionButtonTap,
        )
    }

    /**
     * Resolves the destination a raw push payload asks the host to open.
     *
     * The SDK's own payload parser is internal, so this reads the documented
     * wire keys directly, through the same [flatten] overlay the SDK applies:
     * an `open_action` object of `{type, data}` (tolerating one level of string
     * encoding, because an FCM data map is string-valued), falling back to a
     * bare `deep_link` or the legacy `link` key when no `open_action` is
     * present at all. A present but unparseable `open_action` deliberately does
     * not fall through to that compatibility path - the sender did state an
     * intent - which is what `resolveOpenAction` does natively.
     */
    fun deepLinkFrom(payload: Map<*, *>?): String? {
        val data = flatten(NaryaCodec.toStringMap(payload))
        if (data.containsKey(WIRE_KEY_OPEN_ACTION)) {
            return parseOpenAction(data[WIRE_KEY_OPEN_ACTION])
        }
        return (data[WIRE_KEY_DEEP_LINK] ?: data[WIRE_KEY_LEGACY_LINK])
            ?.takeIf { it.isNotBlank() }
    }

    /**
     * Flattens the `CustomData` and `mithra` overlays into one lookup map,
     * mirroring the SDK's `flattenPushData`.
     *
     * gwaihir nests the Mithra keys inside `CustomData` for some providers and
     * inlines them for others, so a bridge that only read the top level would
     * silently see no `open_action` at all on the nested shape. Precedence is
     * the SDK's: a root key beats `mithra`, which beats `CustomData`.
     */
    private fun flatten(data: Map<String, String>): Map<String, String> {
        val merged = LinkedHashMap<String, String>()
        overlayInto(data[WIRE_KEY_CUSTOM_DATA], merged)
        overlayInto(data[WIRE_KEY_MITHRA], merged)
        merged.putAll(data)
        return merged
    }

    /** Copies a JSON-object string overlay's entries into [into]; malformed JSON is ignored. */
    private fun overlayInto(raw: String?, into: MutableMap<String, String>) {
        val trimmed = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return
        val json = try {
            JSONObject(trimmed)
        } catch (_: JSONException) {
            return
        }
        for (key in json.keys()) {
            if (json.isNull(key)) continue
            into[key] = json.get(key).toString()
        }
    }

    /**
     * Parses the payload of a tap intent into a Dart-encodable map.
     *
     * Only string extras are considered, matching the shape of an FCM data
     * payload. A `RemoteInput` reply travels in the intent's `ClipData` rather
     * than in its extras, so the text a user typed into a text-input action
     * button is read separately and added under [WIRE_KEY_USER_TEXT], exactly
     * as the native SDK's `Intent.extractPushNotificationData` does.
     */
    private fun pushDataOf(intent: Intent): Map<String, Any?> {
        val result = LinkedHashMap<String, Any?>(stringExtrasOf(intent))
        remoteInputUserText(intent)?.let { result[WIRE_KEY_USER_TEXT] = it }
        return result
    }

    private fun stringExtrasOf(intent: Intent): Map<String, Any?> {
        val extras = intent.extras ?: return emptyMap()
        val result = LinkedHashMap<String, Any?>()
        for (key in extras.keySet()) {
            val value = extras.getString(key)
            if (value != null) {
                result[key] = value
            }
        }
        return result
    }

    private fun remoteInputUserText(intent: Intent): String? =
        RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(REMOTE_INPUT_RESULT_KEY)
            ?.toString()
            ?.takeIf { it.isNotBlank() }

    private fun resolveSmallIcon(context: Context, name: String?): Int {
        val resourceName = name?.trim()?.takeIf { it.isNotEmpty() }
        if (resourceName == null) {
            // The manifest icon renders as a silhouette but is always present,
            // which is the sensible default for a host that ships no dedicated
            // status-bar asset.
            return context.applicationInfo.icon.takeIf { it != 0 }
                ?: android.R.drawable.sym_def_app_icon
        }
        val resources = context.resources
        val packageName = context.packageName
        @Suppress("DiscouragedApi")
        val id = resources.getIdentifier(resourceName, "drawable", packageName)
            .takeIf { it != 0 }
            ?: resources.getIdentifier(resourceName, "mipmap", packageName)
        if (id == 0) {
            throw IllegalArgumentException(
                "NaryaPushDisplayOptions.smallIcon \"$resourceName\" is not a drawable or " +
                    "mipmap resource of $packageName.",
            )
        }
        return id
    }

    private fun resolveTapActivity(context: Context, className: String?): Class<out Activity> {
        val name = className?.trim()?.takeIf { it.isNotEmpty() }
            ?: context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.component
                ?.className
            ?: throw IllegalArgumentException(
                "NaryaPushDisplayOptions.tapActivity was not set and ${context.packageName} " +
                    "declares no launcher activity.",
            )
        return try {
            Class.forName(name).asSubclass(Activity::class.java)
        } catch (error: ClassNotFoundException) {
            throw IllegalArgumentException(
                "NaryaPushDisplayOptions.tapActivity \"$name\" is not a class in this app.",
                error,
            )
        } catch (error: ClassCastException) {
            throw IllegalArgumentException(
                "NaryaPushDisplayOptions.tapActivity \"$name\" is not an android.app.Activity.",
                error,
            )
        }
    }

    /**
     * Reads the deep link out of one `open_action` value, or `null` when the
     * value is not a `{type, data}` object or carries a type this bridge does
     * not know.
     *
     * The type is matched the way `OpenActionType.from` matches it - trimmed
     * and lower-cased - so a sender emitting `DEEP_LINK` is not silently
     * dropped.
     */
    private fun parseOpenAction(raw: String?): String? {
        val trimmed = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val json = openActionObject(trimmed) ?: return null
        val type = json.optString(WIRE_KEY_TYPE).trim().lowercase()
        if (type != WIRE_VALUE_DEEP_LINK) {
            return null
        }
        return json.optString(WIRE_KEY_DATA).takeIf { it.isNotBlank() }
    }

    /**
     * Unwraps an `open_action` value, tolerating one level of string encoding,
     * as the SDK's `openActionObject` does.
     *
     * Both shapes reach here in the field: an inlined JSON object, and a JSON
     * string holding that object - which is what a sender nesting `open_action`
     * inside the string-valued `CustomData` map, or double-encoding it,
     * produces.
     */
    private fun openActionObject(raw: String): JSONObject? {
        val value = jsonValueOf(raw) ?: return null
        (value as? JSONObject)?.let { return it }
        val nested = (value as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return jsonValueOf(nested) as? JSONObject
    }

    private fun jsonValueOf(raw: String): Any? = try {
        JSONTokener(raw).nextValue()
    } catch (_: JSONException) {
        null
    }
}
