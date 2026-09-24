import AgentHQKit
import AppKit
import Foundation

/// Presents the selected conversation in Ghostty after herdr has focused its
/// pane.
///
/// Herdr 0.9.1 cannot select a machine in an already attached multi-machine
/// client through its API, so a reveal is two steps: herdr focuses the pane in
/// its own server, then this focuses the Ghostty surface that renders that
/// server. For a remote machine no such surface may exist yet, so the first
/// click opens one and the terminal is remembered for the next.
@MainActor
enum GhosttyReveal {
    enum RevealError: LocalizedError {
        case herdrMissing
        case invalidArgument
        case automationDenied
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .herdrMissing:
                "Could not find the herdr executable on this Mac."
            case .invalidArgument:
                "The saved machine has an invalid SSH target or session name."
            case .automationDenied:
                "Allow AgentHQ to control Ghostty in System Settings → Privacy & Security → Automation."
            case .scriptFailed(let message):
                "Could not reveal this conversation in Ghostty: \(message)"
            }
        }
    }

    // Earlier commands failed to start. Never reuse their terminal windows.
    private static let terminalKeyPrefix = "ghostty.reveal.v3.terminal."

    /// Focus an existing terminal when possible, or open a client for this
    /// machine. The returned text is suitable for the row's status line.
    static func present(machine: Machine, agent: Agent) throws -> String {
        try present(machine: machine, needles: needles(for: machine, agent: agent))
    }

    /// Bring up a herdr client for a machine with no agent to aim at — the
    /// panel's Open herdr button, for when there is nothing to Reveal yet.
    ///
    /// `isServing` is whether AgentHQ can currently reach that machine's
    /// herdr. When it cannot, no surface on screen can be drawing it, so
    /// neither a title match nor the remembered terminal is worth focusing:
    /// the remembered one may be a shell left behind by a herdr that exited,
    /// and focusing it would look like the click worked. Starting `herdr`
    /// starts its server too, which is the point of the button.
    static func open(machine: Machine, isServing: Bool) throws -> String {
        guard isServing else {
            return try present(machine: machine, needles: [], reuse: false)
        }
        return try present(machine: machine, needles: needles(for: machine, agent: nil))
    }

    private static func present(machine: Machine, needles: [String], reuse: Bool = true) throws -> String {
        let command = try herdrCommand(for: machine)
        let key = terminalKeyPrefix + machine.id.raw
        let rememberedID = reuse ? UserDefaults.standard.string(forKey: key) : nil
        let source = try script(
            command: command,
            rememberedID: rememberedID,
            needles: needles,
            // A local herdr is already drawn by whichever Ghostty surface the
            // user runs it in, so finding that surface beats one AgentHQ
            // opened. A remote machine is the reverse: the window AgentHQ
            // created is the only place the conversation is guaranteed to be.
            preferRemembered: machine.transport.isRemote
        )

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw RevealError.scriptFailed("AppleScript could not be created")
        }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let response = result.stringValue,
              let separator = response.firstIndex(of: "|")
        else {
            let number = error?["NSAppleScriptErrorNumber"] as? Int
            if number == -1743 { throw RevealError.automationDenied }
            let message = error?["NSAppleScriptErrorMessage"] as? String
                ?? "Ghostty did not return a terminal"
            throw RevealError.scriptFailed(message)
        }

        let disposition = String(response[..<separator])
        let terminalID = String(response[response.index(after: separator)...])
        guard !terminalID.isEmpty else {
            throw RevealError.scriptFailed("Ghostty returned an empty terminal ID")
        }
        UserDefaults.standard.set(terminalID, forKey: key)
        return disposition == "created" ? "Opened in Ghostty." : "Focused in Ghostty."
    }

    /// Name fragments that identify the Ghostty surface rendering a machine's
    /// herdr, most trustworthy first.
    ///
    /// Only a local herdr is already drawn by a Ghostty surface the user owns,
    /// and only the local hostname is a fragment that will not match an
    /// unrelated terminal. herdr titles that surface from `ui.window_title`,
    /// which defaults to `"{hostname}: {workspace}"` — measured against herdr
    /// 0.9.1, where the local surface read `Mac.home: AgentHQ`. `{hostname}`
    /// comes from `gethostname()`, so both sides ask for the same name. The
    /// workspace and repo name only cover a user who titled their window with
    /// those instead; a fragment that never matches simply never matches.
    ///
    /// A remote machine gets no needles at all. Any fragment generic enough to
    /// guess its window title would also match a local terminal, and focusing
    /// the wrong surface is worse than opening the right one.
    ///
    /// With no agent only the hostname is left, which is still the fragment
    /// herdr's default title leads with.
    static func needles(
        for machine: Machine,
        agent: Agent?,
        hostname: String = GhosttyReveal.localHostname()
    ) -> [String] {
        guard machine.transport.isLocal else { return [] }

        var values = [hostname]
        if let agent {
            values += [agent.workspace, (agent.directory as NSString).lastPathComponent]
        }

        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func herdrCommand(for machine: Machine, home: String = NSHomeDirectory()) throws -> String {
        let candidates = [
            "\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/herdr" }
        guard let binary = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw RevealError.herdrMissing
        }

        return try command(binary: binary, for: machine)
    }

    /// Variables herdr exports into every pane. A Ghostty launched from inside
    /// a pane (`open -a Ghostty` typed there) inherits them and hands them to
    /// every surface it opens, and herdr refuses to start under `HERDR_ENV`
    /// with "nested herdr is disabled". The rest name a pane and socket that
    /// belong to whichever client the user typed in, not the one opening here.
    static let inheritedHerdrVariables = [
        "HERDR_ENV", "HERDR_BIN_PATH", "HERDR_SOCKET_PATH",
        "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID",
    ]

    static func command(binary: String, for machine: Machine) throws -> String {
        // Ghostty's macOS surface runner prepends `exec -l` itself. A `shell:`
        // prefix or another `exec` would be interpreted as the program name;
        // `env` is a program, so it runs under that `exec` like herdr would.
        var command = "/usr/bin/env"
        for name in inheritedHerdrVariables {
            command += " -u \(name)"
        }
        command += " \(try shellArgument(binary))"
        if case .ssh(let destination, _, let session, _) = machine.transport {
            command += " --remote \(try shellArgument(destination))"
            if session != "default" && !session.isEmpty {
                command += " --session \(try shellArgument(session))"
            }
        }
        return command
    }

    /// The local hostname, as herdr's `{hostname}` token renders it.
    ///
    /// `gethostname()` returns `Mac.home` where `ProcessInfo.hostName` returns
    /// `johans-macbook-air.local`; herdr uses the former, so a match has to be
    /// asked for the same name it is.
    static func localHostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(
            decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self
        )
    }

    /// Build only literal AppleScript strings. Machine data is never parsed as
    /// script, and the herdr command quotes each shell argument separately.
    static func script(
        command: String,
        rememberedID: String?,
        needles: [String],
        preferRemembered: Bool = true
    ) throws -> String {
        let commandLiteral = try appleScriptLiteral(command)
        let idLiteral = try rememberedID.map(appleScriptLiteral) ?? "\"\""
        let needlesLiteral = "{"
            + (try needles.map(appleScriptLiteral).joined(separator: ", "))
            + "}"

        // A remembered terminal that Ghostty has since closed fails with -1728
        // (unknown id), which is the one error worth swallowing: any other is a
        // real scripting failure and has to surface.
        let rememberedAttempt = """
        if rememberedID is not "" then
            try
                set targetTerminal to terminal id rememberedID
                focus targetTerminal
                return "focused|" & (id of targetTerminal)
            on error errText number errNumber
                if errNumber is not -1728 then error errText number errNumber
            end try
        end if
        """

        return """
        tell application id "com.mitchellh.ghostty"
            set rememberedID to \(idLiteral)
            set needles to \(needlesLiteral)

        \(preferRemembered ? rememberedAttempt : "")

            repeat with needle in needles
                repeat with candidate in terminals
                    if needle is not "" and (name of candidate) contains needle then
                        focus candidate
                        return "focused|" & (id of candidate)
                    end if
                end repeat
            end repeat

        \(preferRemembered ? "" : rememberedAttempt)

            set cfg to new surface configuration
            set command of cfg to \(commandLiteral)
            set wait after command of cfg to false
            set newWindow to new window with configuration cfg
            set targetTerminal to terminal 1 of selected tab of newWindow
            focus targetTerminal
            return "created|" & (id of targetTerminal)
        end tell
        """
    }

    private static func appleScriptLiteral(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RevealError.invalidArgument
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func shellArgument(_ value: String) throws -> String {
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw RevealError.invalidArgument }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
