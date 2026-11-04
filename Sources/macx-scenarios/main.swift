import Darwin
import Foundation

// Line-buffered so run-scenarios.sh (stdout is a pipe into tee) shows each PASS/FAIL line as it happens,
// and a trapping scenario does not swallow the lines before it.
setvbuf(stdout, nil, _IOLBF, 0)
Task { @MainActor in
    let code = await ScenarioCLI.main(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
RunLoop.main.run()
