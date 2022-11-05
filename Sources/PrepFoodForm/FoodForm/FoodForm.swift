import SwiftUI
import SwiftUISugar
import FoodLabelScanner
import PhotosUI
import MFPScraper
import PrepDataTypes
import SwiftHaptics

public struct FoodForm: View {
    
    @Environment(\.dismiss) var dismiss
    
    let didSave: (FoodFormOutput) -> ()
    
    /// ViewModels
    @ObservedObject var fields: Fields
    @ObservedObject var sources: Sources

    /// Sheets
    @State var showingEmojiPicker = false
    @State var showingCamera = false
    @State var showingFoodLabelCamera = false
    @State var showingPhotosPicker = false
    @State var showingPrefill = false
    @State var showingPrefillInfo = false
    @State var showingTextPicker = false
    @State var showingBarcodeScanner = false

    /// Menus
    @State var showingFoodLabel = false


    /// Wizard
    @State var shouldShowWizard: Bool = true
    @State var showingWizard = true
    @State var showingWizardOverlay = true
    @State var formDisabled = false

    /// Barcode
    @State var showingAddBarcodeAlert = false
    @State var barcodePayload: String = ""
    
    let didScanFoodLabel = NotificationCenter.default.publisher(for: .didScanFoodLabel)
    
    @State var initialScanResult: ScanResult?
    @State var initialScanImage: UIImage?
    
    public init(fields: FoodForm.Fields, sources: FoodForm.Sources, didSave: @escaping (FoodFormOutput) -> ()) {
        Fields.shared = fields
        Sources.shared = sources
        self.fields = fields
        self.sources = sources
        self.didSave = didSave
        _initialScanResult = State(initialValue: nil)
        _initialScanImage = State(initialValue: nil)
    }
    
    public init(fields: FoodForm.Fields, sources: FoodForm.Sources, scanResult: ScanResult, image: UIImage, didSave: @escaping (FoodFormOutput) -> ()) {
        Fields.shared = fields
        Sources.shared = sources
        self.fields = fields
        self.sources = sources
        self.didSave = didSave
        _shouldShowWizard = State(initialValue: false)
        _initialScanResult = State(initialValue: scanResult)
        _initialScanImage = State(initialValue: image)
    }
    
    public var body: some View {
//        let _ = Self._printChanges()
        return NavigationView {
            content
                .navigationTitle("New Food")
                .toolbar { navigationLeadingContent }
                .toolbar { navigationTrailingContent }
                .onAppear(perform: appeared)
                .onChange(of: sources.selectedPhotos, perform: sources.selectedPhotosChanged)
                .onReceive(didScanFoodLabel, perform: didScanFoodLabel)
                .sheet(isPresented: $showingEmojiPicker) { emojiPicker }
                .sheet(isPresented: $showingPrefill) { mfpSearch }
                .sheet(isPresented: $showingFoodLabelCamera) { foodLabelCamera }
                .sheet(isPresented: $showingCamera) { camera }
                .sheet(isPresented: $showingBarcodeScanner) { barcodeScanner }
                .sheet(isPresented: $showingPrefillInfo) { prefillInfo }
                .alert(addBarcodeTitle,
                       isPresented: $showingAddBarcodeAlert,
                       actions: { addBarcodeActions },
                       message: { addBarcodeMessage })
                .fullScreenCover(isPresented: $showingTextPicker) { textPicker }
                .photosPicker(
                    isPresented: $showingPhotosPicker,
                    selection: $sources.selectedPhotos,
                    maxSelectionCount: sources.availableImagesCount,
                    matching: .images
                )
                .onChange(of: sources.columnSelectionInfo) { columnSelectionInfo in
                    if columnSelectionInfo != nil {
                        self.showingTextPicker = true
                    }
                }
        }
    }

    var content: some View {
        ZStack {
            formLayer
            wizardLayer
            buttonsLayer
        }
    }
    
    //MARK: - Layers
    
    @State var showingSaveButtons = false
    
