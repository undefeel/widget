import Foundation

@main
enum ProcessHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        let huge = String(repeating: "x", count: 8_000_000)
        let closed = Shell.run("/bin/sh", ["-c", "exec 0<&-; printf closed"], input: huge, timeout: 3)
        expect(closed == "closed", "closed stdin with a large input must not terminate the caller")

        let drained = Shell.run("/bin/sh", ["-c", "head -c 500000 /dev/zero | tr '\\000' x"], timeout: 5)
        expect(drained.count == 500_000, "ordinary stdout must drain completely")

        let timedStart = ProcessInfo.processInfo.systemUptime
        let timed = Shell.run("/bin/sh", ["-c", "sleep 5"], timeout: 0.15)
        expect(ProcessInfo.processInfo.systemUptime - timedStart < 1.5, "timeout cleanup must be bounded")
        expect(timed.isEmpty, "timeout child should not fabricate output")

        let pidOutput = Shell.run("/bin/sh", ["-c", "trap '' TERM; echo $$; exec sleep 5"], timeout: 0.15)
        if let pid = pidOutput.split(separator: "\n").first.flatMap({ Int32($0) }) {
            expect(kill(pid, 0) == -1 && errno == ESRCH, "timed-out direct child must be reaped")
        } else { expect(false, "timeout probe must report its child pid") }

        let earlyStart = ProcessInfo.processInfo.systemUptime
        let early = Shell.run("/bin/sh", ["-c", "printf 'ready\\n'; sleep 5"], timeout: 5) { text in
            text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().contains("ready")
        }
        expect(early == "ready\n", "early stop must retain the matching complete line")
        expect(ProcessInfo.processInfo.systemUptime - earlyStart < 1.5, "early-stop cleanup must be bounded")

        let fdCount = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
        for _ in 0..<20 {
            _ = Shell.run("/bin/sh", ["-c", "printf x"], timeout: 1)
        }
        let fdAfter = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? fdCount
        expect(fdAfter <= fdCount + 1, "repeated subprocess runs must not leak descriptors")

        let sentinel = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ailimits-shell-lookup-\(UUID().uuidString)")
        let hostile = "sh; touch \(sentinel.path)"
        _ = CLI.find(hostile)
        expect(!FileManager.default.fileExists(atPath: sentinel.path), "lookup argument must not execute shell syntax")
        expect(CLI.find("sh") != nil, "known command lookup must work")

        let valid = CodexFetcher.replies([
            #"{"id":1,"result":{"ok":true}}"#,
            #"{ "result" : {}, "id" : 1 }"#,
            #"{"error":{"message":"denied"},"id":1}"#,
        ].joined(separator: "\n") + "\n")
        expect(valid.count == 3, "id-first, id-last and error replies must be recognized")
        let invalid = CodexFetcher.replies([
            #"{"id":2,"result":{}}"#,
            #"{"method":"notification"}"#,
            #"{"id":true,"result":{}}"#,
            #"{not json}"#,
        ].joined(separator: "\n") + "\n" + #"{"id":1,"result":{}}"#)
        expect(invalid.isEmpty, "unrelated, notification, boolean-id, malformed and partial messages must be ignored")
        print("Process harness passed")
    }
}
