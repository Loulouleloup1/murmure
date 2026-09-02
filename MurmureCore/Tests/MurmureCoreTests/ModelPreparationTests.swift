import XCTest
@testable import MurmureCore

/// The measured shape of the real download, which is what every assertion below is about.
///
/// These are the file sizes on a machine that has finished it -- the 24 files of
/// `openai_whisper-large-v3-v20240930_turbo` under
/// `Application Support/Murmure/models/models/argmaxinc/whisperkit-coreml`.
private enum RealDownload {
    /// Every byte the store holds when the download is complete, sidecars included.
    static let total = ModelDownload.transcriptionModelBytes

    /// The two files that are nearly all of it: `AudioEncoder.mlmodelc/weights/weight.bin` and
    /// `TextDecoder.mlmodelc/weights/weight.bin`.
    static let twoWeightFiles: Int64 = 1_273_974_400 + 343_933_748

    /// Everything else. 22 model files and the Hub's 24 `.metadata` sidecars.
    static let everythingElse = total - twoWeightFiles

    /// How many files the Hub counts, and therefore what its progress is an average of.
    static let fileCount = 24
}

/// Louis installed Murmure on a second Mac, watched "transcribing" for a long time and concluded
/// the app was broken. It was not: it was pulling 1.6 GB and then handing four `.mlmodelc` bundles
/// to CoreML, and it said nothing about either. Every test below is one way that wait stops being
/// legible again.
final class ModelPreparationTests: XCTestCase {
    // MARK: - Why the number the interface shows is not the number WhisperKit reports

    /// **The measurement that decides the whole design.** The Hub builds its `Progress` as one
    /// equally-weighted child per file, so its `fractionCompleted` is the mean of 24 per-file
    /// fractions -- and two of those files are 98.7 % of the bytes. At the instant the 22 small
    /// ones are done, WhisperKit reports over 90 % complete and the download has barely started.
    ///
    /// Showing that number would have reproduced the defect this task exists to remove, inside the
    /// progress bar: minutes of apparent stillness at "nearly done".
    func testTheFileAverageWouldClaimNearlyDoneWithNearlyNothingDownloaded() {
        let asWhisperKitCountsIt =
            100.0 * Double(RealDownload.fileCount - 2) / Double(RealDownload.fileCount)
        var asBytes = ModelDownload(expectedBytes: RealDownload.total)
        asBytes.observe(receivedBytes: RealDownload.everythingElse)

        XCTAssertGreaterThan(
            asWhisperKitCountsIt, 90,
            "the file average is what it is; if this ever falls the reason for this type changes")
        XCTAssertLessThan(asBytes.percent, 5)
        XCTAssertGreaterThan(
            asWhisperKitCountsIt - Double(asBytes.percent), 80,
            "the two readings must be far enough apart that showing the wrong one is a defect")
    }

    // MARK: - The percentage itself

    func testItStartsAtZeroHavingMeasuredNothing() {
        XCTAssertEqual(ModelDownload(expectedBytes: RealDownload.total).percent, 0)
        XCTAssertEqual(ModelDownload(expectedBytes: RealDownload.total).fraction, 0)
    }

    func testItReportsTheShareOfTheBytesThatHaveLanded() {
        var download = ModelDownload(expectedBytes: 1000)
        download.observe(receivedBytes: 250)
        XCTAssertEqual(download.percent, 25)
        XCTAssertEqual(download.fraction, 0.25, accuracy: 1e-12)
    }

    /// The disk really does read lower than it did a second ago: the Hub writes into a
    /// `.<etag>.incomplete` file and then MOVES it to its destination, and a walk taken between
    /// those two counts neither. A bar falling back under Louis's eyes is the app telling him it
    /// has lost ground it has not lost.
    func testAReadingThatFellBackDoesNotEmptyTheBar() {
        var download = ModelDownload(expectedBytes: 1000)
        download.observe(receivedBytes: 600)
        download.observe(receivedBytes: 340)
        XCTAssertEqual(download.percent, 60)
    }

    func testAReadingPastTheExpectedTotalCannotOverfillTheBar() {
        // The constant is measured rather than told to us, so a variant re-uploaded larger really
        // can push past it.
        var download = ModelDownload(expectedBytes: 1000)
        download.observe(receivedBytes: 4000)
        XCTAssertLessThanOrEqual(download.percent, 100)
        XCTAssertLessThanOrEqual(download.fraction, 1)
    }

