import Foundation

// MARK: - Where an agent keeps its conversation

/// The agent's own session, as the agent reported it to herdr.
///
/// herdr's integrations report either an id, which names a file in the agent's
/// own store, or a path to it. herdr passes the value along and has no reader
/// for it: `pane.read` is the terminal, and on an alternate screen — Claude
/// Code in fullscreen — the terminal is one screenful and no more.
public struct AgentSessionRef: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case id
        case path
    }

    /// The agent that reported it, lowercased: `claude`, `codex`, `pi`, …
    public let agent: String
    public let kind: Kind
    public let value: String

    public init(agent: String, kind: Kind, value: String) {
        self.agent = agent.lowercased()
        self.kind = kind
        self.value = value
    }

    /// The format of this session's transcript, when AgentHQ has a reader for
    /// it. Nil is the answer for every other agent: the console then offers
    /// the screen only, rather than a reader guessed from someone else's
    /// format.
    public var format: TranscriptFormat? { TranscriptFormat(agent: agent) }
}

/// The transcript formats AgentHQ can read, each pinned in tests to records
/// captured from a real session of that agent.
public enum TranscriptFormat: String, Sendable, Equatable, CaseIterable {
    /// Claude Code: `~/.claude/projects/<slug>/<id>.jsonl`.
    case claude
    /// Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`.
    case codex
    /// pi: `~/.pi/agent/sessions/<slug>/<time>_<id>.jsonl`; its integration
    /// reports the path itself.
    case pi
    /// opencode: rows in `~/.local/share/opencode/opencode.db`, not a file.
    case opencode

    public init?(agent: String) {
        self.init(rawValue: agent.lowercased())
    }
}

// MARK: - One turn

