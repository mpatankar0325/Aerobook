// Theme.swift — AeroBook Aviation Design System
// Palette: White + Steel Blue, clean & professional

import SwiftUI

// MARK: - Color Palette

extension Color {
    // Steel Blue — Primary brand
    static let sky900  = Color(red: 12/255,  green: 36/255,  blue: 66/255)   // Deep navy
    static let sky800  = Color(red: 20/255,  green: 52/255,  blue: 92/255)
    static let sky700  = Color(red: 28/255,  green: 72/255,  blue: 120/255)
    static let sky600  = Color(red: 37/255,  green: 99/255,  blue: 158/255)
    static let sky500  = Color(red: 46/255,  green: 109/255, blue: 180/255)  // Primary action blue
    static let sky400  = Color(red: 91/255,  green: 155/255, blue: 213/255)
    static let sky300  = Color(red: 147/255, green: 197/255, blue: 233/255)
    static let sky200  = Color(red: 186/255, green: 221/255, blue: 243/255)
    static let sky100  = Color(red: 219/255, green: 238/255, blue: 250/255)
    static let sky50   = Color(red: 240/255, green: 248/255, blue: 255/255)

    // Neutrals — Warm whites and grays
    static let neutral900 = Color(red: 15/255,  green: 20/255,  blue: 30/255)
    static let neutral800 = Color(red: 30/255,  green: 38/255,  blue: 52/255)
    static let neutral700 = Color(red: 52/255,  green: 62/255,  blue: 78/255)
    static let neutral600 = Color(red: 82/255,  green: 94/255,  blue: 112/255)
    static let neutral500 = Color(red: 118/255, green: 132/255, blue: 152/255)
    static let neutral400 = Color(red: 158/255, green: 170/255, blue: 186/255)
    static let neutral300 = Color(red: 200/255, green: 208/255, blue: 220/255)
    static let neutral200 = Color(red: 224/255, green: 230/255, blue: 238/255)
    static let neutral100 = Color(red: 240/255, green: 244/255, blue: 248/255)
    static let neutral50  = Color(red: 248/255, green: 250/255, blue: 252/255)

    // Status colors
    static let statusGreen  = Color(red: 16/255,  green: 163/255, blue: 127/255)  // Current / valid
    static let statusAmber  = Color(red: 217/255, green: 119/255, blue: 6/255)    // Warning
    static let statusRed    = Color(red: 220/255, green: 38/255,  blue: 38/255)   // Expired

    static let statusGreenBg = Color(red: 236/255, green: 253/255, blue: 245/255)
    static let statusAmberBg = Color(red: 255/255, green: 251/255, blue: 235/255)
    static let statusRedBg   = Color(red: 254/255, green: 242/255, blue: 242/255)

    // Gold accent — aviation instruments feel
    static let gold400 = Color(red: 212/255, green: 175/255, blue: 55/255)
    static let gold300 = Color(red: 230/255, green: 200/255, blue: 100/255)

    // Legacy zinc — kept for backward compatibility
    static let zinc900 = Color(red: 24/255, green: 24/255, blue: 27/255)
    static let zinc800 = Color(red: 39/255, green: 39/255, blue: 42/255)
    static let zinc700 = Color(red: 63/255, green: 63/255, blue: 70/255)
    static let zinc600 = Color(red: 82/255, green: 82/255, blue: 91/255)
    static let zinc500 = Color(red: 113/255, green: 113/255, blue: 122/255)
    static let zinc400 = Color(red: 161/255, green: 161/255, blue: 170/255)
    static let zinc300 = Color(red: 212/255, green: 212/255, blue: 216/255)
    static let zinc200 = Color(red: 228/255, green: 228/255, blue: 231/255)
    static let zinc100 = Color(red: 244/255, green: 244/255, blue: 245/255)
    static let zinc50  = Color(red: 250/255, green: 250/255, blue: 250/255)

    static let emerald500 = Color(red: 16/255,  green: 185/255, blue: 129/255)
    static let emerald600 = Color(red: 5/255,   green: 150/255, blue: 105/255)
    static let emerald800 = Color(red: 6/255,   green: 95/255,  blue: 70/255)
    static let emerald900 = Color(red: 6/255,   green: 78/255,  blue: 59/255)
    static let emerald100 = Color(red: 209/255, green: 250/255, blue: 229/255)
    static let emerald50  = Color(red: 236/255, green: 253/255, blue: 245/255)
    static let amber500   = Color(red: 245/255, green: 158/255, blue: 11/255)
    static let rose500    = Color(red: 244/255, green: 63/255,  blue: 94/255)
}

// MARK: - ShapeStyle extensions

extension ShapeStyle where Self == Color {
    // Sky
    static var sky900: Color  { .sky900 }
    static var sky800: Color  { .sky800 }
    static var sky700: Color  { .sky700 }
    static var sky600: Color  { .sky600 }
    static var sky500: Color  { .sky500 }
    static var sky400: Color  { .sky400 }
    static var sky300: Color  { .sky300 }
    static var sky200: Color  { .sky200 }
    static var sky100: Color  { .sky100 }
    static var sky50:  Color  { .sky50  }

    // Neutral
    static var neutral900: Color { .neutral900 }
    static var neutral800: Color { .neutral800 }
    static var neutral700: Color { .neutral700 }
    static var neutral600: Color { .neutral600 }
    static var neutral500: Color { .neutral500 }
    static var neutral400: Color { .neutral400 }
    static var neutral300: Color { .neutral300 }
    static var neutral200: Color { .neutral200 }
    static var neutral100: Color { .neutral100 }
    static var neutral50:  Color { .neutral50  }

