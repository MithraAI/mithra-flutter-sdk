package com.mithra.flutter.sdk

import android.content.Intent
import com.mithra.sdk.kotlin.android.pushnotification.EXTRA_ACTION_ID
import com.mithra.sdk.kotlin.android.pushnotification.EXTRA_MESSAGE_ID
import com.mithra.sdk.kotlin.android.pushnotification.EXTRA_PUSH_OPENED
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Covers the tap-intent readers of [NaryaPushBridge].
 *
 * These need a real `Intent` and `Bundle` - the mockable `android.jar` returns
 * defaults for both, which would make every assertion here pass vacuously - so
 * the class runs under Robolectric while the pure payload readers stay plain
 * JVM tests in [NaryaPushBridgeTest].
 */
@RunWith(RobolectricTestRunner::class)
class NaryaPushBridgeIntentTest {

    @Before
    @After
    fun resetBridgeState() {
        NaryaPushBridge.clearReportedTaps()
        NaryaPushBridge.clock = { System.currentTimeMillis() }
    }

    /**
     * The regression this class exists for: the SDK stamps the tap marker as
     * the string `"true"` ([EXTRA_PUSH_OPENED] in
     * `PushNotificationRenderer.tapIntentExtras`), and reading it as a boolean
     * dropped every Android tap.
     */
    @Test
    fun `the SDK's string tap marker is recognised as a tap`() {
        val intent = Intent().putExtra(EXTRA_PUSH_OPENED, "true")
        assertTrue(NaryaPushBridge.isPushOpen(intent))
    }

    @Test
    fun `a string tap marker is matched trimmed and case-insensitively`() {
        assertTrue(NaryaPushBridge.isPushOpen(Intent().putExtra(EXTRA_PUSH_OPENED, " TRUE ")))
        assertTrue(NaryaPushBridge.isPushOpen(Intent().putExtra(EXTRA_PUSH_OPENED, "1")))
        assertTrue(NaryaPushBridge.isPushOpen(Intent().putExtra(EXTRA_PUSH_OPENED, "yes")))
    }

    /** A future SDK stamping a real boolean must not break tap reporting again. */
    @Test
    fun `a boolean tap marker is recognised as a tap`() {
        val intent = Intent().putExtra(EXTRA_PUSH_OPENED, true)
        assertTrue(NaryaPushBridge.isPushOpen(intent))
    }

    @Test
    fun `an intent without the marker is not a tap`() {
        assertFalse(NaryaPushBridge.isPushOpen(Intent()))
        assertFalse(NaryaPushBridge.isPushOpen(null))
        assertFalse(NaryaPushBridge.isPushOpen(Intent().putExtra("other", "true")))
    }

    @Test
    fun `a falsy marker is not a tap`() {
        assertFalse(NaryaPushBridge.isPushOpen(Intent().putExtra(EXTRA_PUSH_OPENED, "false")))
        assertFalse(NaryaPushBridge.isPushOpen(Intent().putExtra(EXTRA_PUSH_OPENED, "")))
        assertFalse(NaryaPushBridge.isPushOpen(Intent().putExtra(EXTRA_PUSH_OPENED, false)))
    }

    /**
     * The plugin's own de-duplication extra is written and read as a boolean by
     * this file alone, so it round-trips - unlike the SDK's string markers.
     */
    @Test
    fun `a tap is reported once`() {
        val intent = Intent().putExtra(EXTRA_PUSH_OPENED, "true")
        assertFalse(NaryaPushBridge.isTapReported(intent))
        NaryaPushBridge.markTapReported(intent)
        assertTrue(NaryaPushBridge.isTapReported(intent))
    }

