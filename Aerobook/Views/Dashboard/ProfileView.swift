// ProfileView.swift — AeroBook
//
// Sections: Pilot Identity · Medical Certification · Home Base · My Aircraft · My Instructors
// Medical: Standard 1/2/3, BasicMed, None — expiry calculated from birthdate per FAA 14 CFR 61.23

import SwiftUI
import Combine
// MARK: - ViewModel

final class ProfileViewModel: ObservableObject {

    // Identity
    @Published var name              = ""
    @Published var ftn               = ""
    @Published var pilotCertificate  = ""
    @Published var certificateNumber = ""
    @Published var dateOfBirth       = Date()
    @Published var hasBirthdate      = false    // false until user explicitly sets DOB

    // Medical
    @Published var medicalType = FAAMedical.MedicalType.standard3
    @Published var medicalDate = Date()

    // Home base
    @Published var countryCode      = "US"
    @Published var homeAirport      = ""
    @Published var homeAirportName  = ""

    // Collections
    @Published var aircraft:    [AircraftRecord]   = []
    @Published var instructors: [InstructorRecord] = []
    @Published var simulators:  [SimulatorRecord]  = []

    @Published var isSaving = false

    // Static option lists
    let allRatings  = ["CFI", "CFII", "MEI", "ATP", "Other"]
    let engineTypes = ["Piston", "Turboprop", "Jet", "Electric"]
    let categories  = ["Airplane", "Rotorcraft", "Glider", "Lighter-than-air", "Powered Parachute"]
    let classes     = ["ASEL", "AMEL", "ASES", "AMES", "Helicopter", "Gyroplane"]
    let countries: [(code: String, name: String)] = [
        ("US", "United States"), ("AU", "Australia"), ("CA", "Canada"),
        ("GB", "United Kingdom"), ("NZ", "New Zealand"), ("ZA", "South Africa"),
        ("IE", "Ireland"), ("IN", "India"), ("DE", "Germany"),
        ("FR", "France"), ("AE", "UAE"), ("SG", "Singapore"), ("OTHER", "Other"),
    ]

    // MARK: Computed

    var dobForExpiry: Date? { hasBirthdate ? dateOfBirth : nil }

    var medicalExpiry: Date? {
        FAAMedical.expiryDate(examDate: medicalDate, type: medicalType, dateOfBirth: dobForExpiry)
    }

    var medicalRuleDescription: String {
        FAAMedical.ruleDescription(type: medicalType, dateOfBirth: dobForExpiry)
    }

    var initials: String {
        let parts = name.split(separator: " ")
        let f = parts.first?.prefix(1) ?? "P"
        let l = parts.dropFirst().first?.prefix(1) ?? ""
        return "\(f)\(l)".uppercased()
    }

    // MARK: Load

    func load() {
        let p   = DatabaseManager.shared.fetchFullProfile()
        let df  = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        name              = p.pilotName
        ftn               = p.ftn
        pilotCertificate  = p.pilotCertificate
        certificateNumber = p.certificateNumber
        countryCode       = p.countryCode
        homeAirport       = p.homeAirport
        homeAirportName   = p.homeAirportName

        // Medical type — migrate old "Class 1/2/3" values gracefully
        let storedType = p.medicalType
        if let t = FAAMedical.MedicalType(rawValue: storedType) {
            medicalType = t
        } else {
            // Legacy values
            switch storedType {
            case "Class 1": medicalType = .standard1
            case "Class 2": medicalType = .standard2
            default:        medicalType = .standard3
            }
        }

        if !p.medicalDate.isEmpty, let d = df.date(from: p.medicalDate) {
            medicalDate = d
        }

        if !p.dateOfBirth.isEmpty, let d = df.date(from: p.dateOfBirth) {
            dateOfBirth = d
            hasBirthdate = true
        }

        aircraft    = DatabaseManager.shared.fetchAllAircraft()
        instructors = DatabaseManager.shared.fetchAllInstructors()
        simulators  = DatabaseManager.shared.fetchAllSimulators()
    }

    // MARK: Save

    func save(completion: @escaping () -> Void) {
        isSaving = true
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var p = DatabaseManager.FullProfile()
        p.pilotName         = name
        p.ftn               = ftn
        p.pilotCertificate  = pilotCertificate
        p.certificateNumber = certificateNumber
        p.medicalType       = medicalType.rawValue
        p.medicalDate       = df.string(from: medicalDate)
        p.dateOfBirth       = hasBirthdate ? df.string(from: dateOfBirth) : ""
        p.countryCode       = countryCode
        p.homeAirport       = homeAirport.uppercased().trimmingCharacters(in: .whitespaces)
        p.homeAirportName   = homeAirportName

        // Pre-compute and store expiry string
        if let expiry = medicalExpiry {
            p.medicalExpiry = df.string(from: expiry)
        }

        // updateFullProfile is now async — callback fires on main thread
        DatabaseManager.shared.updateFullProfile(p) { [weak self] _ in
            self?.isSaving = false
            completion()
        }
    }

    // MARK: Aircraft

    func saveAircraft(_ a: AircraftRecord, completion: @escaping () -> Void) {
        DatabaseManager.shared.saveAircraft(a) { [weak self] ok in
            guard let self else { return }
            // Reload on main thread after async write completes
            DispatchQueue.main.async {
                self.aircraft = DatabaseManager.shared.fetchAllAircraft()
                completion()
            }
        }
    }

    func deleteAircraft(_ registration: String) {
        DatabaseManager.shared.deleteAircraft(registration: registration) { [weak self] _ in
            DispatchQueue.main.async {
                self?.aircraft = DatabaseManager.shared.fetchAllAircraft()
            }
        }
    }

    func renameAircraft(oldRegistration: String, updated: AircraftRecord,
                        completion: @escaping () -> Void) {
        DatabaseManager.shared.renameAircraft(oldRegistration: oldRegistration, updated: updated) { [weak self] _ in
            DispatchQueue.main.async {
                self?.aircraft = DatabaseManager.shared.fetchAllAircraft()
                completion()
            }
        }
    }

    // MARK: Instructors

    func saveInstructor(_ i: InstructorRecord, completion: @escaping () -> Void) {
        DatabaseManager.shared.saveInstructor(i) { [weak self] _ in
            DispatchQueue.main.async {
                self?.instructors = DatabaseManager.shared.fetchAllInstructors()
                completion()
            }
        }
    }

