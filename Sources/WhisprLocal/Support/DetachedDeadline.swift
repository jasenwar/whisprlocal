import Foundation

enum DetachedDeadline {
    static func run<Value: Sendable>(
        timeout: Duration,
        onOperationFinished: @escaping @Sendable () async -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let gate = DeadlineGate<Value>()
        let operationTask = Task.detached(priority: .userInitiated) {
            let outcome: DeadlineOutcome<Value>
            do {
                outcome = .value(try await operation())
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            await onOperationFinished()
            await gate.resolve(outcome)
        }
        let timeoutTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: timeout)
                await gate.resolve(.timedOut)
            } catch {
                // The operation completed or the caller cancelled.
            }
        }

        let outcome = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            Task {
                await gate.resolve(.cancelled)
            }
        }

        operationTask.cancel()
        timeoutTask.cancel()
        switch outcome {
        case .value(let value):
            return value
        case .failure(let message):
            throw DetachedOperationError(message: message)
        case .timedOut:
            throw WhisprLocalError.cleanupTimedOut
        case .cancelled:
            throw CancellationError()
        }
    }
}

private enum DeadlineOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case failure(String)
    case timedOut
    case cancelled
}

private actor DeadlineGate<Value: Sendable> {
    private var outcome: DeadlineOutcome<Value>?
    private var continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>?

    func wait() async -> DeadlineOutcome<Value> {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ outcome: DeadlineOutcome<Value>) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private struct DetachedOperationError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
