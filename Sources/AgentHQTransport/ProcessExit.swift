import Darwin
import Foundation

/// Waiting for a child process without `waitUntilExit`.
///
/// `waitUntilExit` spins the calling thread's run loop until Foundation posts
/// the exit to it — and under Swift concurrency or GCD the thread that waits
/// is rarely the one that launched, so nothing ever arrives. It hung the WSL
/// tunnel's `deactivate` forever, with the ssh already reaped: `sample` showed
/// the session parked in `waitUntilExit` inside `waitUntilReady`, the
/// `SSHTunnel` actor held for good, the machine stuck at `connecting` — which
/// the supervisor leaves alone — and Retry queued behind the same actor.
/// Reproduced outside the app: launch on an actor, terminate and wait from a
/// cooperative thread, and the sixth iteration never returned.
///
/// `isRunning` is updated off the run loop, so polling it does not have that
/// dependency. Every wait on a child in this package goes through here.
public extension Process {
    /// Suspend until the process has exited. Does not honour cancellation:
    /// the caller is about to rely on the process being gone.
    func exited() async {
        while isRunning {
            await Self.pause()
        }
    }

    /// Block the current thread until the process has exited. For callers
    /// already off every executor — a GCD worker, a detached task.
    func blockUntilExited() {
        while isRunning { usleep(10_000) }
    }

    /// SIGTERM, then SIGKILL if it is still running after `grace`.
    ///
    /// An ssh stuck on a dead link can sit on SIGTERM; a teardown that waited
    /// on it indefinitely would be this same hang with a different cause.
    func terminateAndWait(grace: Duration = .seconds(2)) async {
        guard isRunning else { return }
        terminate()
        let deadline = ContinuousClock.now + grace
        while isRunning, ContinuousClock.now < deadline {
            await Self.pause()
        }
        if isRunning { kill(processIdentifier, SIGKILL) }
        await exited()
    }

    /// Ten milliseconds that cancellation cannot cut short. `Task.sleep`
    /// throws immediately in a cancelled task, which would turn these loops
    /// into a spin — and teardown does run from cancelled tasks.
    private static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
                continuation.resume()
            }
        }
    }
}