    /**
     * The double-report this class' second half exists for: the bridge tracks
     * the tap from the intent and hands the very same payload to Dart, so a
     * host that tracks the open it was just told about - which every
     * `onPushOpened` / `takeInitialPushPayload` listener naturally does -
     * produced a second `push_opened` for one tap.
     */
    @Test
    fun `the echo of a reported tap is not tracked again`() {
        val intent = tapIntent(messageId = "m-1")
        NaryaPushBridge.rememberReportedTap(intent)
        assertTrue(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
    }

    /** One report answers exactly one echo; a host echoing twice is not silenced twice. */
    @Test
    fun `a reported tap is consumed by its first echo only`() {
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        assertTrue(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
        assertFalse(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
    }

    /** A second genuine tap on the same notification is its own report and its own echo. */
    @Test
    fun `each reported tap answers one echo`() {
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        assertTrue(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
        assertTrue(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
        assertFalse(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
    }

    @Test
    fun `a tap on another notification is tracked`() {
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        assertFalse(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-2")))
    }

    /** A body tap and an action-button tap on one notification are different taps. */
    @Test
    fun `an action button tap is a tap of its own`() {
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        assertFalse(
            NaryaPushBridge.consumeReportedTapEcho(
                tapPayload(messageId = "m-1", actionId = "open_feedback"),
            ),
        )
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1", actionId = "open_feedback"))
        assertTrue(
            NaryaPushBridge.consumeReportedTapEcho(
                tapPayload(messageId = "m-1", actionId = "open_feedback"),
            ),
        )
    }

    /**
     * A host tracking a notification it rendered itself hands `trackOpened` the
     * raw FCM data map, which carries none of the SDK's tap extras. It must
     * never be mistaken for an echo, whatever the bridge happens to remember.
     */
    @Test
    fun `a raw push payload is never mistaken for an echo`() {
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        assertFalse(
            NaryaPushBridge.consumeReportedTapEcho(
                mapOf(EXTRA_MESSAGE_ID to "m-1", "title" to "Hello"),
            ),
        )
    }

    /** A tap with no message id at all cannot be matched, and must not match anything else. */
    @Test
    fun `an unidentifiable tap is never matched`() {
        NaryaPushBridge.rememberReportedTap(Intent().putExtra(EXTRA_PUSH_OPENED, "true"))
        assertFalse(
            NaryaPushBridge.consumeReportedTapEcho(mapOf(EXTRA_PUSH_OPENED to "true")),
        )
    }

    /** The FCM message id identifies a payload that carried no Mithra id. */
    @Test
    fun `the fcm message id identifies a tap`() {
        val intent = Intent()
            .putExtra(EXTRA_PUSH_OPENED, "true")
            .putExtra("google.message_id", "fcm-1")
        NaryaPushBridge.rememberReportedTap(intent)
        assertTrue(
            NaryaPushBridge.consumeReportedTapEcho(
                mapOf(EXTRA_PUSH_OPENED to "true", "google.message_id" to "fcm-1"),
            ),
        )
    }

    /** A record left behind by a host that never echoes must not silence a later track. */
    @Test
    fun `a reported tap stops matching once its window passes`() {
        var now = 1_000L
        NaryaPushBridge.clock = { now }
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        now += 6L * 60L * 1000L
        assertFalse(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
    }

    /** Shutting the SDK down must not leave a record that swallows the next tap. */
    @Test
    fun `shutdown clears the reported taps`() {
        NaryaPushBridge.rememberReportedTap(tapIntent(messageId = "m-1"))
        NaryaPushBridge.clearReportedTaps()
        assertFalse(NaryaPushBridge.consumeReportedTapEcho(tapPayload(messageId = "m-1")))
    }

    private fun tapIntent(messageId: String, actionId: String? = null): Intent {
        val intent = Intent()
            .putExtra(EXTRA_PUSH_OPENED, "true")
            .putExtra(EXTRA_MESSAGE_ID, messageId)
        actionId?.let { intent.putExtra(EXTRA_ACTION_ID, it) }
        return intent
    }

    /** The payload shape Dart receives on `onPushOpened`: the tap intent's string extras. */
    private fun tapPayload(messageId: String, actionId: String? = null): Map<String, String> {
        val payload = linkedMapOf(
            EXTRA_PUSH_OPENED to "true",
            EXTRA_MESSAGE_ID to messageId,
            "title" to "Hello",
        )
        actionId?.let { payload[EXTRA_ACTION_ID] = it }
        return payload
    }
}