    func deleteInstructor(id: Int64) {
        DatabaseManager.shared.deleteInstructor(id: id) { [weak self] _ in
            DispatchQueue.main.async {
                self?.instructors = DatabaseManager.shared.fetchAllInstructors()
            }
        }
    }

    // MARK: Simulators

    func saveSimulator(_ s: SimulatorRecord, completion: @escaping () -> Void) {
        DatabaseManager.shared.saveSimulator(s) { [weak self] (_: Bool) in
            DispatchQueue.main.async {
                self?.simulators = DatabaseManager.shared.fetchAllSimulators()
                completion()
            }
        }
    }

    func deleteSimulator(id: Int64) {
        DatabaseManager.shared.deleteSimulator(id: id) { [weak self] (_: Bool) in
            DispatchQueue.main.async {
                self?.simulators = DatabaseManager.shared.fetchAllSimulators()
            }
        }
    }
}

// MARK: - ProfileView

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = ProfileViewModel()

    @State private var showAircraftSheet    = false
    @State private var editingAircraft: AircraftRecord?     = nil
    @State private var showInstructorSheet  = false
    @State private var editingInstructor: InstructorRecord? = nil
    @State private var savedBanner          = false
    @State private var deletingAircraft: AircraftRecord?    = nil
    @State private var deletingInstructor: InstructorRecord? = nil
    @State private var showSimulatorSheet   = false
    @State private var editingSimulator: SimulatorRecord?   = nil
    @State private var deletingSimulator: SimulatorRecord?  = nil

    var body: some View {
        ZStack {
            AeroTheme.pageBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    heroCard.padding(.horizontal).padding(.top, 8)
                    identitySection
                    medicalSection
                    homeBaseSection
                    aircraftSection
                    simulatorSection
                    instructorSection
                    saveButton.padding(.horizontal)
                    Color.clear.frame(height: 24)
                }
                .padding(.bottom, 32)
            }

            if savedBanner {
                VStack {
                    Spacer()
                    savedConfirmation
                        .padding(.horizontal, 24).padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.4), value: savedBanner)
                .zIndex(10)
            }
        }
        .navigationTitle("Pilot Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.load() }
        .sheet(isPresented: $showAircraftSheet) {
            AircraftEditSheet(
                aircraft: editingAircraft, vm: vm,
                onDismiss: { showAircraftSheet = false; editingAircraft = nil }
            )
        }
        .sheet(isPresented: $showInstructorSheet) {
            InstructorEditSheet(
                instructor: editingInstructor, vm: vm,
                onDismiss: { showInstructorSheet = false; editingInstructor = nil }
            )
        }
        .sheet(isPresented: $showSimulatorSheet) {
            SimulatorEditSheet(
                simulator: editingSimulator, vm: vm,
                onDismiss: { showSimulatorSheet = false; editingSimulator = nil }
            )
        }
        .confirmationDialog(
            "Delete \(deletingAircraft?.registration ?? "aircraft")?",
            isPresented: Binding(
                get: { deletingAircraft != nil },
                set: { if !$0 { deletingAircraft = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ac = deletingAircraft { vm.deleteAircraft(ac.registration) }
                deletingAircraft = nil
            }
            Button("Cancel", role: .cancel) { deletingAircraft = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(deletingInstructor?.name ?? "instructor")?",
            isPresented: Binding(
                get: { deletingInstructor != nil },
                set: { if !$0 { deletingInstructor = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ins = deletingInstructor { vm.deleteInstructor(id: ins.id) }
                deletingInstructor = nil
            }
            Button("Cancel", role: .cancel) { deletingInstructor = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(deletingSimulator?.name ?? "simulator")?",
            isPresented: Binding(
                get: { deletingSimulator != nil },
                set: { if !$0 { deletingSimulator = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = deletingSimulator { vm.deleteSimulator(id: s.id) }
                deletingSimulator = nil
            }
            Button("Cancel", role: .cancel) { deletingSimulator = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [AeroTheme.brandPrimary, .sky400],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 68, height: 68)
                Text(vm.initials)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .shadow(color: AeroTheme.brandPrimary.opacity(0.3), radius: 10, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name.isEmpty ? "Pilot" : vm.name)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(AeroTheme.textPrimary)
                Text(vm.pilotCertificate.isEmpty ? "Certificate not set" : vm.pilotCertificate)
                    .font(.system(size: 13)).foregroundStyle(AeroTheme.textSecondary)
                if !vm.homeAirport.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill").font(.system(size: 10))
                        Text(vm.homeAirport)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(AeroTheme.brandPrimary)
                }
            }
            Spacer()
            if !vm.aircraft.isEmpty {
                VStack(spacing: 2) {
                    Text("\(vm.aircraft.count)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AeroTheme.brandPrimary)
                    Text("Aircraft")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
            }
        }
        .aeroCard()
    }

    // MARK: - Identity

    private var identitySection: some View {
        profileSection(title: "Pilot Identity", icon: "person.text.rectangle.fill") {
            VStack(spacing: 14) {
                AeroField(label: "Full Name",             text: $vm.name,              placeholder: "e.g. John Smith",      icon: "person.fill")
                AeroField(label: "FAA Tracking No (FTN)", text: $vm.ftn,               placeholder: "C1234567",              icon: "number")
                AeroField(label: "Certificate Type",      text: $vm.pilotCertificate,  placeholder: "e.g. Commercial Pilot", icon: "airplane.departure")
                AeroField(label: "Certificate Number",    text: $vm.certificateNumber, placeholder: "e.g. 1234567",          icon: "creditcard.fill")

                // Date of Birth — needed for correct medical expiry calculation
                VStack(alignment: .leading, spacing: 6) {
                    Text("Date of Birth")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)

                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "birthday.cake")
                                .font(.system(size: 13))
                                .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                                .frame(width: 20)
                            if vm.hasBirthdate {
                                DatePicker("", selection: $vm.dateOfBirth,
                                           in: ...Date(), displayedComponents: .date)
                                    .labelsHidden()
                                    .tint(AeroTheme.brandPrimary)
                            } else {
                                Text("Not set")
                                    .font(.system(size: 15))
                                    .foregroundStyle(AeroTheme.textTertiary)
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(AeroTheme.fieldBg)
                        .cornerRadius(AeroTheme.radiusMd)
                        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                            .stroke(AeroTheme.fieldStroke, lineWidth: 1))

                        Button {
                            vm.hasBirthdate.toggle()
                            if vm.hasBirthdate {
                                // Default to 30 years ago when first enabled
                                vm.dateOfBirth = Calendar.current.date(
                                    byAdding: .year, value: -30, to: Date()) ?? Date()
                            }
                        } label: {
                            Text(vm.hasBirthdate ? "Clear" : "Set")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AeroTheme.brandPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(AeroTheme.brandPrimary.opacity(0.08))
                                .cornerRadius(AeroTheme.radiusMd)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if !vm.hasBirthdate {
                        Text("Required for accurate medical expiry calculation")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.statusAmber)
                    }
                }
            }
        }
    }

    // MARK: - Medical

    private var medicalSection: some View {
        profileSection(title: "Medical Certification", icon: "cross.case.fill") {
            VStack(spacing: 14) {

                // Medical type — Standard 1/2/3, BasicMed, None
                VStack(alignment: .leading, spacing: 8) {
                    Text("Medical Type")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)

                    // Row 1: Standard classes
                    HStack(spacing: 6) {
                        ForEach([FAAMedical.MedicalType.standard1,
                                 .standard2, .standard3], id: \.self) { t in
                            medTypeButton(t)
                        }
                    }
                    // Row 2: BasicMed + None
                    HStack(spacing: 6) {
                        ForEach([FAAMedical.MedicalType.basicMed,
                                 .none], id: \.self) { t in
                            medTypeButton(t)
                        }
                    }

                    // Rule description
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(AeroTheme.brandPrimary)
                        Text(vm.medicalRuleDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(AeroTheme.textSecondary)
                    }
                    .padding(10)
                    .background(AeroTheme.brandPrimary.opacity(0.05))
                    .cornerRadius(AeroTheme.radiusSm)
                }

                // Exam date (not shown for None)
                if vm.medicalType != .none {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(vm.medicalType == .basicMed
                             ? "AOPA Course Completion Date"
                             : "Date of Medical Examination")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AeroTheme.textSecondary)

                        HStack(spacing: 10) {
                            Image(systemName: "calendar.badge.checkmark")
                                .font(.system(size: 13))
                                .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7))
                                .frame(width: 20)
                            DatePicker("", selection: $vm.medicalDate,
                                       in: ...Date(), displayedComponents: .date)
                                .labelsHidden()
                                .tint(AeroTheme.brandPrimary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(AeroTheme.fieldBg)
                        .cornerRadius(AeroTheme.radiusMd)
                        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                            .stroke(AeroTheme.fieldStroke, lineWidth: 1))
                    }

                    medicalStatusBadge
                }
            }
        }
    }

    private func medTypeButton(_ type: FAAMedical.MedicalType) -> some View {
        Button { vm.medicalType = type } label: {
            Text(type.displayName)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(vm.medicalType == type ? AeroTheme.brandPrimary : AeroTheme.fieldBg)
                .foregroundStyle(vm.medicalType == type ? .white : AeroTheme.textSecondary)
                .cornerRadius(AeroTheme.radiusSm)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusSm)
                    .stroke(vm.medicalType == type ? AeroTheme.brandPrimary : AeroTheme.fieldStroke,
                            lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.spring(response: 0.2), value: vm.medicalType)
    }

    private var medicalStatusBadge: some View {
        let now = Date()
        let expiry = vm.medicalExpiry ?? now

        let daysRemaining = Calendar.current.dateComponents([.day], from: now, to: expiry).day ?? 0
        let color: Color = daysRemaining < 0 ? .statusRed
                         : daysRemaining < 30 ? .statusAmber
                         : .statusGreen
        let bg: Color    = daysRemaining < 0 ? .statusRedBg
                         : daysRemaining < 30 ? .statusAmberBg
                         : .statusGreenBg
        let icon         = daysRemaining < 0 ? "xmark.shield.fill"
                         : daysRemaining < 30 ? "exclamationmark.shield.fill"
                         : "checkmark.shield.fill"
        let statusLabel  = daysRemaining < 0 ? "EXPIRED"
                         : daysRemaining < 30 ? "EXPIRING SOON"
                         : "VALID"

        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none

        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vm.medicalType.displayName) · \(statusLabel)")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(color)
                if vm.medicalExpiry != nil {
                    Text(daysRemaining < 0
                         ? "Expired \(df.string(from: expiry))"
                         : "Valid until \(df.string(from: expiry))")
                        .font(.system(size: 11)).foregroundStyle(color.opacity(0.85))
                } else {
                    Text("Set exam date to calculate expiry")
                        .font(.system(size: 11)).foregroundStyle(color.opacity(0.85))
                }
            }
            Spacer()
            if daysRemaining >= 0 {
                VStack(spacing: 1) {
                    Text("\(daysRemaining)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    Text("days left")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(color.opacity(0.7))
                }
            }
        }
        .padding(14)
        .background(bg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(color.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Home Base

    private var homeBaseSection: some View {
        profileSection(title: "Home Base", icon: "location.circle.fill") {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Country / Aviation Authority")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.textSecondary)
                    Menu {
                        ForEach(vm.countries, id: \.code) { c in
                            Button(c.name) { vm.countryCode = c.code }
                        }
                    } label: {
                        menuPickerRow(
                            icon: "globe",
                            value: vm.countries.first(where: { $0.code == vm.countryCode })?.name ?? vm.countryCode
                        )
                    }
                }

                AeroField(label: "Home Airport (ICAO/IATA)", text: $vm.homeAirport,
                          placeholder: "e.g. KCDW", icon: "airplane.circle")
                    .onChange(of: vm.homeAirport) { vm.homeAirport = $0.uppercased() }

                AeroField(label: "Airport Name (optional)", text: $vm.homeAirportName,
                          placeholder: "e.g. Essex County Airport", icon: "building.2")
            }
        }
    }

    // MARK: - Aircraft

    private var aircraftSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Aircraft", icon: "airplane.circle.fill")

            VStack(spacing: 0) {
                if vm.aircraft.isEmpty {
                    emptyState(icon: "airplane",
                               title: "No aircraft yet",
                               subtitle: "Add the aircraft you flew — the scanner uses these for automatic matching")
                } else {
                    ForEach(vm.aircraft) { ac in
                        AircraftRow(aircraft: ac) {
                            editingAircraft = ac; showAircraftSheet = true
                        } onDelete: {
                            deletingAircraft = ac
                        }
                        if ac.id != vm.aircraft.last?.id { Divider().padding(.leading, 60) }
                    }
                }
                Divider()
                addButton("Add Aircraft") { editingAircraft = nil; showAircraftSheet = true }
            }
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)
            .padding(.horizontal)
        }
    }

    // MARK: - Simulators

    private var simulatorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Simulators", icon: "desktopcomputer")

            VStack(spacing: 0) {
                if vm.simulators.isEmpty {
                    emptyState(icon: "desktopcomputer",
                               title: "No simulators yet",
                               subtitle: "Add FTDs, BATDs, AATDs — the scanner uses these to match simulator column entries")
                } else {
                    ForEach(vm.simulators) { sim in
                        SimulatorRow(simulator: sim) {
                            editingSimulator = sim; showSimulatorSheet = true
                        } onDelete: {
                            deletingSimulator = sim
                        }
                        if sim.id != vm.simulators.last?.id { Divider().padding(.leading, 60) }
                    }
                }
                Divider()
                addButton("Add Simulator") { editingSimulator = nil; showSimulatorSheet = true }
            }
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)
            .padding(.horizontal)
        }
    }

    // MARK: - Instructors

    private var instructorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Instructors", icon: "person.badge.shield.checkmark.fill")

            VStack(spacing: 0) {
                if vm.instructors.isEmpty {
                    emptyState(icon: "person.2",
                               title: "No instructors yet",
                               subtitle: "Add your CFIs — the scanner matches their names automatically")
                } else {
                    ForEach(vm.instructors) { ins in
                        InstructorRow(instructor: ins) {
                            editingInstructor = ins; showInstructorSheet = true
                        } onDelete: {
                            deletingInstructor = ins
                        }
                        if ins.id != vm.instructors.last?.id { Divider().padding(.leading, 60) }
                    }
                }
                Divider()
                addButton("Add Instructor") { editingInstructor = nil; showInstructorSheet = true }
            }
            .background(AeroTheme.cardBg)
            .cornerRadius(AeroTheme.radiusLg)
            .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                .stroke(AeroTheme.cardStroke, lineWidth: 1))
            .shadow(color: AeroTheme.shadowCard, radius: 10, x: 0, y: 3)
            .padding(.horizontal)
        }
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            vm.save {
                withAnimation(.spring(response: 0.4)) { savedBanner = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { savedBanner = false }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if vm.isSaving { ProgressView().tint(.white).scaleEffect(0.85) }
                else { Image(systemName: "checkmark.circle.fill") }
                Text("Save Profile")
            }
            .aeroPrimaryButton()
        }
        .disabled(vm.isSaving)
    }

    private var savedConfirmation: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(.statusGreen)
            Text("Profile saved")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(AeroTheme.textPrimary)
            Spacer()
        }
        .padding(16)
        .background(AeroTheme.cardBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
            .stroke(Color.statusGreen.opacity(0.3), lineWidth: 1))
        .shadow(color: AeroTheme.shadowCard, radius: 12, x: 0, y: 4)
    }

    // MARK: - Shared UI helpers

    private func profileSection<Content: View>(title: String, icon: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title, icon: icon)
            VStack(spacing: 0) { content() }.aeroCard().padding(.horizontal)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2)
        }
        .foregroundStyle(AeroTheme.brandPrimary)
        .padding(.horizontal)
    }

    private func menuPickerRow(icon: String, value: String) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 13))
                .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7)).frame(width: 20)
            Text(value).font(.system(size: 15)).foregroundStyle(AeroTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12)).foregroundStyle(AeroTheme.textTertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(AeroTheme.fieldBg)
        .cornerRadius(AeroTheme.radiusMd)
        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd).stroke(AeroTheme.fieldStroke, lineWidth: 1))
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(AeroTheme.textTertiary)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AeroTheme.textSecondary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(AeroTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 20)
    }

    private func addButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(AeroTheme.brandPrimary)
                Text(label).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AeroTheme.brandPrimary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - AircraftRow

