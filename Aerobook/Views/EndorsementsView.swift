import SwiftUI
import PencilKit
import MessageUI
import CryptoKit
import Combine

// MARK: - Template Model

struct EndorsementTemplate: Identifiable {
    let id:         String
    let title:      String
    let acRef:      String
    let regulation: String
    let category:   String
    let text:       String
    /// FAR-based expiry in days (nil = permanent)
    let expiryDays: Int?
}

// MARK: - Templates  (bracket placeholder is [PILOT_NAME] — auto-filled from profile)

let endorsementTemplates: [EndorsementTemplate] = [
    .init(id:"A14",    title:"Proof of citizenship",
          acRef:"AC 61-65, A.14", regulation:"49 CFR 1552.3", category:"TSA",
          text:"I certify that [PILOT_NAME] has presented as evidence of U.S. citizenship a [type of document, e.g., birth certificate, passport] in accordance with 49 CFR § 1552.3(h).",
          expiryDays:nil),
    .init(id:"A3",     title:"Pre-solo knowledge test",
          acRef:"AC 61-65, A.3",  regulation:"61.87(b)", category:"Pre-Solo",
          text:"I certify that [PILOT_NAME] has satisfactorily completed the pre-solo knowledge test of § 61.87(b) for the [make and model aircraft].",
          expiryDays:nil),
    .init(id:"A4",     title:"Pre-solo flight training",
          acRef:"AC 61-65, A.4",  regulation:"61.87(c)(d)", category:"Pre-Solo",
          text:"I certify that [PILOT_NAME] has received the required pre-solo training in a [make and model aircraft]. I have determined [he or she] has demonstrated the proficiency of § 61.87(d) and is proficient to make solo flights in [make and model aircraft].",
          expiryDays:nil),
    .init(id:"A6",     title:"Solo flight (initial 90 day)",
          acRef:"AC 61-65, A.6",  regulation:"61.87(n)", category:"Pre-Solo",
          text:"I certify that [PILOT_NAME] has received the required training to solo the [make and model aircraft]. I have determined that [he or she] is proficient to make solo flights in [make and model aircraft] and has met the requirements of § 61.87(n).",
          expiryDays:90),
    .init(id:"A9",     title:"Solo cross-country flight",
          acRef:"AC 61-65, A.9",  regulation:"61.93(c)(1)(2)", category:"Solo",
          text:"I certify that [PILOT_NAME] has received the required training in accordance with § 61.93. I have reviewed [he or she]'s cross-country planning and find it to be correct and that [he or she] is proficient to make the solo cross-country flight from [origination airport] to [destination airport] via [intermediate airports] in a [make and model aircraft].",
          expiryDays:90),
    .init(id:"A32",    title:"Private Pilot: Aero Knowledge",
          acRef:"AC 61-65, A.32", regulation:"61.105", category:"Private",
          text:"I certify that [PILOT_NAME] has received the required training of § 61.105. I have determined that [he or she] is prepared for the [name of knowledge test] knowledge test.",
          expiryDays:nil),
    .init(id:"A33",    title:"Private Pilot: Practical",
          acRef:"AC 61-65, A.33", regulation:"61.107 & 61.109", category:"Private",
          text:"I certify that [PILOT_NAME] has received the required training of §§ 61.107 and 61.109. I have determined that [he or she] is prepared for the [name of practical test] practical test.",
          expiryDays:nil),
    .init(id:"A34",    title:"Commercial Pilot: Knowledge",
          acRef:"AC 61-65, A.34", regulation:"61.125", category:"Commercial",
          text:"I certify that [PILOT_NAME] has received the required training of § 61.125. I have determined that [he or she] is prepared for the [name of knowledge test] knowledge test.",
          expiryDays:nil),
    .init(id:"A35",    title:"Commercial Pilot: Practical",
          acRef:"AC 61-65, A.35", regulation:"61.127 & 61.129", category:"Commercial",
          text:"I certify that [PILOT_NAME] has received the required training of §§ 61.127 and 61.129. I have determined that [he or she] is prepared for the [name of practical test] practical test.",
          expiryDays:nil),
    .init(id:"A68",    title:"Complex airplane",
          acRef:"AC 61-65, A.68", regulation:"61.31(e)", category:"PIC",
          text:"I certify that [PILOT_NAME] has received the required training of § 61.31(e) in a [make and model of complex airplane]. I have determined that [he or she] is proficient in the operation and systems of a complex airplane.",
          expiryDays:nil),
    .init(id:"A69",    title:"High-performance airplane",
          acRef:"AC 61-65, A.69", regulation:"61.31(f)", category:"PIC",
          text:"I certify that [PILOT_NAME] has received the required training of § 61.31(f) in a [make and model of high-performance airplane]. I have determined that [he or she] is proficient in the operation and systems of a high-performance airplane.",
          expiryDays:nil),
    .init(id:"A71",    title:"Tailwheel airplane",
          acRef:"AC 61-65, A.71", regulation:"61.31(i)", category:"PIC",
          text:"I certify that [PILOT_NAME] has received the required training of § 61.31(i) in a [make and model of tailwheel airplane]. I have determined that [he or she] is proficient in the operation of a tailwheel airplane.",
          expiryDays:nil),
    .init(id:"A65",    title:"Flight Review",
          acRef:"AC 61-65, A.65", regulation:"61.56(a) & (c)", category:"Flight Review",
          text:"I certify that [PILOT_NAME] has satisfactorily completed a flight review of § 61.56(a) on [date] consisting of at least 1 hour of flight training and 1 hour of ground training.",
          expiryDays:730),
    .init(id:"A1_CFI", title:"CFI: Prerequisites for practical test",
          acRef:"AC 61-65, A.1",  regulation:"61.39(a)(6)(i)(ii)", category:"CFI",
          text:"I certify that [PILOT_NAME] has received the required training in accordance with §§ 61.183(i) and 61.187(b) and is prepared for the [name of practical test] practical test.",
          expiryDays:nil),
    .init(id:"A2_CFI", title:"CFI: Review of deficiencies",
          acRef:"AC 61-65, A.2",  regulation:"61.39(a)(6)(iii)", category:"CFI",
          text:"I certify that [PILOT_NAME] has demonstrated satisfactory knowledge of the subject areas in which [he or she] was deficient on the [name of knowledge test] airman knowledge test.",
          expiryDays:nil),
    .init(id:"A73",    title:"Retesting after failure",
          acRef:"AC 61-65, A.73", regulation:"61.49", category:"Other",
          text:"I certify that [PILOT_NAME] has received the additional [flight and/or ground] training as required by § 61.49 and have determined that [he or she] is proficient to pass the [name of practical test] practical test.",
          expiryDays:nil),
    .init(id:"SPIN",   title:"Spin training",
          acRef:"AC 61-65, A.1",  regulation:"61.183(i)(1)", category:"CFI",
          text:"I certify that [PILOT_NAME] has received the required training in stall awareness, spin entry, spins, and spin recovery techniques in a [make and model aircraft] and is proficient in those areas.",
          expiryDays:nil)
]

let endorsementCategories = ["All","Pre-Solo","Solo","Private","Commercial",
                              "PIC","Flight Review","CFI","TSA","Other"]

// MARK: - Expiry helpers

extension DatabaseManager.EndorsementRecord {
    func daysRemaining(expiryDays: Int?) -> Int? {
        guard let exp = expiryDays else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        guard let issued = df.date(from: date) else { return nil }
        let expiry = Calendar.current.date(byAdding: .day, value: exp, to: issued) ?? issued
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }
    func expiryStatusType(expiryDays: Int?) -> CurrencyStatus.StatusType? {
        guard let d = daysRemaining(expiryDays: expiryDays) else { return nil }
        if d < 0  { return .expired }
        if d < 30 { return .warning }
        return .current
    }
}

