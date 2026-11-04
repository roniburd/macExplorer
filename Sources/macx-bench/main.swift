import Foundation

Task { @MainActor in
    let code = await BenchCLI.run(Array(CommandLine.arguments.dropFirst()))
    exit(code)
}
RunLoop.main.run()