struct AircraftRow: View {
    let aircraft: AircraftRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AeroTheme.brandPrimary.opacity(0.1)).frame(width: 40, height: 40)
                Image(systemName: "airplane").font(.system(size: 16))
                    .foregroundStyle(AeroTheme.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(aircraft.registration)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(AeroTheme.textPrimary)
                let detail = "\(aircraft.make) \(aircraft.model)".trimmingCharacters(in: .whitespaces)
                Text(detail.isEmpty ? aircraft.aircraftClass : detail)
                    .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if aircraft.isComplex { badge("CX", color: .sky500) }
                if aircraft.isHighPerf { badge("HP", color: .statusAmber) }
                badge(aircraft.aircraftClass, color: AeroTheme.brandPrimary)
            }
            Button(action: onEdit) {
                Image(systemName: "pencil").font(.system(size: 13))
                    .foregroundStyle(AeroTheme.textTertiary)
            }.buttonStyle(PlainButtonStyle())

            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 13))
                    .foregroundStyle(Color.statusRed.opacity(0.7))
            }.buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.1)).foregroundStyle(color).cornerRadius(4)
    }
}

// MARK: - InstructorRow

struct InstructorRow: View {
    let instructor: InstructorRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AeroTheme.brandPrimary.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: "person.badge.shield.checkmark").font(.system(size: 15))
                    .foregroundStyle(AeroTheme.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(instructor.name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                HStack(spacing: 4) {
                    ForEach(instructor.ratings, id: \.self) { r in
                        Text(r).font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(AeroTheme.brandPrimary.opacity(0.1))
                            .foregroundStyle(AeroTheme.brandPrimary).cornerRadius(4)
                    }
                    if !instructor.certificateNumber.isEmpty {
                        Text(instructor.certificateNumber)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                }
            }
            Spacer()
            if instructor.usedForManualEntry {
                Text("Manual")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.statusGreen.opacity(0.1))
                    .foregroundStyle(Color.statusGreen)
                    .cornerRadius(4)
            }
            Button(action: onEdit) {
                Image(systemName: "pencil").font(.system(size: 13))
                    .foregroundStyle(AeroTheme.textTertiary)
            }.buttonStyle(PlainButtonStyle())

            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 13))
                    .foregroundStyle(Color.statusRed.opacity(0.7))
            }.buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

