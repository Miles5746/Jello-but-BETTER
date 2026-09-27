import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A full-screen effect applied to each captured frame before it is drawn in the overlay.
enum Effect: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case invert = "Invert"
    case grayscale = "Grayscale"
    case sepia = "Sepia"
    case hueCycle = "Hue Cycle"
    case pixellate = "Pixellate"
    case scanlines = "CRT Scanlines"

    var id: Self { self }

    /// - Parameter time: Seconds since the overlay started, for animated effects.
    func apply(to image: CIImage, time: TimeInterval) -> CIImage {
        let output: CIImage?
        switch self {
        case .none:
            return image
        case .invert:
            let filter = CIFilter.colorInvert()
            filter.inputImage = image
            output = filter.outputImage
        case .grayscale:
            let filter = CIFilter.photoEffectMono()
            filter.inputImage = image
            output = filter.outputImage
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = image
            filter.intensity = 0.9
            output = filter.outputImage
        case .hueCycle:
            let filter = CIFilter.hueAdjust()
            filter.inputImage = image
            filter.angle = Float(time.truncatingRemainder(dividingBy: 2 * .pi))
            output = filter.outputImage
        case .pixellate:
            let filter = CIFilter.pixellate()
            filter.inputImage = image
            filter.scale = 12
            filter.center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            output = filter.outputImage
        case .scanlines:
            // Vertical stripes rotated 90° become horizontal scanlines, laid over the frame.
            let stripes = CIFilter.stripesGenerator()
            stripes.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)
            stripes.color1 = CIColor.clear
            stripes.width = 2
            stripes.sharpness = 1
            output = stripes.outputImage?
                .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
                .composited(over: image)
        }
        return (output ?? image).cropped(to: image.extent)
    }
}

/// How far a row a full screen height from the cursor lags behind in the jello effect.
enum Jello: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case subtle = "Subtle"
    case medium = "Medium"
    case strong = "Strong"

    var id: Self { self }

    /// Delay, in seconds, a full screen height from the cursor. The cursor's row is live.
    var delay: TimeInterval {
        switch self {
        case .off: 0
        case .subtle: 0.5
        case .medium: 1
        case .strong: 2
        }
    }
}
