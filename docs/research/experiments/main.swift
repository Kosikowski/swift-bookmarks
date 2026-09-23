import Foundation
setvbuf(stdout,nil,_IONBF,0)
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
try? fm.removeItem(at: base); try! fm.createDirectory(at: base, withIntermediateDirectories: true)
let f = base.appendingPathComponent("a.txt"); try! "hello".write(to: f, atomically: false, encoding: .utf8)
func mk(_ name: String, _ o: URL.BookmarkCreationOptions, _ u: URL = f) -> Data? {
  do { let d = try u.bookmarkData(options: o, includingResourceValuesForKeys: nil, relativeTo: nil); print(name, "size", d.count); return d } catch { print(name, "ERR", error); return nil }
}
let plain = mk("plain", [])!
let minimal = mk("minimal", [.minimalBookmark])!
let noimp = mk("withoutImplicitSecurityScope", [.withoutImplicitSecurityScope])!
let ss = mk("withSecurityScope", [.withSecurityScope])
let ssro = mk("withSecurityScope+RO", [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
_ = mk("withSecurityScope+minimal", [.withSecurityScope, .minimalBookmark])
_ = mk("suitableForBookmarkFile", [.suitableForBookmarkFile])
_ = mk("withSecurityScope+suitable", [.withSecurityScope, .suitableForBookmarkFile])
_ = mk("dir plain", [], base)
func res(_ name: String, _ d: Data?, _ o: URL.BookmarkResolutionOptions) {
  guard let d else { return }
  var stale = false
  do { let u = try URL(resolvingBookmarkData: d, options: o, relativeTo: nil, bookmarkDataIsStale: &stale)
    let s = u.startAccessingSecurityScopedResource(); if s { u.stopAccessingSecurityScopedResource() }
    print(name, "->", u.path, "stale", stale, "start", s)
  } catch let e as NSError { print(name, "ERR", e.domain, e.code, e.localizedDescription) }
}
res("plain", plain, []); res("plain+withSS", plain, [.withSecurityScope]); res("ss", ss, [.withSecurityScope]); res("ss noopt", ss, []); res("ssro", ssro, [.withSecurityScope]); res("minimal", minimal, []); res("noimp", noimp, []); res("plain noImplicitStart", plain, [.withoutImplicitStartAccessing])
// rename
let g = base.appendingPathComponent("b.txt"); try! fm.moveItem(at: f, to: g)
print("--after rename"); res("plain", plain, []); res("minimal", minimal, []); res("ss", ss, [.withSecurityScope])
// atomic replace at new path
try! "world".write(to: g, atomically: true, encoding: .utf8)
print("--after atomic write at b.txt"); res("plain", plain, []); res("ss", ss, [.withSecurityScope])
// back at original path atomically replaced
try! fm.moveItem(at: g, to: f); try! "x".write(to: f, atomically: true, encoding: .utf8)
print("--after move back + atomic write a.txt"); res("plain", plain, []); res("minimal", minimal, []); res("ss", ss, [.withSecurityScope])
try! fm.removeItem(at: f)
print("--after delete"); res("plain", plain, []); res("ss", ss, [.withSecurityScope])
// resource values from bookmark
if let rv = URL.resourceValues(forKeys: [.pathKey, .nameKey, .volumeUUIDStringKey, .fileResourceIdentifierKey], fromBookmarkData: plain) { print("rv", rv.path ?? "-", rv.name ?? "-") }
// symlink
let tgt = base.appendingPathComponent("t.txt"); try! "t".write(to: tgt, atomically: false, encoding: .utf8)
let ln = base.appendingPathComponent("ln.txt"); try! fm.createSymbolicLink(at: ln, withDestinationURL: tgt)
let lb = mk("symlink", [], ln)!; res("symlink", lb, [])
// start twice / refcount
setvbuf(stdout,nil,_IONBF,0)
print("garbage:"); res("garbage", Data([1,2,3,4]), [])
