import CryptoKit
import Foundation

/// Sweet Miranda (wilhq.com) ⇄ Trio settings bridge — shared vocabulary.
///
/// Everything travels as Nightscout *treatments* with `eventType == "Sweet Miranda Settings"`
/// so no new Nightscout collection or permission is needed:
///
///   kind "proposal"  written by the Sweet Miranda bridge, read by Trio   (status: pending)
///   kind "result"    written by Trio after Face ID                         (status: applied | declined | failed)
///   kind "snapshot"  written by Trio whenever a setting changes            (the full picture Sweet Miranda shows)
///   kind "approval"  written by LoopFollow on a caregiver's phone          (a Face ID signature over one proposal)
///   kind "enroll"    written by LoopFollow when a caregiver's phone asks to become an approver
///
/// Trio never changes a setting from a proposal without a person authenticating: the device owner
/// on this phone (`UnlockManager` → Face ID / passcode), or a registered approver's Face ID on their
/// own phone, verified here against the public key this phone enrolled. Approvers are only ever
/// added or removed on this phone. Nothing here can dose.
enum SweetMiranda {
    static let eventType = "Sweet Miranda Settings"
    static let enteredBy = "SweetMiranda"
    static let proposalTTL: TimeInterval = 24 * 3600

    enum Kind: String { case proposal, result, snapshot, approval, enroll }
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
        static let approverPrefix = "approver."
        static let approverAdd = "approver.add" // {keyId, name, publicKey}
        static let approverRemove = "approver.remove" // keyId
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
    let expiresRaw: String // smExpires exactly as sent — part of what an approver signs
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
        expiresRaw = (d["smExpires"] as? String) ?? ""
        self.changes = changes
    }

    /// Adding or removing an approver can only be approved on this phone.
    var touchesApprovers: Bool {
        changes.keys.contains { $0.hasPrefix(SweetMiranda.Key.approverPrefix) }
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

// MARK: - Face ID approvers on other phones

/// A caregiver's phone allowed to approve proposals with ITS owner's Face ID (LoopFollow ▸ Sweet Miranda).
/// Only added or removed through a proposal approved on this phone, or removed in Settings here.
struct SMApprover: Codable, Equatable, Identifiable {
    let keyId: String
    let name: String
    let publicKey: String // base64 of the P-256 x9.63 public key (65 bytes, 04‖X‖Y)
    let addedAt: Date

    var id: String { keyId }
}

/// A signed approval read from Nightscout (kind "approval"), written by LoopFollow.
struct SMApproval {
    let proposalId: String
    let keyId: String
    let payload: String
    let signature: Data

    init?(document d: [String: Any]) {
        guard (d["smKind"] as? String) == SweetMiranda.Kind.approval.rawValue,
              let id = d["smId"] as? String, !id.isEmpty,
              let keyId = d["smKeyId"] as? String, !keyId.isEmpty,
              let payload = d["smPayload"] as? String,
              let sigB64 = d["smSig"] as? String,
              let sig = Data(base64Encoded: sigB64)
        else { return nil }
        proposalId = id
        self.keyId = keyId
        self.payload = payload
        signature = sig
    }
}

/// The signing contract shared with LoopFollow (Sweet Miranda approver) — change both sides together.
///
///   payload   = "SMAPPROVE1|<smId>|<sha256 hex of the sorted-keys JSON of smChanges>|<smExpires as sent>"
///   signature = ECDSA P-256 over SHA-256(payload UTF-8), DER
///               (LoopFollow: SecKeyCreateSignature, .ecdsaSignatureMessageX962SHA256, Secure Enclave key
///                with .biometryCurrentSet — Face ID only, no passcode fallback)
///   keyId     = first 16 hex characters of SHA-256(x9.63 public key bytes)
enum SMApprovers {
    static let version = "SMAPPROVE1"

    static func changesHash(_ changes: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func payload(for p: SMProposal) -> String? {
        guard let hash = changesHash(p.changes) else { return nil }
        return [version, p.id, hash, p.expiresRaw].joined(separator: "|")
    }

    static func keyId(publicKey: Data) -> String {
        String(SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The approver whose Face ID signed exactly this proposal, or nil. A bad approval is ignored, never fatal.
    static func verify(_ a: SMApproval, for p: SMProposal, approvers: [SMApprover]) -> SMApprover? {
        guard a.proposalId == p.id, !p.touchesApprovers, !p.isExpired,
              let expected = payload(for: p), a.payload == expected,
              let approver = approvers.first(where: { $0.keyId == a.keyId }),
              let keyData = Data(base64Encoded: approver.publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: a.signature),
              key.isValidSignature(sig, for: Data(expected.utf8))
        else { return nil }
        return approver
    }

    /// Parses and checks an `approver.add` value: {keyId, name, publicKey}.
    static func parseAdd(_ raw: Any) throws -> SMApprover {
        guard let d = raw as? [String: Any],
              let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.count <= 60,
              let pk = d["publicKey"] as? String,
              let keyData = Data(base64Encoded: pk),
              (try? P256.Signing.PublicKey(x963Representation: keyData)) != nil
        else { throw SMError.invalid("The new approver's key is not a valid P-256 public key") }
        let keyId = keyId(publicKey: keyData)
        if let claimed = d["keyId"] as? String, claimed != keyId {
            throw SMError.invalid("The new approver's key ID does not match its key")
        }
        return SMApprover(keyId: keyId, name: name, publicKey: pk, addedAt: Date())
    }
}
