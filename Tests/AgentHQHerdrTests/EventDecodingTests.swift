import AgentHQKit
import Foundation
import Testing
@testable import AgentHQHerdr

/// Decoding pinned to bytes captured off a live herdr 0.9.0 socket.
///
/// These are verbatim, not hand-written approximations. The failure this
/// guards against is silent: a decoder that matches the wrong envelope or the
/// wrong spelling returns nil for every event, the subscription still connects,
/// and the panel renders once and then never changes. Nothing errors.
@Suite("event decoding, against captured wire bytes")
struct EventDecodingTests {
    private func decode(_ json: String) -> HerdrEvent? {
        LiveHerdrClient.decodeEvent(Data(json.utf8))
    }

    @Test("pane_updated carries a full pane and patches in place")
    func paneUpdated() throws {
        let event = decode(#"""
        {"data": {"pane": {"agent": "claude", "agent_session": {"agent": "claude", "kind": "id", "source": "herdr:claude", "value": "b3f6779a"}, "agent_status": "working", "cwd": "/Users/j/dev/AgentHQ", "focused": true, "foreground_cwd": "/Users/j/dev/AgentHQ", "pane_id": "wB:p1", "revision": 52, "tab_id": "wB:t1", "terminal_id": "term_65b", "terminal_title": "◑ title", "terminal_title_stripped": "title", "workspace_id": "wB"}, "type": "pane_updated"}, "event": "pane_updated"}
        """#)

        guard case .paneUpdated(let pane) = try #require(event) else {
            Issue.record("expected .paneUpdated, got \(String(describing: event))")
            return
        }
        #expect(pane.paneId == "wB:p1")
        #expect(pane.agent == "claude")
        #expect(pane.agentStatus == "working")
        // `revision`, not `state_change_seq`. A protocol-17 spelling reads 0.
        #expect(pane.revision == 52)
        #expect(pane.cwd == "/Users/j/dev/AgentHQ")
    }

    @Test("focus events are topology, not agent state")
    func focusEvents() throws {
        // These carry ids only, no pane, so there is nothing to patch.
        #expect(decode(#"{"data": {"pane_id": "wQ:pB", "type": "pane_focused", "workspace_id": "wQ"}, "event": "pane_focused"}"#) == .topologyChanged)
        #expect(decode(#"{"data": {"type": "workspace_focused", "workspace_id": "wQ"}, "event": "workspace_focused"}"#) == .topologyChanged)
        #expect(decode(#"{"data": {"tab_id": "wQ:tB", "type": "tab_focused", "workspace_id": "wQ"}, "event": "tab_focused"}"#) == .topologyChanged)
    }

    @Test("a closed pane is identified by id")
    func paneClosed() throws {
        #expect(decode(#"{"data": {"pane_id": "wQ:pG", "type": "pane_closed"}, "event": "pane_closed"}"#)
                == .paneClosed(paneId: "wQ:pG"))
    }

    @Test("the subscription ack arrives on the event connection")
    func subscriptionAck() {
        #expect(decode(#"{"id":"1","result":{"type":"subscription_started"}}"#) == .connected)
    }

    @Test("event names are snake_case, not the dotted names used to subscribe")
    func spellingIsNotSymmetric() {
        // Subscribing asks for `pane.updated`; the event comes back as
        // `pane_updated`. Matching the subscription spelling drops everything.
        #expect(LiveHerdrClient.globalSubscriptions.contains("pane.updated"))
        #expect(decode(#"{"data": {"pane_id": "x", "type": "pane_closed"}, "event": "pane_closed"}"#) != nil)
        #expect(decode(#"{"data": {"pane_id": "x", "type": "pane.closed"}, "event": "pane.closed"}"#) == nil)
    }

    @Test("an unknown event is dropped, not guessed at")
    func unknownEvent() {
        #expect(decode(#"{"data": {"type": "plugin_did_something"}, "event": "plugin_did_something"}"#) == nil)
        #expect(decode("not json") == nil)
    }
}
