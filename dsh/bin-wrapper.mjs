// bin-wrapper.mjs — signal-safe launcher for the bundled dsh web server.
//
// We dynamically import the real dsh bin. Before that, we monkey-patch
// process.on / process.addListener so that the dsh runtime's own SIGINT and
// SIGHUP handlers (which would call interrupt(130) and tear the server down)
// are silently dropped. SIGTERM is left intact so a clean shutdown from the
// GUI host still works.

const _hasSig = { SIGINT: false, SIGHUP: false };

const realOn = process.on;
const realAddListener = process.addListener;

function ensureIgnore(sig) {
    if (_hasSig[sig]) return;
    realOn.call(process, sig, () => {});
    _hasSig[sig] = true;
}

function patched(sig, fn) {
    if (sig === 'SIGINT' || sig === 'SIGHUP') {
        ensureIgnore(sig);
        return process; // intentionally drop caller's handler
    }
    return realOn.call(process, sig, fn);
}

process.on = patched;
process.addListener = patched;

const { fileURLToPath } = await import('node:url');
const { dirname, resolve } = await import('node:path');
const here = dirname(fileURLToPath(import.meta.url));
const bin = resolve(here, 'node_modules/@deepseek-ai/dsh/lib/bin.js');

const extra = process.argv.slice(2);
process.argv = ['node', bin, ...extra];

await import('file://' + bin);
