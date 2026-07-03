import CoreMediaIO
import Foundation

let providerSource = OBSPhoneCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
