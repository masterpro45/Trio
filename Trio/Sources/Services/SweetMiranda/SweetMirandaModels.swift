import Foundation

/// Sweet Miranda (wilhq.com) ⇄ Trio settings bridge — shared vocabulary.
///
/// Everything travels as Nightscout *treatments* with `eventType == "Sweet Miranda Settings"`
/// so no new Nightscout collection or permission is needed:
///
///   kind "proposal"  written by the Sweet Miranda bridge, read by Trio   (status: pending)
///   kind "result"    written by Trio after Face ID                         (status: applied | declined | failed)
///   kind "snapshot"  written by Trio whenever a setting changes            (the full picture Sweet Miranda shows)
///
/// Trio never changes a setting from a proposal without the device owner authenticating
/// (`UnlockManager` → Face ID / passcode). Nothing here can dose.
enum SweetMiranda {
    static let eventType = "Sweet Miranda Settings"
    static let enteredBy = "SweetMiranda"
    static let proposalTTL: TimeInterval = 24 * 3600

    enum Kind: String { case proposal, result, snapshot }
    enum Status: String { case pending, applied, declined, failed, expired }

    /// Keys of the flat "changes" dictionary a proposal carries.
    ///   pref.<oref preferences.json key>   e.g. pref.max_iob, pref.enableSMB_always
    ///   settings.<TrioSettings key>        curated allow-list, e.g. settings.dosingMode
    ///   pump.maxBolus | pump.maxBasal | pump.insulin_action_curve
    ///   basal | isf | cr | targets         whole schedules (arrays)
    enum Key {
        static let prefPrefix = "pref."
        static let settingsPrefix = "settings."
        static let pumpPrefix = "pump."
        static let basal = "basal"
        static let isf = "isf"
        static let cr = "cr"
        static let targets = "targets"
    }
}

/// One proposal as read from Nightscout.
struct SMProposal: Identifiable, Equatable {
    let id: String // smId — Sweet Miranda's proposal uuid
    let nsId: String? // Nightscout _id of the document
    let from: String // who sent it (a WilHQ user)
    let note: String // the sentence shown under the list
    let baseHash: String? // snapshot hash the sender was looking at
    let createdAt: Date?
    let expiresAt: Date?
    let changes: [String: Any] // see SweetMiranda.Key

    static func == (lhs: SMProposal, rhs: SMProposal) -> Bool { lhs.id == rhs.id }

    /// Parses a Nightscout treatment document; nil when it is not a pending proposal.
    init?(document d: [String: Any]) {
        guard (d["smKind"] as? String) == SweetMiranda.Kind.proposal.rawValue,
              (d["smStatus"] as? String) == SweetMiranda.Status.pending.rawValue,
              let id = d["smId"] as? String, !id.isEmpty,
              let changes = d["smChanges"] as? [String: Any], !changes.isEmpty
        else { return nil }
        self.id = id
        nsId = d["_id"] as? String
        from = (d["smFrom"] as? String) ?? "Sweet Miranda"
        note = (d["smNote"] as? String) ?? ""
        baseHash = d["smBaseHash"] as? String
        createdAt = SMDates.parse(d["created_at"] as? String)
        expiresAt = SMDates.parse(d["smExpires"] as? String)
        self.changes = changes
    }

    var isExpired: Bool {
        if let e = expiresAt { return e < Date() }
        if let c = createdAt { return Date().timeIntervalSince(c) > SweetMiranda.proposalTTL }
        return false
    }
}

/// One line of the approval sheet: what a change means in words.
struct SMChangeLine: Identifiable {
    let id: String
    let group: String
    let label: String
    let from: String
    let to: String
}

enum SMDates {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func string(_ d: Date) -> String { iso.string(from: d) }
}

enum SMError: LocalizedError {
    case notAuthenticated
    case invalid(String)
    case pumpUnavailable(String)
    case nightscout(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return String(localized: "Face ID / passcode was not confirmed. Nothing was changed.")
        case let .invalid(m): return m
        case let .pumpUnavailable(m): return m
        case let .nightscout(m): return m
        }
    }
}
