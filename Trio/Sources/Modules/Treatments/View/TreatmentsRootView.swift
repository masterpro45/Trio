import Charts
import CoreData
import LoopKitUI
import SwiftUI
import Swinject

extension Treatments {
    struct RootView: BaseView {
        enum FocusedField {
            case carbs
            case fat
            case protein
            case bolus
        }

        @FocusState private var focusedField: FocusedField?

        let resolver: Resolver

        @State var state = StateModel()

        @State private var showPresetSheet = false
        @State private var autofocus: Bool = true
        @State private var calculatorDetent = PresentationDetent.large
        @State private var pushed: Bool = false
        @State private var debounce: DispatchWorkItem?
        @State private var showFatProteinOrderBanner = false
        /// Sweet Miranda: carbs came from her Eat screen, so fill the Bolus field with Trio's own
        /// recommendation once it is calculated — until she types her own amount.
        @State private var sweetMirandaPrefill = false
        /// Sweet Miranda: her colours on this screen while her home screen is on (off = stock Trio).
        private var sweetMirandaSkin: Bool { SweetMirandaSkin.shared.isEnabled }
        @State private var sweetMirandaPrefilled: Decimal = 0

        private enum Config {
            static let dividerHeight: CGFloat = 2
            static let spacing: CGFloat = 3
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 2
            formatter.maximumFractionDigits = 3
            return formatter
        }

        private var bolusProgressFormatter: NumberFormatter {
            let fractionDigits: Int = switch state.settingsManager.preferences.bolusIncrement {
            case 0.1: 1
            case 0.025: 3
            default: 2
            }

            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimum = 0
            formatter.maximumFractionDigits = fractionDigits
            formatter.minimumFractionDigits = fractionDigits
            formatter.allowsFloats = true
            formatter.roundingIncrement = Double(state.settingsManager.preferences.bolusIncrement) as NSNumber
            return formatter
        }