// MARK: - SimulatorRow

struct SimulatorRow: View {
    let simulator: SimulatorRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.sky500.opacity(0.1)).frame(width: 40, height: 40)
                Image(systemName: "desktopcomputer").font(.system(size: 15))
                    .foregroundStyle(Color.sky500)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(simulator.name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AeroTheme.textPrimary)
                HStack(spacing: 6) {
                    simBadge(simulator.deviceType)
                    if !simulator.aircraftSimulated.isEmpty {
                        Text(simulator.aircraftSimulated)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AeroTheme.textTertiary)
                    }
                }
            }
            Spacer()
            simBadge(simulator.approvalLevel)
            Button(action: onEdit) {
                Image(systemName: "pencil").font(.system(size: 13))
                    .foregroundStyle(AeroTheme.textTertiary)
            }.buttonStyle(PlainButtonStyle())
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 13))
                    .foregroundStyle(Color.statusRed.opacity(0.7))
            }.buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func simBadge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.sky500.opacity(0.1))
            .foregroundStyle(Color.sky500).cornerRadius(4)
    }
}

// MARK: - AircraftEditSheet
// When adding new aircraft: two-step flow
//   Step 1 — define type (make/model/engine/class/endorsements)
//   Step 2 — add one or more tail numbers, then save all at once
// When editing: single-aircraft form (registration locked)

