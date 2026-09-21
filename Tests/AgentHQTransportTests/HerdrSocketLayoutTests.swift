import Foundation
import Testing
@testable import AgentHQTransport

@Suite("herdr socket layout")
struct HerdrSocketLayoutTests {
    @Test("the default session sits directly in the config directory")
    func defaultSession() {
        #expect(HerdrSocketLayout.socketPath(configDirectory: "/home/u/.config", session: "default")
                == "/home/u/.config/herdr/herdr.sock")
        #expect(HerdrSocketLayout.socketPath(configDirectory: "/home/u/.config", session: "")
                == "/home/u/.config/herdr/herdr.sock")
    }

    @Test("a named session gets its own directory")
    func namedSession() {
        #expect(HerdrSocketLayout.socketPath(configDirectory: "/home/u/.config", session: "work")
                == "/home/u/.config/herdr/sessions/work/herdr.sock")
    }

    @Test("a trailing slash on the config directory does not double up")
    func trailingSlash() {
        #expect(HerdrSocketLayout.socketPath(configDirectory: "/home/u/.config/", session: "default")
                == "/home/u/.config/herdr/herdr.sock")
    }

    @Test("an XDG config directory is used as given")
    func xdgDirectory() {
        #expect(HerdrSocketLayout.socketPath(configDirectory: "/opt/cfg", session: "default")
                == "/opt/cfg/herdr/herdr.sock")
    }

    @Test("the result is always absolute")
    func neverATilde() {
        // `ssh -L` does not expand `~` in the remote half of a forward spec and
        // fails with nothing useful in stderr when given one. A path built here
        // must never contain a tilde.
        for session in ["default", "work", ""] {
            let path = HerdrSocketLayout.socketPath(configDirectory: "/home/u/.config", session: session)
            #expect(path.hasPrefix("/"))
            #expect(!path.contains("~"))
        }
    }
}
