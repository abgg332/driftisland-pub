import PhotosUI
import UIKit

// The SwiftUI settings view is embedded in Preferences. Present from its
// enclosing navigation controller rather than requesting a nested SwiftUI sheet.
final class DIRecordingPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    weak var host: UIViewController?
    private var completion: ((UIImage?) -> Void)?

    func present(completion: @escaping (UIImage?) -> Void) {
        guard let host = host, host.viewIfLoaded?.window != nil else { completion(nil); return }
        var presenter: UIViewController = host.navigationController ?? host
        while let front = presenter.presentedViewController, !front.isBeingDismissed { presenter = front }
        guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { completion(nil); return }
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        self.completion = completion
        picker.delegate = self
        presenter.present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let callback = completion
        completion = nil
        picker.dismiss(animated: true)
        guard let item = results.first?.itemProvider, item.canLoadObject(ofClass: UIImage.self) else {
            if !results.isEmpty { callback?(nil) }
            return
        }
        item.loadObject(ofClass: UIImage.self) { object, _ in
            DispatchQueue.main.async { callback?(object as? UIImage) }
        }
    }
}
