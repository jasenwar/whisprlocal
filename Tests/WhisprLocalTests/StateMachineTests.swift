import XCTest
@testable import WhisprLocal

final class StateMachineTests: XCTestCase {
    func testHappyPathTransitions() throws {
        var machine = DictationStateMachine()
        try machine.transition(to: .preparing)
        try machine.transition(to: .listening)
        try machine.transition(to: .transcribing)
        try machine.transition(to: .correcting)
        try machine.transition(to: .pasting)
        try machine.transition(to: .succeeded)
        try machine.transition(to: .idle)
        XCTAssertEqual(machine.state, .idle)
    }

    func testFnInterruptionPathCancelsListening() throws {
        var machine = DictationStateMachine()
        try machine.transition(to: .preparing)
        try machine.transition(to: .listening)
        try machine.transition(to: .cancelled)
        try machine.transition(to: .idle)
        XCTAssertEqual(machine.state, .idle)
    }

    func testFnReleaseCanCancelMicrophonePreparation() throws {
        var machine = DictationStateMachine()
        try machine.transition(to: .preparing)
        try machine.transition(to: .cancelled)
        try machine.transition(to: .idle)
        XCTAssertEqual(machine.state, .idle)
    }

    func testInvalidTransitionIsRejected() throws {
        var machine = DictationStateMachine()
        XCTAssertThrowsError(try machine.transition(to: .pasting))
        XCTAssertEqual(machine.state, .idle)
    }
}
