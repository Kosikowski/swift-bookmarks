#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
public import UIKit
public import UniformTypeIdentifiers

/// Presents `UIDocumentPickerViewController` and returns what the user picked as grants.
///
/// The picker starts in the configuration's ``PickerConfiguration/directoryURL`` and offers
/// its content types. UIKit's picker has no message, button title, hidden-file or new-folder
/// setting, so those parts of the configuration apply to the Mac's open panel only.
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
            let delegate = PickerDelegate(result: PickerContinuation(continuation))
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &PickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            presenter.present(picker, animated: true)
        }
        return GrantMapping.grants(from: urls, origin: .documentPicker)
    }
}

extension BookmarkStore {
    /// Asks the user to pick the item for `key` again with the document picker, starting in
    /// the folder that held it, and replaces its bookmark: the counterpart on iOS, visionOS and
    /// Mac Catalyst of ``regrantWithOpenPanel(_:message:prompt:attachedTo:)`` on the Mac.
    ///
    /// The picker offers folders when the item was a folder, and files of `fileTypes`
    /// otherwise. It shows no message; explain why the item is needed before presenting it.
    ///
    /// - Returns: The updated record, or `nil` when the user cancelled.
    @MainActor
    public func regrantWithDocumentPicker(
        _ key: Key,
        from presenter: UIViewController,
        fileTypes: [UTType] = [.item]
    ) async throws(Failure) -> Record? {
        let configuration = try await regrantConfiguration(for: key, fileTypes: fileTypes)
        return try await regrant(key, withFirstOf: await DocumentPicker.choose(configuration, from: presenter))
    }
}

@MainActor
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    static var key: UInt8 = 0

    private let result: PickerContinuation

    init(result: PickerContinuation) {
        self.result = result
    }

    deinit {
        result.resume(returning: [])
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        result.resume(returning: urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        result.resume(returning: [])
    }
}
#endif