public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
        /// A tool the agent ran, as one line: its name and what it was given.
        /// Its output is left out — it is what the screen is for, and in these
        /// files it is most of the bytes.
        case tool
    }

    /// Position in the transcript as read. Stable for an append-only file,
    /// which is all SwiftUI needs to keep a list from redrawing.
    public let id: Int
    public let role: Role
    public let text: String

    public init(id: Int, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - Reading it on the machine

/// The shell script that reads a session's transcript on whichever machine
/// holds it, and the protocol its output speaks.
///
/// One script for every machine: `/bin/sh` runs it here, `ssh` runs it there,
/// which keeps this Mac the degenerate case of a remote one. It answers with a
/// header line and then the bytes:
///
/// - `SAME` — nothing changed since the size the caller already holds.
/// - `APPEND <size>` — the bytes after the caller's size, up to `<size>`.
/// - `FULL <size>` — the tail of the file, ending at `<size>`.
/// - `ROWS <fingerprint>` — opencode: a JSON array of its newest parts.
/// - `MISSING` — the store has no such session.
/// - `NOTOOL` — the machine cannot read that store (opencode without sqlite3
///   or python3).
///
/// Both file answers read `head -c <size>` of the file, not the file: an
/// agent is appending while this runs, and bytes past the size just measured
/// would be read twice by the next append.
public enum TranscriptScript {
    /// How much of a file to hold. A long session is megabytes, most of them
    /// tool output, and the console wants the recent turns.
    public static let byteLimit = 1_500_000

    /// opencode rows per read, newest first.
    public static let rowLimit = 300

    /// The script, or nil when the session cannot be read safely or AgentHQ
    /// has no reader for it.
    ///
    /// `value` came from a herdr server, possibly on another machine, and is
    /// about to be run by a shell. So an id must be an id — letters, digits,
    /// `-` and `_` — and a path must be an absolute `.jsonl` path, which goes
    /// in single quotes. Anything else is refused rather than escaped
    /// creatively.
    public static func script(for session: AgentSessionRef, known: Int) -> String? {
        guard let format = session.format else { return nil }
        let known = max(0, known)

        if format == .opencode {
            guard session.kind == .id, isSafeID(session.value) else { return nil }
            return opencode(id: session.value, known: known)
        }

        let locate: String
        switch session.kind {
        case .path:
            guard isSafePath(session.value) else { return nil }
            locate = "f=\(quoted(session.value))"
        case .id:
            guard isSafeID(session.value) else { return nil }
            let id = session.value
            // `ls -t | head -n 1` over a glob: a session id names one file,
            // but the directory above it is derived from the working directory
            // by rules that are each agent's own, and a glob is how to not
            // re-derive them. An unmatched glob stays literal, `ls` fails
            // quietly, and the answer is MISSING.
            let pattern: String
            switch format {
            case .claude:
                pattern = #""${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/\#(id).jsonl"#
            case .codex:
                pattern = #""${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*-\#(id).jsonl"#
            case .pi:
                pattern = #""${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"/sessions/*/*_\#(id).jsonl"#
            case .opencode:
                return nil
            }
            locate = "f=$(ls -t \(pattern) 2>/dev/null | head -n 1)"
        }

        return """
        \(locate)
        if [ -z "$f" ] || [ ! -f "$f" ]; then echo MISSING; exit 0; fi
        size=$(wc -c < "$f" | tr -d ' ')
        known=\(known)
        if [ "$size" = "$known" ]; then echo SAME; exit 0; fi
        if [ "$known" -gt 0 ] && [ "$size" -gt "$known" ] && [ $((size - known)) -le \(byteLimit) ]; then
          echo "APPEND $size"; head -c "$size" "$f" | tail -c +$((known + 1))
        else
          echo "FULL $size"; head -c "$size" "$f" | tail -c \(byteLimit)
        fi
        """
    }

    /// opencode keeps sessions in SQLite. `sqlite3` where there is one, which
    /// is every Mac; `python3`'s own sqlite3 module where there is not, which
    /// is a stock WSL Ubuntu. Read-only either way: opencode may be writing.
    ///
    /// The fingerprint is the part count and newest update, so an unchanged
    /// session costs one small query rather than the rows. `known` is the
    /// fingerprint's hash as the caller holds it.
    private static func opencode(id: String, known: Int) -> String {
        let fingerprintSQL = "select count(*) || '-' || coalesce(max(time_updated), 0) from part where session_id = '\(id)'"
        let rowsSQL = "select m.data as message, p.data as data from part p join message m on m.id = p.message_id where p.session_id = '\(id)' order by p.time_created desc, p.id desc limit \(rowLimit)"
        return """
        db="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
        if [ ! -f "$db" ]; then echo MISSING; exit 0; fi
        known=\(known)
        if command -v sqlite3 >/dev/null 2>&1; then
          fp=$(sqlite3 -readonly "$db" "\(fingerprintSQL)")
          sum=$(printf %s "$fp" | cksum | cut -d ' ' -f 1)
          if [ "$sum" = "$known" ]; then echo SAME; exit 0; fi
          echo "ROWS $sum"; sqlite3 -readonly -json "$db" "\(rowsSQL)"
        elif command -v python3 >/dev/null 2>&1; then
          python3 - "$db" "$known" <<'AGENTHQ_PY'
        import json, sqlite3, subprocess, sys
        db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
        fp = db.execute("\(fingerprintSQL)").fetchone()[0]
        sum = subprocess.run(["cksum"], input=fp.encode(), capture_output=True).stdout.split()[0].decode()
        if sum == sys.argv[2]:
            print("SAME")
        else:
            print("ROWS " + sum)
            rows = db.execute("\(rowsSQL)").fetchall()
            print(json.dumps([{"message": m, "data": d} for m, d in rows]))
        AGENTHQ_PY
        else
          echo NOTOOL
        fi
        """
    }

    static func isSafeID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    static func isSafePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.hasSuffix(".jsonl") && value.count <= 1024
            && !value.contains { $0 == "\0" || $0 == "\n" || $0 == "\r" }
    }

    /// POSIX single quotes: nothing inside is special except the quote itself,
    /// which closes, escapes, and reopens.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// What one run of ``TranscriptScript`` said.
public enum TranscriptRead: Sendable, Equatable {
    case same
    case append(Data, size: Int)
    case full(Data, size: Int)
    case rows(Data, fingerprint: Int)
    case missing
    case noTool

    /// Nil for output that does not start with a header the script writes —
    /// ssh's own complaints, a shell's banner — which is not a transcript and
    /// must not be read as one.
    public init?(output: Data) {
        let newline = output.firstIndex(of: 0x0A) ?? output.endIndex
        let header = String(decoding: output[output.startIndex..<newline], as: UTF8.self)
        let body = newline < output.endIndex ? output[output.index(after: newline)...] : Data()
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? Int(parts[1]) : nil) {
        case ("SAME", _):             self = .same
        case ("MISSING", _):          self = .missing
        case ("NOTOOL", _):           self = .noTool
        case ("APPEND", let n?):      self = .append(Data(body), size: n)
        case ("FULL", let n?):        self = .full(Data(body), size: n)
        case ("ROWS", let n?):        self = .rows(Data(body), fingerprint: n)
        default:                      return nil
        }
    }
}

// MARK: - Holding it between reads

