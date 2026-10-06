import Foundation
import Testing
@testable import AgentHQKit

@Suite("A directory typed into New agent")
struct LaunchDirectoryTests {
    @Test("an absolute path is looked up in single quotes")
    func absolute() {
        #expect(LaunchDirectory.script(for: " /home/me/my project ") == "cd -- '/home/me/my project' && pwd -P")
    }

    @Test("~ is the remote user's home, expanded by the remote shell")
    func home() {
        #expect(LaunchDirectory.script(for: "~") == #"cd -- "$HOME" && pwd -P"#)
        #expect(LaunchDirectory.script(for: "~/dev/app") == #"cd -- "$HOME"/'dev/app' && pwd -P"#)
    }

    @Test("a quote in the path cannot end the quoting")
    func quoteEscaped() {
        #expect(LaunchDirectory.script(for: "/tmp/it's; rm -rf ~") == #"cd -- '/tmp/it'\''s; rm -rf ~' && pwd -P"#)
    }

    @Test("relative paths, ~user and multi-line text get no script")
    func refused() {
        for typed in ["", "   ", "dev/app", "~other/app", "/tmp\nrm -rf /"] {
            #expect(LaunchDirectory.script(for: typed) == nil)
        }
    }

    @Test("the resolved directory is the last absolute line the machine printed")
    func resolved() {
        #expect(LaunchDirectory.resolved(from: Data("motd noise\n/home/me/app\n".utf8)) == "/home/me/app")
        #expect(LaunchDirectory.resolved(from: Data("".utf8)) == nil)
    }

    @Test("the workspace is labelled with the directory's name")
    func label() {
        #expect(LaunchDirectory.label(for: "/home/me/app") == "app")
        #expect(LaunchDirectory.label(for: "/") == "/")
    }
}