    /// A running download may not claim to be finished, because finishing is a change of phase and
    /// not a number. If `transcriptionModelBytes` ever under-estimates, an uncapped percentage
    /// would sit at 100 % with bytes still arriving -- "done, still waiting", which is the state
    /// that started this whole task.
    func testARunningDownloadNeverClaimsAHundredPerCent() {
        var download = ModelDownload(expectedBytes: 1000)
        download.observe(receivedBytes: 1000)
        XCTAssertEqual(download.percent, ModelDownload.ceilingWhileRunning)
        XCTAssertLessThan(download.percent, 100)
    }

    func testAnUnreadableStoreIsNotAReadingOfZero() {
        // `bytesOnDisk` answers 0 for a folder it cannot walk. Taking that as a measurement would
        // make one failed directory walk empty a bar that is half full.
        var download = ModelDownload(expectedBytes: 1000)
        download.observe(receivedBytes: 500)
        download.observe(receivedBytes: 0)
        download.observe(receivedBytes: -1)
        XCTAssertEqual(download.percent, 50)
    }

    func testANonsenseTotalCannotDivideByZero() {
        var download = ModelDownload(expectedBytes: 0)
        download.observe(receivedBytes: 500)
        XCTAssertEqual(download.percent, 0)
    }

    // MARK: - What a whole download looks like from outside the app

    /// **The behavioural test the rest of this file supports.** A real sequence of byte readings --
    /// with the repeats a one-second poll produces, the dip a file move produces, and the overshoot
    /// a drifted total produces -- must reach the surfaces as a strictly rising sequence of
    /// sentences, each one different from the last.
    ///
    /// It asserts on the SENTENCE rather than on the field, because the sentence is what Louis
    /// reads: a percentage that advanced without the label changing would pass a test on `percent`
    /// and still leave a card that never moves.
    func testASequenceOfReadingsBecomesAStrictlyRisingSequenceOfSentences() {
        let readings: [Int64] = [
            0,                              // the Hub is still asking for the file list
            RealDownload.everythingElse,    // the 22 small files, in about a second
            410_000_000,
            410_000_000,                    // a poll a second later, mid-file: same percent
            410_000_100,                    // a few hundred bytes: still the same percent
            409_000_000,                    // the dip while an .incomplete file is moved
            800_000_000,
            1_200_000_000,
            RealDownload.total,
            RealDownload.total + 50_000_000, // the total drifted; bytes are still arriving
        ]

        var download = ModelDownload(expectedBytes: RealDownload.total)
        var shown: [String] = []
        for reading in readings {
            let before = download
            download.observe(receivedBytes: reading)
            // Exactly the rule `WhisperKitEngine.announceBytesReceived` applies: report only what
            // would change on screen.
            guard download != before else { continue }
            shown.append(StatusPanelText.label(for: .preparingModel(.downloading(download))))
        }

        XCTAssertFalse(shown.isEmpty)
        XCTAssertEqual(Set(shown).count, shown.count, "a sentence was shown twice in a row")
        XCTAssertEqual(
            shown, ["Downloading model 1%", "Downloading model 25%", "Downloading model 48%",
                    "Downloading model 73%", "Downloading model 99%"])
    }

    /// The same sequence read as the bar the card draws: it may never move backwards, whatever the
    /// disk says.
    func testTheBarNeverRetreatsAcrossAWholeDownload() throws {
        var download = ModelDownload(expectedBytes: RealDownload.total)
        var fills: [Double] = []
        let readings = Array(stride(from: Int64(0), to: RealDownload.total, by: 37_000_000))
            + [900_000_000, RealDownload.total, 300_000_000]
        for reading in readings {
            download.observe(receivedBytes: reading)
            fills.append(
                NotchAppearance.progressFill(
                    for: .preparingModel(.downloading(download)), decoding: nil) ?? -1)
        }
        XCTAssertEqual(fills, fills.sorted(), "the bar went backwards")
        XCTAssertGreaterThan(try XCTUnwrap(fills.last), 0.9)
    }

