import Foundation
import CoreMediaIO

let providerSource = ACastCameraExtensionProviderSource()
let provider = CMIOExtensionProvider(source: providerSource, clientQueue: nil)

do {
    try provider.addDevice(providerSource.deviceSource.device)
} catch {
    NSLog("ACastCameraExtension: Failed to add device: \(error)")
}

CMIOExtensionProvider.startService(provider: provider)
NSLog("ACastCameraExtension: Service started successfully. Ready for Zoom, FaceTime, etc.")

CFRunLoopRun()
