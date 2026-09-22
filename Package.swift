// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHQ",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentHQApp", targets: ["AgentHQApp"]),
        .library(name: "AgentHQKit", targets: ["AgentHQKit"]),
    ],
    targets: [
        // Domain model. No I/O, no Foundation-beyond-value-types, no knowledge
        // of herdr or SSH. Everything above depends on this; it depends on
        // nothing. If a type here needs a socket, it is in the wrong target.
        .target(name: "AgentHQKit"),

        // How bytes reach a herdr socket: directly, or through an `ssh -L`
        // unix-socket forward. Both resolve to a local socket path, which is
        // the whole point — AgentHQHerdr never learns which one it got.
        .target(name: "AgentHQTransport", dependencies: ["AgentHQKit"]),

        // The herdr wire protocol. Knows one socket path and nothing about
        // fleets, machines, or SSH. Largely a port from Shepherd (MIT).
        .target(name: "AgentHQHerdr", dependencies: ["AgentHQKit"]),

        // One MachineSession per machine; aggregation across them. All the
        // multi-machine complexity lives here and nowhere else.
        .target(
            name: "AgentHQFleet",
            dependencies: ["AgentHQKit", "AgentHQTransport", "AgentHQHerdr"]
        ),

        .executableTarget(name: "AgentHQApp", dependencies: ["AgentHQFleet"]),

        .testTarget(name: "AgentHQKitTests", dependencies: ["AgentHQKit"]),
        .testTarget(name: "AgentHQHerdrTests", dependencies: ["AgentHQHerdr"]),
        .testTarget(name: "AgentHQTransportTests", dependencies: ["AgentHQTransport"]),
        .testTarget(name: "AgentHQFleetTests", dependencies: ["AgentHQFleet"]),
        .testTarget(name: "AgentHQAppTests", dependencies: ["AgentHQApp"]),
    ]
)