    // MARK: - The three waits, told apart

    /// The acceptance criterion, stated as the thing a mutation would break: the two steps of the
    /// preparation and the transcription behind them must not read as each other on any of the
    /// three channels a surface has.
    func testTheThreeWaitsAreToldApartByWordAndByGlyph() {
        let downloading = NotchPhase.preparingModel(
            .downloading(ModelDownload(expectedBytes: RealDownload.total)))
        let loading = NotchPhase.preparingModel(.loading)
        let transcribing = NotchPhase.transcribing

        let labels = [downloading, loading, transcribing].map(StatusPanelText.label(for:))
        XCTAssertEqual(Set(labels).count, 3, "two of the three waits say the same thing")
        for label in labels {
            XCTAssertFalse(label.isEmpty)
        }
        XCTAssertFalse(
            StatusPanelText.label(for: downloading)
                .localizedCaseInsensitiveContains("transcrib"),
            "a download must not borrow the word that made Louis think the app was broken")
        XCTAssertFalse(
            StatusPanelText.label(for: loading).localizedCaseInsensitiveContains("transcrib"))

        let glyphs = [downloading, loading, transcribing].map(NotchCard.symbolName(for:))
        XCTAssertEqual(Set(glyphs).count, 3, "two of the three waits show the same glyph")
        for glyph in glyphs {
            XCTAssertFalse(glyph.isEmpty)
        }
    }

    /// **A download at 0 % is a different drawing from a load, and that is what makes the first
    /// seconds of a fresh Mac legible.** An empty bar is honest here -- nothing has arrived yet,
    /// and something will within a second. There is no bar at all for the load, because CoreML
    /// reports nothing and a bar sitting at zero would be a measurement claiming to exist.
    func testADownloadAtZeroIsNotALoadWithNoCounter() {
        let atZero = NotchPhase.preparingModel(
            .downloading(ModelDownload(expectedBytes: RealDownload.total)))
        XCTAssertEqual(NotchAppearance.progressFill(for: atZero, decoding: nil), 0)
        XCTAssertNil(
            NotchAppearance.progressFill(for: .preparingModel(.loading), decoding: nil))
        XCTAssertNotEqual(
            StatusPanelText.label(for: atZero),
            StatusPanelText.label(for: .preparingModel(.loading)))
    }

    /// The transcription's own bar is still withheld until the decoder has actually moved, and the
    /// download must not have loosened that: half of Louis's dictations decode inside one 30 s
    /// window and measure nothing at all, and a determinate bar at zero would claim the work had
    /// not started when it is nearly done.
    func testTheTranscriptionStillWithholdsABarItHasNotMeasured() {
        XCTAssertNil(NotchAppearance.progressFill(for: .transcribing, decoding: DecodeProgress()))
        var measured = DecodeProgress()
        measured.observe(0.4)
        XCTAssertEqual(
            NotchAppearance.progressFill(for: .transcribing, decoding: measured), 0.4)
    }

    /// A preparation may never draw the transcription's bar, and vice versa. The decode box outlives
    /// the dictation -- it still reads 1 while a completion is on screen -- so a load that borrowed
    /// it would show a full bar over the sentence "Loading model".
    func testAPreparationNeverBorrowsTheDecodersBar() {
        var finished = DecodeProgress()
        finished.observe(0.9)
        finished.finish()
        XCTAssertNil(
            NotchAppearance.progressFill(for: .preparingModel(.loading), decoding: finished))

        var download = ModelDownload(expectedBytes: 1000)
        download.observe(receivedBytes: 200)
        XCTAssertEqual(
            NotchAppearance.progressFill(
                for: .preparingModel(.downloading(download)), decoding: finished),
            0.2,
            "the download's own bytes, not the decoder's audio")
    }