// MARK: - Endorsement Remote Token
//
// Mirrors SignatureToken but carries endorsement-specific payload.
// Encoded into aerobook://endorsesign?... and returned as aerobook://endorsereturn?...

struct EndorsementToken: Codable, Identifiable {
    var id:              String
    var pilotName:       String
    var templateId:      String
    var templateTitle:   String
    var acRef:           String
    var endorsementText: String          // fully filled-in endorsement text
    var date:            String
    var createdAt:       Date
    var expiresAt:       Date
    var status:          Status
    // Filled after instructor signs
    var instructorName:  String
    var instructorCert:  String
    var instructorExpiry:String
    var signatureBase64: String
    var signatureHash:   String
    // Local DB row ID for the saved endorsement record (-1 = not yet saved)
    var endorsementDBID: Int64

    enum Status: String, Codable {
        case pending, signed, expired, cancelled
    }

    var isExpired: Bool { Date() > expiresAt }

    var deepLink: String {
        var c = URLComponents(string: "aerobook://endorsesign")!
        c.queryItems = [
            URLQueryItem(name: "token",    value: id),
            URLQueryItem(name: "pilot",    value: pilotName),
            URLQueryItem(name: "tmplId",   value: templateId),
            URLQueryItem(name: "tmplTitle",value: templateTitle),
            URLQueryItem(name: "acRef",    value: acRef),
            URLQueryItem(name: "date",     value: date),
            URLQueryItem(name: "text",     value: endorsementText),
            URLQueryItem(name: "dbID",     value: String(endorsementDBID)),
        ]
        return c.url?.absoluteString ?? ""
    }
}

// MARK: - Endorsement Remote Service

class EndorsementRemoteService: NSObject, ObservableObject,
                                 MFMailComposeViewControllerDelegate,
                                 MFMessageComposeViewControllerDelegate {

    static let shared = EndorsementRemoteService()
    private let storageKey = "aerobook.endorsementTokens"

    @Published var tokens: [EndorsementToken] = []

    private override init() {
        super.init()
        load(); purgeExpired()
    }

    // MARK: Create token

    func createToken(template: EndorsementTemplate,
                     pilotName: String,
                     endorsementText: String,
                     date: String,
                     dbID: Int64 = -1) -> EndorsementToken {
        let tok = EndorsementToken(
            id:              UUID().uuidString,
            pilotName:       pilotName,
            templateId:      template.id,
            templateTitle:   template.title,
            acRef:           template.acRef,
            endorsementText: endorsementText,
            date:            date,
            createdAt:       Date(),
            expiresAt:       Calendar.current.date(byAdding: .day, value: 30, to: Date())!,
            status:          .pending,
            instructorName:  "",
            instructorCert:  "",
            instructorExpiry:"",
            signatureBase64: "",
            signatureHash:   "",
            endorsementDBID: dbID
        )
        tokens.append(tok)
        save()
        return tok
    }

    // MARK: Deep-link resolution (instructor device)

    func resolveDeepLink(_ url: URL) -> EndorsementToken? {
        guard url.host == "endorsesign" else { return nil }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
        else { return nil }
        func q(_ n: String) -> String { items.first(where: { $0.name == n })?.value ?? "" }

        let tokenID = q("token")
        // If we already hold it, return our copy
        if let existing = tokens.first(where: { $0.id == tokenID }) { return existing }

        // Reconstruct a minimal token for the instructor's device
        return EndorsementToken(
            id:              tokenID.isEmpty ? UUID().uuidString : tokenID,
            pilotName:       q("pilot"),
            templateId:      q("tmplId"),
            templateTitle:   q("tmplTitle"),
            acRef:           q("acRef"),
            endorsementText: q("text"),
            date:            q("date"),
            createdAt:       Date(),
            expiresAt:       Calendar.current.date(byAdding: .day, value: 30, to: Date())!,
            status:          .pending,
            instructorName:  "",
            instructorCert:  "",
            instructorExpiry:"",
            signatureBase64: "",
            signatureHash:   "",
            endorsementDBID: Int64(q("dbID")) ?? -1
        )
    }

    // MARK: Build return URL (instructor → student)

    func buildReturnURL(token: EndorsementToken,
                        cfiName: String, cfiCert: String, cfiExpiry: String,
                        signatureBase64: String) -> String {
        // SHA-256 tamper seal
        let raw  = "\(token.id)|\(token.templateId)|\(token.date)|\(cfiName)|\(cfiCert)"
        let hash: String
        if let d = raw.data(using: .utf8) {
            hash = SHA256.hash(data: d).compactMap { String(format: "%02x", $0) }.joined()
        } else { hash = UUID().uuidString }

        var c = URLComponents(string: "aerobook://endorsereturn")!
        c.queryItems = [
            URLQueryItem(name: "token",   value: token.id),
            URLQueryItem(name: "dbID",    value: String(token.endorsementDBID)),
            URLQueryItem(name: "tmplId",  value: token.templateId),
            URLQueryItem(name: "tmplTitle",value: token.templateTitle),
            URLQueryItem(name: "acRef",   value: token.acRef),
            URLQueryItem(name: "text",    value: token.endorsementText),
            URLQueryItem(name: "date",    value: token.date),
            URLQueryItem(name: "pilot",   value: token.pilotName),
            URLQueryItem(name: "cfiName", value: cfiName),
            URLQueryItem(name: "cfiCert", value: cfiCert),
            URLQueryItem(name: "expiry",  value: cfiExpiry),
            URLQueryItem(name: "hash",    value: hash),
            URLQueryItem(name: "sig",     value: signatureBase64),
        ]
        return c.url?.absoluteString ?? ""
    }

    // MARK: Apply returned signature (student device)

    func applyReturn(_ url: URL, completion: @escaping (Bool, String) -> Void) {
        guard url.host == "endorsereturn",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
        else { completion(false, "Invalid endorsement return link."); return }
        func q(_ n: String) -> String { items.first(where: { $0.name == n })?.value ?? "" }

        let tokenID = q("token")
        let dbID    = Int64(q("dbID")) ?? -1
        let cfiName = q("cfiName")
        let cfiCert = q("cfiCert")
        let hash    = q("hash")
        let sig     = q("sig")
        // Fields needed to save a new record if DB row doesn't exist yet
        let tmplId    = q("tmplId")
        let tmplTitle = q("tmplTitle")
        let text      = q("text")
        let date      = q("date")

        guard !cfiName.isEmpty, !cfiCert.isEmpty, !sig.isEmpty else {
            completion(false, "Endorsement signature data is incomplete."); return
        }

        let finalize: (Bool) -> Void = { success in
            if success {
                self.markTokenSigned(tokenID: tokenID, name: cfiName,
                                     cert: cfiCert, sig: sig, hash: hash)
                completion(true, "Endorsement signed by \(cfiName).")
            } else {
                completion(false, "Failed to apply signature to endorsement.")
            }
        }

        if dbID > 0 {
            // Update existing record
            DatabaseManager.shared.updateEndorsementSignature(
                id: dbID, signatureBlob: sig,
                instructorName: cfiName, instructorCertificate: cfiCert,
                completion: finalize)
        } else {
            // Insert new record (endorsement was sent before being saved locally)
            DatabaseManager.shared.addEndorsement(
                templateId: tmplId, title: tmplTitle, text: text,
                date: date.isEmpty ? todayString() : date,
                instructorName: cfiName, instructorCertificate: cfiCert,
                signatureBlob: sig, completion: { rowID in
                    finalize(rowID != nil)
                })
        }
    }

    // MARK: Email / Message composers

    func emailVC(for token: EndorsementToken) -> MFMailComposeViewController? {
        guard MFMailComposeViewController.canSendMail() else { return nil }
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = self
        vc.setSubject("Endorsement Signature Request — \(token.templateTitle) · \(token.pilotName)")
        vc.setMessageBody(htmlBody(token), isHTML: true)
        return vc
    }

    func messageVC(for token: EndorsementToken) -> MFMessageComposeViewController? {
        guard MFMessageComposeViewController.canSendText() else { return nil }
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = self
        vc.body = smsBody(token)
        return vc
    }

    func mailComposeController(_ c: MFMailComposeViewController,
                               didFinishWith _: MFMailComposeResult, error _: Error?) {
        c.dismiss(animated: true)
    }
    func messageComposeViewController(_ c: MFMessageComposeViewController,
                                      didFinishWith _: MessageComposeResult) {
        c.dismiss(animated: true)
    }

    // MARK: Cancel

    func cancel(_ token: EndorsementToken) {
        if let idx = tokens.firstIndex(where: { $0.id == token.id }) {
            tokens[idx].status = .cancelled; save()
        }
    }

    // MARK: Persistence

    private func markTokenSigned(tokenID: String, name: String, cert: String,
                                  sig: String, hash: String) {
        if let idx = tokens.firstIndex(where: { $0.id == tokenID }) {
            tokens[idx].status          = .signed
            tokens[idx].instructorName  = name
            tokens[idx].instructorCert  = cert
            tokens[idx].signatureBase64 = sig
            tokens[idx].signatureHash   = hash
            save()
            NotificationCenter.default.post(name: .logbookDataDidChange, object: nil)
        }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(d, forKey: storageKey)
        }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let t = try? JSONDecoder().decode([EndorsementToken].self, from: d)
        else { return }
        tokens = t
    }
    private func purgeExpired() {
        tokens = tokens.map {
            var t = $0; if t.status == .pending && t.isExpired { t.status = .expired }; return t
        }
        save()
    }
    private func todayString() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; return df.string(from: Date())
    }

    // MARK: Message bodies

    private func htmlBody(_ token: EndorsementToken) -> String {
        let link = token.deepLink
        return """
        <!DOCTYPE html><html><body
         style="font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#0f141e;">
          <div style="background:#f5f8fc;border-radius:16px;padding:24px;margin-bottom:20px;">
            <h2 style="margin:0 0 4px 0;font-size:20px;">✍️ Endorsement Signature Requested</h2>
            <p style="margin:0;font-size:13px;color:#526070;">\(token.acRef) · \(token.templateTitle)</p>
          </div>
          <p style="font-size:15px;">Hi Instructor,</p>
          <p style="font-size:15px;"><strong>\(token.pilotName)</strong> has requested your digital signature on the following AC 61-65 endorsement:</p>
          <div style="background:#fff;border:1px solid #dce6f2;border-radius:12px;padding:18px;margin:20px 0;font-family:Georgia,serif;font-size:14px;line-height:1.6;color:#0f141e;">
            \(token.endorsementText.replacingOccurrences(of: "\n", with: "<br>"))
          </div>
          <div style="text-align:center;margin:28px 0;">
            <a href="\(link)" style="background-color:#25639e;color:#fff;padding:16px 32px;text-decoration:none;border-radius:12px;font-weight:bold;font-size:15px;display:inline-block;">
              ✍️ Review &amp; Sign Endorsement
            </a>
          </div>
          <p style="font-size:12px;color:#9eaabe;">Requires AeroBook. Expires in 30 days.<br>Link: <a href="\(link)" style="color:#25639e;">\(link)</a></p>
          <p style="font-size:12px;color:#526070;">By signing you certify this endorsement is accurate under 14 CFR 61.189 and AC 61-65. Falsification is a federal offense under 18 U.S.C. § 1001.</p>
        </body></html>
        """
    }
    private func smsBody(_ token: EndorsementToken) -> String {
        "✍️ AeroBook Endorsement Request\nPilot: \(token.pilotName)\n\(token.templateTitle) (\(token.acRef))\n\nTap to review & sign:\n\(token.deepLink)\n\n(Requires AeroBook · Expires 30 days)"
    }
}

