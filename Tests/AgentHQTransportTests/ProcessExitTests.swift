import Darwin
import Foundation
import Testing
@testable import AgentHQTransport

/// Launches and later waits from one actor, the way `SSHTunnel` does.
///
/// The `waitUntilExit` hang this replaces does not reproduce under the test
/// runner — only in a standalone process, where it hangs within a few
/// iterations of the loop below. So these defend the replacement's own
/// behaviour, not the absence of that hang.
private actor Launcher {
    private var process: Process?

    func launch(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = arguments
        try process.run()
        self.process = process
        return process
    }

    func deactivate() async {
        await process?.terminateAndWait()
    }
}

@Suite("waiting on a child process")
struct ProcessExitTests {
    @Test(
        "terminating a child from the actor that launched it returns, every time",
        .timeLimit(.minutes(1))
    )
    func terminateAcrossExecutors() async throws {
        for _ in 0..<40 {
            let launcher = Launcher()
            let process = try await launcher.launch(["30"])
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { try? await Task.sleep(for: .milliseconds(20)) }
                }
            }
            await launcher.deactivate()
            #expect(!process.isRunning)
        }
    }

    @Test("a child that ignores SIGTERM is killed after the grace period", .timeLimit(.minutes(1)))
    func escalatesToKill() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30"]
        try process.run()
        // Give the shell time to install its trap before the signal lands.
        try await Task.sleep(for: .milliseconds(200))

        let start = ContinuousClock.now
        await process.terminateAndWait(grace: .milliseconds(300))
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("waiting on a child that already exited returns at once")
    func alreadyExited() async throws {
        let process = try await Launcher().launch(["0"])
        await process.exited()
        await process.terminateAndWait()
        #expect(process.terminationStatus == 0)
    }
}