        private var mealFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 3
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var gluoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.maximumIntegerDigits = 2
                formatter.maximumFractionDigits = 1
            } else {
                formatter.maximumIntegerDigits = 3
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        private var fractionDigits: Int {
            if state.units == .mmolL {
                return 1
            } else { return 0 }
        }

        /// Handles macro input (carb, fat, protein) in a debounced fashion.
        func handleDebouncedInput() {
            debounce?.cancel()
            debounce = DispatchWorkItem { [self] in
                Task {
                    await state.updateForecasts()
                    state.insulinCalculated = await state.calculateInsulin()
                }
            }
            if let debounce = debounce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: debounce)
            }
        }

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                HStack {
                    Text("Fat")
                    TextFieldWithToolBar(
                        text: $state.fat,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .fat) },
                        nextTextField: { focusedField = nextField(from: .fat) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .fat)
                }

                Divider().foregroundStyle(.primary).fontWeight(.bold).frame(width: 10)

                HStack {
                    Text("Protein")
                    TextFieldWithToolBar(
                        text: $state.protein,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .protein) },
                        nextTextField: { focusedField = nextField(from: .protein) },
                        unitsText: String(localized: "g", comment: "Units for carbs")
                    )
                    .focused($focusedField, equals: .protein)
                }
            }
        }

        @ViewBuilder private func carbsTextField() -> some View {
            HStack {
                Text("Carbs")
                Spacer()
                TextFieldWithToolBar(
                    text: $state.carbs,
                    placeholder: "0",
                    keyboardType: .numberPad,
                    numberFormatter: mealFormatter,
                    showArrows: true,
                    previousTextField: { focusedField = previousField(from: .carbs) },
                    nextTextField: { focusedField = nextField(from: .carbs) },
                    unitsText: String(localized: "g", comment: "Units for carbs")
                )
                .focused($focusedField, equals: .carbs)
                .onChange(of: state.carbs) {
                    handleDebouncedInput()
                }
                .onChange(of: state.insulinCalculated) { _, recommended in
                    // Sweet Miranda: Trio's own recommendation into the Bolus field; she still
                    // reviews it and confirms with Trio's button. Stops once she edits the amount.
                    guard sweetMirandaPrefill else { return }
                    guard state.amount == 0 || state.amount == sweetMirandaPrefilled else {
                        sweetMirandaPrefill = false
                        return
                    }
                    state.amount = recommended
                    sweetMirandaPrefilled = recommended
                }
            }
        }

        /// Determines the next field to focus on based on the current focused field.
        ///
        /// This function handles the tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The next field that should receive focus, or nil if there is no next field
        private func nextField(from current: FocusedField) -> FocusedField? {
            // If fat/protein fields are hidden, skip them in navigation
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .protein
            case .protein:
                return .bolus
            case .carbs:
                return showFPU ? .fat : .bolus
            case .bolus:
                return .carbs
            }
        }

        /// Determines the previous field to focus on based on the current focused field.
        ///
        /// This function handles the reverse tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The previous field that should receive focus, or nil if there is no previous field
        private func previousField(from current: FocusedField) -> FocusedField? {
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .carbs
            case .protein:
                return .fat
            case .carbs:
                return .bolus
            case .bolus:
                return showFPU ? .protein : .carbs
            }
        }

        var body: some View {
            ZStack(alignment: .center) {
                VStack {
                    List {
                        Section {
                            ForecastChart(state: state)
                                .padding(.vertical)
                        }.listRowBackground(sweetMirandaSkin ? Color.white.opacity(0.06) : Color.chart)

                        Section {
                            carbsTextField()

                            if state.useFPUconversion {
                                proteinAndFat()

                                if showFatProteinOrderBanner {
                                    HStack {
                                        Image(systemName: "arrow.left.arrow.right")
                                        Text("The order of Fat and Protein inputs has changed.").font(.callout)
                                        Spacer()
                                        Button {
                                            PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange = true
                                            withAnimation { showFatProteinOrderBanner = false }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(Text("Dismiss"))
                                    }
                                    .listRowBackground(Color.orange.opacity(0.75))
                                    .transition(.opacity)
                                }
                            }

                            // Time
                            HStack {
                                // Semi-hacky workaround to make sure the List renders the horizontal divider properly between the `Time` and `Note` rows within the Section
                                HStack {
                                    Text("")
                                    Image(systemName: "clock").padding(.leading, -7)
                                }

                                Spacer()
                                if !pushed {
                                    Button {
                                        pushed = true
                                    } label: { Text("Now") }.buttonStyle(.borderless).foregroundColor(.secondary)
                                        .padding(.trailing, 5)
                                } else {
                                    Button { state.date = state.date.addingTimeInterval(-15.minutes.timeInterval) }
                                    label: { Image(systemName: "minus.circle") }.tint(.blue).buttonStyle(.borderless)
                                        .accessibilityLabel(Text("15 minutes earlier"))

                                    DatePicker(
                                        "Time",
                                        selection: $state.date,
                                        displayedComponents: [.hourAndMinute]
                                    ).controlSize(.mini)
                                        .labelsHidden()
                                        .onChange(of: state.date) { _, _ in
                                            // Trigger simulation when date changes to update forecasts for backdated carbs
                                            Task {
                                                // `updateForecasts()` does update the `simulatedDetermination` of type `Determination?` var on the main thread, so I can use this to pass its cob value into the bolus calc manager
                                                await state.updateForecasts()
                                                state.insulinCalculated = await state.calculateInsulin()
                                            }
                                        }
                                    Button {
                                        state.date = state.date.addingTimeInterval(15.minutes.timeInterval)
                                    }
                                    label: { Image(systemName: "plus.circle") }.tint(.blue).buttonStyle(.borderless)
                                        .accessibilityLabel(Text("15 minutes later"))
                                }
                            }

                            // Notes
                            HStack {
                                Image(systemName: "square.and.pencil")
                                TextFieldWithToolBarString(
                                    text: $state.note,
                                    placeholder: String(localized: "Note..."),
                                    maxLength: 25
                                )
                            }
                        }
                        .listRowBackground(
                            sweetMirandaSkin ? Color(red: 1.0, green: 0.55, blue: 0.2).opacity(0.30) : Color
                                .chart
                        )

                        Section {
                            if sweetMirandaSkin {
                                // Her screen stays simple: no toggles, no raw amount field (the
                                // confusing "0"), no external-insulin switch — just what Trio suggests.
                                smSuggestionRow
                            } else {
                                if state.fattyMeals || state.sweetMeals {
                                    HStack(spacing: 10) {
                                        if state.fattyMeals {
                                            Toggle(isOn: $state.useFattyMealCorrectionFactor) {
                                                Text("Reduced Bolus")
                                            }
                                            .toggleStyle(RadioButtonToggleStyle())
                                            .font(.footnote)
                                            .onChange(of: state.useFattyMealCorrectionFactor) {
                                                Task {
                                                    state.insulinCalculated = await state.calculateInsulin()
                                                    if state.useFattyMealCorrectionFactor {
                                                        state.useSuperBolus = false
                                                    }
                                                }
                                            }
                                        }
                                        if state.sweetMeals {
                                            Toggle(isOn: $state.useSuperBolus) {
                                                Text("Super Bolus")
                                            }
                                            .toggleStyle(RadioButtonToggleStyle())
                                            .font(.footnote)
                                            .onChange(of: state.useSuperBolus) {
                                                Task {
                                                    state.insulinCalculated = await state.calculateInsulin()
                                                    if state.useSuperBolus {
                                                        state.useFattyMealCorrectionFactor = false
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                HStack {
                                    HStack {
                                        Text("Recommendation")
                                        Button(action: {
                                            state.showInfo.toggle()
                                        }, label: {
                                            Image(systemName: "info.circle")
                                        })
                                            .foregroundStyle(.blue)
                                            .buttonStyle(PlainButtonStyle())
                                            .accessibilityLabel(Text("About the recommendation"))
                                    }
                                    Spacer()
                                    Button {
                                        state.amount = state.insulinCalculated
                                    } label: {
                                        HStack {
                                            Text(
                                                formatter
                                                    .string(from: Double(state.insulinCalculated) as NSNumber) ?? ""
                                            )

                                            Text(
                                                String(
                                                    localized:
                                                    " U",
                                                    comment: "Unit in number of units delivered (keep the space character!)"
                                                )
                                            ).foregroundColor(.secondary)
                                        }
                                    }
                                    .disabled(state.insulinCalculated == 0 || state.amount == state.insulinCalculated)
                                    .buttonStyle(.bordered).padding(.trailing, -10)
                                    .accessibilityLabel(Text(
                                        "Use recommended bolus, "
                                            + (formatter.string(from: Double(state.insulinCalculated) as NSNumber) ?? "")
                                            + " " + String(localized: "units", comment: "Insulin units, spoken")
                                    ))
                                    .accessibilityHint(Text("Copies the recommended amount into the bolus field"))
                                }

                                HStack {
                                    Text("Bolus")
                                    Spacer()
                                    TextFieldWithToolBar(
                                        text: $state.amount,
                                        placeholder: "0",
                                        textColor: colorScheme == .dark ? .white : .blue,
                                        maxLength: 5,
                                        numberFormatter: formatter,
                                        showArrows: true,
                                        previousTextField: { focusedField = previousField(from: .bolus) },
                                        nextTextField: { focusedField = nextField(from: .bolus) },
                                        unitsText: String(localized: "U", comment: "Units for bolus amount")
                                    ).focused($focusedField, equals: .bolus)
                                        .onChange(of: state.amount) {
                                            Task {
                                                await state.updateForecasts()
                                            }
                                        }
                                }

                                HStack {
                                    Text("External Insulin")
                                    Spacer()
                                    Toggle("", isOn: $state.externalInsulin).toggleStyle(CheckboxToggleStyle())
                                }
                            }
                        }.listRowBackground(sweetMirandaSkin ? SweetMirandaPalette.mint.opacity(0.38) : Color.chart)

                        treatmentButton
                    }
                    .listSectionSpacing(sectionSpacing)
                }
                .blur(radius: state.isAwaitingDeterminationResult ? 5 : 0)

                if state.isAwaitingDeterminationResult {
                    CustomProgressView(text: progressText.displayName)
                }
            }
            .padding(.top)
            .ignoresSafeArea(edges: .top)
            .scrollContentBackground(.hidden)
            .background {
                if sweetMirandaSkin {
                    LinearGradient(
                        colors: [SweetMirandaPalette.ground, Color(red: 0.30, green: 0.08, blue: 0.20)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                } else {
                    appState.trioBackgroundColor(for: colorScheme)
                }
            }
            .preferredColorScheme(sweetMirandaSkin ? .dark : nil)
            .blur(radius: state.showInfo ? 3 : 0)
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.hideModal()
                    } label: {
                        Text("Close")
                    }
                }
                if state.displayPresets {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            showPresetSheet = true
                        }, label: {
                            HStack {
                                Text("Presets")
                                Image(systemName: "plus")
                            }
                        })
                    }
                }
            })
            .onAppear {
                configureView {
                    state.isActive = true
                    // Sweet Miranda: on her skin, always follow Trio's recommendation into the
                    // (hidden) bolus amount, so the HOLD-TO-BOLUS button is live whether she came
                    // through EAT or typed carbs straight in. Stops if a parent edits the amount
                    // (only possible with the skin off).
                    if sweetMirandaSkin { sweetMirandaPrefill = true }
                    // Sweet Miranda: carbs she picked on her Eat screen, handed over once.
                    if let meal = SweetMirandaMealHandoff.take() {
                        state.carbs = meal.carbs
                        if state.note.isEmpty { state.note = meal.note }
                        // The first calculation below runs before this screen has loaded glucose,
                        // IOB and the forecast, so run the same pipeline typed carbs run, twice,
                        // once the data is in.
                        sweetMirandaPrefill = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { handleDebouncedInput() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { handleDebouncedInput() }
                    }
                    Task { @MainActor in
                        state.insulinCalculated = await state.calculateInsulin()
                    }

                    if PropertyPersistentFlags.shared.hasSeenFatProteinOrderChange != true {
                        showFatProteinOrderBanner = true
                    }
                }
            }
            .onDisappear {
                state.isActive = false
                state.addButtonPressed = false

                // Cancel all Combine subscriptions and unregister State from broadcaster
                state.cleanupTreatmentState()
            }
            .sheet(isPresented: $state.showInfo) {
                PopupView(state: state)
            }
            .sheet(isPresented: $showPresetSheet, onDismiss: {
                showPresetSheet = false
            }) {
                MealPresetView(state: state)
            }
            .alert("Error while processing Treatment", isPresented: $state.showDeterminationFailureAlert) {
                Button("OK", role: .cancel) {
                    state.hideModal()
                }
            } message: {
                Text("\(state.determinationFailureMessage)")
            }
        }

        var progressText: ProgressText {
            switch (state.amount > 0, state.carbs > 0) {
            case (true, true):
                return .updatingIOBandCOB
            case (false, true):
                return .updatingCOB
            case (true, false):
                return .updatingIOB
            default:
                return .updatingTreatments
            }
        }

        @State private var showConfirmDialogForBolusing = false
        // Sweet Miranda: her BOLUS button is a 2-second hold instead of Face ID.
        @State private var bolusHolding = false
        @State private var bolusHoldProgress: CGFloat = 0
        @State private var smBolusSkipAuth = false

        private var bolusWarning: (shouldConfirm: Bool, warningMessage: String, color: Color) {
            let isGlucoseVeryLow = state.currentBG < 54
            let isForecastVeryLow = state.minPredBG < 54

            // Only warn when enacting a bolus via pump
            guard !state.externalInsulin, state.amount > 0 else {
                return (false, "", .primary)
            }

            let warningMessage = isGlucoseVeryLow ? String(localized: "Glucose is very low.") :
                isForecastVeryLow ? String(localized: "Glucose forecast is very low.") :
                ""

            let warningColor: Color = isGlucoseVeryLow ? .red : colorScheme == .dark ? .orange : .accentColor

            let shouldConfirm = state.confirmBolus && (isGlucoseVeryLow || isForecastVeryLow)

            return (shouldConfirm, warningMessage, warningColor)
        }

        var treatmentButton: some View {
            let shouldDisplayBolusProgress = bolusInProgressForEntry

            var treatmentButtonBackground = sweetMirandaSkin ? SweetMirandaPalette.pink : Color(.systemBlue)
            if limitExceeded {
                treatmentButtonBackground = Color(.systemRed)
            } else if disableTaskButton {
                treatmentButtonBackground = Color(.systemGray)
            }

            return Section {
                if shouldDisplayBolusProgress {
                    bolusInProgressView
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } else if sweetMirandaSkin {
                    // Just two buttons (Wilson 2026-09-29). Save carbs only shows when there
                    // are carbs; the bolus is a 2-second hold — or a "too low" block under 60.
                    if state.carbs > 0 {
                        smSaveCarbsButton
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
                    }
                    if smBelow60 {
                        smTooLowRow
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                    } else if state.amount > 0, !limitExceeded, !state.externalInsulin, state.fat == 0, state.protein == 0 {
                        smBolusHoldButton
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                    }
                } else {
                    Button {
                        if bolusWarning.shouldConfirm {
                            smBolusSkipAuth = false
                            showConfirmDialogForBolusing = true
                        } else {
                            state.invokeTreatmentsTask()
                        }
                    } label: {
                        HStack {
                            sweetMirandaButtonLabel
                        }
                        .font(sweetMirandaSkin ? .system(size: 19, weight: .heavy, design: .rounded) : .headline)
                        .foregroundStyle(
                            sweetMirandaSkin && !limitExceeded && !disableTaskButton ? SweetMirandaPalette.ink : Color.white
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 35)
                    }
                    .disabled(disableTaskButton)
                    .listRowBackground(treatmentButtonBackground)
                    .shadow(radius: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } header: {
                if !bolusWarning.warningMessage.isEmpty {
                    Text(bolusWarning.warningMessage)
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundColor(bolusWarning.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, -22)
                }
            }
            .glassActionSheet(
                Text(bolusWarning.warningMessage + " Bolus \(state.amount.description) U?"),
                isPresented: $showConfirmDialogForBolusing,
                actions: [
                    GlassSheetAction(
                        verbatim: bolusWarning.warningMessage
                            .isEmpty ? String(localized: "Enact Bolus") :
                            String(localized: "Ignore Warning and Enact Bolus"),
                        role: bolusWarning.warningMessage.isEmpty ? nil : .destructive
                    ) {
                        // Sweet Miranda: when the confirm sheet was reached from her
                        // 2-second hold, the hold already stood in for Face ID.
                        state.invokeTreatmentsTask(skipAuth: smBolusSkipAuth)
                    }
                ]
            )
        }

        /// Sweet Miranda: never let her bolus when her glucose is under 60 (Wilson 2026-09-29).
        /// currentBG of 0 means "no reading" — that's handled by Trio's stale-glucose path, not here.
        private var smBelow60: Bool { state.currentBG > 0 && state.currentBG < 60 }

        /// Read-only line on her screen showing what Trio suggests (no editable amount field).
        @ViewBuilder private var smSuggestionRow: some View {
            HStack(spacing: 8) {
                Image(systemName: "drop.fill").foregroundStyle(SweetMirandaPalette.mint)
                if state.amount > 0 {
                    Text("Bolus \(state.amount.description) U")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Text("Trio's suggestion").font(.caption).foregroundStyle(SweetMirandaPalette.muted)
                } else {
                    Text(state.carbs > 0 ? "No insulin needed for this" : "Enter carbs above")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SweetMirandaPalette.muted)
                    Spacer()
                }
            }
        }

        /// Her first button: SAVE CARBS (a plain tap) — logs carbs with no insulin.
        private var smSaveCarbsButton: some View {
            Button { state.saveCarbsOnly() } label: {
                Text("SAVE CARBS \(state.carbs.description) g")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(SweetMirandaPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 44)
                    .background(SweetMirandaPalette.amber, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save \(state.carbs.description) grams of carbs, no insulin")
        }

        /// Shown instead of the bolus button when she's under 60 — bolus is blocked.
        private var smTooLowRow: some View {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                Text("Too low to bolus — glucose \(state.currentBG.description)")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(minHeight: 44)
            .padding(.horizontal, 8)
            .background(SweetMirandaPalette.red, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Too low to bolus, glucose \(state.currentBG.description)")
        }

        /// The pink BOLUS bar she holds for two seconds. The fill tracks the hold; on
        /// completion it enacts the bolus with no Face ID (the hold is the
        /// confirmation), except that a very-low glucose still raises the extra
        /// "are you sure?" sheet afterward.
        private var smBolusHoldButton: some View {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(SweetMirandaPalette.pink)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.38))
                        .frame(width: geo.size.width * bolusHoldProgress)
                }
                Text(bolusHolding ? "Keep holding…" : "HOLD 2 SEC · BOLUS \(state.amount.description) U")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(SweetMirandaPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 3)
            .onLongPressGesture(minimumDuration: 2, maximumDistance: 40) {
                bolusHolding = false
                withAnimation(.easeOut(duration: 0.2)) { bolusHoldProgress = 0 }
                // Safety: if she dropped under 60 during the hold, don't bolus.
                guard !smBelow60 else {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    return
                }
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                if bolusWarning.shouldConfirm {
                    smBolusSkipAuth = true
                    showConfirmDialogForBolusing = true
                } else {
                    state.invokeTreatmentsTask(skipAuth: true)
                }
            } onPressingChanged: { pressing in
                bolusHolding = pressing
                withAnimation(pressing ? .linear(duration: 2) : .easeOut(duration: 0.2)) {
                    bolusHoldProgress = pressing ? 1 : 0
                }
            }
            .accessibilityLabel("Hold two seconds to give \(state.amount.description) units of insulin")
        }

        /// Card-style in-progress visualizer matching Home's `bolusView` look:
        /// insulin-tinted background, cross.vial.fill icon, "Bolusing" + "X of Y U" text,
        /// xmark.app cancel, gradient progress bar overlaid at the bottom.
        @ViewBuilder private var bolusInProgressView: some View {
            let progress = state.bolusProgress ?? 0
            let bolusTotal = state.lastPumpBolus?.bolus?.amount as Decimal?
            let bolusFraction = (bolusTotal ?? 0) * progress
            let bolusString: String = {
                guard let bolusTotal = bolusTotal else { return String(localized: "Bolus In Progress...") }
                return (bolusProgressFormatter.string(from: bolusFraction as NSNumber) ?? "0")
                    + String(localized: " of ", comment: "Bolus string partial message: 'x U of y U' in home view")
                    + (Formatter.decimalFormatterWithThreeFractionDigits.string(from: bolusTotal as NSNumber) ?? "0")
                    + String(localized: " U", comment: "Insulin unit")
            }()
            let bolusLabel = state.bolusStatus == .inProgress ? String(localized: "Bolusing") : String(localized: "Initiating…")

            ZStack {
                // background card
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        colorScheme == .dark
                            ? Color(red: 0.03921568627, green: 0.133333333, blue: 0.2156862745)
                            : Color.insulin.opacity(0.2)
                    )
                    .frame(height: 56)
                    .shadow(
                        color: colorScheme == .dark
                            ? Color(red: 0.02745098039, green: 0.1098039216, blue: 0.1411764706)
                            : Color.black.opacity(0.33),
                        radius: 3
                    )

                // bolus content
                HStack {
                    Image(systemName: "cross.vial.fill")
                        .font(.system(size: 25))

                    Spacer()

                    VStack {
                        Text(bolusLabel)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(bolusString)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 5)

                    Spacer()

                    if state.bolusStatus == .inProgress {
                        if sweetMirandaSkin {
                            // Big, obvious STOP so she can cancel a bolus she started by mistake.
                            Button { state.cancelBolus() } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("STOP").font(.system(size: 16, weight: .heavy, design: .rounded))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(height: 40)
                                .background(SweetMirandaPalette.red, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Stop this bolus")
                        } else {
                            Button { state.cancelBolus() } label: {
                                Image(systemName: "xmark.app")
                                    .font(.system(size: 25))
                            }.tint(Color.tabBar)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Cancel bolus")
                        }
                    } else if state.bolusStatus == .initiating {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.trailing, 8)
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                BolusProgressBar(progress: progress)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
        }

        /// Sweet Miranda: a short label that always says what will happen — "BOLUS 9 U" names the
        /// amount on the button she presses; with no insulin it saves carbs and says so. Limits,
        /// external insulin and fat/protein keep Trio's own wording.
        @ViewBuilder private var sweetMirandaButtonLabel: some View {
            let plain = sweetMirandaSkin && !limitExceeded && !state.externalInsulin && state.fat == 0 && state.protein == 0
            if plain, state.amount > 0 {
                Text("BOLUS \(state.amount.description) U")
            } else if plain, state.amount == 0, state.carbs > 0 {
                Text("SAVE CARBS")
            } else {
                taskButtonLabel
            }
        }

        private var taskButtonLabel: some View {
            if pumpBolusLimitExceeded {
                return Text("Max Bolus of \(state.maxBolus.description) U Exceeded")
            } else if externalBolusLimitExceeded {
                return Text("Max External Bolus of \(state.maxExternal.description) U Exceeded")
            } else if carbLimitExceeded {
                return Text("Max Carbs of \(state.maxCarbs.description) g Exceeded")
            } else if fatLimitExceeded {
                return Text("Max Fat of \(state.maxFat.description) g Exceeded")
            } else if proteinLimitExceeded {
                return Text("Max Protein of \(state.maxProtein.description) g Exceeded")
            }

            let hasInsulin = state.amount > 0
            let hasCarbs = state.carbs > 0
            let hasFatOrProtein = state.fat > 0 || state.protein > 0
            let bolusString = state.externalInsulin ? String(localized: "External Insulin") : String(localized: "Enact Bolus")

            // Note: when a pump bolus is in progress, the row is rendered by `bolusInProgressView`
            // (Home-style card), so this label's in-progress branch is intentionally absent.

            switch (hasInsulin, hasCarbs, hasFatOrProtein) {
            case (true, true, true):
                return Text("Log Meal and \(bolusString)")
            case (true, true, false):
                return Text("Log Carbs and \(bolusString)")
            case (true, false, true):
                return Text("Log FPU and \(bolusString)")
            case (true, false, false):
                return Text(state.externalInsulin ? String(localized: "Log External Insulin") : String(localized: "Enact Bolus"))
            case (false, true, true):
                return Text("Log Meal")
            case (false, true, false):
                return Text("Log Carbs")
            case (false, false, true):
                return Text("Log FPU")
            default:
                return Text("Continue Without Treatment")
            }
        }

        private var pumpBolusLimitExceeded: Bool {
            !state.externalInsulin && state.amount > state.maxBolus
        }

        private var externalBolusLimitExceeded: Bool {
            state.externalInsulin && state.amount > state.maxExternal
        }

        private var carbLimitExceeded: Bool {
            state.carbs > state.maxCarbs
        }

        private var fatLimitExceeded: Bool {
            state.fat > state.maxFat
        }

        private var proteinLimitExceeded: Bool {
            state.protein > state.maxProtein
        }

        private var limitExceeded: Bool {
            pumpBolusLimitExceeded || externalBolusLimitExceeded || carbLimitExceeded || fatLimitExceeded || proteinLimitExceeded
        }

        private var bolusInProgressForEntry: Bool {
            // .initiating covers pumps that take a few seconds before reporting progress
            (state.bolusProgress != nil || state.bolusStatus == .initiating) &&
                state.amount > 0 && !state.externalInsulin
        }

        private var disableTaskButton: Bool {
            bolusInProgressForEntry || state.addButtonPressed || limitExceeded
        }
    }

    struct DividerDouble: View {
        var body: some View {
            VStack(spacing: 2) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
            }
            .frame(height: 4)
            .padding(.vertical)
        }
    }

    struct DividerCustom: View {
        var body: some View {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.65))
                .padding(.vertical)
        }
    }
}
