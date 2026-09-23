import Bookmarks
import BookmarksUI
import SwiftUI

@main
struct IntegrationHostApp: App {
    var body: some Scene {
        WindowGroup("Bookmarks Integration Host") {
            ProbeView()
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}

@MainActor
@Observable
final class ProbeModel {
    var observations: [ProbeResult] = []
    var savedBookmark: BookmarkData?
    private let probes = Probes()

    func record(_ new: [ProbeResult]) {
        observations.append(contentsOf: new)
    }

    func pickWithPanel(files: Bool, run probe: @escaping @Sendable (Probes, Grant) async -> [ProbeResult]) async {
        let configuration = files ? PickerConfiguration.files([.item]) : .folder()
        guard let grant = await OpenPanelPicker.choose(configuration).first else { return }
        let probes = probes
        record(await probe(probes, grant))
    }

    func saveForLater() async {
        guard let grant = await OpenPanelPicker.choose(.folder(message: "Pick a folder, then delete it or eject its volume")).first else { return }
        do {
            savedBookmark = try await probes.bookmarks.adopt(grant, kind: .appScoped(.readWrite)).data
            record([ProbeResult(probe: "Resolution", detail: "Saved a bookmark to \(grant.url.path(percentEncoded: false))")])
        } catch {
            record([ProbeResult(probe: "Resolution", detail: "Saving failed: \(error)")])
        }
    }

    func resolveSaved() async {
        guard let savedBookmark else { return }
        record(await probes.resolution(of: savedBookmark))
    }

    func handle(_ grants: [Grant]) {
        for grant in grants {
            record(probes.systemStart(for: grant))
        }
    }
}

struct ProbeView: View {
    @State private var model = ProbeModel()
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each button answers one question from docs/design.md §11. Drop a folder anywhere to probe drops.")
                .foregroundStyle(.secondary)
            HStack {
                Button("1. Panel start state") {
                    Task { await model.pickWithPanel(files: false) { probes, grant in probes.systemStart(for: grant) } }
                }
                Button("1. Importer start state") { importing = true }
                Button("2. Rebuilt URL") {
                    Task { await model.pickWithPanel(files: false) { await $0.rebuiltURL(for: $1) } }
                }
            }
            HStack {
                Button("3. Save bookmark") { Task { await model.saveForLater() } }
                Button("3. Resolve saved") { Task { await model.resolveSaved() } }
                    .disabled(model.savedBookmark == nil)
                Button("4. Read-only scope") {
                    Task { await model.pickWithPanel(files: false) { await $0.readOnlyBookmark(for: $1) } }
                }
                Button("5. Atomic save") {
                    Task { await model.pickWithPanel(files: true) { await $0.atomicSave(for: $1) } }
                }
            }
            List(model.observations) { observation in
                VStack(alignment: .leading) {
                    Text(observation.probe).font(.headline)
                    Text(observation.detail).textSelection(.enabled)
                }
            }
        }
        .padding()
        .bookmarkImporter(isPresented: $importing, configuration: .folder()) { model.handle($0) }
        .bookmarkDropDestination { grants in
            model.handle(grants)
            return true
        }
    }
}