struct AircraftEditSheet: View {
    let aircraft: AircraftRecord?           // nil = new, non-nil = edit existing
    let vm: ProfileViewModel
    let onDismiss: () -> Void

    // Shared type fields
    @State private var make          = ""
    @State private var model         = ""
    @State private var year          = ""
    @State private var engineType    = "Piston"
    @State private var category      = "Airplane"
    @State private var aircraftClass = "ASEL"
    @State private var isComplex     = false
    @State private var isHighPerf    = false
    @State private var isTAA         = false
    @State private var notes         = ""

    // Single-edit mode
    @State private var registration  = ""

    // Add-new mode — step + tail list
    @State private var step: Int = 1               // 1 = type details, 2 = tail numbers
    @State private var tailNumbers: [String] = [""] // at least one input row

    @State private var isSaving = false

    var isEditing: Bool { aircraft != nil }

    // Step 1 valid when make+model filled
    var step1Valid: Bool {
        !make.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
    // Step 2 valid when at least one non-empty tail number
    var step2Valid: Bool {
        tailNumbers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    // Edit mode valid
    var editValid: Bool {
        !registration.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        if isEditing {
                            editContent
                        } else if step == 1 {
                            stepOneContent
                        } else {
                            stepTwoContent
                        }
                        Color.clear.frame(height: 20)
                    }
                    .padding(.top, 16).padding(.bottom, 32)
                }
            }
            .navigationTitle(isEditing ? "Edit Aircraft" : (step == 1 ? "Aircraft Type" : "Tail Numbers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isEditing && step == 2 {
                        Button("Back") { withAnimation(.spring(response: 0.3)) { step = 1 } }
                            .foregroundStyle(AeroTheme.brandPrimary)
                    } else {
                        Button("Cancel", action: onDismiss)
                            .foregroundStyle(AeroTheme.brandPrimary)
                    }
                }
            }
        }
        .onAppear {
            guard let a = aircraft else { return }
            registration  = a.registration
            make          = a.make
            model         = a.model
            year          = a.year > 0 ? "\(a.year)" : ""
            engineType    = a.engineType
            category      = a.category
            aircraftClass = a.aircraftClass
            isComplex     = a.isComplex
            isHighPerf    = a.isHighPerf
            isTAA         = a.isTAA
            notes         = a.notes
        }
    }

    // MARK: - Edit existing aircraft (unchanged single form)

    private var editContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("REGISTRATION")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(AeroTheme.brandPrimary).padding(.horizontal)
                AeroField(label: "Tail Number / Registration",
                          text: $registration,
                          placeholder: "e.g. N12345 or VH-ABC",
                          icon: "number.square.fill")
                    .onChange(of: registration) { registration = $0.uppercased() }
                    .padding(.horizontal)
            }

            typeFieldsSection

            Button(action: saveEdit) {
                HStack(spacing: 8) {
                    if isSaving { ProgressView().tint(.white).scaleEffect(0.85) }
                    else { Image(systemName: "checkmark.circle.fill") }
                    Text("Save Changes")
                }
                .aeroPrimaryButton()
            }
            .disabled(!editValid || isSaving).opacity(!editValid ? 0.5 : 1)
            .padding(.horizontal)
        }
    }

    // MARK: - Step 1: define the aircraft type

    private var stepOneContent: some View {
        Group {
            // Step indicator
            stepIndicator(current: 1)

            HStack(spacing: 10) {
                Image(systemName: "info.circle").font(.system(size: 13))
                    .foregroundStyle(AeroTheme.brandPrimary)
                Text("Define the aircraft type once — you'll add tail numbers next")
                    .font(.system(size: 12)).foregroundStyle(AeroTheme.textSecondary)
            }
            .padding(12)
            .background(AeroTheme.brandPrimary.opacity(0.05))
            .cornerRadius(AeroTheme.radiusMd)
            .padding(.horizontal)

            typeFieldsSection

            Button {
                withAnimation(.spring(response: 0.3)) { step = 2 }
            } label: {
                HStack(spacing: 8) {
                    Text("Next — Add Tail Numbers")
                    Image(systemName: "arrow.right.circle.fill")
                }
                .aeroPrimaryButton()
            }
            .disabled(!step1Valid).opacity(!step1Valid ? 0.5 : 1)
            .padding(.horizontal)
        }
    }

    // MARK: - Step 2: add tail numbers

    private var stepTwoContent: some View {
        Group {
            stepIndicator(current: 2)

            // Type summary card
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AeroTheme.brandPrimary.opacity(0.1)).frame(width: 44, height: 44)
                    Image(systemName: "airplane")
                        .font(.system(size: 18)).foregroundStyle(AeroTheme.brandPrimary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(make) \(model)".trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(AeroTheme.textPrimary)
                    HStack(spacing: 6) {
                        typeBadge(aircraftClass)
                        typeBadge(engineType)
                        if isComplex { typeBadge("CX") }
                        if isHighPerf { typeBadge("HP") }
                        if isTAA { typeBadge("TAA") }
                    }
                }
                Spacer()
                Button { withAnimation(.spring(response: 0.3)) { step = 1 } } label: {
                    Text("Edit").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AeroTheme.brandPrimary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .aeroCard().padding(.horizontal)

            // Tail number input list
            VStack(alignment: .leading, spacing: 10) {
                Text("TAIL NUMBERS")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(AeroTheme.brandPrimary).padding(.horizontal)

                VStack(spacing: 0) {
                    ForEach(tailNumbers.indices, id: \.self) { i in
                        HStack(spacing: 10) {
                            Image(systemName: "number.square.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(AeroTheme.brandPrimary.opacity(0.6))
                                .frame(width: 22)

                            TextField("e.g. N12345", text: Binding(
                                get: { tailNumbers[i] },
                                set: { tailNumbers[i] = $0.uppercased() }
                            ))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(AeroTheme.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)

                            if tailNumbers.count > 1 {
                                Button {
                                    tailNumbers.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Color.statusRed.opacity(0.7))
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 13)

                        if i < tailNumbers.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }

                    Divider()

                    // Add another row
                    Button {
                        tailNumbers.append("")
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16)).foregroundStyle(AeroTheme.brandPrimary)
                            Text("Add Another Tail Number")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AeroTheme.brandPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 13)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .background(AeroTheme.cardBg)
                .cornerRadius(AeroTheme.radiusLg)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
                .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 2)
                .padding(.horizontal)
            }

            // Save all button
            Button(action: saveAll) {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    let count = tailNumbers.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                    Text(count > 1 ? "Save \(count) Aircraft" : "Save Aircraft")
                }
                .aeroPrimaryButton()
            }
            .disabled(!step2Valid || isSaving).opacity(!step2Valid ? 0.5 : 1)
            .padding(.horizontal)
        }
    }

    // MARK: - Shared type fields (used in both steps and edit mode)

    private var typeFieldsSection: some View {
        Group {
            sheetSection("Aircraft Details") {
                AeroField(label: "Make",  text: $make,  placeholder: "e.g. Cessna, Piper", icon: "building.fill")
                AeroField(label: "Model", text: $model, placeholder: "e.g. 172S, PA-28",   icon: "airplane")
                AeroField(label: "Year (optional)", text: $year, placeholder: "e.g. 1998", icon: "calendar")
            }
            sheetSection("Category & Class") {
                pickerRow("Category",    icon: "square.grid.2x2",   selection: $category,      options: vm.categories)
                pickerRow("Class",       icon: "list.bullet",       selection: $aircraftClass, options: vm.classes)
                pickerRow("Engine Type", icon: "engine.combustion", selection: $engineType,    options: vm.engineTypes)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("ENDORSEMENTS REQUIRED")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(AeroTheme.brandPrimary).padding(.horizontal)
                VStack(spacing: 0) {
                    toggleRow("Complex",          sub: "Retractable gear + flaps + CSP", icon: "gearshape.2", val: $isComplex)
                    Divider().padding(.leading, 60)
                    toggleRow("High Performance", sub: "More than 200 HP",               icon: "bolt.fill",   val: $isHighPerf)
                    Divider().padding(.leading, 60)
                    toggleRow("TAA",              sub: "Glass cockpit + autopilot",      icon: "display",     val: $isTAA)
                }
                .background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                    .stroke(AeroTheme.cardStroke, lineWidth: 1))
                .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 2)
                .padding(.horizontal)
            }
            AeroField(label: "Notes (optional)", text: $notes,
                      placeholder: "e.g. Club aircraft", icon: "note.text")
                .padding(.horizontal)
        }
    }

    // MARK: - Save functions

    private func saveEdit() {
        isSaving = true
        let newReg = registration.trimmingCharacters(in: .whitespaces)
        let oldReg = aircraft?.registration ?? newReg
        let rec = AircraftRecord(
            registration: newReg,
            make: make, model: model, year: Int(year) ?? 0,
            engineType: engineType, category: category, aircraftClass: aircraftClass,
            isComplex: isComplex, isHighPerf: isHighPerf, isTAA: isTAA, notes: notes
        )
        if newReg != oldReg {
            // Registration changed — rename atomically (updates flights table too)
            vm.renameAircraft(oldRegistration: oldReg, updated: rec) {
                isSaving = false; onDismiss()
            }
        } else {
            vm.saveAircraft(rec) { isSaving = false; onDismiss() }
        }
    }

    private func saveAll() {
        let regs = tailNumbers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !regs.isEmpty else { return }
        isSaving = true

        // Save each registration as a separate AircraftRecord — same type details
        let group = DispatchGroup()
        for reg in regs {
            group.enter()
            let rec = AircraftRecord(
                registration: reg,
                make: make, model: model, year: Int(year) ?? 0,
                engineType: engineType, category: category, aircraftClass: aircraftClass,
                isComplex: isComplex, isHighPerf: isHighPerf, isTAA: isTAA, notes: notes
            )
            vm.saveAircraft(rec) { group.leave() }
        }
        group.notify(queue: .main) {
            isSaving = false
            onDismiss()
        }
    }

    // MARK: - Step indicator

    private func stepIndicator(current: Int) -> some View {
        HStack(spacing: 0) {
            stepDot(n: 1, label: "Type", active: current == 1, done: current > 1)
            Rectangle().fill(current > 1 ? AeroTheme.brandPrimary : AeroTheme.cardStroke)
                .frame(height: 2).frame(maxWidth: .infinity)
            stepDot(n: 2, label: "Tail Numbers", active: current == 2, done: false)
        }
        .padding(.horizontal, 32).padding(.vertical, 4)
    }

    private func stepDot(n: Int, label: String, active: Bool, done: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(done ? AeroTheme.brandPrimary : (active ? AeroTheme.brandPrimary : AeroTheme.cardStroke))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(active ? .white : AeroTheme.textTertiary)
                }
            }
            Text(label).font(.system(size: 10, weight: active || done ? .semibold : .regular))
                .foregroundStyle(active || done ? AeroTheme.brandPrimary : AeroTheme.textTertiary)
        }
    }

    private func typeBadge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(AeroTheme.brandPrimary.opacity(0.1))
            .foregroundStyle(AeroTheme.brandPrimary).cornerRadius(4)
    }

    // MARK: - Sheet helpers (same as before)

    private func sheetSection<Content: View>(_ title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(1.2)
                .foregroundStyle(AeroTheme.brandPrimary).padding(.horizontal)
            VStack(spacing: 14) { content() }.aeroCard().padding(.horizontal)
        }
    }

    private func pickerRow(_ label: String, icon: String,
                            selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AeroTheme.textSecondary)
            Menu {
                ForEach(options, id: \.self) { opt in Button(opt) { selection.wrappedValue = opt } }
            } label: {
                HStack {
                    Image(systemName: icon).font(.system(size: 13))
                        .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7)).frame(width: 20)
                    Text(selection.wrappedValue).font(.system(size: 15)).foregroundStyle(AeroTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(AeroTheme.fieldBg).cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.fieldStroke, lineWidth: 1))
            }
        }
    }

    private func toggleRow(_ title: String, sub: String, icon: String, val: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(AeroTheme.brandPrimary.opacity(0.1)).frame(width: 36, height: 36)
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(AeroTheme.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AeroTheme.textPrimary)
                Text(sub).font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: val).tint(AeroTheme.brandPrimary).labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - InstructorEditSheet

