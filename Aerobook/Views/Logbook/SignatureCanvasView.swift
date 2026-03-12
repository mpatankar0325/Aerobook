import SwiftUI
import PencilKit
import CryptoKit

struct SignatureCanvasView: View {
    let flightID: Int64
    let pilotName: String
    
    @State private var canvasView = PKCanvasView()
    @State private var cfiName = ""
    @State private var cfiCertificate = ""
    @State private var flightData: [String: Any]?
    @State private var isSaving = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let flight = flightData {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Flight Details")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text(flight["date"] as? String ?? "").font(.title3.bold())
                                Text(flight["aircraft_ident"] as? String ?? "").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(String(format: "%.1f", flight["total_time"] as? Double ?? 0.0)) hrs")
                                .font(.title2.bold())
                                .foregroundStyle(.emerald500)
                        }
                        .padding()
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.05), radius: 10)
                    }
                    .padding(.horizontal)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Instructor Information")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    
                    VStack(spacing: 0) {
                        TextField("CFI Full Name", text: $cfiName)
                            .padding()
                        Divider()
                        TextField("Certificate Number", text: $cfiCertificate)
                            .padding()
                    }
                    .background(Color.white)
                    .cornerRadius(16)
                    .padding(.horizontal)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("CFI Signature")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    
                    PencilKitView(canvasView: $canvasView)
                        .frame(height: 200)
                        .background(Color.white)
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.zinc200, lineWidth: 1)
                        )
                        .padding(.horizontal)
                    
                    Button("Clear Signature") {
                        canvasView.drawing = PKDrawing()
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.zinc400)
                    .padding(.horizontal)
                }
                
                Spacer()
                
                Button(action: signAndLock) {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Sign & Cryptographically Lock")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.zinc900)
                .foregroundStyle(.white)
                .cornerRadius(16)
                .padding()
                .disabled(isSaving || cfiName.isEmpty || cfiCertificate.isEmpty)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("CFI Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: loadFlightData)
            .alert("Signature Status", isPresented: $showAlert) {
                Button("OK") { if alertMessage.contains("Success") { dismiss() } }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private func loadFlightData() {
        if let flight = DatabaseManager.shared.fetchFlight(id: flightID) {
            self.flightData = flight
        }
    }
    
    private func signAndLock() {
        guard let flight = flightData else { return }
        isSaving = true
        
        // Task 3: The "Lock" Logic
        // 1. Generate SHA256 Hash of the flight data
        let date = flight["date"] as? String ?? ""
        let tail = flight["aircraft_ident"] as? String ?? ""
        let time = flight["total_time"] as? Double ?? 0.0
        let dataString = "\(flightID)|\(date)|\(tail)|\(time)"
        
        guard let data = dataString.data(using: .utf8) else { return }
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        // 2. Convert Signature to PNG Base64
        let image = canvasView.drawing.image(from: canvasView.bounds, scale: 1.0)
        guard let pngData = image.pngData() else { return }
        let signatureBase64 = pngData.base64EncodedString()
        
        // 3. Save to Database
        DatabaseManager.shared.signFlight(
            id: flightID,
            signature: signatureBase64,
            hash: hashString,
            name: cfiName,
            certificate: cfiCertificate
        ) { success in
            isSaving = false
            if success {
                alertMessage = "Success! Entry has been cryptographically locked."
            } else {
                alertMessage = "Failed to save signature. Please try again."
            }
            showAlert = true
        }
    }
}

struct PencilKitView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

#Preview {
    SignatureCanvasView(flightID: 1, pilotName: "John Doe")
}
