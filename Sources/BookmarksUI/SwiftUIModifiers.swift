#if canImport(SwiftUI)
public import SwiftUI

extension View {
    /// Presents a file importer and hands the picked items over as grants.
    ///
    /// SwiftUI doesn't start access for importer URLs on any platform; adopting the grants
    /// starts it around bookmark creation.
    public func bookmarkImporter(
        isPresented: Binding<Bool>,
        configuration: PickerConfiguration,
        onGrants: @escaping ([Grant]) -> Void,
        onFailure: @escaping (any Error) -> Void = { _ in }
    ) -> some View {
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: configuration.pickerContentTypes,
            allowsMultipleSelection: configuration.allowsMultipleSelection
        ) { result in
            switch GrantMapping.grants(from: result) {
            case .success(let grants):
                onGrants(grants)
            case .failure(let error):
                onFailure(error)
            }
        }
    }

    /// Accepts dropped files and folders and hands them over as grants.
    ///
    /// Adopt every grant you keep and pass the rest to `BookmarkService.relinquish(_:)`.
    public func bookmarkDropDestination(onDrop: @escaping ([Grant]) -> Bool) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            onDrop(GrantMapping.grants(from: urls, origin: .swiftUIDrop))
        }
    }
}
#endif
