import Foundation
setvbuf(stdout,nil,_IONBF,0)
let bmdir = URL(fileURLWithPath: CommandLine.arguments[1])
let target = CommandLine.arguments[2]
func load(_ n: String) -> Data { try! Data(contentsOf: bmdir.appendingPathComponent(n)) }
print("sandboxed? HOME=", NSHomeDirectory())
print("read direct path before:", (try? String(contentsOfFile: target + "/x.txt", encoding: .utf8)) ?? "DENIED")
let pathURL = URL(fileURLWithPath: target + "/x.txt")
print("start on path URL:", pathURL.startAccessingSecurityScopedResource())
var st = false
// noimp
do { let u = try URL(resolvingBookmarkData: load("file-noimp.bm"), bookmarkDataIsStale: &st); print("noimp resolved", u.path, "start", u.startAccessingSecurityScopedResource(), "read", (try? String(contentsOf: u, encoding: .utf8)) ?? "DENIED") } catch { print("noimp err", error) }
// implicit start
do { let u = try URL(resolvingBookmarkData: load("file.bm"), options: [.withoutImplicitStartAccessing], bookmarkDataIsStale: &st)
  print("withoutImplicitStart read before start:", (try? String(contentsOf: u, encoding: .utf8)) ?? "DENIED")
  print("start:", u.startAccessingSecurityScopedResource(), "read:", (try? String(contentsOf: u, encoding: .utf8)) ?? "DENIED")
  u.stopAccessingSecurityScopedResource(); print("after stop read:", (try? String(contentsOf: u, encoding: .utf8)) ?? "DENIED")
} catch { print(error) }
// refcount on same instance
do { let u = try URL(resolvingBookmarkData: load("dir.bm"), options: [.withoutImplicitStartAccessing], bookmarkDataIsStale: &st)
  let y = u.appendingPathComponent("sub/y.txt")
  print("dir start1", u.startAccessingSecurityScopedResource(), "start2", u.startAccessingSecurityScopedResource())
  print("child read:", (try? String(contentsOf: y, encoding: .utf8)) ?? "DENIED", "child start:", y.startAccessingSecurityScopedResource())
  u.stopAccessingSecurityScopedResource(); print("after 1 stop child read:", (try? String(contentsOf: y, encoding: .utf8)) ?? "DENIED")
  u.stopAccessingSecurityScopedResource(); print("after 2 stops child read:", (try? String(contentsOf: y, encoding: .utf8)) ?? "DENIED")
  // copy of URL
  let u2 = try URL(resolvingBookmarkData: load("dir.bm"), options: [.withoutImplicitStartAccessing], bookmarkDataIsStale: &st)
  let copy = URL(string: u2.absoluteString)!
  print("fresh-from-string URL start:", copy.startAccessingSecurityScopedResource())
  let appended = u2.appendingPathComponent("sub")
  print("appended child start (parent not started):", appended.startAccessingSecurityScopedResource())
} catch { print(error) }
// limit test
var n = 0
let data = load("file.bm")
var keep: [URL] = []
while n < 100000 {
  guard let u = try? URL(resolvingBookmarkData: data, options: [.withoutImplicitStartAccessing], bookmarkDataIsStale: &st) else { print("resolve failed at", n); break }
  if !u.startAccessingSecurityScopedResource() { print("start returned false after", n, "outstanding"); break }
  keep.append(u); n += 1
}
if n == 100000 { print("no limit hit up to", n) }
// can we still resolve implicit start after limit?
do { let u = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &st); print("implicit-resolve after limit ok; read:", (try? String(contentsOf: u, encoding: .utf8)) ?? "DENIED") } catch let e as NSError { print("resolve after limit err", e.domain, e.code, e.localizedDescription) }
for u in keep { u.stopAccessingSecurityScopedResource() }
let u = try! URL(resolvingBookmarkData: data, options: [.withoutImplicitStartAccessing], bookmarkDataIsStale: &st)
print("after releasing all, start:", u.startAccessingSecurityScopedResource())
