import AgentHQFleet
import AgentHQKit
import AgentHQTransport
import SwiftUI

@main
struct AgentHQApp: App {
    @State private var fleet = FleetStore()

    var body: some Scene {
        MenuBarExtra {
            PanelView(fleet: fleet)
                .task {
                    // Machines come from herdr's own registry, so adding one
                    // there is all the configuration there is.
                    fleet.importHerdrMachines(
                        includingLocal: LocalSocketTransport.resolveDefaultSocketPath()
                    )
                }
        } label: {
            MenuBarLabel(signal: fleet.signal)
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
