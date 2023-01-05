import SwiftUI
import FoodLabelCamera
import FoodLabelScanner
import SwiftHaptics
import ZoomableScrollView
import SwiftSugar
import Shimmer
import VisionSugar

@MainActor
class LabelScannerViewModel: ObservableObject {

    let isCamera: Bool
    let imageHandler: (UIImage, ScanResult) -> ()
    let scanResultHandler: (ScanResult) -> ()
    let dismissHandler: () -> ()
    var shimmeringStart: Double = 0
    
    @Published var hideCamera = false
    @Published var textBoxes: [TextBox] = []
    @Published var shimmering = false
    @Published var showingBoxes = false
    @Published var scanResult: ScanResult? = nil
    @Published var showingBlackBackground = false
    @Published var image: UIImage? = nil
    @Published var images: [(UIImage, CGRect, UUID, Angle)] = []
    @Published var showingCroppedImages = false
    @Published var stackedOnTop: Bool = false
    @Published var scannedTextBoxes: [TextBox] = []
    @Published var animatingCollapseOfCutouts = false
    @Published var animatingCollapseOfCroppedImages = false
    @Published var columns: ScannedColumns = ScannedColumns()
    @Published var showingColumnPicker = false
    @Published var selectedImageTexts: [ImageText] = []
    @Published var zoomBox: ZoomBox? = nil
    @Published var shimmeringImage = false

    @Published var animatingCollapse: Bool
    @Published var clearSelectedImage: Bool = false
    
    init(
        isCamera: Bool,
        animatingCollapse: Bool,
        imageHandler: @escaping (UIImage, ScanResult) -> (),
        scanResultHandler: @escaping (ScanResult) -> (),
        dismissHandler: @escaping () -> ()
    ) {
        self.animatingCollapse = animatingCollapse
        self.isCamera = isCamera
        self.imageHandler = imageHandler
        self.scanResultHandler = scanResultHandler
        self.dismissHandler = dismissHandler
        
        self.hideCamera = !isCamera
//        self.showingBlackBackground = !isCamera
        self.showingBlackBackground = true
    }
    
    func begin(_ image: UIImage) {
        self.startScan(image)
    }
    
    func startScan(_ image: UIImage) {

        Task.detached {
            let zoomBox = await self.getZoomBox(for: image)
            
            Haptics.selectionFeedback()
            
            try await sleepTask(0.03, tolerance: 0.005)
            //        try await sleepTask(1.0, tolerance: 0.005)
            
            /// Zoom to ensure that the `ImageViewer` matches the camera preview layer
            let userInfo = [Notification.ZoomableScrollViewKeys.zoomBox: zoomBox]
            await MainActor.run {
                NotificationCenter.default.post(name: .zoomZoomableScrollView, object: nil, userInfo: userInfo)
            }
            
            if self.isCamera {
                await MainActor.run {
                    withAnimation {
                        self.hideCamera = true
                    }
                }
            } else {
                /// Ensure the sliding up animation is complete first
                try await sleepTask(0.2, tolerance: 0.005)
            }
            
            /// Now capture recognized texts
            /// - captures all the RecognizedTexts
            let textSet = try await image.recognizedTextSet(for: .accurate, includeBarcodes: true)
            let textBoxes = textSet.texts.map {
                TextBox(
                    id: $0.id,
                    boundingBox: $0.boundingBox,
                    color: .accentColor,
                    opacity: 0.8,
                    tapHandler: {}
                )
            }
            
            Haptics.selectionFeedback()
            
            /// **VisionKit Scan Completed**: Show all `RecognizedText`'s
            await MainActor.run {
                self.shimmeringStart = CFAbsoluteTimeGetCurrent()
                withAnimation {
                    self.shimmeringImage = false
                    self.textBoxes = textBoxes
                    self.showingBoxes = true
                    print("🟢 DONE")
                }
            }
            
            try await sleepTask(0.2, tolerance: 0.005)
            await MainActor.run {
                self.shimmering = true
            }

            try await sleepTask(1, tolerance: 0.005)
            
            try await self.scan(textSet: textSet)
        }
    }
    
    func scan(textSet: RecognizedTextSet) async throws {
        
        Task.detached {
            let scanResult = textSet.scanResult

            await MainActor.run {
                self.scanResult = scanResult
                self.showingBlackBackground = false
            }
            
            guard scanResult.columnCount != 2 else {
                try await self.showColumnPicker()
                return
            }

            /// Make sure the shimmering effect goes on for at least 2 seconds so user gets a feel of the image being processed
            //        let minimumShimmeringTime: Double = 1
            //        let timeSinceShimmeringStart = CFAbsoluteTimeGetCurrent()-shimmeringStart
            //        if timeSinceShimmeringStart < minimumShimmeringTime {
            //            try await sleepTask(minimumShimmeringTime - timeSinceShimmeringStart, tolerance: 0.005)
            //        }
            
            try await self.cropImages()
        }
    }
    
