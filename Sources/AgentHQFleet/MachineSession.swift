import AgentHQHerdr
import AgentHQKit
import AgentHQTransport
import Foundation

/// Everything that happens on behalf of one machine: bring the transport up,
/// speak herdr over it, keep a current agent list, and report reachability.
///
/// One session per machine, each failing and recovering independently. A
/// machine going dark must never stall the others — which is why this owns its
/// own transport, client, and event loop rather than sharing a pool.
public actor MachineSession {
    public let machine: Machine

    private let transport: any Transport
    private var client: (any HerdrClient)?
    private var eventTask: Task<Void, Never>?

    private var reachability: MachineReachability
    private var agents: [Agent] = []
    private var herdrVersion: String?
    /// workspaceId -> label, from the last snapshot. A `pane_updated` event
    /// carries ids but not labels, so patching one in place needs this.
    private var workspaceNames: [String: String] = [:]

    /// Builds the client for a resolved socket path.
    ///
    /// Injected so the staleness guard below can be tested against a client
    /// that records what it was asked to send. Those tests have to assert that
    /// *nothing was sent*, which is not observable from the thrown error
    /// alone — and "nothing was sent" is the entire promise the guard makes.
    public typealias ClientFactory = @Sendable (String) -> any HerdrClient

    private let makeClient: ClientFactory

    public init(
        machine: Machine,
        makeClient: @escaping ClientFactory = { LiveHerdrClient(socketPath: $0) }
    ) {
        self.machine = machine
        self.transport = machine.transport.makeTransport(for: machine.id)
        self.reachability = machine.isEnabled ? .connecting : .disabled
        self.makeClient = makeClient
    }

    /// The machine as the fleet currently sees it.
    public func view() -> MachineView {
        MachineView(
            machine: machine, reachability: reachability,
            agents: agents, herdrVersion: herdrVersion
        )
    }

    public func start() async {
        guard machine.isEnabled else {
            reachability = .disabled
            return
        }
        reachability = .connecting

        do {
            let socketPath = try await transport.activate()
            let client = makeClient(socketPath)
            let handshake = try await client.handshake()
            try await client.connect()

            self.client = client
            self.herdrVersion = handshake.version
            reachability = .connected
            try await resync()
            startEventLoop(client)
        } catch {
            // The reason is shown verbatim in the panel. Transport errors
            // already read as sentences ("build-box accepted the tunnel but
            // nothing is listening on …"), which is why they are not wrapped
            // into a generic "connection failed" here.
            reachability = .unreachable(reason: String(describing: error))
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await client?.disconnect()
        client = nil
        await transport.deactivate()
        reachability = machine.isEnabled ? .connecting : .disabled
        // Agents are kept, not cleared: the last known list is what the UI
        // shows as stale. Clearing it would make a dropped tunnel look like
        // every agent vanished.
    }

    /// Pull a full snapshot and replace the agent list.
    public func resync() async throws {
        guard let client else { return }
        let snapshot = try await client.snapshot()
        workspaceNames = snapshot.workspaceNames
        let output = await readOutput(for: snapshot.panes, using: client)
        // One extra round trip for the whole machine, because the state-change
        // stamps live on herdr's agent view and the snapshot's pane records do
        // not carry them. Without it every intervention would be unguarded.
        let stateSeqs = await readStateSeqs(using: client)
        agents = reconcile(
            snapshot.agents(on: machine.id, output: output, stateSeqs: stateSeqs)
        )
    }

    private func readStateSeqs(using client: any HerdrClient) async -> [String: UInt64] {
        guard let infos = try? await client.agents() else { return [:] }
        return Dictionary(
            infos.map { ($0.paneId, $0.stateChangeSeq) }, uniquingKeysWith: { first, _ in first }
        )
    }

    /// Fetch the output tail for every pane running an agent, concurrently.
    ///
    /// One round trip per pane, ~115ms each to a machine across a tunnel, so
    /// they go out together rather than in series. A pane that cannot be read
    /// simply has no entry and gets classified from its status alone — the
    /// classifier is built to degrade that way.
    private func readOutput(
        for panes: [HerdrPane],
        using client: any HerdrClient
    ) async -> [String: String] {
        let paneIds = panes
            .filter { $0.agent?.isEmpty == false }
            .map(\.paneId)
        guard !paneIds.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, String?).self) { group in
            for paneId in paneIds {
                group.addTask {
                    (paneId, try? await client.readPane(paneId: paneId, lines: 60))
                }
            }
            var result: [String: String] = [:]
            for await (paneId, text) in group {
                if let text { result[paneId] = text }
            }
            return result
        }
    }

    /// Carry dwell forward across refreshes.
    ///
    /// `stateEnteredAt` has to survive a resnapshot, or every refresh resets
    /// every timer and the panel reports that nothing has been waiting longer
    /// than one poll interval.
    private func reconcile(_ incoming: [Agent]) -> [Agent] {
        let previous = Dictionary(agents.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return incoming.map { agent in
            guard let old = previous[agent.ref], old.state == agent.state else { return agent }
            var carried = agent
            carried.stateEnteredAt = old.stateEnteredAt
            return carried
        }
    }

    // MARK: - Interventions

    /// Do something to one agent on this machine, or refuse and say why.
    ///
    /// The refusals are the substance of this method. A panel row is a
    /// photograph of an agent taken up to a refresh interval ago, and the
    /// keystroke it sends arrives later still — an approval answered from a
    /// stale row lands on whatever prompt replaced the one the user read.
    ///
    /// herdr offers no compare-and-swap to prevent that (it accepts an invented
    /// `expected_revision` field and ignores it), so the check happens here, in
    /// two parts, both re-read immediately before sending:
    ///
    /// 1. **The agent's state-change stamp must be unchanged.** This is what
    ///    catches the agent having answered, moved on, and stopped again.
    /// 2. **For an answer, the prompt must still name the same key.** The stamp
    ///    alone would let a keystroke through in the window before herdr has
    ///    noticed a new prompt, and the key is what the user actually chose.
    ///
    /// Neither check makes this atomic, and nothing available here could. They
    /// narrow the window from "a refresh interval" to "one round trip", and
    /// failing closed means the cost of losing the race is a message saying
    /// nothing was sent, not a `y` delivered to an unread question.
    public func perform(_ intervention: Intervention, on agentId: AgentID) async throws {
        guard let client else { throw InterventionError.agentGone }
        guard let index = agents.firstIndex(where: { $0.ref.agent == agentId }) else {
            throw InterventionError.agentGone
        }
        let agent = agents[index]
        guard agent.actions.allows(intervention) else { throw InterventionError.notOffered }

        switch intervention {
        case .approve, .deny:
            let key = intervention == .approve ? agent.actions.approveKey : agent.actions.denyKey
            guard let key else { throw InterventionError.notOffered }
            try await verifyUnmoved(agent, using: client)
            try await verifyPromptStillOffers(key, agent: agent, intervention: intervention, using: client)
            try await send { try await client.sendKeys(paneId: agentId.raw, keys: [key]) }

        case .interrupt:
            // No prompt check: interrupt does not depend on what the pane is
            // showing, only on there being something to stop. The stamp check
            // stays, so an agent that finished on its own is not interrupted
            // after the fact.
            try await verifyUnmoved(agent, using: client)
            try await send { try await client.interrupt(paneId: agentId.raw) }

        case .reveal:
            // No stamp check, and no prompt check. This is the one action that
            // sends nothing to the agent: focusing a pane that has moved on
            // shows the user what is actually there, which is the point. A
            // guard here would refuse precisely when looking is most useful.
            try await send { try await client.focusPane(paneId: agentId.raw) }

        case .nudge(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw InterventionError.notOffered }
            try await verifyUnmoved(agent, using: client)
            try await send { try await client.prompt(paneId: agentId.raw, text: trimmed) }

        case .reply(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw InterventionError.notOffered }

            // The stamp check, and nothing more. Approve can re-read the
            // prompt and confirm it still names the same key; a reply has no
            // key to re-verify, so an unchanged `state_change_seq` — meaning
            // this agent has not moved since the row was built — is the whole
            // guarantee. That is weaker than Approve's, and the reason to say
            // so here rather than let it read as equivalent.
            try await verifyUnmoved(agent, using: client)

            // One call, with the newline inside it. Sending the text and then
            // an Enter separately leaves a failure mode where the words land
            // and the submit does not, and the agent sits holding half an
            // instruction in its input.
            try await send {
                try await client.sendText(paneId: agentId.raw, text: trimmed + "\n")
            }
        }

        // The row should stop offering what it just did, without waiting for
        // herdr to notice and push an event.
        try? await resync()
    }

    /// Re-read the agent and require that it has not moved since the panel drew
    /// the row being acted on.
    private func verifyUnmoved(_ agent: Agent, using client: any HerdrClient) async throws {
        guard let info = try await client.agent(paneId: agent.ref.agent.raw) else {
            throw InterventionError.agentGone
        }
        // No stamp means the row was built from an event that carried none, and
        // an unguarded send is exactly what this method exists to prevent.
        guard let expected = agent.stateSeq else {
            throw InterventionError.stateMoved(was: agent.state, isNow: agent.state)
        }
        guard info.stateChangeSeq == expected else {
            throw InterventionError.stateMoved(
                was: agent.state,
                isNow: StateClassifier().classify(status: info.agentStatus).state
            )
        }
    }

    /// Re-read the pane and require that its prompt still names the key about
    /// to be pressed.
    private func verifyPromptStillOffers(
        _ key: String,
        agent: Agent,
        intervention: Intervention,
        using client: any HerdrClient
    ) async throws {
        let output = try? await client.readPane(paneId: agent.ref.agent.raw, lines: 60)
        let fresh = PromptAffordances().affordances(inRecentOutput: output)
        let offered = intervention == .approve ? fresh.approve : fresh.deny
        guard offered == key else { throw InterventionError.promptChanged }
    }

    /// Translate herdr's refusal into something a row can say.
    private func send(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch HerdrProtocolError.herdr(let code, let message) {
            if code == "agent_not_found" || code == "pane_not_found" {
                throw InterventionError.agentGone
            }
            throw InterventionError.refused(code: code, message: message)
        }
    }

    /// Whether a pane in this state is worth spending a read on.
    ///
    /// A blocked agent is waiting on something the user has to see, and a
    /// finished one may have finished by failing. A working one is just
    /// producing output, and reading it on every event would mean a round trip
    /// per line of agent chatter.
    static func warrantsOutputRead(_ status: String) -> Bool {
        switch status.lowercased() {
        case "blocked", "done", "finished", "idle", "exited", "dead": return true
        default: return false
        }
    }

    private func startEventLoop(_ client: any HerdrClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in client.events() {
                guard let self, !Task.isCancelled else { return }
                await self.apply(event)
            }
        }
    }

    private func apply(_ event: HerdrEvent) async {
        switch event {
        case .paneUpdated(let pane):
            // `data.pane` is the full pane record, so this patches in place.
            // Resnapshotting per event would cost a round trip each time —
            // ~115ms to a machine across an ssh tunnel — and a chatty agent
            // emits these continuously.
            //
            // The output read is the one round trip that remains, and it only
            // happens for a pane that has actually stopped: a working agent's
            // output changes constantly and nothing is waiting on it.
            var output: String?
            var stateSeq: UInt64?
            if pane.agent?.isEmpty == false, Self.warrantsOutputRead(pane.agentStatus) {
                output = try? await client?.readPane(paneId: pane.paneId, lines: 60)
                // Fetched exactly where the output is, and for the same reason:
                // these are the panes that have stopped and can therefore be
                // acted on. A working pane emits these events continuously and
                // offers nothing to answer, so it is not worth a round trip.
                stateSeq = try? await client?.agent(paneId: pane.paneId)?.stateChangeSeq
            }
            patch(pane, output: output, stateSeq: stateSeq)

        case .paneClosed(let paneId):
            agents.removeAll { $0.ref.agent.raw == paneId }

        case .topologyChanged:
            // Labels moved. These events carry no pane, and rebuilding a
            // rename from them is how label maps drift out of sync.
            try? await resync()

        case .connected:
            reachability = .connected

        case .disconnected:
            reachability = .reconnecting(attempt: 1)
        }
    }

    /// Apply one pane to the agent list, preserving dwell when the state has
    /// not actually changed.
    private func patch(_ pane: HerdrPane, output: String?, stateSeq: UInt64? = nil) {
        var outputs: [String: String] = [:]
        if let output { outputs[pane.paneId] = output }
        var stateSeqs: [String: UInt64] = [:]
        if let stateSeq { stateSeqs[pane.paneId] = stateSeq }

        let incoming = HerdrSnapshot(
            herdrVersion: herdrVersion ?? "",
            protocolVersion: 0,
            panes: [pane],
            workspaceNames: workspaceNames
        ).agents(on: machine.id, output: outputs, stateSeqs: stateSeqs)

        // A pane that stopped being an agent — the agent exited but the shell
        // lives on — drops out of the list rather than freezing on its last
        // state.
        guard let agent = incoming.first else {
            agents.removeAll { $0.ref.agent.raw == pane.paneId }
            return
        }

        if let index = agents.firstIndex(where: { $0.ref == agent.ref }) {
            var updated = agent
            if agents[index].state == agent.state {
                updated.stateEnteredAt = agents[index].stateEnteredAt
            }
            agents[index] = updated
        } else {
            agents.append(agent)
        }
    }
}
