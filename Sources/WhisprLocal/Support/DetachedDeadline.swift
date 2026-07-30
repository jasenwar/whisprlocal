import Foundation

enum DetachedDeadline {
    static func run<Value: Sendable>(
        timeout: Duration,
        onOperationFinished: @escaping @Sendable () async -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = LockedDeadlineRace<Value>()
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
            race.resolve(outcome)
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeout.timeInterval
        ) {
            race.resolve(.timedOut)
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            operationTask.cancel()
            race.resolve(.cancelled)
        }

        operationTask.cancel()
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

private final class LockedDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: DeadlineOutcome<Value>?
    private var continuation: CheckedContinuation<DeadlineOutcome<Value>, Never>?

    func wait() async -> DeadlineOutcome<Value> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ outcome: DeadlineOutcome<Value>) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

private struct DetachedOperationError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