    func cropImages() async throws {
        guard let scanResult, let image else { return }
        
        Task.detached {
            let resultBoxes = scanResult.textBoxes
            
            for box in resultBoxes {
                guard let cropped = await image.cropped(boundingBox: box.boundingBox) else {
                    print("Couldn't get image for box: \(box)")
                    continue
                }
                
                let screen = await UIScreen.main.bounds
                
                let correctedRect: CGRect
                if self.isCamera {
                    let scaledWidth: CGFloat = (image.size.width * screen.height) / image.size.height
                    let scaledSize = CGSize(width: scaledWidth, height: screen.height)
                    let rectForSize = box.boundingBox.rectForSize(scaledSize)
                    
                    correctedRect = CGRect(
                        x: rectForSize.origin.x - ((scaledWidth - screen.width) / 2.0),
                        y: rectForSize.origin.y,
                        width: rectForSize.size.width,
                        height: rectForSize.size.height
                    )
                    
                    print("🌱 box.boundingBox: \(box.boundingBox)")
                    print("🌱 scaledSize: \(scaledSize)")
                    print("🌱 rectForSize: \(rectForSize)")
                    print("🌱 correctedRect: \(correctedRect)")
                    print("🌱 image.boundingBoxForScreenFill: \(image.boundingBoxForScreenFill)")
                    
                    
                } else {
                    
                    let rectForSize: CGRect
                    let x: CGFloat
                    let y: CGFloat
                    
                    if image.size.widthToHeightRatio > screen.size.widthToHeightRatio {
                        /// This means we have empty strips at the top, and image gets width set to screen width
                        let scaledHeight = (image.size.height * screen.width) / image.size.width
                        let scaledSize = CGSize(width: screen.width, height: scaledHeight)
                        rectForSize = box.boundingBox.rectForSize(scaledSize)
                        x = rectForSize.origin.x
                        y = rectForSize.origin.y + ((screen.height - scaledHeight) / 2.0)
                        
                        print("🌱 scaledSize: \(scaledSize)")
                    } else {
                        let scaledWidth = (image.size.width * screen.height) / image.size.height
                        let scaledSize = CGSize(width: scaledWidth, height: screen.height)
                        rectForSize = box.boundingBox.rectForSize(scaledSize)
                        x = rectForSize.origin.x + ((screen.width - scaledWidth) / 2.0)
                        y = rectForSize.origin.y
                    }
                    
                    correctedRect = CGRect(
                        x: x,
                        y: y,
                        width: rectForSize.size.width,
                        height: rectForSize.size.height
                    )
                    
                    print("🌱 rectForSize: \(rectForSize)")
                    print("🌱 correctedRect: \(correctedRect), screenHeight: \(screen.height)")
                    
                }
                
                await MainActor.run {
                    
                    if !self.images.contains(where: { $0.2 == box.id }) {
                        self.images.append((
                            cropped,
                            correctedRect,
                            box.id,
                            Angle.degrees(CGFloat.random(in: -20...20)))
                        )
                    }
                }
            }
            
            Haptics.selectionFeedback()
            
            await MainActor.run {
                withAnimation {
                    self.showingCroppedImages = true
                    self.textBoxes = []
                    self.scannedTextBoxes = scanResult.textBoxes
                }
            }
            
            try await sleepTask(0.5, tolerance: 0.01)
            
            let Bounce: Animation = .interactiveSpring(response: 0.35, dampingFraction: 0.66, blendDuration: 0.35)
            
            await MainActor.run {
                Haptics.feedback(style: .soft)
                withAnimation(Bounce) {
                    self.stackedOnTop = true
                }
            }
            
            try await sleepTask(0.5, tolerance: 0.01)
            
            try await self.collapse()
        }
    }
    
    @MainActor
    func collapse() async throws {
        withAnimation {
            self.animatingCollapse = true
            self.animatingCollapseOfCutouts = true
            imageHandler(image!, scanResult!)
        }
        
        try await sleepTask(0.5, tolerance: 0.01)
        
        withAnimation {
            self.animatingCollapseOfCroppedImages = true
        }

        try await sleepTask(0.2, tolerance: 0.01)

        withAnimation {
            //TODO: Handle this in LabelScanner with a local variable an an onChange modifier since it's a binding
            self.clearSelectedImage = true
            scanResultHandler(scanResult!)
        }
    }
    
    func getZoomBox(for image: UIImage) -> ZoomBox {
        let boundingBox = isCamera
        ? image.boundingBoxForScreenFill
        : CGRect(x: 0, y: 0, width: 1, height: 1)
        
        //TODO: Why isn't this screen bounds for camera as well?
        let imageSize = isCamera ? image.size : UIScreen.main.bounds.size

        /// Having `padded` as true for picked images is crucial to make sure we don't get the bug
        /// where the initial zoom causes the image to scroll way off screen (and hence disappear)
        let padded = !isCamera
        
        return ZoomBox(
            boundingBox: boundingBox,
            animated: false,
            padded: padded,
            imageSize: imageSize
        )
    }
    
}