import SwiftUI

/// Feuille d'édition corporelle hors onboarding : âge, taille, poids (validés par les setters de
/// `UserPreferences`), puis la FC max. Les valeurs s'enregistrent à la validation d'un champ.
struct BodyMeasuresEditor: View {
    @ObservedObject var prefs: UserPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var ageText = ""
    @State private var heightText = ""
    @State private var weightText = ""
    @State private var error: String?

    private var metric: Bool { prefs.unitSystem == .metric }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LoopMeasure.sectionSpacing) {
                    measuresGroup
                    if let error {
                        Text(error)
                            .font(LoopType.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, LoopMeasure.screenGutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(LoopColor.bgSheet)
            .navigationTitle(NSLocalizedString("profile.measures.title", tableName: "Base", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("profile.done", tableName: "Base", comment: "")) {
                        commitAll()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: syncFromPrefs)
        }
    }

    // MARK: - Lignes

    private var measuresGroup: some View {
        VStack(spacing: 0) {
            field(title: NSLocalizedString("profile.body.age", tableName: "Base", comment: ""),
                  text: $ageText, unit: NSLocalizedString("profile.unit.years", tableName: "Base", comment: ""),
                  keyboard: .numberPad) { commitAge() }
            Rectangle().fill(LoopColor.strokeCard).frame(height: 1)
            field(title: NSLocalizedString("profile.body.height", tableName: "Base", comment: ""),
                  text: $heightText, unit: metric ? "cm" : NSLocalizedString("profile.unit.inch", tableName: "Base", comment: ""),
                  keyboard: .decimalPad) { commitHeight() }
            Rectangle().fill(LoopColor.strokeCard).frame(height: 1)
            field(title: NSLocalizedString("profile.body.weight", tableName: "Base", comment: ""),
                  text: $weightText, unit: metric ? "kg" : "lb",
                  keyboard: .decimalPad) { commitWeight() }
        }
        .loopCard(.card)
    }

    private func field(title: String, text: Binding<String>, unit: String, keyboard: UIKeyboardType, onSubmit: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(LoopType.body)
                .foregroundStyle(LoopColor.textPrimary)
            Spacer()
            TextField("", text: text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(LoopType.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: 96)
                .onSubmit(onSubmit)
            Text(unit)
                .font(LoopType.body)
                .foregroundStyle(LoopColor.textSecondary)
        }
        .padding(.horizontal, LoopMeasure.cardPadding)
        .frame(minHeight: 52)
    }

    // MARK: - Actions

    private func syncFromPrefs() {
        ageText = prefs.manualAge.map(String.init) ?? ""
        if let cm = prefs.heightCm {
            heightText = metric ? String(Int(cm.rounded())) : String(Int(BodyProfileFormatting.cmToInches(cm).rounded()))
        }
        if let kg = prefs.weightKg {
            let value = metric ? kg : BodyProfileFormatting.kgToLb(kg)
            weightText = value.formatted(.number.precision(.fractionLength(0...1)))
        }
    }

    private func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func commitAll() {
        commitAge()
        commitHeight()
        commitWeight()
    }

    private func commitAge() {
        let trimmed = ageText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let age = Int(trimmed), BodyProfileFormatting.validatedAge(age) != nil, prefs.setManualAge(age) else {
            error = NSLocalizedString("profile.error.age", tableName: "Base", comment: "")
            return
        }
        error = nil
    }

    private func commitHeight() {
        guard let value = parse(heightText) else { return }
        guard let cm = BodyProfileFormatting.validatedHeightCm(value, units: prefs.unitSystem), prefs.setHeightCm(cm) else {
            error = NSLocalizedString("profile.error.height", tableName: "Base", comment: "")
            return
        }
        error = nil
    }

    private func commitWeight() {
        guard let value = parse(weightText) else { return }
        guard let kg = BodyProfileFormatting.validatedWeightKg(value, units: prefs.unitSystem), prefs.setWeightKg(kg) else {
            error = NSLocalizedString("profile.error.weight", tableName: "Base", comment: "")
            return
        }
        error = nil
    }
}

#Preview {
    BodyMeasuresEditor(prefs: .shared)
}
