#if canImport(SwiftUI)
import Observation
public import SwiftUI
public import UniformTypeIdentifiers

extension View {
    /// Presents a file importer and hands the picked items over as grants.
    ///
    /// SwiftUI doesn't start access for importer URLs on any platform; adopting the grants
    /// starts it around bookmark creation.
    ///
    /// The importer offers the configuration's content types and starts in its
    /// ``PickerConfiguration/directoryURL`` on every platform. On macOS it also shows its
    /// ``PickerConfiguration/message``, uses its ``PickerConfiguration/prompt`` as the
    /// confirmation button's title and shows hidden files when
    /// ``PickerConfiguration/showsHiddenFiles`` is set. The document browser on iOS, iPadOS,
    /// visionOS and Mac Catalyst has no message, button title or hidden files to set, and
    /// SwiftUI's importer can't create folders anywhere; ``OpenPanelPicker`` can.
    ///
    /// - Parameter onCancel: Called when the user dismisses the importer without picking.
    public func bookmarkImporter(
        isPresented: Binding<Bool>,
        configuration: PickerConfiguration,
        onGrants: @escaping ([Grant]) -> Void,
        onFailure: @escaping (any Error) -> Void = { _ in },
        onCancel: @escaping () -> Void = {}
    ) -> some View {
        let dialog = FileDialogOptions(configuration)
        let handlers = ImporterHandlers(onGrants: onGrants, onFailure: onFailure)
        return fileImporter(
            isPresented: isPresented,
            allowedContentTypes: configuration.pickerContentTypes,
            allowsMultipleSelection: configuration.allowsMultipleSelection,
            onCompletion: handlers.complete,
            onCancellation: onCancel
        )
        .fileDialogDefaultDirectory(dialog.defaultDirectory)
        .fileDialogMessage(dialog.message.map { Text(verbatim: $0) })
        .fileDialogConfirmationLabel(dialog.confirmationLabel.map { Text(verbatim: $0) })
        .fileDialogBrowserOptions(dialog.browserOptions)
    }

    /// Asks the user to pick the item stored under a key again with a file importer, and
    /// replaces its bookmark: the SwiftUI counterpart of
    /// ``BookmarkStore/regrantWithOpenPanel(_:message:prompt:attachedTo:)`` and
    /// ``BookmarkStore/regrantWithDocumentPicker(_:from:fileTypes:)``, on every platform.
    ///
    /// Setting `key` presents the importer, configured by
    /// ``BookmarkStore/regrantConfiguration(for:message:prompt:fileTypes:)`` to start in the
    /// folder that held the item. `key` becomes `nil` again when the re-grant ends, and
    /// `onCompletion` gets the updated record, `nil` when the user cancelled, or the error.
    ///
    /// ```swift
    /// .bookmarkRegrant(of: $regranting, in: store, message: "Find “\(name)”") { result in
    ///     if case .failure(let error) = result { show(error) }
    /// }
    /// ```
    ///
    /// `message` and `prompt` show on macOS only; see
    /// ``bookmarkImporter(isPresented:configuration:onGrants:onFailure:onCancel:)``.
    public func bookmarkRegrant<Key, Metadata>(
        of key: Binding<Key?>,
        in store: BookmarkStore<Key, Metadata>,
        message: String? = nil,
        prompt: String? = nil,
        fileTypes: [UTType] = [.item],
        onCompletion: @escaping (Result<BookmarkRecord<Key, Metadata>?, BookmarkStoreError<Key>>) -> Void = { _ in }
    ) -> some View {
        modifier(RegrantImporter(
            key: key,
            store: store,
            request: RegrantRequestOptions(message: message, prompt: prompt, fileTypes: fileTypes),
            onCompletion: onCompletion
        ))
    }

    /// Accepts dropped files and folders and hands them over as grants.
    ///
    /// Adopt every grant you keep and pass the rest to `BookmarkService.relinquish(_:)`.
    /// `isTargeted` reports when a drag enters and leaves the view, for highlighting it.
    public func bookmarkDropDestination(
        onDrop: @escaping ([Grant]) -> Bool,
        isTargeted: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            onDrop(GrantMapping.grants(from: urls, origin: .swiftUIDrop))
        } isTargeted: { targeted in
            isTargeted(targeted)
        }
    }
}

/// Hands an importer's result over as grants or an error.
struct ImporterHandlers {
    let onGrants: ([Grant]) -> Void
    let onFailure: (any Error) -> Void