    // Status
    static var statusGreen:   Color { .statusGreen }
    static var statusAmber:   Color { .statusAmber }
    static var statusRed:     Color { .statusRed }
    static var statusGreenBg: Color { .statusGreenBg }
    static var statusAmberBg: Color { .statusAmberBg }
    static var statusRedBg:   Color { .statusRedBg }

    // Gold
    static var gold400: Color { .gold400 }
    static var gold300: Color { .gold300 }

    // Legacy zinc
    static var zinc900: Color { .zinc900 }
    static var zinc800: Color { .zinc800 }
    static var zinc700: Color { .zinc700 }
    static var zinc600: Color { .zinc600 }
    static var zinc500: Color { .zinc500 }
    static var zinc400: Color { .zinc400 }
    static var zinc300: Color { .zinc300 }
    static var zinc200: Color { .zinc200 }
    static var zinc100: Color { .zinc100 }
    static var zinc50:  Color { .zinc50  }

    static var emerald500: Color { .emerald500 }
    static var emerald600: Color { .emerald600 }
    static var emerald800: Color { .emerald800 }
    static var emerald900: Color { .emerald900 }
    static var emerald100: Color { .emerald100 }
    static var emerald50:  Color { .emerald50  }
    static var amber500:   Color { .amber500   }
    static var rose500:    Color { .rose500    }
}

// MARK: - Design Tokens

enum AeroTheme {
    static let neutral300 = Color(red: 200/255, green: 208/255, blue: 220/255)
    static let neutral200 = Color(red: 224/255, green: 230/255, blue: 238/255)
    // Background
    static let pageBg       = Color(red: 245/255, green: 248/255, blue: 252/255)  // Very light blue-white
    static let cardBg       = Color.white
    static let cardStroke   = Color(red: 220/255, green: 230/255, blue: 242/255)

    // Typography
    static let textPrimary   = Color(red: 15/255,  green: 20/255,  blue: 30/255)
    static let textSecondary = Color(red: 82/255,  green: 94/255,  blue: 112/255)
    static let textTertiary  = Color(red: 158/255, green: 170/255, blue: 186/255)

    // Brand
    static let brandPrimary  = Color(red: 37/255, green: 99/255, blue: 158/255)   // sky600
    static let brandDark     = Color(red: 12/255, green: 36/255, blue: 66/255)    // sky900
    static let brandLight    = Color(red: 240/255, green: 248/255, blue: 255/255) // sky50

    // Input fields
    static let fieldBg     = Color(red: 246/255, green: 249/255, blue: 253/255)
    static let fieldStroke = Color(red: 210/255, green: 222/255, blue: 236/255)

    // Radius
    static let radiusSm: CGFloat  = 10
    static let radiusMd: CGFloat  = 16
    static let radiusLg: CGFloat  = 24
    static let radiusXl: CGFloat  = 32

    // Shadow
    static let shadowCard  = Color.black.opacity(0.06)
    static let shadowDeep  = Color.sky900.opacity(0.15)
}

// MARK: - Reusable View Modifiers

struct AeroCard: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg).stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
    }
}

struct AeroPrimaryButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AeroTheme.brandPrimary)
            .cornerRadius(AeroTheme.radiusMd)
            .shadow(color: AeroTheme.brandPrimary.opacity(0.35), radius: 8, x: 0, y: 4)
    }
}

struct AeroSectionHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(AeroTheme.brandPrimary)
            .textCase(.uppercase)
    }
}

extension View {
    func aeroCard(padding: CGFloat = 20) -> some View {
        modifier(AeroCard(padding: padding))
    }
    func aeroPrimaryButton() -> some View {
        modifier(AeroPrimaryButton())
    }
    func aeroSectionHeader() -> some View {
        modifier(AeroSectionHeader())
    }
}

// MARK: - Shared Input Components

struct AeroField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AeroTheme.textSecondary)

            HStack(spacing: 10) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                        .frame(width: 20)
                }
                TextField(placeholder, text: $text)
                    .keyboardType(keyboard)
                    .font(.system(size: 15))
                    .foregroundStyle(AeroTheme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AeroTheme.fieldBg)
            .cornerRadius(AeroTheme.radiusMd)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(AeroTheme.fieldStroke, lineWidth: 1))
        }
    }
}

struct AeroPageHeader: View {
    let title: String
    let subtitle: String
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)

                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(AeroTheme.brandPrimary.opacity(0.12))
                        .foregroundStyle(AeroTheme.brandPrimary)
                        .cornerRadius(100)
                }
            }
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(AeroTheme.textSecondary)
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    enum StatusType { case current, warning, expired }
    let type: StatusType

    var label: String {
        switch type {
        case .current: return "CURRENT"
        case .warning: return "WARNING"
        case .expired: return "EXPIRED"
        }
    }
    var color: Color {
        switch type {
        case .current: return .statusGreen
        case .warning: return .statusAmber
        case .expired: return .statusRed
        }
    }
    var bg: Color {
        switch type {
        case .current: return .statusGreenBg
        case .warning: return .statusAmberBg
        case .expired: return .statusRedBg
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .black))
            .tracking(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg)
            .foregroundStyle(color)
            .cornerRadius(6)
    }
}
