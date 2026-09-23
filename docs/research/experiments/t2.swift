import Foundation
setvbuf(stdout,nil,_IONBF,0)
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1]); try? fm.removeItem(at: base); try! fm.createDirectory(at: base, withIntermediateDirectories: true)
let f = base.appendingPathComponent("a.txt"); try! "a".write(to: f, atomically: false, encoding: .utf8)
print("path URL start (non-sandboxed):", URL(fileURLWithPath: "/etc/hosts").startAccessingSecurityScopedResource())
do { _ = try base.appendingPathComponent("nope.txt").bookmarkData(); } catch let e as NSError { print("bookmark missing file:", e.domain, e.code, e.localizedDescription) }
do { _ = try base.appendingPathComponent("nope.txt").bookmarkData(options: .withSecurityScope); } catch let e as NSError { print("ss bookmark missing file:", e.domain, e.code, e.localizedDescription) }
// document scoped
let doc = base.appendingPathComponent("doc.proj"); try! "d".write(to: doc, atomically: false, encoding: .utf8)
do { let d = try f.bookmarkData(options: .withSecurityScope, relativeTo: doc); print("doc-scoped size", d.count)
  var s=false; let u = try URL(resolvingBookmarkData: d, options: .withSecurityScope, relativeTo: doc, bookmarkDataIsStale: &s); print("doc-scoped resolve ok", u.lastPathComponent)
  do { _ = try URL(resolvingBookmarkData: d, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &s); print("doc-scoped resolve w/o relativeTo OK?!") } catch let e as NSError { print("doc-scoped w/o relativeTo:", e.code, e.localizedDescription) }
  do { _ = try URL(resolvingBookmarkData: d, options: .withSecurityScope, relativeTo: f, bookmarkDataIsStale: &s); print("doc-scoped wrong relativeTo OK?!") } catch let e as NSError { print("doc-scoped wrong relativeTo:", e.code, e.localizedDescription) }
} catch let e as NSError { print("doc-scoped create:", e.code, e.localizedDescription) }
do { _ = try base.bookmarkData(options: .withSecurityScope, relativeTo: doc); print("doc-scoped to DIRECTORY ok (non-sandboxed)") } catch let e as NSError { print("doc-scoped dir:", e.code, e.localizedDescription) }
// hard link
let h = base.appendingPathComponent("hard.txt"); try! fm.linkItem(at: f, to: h)
let hb = try! h.bookmarkData(); try! fm.removeItem(at: h)
var s = false; if let u = try? URL(resolvingBookmarkData: hb, bookmarkDataIsStale: &s) { print("hardlink bm after removing link name ->", u.lastPathComponent, "stale", s) } else { print("hardlink bm fails after unlink") }
// directory rename with child bookmark
let d1 = base.appendingPathComponent("d1"); try! fm.createDirectory(at: d1, withIntermediateDirectories: true); let c = d1.appendingPathComponent("c.txt"); try! "c".write(to: c, atomically: false, encoding: .utf8)
let cb = try! c.bookmarkData(options: .withSecurityScope); try! fm.moveItem(at: d1, to: base.appendingPathComponent("d2"))
let cu = try! URL(resolvingBookmarkData: cb, options: .withSecurityScope, bookmarkDataIsStale: &s); print("child after parent rename ->", cu.path.replacingOccurrences(of: base.path, with: ""), "stale", s)
// custom resource values
let cust = try! f.bookmarkData(options: [], includingResourceValuesForKeys: [.localizedNameKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .volumeURLKey])
let rv = URL.resourceValues(forKeys: [.localizedNameKey, .fileSizeKey, .contentModificationDateKey, .pathKey, .volumeURLKey], fromBookmarkData: cust)
print("rv from bookmark:", rv?.localizedName ?? "-", rv?.fileSize ?? -1, rv?.contentModificationDate as Any, rv?.path ?? "-", rv?.volume?.path ?? "-", "size", cust.count)
let rv2 = URL.resourceValues(forKeys: [.fileSizeKey, .pathKey], fromBookmarkData: try! f.bookmarkData())
print("rv default bookmark fileSize:", rv2?.fileSize as Any, rv2?.path ?? "-")
// timing
var t = Date(); for _ in 0..<1000 { _ = try! f.bookmarkData(options: .withSecurityScope) }; print("create ss x1000:", Date().timeIntervalSince(t))
t = Date(); for _ in 0..<1000 { _ = try! f.bookmarkData() }; print("create plain x1000:", Date().timeIntervalSince(t))
let ssd = try! f.bookmarkData(options: .withSecurityScope)
t = Date(); for _ in 0..<1000 { _ = try! URL(resolvingBookmarkData: ssd, options: .withSecurityScope, bookmarkDataIsStale: &s) }; print("resolve ss x1000:", Date().timeIntervalSince(t))
let pd = try! f.bookmarkData()
t = Date(); for _ in 0..<1000 { let u = try! URL(resolvingBookmarkData: pd, bookmarkDataIsStale: &s); u.stopAccessingSecurityScopedResource() }; print("resolve plain x1000:", Date().timeIntervalSince(t))
// alias file
let ab = try! f.bookmarkData(options: .suitableForBookmarkFile); let al = base.appendingPathComponent("alias")
try! URL.writeBookmarkData(ab, to: al); let written = try! fm.contentsOfDirectory(atPath: base.path).filter{ $0.hasPrefix("alias") }; print("alias written as", written)
let aurl = base.appendingPathComponent(written[0]); print("isAliasFile", (try! aurl.resourceValues(forKeys: [.isAliasFileKey])).isAliasFile!, "resolved ->", (try! URL(resolvingAliasFileAt: aurl)).lastPathComponent)
do { try URL.writeBookmarkData(pd, to: base.appendingPathComponent("alias2")); print("writing non-suitable bookmark OK?!") } catch let e as NSError { print("write non-suitable:", e.code, e.localizedDescription) }
// stale-then-refresh: bookmark recreated from stale-resolved URL
try! fm.moveItem(at: f, to: base.appendingPathComponent("moved.txt"))
let r = try! URL(resolvingBookmarkData: ssd, options: .withSecurityScope, bookmarkDataIsStale: &s); print("stale", s)
let ok = r.startAccessingSecurityScopedResource(); let nd = try! r.bookmarkData(options: .withSecurityScope); if ok { r.stopAccessingSecurityScopedResource() }
_ = try! URL(resolvingBookmarkData: nd, options: .withSecurityScope, bookmarkDataIsStale: &s); print("refreshed stale", s)
