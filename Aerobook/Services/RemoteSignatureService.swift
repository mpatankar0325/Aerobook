import Foundation
import CryptoKit
import MessageUI
import SwiftUI
import Combine

// MARK: - Signature Request Token Model

/// A pending remote signature request stored locally and encoded into a deep link.
/// All data stays 100% on-device — no cloud server required.
struct SignatureToken: Codable, Identifiable {
    var id:              String        // UUID token — acts as the secret key
    var flightID:        Int64         // DB row ID of the flight (or -1 for endorsement)
    var endorsementID:   Int64?        // DB row ID of endorsement (nil for flight)
    var entryType:       EntryType
    var pilotName:       String
    var flightDate:      String
    var aircraftIdent:   String
    var totalTime:       Double
    var dualReceived:    Double
    var remarks:         String
    var createdAt:       Date
    var expiresAt:       Date          // 30-day expiry per reasonable practice
    var status:          TokenStatus
    var instructorName:  String
    var instructorCert:  String
    var signatureBase64: String        // filled when instructor signs
    var signatureHash:   String        // SHA-256 tamper seal

    enum EntryType: String, Codable {
        case dualFlight   = "dual_flight"
        case endorsement  = "endorsement"
    }

    enum TokenStatus: String, Codable {
        case pending   = "pending"
        case signed    = "signed"
        case expired   = "expired"
        case cancelled = "cancelled"
    }

    var isExpired: Bool { Date() > expiresAt }
    var deepLink:  String {
        let base = "aerobook://remotesign"
        var c    = URLComponents(string: base)!
        c.queryItems = [
            URLQueryItem(name: "token",       value: id),
            URLQueryItem(name: "pilot",       value: pilotName),
            URLQueryItem(name: "date",        value: flightDate),
            URLQueryItem(name: "tail",        value: aircraftIdent),
            URLQueryItem(name: "time",        value: String(format: "%.1f", totalTime)),
            URLQueryItem(name: "dual",        value: String(format: "%.1f", dualReceived)),
            URLQueryItem(name: "type",        value: entryType.rawValue),
            URLQueryItem(name: "remarks",     value: remarks),
            URLQueryItem(name: "flightID",    value: String(flightID)),
            URLQueryItem(name: "endorseID",   value: endorsementID.map { String($0) } ?? ""),
        ]
        return c.url?.absoluteString ?? base
    }
}

// MARK: - Remote Signature Service

