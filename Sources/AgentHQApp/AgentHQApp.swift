import AgentHQFleet
import AgentHQKit
import AgentHQTransport
import SwiftUI

@main
struct AgentHQApp: App {
    @State private var fleet = FleetStore()
    @State private var notifier = Notifier()

    var body: some Scene {
        MenuBarExtra {
            PanelView(fleet: fleet, notifier: notifier)
        } label: {
            MenuBarLabel(signal: fleet.signal)
                // Startup hangs off the label, not the panel and not `init`.
                // The panel only exists while it is open, so a bar that waited
                // for it would stay blank until clicked — which is the one
                // moment the bar is supposed to already know the answer. And
                // `App.init` runs before SwiftUI installs the @State, so work
                // started there can act on an instance the views never observe.
                .task {
                    notifier.prepare()
                    fleet.onAnnouncements = { [notifier] batch in
                        notifier.deliver(batch)
                    }
                    fleet.start(
                        localSocketPath: LocalSocketTransport.resolveDefaultSocketPath()
                    )
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The glance. Worst state wins, and a degraded fleet says so rather than
/// quietly reporting on the machines it can still see.
struct MenuBarLabel: View {
    let signal: FleetSignal

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if signal.attentionCount > 0 {
                Text("\(signal.attentionCount)")
            }
            if signal.isDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
    }

    private var symbol: String {
        guard let top = signal.topState else { return "circle.dashed" }
        switch top {
        case .crashed:       return "exclamationmark.octagon.fill"
        case .needsApproval: return "hand.raised.fill"
        case .needsInput:    return "questionmark.circle.fill"
        case .mergeConflict: return "arrow.triangle.branch"
        case .ciFailed:      return "xmark.diamond.fill"
        case .rateLimited:   return "hourglass"
        case .finished:      return "checkmark.circle.fill"
        case .working:       return "circle.fill"
        case .unknown:       return "circle.dashed"
        }
    }
}