struct InstructorEditSheet: View {
    let instructor: InstructorRecord?
    let vm: ProfileViewModel
    let onDismiss: () -> Void

    @State private var name             = ""
    @State private var certNumber       = ""
    @State private var selectedRatings  = Set<String>(["CFI"])
    @State private var notes            = ""
    @State private var usedForManualEntry = false
    @State private var isSaving         = false

    var isEditing: Bool { instructor != nil }
    var canSave:   Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !selectedRatings.isEmpty }

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        VStack(spacing: 14) {
                            AeroField(label: "Full Name", text: $name,
                                      placeholder: "e.g. Jane Doe", icon: "person.fill")

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ratings (select all that apply)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AeroTheme.textSecondary)
                                HStack(spacing: 6) {
                                    ForEach(vm.allRatings, id: \.self) { r in
                                        let selected = selectedRatings.contains(r)
                                        Button {
                                            if selected { selectedRatings.remove(r) }
                                            else { selectedRatings.insert(r) }
                                        } label: {
                                            Text(r).font(.system(size: 12, weight: .semibold))
                                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                                .background(selected ? AeroTheme.brandPrimary : AeroTheme.fieldBg)
                                                .foregroundStyle(selected ? .white : AeroTheme.textSecondary)
                                                .cornerRadius(AeroTheme.radiusSm)
                                                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusSm)
                                                    .stroke(selected ? AeroTheme.brandPrimary : AeroTheme.fieldStroke, lineWidth: 1))
                                        }.buttonStyle(PlainButtonStyle())
                                        .animation(.spring(response: 0.15), value: selected)
                                    }
                                }
                                if selectedRatings.isEmpty {
                                    Text("Select at least one rating")
                                        .font(.system(size: 11)).foregroundStyle(.statusAmber)
                                }
                            }

                            AeroField(label: "Certificate Number (optional)", text: $certNumber,
                                      placeholder: "e.g. 1234567CFI", icon: "creditcard.fill")
                            AeroField(label: "Notes (optional)", text: $notes,
                                      placeholder: "e.g. Primary trainer at KCDW", icon: "note.text")
                        }
                        .aeroCard().padding(.horizontal)

                        // Manual entry shortcut toggle
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9).fill(AeroTheme.brandPrimary.opacity(0.1))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "pencil.and.list.clipboard").font(.system(size: 14))
                                    .foregroundStyle(AeroTheme.brandPrimary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show in Manual Entry").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AeroTheme.textPrimary)
                                Text("Pre-fills the CFI field when logging flights manually")
                                    .font(.system(size: 11)).foregroundStyle(AeroTheme.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $usedForManualEntry).tint(AeroTheme.brandPrimary).labelsHidden()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(AeroTheme.cardBg).cornerRadius(AeroTheme.radiusLg)
                        .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusLg)
                            .stroke(AeroTheme.cardStroke, lineWidth: 1))
                        .shadow(color: AeroTheme.shadowCard, radius: 8, x: 0, y: 2)
                        .padding(.horizontal)

                        Button(action: save) {
                            HStack(spacing: 8) {
                                if isSaving { ProgressView().tint(.white).scaleEffect(0.85) }
                                else { Image(systemName: "checkmark.circle.fill") }
                                Text(isEditing ? "Save Changes" : "Add Instructor")
                            }
                            .aeroPrimaryButton()
                        }
                        .disabled(!canSave || isSaving).opacity(!canSave ? 0.5 : 1)
                        .padding(.horizontal)

                        Color.clear.frame(height: 20)
                    }
                    .padding(.top, 16).padding(.bottom, 32)
                }
            }
            .navigationTitle(isEditing ? "Edit Instructor" : "Add Instructor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onDismiss).foregroundStyle(AeroTheme.brandPrimary)
                }
            }
        }
        .onAppear {
            guard let i = instructor else { return }
            name                = i.name
            certNumber          = i.certificateNumber
            selectedRatings     = Set(i.ratings)
            notes               = i.notes
            usedForManualEntry  = i.usedForManualEntry
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        // Sort ratings in canonical order for consistent display
        let order = ["CFI", "CFII", "MEI", "ATP", "Other"]
        let sorted = order.filter { selectedRatings.contains($0) }
        let rec = InstructorRecord(
            id: instructor?.id ?? 0,
            name: name.trimmingCharacters(in: .whitespaces),
            certificateNumber: certNumber,
            ratings: sorted.isEmpty ? Array(selectedRatings) : sorted,
            notes: notes,
            usedForManualEntry: usedForManualEntry
        )
        vm.saveInstructor(rec) { isSaving = false; onDismiss() }
    }
}