// MARK: - Main EndorsementsView

struct EndorsementsView: View {
    @State private var searchText        = ""
    @State private var selectedCategory  = "All"
    @State private var showHistory       = false
    @State private var showPending       = false
    @State private var copiedId: String? = nil
    @State private var history: [DatabaseManager.EndorsementRecord] = []
    @State private var activeTemplate: EndorsementTemplate? = nil
    @StateObject private var remoteService = EndorsementRemoteService.shared

    // Apply return link
    @State private var showApplySheet   = false
    @State private var pastedReturnURL  = ""
    @State private var applyBanner: (success: Bool, msg: String)? = nil

    var filteredTemplates: [EndorsementTemplate] {
        endorsementTemplates.filter {
            (selectedCategory == "All" || $0.category == selectedCategory)
            && (searchText.isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.acRef.localizedCaseInsensitiveContains(searchText)
                || $0.regulation.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var pendingCount: Int {
        remoteService.tokens.filter { $0.status == .pending }.count
    }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar.padding(.horizontal).padding(.top, 8).padding(.bottom, 16)

                    // Apply-return banner
                    if let banner = applyBanner {
                        applyResultBanner(banner)
                            .padding(.horizontal).padding(.bottom, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if showPending       { pendingTokensView }
                    else if showHistory  { historyList }
                    else                 { templateList }
                }
            }
            .navigationTitle("").navigationBarHidden(true)
            .onAppear { loadHistory() }
            .sheet(item: $activeTemplate) { tmpl in
                EndorsementCreateSheet(template: tmpl) { loadHistory(); activeTemplate = nil }
            }
            .sheet(isPresented: $showApplySheet) { applyReturnSheet }
            .animation(.spring(response: 0.3), value: applyBanner != nil)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom) {
                AeroPageHeader(title: "Endorsements", subtitle: "AC 61-65 CFI templates")
                Spacer()
                HStack(spacing: 8) {
                    // Apply return link button
                    Button(action: { showApplySheet = true }) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 15))
                            .padding(9)
                            .background(Color.statusGreen.opacity(0.1))
                            .foregroundStyle(Color.statusGreen)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.statusGreen.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Mode toggle
                    segmentPicker
                }
            }
        }
    }

    private var segmentPicker: some View {
        HStack(spacing: 0) {
            ForEach([("doc.text.magnifyingglass","Templates",false,false),
                     ("clock.arrow.circlepath","History",true,false),
                     ("envelope.badge.fill","Pending",false,true)], id: \.1) { icon, label, isHistory, isPending in
                let active = isHistory ? showHistory : isPending ? showPending : (!showHistory && !showPending)
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        showHistory = isHistory; showPending = isPending
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: icon).font(.system(size: 11))
                        Text(label).font(.system(size: 11, weight: .bold))
                        if isPending && pendingCount > 0 {
                            Text("\(pendingCount)")
                                .font(.system(size: 9, weight: .black))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.white.opacity(0.3))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(active ? AeroTheme.brandPrimary : Color.clear)
                    .foregroundStyle(active ? .white : AeroTheme.textSecondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .background(AeroTheme.cardBg)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AeroTheme.cardStroke, lineWidth: 1))
    }

    // MARK: - Template List

    private var templateList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14))
                        .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                    TextField("Search by title or AC reference...", text: $searchText)
                        .font(.system(size: 14)).foregroundStyle(AeroTheme.textPrimary)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(AeroTheme.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(endorsementCategories, id: \.self) { cat in
                            Button(action: { selectedCategory = cat }) {
                                Text(cat).font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(selectedCategory == cat ? AeroTheme.brandPrimary : AeroTheme.cardBg)
                                    .foregroundStyle(selectedCategory == cat ? .white : AeroTheme.textSecondary)
                                    .cornerRadius(20)
                                    .overlay(RoundedRectangle(cornerRadius: 20)
                                        .stroke(selectedCategory == cat ? AeroTheme.brandPrimary : AeroTheme.cardStroke, lineWidth: 1))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .animation(.spring(response: 0.25), value: selectedCategory)
                        }
                    }.padding(.horizontal)
                }
            }.padding(.bottom, 12)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    ForEach(filteredTemplates) { tmpl in
                        TemplateCard(template: tmpl, isCopied: copiedId == tmpl.id,
                                     onCopy:   { copyTemplate(tmpl) },
                                     onSign:   { activeTemplate = tmpl },
                                     onSendRemote: { sendRemote(tmpl) })
                    }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal).padding(.bottom, 24)
            }
        }
    }

    // MARK: - History List

    private var historyList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                if history.isEmpty {
                    emptyHistoryState
                } else {
                    ForEach(history) { record in
                        let tmpl = endorsementTemplates.first { $0.id == record.templateId }
                        HistoryCard(record: record, templateExpiryDays: tmpl?.expiryDays) {
                            deleteRecord(id: record.id)
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
            .padding(.horizontal).padding(.bottom, 24)
        }
    }

    // MARK: - Pending Tokens View

    private var pendingTokensView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                if remoteService.tokens.isEmpty {
                    emptyPendingState
                } else {
                    let groups: [(String, EndorsementToken.Status, Color)] = [
                        ("Awaiting Signature", .pending,   Color.statusAmber),
                        ("Signed & Complete",  .signed,    Color.statusGreen),
                        ("Expired / Cancelled",.expired,   AeroTheme.textTertiary),
                    ]
                    ForEach(groups, id: \.0) { title, status, color in
                        let toks = remoteService.tokens.filter {
                            $0.status == status ||
                            (status == .expired && ($0.status == .expired || $0.status == .cancelled))
                        }.sorted { $0.createdAt > $1.createdAt }
                        if !toks.isEmpty {
                            endorsementTokenSection(title: title, color: color, tokens: toks)
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
            .padding(.horizontal).padding(.top, 4).padding(.bottom, 24)
        }
    }

    private func endorsementTokenSection(title: String, color: Color,
                                          tokens: [EndorsementToken]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(color)
                Spacer()
                Text("\(tokens.count)").font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color.opacity(0.12)).foregroundStyle(color).cornerRadius(20)
            }
            ForEach(tokens) { tok in
                EndorsementTokenCard(token: tok,
                    onResend: { resendToken(tok) },
                    onCancel: { remoteService.cancel(tok) })
            }
        }
    }

    private var emptyPendingState: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge").font(.system(size: 44))
                .foregroundStyle(AeroTheme.textTertiary.opacity(0.4))
            Text("No Remote Requests").font(.system(size: 16, weight: .bold))
                .foregroundStyle(AeroTheme.textPrimary)
            Text("Tap a template and choose \"Request Remotely\" to send an endorsement to your instructor for signature.")
                .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    // MARK: - Apply Return Link Sheet

    private var applyReturnSheet: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apply Signed Endorsement")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AeroTheme.textPrimary)
                        Text("Paste the aerobook://endorsereturn?... link your instructor sent back to apply their signature to the endorsement.")
                            .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)

                    // Clipboard auto-detect
                    if let clip = UIPasteboard.general.string,
                       clip.hasPrefix("aerobook://endorsereturn") {
                        Button(action: { pastedReturnURL = clip }) {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(Color.statusGreen)
                                Text("Use Clipboard Link")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AeroTheme.textPrimary)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.statusGreen)
                            }
                            .padding(14).background(Color.statusGreen.opacity(0.07))
                            .cornerRadius(AeroTheme.radiusMd)
                            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                                .stroke(Color.statusGreen.opacity(0.2), lineWidth: 1))
                        }.buttonStyle(PlainButtonStyle())
                    }

                    ZStack(alignment: .topLeading) {
                        if pastedReturnURL.isEmpty {
                            Text("aerobook://endorsereturn?...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AeroTheme.textTertiary)
                                .padding(.horizontal, 14).padding(.vertical, 14)
                        }
                        TextEditor(text: $pastedReturnURL)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 100).padding(10)
                            .scrollContentBackground(.hidden)
                    }
                    .background(AeroTheme.fieldBg).cornerRadius(AeroTheme.radiusMd)
                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                        .stroke(AeroTheme.fieldStroke, lineWidth: 1))

                    Button(action: applyPasted) {
                        Text("Apply Endorsement Signature")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(pastedReturnURL.hasPrefix("aerobook://endorsereturn")
                                ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
                            .foregroundStyle(.white).cornerRadius(AeroTheme.radiusMd)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!pastedReturnURL.hasPrefix("aerobook://endorsereturn"))

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Apply Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showApplySheet = false }
                }
            }
        }
    }

    private func applyResultBanner(_ banner: (success: Bool, msg: String)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: banner.success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(banner.success ? Color.statusGreen : Color.red)
            Text(banner.msg)
                .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary).lineLimit(2)
            Spacer()
            Button(action: { withAnimation { applyBanner = nil } }) {
                Image(systemName: "xmark").font(.system(size: 11))
                    .foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(14)
        .background(banner.success ? Color.statusGreenBg : Color.red.opacity(0.06))
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke((banner.success ? Color.statusGreen : Color.red).opacity(0.2), lineWidth: 1))
    }

    private var emptyHistoryState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(AeroTheme.brandPrimary.opacity(0.08)).frame(width: 72, height: 72)
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 28))
                    .foregroundStyle(AeroTheme.brandPrimary.opacity(0.4))
            }
            VStack(spacing: 6) {
                Text("No signed endorsements yet").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text("Use a template to create your first endorsement")
                    .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    // MARK: - Helpers

    private func loadHistory() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DatabaseManager.shared.fetchEndorsements()
            DispatchQueue.main.async { history = r }
        }
    }
    private func copyTemplate(_ tmpl: EndorsementTemplate) {
        let profile = DatabaseManager.shared.fetchUserProfile()
        let name = profile["pilot_name"] as? String ?? "[Pilot Name]"
        UIPasteboard.general.string = tmpl.text.replacingOccurrences(of: "[PILOT_NAME]", with: name)
        withAnimation { copiedId = tmpl.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { if copiedId == tmpl.id { copiedId = nil } }
        }
    }
    private func deleteRecord(id: Int64) {
        DatabaseManager.shared.deleteEndorsement(id: id) { _ in loadHistory() }
    }
    private func sendRemote(_ tmpl: EndorsementTemplate) {
        activeTemplate = tmpl  // opens EndorsementCreateSheet which now shows send option
    }
    private func resendToken(_ tok: EndorsementToken) {
        if MFMailComposeViewController.canSendMail(),
           let vc = EndorsementRemoteService.shared.emailVC(for: tok) {
            // Present via UIKit since we need MFMailComposeVC
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })?.rootViewController?
                .present(vc, animated: true)
        } else if MFMessageComposeViewController.canSendText(),
                  let vc = EndorsementRemoteService.shared.messageVC(for: tok) {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })?.rootViewController?
                .present(vc, animated: true)
        } else {
            UIPasteboard.general.string = tok.deepLink
        }
    }
    private func applyPasted() {
        guard let url = URL(string: pastedReturnURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "aerobook" else { return }
        showApplySheet = false
        EndorsementRemoteService.shared.applyReturn(url) { success, msg in
            withAnimation { applyBanner = (success, msg) }
            loadHistory()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                withAnimation { applyBanner = nil }
            }
        }
    }
}

