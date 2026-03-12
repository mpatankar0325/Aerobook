import Foundation
import SwiftUI
import Combine

// MARK: - Signature Request (original, kept for SignatureCanvasView compatibility)

struct SignatureRequest: Identifiable {
    let id        = UUID()
    let flightID:   Int64
    let pilotName:  String
}

// MARK: - Deep Link Manager

final class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    // Original local-sign flow (SignatureCanvasView)
    @Published var activeSignatureRequest: SignatureRequest?

    // Remote-sign flow — instructor opened aerobook://remotesign?...
    @Published var activeRemoteSignToken: SignatureToken?

    // Signature-return applied result banner
    @Published var signatureReturnResult: (success: Bool, message: String)?

    // Remote endorsement sign — instructor opens aerobook://endorsesign?...
    @Published var activeEndorsementToken: EndorsementToken?

    func handleURL(_ url: URL) {
        guard url.scheme == "aerobook" else { return }

        let comps      = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let queryItems = comps?.queryItems ?? []
        func q(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        switch url.host {

        // ── Original local sign: aerobook://sign?entryID=&pilotName= ──────────
        case "sign":
            if let idStr = q("entryID"), let id = Int64(idStr) {
                let name = q("pilotName") ?? "Pilot"
                DispatchQueue.main.async {
                    self.activeSignatureRequest = SignatureRequest(flightID: id, pilotName: name)
                }
            }

        // ── Remote sign request: aerobook://remotesign?token=... ─────────────
        // Opened on instructor's device; resolves into an InstructorRemoteSignView
        case "remotesign":
            if let token = RemoteSignatureService.shared.resolveDeepLink(url) {
                DispatchQueue.main.async {
                    self.activeRemoteSignToken = token
                }
            }

        // ── Signature return: aerobook://sigreturn?token=...&sig=... ─────────
        // Opened on student's device after instructor shares the return link
        case "sigreturn":
            RemoteSignatureService.shared.applyReturnedSignature(url) { success, message in
                DispatchQueue.main.async {
                    self.signatureReturnResult = (success, message)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        self.signatureReturnResult = nil
                    }
                }
            }

        // ── Endorsement sign: aerobook://endorsesign?token=... ──────────────
        // Opened on instructor's device; presents InstructorEndorsementSignView
        case "endorsesign":
            if let token = EndorsementRemoteService.shared.resolveDeepLink(url) {
                DispatchQueue.main.async {
                    self.activeEndorsementToken = token
                }
            }

        // ── Endorsement return: aerobook://endorsereturn?... ─────────────────
        // Opened on student's device after instructor signs and shares return link
        case "endorsereturn":
            EndorsementRemoteService.shared.applyReturn(url) { success, message in
                DispatchQueue.main.async {
                    self.signatureReturnResult = (success, message)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        self.signatureReturnResult = nil
                    }
                }
            }

        default:
            break
        }
    }
}