// MARK: - SimulatorEditSheet

struct SimulatorEditSheet: View {
    let simulator: SimulatorRecord?
    let vm: ProfileViewModel
    let onDismiss: () -> Void

    @State private var name              = ""
    @State private var deviceType        = "BATD"
    @State private var approvalLevel     = "FAA Approved"
    @State private var make              = ""
    @State private var model             = ""
    @State private var aircraftSimulated = ""
    @State private var location          = ""
    @State private var notes             = ""
    @State private var isSaving          = false

    var isEditing: Bool { simulator != nil }
    var canSave: Bool   { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    let deviceTypes    = ["FFS", "FTD", "AATD", "BATD", "ATD", "PCATDx"]
    let approvalLevels = ["FAA Approved", "Non-certified", "Level A", "Level B",
                          "Level C", "Level D", "Level 4", "Level 5", "Level 6", "Level 7"]

    var body: some View {
        NavigationView {
            ZStack {
                AeroTheme.pageBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        // Name
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SIMULATOR NAME")
                                .font(.system(size: 11, weight: .bold)).tracking(1.2)
                                .foregroundStyle(AeroTheme.brandPrimary).padding(.horizontal)
                            AeroField(label: "Display Name", text: $name,
                                      placeholder: "e.g. Redbird TD2 or Club Frasca",
                                      icon: "desktopcomputer")
                                .padding(.horizontal)
                            Text("The name shown in the scanner matching list")
                                .font(.system(size: 11)).foregroundStyle(AeroTheme.textTertiary)
                                .padding(.horizontal)
                        }

                        // Device type
                        VStack(alignment: .leading, spacing: 10) {
                            Text("DEVICE TYPE")
                                .font(.system(size: 11, weight: .bold)).tracking(1.2)
                                .foregroundStyle(AeroTheme.brandPrimary).padding(.horizontal)

                            // Row 1: FFS, FTD, AATD
                            HStack(spacing: 6) {
                                ForEach(["FFS", "FTD", "AATD"], id: \.self) { t in
                                    typeToggle(t)
                                }
                            }.padding(.horizontal)
                            // Row 2: BATD, ATD, PCATDx
                            HStack(spacing: 6) {
                                ForEach(["BATD", "ATD", "PCATDx"], id: \.self) { t in
                                    typeToggle(t)
                                }
                            }.padding(.horizontal)

                            // FAA definitions hint
                            VStack(alignment: .leading, spacing: 3) {
                                typeHint("FFS", "Full Flight Simulator — highest fidelity, Level A–D")
                                typeHint("FTD", "Flight Training Device — Level 1–7")
                                typeHint("AATD", "Advanced Aviation Training Device")
                                typeHint("BATD", "Basic Aviation Training Device")
                            }
                            .padding(10)
                            .background(AeroTheme.brandPrimary.opacity(0.04))
                            .cornerRadius(AeroTheme.radiusSm)
                            .padding(.horizontal)
                        }

                        // Approval level + device details
                        simSection("Device Details") {
                            pickerRow("Approval Level", icon: "checkmark.seal",
                                      selection: $approvalLevel, options: approvalLevels)
                            AeroField(label: "Manufacturer", text: $make,
                                      placeholder: "e.g. Redbird, Frasca, Elite", icon: "building.fill")
                            AeroField(label: "Device Model", text: $model,
                                      placeholder: "e.g. TD2, 141, PCATD", icon: "cpu")
                        }

                        simSection("Usage Info") {
                            AeroField(label: "Aircraft Simulated", text: $aircraftSimulated,
                                      placeholder: "e.g. C172, PA-28, B737",
                                      icon: "airplane")
                            AeroField(label: "Location", text: $location,
                                      placeholder: "e.g. KCDW Flight School",
                                      icon: "mappin.circle")
                            AeroField(label: "Notes (optional)", text: $notes,
                                      placeholder: "e.g. IFR approved, used for instrument currency",
                                      icon: "note.text")
                        }

                        Button(action: save) {
                            HStack(spacing: 8) {
                                if isSaving { ProgressView().tint(.white).scaleEffect(0.85) }
                                else { Image(systemName: "checkmark.circle.fill") }
                                Text(isEditing ? "Save Changes" : "Add Simulator")
                            }
                            .aeroPrimaryButton()
                        }
                        .disabled(!canSave || isSaving).opacity(!canSave ? 0.5 : 1)
                        .padding(.horizontal)

                        Color.clear.frame(height: 20)
                    }
                    .padding(.top, 16).padding(.bottom, 32)
                }
            }
            .navigationTitle(isEditing ? "Edit Simulator" : "Add Simulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onDismiss).foregroundStyle(AeroTheme.brandPrimary)
                }
            }
        }
        .onAppear {
            guard let s = simulator else { return }
            name              = s.name
            deviceType        = s.deviceType
            approvalLevel     = s.approvalLevel
            make              = s.make
            model             = s.model
            aircraftSimulated = s.aircraftSimulated
            location          = s.location
            notes             = s.notes
        }
    }

    private func save() {
        isSaving = true
        let rec = SimulatorRecord(
            id: simulator?.id ?? 0,
            name: name.trimmingCharacters(in: .whitespaces),
            deviceType: deviceType, approvalLevel: approvalLevel,
            make: make, model: model,
            aircraftSimulated: aircraftSimulated,
            location: location, notes: notes
        )
        vm.saveSimulator(rec) { isSaving = false; onDismiss() }
    }

    // MARK: Helpers

    private func typeToggle(_ type: String) -> some View {
        Button { deviceType = type } label: {
            Text(type).font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(deviceType == type ? Color.sky500 : AeroTheme.fieldBg)
                .foregroundStyle(deviceType == type ? .white : AeroTheme.textSecondary)
                .cornerRadius(AeroTheme.radiusSm)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusSm)
                    .stroke(deviceType == type ? Color.sky500 : AeroTheme.fieldStroke, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.spring(response: 0.15), value: deviceType)
    }

    private func typeHint(_ abbrev: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(abbrev).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.sky500)
                .frame(width: 44, alignment: .leading)
            Text(desc).font(.system(size: 10)).foregroundStyle(AeroTheme.textTertiary)
        }
    }

    private func simSection<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(1.2)
                .foregroundStyle(AeroTheme.brandPrimary).padding(.horizontal)
            VStack(spacing: 14) { content() }.aeroCard().padding(.horizontal)
        }
    }

    private func pickerRow(_ label: String, icon: String,
                            selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AeroTheme.textSecondary)
            Menu {
                ForEach(options, id: \.self) { opt in Button(opt) { selection.wrappedValue = opt } }
            } label: {
                HStack {
                    Image(systemName: icon).font(.system(size: 13))
                        .foregroundStyle(AeroTheme.brandPrimary.opacity(0.7)).frame(width: 20)
                    Text(selection.wrappedValue).font(.system(size: 15)).foregroundStyle(AeroTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                        .foregroundStyle(AeroTheme.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(AeroTheme.fieldBg).cornerRadius(AeroTheme.radiusMd)
                .overlay(RoundedRectangle(cornerRadius: AeroTheme.radiusMd)
                    .stroke(AeroTheme.fieldStroke, lineWidth: 1))
            }
        }
    }
}

// MARK: - Backward compatibility shim

struct ProfileField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var icon: String? = nil
    var body: some View {
        AeroField(label: label, text: $text, placeholder: placeholder, icon: icon)
    }
}

#Preview { NavigationView { ProfileView() } }
