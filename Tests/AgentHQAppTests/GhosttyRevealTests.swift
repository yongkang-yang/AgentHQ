import AgentHQKit
import AppKit
import Foundation
import Testing
@testable import AgentHQApp

@Suite("Reveal opens the selected herd in Ghostty")
struct GhosttyRevealTests {
    private func agent(
        workspace: String = "", directory: String = ""
    ) -> Agent {
        Agent(
            ref: AgentRef(machine: MachineID("m"), agent: AgentID("wC:p5")),
            provider: "pi",
            workspace: workspace,
            directory: directory
        )
    }

    private func localMachine() -> Machine {
        Machine(
            id: MachineID("local"), displayName: "localhost",
            transport: .local(socketPath: "/tmp/herdr.sock")
        )
    }

    private func remoteMachine() -> Machine {
        Machine(
            id: MachineID("remote"), displayName: "remote",
            transport: .ssh(
                destination: "wsl; echo unwanted", port: nil,
                session: "night's work", remoteSocketPath: nil
            )
        )
    }

    @Test("remote commands keep the SSH target and session as literal arguments")
    @MainActor
    func remoteCommandQuotesArguments() throws {
        let command = try GhosttyReveal.command(binary: "/tmp/my herdr", for: remoteMachine())
        #expect(command.hasSuffix(
            " '/tmp/my herdr' --remote 'wsl; echo unwanted' --session 'night'\\''s work'"
        ))
    }

    @Test("a Ghostty launched from inside a herdr pane does not pass that pane's variables on")
    @MainActor
    func surfaceCommandDropsInheritedHerdrVariables() throws {
        let command = try GhosttyReveal.command(binary: "/usr/bin/env", for: localMachine())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(command)"]
        var environment = ProcessInfo.processInfo.environment
        for name in GhosttyReveal.inheritedHerdrVariables {
            environment[name] = "inherited"
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let printed = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(printed.contains("PATH="))
        #expect(!printed.contains("HERDR_"))
    }

    @Test("Ghostty's macOS exec wrapper can execute the generated command")
    @MainActor
    func surfaceCommandRunsInShell() throws {
        let command = try GhosttyReveal.command(binary: "/bin/echo", for: remoteMachine())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(command)"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        let line = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(process.terminationStatus == 0)
        #expect(line == "--remote wsl; echo unwanted --session night's work\n")
    }

    @Test("a local reveal looks first for the hostname herdr titles its surface with")
    @MainActor
    func localNeedlesLeadWithHostname() {
        let needles = GhosttyReveal.needles(
            for: localMachine(),
            agent: agent(workspace: "RainNext", directory: "/Users/me/Code/RainNext"),
            hostname: "Mac.home"
        )
        // herdr's default `window_title` is "{hostname}: {workspace}".
        #expect(needles.first == "Mac.home")
        // The extras cover a window titled with the workspace or repo instead.
        #expect(needles.contains("RainNext"))
        #expect(needles.filter { $0 == "RainNext" }.count == 1)
    }

    @Test("a remote reveal scans nothing and relies on its own window")
    @MainActor
    func remoteHasNoNeedles() {
        // A remote title is the remote host's name, which we cannot resolve, and
        // any generic guess would match a local terminal instead.
        let needles = GhosttyReveal.needles(
            for: remoteMachine(),
            agent: agent(workspace: "AgentHQ", directory: "/Users/me/Code/AgentHQ"),
            hostname: "Mac.home"
        )
        #expect(needles.isEmpty)
    }

    @Test("Ghostty's installed dictionary accepts the reveal script")
    @MainActor
    func scriptCompiles() throws {
        let source = try GhosttyReveal.script(
            command: "'/tmp/herdr' --remote 'wsl'",
            rememberedID: "8B20BC85-14A7-4A6A-8EE0-D026B33E4995",
            needles: ["Mac.home", "RainNext"]
        )
        let script = try #require(NSAppleScript(source: source))
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        #expect(compiled, "\(String(describing: error))")
    }

    @Test("a local reveal tries the matching surface before the remembered one")
    @MainActor
    func localPrefersTitleMatch() throws {
        let source = try GhosttyReveal.script(
            command: "'/tmp/herdr'", rememberedID: "ABC", needles: ["Mac.home"],
            preferRemembered: false
        )
        let remembered = try #require(source.range(of: "rememberedID is not \"\""))
        let needles = try #require(source.range(of: "repeat with candidate in terminals"))
        // Exactly one remembered attempt, and it comes after the title match.
        #expect(source.components(separatedBy: "rememberedID is not \"\"").count == 2)
        #expect(needles.lowerBound < remembered.lowerBound)
    }

    @Test("a remote reveal reuses its window before scanning for one")
    @MainActor
    func remotePrefersRemembered() throws {
        let source = try GhosttyReveal.script(
            command: "'/tmp/herdr'", rememberedID: "ABC", needles: ["remote", "RainNext"],
            preferRemembered: true
        )
        let remembered = try #require(source.range(of: "rememberedID is not \"\""))
        let needles = try #require(source.range(of: "repeat with candidate in terminals"))
        #expect(remembered.lowerBound < needles.lowerBound)
    }

    @Test("machine data cannot add AppleScript statements")
    @MainActor
    func scriptRejectsControlCharacters() {
        #expect(throws: GhosttyReveal.RevealError.self) {
            try GhosttyReveal.script(
                command: "'/tmp/herdr'",
                rememberedID: nil,
                needles: ["repo\nend tell"]
            )
        }
    }
}
