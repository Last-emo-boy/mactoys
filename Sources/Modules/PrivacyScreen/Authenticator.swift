import AppKit
import Foundation
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import MacToysCore
import OpenDirectory

/// Checks the user's macOS password with Open Directory (the same check `dscl . -authonly` does).
/// The password is only passed through: it is never stored, logged or sent anywhere.
enum PasswordCheck {
    static func verify(_ password: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { verifySync(password) }.value
    }

    nonisolated static func verifySync(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        let user = NSUserName()
        // The local node first; network and mobile accounts are found through the search node.
        for nodeType in [kODNodeTypeLocalNodes, kODNodeTypeAuthentication] {
            let record: ODRecord
            do {
                let node = try ODNode(session: ODSession.default(), type: ODNodeType(nodeType))
                record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            } catch {
                continue
            }
            do {
                try record.verifyPassword(password)
                return true
            } catch {
                // The account exists here and the password is wrong: don't count a second attempt
                // against another node.
                return false
            }
        }
        Log.for("privacyscreen").error("No directory record found for the current user")
        return false
    }
}

/// Touch ID (or an Apple Watch) through LocalAuthentication's embedded view, so no system sheet
/// opens — a sheet would sit hidden behind the shield.
@MainActor
final class BiometricPrompt {
    enum Outcome: Equatable {
        case success
        /// Not recognized (the sensor's own retries are used up).
        case failed
        /// Too many failures: macOS requires the password before Touch ID works again.
        case lockedOut
        /// Cancelled by us or the system (e.g. the lock ended).
        case cancelled
        case unavailable
    }

    /// Hosts the current `LAAuthenticationView`; a new one is swapped in for every attempt,
    /// because a view stays paired with the context it was made for.
    let slot = NSView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    private var context: LAContext?
    private var generation = 0

    static let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometricsOrCompanion

    /// Whether Touch ID or a paired Apple Watch can be used right now.
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(policy, error: &error)
    }

    /// Starts an evaluation; `completion` runs once, on the main actor.
    func begin(reason: String, completion: @escaping @MainActor (Outcome) -> Void) {
        cancel()
        let ctx = LAContext()
        ctx.localizedCancelTitle = nil
        var error: NSError?
        guard ctx.canEvaluatePolicy(Self.policy, error: &error) else {
            completion(error.map(Self.outcome) ?? .unavailable)
            return
        }
        let view = LAAuthenticationView(context: ctx, controlSize: .regular)
        view.frame = slot.bounds
        view.autoresizingMask = [.width, .height]
        slot.subviews.forEach { $0.removeFromSuperview() }
        slot.addSubview(view)
        context = ctx
        generation += 1
        let mine = generation
        ctx.evaluatePolicy(Self.policy, localizedReason: reason) { [weak self] ok, error in
            let outcome: Outcome = ok ? .success : (error.map { Self.outcome($0 as NSError) } ?? .failed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == mine else { return }
                    self.context = nil
                    completion(outcome)
                }
            }
        }
    }

    func cancel() {
        generation += 1
        context?.invalidate()
        context = nil
    }

    nonisolated private static func outcome(_ error: NSError) -> Outcome {
        guard error.domain == LAErrorDomain, let code = LAError.Code(rawValue: error.code) else { return .failed }
        switch code {
        case .biometryLockout: return .lockedOut
        case .authenticationFailed: return .failed
        case .userCancel, .systemCancel, .appCancel, .invalidContext, .userFallback: return .cancelled
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet, .notInteractive,
             .companionNotAvailable, .biometryDisconnected, .biometryNotPaired:
            return .unavailable
        default: return .failed
        }
    }
}
