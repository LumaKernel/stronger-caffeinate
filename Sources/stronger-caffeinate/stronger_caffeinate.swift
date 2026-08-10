import ArgumentParser
import Foundation
import IOKit.pwr_mgt

@main
struct StrongerCaffeinate: ParsableCommand {
    static let version = "2.0.0"

    static let configuration = CommandConfiguration(
        commandName: "stronger-caffeinate",
        abstract: "Prevent sleep using strong IOPMAssertion (NoDisplaySleep / NoIdleSleep).",
        discussion: """
            Unlike caffeinate which uses PreventUserIdle* (weak) assertions,
            this tool uses NoDisplaySleep / NoIdleSleep (strong) assertions
            that provide stronger sleep prevention guarantees.

            Without any flags, defaults to -d -i (both display and idle sleep prevention).
            """,
        version: version
    )

    @Flag(name: .shortAndLong, help: "Prevent display sleep (NoDisplaySleep).")
    var display = false

    @Flag(name: .shortAndLong, help: "Prevent idle sleep (NoIdleSleep).")
    var idle = false

    @Flag(name: .shortAndLong, help: "Prevent system sleep (PreventSystemSleep).")
    var system = false

    @Option(name: .shortAndLong, help: "Timeout in seconds.")
    var timeout: Int?

    @Argument(help: "Command to run (assertion held until it exits).")
    var command: [String] = []

    func run() throws {
        let useDisplay: Bool
        let useIdle: Bool
        let useSystem: Bool

        if !display && !idle && !system {
            // Default: both display and idle
            useDisplay = true
            useIdle = true
            useSystem = false
        } else {
            useDisplay = display
            useIdle = idle
            useSystem = system
        }

        var assertions: [Assertion] = []

        if useDisplay {
            assertions.append(
                try Assertion.create(
                    type: kIOPMAssertionTypeNoDisplaySleep as CFString,
                    reason: "stronger-caffeinate: prevent display sleep"
                )
            )
        }
        if useIdle {
            assertions.append(
                try Assertion.create(
                    type: kIOPMAssertionTypeNoIdleSleep as CFString,
                    reason: "stronger-caffeinate: prevent idle sleep"
                )
            )
        }
        if useSystem {
            assertions.append(
                try Assertion.create(
                    type: "PreventSystemSleep" as CFString,
                    reason: "stronger-caffeinate: prevent system sleep"
                )
            )
        }

        let assertionNames = assertions.map(\.name).joined(separator: ", ")
        print("Assertions active: \(assertionNames)")

        defer {
            for assertion in assertions {
                assertion.release()
            }
            print("\nAssertions released.")
        }

        setupSignalHandler()

        if !command.isEmpty {
            let exitCode = runChildProcess(command)
            throw ExitCode(exitCode)
        } else if let timeout {
            print("Timeout: \(timeout)s. Ctrl+C to cancel.")
            sleep(UInt32(timeout))
        } else {
            print("Running until Ctrl+C...")
            sigsuspend(nil)
        }
    }
}

struct Assertion: Sendable {
    let id: IOPMAssertionID
    let name: String

    static func create(type: CFString, reason: String) throws -> Assertion {
        var assertionID: IOPMAssertionID = 0
        let ret = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard ret == kIOReturnSuccess else {
            throw ValidationError("Failed to create assertion '\(type)': IOReturn \(ret)")
        }
        return Assertion(id: assertionID, name: type as String)
    }

    func release() {
        IOPMAssertionRelease(id)
    }
}

private nonisolated(unsafe) var childPID: pid_t = 0

private func setupSignalHandler() {
    signal(SIGINT, SIG_DFL)
    signal(SIGTERM, SIG_DFL)
}

private func forwardSignalHandler(_: Int32) {
    if childPID > 0 {
        kill(childPID, SIGINT)
    }
}

private func forwardTermHandler(_: Int32) {
    if childPID > 0 {
        kill(childPID, SIGTERM)
    }
}

private func runChildProcess(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments

    do {
        try process.run()
    } catch {
        print("Failed to start process: \(error)")
        return 1
    }

    childPID = process.processIdentifier
    signal(SIGINT, forwardSignalHandler)
    signal(SIGTERM, forwardTermHandler)

    process.waitUntilExit()
    return process.terminationStatus
}