/// A console's copy of one transcript, kept current by appending.
///
/// Holds raw bytes rather than parsed entries: the last line of a read can be
/// a record the agent was still writing, and it is only complete once the
/// next append lands behind it. Reparsing the held bytes each time is what
/// makes that free.
public struct TranscriptBuffer: Sendable, Equatable {
    public let format: TranscriptFormat
    /// What to pass the next script run as `known`.
    public private(set) var cursor = 0
    public private(set) var entries: [TranscriptEntry] = []
    private var bytes = Data()

    public init(format: TranscriptFormat) {
        self.format = format
    }

    /// Fold one read in. Returns whether the entries changed.
    @discardableResult
    public mutating func apply(_ read: TranscriptRead) -> Bool {
        switch read {
        case .same, .missing, .noTool:
            return false
        case .append(let data, let size):
            bytes.append(data)
            cursor = size
            trim()
        case .full(let data, let size):
            bytes = data
            cursor = size
        case .rows(let data, let fingerprint):
            bytes = data
            cursor = fingerprint
        }
        let parsed = TranscriptParser.parse(bytes, format: format)
        guard parsed != entries else { return false }
        entries = parsed
        return true
    }

    /// Keep to the byte limit, dropping whole lines from the front.
    private mutating func trim() {
        let excess = bytes.count - TranscriptScript.byteLimit
        guard excess > 0 else { return }
        let cut = bytes[(bytes.startIndex + excess)...].firstIndex(of: 0x0A).map { $0 + 1 }
            ?? bytes.endIndex
        bytes = Data(bytes[cut...])
    }
}

// MARK: - Parsing

/// Each agent's transcript, reduced to user / assistant / tool turns.
///
/// What is left out is left out on purpose: reasoning (often encrypted, and
/// not the conversation), tool output (the screen shows it), and everything an
/// agent writes to its own file for its own bookkeeping — injected
/// instructions, metadata records, token counts.
public enum TranscriptParser {
    /// The newest turns kept. A console is a window, not an archive.
    public static let entryLimit = 400

    public static func parse(_ data: Data, format: TranscriptFormat) -> [TranscriptEntry] {
        var turns: [(TranscriptEntry.Role, String)] = []
        switch format {
        case .opencode:
            turns = opencodeTurns(data)
        case .claude, .codex, .pi:
            for line in data.split(separator: 0x0A) {
                // A line that does not decode is the partial record at either
                // end of a read, and is skipped rather than guessed at.
                guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                switch format {
                case .claude: turns += claudeTurns(record)
                case .codex:  turns += codexTurns(record)
                case .pi:     turns += piTurns(record)
                case .opencode: break
                }
            }
        }
        let kept = turns
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .suffix(entryLimit)
        return kept.enumerated().map { TranscriptEntry(id: $0.offset, role: $0.element.0, text: $0.element.1) }
    }

    // MARK: Claude Code

