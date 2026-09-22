import AgentHQKit
import Observation

/// What the panel should scroll to when it opens.
///
/// A notification click is a request to look at one agent, and the panel is
/// built once and reused, so it cannot be told by being rebuilt. `nonce` makes
/// two clicks on the same agent two distinct events rather than one no-op.
@MainActor
@Observable
final class PanelFocus {
    private(set) var ref: AgentRef?
    private(set) var nonce = 0

    func focus(_ ref: AgentRef?) {
        self.ref = ref
        nonce &+= 1
    }
}
