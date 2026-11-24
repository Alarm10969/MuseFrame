import Foundation

enum MuseFrameResources {
    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        if let resourceURL = Bundle.main.resourceURL,
           let packaged = Bundle(url: resourceURL.appendingPathComponent("MuseFrame_MuseFrame.bundle")) {
            return packaged
        }
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()
}
