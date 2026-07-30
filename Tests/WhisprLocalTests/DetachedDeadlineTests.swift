import Dispatch
import XCTest
@testable import WhisprLocal

final class DetachedDeadlineTests: XCTestCase {
    func testImmediateOperationReturnsItsValue() async throws {
        let value = try await DetachedDeadline.run(timeout: .seconds(1)) {
            "ready"
        }
        XCTAssertEqual(value, "ready")
    }

    func testDeadlineDoesNotWaitForOperationThatIgnoresCancellation() async {
        let started = ContinuousClock.now
        do {
            let _: String = try await DetachedDeadline.run(
                timeout: .milliseconds(50)
            ) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + .milliseconds(350)
                    ) {
                        continuation.resume(returning: "late")
                    }
                }
            }
            XCTFail("Expected cleanup deadline.")
        } catch WhisprLocalError.cleanupTimedOut {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertLessThan(
            (ContinuousClock.now - started).timeInterval,
            0.2
        )
    }
}
