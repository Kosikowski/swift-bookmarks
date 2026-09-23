import Bookmarks
import Foundation

struct ProbeResult: Identifiable, Sendable {
    let id = UUID()
    let probe: String
    let detail: String
}

/// Checks that answer the open questions in docs/design.md §11 on a real sandboxed build.
struct Probes: Sendable {
    let engine = SystemBookmarkEngine()
    var service: BookmarkService { BookmarkService(engine: engine) }

    /// Question 1: does the system start access for this grant, and what does another start return?
    func systemStart(for grant: Grant) -> [ProbeResult] {
        let name = "Start state of \(grant.origin.rawValue) URL"
        var observations = [ProbeResult(probe: name, detail: "Readable before any start: \(canRead(grant.url))")]
        let started = engine.startAccessing(grant.url)
        observations.append(ProbeResult(probe: name, detail: "startAccessing returned \(started)"))
        if started {
            engine.stopAccessing(grant.url)
            observations.append(ProbeResult(probe: name, detail: "Readable after balancing our start: \(canRead(grant.url))"))
        }
        engine.stopAccessing(grant.url)
        observations.append(ProbeResult(probe: name, detail: "Readable after one more stop: \(canRead(grant.url))"))
        return observations
    }

    /// Question 2: does a URL rebuilt from the resolved path carry the scope?
    func rebuiltURL(for grant: Grant) async -> [ProbeResult] {
        let name = "Rebuilt URL"
        do {
            let resolved = try await service.adopt(grant, kind: .appScoped(.readWrite))
            let rebuilt = URL(filePath: resolved.displayPath)
            let rebuiltStarted = engine.startAccessing(rebuilt)
            var observations = [
                ProbeResult(probe: name, detail: "start on rebuilt URL returned \(rebuiltStarted)"),
                ProbeResult(probe: name, detail: "Rebuilt URL readable: \(canRead(rebuilt))"),
            ]
            if rebuiltStarted { engine.stopAccessing(rebuilt) }
            let lease = resolved.beginAccess()
            observations.append(ProbeResult(probe: name, detail: "Resolved URL lease started: \(lease.didStartScope), readable: \(canRead(lease.url))"))
            observations.append(ProbeResult(probe: name, detail: "Rebuilt URL readable while lease is active: \(canRead(rebuilt))"))
            lease.end()
            return observations
        } catch {
            return [ProbeResult(probe: name, detail: "Failed: \(error)")]
        }
    }

    /// Question 3: which failure does resolution report once the item or its volume is gone?
    func resolution(of data: BookmarkData) async -> [ProbeResult] {
        do {
            let resolved = try await service.resolve(data, kind: .appScoped(.readWrite))
            return [ProbeResult(probe: "Resolution", detail: "Resolved to \(resolved.displayPath), stale: \(resolved.wasStale)")]
        } catch {
            let underlying = (error.underlying as? NSError).map { "\($0.domain) \($0.code)" } ?? "none"
            return [ProbeResult(probe: "Resolution", detail: "Failure \(error.failure), underlying \(underlying)")]
        }
    }

    /// Question 4: can a read-only app-scoped bookmark be created and used?
    func readOnlyBookmark(for grant: Grant) async -> [ProbeResult] {
        do {
            let resolved = try await service.adopt(grant, kind: .appScoped(.readOnly))
            let lease = resolved.beginAccess()
            defer { lease.end() }
            return [ProbeResult(probe: "Read-only scope", detail: "Created; lease started: \(lease.didStartScope), readable: \(canRead(lease.url))")]
        } catch {
            return [ProbeResult(probe: "Read-only scope", detail: "Failed: \(error)")]
        }
    }

    /// Question 5: does an atomic save succeed with only a file-scoped bookmark?
    func atomicSave(for grant: Grant) async -> [ProbeResult] {
        do {
            let resolved = try await service.adopt(grant, kind: .appScoped(.readWrite))
            let lease = resolved.beginAccess()
            defer { lease.end() }
            let original = try Data(contentsOf: lease.url)
            do {
                try original.write(to: lease.url, options: .atomic)
                return [ProbeResult(probe: "Atomic save", detail: "Atomic write succeeded")]
            } catch {
                try original.write(to: lease.url)
                return [ProbeResult(probe: "Atomic save", detail: "Atomic write failed (\(error)); in-place write succeeded")]
            }
        } catch {
            return [ProbeResult(probe: "Atomic save", detail: "Failed: \(error)")]
        }
    }

    private func canRead(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) != nil
        }
        return (try? FileHandle(forReadingFrom: url).close()) != nil
    }
}
