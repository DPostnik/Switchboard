import Foundation

/// Real interpreter for fixture scripts. `/usr/bin/python3` is an xcrun shim;
/// under a fully parallel run its exec chain can stall for longer than the
/// adapters' fixed process deadlines, so fixtures bypass it.
let fixturePython: String = {
    let shim = "/usr/bin/python3", process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: shim)
    process.arguments = ["-c", "import sys; print(sys.executable)"]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return shim }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    // A shebang cannot contain spaces; keep the shim if the path is unusable.
    guard process.terminationStatus == 0, path.hasPrefix("/"), !path.contains(" "),
          FileManager.default.isExecutableFile(atPath: path) else { return shim }
    return path
}()

/// Slow mode for the process fixtures, tests only: `SWITCHBOARD_FIXTURE_DELAY_MS` in the test run's environment makes a
/// fixture sleep that long before each file it writes and each frame it prints. The adapters start fixtures with their
/// own environment, so the value is written into the script as a Python literal (seconds). Unset or 0: no delay.
let fixtureDelaySeconds: String = {
    let milliseconds = Int(ProcessInfo.processInfo.environment["SWITCHBOARD_FIXTURE_DELAY_MS"] ?? "") ?? 0
    return milliseconds > 0 ? String(Double(milliseconds) / 1000) : "0"
}()

/// Python helpers shared by the process fixtures; `home` must be a `pathlib.Path` before they run. Files a test reads are
/// written so a reader never sees half of them: `replace` writes a temporary file in the same folder and renames it over
/// the target, `append` adds whole lines with one `os.write` on an `O_APPEND` descriptor.
let fixtureWriteHelpers = #"""
DELAY=\#(fixtureDelaySeconds)
def pause():
    if DELAY: time.sleep(DELAY)
def append(name,text):
    pause(); data=text.encode(); fd=os.open(str(home/name),os.O_WRONLY|os.O_APPEND|os.O_CREAT,0o644)
    try: assert os.write(fd,data)==len(data)
    finally: os.close(fd)
def replace(name,text):
    pause(); temporary=home/('.'+name+'.'+str(os.getpid())+'.tmp'); temporary.write_text(text); os.replace(temporary,home/name)
"""#

private let fixtureLauncher: URL = {
    let launcher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fixture-launcher")
    // Fixtures are symlinks to this shared file; a stray write must not alter it.
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: launcher.path)
    return launcher
}()

/// Makes the script just written at `url` runnable without executing a new file:
/// the script moves to `<url>.fixture` and `url` becomes a symlink to the shared,
/// already-assessed launcher, which runs it with its shebang interpreter.
func installFixtureExecutable(at url: URL) throws {
    let script = url.appendingPathExtension("fixture")
    try? FileManager.default.removeItem(at: script)
    try FileManager.default.moveItem(at: url, to: script)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixtureLauncher)
}
