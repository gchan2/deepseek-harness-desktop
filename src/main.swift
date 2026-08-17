import AppKit
import Foundation
import Darwin

// MARK: - Constants

let port: UInt16 = 3080
let localURL = URL(string: "http://127.0.0.1:\(port)")!
let appName = "DeepSeek Harness"
let chromeWindowSize = "960,680"

// MARK: - Helpers

func fileExists(_ path: String) -> Bool {
    return FileManager.default.fileExists(atPath: path)
}

func isExecutable(_ path: String) -> Bool {
    return FileManager.default.isExecutableFile(atPath: path)
}

/// Find a usable node binary. Requires Node >= 20.12 (needed for util.parseEnv).
func findNode() -> String? {
    let candidates = [
        "/usr/local/bin/node",
        "/opt/homebrew/bin/node",
        "/usr/bin/node",
        "/Users/gchen/.workbuddy/binaries/node/versions/22.22.2/bin/node",
        "/Users/gchen/.workbuddy/binaries/node/versions/22.23.1/bin/node",
        "/Users/gchen/.local/bin/node",
        "/usr/local/bin/node22",
        "/opt/homebrew/bin/node22"
    ]
    for c in candidates where fileExists(c) && isExecutable(c) {
        if nodeVersion(at: c) >= (20, 12) { return c }
    }
    return nil
}

/// Runs `node -p process.versions.node` and parses the major.minor.
func nodeVersion(at path: String) -> (Int, Int) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["-p", "process.versions.node"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = s.split(separator: ".")
        if parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) {
            return (major, minor)
        }
    } catch {}
    return (0, 0)
}

/// Locate the bundled dsh wrapper. The wrapper installs signal-ignore
/// handlers and then dynamically imports the real dsh entry script.
func bundledDSHBin() -> String? {
    guard let res = Bundle.main.resourceURL else { return nil }
    let p = res.appendingPathComponent("dsh/bin-wrapper.mjs").path
    return fileExists(p) ? p : nil
}

// MARK: - Socket helper (port readiness)

func portOpen(host: String, port: UInt16) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 { return false }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    var sa = sockaddr()
    withUnsafePointer(to: &addr) { a in
        a.withMemoryRebound(to: sockaddr.self, capacity: 1) { reb in
            sa = reb.pointee
        }
    }
    let r = withUnsafePointer(to: &sa) { p in
        connect(sock, p, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
    return r == 0
}

// MARK: - Server process management

final class ServerController {
    private var process: Process?
    var onLog: ((String) -> Void)?

    func start(node: String, bin: String) -> Bool {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [bin, "web"]

        let fm = FileManager.default
        let support = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeepSeekHarness"))!
        try? fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: nil)
        p.currentDirectoryURL = support

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = NSHomeDirectory()
        env["LANG"] = "en_US.UTF-8"
        env["NO_COLOR"] = "1"
        env.removeValue(forKey: "NODE_OPTIONS")
        env.removeValue(forKey: "NODE_PATH")
        env.removeValue(forKey: "NODE_EXTRA_CA_CERTS")
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let forward: (FileHandle) -> Void = { [weak self] h in
            let d = h.availableData
            if d.count > 0, let s = String(data: d, encoding: .utf8) {
                self?.onLog?(s)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = forward
        errPipe.fileHandleForReading.readabilityHandler = forward

        do {
            try p.run()
            process = p
            NSLog("DSH: server process started pid=\(p.processIdentifier)")
            return true
        } catch {
            NSLog("DSH: Failed to start server: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if let p = self?.process, p.isRunning { p.interrupt() }
        }
        process = nil
    }

    deinit { stop() }
}

// MARK: - App delegate (menu bar app)

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let server = ServerController()
    private var statusItem: NSStatusItem!
    private var didOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no persistent window.
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        launchServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = menuBarIcon()
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开 DeepSeek Harness", action: #selector(openWebUI), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        let browserItem = NSMenuItem(title: "在浏览器中打开", action: #selector(openInBrowserAction), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出并停止服务", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func menuBarIcon() -> NSImage {
        // Draw the whale directly (template) so the menu-bar item is always visible.
        let img = NSImage(size: NSSize(width: 18, height: 18))
        img.lockFocus()
        NSColor.black.setFill()
        let w = NSBezierPath()
        // body (ellipse) + tail fluke + belly, scaled into 18x18
        w.appendOval(in: NSRect(x: 8.5, y: 6, width: 7.5, height: 6))
        w.move(to: NSPoint(x: 8.5, y: 9))
        w.line(to: NSPoint(x: 3, y: 12))
        w.line(to: NSPoint(x: 4.5, y: 9))
        w.line(to: NSPoint(x: 3, y: 6))
        w.close()
        w.fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: Server launch

    private func launchServer() {
        NSLog("DSH: launchServer: finding node")
        guard let node = findNode() else {
            notifyError("Node.js 未找到或版本低于 20.12，请先安装 Node.js 20.12+（https://nodejs.org）")
            return
        }
        NSLog("DSH: launchServer: node=\(node)")
        guard let bin = bundledDSHBin() else {
            notifyError("未找到内置的 DeepSeek Harness 程序，请重新安装本应用。")
            return
        }
        NSLog("DSH: launchServer: bin=\(bin)")

        server.onLog = { [weak self] line in
            NSLog("DSH: [dsh] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let ok = server.start(node: node, bin: bin)
        NSLog("DSH: launchServer: start returned \(ok)")
        if !ok { return }

        let deadline = Date().addingTimeInterval(120)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while Date() < deadline {
                if portOpen(host: "127.0.0.1", port: port) {
                    DispatchQueue.main.async { self?.finishLoading() }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async {
                self?.notifyError("启动超时：本地服务未在 3080 端口响应。")
            }
        }
    }

    private func finishLoading() {
        guard !didOpen else { return }
        didOpen = true
        openWebUI()
    }

    private func notifyError(_ message: String) {
        NSLog("DSH: %@", message)
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Actions

    @objc private func openWebUI() {
        // Prefer Chrome app-mode (borderless standalone window); fall back to
        // the system default browser.
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if FileManager.default.isExecutableFile(atPath: chrome) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: chrome)
            p.arguments = ["--app=\(localURL.absoluteString)", "--window-size=\(chromeWindowSize)", "--new-window"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                return
            } catch {
                NSLog("DSH: chrome app-mode failed: \(error.localizedDescription)")
            }
        }
        NSWorkspace.shared.open(localURL)
    }

    @objc private func openInBrowserAction() {
        NSWorkspace.shared.open(localURL)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
