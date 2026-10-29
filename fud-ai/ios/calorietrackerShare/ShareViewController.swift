import UIKit
import Social
import MobileCoreServices
import UniformTypeIdentifiers
import WebKit

class ShareViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear // Keep the transition entirely seamless
        handleShare()
    }
    
    private func handleShare() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            dismissWithError()
            return
        }
        
        // Find the first attachment that conforms to image
        let imageType = UTType.image.identifier
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(imageType) }) else {
            dismissWithError()
            return
        }
        
        provider.loadItem(forTypeIdentifier: imageType, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }
            
            var imageData: Data? = nil
            
            if let url = item as? URL {
                imageData = try? Data(contentsOf: url)
            } else if let image = item as? UIImage {
                imageData = image.jpegData(compressionQuality: 0.8)
            } else if let data = item as? Data {
                imageData = data
            }
            
            guard let data = imageData else {
                DispatchQueue.main.async {
                    self.dismissWithError()
                }
                return
            }
            
            // Save to shared App Group container using ShareImportManager
            let success = ShareImportManager.saveSharedImage(data)
            if success {
                DispatchQueue.main.async {
                    self.openMainAppAndComplete()
                }
            } else {
                DispatchQueue.main.async {
                    self.dismissWithError()
                }
            }
        }
    }
    private func openMainAppAndComplete() {
        let url = URL(string: "fudai://import-share-image")!
        
        // In iOS 18, the old openURL: selector silently fails. We must use the modern 3-argument selector.
        // Furthermore, the UIApplication singleton is not in the responder chain of an extension.
        // We must fetch it dynamically via NSClassFromString to bypass the APPLICATION_EXTENSION_API_ONLY ban.
        
        if let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type {
            let sharedAppSelector = sel_registerName("sharedApplication")
            if applicationClass.responds(to: sharedAppSelector) {
                if let sharedApp = applicationClass.perform(sharedAppSelector)?.takeUnretainedValue() {
                    let openURLSelector = sel_registerName("openURL:options:completionHandler:")
                    if sharedApp.responds(to: openURLSelector) {
                        
                        // We have the shared UIApplication instance, and it responds to the modern openURL selector.
                        // Since it takes 3 arguments, we must use unsafeBitCast to call it.
                        typealias OpenURLMethod = @convention(c) (AnyObject, Selector, URL, NSDictionary, ((Bool) -> Void)?) -> Void
                        let method = sharedApp.method(for: openURLSelector)
                        let openURL = unsafeBitCast(method, to: OpenURLMethod.self)
                        
                        let options: NSDictionary = [:]
                        openURL(sharedApp, openURLSelector, url, options, nil)
                    }
                }
            }
        }
        
        // Wait 0.5s to let the app launch before completing the extension request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
    
    private func dismissWithError() {
        let alert = UIAlertController(
            title: String(localized: "Error", comment: "Title of the alert shown when a shared image can't be imported into Fud AI."),
            message: String(
                localized: "Unable to process the shared image.",
                comment: "Message of the alert shown when the image shared from another app can't be read or saved."
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK", comment: "Button that dismisses the shared image error alert."), style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "ShareError", code: 1, userInfo: nil))
        })
        present(alert, animated: true)
    }
}
