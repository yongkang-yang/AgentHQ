import AgentHQKit
import Foundation

/// Where the dwell figures survive a restart.
///
/// A small JSON file rather than UserDefaults: it is a few hundred rows of
/// per-agent state, it is regenerated from scratch if it goes missing, and a
/// file can be deleted by hand when it says something wrong.
public actor DwellStore {
    private let url: URL
    private var latestRevision: UInt64 = 0

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    public static func defaultURL(
        home: String = NSHomeDirectory()
    ) -> URL {
        URL(fileURLWithPath: "\(home)/Library/Application Support/AgentHQ/dwell.json")
    }

    public func load() -> [DwellRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A file we cannot read is a file we ignore. Every dwell figure is
        // recoverable by waiting; none of it is worth an error the user has to
        // care about.
        return (try? decoder.decode([DwellRecord].self, from: data)) ?? []
    }

    /// Replace records for machines we actually reached. A failed tunnel does
    /// not prove that its agents disappeared, so its last known clocks stay.
    public func save(_ snapshot: FleetSnapshot, revision: UInt64) {
        guard revision > latestRevision else { return }
        latestRevision = revision

        var byMachine = Dictionary(grouping: load(), by: \.machine)
        var reachedAnyMachine = false
        for view in snapshot.machines where view.reachability.isConnected {
            reachedAnyMachine = true
            byMachine[view.machine.id.raw] = DwellMemory.records(for: view.agents)
        }
        guard reachedAnyMachine else { return }

        let records = byMachine.values.flatMap { $0 }.sorted {
            ($0.machine, $0.agent) < ($1.machine, $1.agent)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        if (try? Data(contentsOf: url)) == data { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic: a half-written file on a crash would be read back as
        // nonsense, and nonsense here is a fabricated waiting time.
        try? data.write(to: url, options: .atomic)
    }
}
