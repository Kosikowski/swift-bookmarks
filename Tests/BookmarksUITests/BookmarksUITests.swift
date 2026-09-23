import Bookmarks
import BookmarksTesting
import BookmarksUI
import Foundation
import Testing
import UniformTypeIdentifiers

@Suite("PickerConfiguration")
struct PickerConfigurationTests {
    @Test func defaultsPickOneFolder() {
        let configuration = PickerConfiguration()

        #expect(configuration.allowsFolders)
        #expect(!configuration.allowsFiles)
        #expect(!configuration.allowsMultipleSelection)
        #expect(configuration.pickerContentTypes == [.folder])
        #expect(configuration == .folder())
    }

    @Test func folderPresetKeepsMessageAndLocation() {
        let start = URL(filePath: "/Users/me")

        let configuration = PickerConfiguration.folder(message: "Choose your projects folder", directoryURL: start)

        #expect(configuration.message == "Choose your projects folder")
        #expect(configuration.directoryURL == start)
    }

    @Test func filesPresetOffersOnlyTheTypes() {
        let configuration = PickerConfiguration.files([.plainText, .pdf], multiple: true)

        #expect(!configuration.allowsFolders)
        #expect(configuration.allowsFiles)
        #expect(configuration.allowsMultipleSelection)
        #expect(configuration.pickerContentTypes == [.plainText, .pdf])
    }

    @Test func foldersAndFilesTogether() {
        let configuration = PickerConfiguration(allowedContentTypes: [.image])

        #expect(configuration.pickerContentTypes == [.folder, .image])
    }
}

@Suite("RegrantConfiguration")
struct RegrantConfigurationTests {
    func record(_ path: String) -> BookmarkRecord<String, NoMetadata> {
        BookmarkRecord(key: "k", data: BookmarkData(Data()), kind: .appScoped(.readWrite), lastKnownPath: path, createdAt: Date(), metadata: NoMetadata())
    }

    @Test func startsNextToTheLastKnownLocation() {
        let configuration = RegrantConfiguration.make(for: record("/Users/me/Projects/App"), recorded: RecordedValues(isDirectory: true), message: "Find App", prompt: "Grant")

        #expect(configuration.directoryURL?.path(percentEncoded: false) == "/Users/me/Projects/")
        #expect(configuration.message == "Find App")
        #expect(configuration.prompt == "Grant")
        #expect(configuration.allowsFolders)
        #expect(!configuration.allowsFiles)
    }

    @Test func offersFilesWhenTheBookmarkRecordedAFile() {
        let configuration = RegrantConfiguration.make(for: record("/Users/me/Notes"), recorded: RecordedValues(isDirectory: false), fileTypes: [.plainText])

        #expect(!configuration.allowsFolders)
        #expect(configuration.allowedContentTypes == [.plainText])
    }

    @Test(arguments: [("/Users/me/Folder", true), ("/Users/me/Notes.md", false)])
    func guessesFromTheExtensionWithoutRecordedValues(_ path: String, _ isFolder: Bool) {
        let configuration = RegrantConfiguration.make(for: record(path), recorded: nil)

        #expect(configuration.allowsFolders == isFolder)
        #expect(configuration.allowsFiles == !isFolder)
    }
}

@Suite("GrantMapping")
struct GrantMappingTests {
    struct Failure: Error {}

    @Test func keepsFileURLsWithTheirOrigin() {
        let urls = [URL(filePath: "/a"), URL(string: "https://example.com")!, URL(filePath: "/b")]

        let grants = GrantMapping.grants(from: urls, origin: .drop)

        #expect(grants == [Grant(url: URL(filePath: "/a"), origin: .drop), Grant(url: URL(filePath: "/b"), origin: .drop)])
    }

    @Test func importerResultsBecomeImporterGrants() throws {
        let grants = try GrantMapping.grants(from: .success([URL(filePath: "/a")])).get()

        #expect(grants == [Grant(url: URL(filePath: "/a"), origin: .fileImporter)])
    }

    @Test func importerFailuresPassThrough() {
        #expect(throws: Failure.self) { try GrantMapping.grants(from: .failure(Failure())).get() }
    }
}

#if os(macOS)
import AppKit

@Suite("OpenPanelPicker")
@MainActor
struct OpenPanelPickerTests {
    @Test func configuresThePanel() {
        let panel = NSOpenPanel()
        let configuration = PickerConfiguration(
            message: "Pick",
            prompt: "Allow",
            directoryURL: URL(filePath: "/tmp"),
            allowsFolders: false,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: true,
            canCreateFolders: true,
            showsHiddenFiles: true
        )

        OpenPanelPicker.configure(panel, with: configuration)

        #expect(panel.message == "Pick")
        #expect(panel.prompt == "Allow")
        #expect(!panel.canChooseDirectories)
        #expect(panel.canChooseFiles)
        #expect(panel.allowedContentTypes == [.plainText])
        #expect(panel.allowsMultipleSelection)
        #expect(panel.canCreateDirectories)
        #expect(panel.showsHiddenFiles)
        #expect(panel.resolvesAliases)
    }

    @Test func regrantingAnUnknownKeyFailsWithoutAPanel() async {
        let store = BookmarkStore<String, NoMetadata>(
            persistence: InMemoryPersistence(),
            bookmarks: Bookmarks(engine: FakeBookmarkEngine())
        )

        await #expect(throws: BookmarkStoreError<String>.self) {
            try await store.regrantWithOpenPanel("missing")
        }
    }
}
#endif