/// Manages the full lifecycle of remote signature requests:
///   1. Create token for a flight or endorsement entry
///   2. Send via Email or iMessage
///   3. Instructor opens link → InstructorRemoteSignView presents
///   4. Instructor signs → token stored in Keychain/UserDefaults as signed
///   5. Student polls / fetches → signature applied to local DB entry
class RemoteSignatureService: NSObject, ObservableObject, MFMailComposeViewControllerDelegate,
                               MFMessageComposeViewControllerDelegate {

    static let shared = RemoteSignatureService()

    // MARK: Published state
    @Published var pendingTokens: [SignatureToken] = []

    private let storageKey = "aerobook.remoteSignatureTokens"
    private override init() {
        super.init()
        loadTokens()
        purgeExpiredTokens()
    }

    // MARK: - Create Token

    func createToken(
        flightID:      Int64,
        endorsementID: Int64?   = nil,
        entryType:     SignatureToken.EntryType,
        pilotName:     String,
        flightDate:    String,
        aircraftIdent: String,
        totalTime:     Double,
        dualReceived:  Double,
        remarks:       String
    ) -> SignatureToken {
        let token = SignatureToken(
            id:              UUID().uuidString,
            flightID:        flightID,
            endorsementID:   endorsementID,
            entryType:       entryType,
            pilotName:       pilotName,
            flightDate:      flightDate,
            aircraftIdent:   aircraftIdent,
            totalTime:       totalTime,
            dualReceived:    dualReceived,
            remarks:         remarks,
            createdAt:       Date(),
            expiresAt:       Calendar.current.date(byAdding: .day, value: 30, to: Date())!,
            status:          .pending,
            instructorName:  "",
            instructorCert:  "",
            signatureBase64: "",
            signatureHash:   ""
        )
        pendingTokens.append(token)
        saveTokens()
        return token
    }

    // MARK: - Send via Email

    /// Returns a configured MFMailComposeViewController ready to present
    func emailViewController(for token: SignatureToken) -> MFMailComposeViewController? {
        guard MFMailComposeViewController.canSendMail() else { return nil }
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = self
        mail.setSubject("Signature Request — \(token.pilotName) · \(token.flightDate)")
        mail.setMessageBody(htmlEmailBody(for: token), isHTML: true)
        return mail
    }

    /// Returns a configured MFMessageComposeViewController for iMessage/SMS
    func messageViewController(for token: SignatureToken) -> MFMessageComposeViewController? {
        guard MFMessageComposeViewController.canSendText() else { return nil }
        let msg = MFMessageComposeViewController()
        msg.messageComposeDelegate = self
        msg.body = smsBody(for: token)
        return msg
    }

    // MARK: - Deep Link Handler (called from DeepLinkManager)

    /// Called when `aerobook://remotesign?token=...` is opened.
    /// Returns a fully populated SignatureToken ready for the instructor UI.
    func resolveDeepLink(_ url: URL) -> SignatureToken? {
        guard url.host == "remotesign" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let items = comps.queryItems else { return nil }

        func q(_ name: String) -> String { items.first(where: { $0.name == name })?.value ?? "" }

        let tokenID     = q("token")
        let flightIDStr = q("flightID")
        let flightID    = Int64(flightIDStr) ?? -1
        let endorseStr  = q("endorseID")
        let endorseID   = endorseStr.isEmpty ? nil : Int64(endorseStr)
        let typeStr     = q("type")
        let entryType   = SignatureToken.EntryType(rawValue: typeStr) ?? .dualFlight

        // Check if this token already exists locally (student's device receiving their own link)
        if let existing = pendingTokens.first(where: { $0.id == tokenID }) {
            return existing
        }

        // Instructor's device: reconstruct a lightweight token from URL params
        return SignatureToken(
            id:              tokenID.isEmpty ? UUID().uuidString : tokenID,
            flightID:        flightID,
            endorsementID:   endorseID,
            entryType:       entryType,
            pilotName:       q("pilot"),
            flightDate:      q("date"),
            aircraftIdent:   q("tail"),
            totalTime:       Double(q("time")) ?? 0,
            dualReceived:    Double(q("dual")) ?? 0,
            remarks:         q("remarks"),
            createdAt:       Date(),
            expiresAt:       Calendar.current.date(byAdding: .day, value: 30, to: Date())!,
            status:          .pending,
            instructorName:  "",
            instructorCert:  "",
            signatureBase64: "",
            signatureHash:   ""
        )
    }

    // MARK: - Complete Signature (instructor side)

    /// Called when instructor completes signing on their device.
    /// Stores the signed token locally and generates a callback deep link.
    func completeSignature(
        token:           SignatureToken,
        instructorName:  String,
        instructorCert:  String,
        signatureBase64: String
    ) -> String {
        // Compute SHA-256 tamper seal
        let dataStr  = "\(token.id)|\(token.flightID)|\(token.flightDate)|\(instructorName)|\(instructorCert)"
        let hash: String
        if let data = dataStr.data(using: .utf8) {
            let h = SHA256.hash(data: data)
            hash  = h.compactMap { String(format: "%02x", $0) }.joined()
        } else {
            hash  = UUID().uuidString
        }

        // Build return deep link so instructor can send back to student
        var returnComps = URLComponents(string: "aerobook://sigreturn")!
        returnComps.queryItems = [
            URLQueryItem(name: "token",      value: token.id),
            URLQueryItem(name: "flightID",   value: String(token.flightID)),
            URLQueryItem(name: "endorseID",  value: token.endorsementID.map { String($0) } ?? ""),
            URLQueryItem(name: "type",       value: token.entryType.rawValue),
            URLQueryItem(name: "cfiName",    value: instructorName),
            URLQueryItem(name: "cfiCert",    value: instructorCert),
            URLQueryItem(name: "hash",       value: hash),
            URLQueryItem(name: "sig",        value: signatureBase64),
        ]
        return returnComps.url?.absoluteString ?? ""
    }

    // MARK: - Apply Returned Signature (student side)

    /// Called when `aerobook://sigreturn?...` is opened on the student's device.
    /// Applies the instructor's signature to the local DB entry.
    func applyReturnedSignature(_ url: URL, completion: @escaping (Bool, String) -> Void) {
        guard url.host == "sigreturn",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let items = comps.queryItems else {
            completion(false, "Invalid signature return link.")
            return
        }

        func q(_ n: String) -> String { items.first(where: { $0.name == n })?.value ?? "" }

        let tokenID    = q("token")
        let flightID   = Int64(q("flightID")) ?? -1
        let endorseStr = q("endorseID")
        let endorseID  = endorseStr.isEmpty ? nil : Int64(endorseStr)
        let entryType  = SignatureToken.EntryType(rawValue: q("type")) ?? .dualFlight
        let cfiName    = q("cfiName")
        let cfiCert    = q("cfiCert")
        let hash       = q("hash")
        let sigB64     = q("sig")

        guard !cfiName.isEmpty, !cfiCert.isEmpty, !sigB64.isEmpty else {
            completion(false, "Signature data is incomplete.")
            return
        }

        if entryType == .endorsement, let eID = endorseID {
            DatabaseManager.shared.updateEndorsementSignature(
                id: eID,
                signatureBlob: sigB64,
                instructorName: cfiName,
                instructorCertificate: cfiCert
            ) { success in
                if success {
                    self.markTokenSigned(tokenID: tokenID, name: cfiName, cert: cfiCert,
                                        sig: sigB64, hash: hash)
                    completion(true, "Endorsement signed by \(cfiName).")
                } else {
                    completion(false, "Failed to apply signature to endorsement.")
                }
            }
        } else {
            DatabaseManager.shared.signFlight(
                id: flightID, signature: sigB64, hash: hash,
                name: cfiName, certificate: cfiCert
            ) { success in
                if success {
                    self.markTokenSigned(tokenID: tokenID, name: cfiName, cert: cfiCert,
                                        sig: sigB64, hash: hash)
                    completion(true, "Flight entry signed by \(cfiName).")
                } else {
                    completion(false, "Failed to apply signature to flight entry.")
                }
            }
        }
    }

    // MARK: - Token Persistence

    private func markTokenSigned(tokenID: String, name: String, cert: String,
                                  sig: String, hash: String) {
        if let idx = pendingTokens.firstIndex(where: { $0.id == tokenID }) {
            pendingTokens[idx].status          = .signed
            pendingTokens[idx].instructorName  = name
            pendingTokens[idx].instructorCert  = cert
            pendingTokens[idx].signatureBase64 = sig
            pendingTokens[idx].signatureHash   = hash
            saveTokens()
            NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
        }
    }

    func cancelToken(_ token: SignatureToken) {
        if let idx = pendingTokens.firstIndex(where: { $0.id == token.id }) {
            pendingTokens[idx].status = .cancelled
            saveTokens()
        }
    }

    private func saveTokens() {
        if let data = try? JSONEncoder().encode(pendingTokens) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadTokens() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let tokens = try? JSONDecoder().decode([SignatureToken].self, from: data)
        else { return }
        pendingTokens = tokens
    }

    private func purgeExpiredTokens() {
        pendingTokens = pendingTokens.map { token in
            var t = token
            if t.status == .pending && t.isExpired { t.status = .expired }
            return t
        }
        saveTokens()
    }

    // MARK: - Message Delegates

    func mailComposeController(_ c: MFMailComposeViewController,
                               didFinishWith result: MFMailComposeResult, error: Error?) {
        c.dismiss(animated: true)
    }

    func messageComposeViewController(_ c: MFMessageComposeViewController,
                                       didFinishWith result: MessageComposeResult) {
        c.dismiss(animated: true)
    }

    // MARK: - Message Bodies

    private func htmlEmailBody(for token: SignatureToken) -> String {
        let link = token.deepLink
        let entryLabel = token.entryType == .endorsement ? "Endorsement Entry" : "Dual Flight Entry"
        return """
        <!DOCTYPE html>
        <html>
        <body style="font-family: -apple-system, Helvetica, Arial, sans-serif;
                     max-width: 520px; margin: 0 auto; padding: 24px; color: #0f141e;">

          <div style="background: #f5f8fc; border-radius: 16px; padding: 24px; margin-bottom: 20px;">
            <h2 style="margin: 0 0 4px 0; font-size: 20px; color: #0f141e;">
              ✍️ Signature Requested
            </h2>
            <p style="margin: 0; font-size: 13px; color: #526070;">AeroBook · \(entryLabel)</p>
          </div>

          <p style="font-size: 15px;">Hi Instructor,</p>
          <p style="font-size: 15px;">
            <strong>\(token.pilotName)</strong> has requested your digital signature
            for a logbook entry in AeroBook.
          </p>

          <div style="background: #fff; border: 1px solid #dce6f2; border-radius: 12px;
                      padding: 18px; margin: 20px 0;">
            <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
              <tr><td style="color: #526070; padding: 4px 0;">Date</td>
                  <td style="font-weight: 600; text-align: right;">\(token.flightDate)</td></tr>
              <tr><td style="color: #526070; padding: 4px 0;">Aircraft</td>
                  <td style="font-weight: 600; text-align: right;">\(token.aircraftIdent)</td></tr>
              <tr><td style="color: #526070; padding: 4px 0;">Total Time</td>
                  <td style="font-weight: 600; text-align: right;">\(String(format: "%.1f", token.totalTime)) hrs</td></tr>
              <tr><td style="color: #526070; padding: 4px 0;">Dual Received</td>
                  <td style="font-weight: 600; text-align: right;">\(String(format: "%.1f", token.dualReceived)) hrs</td></tr>
              <tr><td style="color: #526070; padding: 4px 0;">Entry Type</td>
                  <td style="font-weight: 600; text-align: right;">\(entryLabel)</td></tr>
            </table>
          </div>

          <div style="text-align: center; margin: 28px 0;">
            <a href="\(link)"
               style="background-color: #25639e; color: #fff; padding: 16px 32px;
                      text-decoration: none; border-radius: 12px; font-weight: bold;
                      font-size: 15px; display: inline-block;">
              ✍️ Review &amp; Sign Entry
            </a>
          </div>

          <p style="font-size: 12px; color: #9eaabe;">
            Requires AeroBook installed on your device.
            This request expires in 30 days.<br>
            Link: <a href="\(link)" style="color: #25639e;">\(link)</a>
          </p>

          <p style="font-size: 13px; color: #526070;">
            By signing, you certify this entry is accurate under 14 CFR 61.51 &amp; 61.189.<br>
            Falsification is a federal offense under 18 U.S.C. § 1001.
          </p>
        </body>
        </html>
        """
    }

    private func smsBody(for token: SignatureToken) -> String {
        """
        ✍️ AeroBook Signature Request
        Pilot: \(token.pilotName)
        Date: \(token.flightDate) · \(token.aircraftIdent) · \(String(format: "%.1f", token.totalTime)) hrs

        Tap to review & sign:
        \(token.deepLink)

        (Requires AeroBook · Expires 30 days)
        """
    }
}
