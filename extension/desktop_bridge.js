// Desktop app bridge helper (shared by popup + options).
//
// The Zalo Workspace desktop app runs a loopback HTTP server (see
// lib/src/services/local_bridge_server.dart) on one of a few fixed ports. This
// helper lets the extension:
//   - detect whether the app is running (probe /health),
//   - ask it to come to the foreground (/activate),
//   - fall back to the campaio-zalo:// URL scheme to wake/launch it when the
//     loopback probe finds nothing (app not running yet).
//
// Keep CANDIDATE_PORTS in sync with LocalBridgeServer.candidatePorts.

const CAMPAIO_DESKTOP = (() => {
  const CANDIDATE_PORTS = [8770, 8771, 8772, 8773];
  const PROBE_TIMEOUT_MS = 800;
  const URL_SCHEME = "campaio-zalo://activate";

  async function fetchWithTimeout(url, init = {}, timeout = PROBE_TIMEOUT_MS) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
      return await fetch(url, { ...init, signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }
  }

  // Probe the candidate ports; return { online, port, health } for the first
  // that answers /health, else { online: false }.
  async function detect() {
    for (const port of CANDIDATE_PORTS) {
      try {
        const res = await fetchWithTimeout(`http://127.0.0.1:${port}/health`);
        if (res.ok) {
          const health = await res.json().catch(() => ({}));
          if (health && health.app) {
            return { online: true, port, health };
          }
        }
      } catch {
        // Port closed / no app — try the next.
      }
    }
    return { online: false };
  }

  // Ask the running app to focus. Returns true if a port accepted /activate.
  async function activate() {
    const found = await detect();
    if (!found.online) return false;
    try {
      await fetchWithTimeout(`http://127.0.0.1:${found.port}/activate`, { method: "POST" });
      return true;
    } catch {
      return false;
    }
  }

  // Trigger the OS custom URL scheme to wake/launch the app when it isn't
  // running. In an extension popup, opening a tab with the scheme hands the URL
  // to the OS, which routes it to the registered app bundle.
  function wakeViaUrlScheme() {
    try {
      if (typeof chrome !== "undefined" && chrome.tabs && chrome.tabs.create) {
        chrome.tabs.create({ url: URL_SCHEME, active: false });
        return true;
      }
    } catch {
      // fall through
    }
    try {
      window.open(URL_SCHEME, "_blank");
      return true;
    } catch {
      return false;
    }
  }

  // High-level "Mở app" action: focus if running, else wake via URL scheme then
  // re-probe a couple of times. Returns a status string for the UI.
  async function openApp() {
    if (await activate()) {
      return { ok: true, state: "focused", message: "App đang chạy — đã đưa ra trước." };
    }
    wakeViaUrlScheme();
    // Give the OS/app a moment to launch, then re-probe.
    for (let i = 0; i < 6; i += 1) {
      await new Promise((r) => setTimeout(r, 700));
      const found = await detect();
      if (found.online) {
        return { ok: true, state: "launched", message: "Đã mở app desktop." };
      }
    }
    return {
      ok: false,
      state: "unknown",
      message:
        "Không phát hiện app desktop. Hãy kiểm tra: app đã cài & đang chạy chưa, " +
        "và scheme campaio-zalo:// đã được đăng ký (mở app ít nhất một lần)."
    };
  }

  return { detect, activate, wakeViaUrlScheme, openApp, CANDIDATE_PORTS };
})();

if (typeof window !== "undefined") {
  window.CAMPAIO_DESKTOP = CAMPAIO_DESKTOP;
}
