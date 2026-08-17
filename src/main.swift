import AppKit
import WebKit
import Foundation
import Darwin

// MARK: - Constants

let port: UInt16 = 3080
let localURL = URL(string: "http://127.0.0.1:\(port)")!
let appName = "DeepSeek Harness"

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

        // Writable working dir for any runtime state.
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
        // Strip NODE_OPTIONS: some flags (e.g. --use-system-ca) are not allowed via
        // NODE_OPTIONS on Node 19+ and can break the bundled server.
        env.removeValue(forKey: "NODE_OPTIONS")
        env.removeValue(forKey: "NODE_PATH")
        env.removeValue(forKey: "NODE_EXTRA_CA_CERTS")
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.count > 0, let s = String(data: d, encoding: .utf8) {
                self?.onLog?(s)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.count > 0, let s = String(data: d, encoding: .utf8) {
                self?.onLog?(s)
            }
        }

        p.terminationHandler = { proc in
            NSLog("DSH: server process terminated status=\(proc.terminationStatus) reason=\(proc.terminationReason.rawValue)")
        }

        do {
            try p.run()
            process = p
            NSLog("DSH: server process started pid=\(p.processIdentifier)")
            return true
        } catch {
            NSLog("DSH: Failed to start server: \(error.localizedDescription)")
            onLog?("Failed to start server: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        // Give it a moment, then kill harder.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if let p = self?.process, p.isRunning { p.interrupt() }
        }
        process = nil
    }

    deinit { stop() }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate, WKScriptMessageHandler {

    private var window: NSWindow!
    private var webView: WKWebView!
    private let server = ServerController()
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var loadingContainer: NSView!
    private var didLoad = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        launchServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    // MARK: UI

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "b")
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
        window.title = appName
        window.titlebarAppearsTransparent = false
        window.center()
        window.minSize = NSSize(width: 720, height: 520)
        window.delegate = self

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // Capture front-end console output (console.log/error/warn, window.onerror,
        // unhandledrejection) so web UI errors are visible in the system log.
        let ucc = WKUserContentController()
        let consoleBridge = """
        (function(){
          // Polyfill AbortSignal.timeout / AbortSignal.any (Safari 16 / 17.4+);
          // macOS 12 WKWebView (Safari 15) lacks them and dsh calls them directly.
          try {
            if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout !== 'function') {
              AbortSignal.timeout = function(ms){
                var c = new AbortController();
                var t = setTimeout(function(){
                  var reason;
                  try { reason = new DOMException('The operation timed out', 'TimeoutError'); }
                  catch(e){ reason = new Error('Timeout'); }
                  c.abort(reason);
                }, ms);
                return c.signal;
              };
            }
            if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.any !== 'function') {
              AbortSignal.any = function(signals){
                var c = new AbortController();
                if (signals) {
                  Array.prototype.slice.call(signals).forEach(function(sig){
                    if (!sig) return;
                    if (sig.aborted) { c.abort(sig.reason); return; }
                    sig.addEventListener('abort', function(){ c.abort(sig.reason); }, { once: true });
                  });
                }
                return c.signal;
              };
            }
          } catch(e){}
          function post(level, args){
            try {
              var parts = Array.prototype.slice.call(args).map(function(a){
                if (a instanceof Error) return a.name + ': ' + a.message;
                if (typeof a === 'object') { try { return JSON.stringify(a); } catch(e){ return String(a); } }
                return String(a);
              });
              window.webkit.messageHandlers.console.postMessage({level: level, msg: parts.join(' ')});
            } catch(e){}
          }
          ['log','error','warn','info','debug'].forEach(function(l){
            var orig = console[l];
            console[l] = function(){ post(l, arguments); if (orig) orig.apply(console, arguments); };
          });
          window.addEventListener('error', function(e){
            post('error', ['[window.onerror]', e.message, (e.filename||'')+':'+(e.lineno||'')]);
          });
          window.addEventListener('unhandledrejection', function(e){
            post('error', ['[unhandledrejection]', (e.reason && e.reason.message) || e.reason]);
          });
          // Instrument WebSocket lifecycle for diagnostics
          try {
            var OrigWS = window.WebSocket;
            if (OrigWS) {
              window.WebSocket = function(url, protocols){
                var ws = protocols ? new OrigWS(url, protocols) : new OrigWS(url);
                try {
                  ws.addEventListener('open', function(){ post('log', ['[ws] open', String(url)]); });
                  ws.addEventListener('error', function(){ post('error', ['[ws] ERROR', String(url)]); });
                  ws.addEventListener('close', function(e){ post('warn', ['[ws] close', String(url), 'code='+e.code, 'clean='+e.wasClean]); });
                } catch(e){}
                return ws;
              };
              window.WebSocket.prototype = OrigWS.prototype;
            }
          } catch(e){}
          // Instrument failed fetches
          try {
            var origFetch = window.fetch;
            if (origFetch) {
              window.fetch = function(){
                var url = arguments[0];
                return origFetch.apply(this, arguments).then(function(res){
                  if (!res.ok) post('error', ['[fetch] HTTP '+res.status, String(url)]);
                  return res;
                }).catch(function(err){
                  post('error', ['[fetch] FAIL', String(url), (err && err.message) || err]);
                  throw err;
                });
              };
            }
          } catch(e){}
        })();
        """
        let script = WKUserScript(source: consoleBridge, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        ucc.addUserScript(script)
        ucc.add(self, name: "console")
        config.userContentController = ucc

        webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        // Loading overlay
        loadingContainer = NSView(frame: rect)
        loadingContainer.autoresizingMask = [.width, .height]
        loadingContainer.wantsLayer = true
        loadingContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.sizeToFit()
        spinner.startAnimation(nil)

        statusLabel = NSTextField(labelWithString: "Starting DeepSeek Harness…")
        statusLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [spinner, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingContainer.centerYAnchor)
        ])

        window.contentView = webView
        webView.addSubview(loadingContainer)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Server launch

    private func launchServer() {
        NSLog("DSH: launchServer: finding node")
        guard let node = findNode() else {
            showError("Node.js 未找到或版本低于 20.12，请先安装 Node.js 20.12+（https://nodejs.org）后重试。")
            return
        }
        NSLog("DSH: launchServer: node=\(node)")
        guard let bin = bundledDSHBin() else {
            showError("未找到内置的 DeepSeek Harness 程序，请重新安装本应用。")
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
                self?.showError("启动超时：本地服务未在 3080 端口响应。请检查 Node.js 环境或网络。")
            }
        }
    }

    private func finishLoading() {
        guard !didLoad else { return }
        didLoad = true
        loadingContainer.isHidden = true
        // Open the web UI in a Chrome app-mode window (borderless, no address bar)
        // so it looks like a native app. Chrome's Chromium engine supports the
        // regex lookbehind that macOS 12's WKWebView lacks.
        openWebUI()
        let html = """
        <html><head><meta charset="utf-8"><style>
          body { font-family:-apple-system; display:flex; align-items:center; justify-content:center; height:100%; margin:0; background:#f5f5f7; }
          .box { text-align:center; color:#1d1d1f; max-width:520px; padding:24px; }
          h1 { font-size:22px; margin-bottom:12px; }
          p { color:#555; line-height:1.6; }
          .url { font-family:ui-monospace,monospace; font-size:13px; color:#888; }
          a.btn { display:inline-block; margin:8px 4px; padding:10px 18px; border-radius:8px; background:#4A73FF; color:#fff; text-decoration:none; font-weight:600; }
          a.btn.ghost { background:#e5e5ea; color:#1d1d1f; }
        </style></head><body>
        <div class="box">
          <h1>已在独立窗口打开</h1>
          <p>DeepSeek Harness 已在 Chrome 独立窗口中打开<br><span class="url">http://127.0.0.1:3080</span></p>
          <p>本窗口负责在后台运行服务。<br><strong>关闭窗口或退出 App 会同时停止服务。</strong></p>
          <p>
            <a class="btn" href="http://127.0.0.1:3080">重新打开</a>
            <a class="btn ghost" href="app://quit">退出并停止服务</a>
          </p>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func openWebUI() {
        // Prefer Chrome app-mode (borderless standalone window); fall back to
        // the system default browser.
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if FileManager.default.isExecutableFile(atPath: chrome) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: chrome)
            p.arguments = ["--app=\(localURL.absoluteString)", "--new-window"]
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

    private func showError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        spinner.stopAnimation(nil)
        let html = """
        <html><body style="font-family:-apple-system;display:flex;align-items:center;justify-content:center;height:100%;margin:0;background:#f5f5f7">
        <div style="text-align:center;color:#1d1d1f;max-width:480px">
        <h2>\(appName)</h2><p style="color:#555">\(message)</p>
        <p><a href="https://nodejs.org">Install Node.js</a> · <a href="https://github.com/deepseek-ai/deepseek-harness">Project on GitHub</a></p>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: Actions

    @objc private func reload() {
        webView.reload()
    }

    @objc private func openInBrowser() {
        openWebUI()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel); return
        }
        if url.scheme == "app" {
            if url.host == "quit" {
                NSApp.terminate(nil)
            }
            decisionHandler(.cancel); return
        }
        // Keep everything on the local server inside the app; external links open in the browser.
        if url.host == "127.0.0.1" || url.host == "localhost" {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Hide the overlay once real content starts loading.
        if didLoad {
            loadingContainer.isHidden = true
        }
    }

    // MARK: WKScriptMessageHandler — forward front-end console logs to the system log
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "console" else { return }
        if let body = message.body as? [String: Any] {
            let level = body["level"] as? String ?? "log"
            let msg = body["msg"] as? String ?? ""
            if msg.count > 800 {
                NSLog("DSH-WEB[%@] %@…", level, String(msg.prefix(800)))
            } else {
                NSLog("DSH-WEB[%@] %@", level, msg)
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