// MARK: - TemplateCard (updated with Send Remotely button)

struct TemplateCard: View {
    let template: EndorsementTemplate
    let isCopied: Bool
    let onCopy: () -> Void
    let onSign: () -> Void
    let onSendRemote: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(template.category)
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AeroTheme.brandPrimary.opacity(0.1))
                    .foregroundStyle(AeroTheme.brandPrimary).cornerRadius(6)
                Text(template.acRef)
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(AeroTheme.textTertiary)
                Text("§\(template.regulation)")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(AeroTheme.textTertiary)
                Spacer()
                if let exp = template.expiryDays {
                    HStack(spacing: 3) {
                        Image(systemName: "clock").font(.system(size: 8))
                        Text(exp == 730 ? "24 mo" : "\(exp)d")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.statusAmberBg).foregroundStyle(Color.statusAmber).cornerRadius(5)
                }
            }

            Text(template.title)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(AeroTheme.textPrimary)

            if expanded {
                Text(template.text)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(AeroTheme.textSecondary)
                    .lineSpacing(4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                // Expand/collapse
                Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AeroTheme.textTertiary)
                        .padding(8)
                        .background(AeroTheme.fieldBg).cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())

                // Copy
                Button(action: onCopy) {
                    HStack(spacing: 5) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isCopied ? Color.statusGreen.opacity(0.12) : AeroTheme.fieldBg)
                    .foregroundStyle(isCopied ? Color.statusGreen : AeroTheme.textSecondary)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(isCopied ? Color.statusGreen.opacity(0.2) : AeroTheme.cardStroke, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())

                // Sign (instructor present)
                Button(action: onSign) {
                    HStack(spacing: 5) {
                        Image(systemName: "signature").font(.system(size: 11))
                        Text("Sign").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(AeroTheme.brandPrimary)
                    .foregroundStyle(.white).cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())

                // Send Remotely ← NEW
                Button(action: onSendRemote) {
                    HStack(spacing: 5) {
                        Image(systemName: "envelope.badge.fill").font(.system(size: 11))
                        Text("Remote").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.sky500.opacity(0.1))
                    .foregroundStyle(Color.sky500).cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.sky500.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(18).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
        .animation(.spring(response: 0.3), value: expanded)
    }
}

