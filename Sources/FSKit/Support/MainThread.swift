import Foundation

/// Debug builds: preconditionFailure if called on the main thread. Release: no-op.
/// Called at the top of every MacxFS/Core function that makes a blocking file-system call (§4.4).
public func assertOffMain(_ function: StaticString = #function, file: StaticString = #fileID, line: UInt = #line) {
    #if DEBUG
    if Thread.isMainThread {
        preconditionFailure("\(function) must not run on the main thread (§4.4 main-thread rule)", file: file, line: line)
    }
    #endif
}
