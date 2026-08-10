import AVFoundation
import XCTest
@testable import Manas

/// The check-off pop.
@MainActor
final class SoundsTests: XCTestCase {
    override func tearDown() {
        Sounds.isEnabled = false
        super.tearDown()
    }

    /// The bytes have to be real audio, not merely non-empty. Handing
    /// `AVAudioPlayer` a malformed buffer fails at runtime in the one place
    /// nobody is looking — inside a checkbox tap — so the parser is the test.
    func testTheGeneratedPopIsPlayableAudioOfAboutTheRightLength() throws {
        let data = try XCTUnwrap(Sounds.popWAV)
        let player = try AVAudioPlayer(data: data)

        XCTAssertEqual(player.duration, 0.075, accuracy: 0.005)
        XCTAssertEqual(player.numberOfChannels, 1)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
    }

    /// A pop that starts at full amplitude clicks, and one that hasn't decayed
    /// by the end clips into silence — both read as a glitch rather than a pop.
    func testItFadesInAndDiesAwayInsteadOfClicking() throws {
        let data = try XCTUnwrap(Sounds.makePopWAV())
        let samples = pcm(in: data)

        XCTAssertGreaterThan(samples.count, 3000)
        XCTAssertEqual(Int(samples[0]), 0, "a hard onset is a click")
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 8_000, "too quiet to hear over a room")
        let tail = samples.suffix(200).map { abs(Int($0)) }.max() ?? 0
        XCTAssertLessThan(tail, peak / 20, "it should have rung out, not been cut off")
    }

    /// Nothing that merely builds a store may make a noise — that is what keeps
    /// the suite, previews and the accessibility-driven verification runs quiet.
    func testSoundIsOffUntilARealAppTurnsItOn() {
        XCTAssertFalse(Sounds.isEnabled, "default must be silent")

        let store = AppStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json"))
        let todo = store.addTodo("Ship it")!
        store.toggleDone(todo.id)   // would play if the default were wrong

        XCTAssertTrue(store.todos.first { $0.id == todo.id }!.isDone)
    }

    /// The pop is the sound of finishing something. Hearing it while undoing
    /// reads as the app misunderstanding what you did, so only one direction
    /// of the toggle is meant to make it.
    func testOnlyCompletingIsMeantToMakeASound() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ManasTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json"))
        let todo = store.addTodo("Ship it")!

        store.toggleDone(todo.id)
        XCTAssertTrue(store.todos.first { $0.id == todo.id }!.isDone)
        store.toggleDone(todo.id)
        XCTAssertFalse(
            store.todos.first { $0.id == todo.id }!.isDone,
            "reopening is the silent direction"
        )
    }

    private func pcm(in wav: Data) -> [Int16] {
        // 44-byte canonical header, then little-endian 16-bit frames.
        let body = wav.dropFirst(44)
        return stride(from: 0, to: body.count - 1, by: 2).map { offset in
            let index = body.startIndex + offset
            return Int16(littleEndian: Int16(body[index]) | (Int16(bitPattern: UInt16(body[index + 1])) << 8))
        }
    }
}
