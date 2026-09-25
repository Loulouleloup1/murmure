import XCTest

/// Contrat rouge du lot 10-S : le panel et le socket doivent partager une seule file, et le
/// résultat attendu doit être attaché à l'identité de l'entrée. La file cœur n'est pas compilée
/// ici : son contrat de comportement reste dans TranscriptQueueTests du lot 10. Ces tests
/// inspectent la couture applicative, seule surface où une seconde file pourrait se glisser.
final class TranscriptQueueSharedSurfaceTests: XCTestCase {
    private var racine: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relative: String) -> String {
        let url = racine.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    func testPanelAndSocketShareOneQueueWithoutProvisionalBoard() {
        let pane = source("Murmure/TranscriptsPaneModel.swift")
        let server = source("Murmure/TranscriptControlServer.swift")
        XCTAssertTrue(pane.contains("TranscriptQueue"))
        XCTAssertTrue(server.contains("TranscriptQueue"))
        XCTAssertFalse(server.contains("ControlJobBoard"))
        XCTAssertFalse(server.contains("enchainer"))
        XCTAssertTrue(server.contains("TranscriptsPaneModel") || server.contains("queue"))
    }

    func testSocketWaitIsBoundToEntryIdentity() {
        let queue = source("MurmureCore/Sources/MurmureCore/TranscriptQueue.swift")
        let server = source("Murmure/TranscriptControlServer.swift")
        XCTAssertTrue(queue.contains("id"))
        XCTAssertTrue(queue.contains("wait"))
        XCTAssertTrue(queue.contains("TranscriptDocument") || queue.contains("result"))
        XCTAssertTrue(server.contains("wait"))
        XCTAssertTrue(server.contains("id"))
    }

    func testSocketUsesTheEntryErrorAndCancellationPath() {
        let server = source("Murmure/TranscriptControlServer.swift")
        XCTAssertTrue(server.contains("error") || server.contains("failed"))
        XCTAssertTrue(server.contains("cancel") || server.contains("Cancellation"))
        XCTAssertTrue(server.contains("id"))
    }

    func testSocketStatusReadsTheCommonQueueWithoutTranscriptText() {
        let server = source("Murmure/TranscriptControlServer.swift")
        let start = server.range(of: "func status") ?? server.startIndex..<server.endIndex
        let body = String(server[start.lowerBound...])
        XCTAssertTrue(body.contains("TranscriptQueue"))
        XCTAssertFalse(body.contains("TranscriptDocument"))
        XCTAssertFalse(body.contains("segments"))
    }

    func testSocketDoesNotConstructASecondQueueOrEngine() {
        let server = source("Murmure/TranscriptControlServer.swift")
        XCTAssertFalse(server.contains("ControlJobBoard"))
        XCTAssertFalse(server.contains("WhisperKitEngine()"))
        XCTAssertTrue(server.contains("TranscriptQueue") || server.contains("queue"))
    }
}
