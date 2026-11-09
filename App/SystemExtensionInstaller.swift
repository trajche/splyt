import Foundation
import SplytCore
import SystemExtensions

/// Activates the bundled system extension. macOS asks the user to allow it in
/// System Settings the first time, so `run` can stay suspended for a long while.
@MainActor
final class SystemExtensionInstaller: NSObject {
    enum InstallerError: LocalizedError {
        case rebootRequired

        var errorDescription: String? {
            "Restart your Mac to finish installing the Splyt extension."
        }
    }

    var onNeedsApproval: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?

    func activate() async throws {
        try await run(.activationRequest(
            forExtensionWithIdentifier: SplytConstants.extensionBundleID, queue: .main
        ))
    }

    func deactivate() async throws {
        try await run(.deactivationRequest(
            forExtensionWithIdentifier: SplytConstants.extensionBundleID, queue: .main
        ))
    }

    private func run(_ request: OSSystemExtensionRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation?.resume(throwing: CancellationError())
            self.continuation = continuation
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { onNeedsApproval?() }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            finish(result == .completed ? .success(()) : .failure(InstallerError.rebootRequired))
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }
}
