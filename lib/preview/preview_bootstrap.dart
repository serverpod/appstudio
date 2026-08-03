/// Injected into the CEF preview so Flutter web actually starts.
///
/// `flutter run -d web-server` serves HTML as soon as the port is open, but
/// DWDS only sends RunRequest after attach — often before DDC finishes loading
/// `$dartRunMain`. If that request is missed the page stays blank after the
/// module loader finishes. This poller waits for `$dartRunMain`, gives DWDS a
/// short window to call it, then invokes it once as a fallback.
const previewBootstrapScript = r'''
(function () {
  if (window.__appStudioPreviewBootstrap) return;
  window.__appStudioPreviewBootstrap = true;

  var seenRunMainAt = null;
  var tries = 0;
  var maxTries = 240;

  function tick() {
    tries++;
    if (window.$dartMainExecuted) return;

    if (typeof window.$dartRunMain === 'function') {
      if (seenRunMainAt == null) seenRunMainAt = Date.now();
      // Prefer DWDS RunRequest; only kick main if it never arrives.
      if (Date.now() - seenRunMainAt >= 2500) {
        try {
          window.$dartRunMain();
        } catch (e) {
          console.error('App Studio preview bootstrap failed:', e);
        }
        return;
      }
    }

    if (tries < maxTries) {
      setTimeout(tick, 250);
    }
  }

  setTimeout(tick, 500);
})();
''';
