import Foundation
import UIKit
import UserNotifications

/// App icon badge control for the bridge.
///
/// gwaihir stamps `badge = 1` on every alert push, so iOS lights the app icon
/// badge on the first notification and nothing ever turns it off: APNs changes
/// the badge only when a payload sets it, and no payload sets it back to zero.
/// Clearing it is the host's job, which is what `Narya.push.setBadgeCount` /
/// `clearBadge` expose.
///
/// The implementation lives here rather than being called on `Analytics`
/// because badge control must work without a live SDK instance. It mirrors,
/// call for call, the native `Analytics.setBadgeCount(_:completion:)` /
/// `clearBadge(completion:)` shipped in `MithraAnalytics` 1.5.0: the modern
/// `UNUserNotificationCenter.setBadgeCount(_:withCompletionHandler:)` on
/// iOS 16+, and the deprecated `UIApplication.applicationIconBadgeNumber` on
/// iOS 15. Delegating to the native methods is a follow-up - the same
/// arrangement `NaryaPushGate` uses for `isNaryaPush`.
///
/// No SDK calls and no state: this is pure platform plumbing.
enum NaryaBadge {

    /// Sets the app icon badge to [count], clamping a negative value to zero.
    ///
    /// The completion handler may run on an arbitrary queue on iOS 16+, so the
    /// caller is responsible for hopping back to the platform thread before
    /// replying to Dart. `0` clears the badge.
    static func setCount(_ count: Int, completion: @escaping (Error?) -> Void) {
        // The Dart layer clamps as well; doing it here too keeps the native
        // behaviour identical no matter which side calls in.
        let clamped = max(0, count)

        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(
                clamped,
                withCompletionHandler: completion
            )
        } else {
            // Deprecated in iOS 17 but the only option on iOS 15, and it must
            // be touched on the main thread: it is UIKit state.
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = clamped
                completion(nil)
            }
        }
    }
}
