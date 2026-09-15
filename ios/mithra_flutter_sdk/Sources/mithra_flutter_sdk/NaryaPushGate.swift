import Foundation
import UserNotifications

/// Push payload predicates the bridge needs natively.
///
/// `isNaryaPush` mirrors, byte for byte, the rule behind the Dart
/// `Narya.push.isNaryaPush` and the native SDKs' `isNaryaPush`
/// (`narya-ios` `PushNotificationPayload.isNaryaPush` is the reference; the
/// parity table is in `docs/api-contract.md`). It lives here rather than being
/// called on `Analytics` because the bridge needs the predicate in contexts
/// where no SDK instance is guaranteed. `MithraAnalytics` 1.5.0 does export
/// `Analytics.isNaryaPush(userInfo:)`, so this file can be reduced to a
/// delegation in a follow-up; the rule is kept in sync with the parity table
/// until then.
///
/// Pure translation: no SDK calls, no state.
enum NaryaPushGate {

    // Wire keys from gwaihir's push payload contract.
    private static let customDataKey = "CustomData"
    private static let mithraKey = "mithra"
    private static let trackingKey = "tracking"
    private static let inAppSyncKey = "inapp_sync"
    private static let mithraMessageIdKey = "mithra_message_id"
    /// Stamped by the Notification Service Extension after it tracked
    /// `push_delivered` itself (`NotificationServiceHelper.nseTrackedUserInfoKey`).
    private static let nseTrackedKey = "narya_nse_tracked"

    /// Whether a remote notification payload was sent by Mithra.
    ///
    /// The root, the `CustomData` dictionary and the `mithra` overlay
    /// (a dictionary, or a JSON string decoding to one) are inspected
    /// independently; the payload is Mithra's when any level has a non-empty
    /// `tracking`, a truthy `inapp_sync` or a non-empty `mithra_message_id`, or
    /// when the top-level `mithra` key holds an object. A bare `message_id` /
    /// `gcm.message_id` is not enough.
    static func isNaryaPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let overlay = mithraOverlay(from: userInfo)
        let customData = userInfo[customDataKey] as? [AnyHashable: Any]
        let levels: [[AnyHashable: Any]] = [userInfo, customData ?? [:], overlay]

        for level in levels {
            if isNonEmptyValue(level[trackingKey]) { return true }
            if isTruthy(level[inAppSyncKey]) { return true }
            if nonEmptyString(level[mithraMessageIdKey]) != nil { return true }
        }

        return hasMithraEnvelope(userInfo)
    }

    /// `isNaryaPush` for the notification behind a response.
    static func isNaryaPush(_ response: UNNotificationResponse) -> Bool {
        isNaryaPush(response.notification.request.content.userInfo)
    }

    /// Whether a response is a dismissal rather than an open - the rule
    /// deciding whether the native SDK tracks `push_dismissed` or
    /// `push_opened`. See `NaryaPushDismissal`, which holds the rule itself so
    /// it can be unit-tested on a host toolchain.
    static func isDismissal(_ response: UNNotificationResponse) -> Bool {
        NaryaPushDismissal.isDismissal(
            response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier
        )
    }

    /// The Mithra message identifier a payload carries, looked up at the same
    /// levels as `isNaryaPush` (root, `CustomData`, `mithra` overlay).
    ///
    /// Used to recognise one delivery that reaches two callbacks, so it is not
    /// counted as two `push_delivered` events.
    static func messageId(_ userInfo: [AnyHashable: Any]) -> String? {
        let overlay = mithraOverlay(from: userInfo)
        let customData = userInfo[customDataKey] as? [AnyHashable: Any]
        let levels: [[AnyHashable: Any]] = [userInfo, customData ?? [:], overlay]

        for level in levels {
            if let identifier = nonEmptyString(level[mithraMessageIdKey]) {
                return identifier
            }
        }

        return nil
    }

    /// Whether a payload is the silent in-app wake push, which the native SDK
    /// deliberately does not count as a `push_delivered`.
    ///
    /// Mirrors `Analytics.isInAppSyncPayload` (not public): the flag is read at
    /// the root and inside `CustomData`.
    static func isInAppSyncWake(_ userInfo: [AnyHashable: Any]) -> Bool {
        if isTruthy(userInfo[inAppSyncKey]) { return true }
        if let customData = userInfo[customDataKey] as? [AnyHashable: Any] {
            return isTruthy(customData[inAppSyncKey])
        }
        return false
    }

    /// Whether a Notification Service Extension already tracked delivery for
    /// this notification, so the app must not track it again.
    static func isTrackedByServiceExtension(_ userInfo: [AnyHashable: Any]) -> Bool {
        if let flag = userInfo[nseTrackedKey] as? Bool { return flag }
        if let number = userInfo[nseTrackedKey] as? NSNumber { return number.boolValue }
        return false
    }

    // MARK: - rule helpers (identical to the native reference)

    private static func hasMithraEnvelope(_ userInfo: [AnyHashable: Any]) -> Bool {
        let rawValue = userInfo[mithraKey]
        if rawValue is [AnyHashable: Any] { return true }

        guard let jsonString = rawValue as? String,
              let data = jsonString.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return decoded is [AnyHashable: Any]
    }

    private static func mithraOverlay(from userInfo: [AnyHashable: Any]) -> [AnyHashable: Any] {
        let rawValue = userInfo[mithraKey]
        if let dictionary = rawValue as? [AnyHashable: Any] { return dictionary }

        if let jsonString = rawValue as? String,
           let data = jsonString.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] {
            return decoded
        }

        return [:]
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["1", "true", "yes"].contains(text.lowercased())
        default: return false
        }
    }

    private static func isNonEmptyValue(_ value: Any?) -> Bool {
        switch value {
        case nil: return false
        case let text as String: return !text.isEmpty
        case let dictionary as [AnyHashable: Any]: return !dictionary.isEmpty
        default: return true
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
