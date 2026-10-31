import Foundation
import Testing
@testable import PureClipboardCore

@Suite struct TransferNoticeTests {
    private func job(_ state: TransferState, reason: TransferPauseReason? = nil, message: String? = nil) -> TransferJob {
        var job = TransferJob(sourcePath: "/x/foto.jpg", sourceName: "foto.jpg", size: 10, modifiedAt: 0, destinationDirectory: "/sdcard/Download")
        job.state = state
        job.pauseReason = reason
        job.message = message
        job.destinationName = "foto.jpg"
        return job
    }

    @Test func completionAndFailureNotify() {
        #expect(TransferNotice.message(for: job(.completed), previous: .verifying)?.title == "Soubor je v telefonu")
        #expect(TransferNotice.message(for: job(.failed, message: "Kontrolní součet"), previous: .running)?.body.contains("Kontrolní součet") == true)
    }

    @Test func mobileDataAndLostPhoneNotify() {
        #expect(TransferNotice.message(for: job(.paused, reason: .mobileData), previous: .running)?.title == "Čeká na potvrzení")
        #expect(TransferNotice.message(for: job(.paused, reason: .noPhone), previous: .preparing)?.title == "Přenos pozastaven")
    }

    @Test func userPausesAndRepeatedStatesAreSilent() {
        #expect(TransferNotice.message(for: job(.paused, reason: .user), previous: .pausing) == nil)
        #expect(TransferNotice.message(for: job(.running), previous: .preparing) == nil)
        #expect(TransferNotice.message(for: job(.completed), previous: .completed) == nil)
    }
}