    @ViewBuilder
    var formLayer: some View {
        FormStyledScrollView {
            detailsSection
            servingSection
            foodLabelSection
            barcodesSection
            sourcesSection
            prefillSection
        }
        .safeAreaInset(edge: .bottom) { safeAreaInset }
        .overlay(overlay)
        .blur(radius: showingWizardOverlay ? 5 : 0)
        .disabled(formDisabled)
    }
    
    @ViewBuilder
    var safeAreaInset: some View {
        if fields.canBeSaved {
            //TODO: Programmatically get this inset (67516AA6)
            Spacer()
                .frame(height: sources.canBePublished ? 150 : 100)
        }
    }
    
    @ViewBuilder
    var overlay: some View {
        if showingWizardOverlay {
            Color(.quaternarySystemFill)
                .opacity(showingWizardOverlay ? 0.3 : 0)
        }
    }
    
    @ViewBuilder
    var wizardLayer: some View {
        if showingWizard {
            Wizard(tapHandler: tappedWizardButton)
        }
    }
    
    @ViewBuilder
    var buttonsLayer: some View {
        if fields.canBeSaved {
            VStack {
                Spacer()
                saveButtons
            }
            .edgesIgnoringSafeArea(.bottom)
            .transition(.move(edge: .bottom))
        }
    }

    var saveButtons: some View {
        var publicButton: some View {
            FormPrimaryButton(title: "Add to Public Database") {
                guard let data = foodFormOutput(shouldPublish: true) else {
                    return
                }
                didSave(data)
                dismiss()
            }
        }
        
        var privateButton: some View {
            FormSecondaryButton(title: "Add to Private Database") {
                guard let data = foodFormOutput(shouldPublish: false) else {
                    return
                }
                didSave(data)
                dismiss()
            }
        }
        
        return VStack(spacing: 0) {
            Divider()
            VStack {
                if sources.canBePublished {
                    publicButton
                        .padding(.top)
                    privateButton
                } else {
                    privateButton
                        .padding(.vertical)
                }
            }
            /// ** REMOVE THIS HARDCODED VALUE for the safe area bottom inset **
            .padding(.bottom, 30)
        }
        .background(.thinMaterial)
    }
    
    //MARK: - Toolbars
    
    var navigationTrailingContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if let statusMessage {
                Text(statusMessage)
                    .foregroundColor(Color(.tertiaryLabel).opacity(0.8))
                    .font(.caption)
            }
        }
    }
    
    var navigationLeadingContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button {
                dismiss()
            } label: {
                closeButtonLabel
            }
        }
    }
}

extension FoodForm {
    var statusMessage: String? {
        guard !showingWizard, !fields.isInEmptyState else {
            return nil
        }
        if let missingField = fields.missingRequiredField {
            return "Missing \(missingField)"
        } else {
            if sources.canBePublished {
                return nil
            } else {
                return "Missing source"
            }
        }
    }
    
//    var statusMessageColor: Color {
//        if fields.canBeSaved {
//            if sources.canBePublished {
//                return .green.opacity(0.4)
//            } else {
//                return .yellow.opacity(0.5)
//            }
//        } else {
//            return Color(.tertiaryLabel).opacity(0.8)
//        }
//    }
}

extension FoodForm.Fields {
    var missingRequiredField: String? {
        
        if !isInEmptyState { return nil }
        
        if name.isEmpty { return "Name" }
        if amount.value.isEmpty { return "Amount" }
        if energy.value.isEmpty { return "Energy" }
        if carb.value.isEmpty { return "Carbohydrate"}
        if fat.value.isEmpty { return "Total Fats" }
        if protein.value.isEmpty { return "Protein"}
        return nil
    }
    
    var isInEmptyState: Bool {
        detailsAreEmpty
        && serving.value.isEmpty
        && energy.value.isEmpty
        && carb.value.isEmpty
        && fat.value.isEmpty
        && protein.value.isEmpty
        && allSizes.isEmpty
        && allMicronutrientFields.isEmpty
        && prefilledFood == nil
    }
}
