import Foundation

/// Whether a notification interaction is a dismissal rather than an open.
///
/// This is the rule that decides whether the native SDK tracks
/// `push_dismissed` or `push_opened`, mirrored here so the bridge can skip a
/// dismissal before reporting a tap to Dart: `onPushOpened` and
/// `takeInitialPushPayload` document opens only.
///
/// `narya-ios` `PushNotificationPayload.isDismissal` is the reference, which
/// `MithraAnalytics` also exports as `Analytics.isPushDismissal(response:)`
/// from 1.5.0. Like `NaryaPushGate.isNaryaPush` it is kept as a plugin-local
/// mirror so the bridge can ask the question with no SDK instance at hand, and
/// can be reduced to a delegation once the pinned SDK floor allows it.
///
/// Android needs no equivalent: a dismiss action button there is a broadcast to
/// `PushDismissReceiver` that never reaches the tap activity, so it never was a
/// Dart open event.
///
/// Pure Foundation for the same reason as `NaryaPushOwnership`: it is compiled
/// a second time as its own module by `ios/Package.swift` so it can be
/// unit-tested on a host toolchain.
enum NaryaPushDismissal {

    /// Raw value of `UNNotificationDefaultActionIdentifier` (a body tap),
    /// spelled out so this file stays free of a UserNotifications import.
    static let defaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"

    /// Raw value of `UNNotificationDismissActionIdentifier` (the system dismiss
    /// gesture: a swipe-away or "Clear").
    static let dismissActionIdentifier = "com.apple.UNNotificationDismissActionIdentifier"

    // Wire keys from gwaihir's push payload contract.
    private static let customDataKey = "CustomData"
    private static let mithraKey = "mithra"
    private static let actionsKey = "actions"
    private static let actionIdKey = "id"
    private static let actionRouteKey = "action"
    private static let routeTypeKey = "type"
    private static let buttonTypeKey = "button_type"
    private static let dismissRouteType = "dismiss"
    private static let textInputButtonType = "text_input"

    /// Whether an interaction is tracked as `push_dismissed`.
    ///
    /// True for the system dismiss gesture, and for a tap on an action button
    /// whose route is `dismiss` - iOS reports those under the button's own
    /// identifier, not the system one, which is why the payload has to be
    /// consulted at all. An inline-reply button (`button_type` of `text_input`)
    /// is an open even with a `dismiss` route, matching Android, where a text
    /// input button keeps the activity intent whatever its route.
    ///
    /// - Parameters:
    ///   - userInfo: the notification payload as delivered by the system.
    ///   - actionIdentifier: `UNNotificationResponse.actionIdentifier`.
    static func isDismissal(_ userInfo: [AnyHashable: Any], actionIdentifier: String) -> Bool {
        if actionIdentifier == dismissActionIdentifier { return true }
        guard actionIdentifier != defaultActionIdentifier,
              let entry = actionEntry(userInfo, actionIdentifier: actionIdentifier),
              let route = dictionary(entry[actionRouteKey]),
              normalized(route[routeTypeKey]) == dismissRouteType else {
            return false
        }
        return normalized(entry[buttonTypeKey]) != textInputButtonType
    }

    /// The `actions` entry the tapped button's identifier names.
    ///
    /// The array is looked up at the payload root first, then inside
    /// `CustomData`, then in the `mithra` overlay - the lookup order the native
    /// SDK applies - and may be a real array or a JSON string, since an APNs
    /// payload is free to carry either.
    private static func actionEntry(
        _ userInfo: [AnyHashable: Any],
        actionIdentifier: String
    ) -> [AnyHashable: Any]? {
        let customData = userInfo[customDataKey] as? [AnyHashable: Any]
        let rawActions = userInfo[actionsKey]
            ?? customData?[actionsKey]
            ?? dictionary(userInfo[mithraKey])?[actionsKey]

        guard let rawActions else { return nil }
        return actionEntries(rawActions).first { $0[actionIdKey] as? String == actionIdentifier }
    }

    private static func actionEntries(_ rawValue: Any) -> [[AnyHashable: Any]] {
        var value = rawValue
        if let jsonString = rawValue as? String {
            guard let data = jsonString.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) else {
                return []
            }
            value = decoded
        }

        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { $0 as? [AnyHashable: Any] }
    }

    /// A payload value as a dictionary, tolerating one level of string
    /// encoding: an FCM data map is string-valued, so nested objects reach iOS
    /// as JSON strings.
    private static func dictionary(_ rawValue: Any?) -> [AnyHashable: Any]? {
        if let dictionary = rawValue as? [AnyHashable: Any] { return dictionary }

        guard let jsonString = rawValue as? String,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any]
    }

    /// A wire enum value as the native SDKs compare it: trimmed and lowercased.
    private static func normalized(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
