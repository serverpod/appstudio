/// Empties the caches that live *inside* the page, before the preview reloads.
///
/// A hard reload defeats the HTTP cache and nothing else. A service worker and
/// its Cache Storage entries are page state: they survive the navigation and
/// then answer the new document's requests out of the previous build, which is
/// exactly the "the preview is showing old code" symptom a hard reload is
/// supposed to rule out. Flutter web in debug does not register one, but the
/// previewed app is the user's and may.
///
/// Sets [previewCachesPurgedFlag] when it is done — the work is asynchronous
/// and `executeJavaScript` cannot await it, so the caller polls for the flag.
const previewCachePurgeScript = r'''
(function () {
  window.__appStudioCachesPurged = false;
  var jobs = [];
  try {
    if (navigator.serviceWorker) {
      jobs.push(
        navigator.serviceWorker
          .getRegistrations()
          .then(function (regs) {
            return Promise.all(regs.map(function (r) { return r.unregister(); }));
          })
      );
    }
  } catch (e) {}
  try {
    if (window.caches) {
      jobs.push(
        caches.keys().then(function (keys) {
          return Promise.all(keys.map(function (k) { return caches.delete(k); }));
        })
      );
    }
  } catch (e) {}
  // A failure here must not hold the reload up: stale assets are the thing we
  // are trying to avoid, and not reloading at all is worse than reloading with
  // one of these still in place.
  Promise.all(jobs.map(function (j) { return j.catch(function () {}); }))
    .then(function () { window.__appStudioCachesPurged = true; })
    .catch(function () { window.__appStudioCachesPurged = true; });
})();
''';

/// The flag [previewCachePurgeScript] raises once it has finished.
const previewCachesPurgedFlag = 'window.__appStudioCachesPurged === true';
