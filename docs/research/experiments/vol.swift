import Foundation
setvbuf(stdout,nil,_IONBF,0)
let f = URL(fileURLWithPath: CommandLine.arguments[2])
if CommandLine.arguments[1] == "make" { try! f.bookmarkData().write(to: URL(fileURLWithPath: "bm-vol.bin")); try! f.bookmarkData(options: .withSecurityScope).write(to: URL(fileURLWithPath: "bm-vol-ss.bin")); print("made"); exit(0) }
for (n, o) in [("plain", URL.BookmarkResolutionOptions([.withoutMounting, .withoutUI])), ("plain-mount", [.withoutUI])] {
  var s = false
  do { let u = try URL(resolvingBookmarkData: try Data(contentsOf: URL(fileURLWithPath: "bm-vol.bin")), options: o, bookmarkDataIsStale: &s); print(n, "->", u.path, s) } catch let e as NSError { print(n, "ERR", e.domain, e.code, e.localizedDescription, e.userInfo.keys.map{$0}) }
}
var s = false
do { let u = try URL(resolvingBookmarkData: try Data(contentsOf: URL(fileURLWithPath: "bm-vol-ss.bin")), options: [.withSecurityScope, .withoutMounting], bookmarkDataIsStale: &s); print("ss ->", u.path) } catch let e as NSError { print("ss ERR", e.domain, e.code, e.localizedDescription) }
let rv = URL.resourceValues(forKeys: [.pathKey, .volumeNameKey, .volumeURLKey, .volumeUUIDStringKey, .volumeIsRemovableKey], fromBookmarkData: try! Data(contentsOf: URL(fileURLWithPath: "bm-vol.bin")))
print("rv", rv?.path ?? "-", rv?.volumeName ?? "-", rv?.volume?.path ?? "-", rv?.volumeUUIDString ?? "-")
