// ScannerView.swift — AeroBook
// Placeholder — scanner system is being rebuilt from scratch.
// Drop this file in place of the old ScannerView.swift so the
// Scanner tab compiles while the new implementation is in progress.

import SwiftUI
import Combine

struct ScannerView: View {
    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer()

                    // Icon
                    ZStack {
                        Circle()
                            .fill(AeroTheme.brandPrimary.opacity(0.08))
                            .frame(width: 110, height: 110)
                        Circle()
                            .fill(AeroTheme.brandPrimary.opacity(0.14))
                            .frame(width: 80, height: 80)
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(AeroTheme.brandPrimary)
                    }

                    // Text
                    VStack(spacing: 8) {
                        Text("Scanner")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(AeroTheme.textPrimary)
                        Text("New scanner coming soon.\nThe logbook import system is being rebuilt.")
                            .font(.system(size: 14))
                            .foregroundStyle(AeroTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 40)

                    Spacer()
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
        }
    }
}

#Preview {
    ScannerView()
}
