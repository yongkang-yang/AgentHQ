import Foundation

// MARK: - AgentID

/// A herdr pane id, exactly as herdr spells it.
///
/// This value goes back onto the wire verbatim as the `pane_id` parameter of
/// every herdr call, so it must stay a faithful echo of what herdr sent. It
/// carries no machine dimension and never will — see ``AgentRef`` for the
/// fleet-wide identity.
public struct AgentID: Hashable, Sendable, Codable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        self.raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - AgentRef

/// The fleet-wide identity of one agent: which machine, and which pane on it.
///
/// Two machines will hand out colliding pane ids — herdr numbers panes per
/// host and has no idea other hosts exist. `AgentRef` is therefore the key for
/// every collection that spans machines, and ``AgentID`` alone is only ever
/// valid inside a single ``MachineID``'s scope.
///
/// Deliberately a struct of two fields rather than a joined string: the moment
/// an id is stringly-joined, something downstream parses it back apart and
/// sends the wrong half to herdr.
public struct AgentRef: Hashable, Sendable, Codable {
    public let machine: MachineID
    public let agent: AgentID

    public init(machine: MachineID, agent: AgentID) {
        self.machine = machine
        self.agent = agent
    }
}
