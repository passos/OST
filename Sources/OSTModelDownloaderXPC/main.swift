import Foundation
import OSTCore
import OSTDownloader

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service: ModelDownloaderService

    init(service: ModelDownloaderService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ModelDownloaderXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

do {
    guard let containerURL = ModelStoreLayout.containerURL() else {
        throw ModelInstallerError.appGroupUnavailable
    }
    let service = ModelDownloaderService(
        catalog: try ModelCatalog.bundled(),
        containerURL: containerURL
    )
    let delegate = ServiceDelegate(service: service)
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    listener.resume()
    dispatchMain()
} catch {
    exit(EXIT_FAILURE)
}
