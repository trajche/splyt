import Foundation
import SplytCore

/// Drives the installed NetBird client. Its daemon socket is open to local users,
/// so this needs no extra privileges.
enum NetBirdCLI {
    private static let candidates = ["/usr/local/bin/netbird", "/opt/homebrew/bin/netbird"]

    static var executable: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Nil when NetBird is not installed or the daemon is not reachable.
    static func networks() async -> [NetBirdNetwork]? {
        guard let output = try? await run(["networks", "list"]) else {
            return nil
        }
        return NetBirdNetwork.parse(output)
    }

    /// Selecting adds to the current selection, so other networks stay as they are.
    static func set(network id: String, selected: Bool) async throws {
        _ = try await run(selected ? ["networks", "select", "-a", id] : ["networks", "deselect", id])
    }

    struct CommandError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private static func run(_ arguments: [String]) async throws -> String {
        guard let executable else {
            throw CommandError(message: "NetBird is not installed.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: CommandError(
                        message: text.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