    func complete(_ result: Result<[URL], any Error>) {
        switch GrantMapping.grants(from: result) {
        case .success(let grants):
            onGrants(grants)
        case .failure(let error):
            onFailure(error)
        }
    }
}

/// How a SwiftUI file dialog presents a picker configuration.
struct FileDialogOptions: Equatable {
    var defaultDirectory: URL?
    var message: String?
    var confirmationLabel: String?
    var showsHiddenFiles: Bool

    init(_ configuration: PickerConfiguration) {
        defaultDirectory = configuration.directoryURL
        message = configuration.message
        confirmationLabel = configuration.prompt
        showsHiddenFiles = configuration.showsHiddenFiles
    }

    var browserOptions: FileDialogBrowserOptions {
        showsHiddenFiles ? [.includeHiddenFiles] : []
    }
}

struct RegrantRequestOptions: Equatable {
    var message: String?
    var prompt: String?
    var fileTypes: [UTType]
}

/// One re-grant through a SwiftUI importer: preparing the configuration, then finishing with
/// what the user picked, cancelled or what failed. The importer's callbacks only hand over.
@MainActor
@Observable
final class RegrantSession<Key: Hashable & Sendable, Metadata: Sendable & Equatable> {
    typealias Outcome = Result<BookmarkRecord<Key, Metadata>?, BookmarkStoreError<Key>>

    /// The key being re-granted and the importer's configuration, while it's presented.
    private(set) var presented: (key: Key, configuration: PickerConfiguration)?

    var isPresenting: Bool {
        get { presented != nil }
        set { if !newValue { presented = nil } }
    }

    /// Prepares the importer when `key` is set, or fails when there's no record for it.
    func begin(_ key: Key?, in store: BookmarkStore<Key, Metadata>, options: RegrantRequestOptions) async -> Outcome? {
        guard let key else { return nil }
        return await prepare(key, in: store, options: options)
    }

    /// Prepares the importer for `key`, or fails when there's no record for it.
    func prepare(_ key: Key, in store: BookmarkStore<Key, Metadata>, options: RegrantRequestOptions) async -> Outcome? {
        do {
            let configuration = try await store.regrantConfiguration(for: key, message: options.message, prompt: options.prompt, fileTypes: options.fileTypes)
            presented = (key, configuration)
            return nil
        } catch {
            presented = nil
            return .failure(error)
        }
    }

    /// Re-grants `key` with what the user picked.
    func finish(_ key: Key, with grants: [Grant], in store: BookmarkStore<Key, Metadata>) async -> Outcome {
        presented = nil
        do {
            return .success(try await store.regrant(key, withFirstOf: grants))
        } catch {
            return .failure(error)
        }
    }

    /// Re-grants the presented key, or `fallback` when the importer already dismissed, with
    /// what the user picked. Without either, the grants are relinquished and there's nothing
    /// to report.
    func picked(_ grants: [Grant], fallback: Key?, in store: BookmarkStore<Key, Metadata>) async -> Outcome? {
        guard let key = presented?.key ?? fallback else {
            store.service.relinquish(grants)
            return nil
        }
        return await finish(key, with: grants, in: store)
    }

    /// Ends the re-grant because the user cancelled, or because the importer failed.
    func end(failing error: (any Error)? = nil) -> Outcome {
        presented = nil
        guard let error else { return .success(nil) }
        let nsError = error as NSError
        return .failure(.bookmark(BookmarkError(.other(domain: nsError.domain, code: nsError.code), underlying: error)))
    }
}

private struct RegrantImporter<Key: Hashable & Sendable, Metadata: Sendable & Equatable>: ViewModifier {
    @Binding var key: Key?
    let store: BookmarkStore<Key, Metadata>
    let request: RegrantRequestOptions
    let onCompletion: (RegrantSession<Key, Metadata>.Outcome) -> Void
    @State private var session = RegrantSession<Key, Metadata>()

    func body(content: Content) -> some View {
        content
            .task(id: key) {
                complete(await session.begin(key, in: store, options: request))
            }
            .bookmarkImporter(
                isPresented: $session.isPresenting,
                configuration: session.presented?.configuration ?? PickerConfiguration(),
                onGrants: { grants in
                    Task { complete(await session.picked(grants, fallback: key, in: store)) }
                },
                onFailure: { complete(session.end(failing: $0)) },
                onCancel: { complete(session.end()) }
            )
    }

    private func complete(_ outcome: RegrantSession<Key, Metadata>.Outcome?) {
        guard let outcome else { return }
        key = nil
        onCompletion(outcome)
    }
}
#endif
