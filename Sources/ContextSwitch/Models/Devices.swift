import Foundation

/// A USB device that's plugged in — directly, or through a hub or dock.
struct USBDevice: Hashable, Identifiable {
    var name: String
    var manufacturer: String?
    var vendorID: Int
    var productID: Int
    /// nil if the device doesn't report one. Not every serial number is
    /// unique: some makers give all units the same one (e.g. "000000001").
    var serialNumber: String?

    var id: String { "\(vendorID):\(productID):\(serialNumber ?? "")" }
}

/// A connected external display. The built-in one is left out.
struct ConnectedDisplay: Hashable, Identifiable {
    var name: String
    var vendorID: Int
    var modelID: Int
    /// From the display's EDID; nil when it doesn't report one.
    var serialNumber: Int?

    var id: String { "\(vendorID):\(modelID):\(serialNumber.map(String.init) ?? "")" }
}