    /// `{"type": "user" | "assistant", "message": {"content": …}}`.
    ///
    /// A user record is also how Claude Code hands back a tool result, and how
    /// it injects its own context: `isMeta` records, command echoes wrapped in
    /// `<command-…>` / `<local-command-…>` tags, and `<system-reminder>`s. Only
    /// plain text the user typed is a user turn. Sidechains are sub-agents,
    /// whose turns are not this conversation's.
    private static func claudeTurns(_ record: [String: Any]) -> [(TranscriptEntry.Role, String)] {
        guard let type = record["type"] as? String, type == "user" || type == "assistant",
              record["isSidechain"] as? Bool != true,
              record["isMeta"] as? Bool != true,
              let message = record["message"] as? [String: Any]
        else { return [] }

        if type == "user" {
            let texts: [String]
            if let content = message["content"] as? String {
                texts = [content]
            } else {
                texts = blocks(message["content"]).compactMap {
                    $0["type"] as? String == "text" ? $0["text"] as? String : nil
                }
            }
            return texts.filter { !isInjected($0) }.map { (.user, $0) }
        }

        return blocks(message["content"]).compactMap { block in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String).map { (.assistant, $0) }
            case "tool_use":
                return (.tool, toolLine(block["name"] as? String, block["input"]))
            default:
                return nil
            }
        }
    }

    private static func isInjected(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<") || trimmed.hasPrefix("Caveat:")
    }

    // MARK: Codex

    /// Read from `event_msg` / `item_completed`, not from `response_item`.
    ///
    /// The response items are the model's input, and Codex's own injected
    /// context arrives there as *user* messages — `# AGENTS.md instructions`,
    /// `<environment_context>` — indistinguishable by role from what the user
    /// typed. The completed items are the thread as Codex's own UI shows it:
    /// `UserMessage`, `AgentMessage`, and the tools.
    private static func codexTurns(_ record: [String: Any]) -> [(TranscriptEntry.Role, String)] {
        guard record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              payload["type"] as? String == "item_completed",
              let item = payload["item"] as? [String: Any],
              let type = item["type"] as? String
        else { return [] }

        switch type {
        case "UserMessage":
            return [(.user, joinedText(item["content"]))]
        case "AgentMessage":
            return [(.assistant, joinedText(item["content"]))]
        case "CommandExecution":
            let command = (item["command"] as? [String]).map(unwrapShell) ?? ""
            return [(.tool, "exec: \(command)")]
        case "McpToolCall":
            let name = [item["server"] as? String, item["tool"] as? String]
                .compactMap { $0 }.joined(separator: ".")
            return [(.tool, toolLine(name, item["arguments"]))]
        default:
            // Reasoning, and item kinds not measured yet: nothing rather than
            // a guess at their shape.
            return []
        }
    }

    /// `["/bin/zsh", "-lc", "rg …"]` is `rg …` to anyone reading along.
    private static func unwrapShell(_ argv: [String]) -> String {
        if argv.count == 3, argv[1].hasPrefix("-") && argv[1].contains("c") { return argv[2] }
        return argv.joined(separator: " ")
    }

    // MARK: pi

    /// `{"type": "message", "message": {"role": …, "content": [...]}}`.
    ///
    /// Roles are `user`, `assistant`, `toolResult` and `system`; only the
    /// first two are turns. A pi session is a tree — `parentId` — and a
    /// branch the user left behind is still in the file; read in file order,
    /// as pi appends them.
    private static func piTurns(_ record: [String: Any]) -> [(TranscriptEntry.Role, String)] {
        guard record["type"] as? String == "message",
              let message = record["message"] as? [String: Any],
              let role = message["role"] as? String
        else { return [] }

        switch role {
        case "user":
            if let content = message["content"] as? String { return [(.user, content)] }
            return [(.user, joinedText(message["content"]))]
        case "assistant":
            return blocks(message["content"]).compactMap { block in
                switch block["type"] as? String {
                case "text":
                    return (block["text"] as? String).map { (.assistant, $0) }
                case "toolCall":
                    return (.tool, toolLine(block["name"] as? String, block["arguments"]))
                default:
                    return nil
                }
            }
        default:
            return []
        }
    }

    // MARK: opencode

    /// A JSON array of `{message, data}` — the message row and one part row,
    /// newest first. The role is on the message; the content is on the part.
    /// Synthetic parts are opencode's own additions to a user turn.
    private static func opencodeTurns(_ data: Data) -> [(TranscriptEntry.Role, String)] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return rows.reversed().compactMap { row in
            guard let message = decodeJSONString(row["message"]),
                  let part = decodeJSONString(row["data"]),
                  let role = message["role"] as? String
            else { return nil }

            switch (role, part["type"] as? String) {
            case ("user", "text"):
                guard part["synthetic"] as? Bool != true else { return nil }
                return (part["text"] as? String).map { (.user, $0) }
            case ("assistant", "text"):
                return (part["text"] as? String).map { (.assistant, $0) }
            case ("assistant", "tool"):
                let state = part["state"] as? [String: Any]
                return (.tool, toolLine(part["tool"] as? String, state?["input"]))
            default:
                return nil
            }
        }
    }

    private static func decodeJSONString(_ value: Any?) -> [String: Any]? {
        guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Shared

    private static func blocks(_ content: Any?) -> [[String: Any]] {
        content as? [[String: Any]] ?? []
    }

    private static func joinedText(_ content: Any?) -> String {
        blocks(content).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// One line for a tool call: its name and the argument a reader would
    /// recognise it by — the command, the file, the pattern — rather than
    /// the whole input.
    static func toolLine(_ name: String?, _ input: Any?) -> String {
        let name = name ?? "tool"
        var arguments = input as? [String: Any]
        if arguments == nil, let string = input as? String {
            arguments = decodeJSONString(string)
            if arguments == nil { return "\(name): \(firstLine(string))" }
        }
        guard let arguments else { return name }
        let preferred = ["command", "cmd", "file_path", "filePath", "path", "pattern", "query", "url", "description", "title"]
        let value = preferred.lazy.compactMap { arguments[$0] as? String }.first
            ?? arguments.values.lazy.compactMap { $0 as? String }.first
        guard let value else { return name }
        return "\(name): \(firstLine(value))"
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}

public enum TranscriptError: Error, Sendable, CustomStringConvertible {
    /// The machine answered with something that is not the script's protocol.
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let output):
            return output.isEmpty
                ? "The machine returned nothing for this transcript."
                : "The machine did not answer as expected: \(output)"
        }
    }
}
