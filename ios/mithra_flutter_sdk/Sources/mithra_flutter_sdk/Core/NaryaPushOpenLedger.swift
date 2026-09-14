import Foundation

/// Remembers the notification taps the bridge has already tracked
/// `push_opened` for, so the host echoing the very same tap back through
/// `push.trackOpened` does not report it a second time.
///
/// The bridge tracks the tap natively from
/// `userNotificationCenter(_:didReceive:)` and then hands the notification's
/// payload to Dart, where every host that listens on `onPushOpened` or claims
/// `takeInitialPushPayload` naturally tracks the open it was just told about -
/// the plugin's own demo and the README example both did. One tap therefore
/// produced two `push_opened` events milliseconds apart.
///
/// Matching on the payload's own content cannot solve it here. The echo is the
/// notification's `userInfo`, which is exactly what a host hands to
/// `trackOpened` for a notification it rendered and routed itself, and it
/// carries no trace of *which* button was tapped: the action identifier lives
/// on `UNNotificationResponse`, not in the payload, so the two events are not
/// even equal - the echo is a degraded copy with the action id missing. An
/// identity of "message id plus action id", which is what the Android bridge
/// can use, would therefore never match on iOS.
///
/// So the tap is not identified by what it contains but by a token this ledger
/// mints for it: `stamp(_:)` records a tap and returns the payload with the
/// token added, and `consumeEcho(_:)` recognises a payload carrying a token it
/// minted. That makes the answer exact - a payload with no token was never
/// handed out by the bridge and is always tracked, and two taps on the same
/// message, with the same button or different ones, get distinct tokens and
/// stay two reportable taps.
///
/// Consuming, rather than merely matching, is what keeps a genuine second tap
/// reportable: every tap the bridge reports mints one token and every echo
/// spends exactly one. A host that never echoes leaves tokens behind, which
/// expire after `echoWindow` and are capped at `maximumRecords`, so they can
/// never accumulate or silence a later call.
///
/// Pure Foundation, and therefore unit-tested by `ios/Package.swift`; see that
/// manifest.
final class NaryaPushOpenLedger {

    /// The payload key carrying the token.
    ///
    /// Namespaced to the plugin, and inert everywhere else: the SDK's push APIs
    /// read named keys out of a payload and ignore the rest, so a stamped
    /// payload still resolves its deep link and still reads as a Mithra push.
    static let tapTokenKey = "narya_flutter_tap_token"

    /// How long a minted token stays matchable by its echo.
    ///
    /// The echo follows within milliseconds while the app runs; the slowest
    /// path by far is a cold start, where the host only claims the tap through
    /// `takeInitialPushPayload` once its Dart side is up. Minutes of head room
    /// cost nothing - a token can suppress at most the one `trackOpened` call
    /// that carries it - and the cap below bounds the memory.
    static let echoWindow: TimeInterval = 5 * 60

    /// Hard cap on remembered taps; a host that never echoes must not grow this.
    static let maximumRecords = 16

    private struct Record {
        let token: String
        let mintedAt: TimeInterval
    }

    private let lock = NSLock()
    private var records: [Record] = []

    private let clock: () -> TimeInterval
    private let tokenFactory: () -> String

    /// - Parameters:
    ///   - clock: monotonic-enough time source; overridable so the expiry
    ///     window is testable.
    ///   - tokenFactory: mints one token per tap; overridable so tests can
    ///     assert on known values.
    init(
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        tokenFactory: @escaping () -> String = { UUID().uuidString }
    ) {
        self.clock = clock
        self.tokenFactory = tokenFactory
    }

    /// Records that the bridge reported `push_opened` for the tap [payload]
    /// describes, and returns the payload to hand to Dart - the same map plus
    /// the token that identifies this tap.
    func stamp(_ payload: [String: Any]) -> [String: Any] {
        let token = tokenFactory()
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        dropExpired(now: now)
        records.append(Record(token: token, mintedAt: now))
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
        }
        var stamped = payload
        stamped[Self.tapTokenKey] = token
        return stamped
    }

    /// Whether [userInfo] is the echo of a tap this ledger stamped, in which
    /// case its token is spent and the caller must not track the open again.
    ///
    /// A payload with no token, or with one that was already spent or has
    /// expired, is not an echo: the host means it, and the caller tracks it.
    func consumeEcho(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let token = userInfo[Self.tapTokenKey] as? String, !token.isEmpty else {
            return false
        }
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        dropExpired(now: now)
        guard let index = records.firstIndex(where: { $0.token == token }) else {
            return false
        }
        records.remove(at: index)
        return true
    }

    /// The payload without the bridge's own token, which is an implementation
    /// detail of this ledger and has no business reaching the SDK.
    static func withoutTapToken(_ userInfo: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard userInfo[tapTokenKey] != nil else { return userInfo }
        var result = userInfo
        result.removeValue(forKey: tapTokenKey)
        return result
    }

    /// Forgets every remembered tap. Used when the SDK is shut down.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
    }

    /// How many taps are currently remembered. Test seam.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    private func dropExpired(now: TimeInterval) {
        records.removeAll { now - $0.mintedAt > Self.echoWindow }
    }
}