    /// One mark from the first second of the download to the last of the decode.
    ///
    /// `NotchAppearance.animationStart` restarts a drawing's clock only when the FAMILY changes, so
    /// sharing `travelling` across the three is what makes a multi-minute first run a single
    /// uninterrupted motion. A family of its own for the preparation would send the mark back to
    /// its starting edge twice, in the one wait where the thing saying the app is alive matters
    /// most.
    func testTheMarkNeverRestartsBetweenPreparingAndTranscribing() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let later = start.addingTimeInterval(90)
        let steps: [NotchPhase] = [
            .preparingModel(.downloading(ModelDownload(expectedBytes: 1000))),
            .preparingModel(.loading),
            .transcribing,
            .inserting,
        ]
        var mark = NotchAppearance.mark(for: steps[0])
        for phase in steps.dropFirst() {
            let next = NotchAppearance.mark(for: phase)
            XCTAssertEqual(
                NotchAppearance.animationStart(
                    previousMark: mark, previousStart: start, newMark: next, now: later),
                start,
                "\(phase) restarts the drawing the previous phase was in the middle of")
            mark = next
        }
    }

    // MARK: - Composing a preparation with the dictation it happens inside

    func testAPreparationIsShownWhileTheDictationIsTranscribing() {
        XCTAssertEqual(
            NotchPresenter.phase(dictation: .transcribing, preparing: .loading),
            .preparingModel(.loading))
    }

    func testNoPreparationLeavesTheDictationExactlyAsItWas() {
        let phases: [NotchPhase] = [
            .hidden, .recording, .transcribing, .refining, .inserting,
            .completed(insertedCharacters: 9), .nothingHeard,
            .failed(message: "boom", recoveredText: nil), .alert(message: "no hotkey"),
        ]
        for phase in phases {
            XCTAssertEqual(NotchPresenter.phase(dictation: phase, preparing: nil), phase)
        }
    }

    /// **The failure has to win, and this is the assertion that says so.** A download that stops
    /// making progress throws `modelDownloadStalled`, the session turns it into `.failed`, and that
    /// sentence -- "check your internet connection" -- is the only thing that will tell Louis his
    /// connection died rather than that Murmure is slow. A stale `.downloading` outranking it would
    /// leave a percentage frozen where the connection dropped, which is the original defect wearing
    /// the fix's clothes.
    func testAStalledDownloadsFailureReachesTheSurfaceInsteadOfItsLastPercentage() {
        var reached = ModelDownload(expectedBytes: 1000)
        reached.observe(receivedBytes: 430)

        let stalled = DictationSession.State.failed(
            message: """
                transcription failed: The transcription model download stopped making progress \
                for 180 s. Check your internet connection and try again.
                """,
            recoveredText: nil)
        // The whole chain, from the state the session emits to the sentence on the strip.
        let dictation = NotchPresenter.phase(previous: .transcribing, current: stalled)
        let shown = NotchPresenter.phase(
            dictation: dictation, preparing: .downloading(reached))

        XCTAssertEqual(shown, dictation)
        XCTAssertTrue(NotchAppearance.showsShape(in: shown), "the failure needs a window")
        XCTAssertEqual(NotchCard.tint(for: shown), .warning)
        let label = StatusPanelText.label(for: shown)
        XCTAssertTrue(label.localizedCaseInsensitiveContains("internet connection"))
        XCTAssertFalse(label.contains("43%"), "the percentage it stalled at is not the news")
        XCTAssertNotNil(
            NotchPresenter.dwell(for: shown), "a failure has to leave the screen on its own")
    }

    /// Every other phase a stale report could land on. The preparation is true only while the
    /// session is inside `Transcriber.transcribe`, so anything else means the dictation has moved
    /// on and its own phase is the current fact.
    func testAStalePreparationCannotPaintOverADictationThatHasMovedOn() {
        let stale = ModelPreparation.downloading(ModelDownload(expectedBytes: 1000))
        let moved: [NotchPhase] = [
            .hidden, .recording, .refining, .inserting,
            .completed(insertedCharacters: 12), .nothingHeard,
            .failed(message: "paste refused", recoveredText: "bonjour"),
            .alert(message: "accessibility"),
        ]
        for phase in moved {
            XCTAssertEqual(
                NotchPresenter.phase(dictation: phase, preparing: stale), phase,
                "\(phase) was painted over by a preparation that is no longer happening")
        }
    }

    /// The report and the session's state change reach the main actor by two different routes, so
    /// a preparation can arrive one frame early. It is suppressed rather than shown over
    /// `.recording` -- and it is not lost: the caller keeps it and composes again on the
    /// `.transcribing` that follows.
    func testAPreparationThatArrivedEarlyIsRecoveredByTheStateThatFollows() {
        let early = ModelPreparation.loading
        XCTAssertEqual(NotchPresenter.phase(dictation: .recording, preparing: early), .recording)
        XCTAssertEqual(
            NotchPresenter.phase(dictation: .transcribing, preparing: early),
            .preparingModel(early))
    }

    // MARK: - Where it is shown

    /// A preparation happens inside a dictation, on the display that dictation already resolved.
    /// Nothing about the model being fetched moves the card to another screen.
    func testAPreparationStaysOnTheDisplayTheDictationResolved() {
        let held = StatusRoute(screenIndex: 1, surface: .panel)
        let elsewhere = StatusRoute(screenIndex: 0, surface: .notch)
        let phase = NotchPhase.preparingModel(.downloading(ModelDownload(expectedBytes: 1000)))
        XCTAssertEqual(
            StatusSurfaceChoice.route(for: phase, held: held, resolved: elsewhere), held)
    }

    /// Every phase, so the two assertions below quantify over a real domain.
    private static let everyPhase: [NotchPhase] = [
        .hidden, .recording,
        .preparingModel(.downloading(ModelDownload(expectedBytes: 1000))),
        .preparingModel(.loading), .transcribing, .refining, .inserting,
        .completed(insertedCharacters: 3), .nothingHeard, .cancelled,
        .failed(message: "boom", recoveredText: nil), .alert(message: "no hotkey"),
    ]

    /// The optimisation that makes a once-a-second report affordable is a READING of the routing
    /// rule, not a second rule: wherever `resolvesAfresh` says no, resolving a display and not
    /// resolving one give the same answer, so `StatusRouter` may skip the Accessibility round-trip
    /// entirely. If the rule ever changes and this reading does not, the two disagree about a
    /// display -- which is the bug `643165c` removed.
    func testSkippingTheDisplayResolutionCannotChangeTheAnswer() {
        let held: [StatusRoute?] = [nil, StatusRoute(screenIndex: 1, surface: .panel)]
        let resolved = StatusRoute(screenIndex: 0, surface: .notch)
        for phase in Self.everyPhase {
            for hold in held where !StatusSurfaceChoice.resolvesAfresh(for: phase, held: hold) {
                XCTAssertEqual(
                    StatusSurfaceChoice.route(for: phase, held: hold, resolved: resolved),
                    StatusSurfaceChoice.route(for: phase, held: hold, resolved: nil),
                    "\(phase) with \(String(describing: hold)) needs the fresh resolution")
            }
        }
    }

    /// **And the two answers it has to give**, because the test above is vacuous on its own: a
    /// predicate that said "always resolve" would satisfy it by never entering the loop, and one
    /// that said "never resolve" would satisfy it by entering the loop where the answer happens to
    /// be the same.
    ///
    /// The two directions cost different things and both are stated:
    ///
    /// - **A press must always resolve afresh**, held route or not. That is rule 2 of
    ///   `route(for:held:resolved:)`, and skipping it would place a dictation on the display the
    ///   previous one used -- a monitor plugged in between two dictations would need a restart.
    /// - **A dictation already on a display must not**, or the saving is not made at all and a
    ///   download pays a few hundred cross-process Accessibility messages for an answer that is
    ///   discarded.
    func testTheRuleResolvesForAPressAndForNothingHeldAndOtherwiseSkips() {
        let held = StatusRoute(screenIndex: 1, surface: .panel)
        XCTAssertTrue(StatusSurfaceChoice.resolvesAfresh(for: .recording, held: held))
        XCTAssertTrue(StatusSurfaceChoice.resolvesAfresh(for: .recording, held: nil))
        for phase in Self.everyPhase {
            XCTAssertTrue(
                StatusSurfaceChoice.resolvesAfresh(for: phase, held: nil),
                "\(phase) with no display held has nowhere to draw without resolving one")
        }
        for phase in Self.everyPhase where !isRecording(phase) {
            XCTAssertFalse(
                StatusSurfaceChoice.resolvesAfresh(for: phase, held: held),
                "\(phase) pays for a display resolution the routing rule then discards")
        }
    }
}

private func isRecording(_ phase: NotchPhase) -> Bool {
    if case .recording = phase { true } else { false }
}