// MARK: - HistoryCard

struct HistoryCard: View {
    let record: DatabaseManager.EndorsementRecord
    let templateExpiryDays: Int?
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false
    @State private var showSig           = false

    private var statusColor: Color {
        switch record.expiryStatusType(expiryDays: templateExpiryDays) {
        case .current: return .statusGreen
        case .warning: return .statusAmber
        case .expired: return .statusRed
        case .none:    return AeroTheme.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if templateExpiryDays != nil {
                    ZStack {
                        Circle().fill(statusColor.opacity(0.1)).frame(width: 28, height: 28)
                        Image(systemName: "clock.fill").font(.system(size: 11)).foregroundStyle(statusColor)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AeroTheme.textPrimary)
                    Text("Signed \(record.date)").font(.system(size: 11)).foregroundStyle(AeroTheme.textTertiary)
                }
                Spacer()
                if let days = record.daysRemaining(expiryDays: templateExpiryDays) {
                    VStack(alignment: .trailing, spacing: 0) {
                        if days < 0 {
                            Text("EXPIRED").font(.system(size: 9, weight: .black)).foregroundStyle(statusColor)
                        } else {
                            Text("\(days)").font(.system(size: 18, weight: .light, design: .rounded))
                                .foregroundStyle(statusColor)
                            Text("days").font(.system(size: 9)).foregroundStyle(statusColor.opacity(0.8))
                        }
                    }
                }
            }

            Text(record.text)
                .font(.system(size: 12, design: .serif)).foregroundStyle(AeroTheme.textSecondary)
                .lineSpacing(3)

            HStack(spacing: 10) {
                if !record.signatureBlob.isEmpty {
                    Button(action: { showSig.toggle() }) {
                        HStack(spacing: 5) {
                            Image(systemName: showSig ? "eye.slash" : "eye.fill")
                                .font(.system(size: 10))
                            Text(showSig ? "Hide Sig" : "View Sig")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.statusGreen.opacity(0.1))
                        .foregroundStyle(Color.statusGreen).cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Label("Unsigned", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.statusAmber)
                }

                if !record.instructorName.isEmpty {
                    Text(record.instructorName)
                        .font(.system(size: 11)).foregroundStyle(AeroTheme.textTertiary)
                }

                Spacer()

                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.6))
                }
                .buttonStyle(PlainButtonStyle())
            }

            if showSig, let imgData = Data(base64Encoded: record.signatureBlob),
               let img = UIImage(data: imgData) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 100)
                    .background(Color.white).cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.statusGreen.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(18).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(templateExpiryDays != nil ? statusColor.opacity(0.2) : AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
        .confirmationDialog("Delete this endorsement?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - EndorsementTokenCard

struct EndorsementTokenCard: View {
    let token: EndorsementToken
    let onResend: () -> Void
    let onCancel: () -> Void
    @State private var expanded = false

    private var statusColor: Color {
        switch token.status {
        case .pending:   return Color.statusAmber
        case .signed:    return Color.statusGreen
        case .expired, .cancelled: return AeroTheme.textTertiary
        }
    }
    private var statusIcon: String {
        switch token.status {
        case .pending:            return "clock.fill"
        case .signed:             return "checkmark.seal.fill"
        case .expired:            return "clock.badge.xmark.fill"
        case .cancelled:          return "xmark.circle.fill"
        }
    }
    private var statusLabel: String {
        switch token.status {
        case .pending:   return "Pending"
        case .signed:    return "Signed"
        case .expired:   return "Expired"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(statusColor.opacity(0.1)).frame(width: 38, height: 38)
                    Image(systemName: statusIcon).font(.system(size: 15)).foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(token.templateTitle)
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(AeroTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(statusLabel)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(statusColor.opacity(0.12)).foregroundStyle(statusColor).cornerRadius(20)
                    }
                    Text("\(token.acRef) · \(token.date)")
                        .font(.system(size: 11)).foregroundStyle(AeroTheme.textTertiary)
                }

                Button(action: { withAnimation(.spring(response: 0.3)) { expanded.toggle() } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11)).foregroundStyle(AeroTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(14)

            if expanded {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 10) {
                    if token.status == .signed {
                        HStack(spacing: 8) {
                            Image(systemName: "person.badge.key.fill").font(.system(size: 11))
                                .foregroundStyle(Color.statusGreen)
                            Text("Signed by \(token.instructorName) · \(token.instructorCert)")
                                .font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary)
                        }
                    }
                    Text(token.endorsementText)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(AeroTheme.textSecondary)
                        .lineSpacing(3)

                    if token.status == .pending {
                        HStack(spacing: 8) {
                            Button(action: onResend) {
                                Label("Resend", systemImage: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(AeroTheme.brandPrimary).foregroundStyle(.white).cornerRadius(10)
                            }.buttonStyle(PlainButtonStyle())
                            Button(action: onCancel) {
                                Label("Cancel", systemImage: "xmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(AeroTheme.fieldBg)
                                    .foregroundStyle(Color.red.opacity(0.8)).cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.red.opacity(0.2), lineWidth: 1))
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }
                    Color.clear.frame(height: 2)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(token.status == .pending ? statusColor.opacity(0.25) : AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 6, x: 0, y: 2)
    }
}

// MARK: - EndorsementCreateSheet (updated with Remote Send option)

struct EndorsementCreateSheet: View {
    let template: EndorsementTemplate
    let onSave:   () -> Void

    @Environment(\.dismiss) var dismiss
    @State private var customText: String
    @State private var date           = Date()
    @State private var instructorName: String
    @State private var instructorCert: String
    @State private var canvasView     = PKCanvasView()
    @State private var isSaving       = false
    @State private var hasSignature   = false

    // Remote send state
    @State private var showSendPicker  = false
    @State private var pendingToken: EndorsementToken?
    @State private var showMailVC      = false
    @State private var showMsgVC       = false
    @State private var mailVC: MFMailComposeViewController?
    @State private var msgVC:  MFMessageComposeViewController?
    @State private var remoteSent      = false

    init(template: EndorsementTemplate, onSave: @escaping () -> Void) {
        self.template = template
        self.onSave   = onSave
        let profile    = DatabaseManager.shared.fetchUserProfile()
        let pilotName  = profile["pilot_name"] as? String ?? ""
        let filled     = template.text.replacingOccurrences(of: "[PILOT_NAME]",
                            with: pilotName.isEmpty ? "[Pilot Name]" : pilotName)
        _customText     = State(initialValue: filled)
        _instructorName = State(initialValue: pilotName)
        _instructorCert = State(initialValue: profile["certificate_number"] as? String ?? "")
    }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        // Meta badges
                        HStack(spacing: 8) {
                            Text(template.category)
                                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(AeroTheme.brandPrimary.opacity(0.1))
                                .foregroundStyle(AeroTheme.brandPrimary).cornerRadius(6)
                            Text(template.acRef).font(.system(size: 9, weight: .bold)).foregroundStyle(AeroTheme.textTertiary)
                            Text("§ \(template.regulation)").font(.system(size: 9, weight: .bold)).foregroundStyle(AeroTheme.textTertiary)
                            if let exp = template.expiryDays {
                                Spacer()
                                HStack(spacing: 3) {
                                    Image(systemName: "clock").font(.system(size: 8))
                                    Text("Expires in \(exp == 730 ? "24 months" : "\(exp) days")")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.statusAmberBg).foregroundStyle(Color.statusAmber).cornerRadius(5)
                            }
                        }

                        // Endorsement text
                        EntryCard(title: "Endorsement Text", icon: "doc.text.fill") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 5) {
                                    Image(systemName: "info.circle").font(.system(size: 11))
                                        .foregroundStyle(AeroTheme.brandPrimary)
                                    Text("Pilot name pre-filled from profile. Replace remaining bracketed fields.")
                                        .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary).lineSpacing(3)
                                }
                                TextEditor(text: $customText)
                                    .font(.system(size: 14, design: .serif))
                                    .foregroundColor(Color(red: 15/255, green: 20/255, blue: 30/255))
                                    .tint(AeroTheme.brandPrimary).scrollContentBackground(.hidden)
                                    .frame(minHeight: 140).padding(10)
                                    .background(Color(red: 0.96, green: 0.97, blue: 0.99))
                                    .colorScheme(.light).cornerRadius(AeroTheme.radiusMd)
                                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                                        .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                            }
                        }

                        // Instructor details
                        EntryCard(title: "Instructor Details", icon: "person.badge.key.fill") {
                            VStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Date of Endorsement")
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(AeroTheme.textSecondary)
                                    HStack(spacing: 10) {
                                        Image(systemName: "calendar").font(.system(size: 13))
                                            .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7)).frame(width: 20)
                                        DatePicker("", selection: $date, displayedComponents: .date)
                                            .labelsHidden().tint(AeroTheme.brandPrimary)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(AeroTheme.fieldBg).cornerRadius(AeroTheme.radiusMd)
                                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                                        .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                                }
                                AeroField(label: "Instructor Name", text: $instructorName,
                                          placeholder: "Full name", icon: "person.fill")
                                AeroField(label: "CFI Certificate Number", text: $instructorCert,
                                          placeholder: "CFI 1234567", icon: "creditcard.fill")
                            }
                        }

                        // CFI Signature canvas
                        EntryCard(title: "CFI Signature", icon: "signature") {
                            VStack(alignment: .leading, spacing: 10) {
                                PencilKitCanvas(canvasView: $canvasView)
                                    .frame(height: 160)
                                    .background(Color.white).cornerRadius(AeroTheme.radiusMd)
                                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                                        .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                                Button(action: { canvasView.drawing = PKDrawing() }) {
                                    Label("Clear Signature", systemImage: "trash")
                                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.statusRed)
                                }
                            }
                        }

                        // ── Action section ──────────────────────────────────

                        // Save locally (instructor present)
                        Button(action: saveEndorsement) {
                            HStack(spacing: 8) {
                                if isSaving { ProgressView().tint(.white) }
                                else {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("Save Endorsement")
                                }
                            }
                            .aeroPrimaryButton()
                        }
                        .disabled(isSaving || instructorName.isEmpty)
                        .opacity(instructorName.isEmpty ? 0.5 : 1)

                        // OR separator
                        HStack(spacing: 10) {
                            Rectangle().fill(AeroTheme.cardStroke).frame(height: 1)
                            Text("OR").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AeroTheme.textTertiary)
                            Rectangle().fill(AeroTheme.cardStroke).frame(height: 1)
                        }

                        // Send remotely to instructor ← NEW
                        remoteSendSection

                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal).padding(.top, 12).padding(.bottom, 24)
                }
            }
            .navigationTitle(template.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(AeroTheme.textSecondary)
                }
            }
            .sheet(isPresented: $showMailVC) {
                if let vc = mailVC { MailComposerSheet(viewController: vc) }
            }
            .sheet(isPresented: $showMsgVC) {
                if let vc = msgVC { MessageComposerSheet(viewController: vc) }
            }
            .sheet(isPresented: $showSendPicker) { sendChannelSheet }
        }
    }

    // MARK: Remote Send Section

    private var remoteSendSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.sky500.opacity(0.1)).frame(width: 40, height: 40)
                    Image(systemName: "envelope.badge.shield.half.filled.fill")
                        .font(.system(size: 16)).foregroundStyle(Color.sky500)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Request Endorsement Remotely")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(AeroTheme.textPrimary)
                    Text("Instructor not present? Send the endorsement text for them to review and sign on their device.")
                        .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.sky500.opacity(0.05))
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(Color.sky500.opacity(0.2), lineWidth: 1))

            Button(action: prepareSendRemote) {
                HStack(spacing: 10) {
                    Image(systemName: remoteSent ? "checkmark.circle.fill" : "paperplane.fill")
                        .font(.system(size: 14))
                    Text(remoteSent ? "Request Sent!" : "Send to Instructor for Signature")
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(remoteSent ? Color.statusGreen : Color.sky500)
                .foregroundStyle(.white).cornerRadius(AeroTheme.radiusMd)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(remoteSent)

            if remoteSent {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(AeroTheme.brandPrimary)
                    Text("Track this request in Endorsements → Pending tab.")
                        .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
                }
            }
        }
    }

    // MARK: Send Channel Sheet

    private var sendChannelSheet: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Image(systemName: "envelope.badge.shield.half.filled.fill")
                            .font(.system(size: 36)).foregroundStyle(Color.sky500)
                        Text("Send Endorsement Request").font(.system(size: 20, weight: .bold))
                        Text("Choose how to deliver this endorsement to your instructor.")
                            .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }.padding(.top, 16)

                    VStack(spacing: 12) {
                        sendChannelButton(icon: "envelope.fill", color: AeroTheme.brandPrimary,
                                          label: "Send via Email") {
                            showSendPicker = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if let tok = pendingToken,
                                   let vc = EndorsementRemoteService.shared.emailVC(for: tok) {
                                    mailVC = vc; showMailVC = true; remoteSent = true
                                }
                            }
                        }
                        sendChannelButton(icon: "message.fill", color: Color.statusGreen,
                                          label: "Send via iMessage / SMS") {
                            showSendPicker = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                if let tok = pendingToken,
                                   let vc = EndorsementRemoteService.shared.messageVC(for: tok) {
                                    msgVC = vc; showMsgVC = true; remoteSent = true
                                }
                            }
                        }
                        sendChannelButton(icon: "doc.on.doc.fill", color: .sky500,
                                          label: "Copy Link to Clipboard") {
                            if let tok = pendingToken {
                                UIPasteboard.general.string = tok.deepLink
                                remoteSent = true
                            }
                            showSendPicker = false
                        }
                    }.padding(.horizontal)
                    Spacer()
                }.padding(20)
            }
            .navigationTitle("Send Request").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSendPicker = false }
                }
            }
        }
    }

    private func sendChannelButton(icon: String, color: Color, label: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)).frame(width: 40, height: 40)
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color)
                }
                Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(AeroTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(AeroTheme.textTertiary)
            }
            .padding(16).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(AeroTheme.cardStroke, lineWidth: 1))
        }.buttonStyle(PlainButtonStyle())
    }

    // MARK: Logic

    private func prepareSendRemote() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let profile  = DatabaseManager.shared.fetchUserProfile()
        let pilot    = profile["pilot_name"] as? String ?? "Pilot"
        let tok = EndorsementRemoteService.shared.createToken(
            template:        template,
            pilotName:       pilot,
            endorsementText: customText,
            date:            df.string(from: date)
        )
        pendingToken   = tok
        showSendPicker = true
    }

    private func saveEndorsement() {
        isSaving = true
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let img     = canvasView.drawing.image(from: canvasView.bounds, scale: 2.0)
        let sigBlob = img.pngData()?.base64EncodedString() ?? ""
        DatabaseManager.shared.addEndorsement(
            templateId: template.id, title: template.title, text: customText,
            date: df.string(from: date), instructorName: instructorName,
            instructorCertificate: instructorCert, signatureBlob: sigBlob
        ) { _ in isSaving = false; onSave() }
    }
}

