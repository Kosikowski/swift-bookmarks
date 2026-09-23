#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
public import UIKit

/// Presents `UIDocumentPickerViewController` and returns what the user picked as grants.
@MainActor
public enum DocumentPicker {
    /// Presents a document picker from `presenter` and returns the picked items, or an empty
    /// array when cancelled.
    ///
    /// The returned grants don't have access started; adopting them starts it around bookmark
    /// creation.
    public static func choose(_ configuration: PickerConfiguration, from presenter: UIViewController) async -> [Grant] {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: configuration.pickerContentTypes, asCopy: false)
        picker.allowsMultipleSelection = configuration.allowsMultipleSelection
        picker.directoryURL = configuration.directoryURL
        let urls = await withCheckedContinuation { continuation in
            let delegate = PickerDelegate(continuation: continuation)
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &PickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
        return GrantMapping.grants(from: urls, origin: .documentPicker)
    }
}

@MainActor
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    static var key: UInt8 = 0

    private var continuation: CheckedContinuation<[URL], Never>?

    init(continuation: CheckedContinuation<[URL], Never>) {
        self.continuation = continuation
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        continuation?.resume(returning: urls)
        continuation = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        continuation?.resume(returning: [])
        continuation = nil
    }
}
#endif
