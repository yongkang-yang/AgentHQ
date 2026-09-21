import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

@Suite("herdr machine registry")
struct HerdrMachineRegistryTests {
    /// Verbatim from a real `~/.local/state/herdr/client/endpoints.json`.
    private let realFile = Data(#"""
    {
      "version": 1,
      "ssh": [
        { "id": "3820f198aa41e67920f90e8eb4217c2c", "label": "cursor", "target": "cursor", "session": "default", "enabled": false },
        { "id": "822f3f7c5aefc1d1b873d31c7dd04e35", "label": "wsl", "target": "wsl", "session": "default", "enabled": true }
      ]
    }
    """#.utf8)

    @Test("imports saved machines with herdr's own ids")
    func importsMachines() throws {
        let machines = HerdrMachineRegistry.machines(from: realFile)
        #expect(machines.count == 2)

        let wsl = try #require(machines.first { $0.displayName == "wsl" })
        // Adopting herdr's id is what keeps dwell timers and acknowledged
        // notifications attached to a machine across restarts and renames.
        #expect(wsl.id == MachineID("822f3f7c5aefc1d1b873d31c7dd04e35"))
        #expect(wsl.isEnabled)

        guard case .ssh(let destination, let port, let session, let remote) = wsl.transport else {
            Issue.record("expected an ssh transport")
            return
        }
        #expect(destination == "wsl")
        #expect(port == nil)
        #expect(session == "default")
        // Resolved on first connect; ssh will not expand a tilde in a forward.
        #expect(remote == nil)
    }

    @Test("a disabled machine imports as disabled rather than being dropped")
    func disabledIsPreserved() throws {
        let cursor = try #require(
            HerdrMachineRegistry.machines(from: realFile).first { $0.displayName == "cursor" }
        )
        // Dropping it would silently lose a machine the user configured and
        // may re-enable.
        #expect(!cursor.isEnabled)
    }

    @Test("an unknown schema version imports nothing")
    func futureVersionIgnored() {
        // This is herdr's internal state, not an API. Guessing at a shape we
        // have not seen is worse than importing nothing.
        let future = Data(#"{"version": 2, "ssh": [{"id":"a","label":"x","target":"x","session":"default","enabled":true}]}"#.utf8)
        #expect(HerdrMachineRegistry.machines(from: future).isEmpty)
    }

    @Test("a missing or unreadable file is not an error")
    func missingFile() {
        #expect(HerdrMachineRegistry.machines(at: URL(fileURLWithPath: "/nonexistent/endpoints.json")).isEmpty)
        #expect(HerdrMachineRegistry.machines(from: Data("not json".utf8)).isEmpty)
        #expect(HerdrMachineRegistry.machines(from: Data(#"{"version":1}"#.utf8)).isEmpty)
    }

    @Test("entries missing an id or target are skipped, not defaulted")
    func incompleteEntries() {
        let partial = Data(#"""
        {"version":1,"ssh":[
          {"label":"no id","target":"host","session":"default","enabled":true},
          {"id":"abc","label":"no target","session":"default","enabled":true},
          {"id":"def","target":"good","session":"default","enabled":true}
        ]}
        """#.utf8)
        let machines = HerdrMachineRegistry.machines(from: partial)
        #expect(machines.count == 1)
        #expect(machines.first?.id == MachineID("def"))
    }

    @Test("a machine with no label falls back to its ssh target")
    func labelFallback() throws {
        let unlabelled = Data(#"{"version":1,"ssh":[{"id":"x","target":"build-box","session":"default","enabled":true}]}"#.utf8)
        #expect(HerdrMachineRegistry.machines(from: unlabelled).first?.displayName == "build-box")
    }
}