// MARK: - Instructor Endorsement Remote Sign View
//
// Presented when instructor opens aerobook://endorsesign?...
// They review the endorsement text, enter credentials, draw signature,
// then share back aerobook://endorsereturn?...

struct InstructorEndorsementSignView: View {
    let token: EndorsementToken
    @Environment(\.dismiss) private var dismiss

    @State private var cfiName    = ""
    @State private var cfiCert    = ""
    @State private var cfiExpiry  = ""
    @State private var canvasView = PKCanvasView()
    @State private var hasSignature  = false
    @State private var isSigning     = false
    @State private var returnURL: String?
    @State private var showShare     = false

    private var canSign: Bool {
        !cfiName.isEmpty && !cfiCert.isEmpty && hasSignature && !token.isExpired
    }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Header
                        headerCard

                        // Endorsement text preview
                        endorsementTextCard

                        if token.isExpired {
                            expiredBanner
                        } else {
                            // Instructor info
                            instructorInfoCard

                            // Signature canvas
                            signatureCard

                            if canSign { signButton }

                            legalFooter
                        }
                        Color.clear.frame(height: 30)
                    }
                    .padding(.horizontal).padding(.top, 12)
                }
            }
            .navigationTitle("Sign Endorsement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }.foregroundStyle(AeroTheme.textSecondary)
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = returnURL {
                    EndorsementReturnShareSheet(returnURL: url, token: token) { dismiss() }
                }
            }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AeroTheme.brandPrimary.opacity(0.1)).frame(width: 48, height: 48)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22)).foregroundStyle(AeroTheme.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Endorsement Requested")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(AeroTheme.textPrimary)
                Text("\(token.pilotName) · \(token.acRef)")
                    .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary)
            }
            Spacer()
        }
        .padding(16).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
            .stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private var endorsementTextCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text.fill").font(.system(size: 12)).foregroundStyle(AeroTheme.brandPrimary)
                Text("ENDORSEMENT TEXT").font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(AeroTheme.brandPrimary)
            }
            HStack(spacing: 8) {
                Text(token.templateTitle).font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AeroTheme.brandPrimary.opacity(0.08)).foregroundStyle(AeroTheme.brandPrimary).cornerRadius(6)
                Text(token.acRef).font(.system(size: 10)).foregroundStyle(AeroTheme.textTertiary)
            }
            Text(token.endorsementText)
                .font(.system(size: 14, design: .serif))
                .foregroundColor(Color(red: 15/255, green: 20/255, blue: 30/255))
                .lineSpacing(4)
                .padding(14)
                .background(Color(red: 0.96, green: 0.97, blue: 0.99))
                .colorScheme(.light)
                .cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.fieldStroke, lineWidth: 1))

            HStack(spacing: 6) {
                Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(AeroTheme.brandPrimary)
                Text("Requested by \(token.pilotName) · \(token.date)")
                    .font(.system(size: 11)).foregroundStyle(AeroTheme.textTertiary)
            }
        }
        .padding(20).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private var instructorInfoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "person.badge.key.fill").font(.system(size: 12)).foregroundStyle(AeroTheme.brandPrimary)
                Text("YOUR INFORMATION").font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(AeroTheme.brandPrimary)
            }
            AeroField(label: "Your Full Name", text: $cfiName, placeholder: "John Smith", icon: "person.fill")
            HStack(spacing: 12) {
                AeroField(label: "CFI Certificate #", text: $cfiCert, placeholder: "1234567", icon: "creditcard.fill")
                AeroField(label: "Cert Expiry", text: $cfiExpiry, placeholder: "MM/YYYY", icon: "calendar.badge.clock")
            }
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 13))
                    .foregroundStyle(Color.statusAmber)
                Text("By signing, you certify you hold a current CFI certificate appropriate for this endorsement (14 CFR 61.189).")
                    .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).background(Color.statusAmber.opacity(0.07)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.statusAmber.opacity(0.2), lineWidth: 1))
        }
        .padding(20).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private var signatureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "signature").font(.system(size: 12)).foregroundStyle(AeroTheme.brandPrimary)
                    Text("YOUR SIGNATURE").font(.system(size: 11, weight: .bold)).tracking(1.2)
                        .foregroundStyle(AeroTheme.brandPrimary)
                }
                Spacer()
                if hasSignature {
                    Button(action: { canvasView.drawing = PKDrawing(); hasSignature = false }) {
                        Label("Clear", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.red.opacity(0.7))
                    }.buttonStyle(PlainButtonStyle())
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: AeroTheme.radiusMd).fill(Color.white)
                EntrySignatureCanvas(canvasView: $canvasView) {
                    hasSignature = !canvasView.drawing.strokes.isEmpty
                }
                .clipShape(RoundedRectangle(cornerRadius: AeroTheme.radiusMd))
                if !hasSignature {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.draw.fill").font(.system(size: 30))
                            .foregroundStyle(AeroTheme.textTertiary.opacity(0.35))
                        Text("Sign with Apple Pencil or finger")
                            .font(.system(size: 13)).foregroundStyle(AeroTheme.textTertiary)
                    }.allowsHitTesting(false)
                }
            }
            .frame(height: 160)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                .stroke(hasSignature ? AeroTheme.brandPrimary.opacity(0.5) : AeroTheme.fieldStroke,
                        style: StrokeStyle(lineWidth: 1.5, dash: hasSignature ? [] : [6, 4])))
        }
        .padding(20).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 3)
    }

    private var signButton: some View {
        Button(action: performSign) {
            HStack(spacing: 10) {
                if isSigning { ProgressView().tint(.white).scaleEffect(0.9) }
                else { Image(systemName: "checkmark.seal.fill").font(.system(size: 15)) }
                Text(isSigning ? "Signing…" : "Sign Endorsement & Return to Student")
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .background(AeroTheme.brandPrimary).foregroundStyle(.white)
            .cornerRadius(AeroTheme.radiusMd)
            .shadow(color: AeroTheme.brandPrimary.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(PlainButtonStyle()).disabled(isSigning)
    }

    private var expiredBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.badge.xmark.fill").font(.system(size: 24))
                .foregroundStyle(Color.statusRed)
            VStack(alignment: .leading, spacing: 3) {
                Text("Request Expired").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.statusRed)
                Text("This endorsement request has expired. Ask \(token.pilotName) to send a new one.")
                    .font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary)
            }
        }
        .padding(16).background(Color.statusRedBg).cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusRed.opacity(0.2), lineWidth: 1))
    }

    private var legalFooter: some View {
        Text("By signing, you certify that \(token.pilotName) has satisfactorily met the requirements described in the endorsement text, and that you hold a current and valid CFI certificate for the category and class listed. Falsification of FAA records is a federal offense under 18 U.S.C. § 1001 and 14 CFR 61.15.")
            .font(.system(size: 10)).foregroundStyle(AeroTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(3).padding(.horizontal, 4)
    }

    private func performSign() {
        guard canSign else { return }
        isSigning = true
        let bounds = CGRect(x: 0, y: 0,
                            width: canvasView.bounds.width.isZero ? 600 : canvasView.bounds.width,
                            height: 160)
        let img = canvasView.drawing.image(from: bounds, scale: UIScreen.main.scale)
        guard let png = img.pngData() else { isSigning = false; return }
        let b64 = png.base64EncodedString()
        let url = EndorsementRemoteService.shared.buildReturnURL(
            token: token, cfiName: cfiName, cfiCert: cfiCert,
            cfiExpiry: cfiExpiry, signatureBase64: b64)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isSigning = false; returnURL = url; showShare = true
        }
    }
}

