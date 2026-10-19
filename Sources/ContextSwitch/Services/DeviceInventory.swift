import AppKit
import CoreGraphics
import IOKit

enum DeviceInventory {
    /// The IOKit class of every USB device, whatever port or hub it's on.
    static let usbDeviceClass = "IOUSBHostDevice"

    /// Plugged-in USB devices. Hubs are left out: they have generic names
    /// ("USB3.1 Hub") and it's the devices on them that tell places apart.
    static func usbDevices() -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(usbDeviceClass), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [String: USBDevice] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property<T>(_ key: String) -> T? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
            }
            guard let vendorID: Int = property("idVendor"), let productID: Int = property("idProduct"),
                  property("bDeviceClass") as Int? != 9  // hub
            else { continue }
            let device = USBDevice(
                name: nonEmpty(property("USB Product Name")) ?? String(format: "USB Device %04x:%04x", vendorID, productID),
                manufacturer: nonEmpty(property("USB Vendor Name")),
                vendorID: vendorID,
                productID: productID,
                serialNumber: nonEmpty(property("USB Serial Number"))
            )
            devices[device.id] = device
        }
        return devices.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Connected external displays. Main thread only: names come from
    /// NSScreen.
    @MainActor
    static func displays() -> [ConnectedDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        var displays: [String: ConnectedDisplay] = [:]
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) == 0 {
            let serial = CGDisplaySerialNumber(id)
            let display = ConnectedDisplay(
                // Only the second display of a mirrored pair has no NSScreen.
                name: names[id] ?? "External Display",
                vendorID: Int(CGDisplayVendorNumber(id)),
                modelID: Int(CGDisplayModelNumber(id)),
                serialNumber: serial == 0 ? nil : Int(serial)
            )
            displays[display.id] = display
        }
        return displays.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
