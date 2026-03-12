import Foundation
import MessageUI

class SignatureRequestService: NSObject, MFMailComposeViewControllerDelegate {
    static let shared = SignatureRequestService()
    
    func generateSignatureRequestEmail(flightID: Int64, pilotName: String) -> MFMailComposeViewController? {
        guard MFMailComposeViewController.canSendMail() else {
            return nil
        }
        
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = self
        mail.setSubject("Signature Request for Flight Entry #\(flightID)")
        
        // Task 1: Deep Link Construction
        let deepLink = "aerobook://sign?entryID=\(flightID)&pilotName=\(pilotName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        let body = """
        <html>
        <body>
            <p>Hi Instructor,</p>
            <p>\(pilotName) has requested a digital signature for a flight entry in AeroBook.</p>
            <p>Please tap the button below to review and sign the entry directly on this device.</p>
            <br>
            <a href="\(deepLink)" style="background-color: #10b981; color: white; padding: 14px 24px; text-decoration: none; border-radius: 12px; font-weight: bold; display: inline-block;">Review & Sign Entry</a>
            <br><br>
            <p>If the button doesn't work, copy and paste this link into your browser:</p>
            <p>\(deepLink)</p>
            <br>
            <p>Safe flights,<br>AeroBook Team</p>
        </body>
        </html>
        """
        
        mail.setMessageBody(body, isHTML: true)
        return mail
    }
    
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true)
    }
}