// MARK: - Endorsement Return Share Sheet

struct EndorsementReturnShareSheet: View {
    let returnURL: String
    let token: EndorsementToken
    let onDone: () -> Void
    @State private var showSystemShare = false
    @State private var copied = false

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.statusGreen.opacity(0.12)).frame(width: 80, height: 80)
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 36))
                                    .foregroundStyle(Color.statusGreen)
                            }
                            Text("Endorsement Signed!")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            Text("Send the signed endorsement back to \(token.pilotName)")
                                .font(.system(size: 14)).foregroundStyle(AeroTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }.padding(.top, 20)

                        VStack(spacing: 12) {
                            shareBtn(icon: "square.and.arrow.up.fill",
                                     label: "Share via AirDrop / iMessage / Email",
                                     color: AeroTheme.brandPrimary) { showSystemShare = true }
                            shareBtn(icon: "doc.on.doc.fill",
                                     label: copied ? "Copied!" : "Copy Return Link",
                                     color: copied ? Color.statusGreen : .sky500) {
                                UIPasteboard.general.string = returnURL
                                withAnimation { copied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation { copied = false }
                                }
                            }
                        }.padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("RETURN LINK").font(.system(size: 10, weight: .bold)).tracking(1.2)
                                .foregroundStyle(AeroTheme.brandPrimary)
                            Text(returnURL).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AeroTheme.textTertiary).lineLimit(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14).background(AeroTheme.fieldBg).cornerRadius(AeroTheme.radiusMd)
                        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                            .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                        .padding(.horizontal)

                        Text("When \(token.pilotName) opens this link in AeroBook, the endorsement will be saved and cryptographically signed.")
                            .font(.system(size: 12)).foregroundStyle(AeroTheme.textTertiary)
                            .multilineTextAlignment(.center).padding(.horizontal)

                        Color.clear.frame(height: 20)
                    }
                }
            }
            .navigationTitle("Send Signed Endorsement").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: onDone).font(.system(size: 15, weight: .semibold))
                }
            }
            .sheet(isPresented: $showSystemShare) { SystemShareSheet(items: [returnURL]) }
        }
    }

    private func shareBtn(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)).frame(width: 40, height: 40)
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color)
                }
                Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(AeroTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(AeroTheme.textTertiary)
            }
            .padding(16).background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(AeroTheme.cardStroke, lineWidth: 1))
        }.buttonStyle(PlainButtonStyle())
    }
}

