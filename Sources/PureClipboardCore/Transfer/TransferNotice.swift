import Foundation

/// Decides which state changes deserve a macOS notification. Pauses the user asked for are silent.
public enum TransferNotice {
    public struct Message: Equatable, Sendable {
        public var title: String
        public var body: String
    }

    public static func message(for job: TransferJob, previous: TransferState?) -> Message? {
        guard previous != job.state else { return nil }
        switch job.state {
        case .completed:
            return Message(title: "Soubor je v telefonu", body: "\(job.destinationName ?? job.sourceName) · Stažené")
        case .failed:
            return Message(title: "Přenos selhal", body: "\(job.sourceName): \(job.message ?? "neznámá chyba")")
        case .paused:
            switch job.pauseReason {
            case .mobileData:
                return Message(title: "Čeká na potvrzení", body: "\(job.sourceName) by čerpal mobilní data.")
            case .noPhone, .connectionLost:
                return Message(title: "Přenos pozastaven", body: "\(job.sourceName): telefon není dostupný. Pokračujte v aplikaci.")
            case .user, .interrupted, nil:
                return nil
            }
        default:
            return nil
        }
    }
}
