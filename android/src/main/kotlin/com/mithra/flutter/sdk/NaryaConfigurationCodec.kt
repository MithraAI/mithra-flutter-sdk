package com.mithra.flutter.sdk

import android.app.Application
import com.mithra.sdk.kotlin.android.Configuration
import com.mithra.sdk.kotlin.android.SessionConfiguration
import com.mithra.sdk.kotlin.core.InAppColorScheme
import com.mithra.sdk.kotlin.core.InAppConfiguration
import com.mithra.sdk.kotlin.core.NaryaEnvironment
import com.mithra.sdk.kotlin.core.internals.logger.Logger

/** Thrown when the Dart configuration map cannot produce a native configuration. */
internal class NaryaConfigurationException(
    val code: String,
    override val message: String,
) : RuntimeException(message)

/**
 * Decodes the `NaryaConfiguration.toMap()` wire form into the native
 * [Configuration].
 *
 * Defaults intentionally mirror the Dart defaults so an absent key and an
 * explicit default behave identically.
 */
internal object NaryaConfigurationCodec {

    fun decode(application: Application, source: Map<*, *>?): Configuration {
        if (source == null) {
            throw NaryaConfigurationException(
                "invalid_argument",
                "initialize was called without a configuration.",
            )
        }
        val writeKey = (source["writeKey"] as? String)?.takeIf { it.isNotBlank() }
            ?: throw NaryaConfigurationException(
                "missing_write_key",
                "NaryaConfiguration.writeKey is required and must not be blank.",
            )

        val environment = when (source["environment"] as? String) {
            "staging" -> NaryaEnvironment.STAGING
            else -> NaryaEnvironment.PRODUCTION
        }
        val dataPlaneUrl = (source["dataPlaneUrl"] as? String)?.takeIf { it.isNotBlank() }

        return Configuration(
            application = application,
            writeKey = writeKey,
            environment = environment,
            dataPlaneUrl = dataPlaneUrl ?: environment.dataPlaneUrl,
            trackApplicationLifecycleEvents =
                source["trackApplicationLifecycleEvents"] as? Boolean ?: true,
            trackDeepLinks = source["trackDeepLinks"] as? Boolean ?: true,
            // Flutter screen tracking is NaryaRouteObserver; native activity
            // tracking would emit one event for the single FlutterActivity.
            trackActivities = false,
            collectDeviceId = source["collectDeviceId"] as? Boolean ?: true,
            gzipEnabled = source["gzipEnabled"] as? Boolean ?: false,
            sessionConfiguration = decodeSession(source["session"] as? Map<*, *>),
            logLevel = decodeLogLevel(source["logLevel"] as? String),
            inApp = decodeInApp(source["inApp"] as? Map<*, *>),
            startsOptedOut = source["startsOptedOut"] as? Boolean ?: false,
        )
    }

    private fun decodeSession(source: Map<*, *>?): SessionConfiguration {
        val defaults = SessionConfiguration()
        if (source == null) return defaults
        return SessionConfiguration(
            automaticSessionTracking = source["automaticSessionTracking"] as? Boolean
                ?: defaults.automaticSessionTracking,
            sessionTimeoutInMillis = (source["sessionTimeoutInMillis"] as? Number)?.toLong()
                ?: defaults.sessionTimeoutInMillis,
            updateSessionOnBackgroundEvents =
                source["updateSessionOnBackgroundEvents"] as? Boolean
                    ?: defaults.updateSessionOnBackgroundEvents,
        )
    }

    private fun decodeInApp(source: Map<*, *>?): InAppConfiguration {
        val defaults = InAppConfiguration()
        if (source == null) return defaults
        return InAppConfiguration(
            enabled = source["enabled"] as? Boolean ?: defaults.enabled,
            displayInterval = (source["displayIntervalInSeconds"] as? Number)?.toDouble()
                ?: defaults.displayInterval,
            autoDisplayPaused = source["autoDisplayPaused"] as? Boolean
                ?: defaults.autoDisplayPaused,
            useInMemoryStorage = source["useInMemoryStorage"] as? Boolean
                ?: defaults.useInMemoryStorage,
            colorScheme = when (source["colorScheme"] as? String) {
                "light" -> InAppColorScheme.LIGHT
                "dark" -> InAppColorScheme.DARK
                "system" -> InAppColorScheme.SYSTEM
                else -> defaults.colorScheme
            },
            webViewBaseUrl = (source["webViewBaseUrl"] as? String)?.takeIf { it.isNotBlank() },
        )
    }

    private fun decodeLogLevel(source: String?): Logger.LogLevel = when (source) {
        "verbose" -> Logger.LogLevel.VERBOSE
        "debug" -> Logger.LogLevel.DEBUG
        "info" -> Logger.LogLevel.INFO
        "warn" -> Logger.LogLevel.WARN
        "error" -> Logger.LogLevel.ERROR
        else -> Logger.LogLevel.NONE
    }

    /**
     * A comparison key used to decide whether a repeated `initialize` call is
     * an idempotent no-op or a genuine reconfiguration attempt.
     *
     * The key is canonical - keys sorted at every nesting level - so a map that
     * arrived over the platform channel and the same map restored from the
     * persisted JSON by [NaryaAnalyticsHolder] compare equal even though their
     * concrete map types iterate in a different order.
     */
    fun identityOf(source: Map<*, *>?): String = canonical(source)

    private fun canonical(value: Any?): String = when (value) {
        null -> "null"
        is Map<*, *> -> value.entries
            .sortedBy { it.key?.toString() ?: "" }
            .joinToString(separator = "|", prefix = "{", postfix = "}") {
                "${it.key}=${canonical(it.value)}"
            }
        is Iterable<*> -> value.joinToString(separator = ",", prefix = "[", postfix = "]") {
            canonical(it)
        }
        is Number -> canonicalNumber(value)
        else -> value.toString()
    }

    /** `30` and `30.0` denote the same setting whichever numeric type decoded them. */
    private fun canonicalNumber(value: Number): String {
        val asDouble = value.toDouble()
        return if (asDouble == Math.floor(asDouble) && !asDouble.isInfinite()) {
            value.toLong().toString()
        } else {
            asDouble.toString()
        }
    }
}
