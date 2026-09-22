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
    private var supervisorTask: Task<Void, Never>?

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

    /// How often the supervisor looks at a machine that is not working.
    ///
    /// Injected for the same reason the client factory is: the supervisor's
    /// whole job happens on a timer, and a test that had to sleep out the real
    /// interval could not assert on it at all.
    private let supervisionInterval: Duration

    /// The ceiling the supervisor's backoff grows to while a machine keeps
    /// refusing. Relaunching `ssh` every few seconds against a host that is
    /// not there costs a process spawn and a name lookup per attempt, forever.
    private var maxSupervisionInterval: Duration { supervisionInterval * 10 }

    /// True while a rebuild is out on the network, so a supervisor tick that
    /// fires mid-rebuild does not start a second one.
    private var isRebuilding = false

    /// Bumped by anything that invalidates a connection attempt already in
    /// flight. A `stop` or a rebuild can overtake an `activate` that is still
    /// waiting on `ssh`, and the attempt that lands second must not install its
    /// client over the decision that overtook it.
    private var generation: UInt64 = 0

    /// Entry times remembered from a previous launch, applied once when this
    /// machine's herd is first read.
    private var restorableDwell: [DwellRecord] = []
    private var hasRestoredDwell = false

    /// Whether the agent list has been rebuilt since the event subscription
    /// last came up. See ``apply(_:)``'s `.connected` case.
    private var hasSyncedSinceConnect = false

    /// Runs this session watched end, and that the user has not looked at yet.
    ///
    /// AgentHQ's own copy of the bookkeeping herdr calls `done`. It needs one
    /// because herdr's `done` means "completed **and unseen**" by *herdr's*
    /// reckoning, and for a pane the user has focused there it is already
    /// seen — measured here, a run in a focused pane went `working` (seq 50)
    /// → `idle` (seq 51) and never reported `done` at all. Waiting for
    /// `done` left those runs in Idle forever.
    ///
    /// herdr's own docs say each client tracks viewed completions
    /// independently, so this is the arrangement it expects of a client, not
    /// a second opinion about the same fact. Nothing is fabricated: the
    /// transition out of `working` is something this session watched happen.
    private var completedUnseen: Set<AgentID> = []

    public init(
        machine: Machine,
        makeClient: @escaping ClientFactory = { LiveHerdrClient(socketPath: $0) },
        transport: (any Transport)? = nil,
        supervisionInterval: Duration = .seconds(3)
    ) {
        self.machine = machine
        self.transport = transport ?? machine.transport.makeTransport(for: machine.id)
        self.reachability = machine.isEnabled ? .connecting : .disabled
        self.makeClient = makeClient
        self.supervisionInterval = supervisionInterval
    }

    /// Hand this machine the dwell figures from last launch, before it starts.
    public func prime(dwell records: [DwellRecord]) {
        restorableDwell = records.filter { $0.ref.machine == machine.id }
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
            supervisorTask?.cancel()
            supervisorTask = nil
            return
        }
        startSupervisor()
        await connect()
    }

    public func stop() async {
        supervisorTask?.cancel()
        supervisorTask = nil
        await teardown()
        reachability = machine.isEnabled ? .connecting : .disabled
        // Agents are kept, not cleared: the last known list is what the UI
        // shows as stale. Clearing it would make a dropped tunnel look like
        // every agent vanished.
    }

    /// Bring the transport up, speak herdr over it, and start listening.
    private func connect() async {
        reachability = .connecting
        generation &+= 1
        let attempt = generation

        do {
            let socketPath = try await transport.activate()
            let client = makeClient(socketPath)
            let handshake = try await client.handshake()
            try await client.connect()

            // `activate` can sit on `ssh` for twenty seconds, and a `stop` or a
            // second rebuild can land inside that window. Installing this
            // client now would leave a live subscription and a `connected`
            // badge behind a session that has already been told to go down.
            guard attempt == generation else {
                await client.disconnect()
                return
            }

            self.client = client
            self.herdrVersion = handshake.version
            reachability = .connected
            try await resync()
            hasSyncedSinceConnect = true
            startEventLoop(client)
        } catch {
            guard attempt == generation else { return }
            // The reason is shown verbatim in the panel. Transport errors
            // already read as sentences ("build-box accepted the tunnel but
            // nothing is listening on …"), which is why they are not wrapped
            // into a generic "connection failed" here.
            reachability = .unreachable(reason: String(describing: error))
        }
    }

    /// Drop the live connection without touching the supervisor, which has to
    /// outlive the thing it supervises.
    private func teardown() async {
        generation &+= 1
        eventTask?.cancel()
        eventTask = nil
        hasSyncedSinceConnect = false
        await client?.disconnect()
        client = nil
        await transport.deactivate()
    }

    // MARK: - Supervision

    /// What one supervisor tick did, which is all the loop needs to know to
    /// decide how long to wait before the next one.
    private enum Supervision {
        /// The machine is working, or is already being dealt with.
        case nothingToDo
        /// A rebuild put the machine back.
        case recovered
        /// A rebuild was tried and the machine still is not answering.
        case failed
    }

    /// Watch this machine for as long as it is enabled, and rebuild it when
    /// the thing underneath its socket has gone away.
    ///
    /// This is the only thing in the app that calls `activate` more than once,
    /// and without it a machine reached over `ssh` never comes back from a
    /// network change. The failure is worth spelling out, because every part
    /// of it looks like it is working:
    ///
    /// The Mac changes networks. `ssh` notices through `ServerAliveCountMax`
    /// and exits, taking the forwarded socket with it. The subscription's read
    /// ends, so the client backs off and resubscribes — to a path with nothing
    /// behind it, forever, at a ten-second ceiling. The session reports
    /// `reconnecting`, honestly and permanently, because `activate` ran once
    /// inside `start` and nothing was ever going to run it again. The far side
    /// coming back changes none of this: there is no `ssh` left to carry it.
    /// Quitting and relaunching was the only recovery, which is exactly how it
    /// was found.
    private func startSupervisor() {
        guard supervisorTask == nil else { return }
        let interval = supervisionInterval
        let ceiling = maxSupervisionInterval
        supervisorTask = Task { [weak self] in
            var wait = interval
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                switch await self.superviseOnce() {
                case .failed:
                    wait = min(wait * 2, ceiling)
                case .nothingToDo, .recovered:
                    wait = interval
                }
            }
        }
    }

    /// One look at the machine.
    private func superviseOnce() async -> Supervision {
        guard machine.isEnabled, !isRebuilding else { return .nothingToDo }

        switch reachability {
        case .disabled, .connecting, .connected:
            // `connecting` included: a rebuild or a first connect is already
            // out on the network, and a second one would race it.
            return .nothingToDo

        case .reconnecting:
            // The client resubscribes on its own, and where the socket still
            // has a herdr behind it that is both cheaper and faster than
            // anything here — a herd restarting on the far side recovers
            // without the tunnel being touched. What it cannot recover from is
            // the socket having no server at all, which is the only case this
            // takes over.
            if await transport.isHealthy() { return .nothingToDo }

        case .unreachable:
            // Nothing else retries this. A machine that was down when AgentHQ
            // launched stayed down until the user pressed Retry.
            break
        }

        isRebuilding = true
        defer { isRebuilding = false }
        await teardown()
        await connect()
        return reachability.isConnected ? .recovered : .failed
    }

    /// Pull a full snapshot and replace the agent list.
    public func resync() async throws {
        guard let client else { return }
        let snapshot = try await client.snapshot()
        workspaceNames = snapshot.workspaceNames
        let output = await readOutput(for: snapshot.panes, using: client)
        // One extra round trip for the whole machine, because herdr's agent
        // view carries two things the snapshot's pane records do not: the
        // state-change stamps, without which every intervention is unguarded,
        // and a `done` status, without which no agent ever reads as finished.
        let agentViews = await readAgentViews(using: client)
        var incoming = snapshot.agents(on: machine.id, output: output, agentViews: agentViews)
        if !hasRestoredDwell, !incoming.isEmpty {
            incoming = DwellMemory.restore(incoming, from: restorableDwell)
            hasRestoredDwell = true
            restorableDwell = []
        }
        let previous = Dictionary(agents.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        agents = reconcile(applyCompletions(incoming, previous: previous))
    }

    private func readAgentViews(using client: any HerdrClient) async -> [String: HerdrAgentInfo] {
        guard let infos = try? await client.agents() else { return [:] }
        return Dictionary(infos.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// Promote a run this session watched finish, so it reads as completed
    /// rather than as an agent that happens to be sitting idle.
    ///
    /// Dropped again the moment the row is anything but idle — a new turn, a
    /// prompt, a crash — and when the user acts on it, which is what
    /// ``markSeen(_:)`` is for.
    private func applyCompletions(_ incoming: [Agent], previous: [AgentRef: Agent]) -> [Agent] {
        incoming.map { agent in
            let wasWorking = previous[agent.ref]?.state == .working
            if wasWorking, agent.state == .idle {
                completedUnseen.insert(agent.ref.agent)
            } else if agent.state != .idle, agent.state != .finished {
                completedUnseen.remove(agent.ref.agent)
            }
            guard agent.state == .idle, completedUnseen.contains(agent.ref.agent) else {
                return agent
            }
            var promoted = agent
            promoted.state = .finished
            return promoted
        }
    }

    /// Forget that a run was waiting to be looked at.
    ///
    /// Called for every intervention, not only Reveal. Any of them means the
    /// user has this row in front of them and has dealt with it; leaving it in
    /// Completed afterwards is the same staleness `done` would have had if
    /// herdr never cleared it.
    private func markSeen(_ agentId: AgentID) {
        completedUnseen.remove(agentId)
    }

    /// Carry dwell forward across refreshes.
    ///
    /// `stateEnteredAt` has to survive an unchanged resnapshot, or every
    /// refresh resets every timer. The sequence also has to agree: an agent
    /// can leave a state and return to it between snapshots.
    private func reconcile(_ incoming: [Agent]) -> [Agent] {
        let previous = Dictionary(agents.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return incoming.map { agent in
            guard let old = previous[agent.ref],
                  old.state == agent.state,
                  old.stateSeq == agent.stateSeq
            else { return agent }
            var carried = agent
            carried.stateEnteredAt = old.stateEnteredAt
            return carried
        }
    }

    /// The pane's recent output, verbatim, for a reader rather than the
    /// classifier.
    ///
    /// Read on demand instead of carried on every ``Agent``: the steady-state
    /// refresh already reads 60 wrapped lines per stopped pane to classify it,
    /// and widening that to something worth reading would multiply the cost of
    /// every poll — on a tunnelled machine, per pane, forever — to populate a
    /// view almost no row is showing.
    public func transcript(for agentId: AgentID, lines: Int = 200) async throws -> String {
        guard let client else { throw InterventionError.agentGone }
        let text = try await client.readPane(
            paneId: agentId.raw, lines: lines, source: .recentUnwrapped
        )
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterventionError.agentGone
        }
        return text
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

        case .end:
            try await endConversation(agent, using: client)

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

        markSeen(agentId)

        // The row should stop offering what it just did, without waiting for
        // herdr to notice and push an event.
        try? await resync()
    }

    /// Quit the agent, taking every key from the pane rather than from a table
    /// of which agent is running.
    ///
    /// No stamp check, for the same reason ``Intervention/reveal`` has none:
    /// the target is a pane id, and ending *this* conversation means the same
    /// thing whatever state it happens to be in. Refusing because the agent
    /// finished a second ago would refuse precisely when ending is most
    /// obviously right. The confirmation the panel shows is the guard here.
    ///
    /// Three steps, each one reading before it presses:
    ///
    /// 1. **Ask the pane what exits it.** pi's own footer says
    ///    `ctrl+c/ctrl+d clear/exit` — two parallel lists, in which `ctrl+c`
    ///    is *clear* and `ctrl+d` is exit. An agent that names its exit key
    ///    gets that key, once, and is done.
    /// 2. **Otherwise press `C-c` and look again.** This is the two-step
    ///    gesture, and the second step is only taken because the pane asked
    ///    for it — Claude Code answers the first press with "Press Ctrl-C
    ///    again to exit", and that sentence is the authority for pressing it
    ///    again. Not a count, and not a rule about which agent this is.
    /// 3. **Where nothing was offered, stop and say so.** One `C-c` has
    ///    landed by then and cannot be taken back, so the refusal names what
    ///    was sent instead of claiming nothing happened.
    private func endConversation(_ agent: Agent, using client: any HerdrClient) async throws {
        let paneId = agent.ref.agent.raw
        let affordances = PromptAffordances()

        let before = try? await client.readPane(paneId: paneId, lines: 60)
        if let named = affordances.exitKey(inRecentOutput: before),
           named != PromptAffordances.defaultInterruptKey {
            try await send { try await client.sendKeys(paneId: paneId, keys: [named]) }
            return
        }

        let first = PromptAffordances.defaultInterruptKey
        try await send { try await client.sendKeys(paneId: paneId, keys: [first]) }

        // The agent needs a moment to redraw before it can be asked whether it
        // is offering to exit. Reading instantly would read the pane as it was
        // before the key landed and conclude, wrongly, that nothing was
        // offered — then say so, having half-quit the agent.
        try? await Task.sleep(for: .milliseconds(400))
        let after = try? await client.readPane(paneId: paneId, lines: 60)
        guard let again = affordances.exitConfirmationKey(inRecentOutput: after)
                ?? affordances.exitKey(inRecentOutput: after)
        else {
            throw InterventionError.exitNotConfirmed(sent: first)
        }
        try await send { try await client.sendKeys(paneId: paneId, keys: [again]) }
    }

    /// Re-read the agent and require that it has not moved since the panel drew
    /// the row being acted on.
    private func verifyUnmoved(_ agent: Agent, using client: any HerdrClient) async throws {
        guard let info = try await client.agent(paneId: agent.ref.agent.raw) else {
            throw InterventionError.agentGone
        }
        // No stamp means the row was built from an event that carried none and
        // the agent view could not be reached to supply one, so there is
        // nothing to compare against. An unguarded send is exactly what this
        // method exists to prevent, so it still refuses — but it says it
        // could not check, rather than claiming a move it did not observe.
        guard let expected = agent.stateSeq else {
            throw InterventionError.unverifiable
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
            var view: HerdrAgentInfo?
            if pane.agent?.isEmpty == false {
                let hasStopped = Self.warrantsOutputRead(pane.agentStatus)
                let moved = hasMoved(pane)
                if hasStopped {
                    output = try? await client?.readPane(paneId: pane.paneId, lines: 60)
                }
                // The agent view is fetched for a stopped pane, and for any
                // pane whose state has just changed.
                //
                // Stopped, because the pane record cannot say `done` — it
                // spells a finished run `idle`, and this call is the only
                // thing on this path that tells the two apart.
                //
                // Changed, because the stamp lives only on the agent view, and
                // a row rebuilt without one cannot be acted on at all: the
                // guard in `perform` fails closed on a nil stamp, by design.
                // Fetching only for stopped panes meant an agent that had just
                // *started* working had no stamp until the next full resync —
                // so Stop refused, and said "it moved from working to working
                // first", for the entire window in which anyone wants to press
                // Stop.
                //
                // This is O(state changes), not O(events), which is what makes
                // it affordable. A working agent emits `pane_updated`
                // continuously as it writes output, and those carry the status
                // it already has: they compare equal here and cost nothing.
                if hasStopped || moved {
                    view = try? await client?.agent(paneId: pane.paneId)
                }
            }
            patch(pane, output: output, view: view)

        case .paneClosed(let paneId):
            agents.removeAll { $0.ref.agent.raw == paneId }

        case .topologyChanged:
            // Labels moved. These events carry no pane, and rebuilding a
            // rename from them is how label maps drift out of sync.
            try? await resync()

        case .connected:
            reachability = .connected
            // A reconnect, not a first connect: the subscription thread drops
            // its socket, backs off and resubscribes on its own, and herdr
            // does not replay what happened while it was gone. Every state
            // change in that window is simply missing, and nothing else ever
            // refetches — `resync` otherwise runs only at start, on a topology
            // event, and after an intervention, so the list stays frozen at
            // whatever it held when the socket dropped while the machine goes
            // on reporting itself connected.
            //
            // That is the shape of "only the local machine updates": a unix
            // socket on this Mac effectively never drops, and an `ssh -L`
            // forward to another host does.
            if !hasSyncedSinceConnect {
                try? await resync()
                hasSyncedSinceConnect = true
            }

        case .disconnected:
            hasSyncedSinceConnect = false
            reachability = .reconnecting(attempt: nextReconnectAttempt())
        }
    }

    /// The attempt number to report while the subscription is down.
    ///
    /// Counted, not hardcoded to 1. It was written as `attempt: 1`, so a
    /// machine that had been retrying for ten minutes said "reconnecting
    /// (attempt 1)" — a number the panel presented as measured and that was
    /// invented on every drop.
    private func nextReconnectAttempt() -> Int {
        if case .reconnecting(let attempt) = reachability { return attempt + 1 }
        return 1
    }

    /// Whether this pane record disagrees with the state the list is holding
    /// for it.
    ///
    /// Compared as classified states rather than as raw status strings,
    /// because the two vocabularies do not line up: a pane says `idle` for a
    /// run the list is holding as `finished`. Comparing the strings would call
    /// every such event a change and spend a round trip on it.
    private func hasMoved(_ pane: HerdrPane) -> Bool {
        guard let current = agents.first(where: { $0.ref.agent.raw == pane.paneId }) else {
            // New to the list. One round trip to start it off with a stamp is
            // the same cost the next resync would pay anyway.
            return true
        }
        return StateClassifier().classify(status: pane.agentStatus).state != current.state
    }

    /// Apply one pane to the agent list, preserving dwell when the state has
    /// not actually changed.
    private func patch(_ pane: HerdrPane, output: String?, view: HerdrAgentInfo? = nil) {
        var outputs: [String: String] = [:]
        if let output { outputs[pane.paneId] = output }
        var views: [String: HerdrAgentInfo] = [:]
        if let view { views[pane.paneId] = view }

        let decoded = HerdrSnapshot(
            herdrVersion: herdrVersion ?? "",
            protocolVersion: 0,
            panes: [pane],
            workspaceNames: workspaceNames
        ).agents(on: machine.id, output: outputs, agentViews: views)

        let previous = Dictionary(agents.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        let incoming = applyCompletions(decoded, previous: previous)

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
                let old = agents[index]
                if agent.stateSeq == nil || agent.stateSeq == old.stateSeq {
                    // Working-pane events have no stamp. Keep the last one
                    // until a full resync or stopped-pane read can compare it.
                    updated.stateEnteredAt = old.stateEnteredAt
                    if updated.stateSeq == nil { updated.stateSeq = old.stateSeq }
                }
            }
            agents[index] = updated
        } else {
            agents.append(agent)
        }
    }
}