// MARK: - PencilKitCanvas (local to this file — no dependency on ManualEntryView)

struct PencilKitCanvas: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .white
        canvasView.isOpaque        = true
        canvasView.drawingPolicy   = .anyInput
        canvasView.tool            = PKInkingTool(.pen, color: .black, width: 2)
        return canvasView
    }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

// MARK: - EndorsementSummaryWidget (unchanged)

struct EndorsementSummaryWidget: View {
    @State private var records: [DatabaseManager.EndorsementRecord] = []
    @State private var showSheet = false

    struct TimedItem: Identifiable {
        let id: Int64
        let record: DatabaseManager.EndorsementRecord
        let remaining: Int
        let statusColor: Color
    }
    private var timedItems: [TimedItem] {
        records.compactMap { rec in
            guard let tmpl = endorsementTemplates.first(where: { $0.id == rec.templateId }),
                  let exp  = tmpl.expiryDays,
                  let days = rec.daysRemaining(expiryDays: exp) else { return nil }
            let color: Color = days < 0 ? .statusRed : days < 30 ? .statusAmber : .statusGreen
            return TimedItem(id: rec.id, record: rec, remaining: days, statusColor: color)
        }.sorted { $0.remaining < $1.remaining }
    }

    var body: some View {
        Group {
            if !timedItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
                            Text("Endorsements").font(.system(size: 11, weight: .bold)).tracking(1.2)
                        }
                        .foregroundStyle(AeroTheme.brandPrimary).textCase(.uppercase)
                        Spacer()
                        Button(action: { showSheet = true }) {
                            Text("View All").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AeroTheme.brandPrimary)
                        }.buttonStyle(PlainButtonStyle())
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(timedItems.prefix(3).enumerated()), id: \.element.id) { idx, item in
                            if idx > 0 { Divider().padding(.leading, 52) }
                            timedRow(item)
                        }
                    }
                    .background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
                    .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                        .stroke(AeroTheme.cardStroke, lineWidth: 1))
                }
                .sheet(isPresented: $showSheet) { EndorsementsView() }
                .onAppear { load() }
            }
        }
    }

    private func timedRow(_ item: TimedItem) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(item.statusColor.opacity(0.1)).frame(width: 36, height: 36)
                Image(systemName: "signature").font(.system(size: 14)).foregroundStyle(item.statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.record.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary).lineLimit(1)
                Text("Issued \(item.record.date)").font(.system(size: 10)).foregroundStyle(AeroTheme.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if item.remaining < 0 {
                    Text("EXPIRED").font(.system(size: 9, weight: .black)).foregroundStyle(item.statusColor)
                } else {
                    Text("\(item.remaining)").font(.system(size: 18, weight: .light, design: .rounded))
                        .foregroundStyle(item.statusColor)
                    Text("days").font(.system(size: 9, weight: .medium)).foregroundStyle(item.statusColor.opacity(0.8))
                }
            }.frame(width: 48)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DatabaseManager.shared.fetchEndorsements()
            DispatchQueue.main.async { records = r }
        }
    }
}

#Preview { EndorsementsView() }
