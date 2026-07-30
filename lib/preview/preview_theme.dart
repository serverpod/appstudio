import 'dart:ui';

/// Backdrop drawn behind the CEF surface, which composites with alpha.
///
/// Follows the previewed app's brightness (the preview toggle), not the shell's
/// — the pixels belong to the running app, not to App Studio.
Color previewBackdropColor(Brightness brightness) {
  return switch (brightness) {
    Brightness.dark => const Color(0xFF000000),
    Brightness.light => const Color(0xFFFFFFFF),
  };
}

/// JS injected into the CEF preview so Flutter web sees App Studio's theme.
///
/// Flutter web reads platform brightness from `matchMedia('(prefers-color-scheme: dark)')`.
String previewThemeShimScript({required bool isDark}) {
  final darkLiteral = isDark ? 'true' : 'false';
  return '''
(function () {
  function createFakeMql() {
    var listeners = window.__appStudioThemePatch.listeners;
    return {
      get matches() { return window.__appStudioThemePatch.isDark; },
      media: '(prefers-color-scheme: dark)',
      addEventListener: function (type, listener) {
        if (type === 'change') listeners.push(listener);
      },
      removeEventListener: function (type, listener) {
        var i = listeners.indexOf(listener);
        if (i >= 0) listeners.splice(i, 1);
      },
      addListener: function (listener) { this.addEventListener('change', listener); },
      removeListener: function (listener) { this.removeEventListener('change', listener); },
      onchange: null,
      dispatchEvent: function () { return true; },
    };
  }

  window.appStudioApplyPreviewTheme = function (isDark) {
    document.documentElement.style.colorScheme = isDark ? 'dark' : 'light';

    if (!window.__appStudioThemePatch) {
      window.__appStudioThemePatch = {
        isDark: isDark,
        mql: null,
        listeners: [],
      };
      var origMatchMedia = window.matchMedia.bind(window);
      window.matchMedia = function (query) {
        if (query === '(prefers-color-scheme: dark)') {
          if (!window.__appStudioThemePatch.mql) {
            window.__appStudioThemePatch.mql = createFakeMql();
          }
          return window.__appStudioThemePatch.mql;
        }
        return origMatchMedia(query);
      };
    }

    var patch = window.__appStudioThemePatch;
    var changed = patch.isDark !== isDark;
    patch.isDark = isDark;
    if (!changed) return;

    var event = { matches: isDark, media: '(prefers-color-scheme: dark)' };
    for (var i = 0; i < patch.listeners.length; i++) {
      try { patch.listeners[i](event); } catch (e) {}
    }
    if (patch.mql && patch.mql.onchange) {
      try { patch.mql.onchange(event); } catch (e) {}
    }
  };

  window.appStudioApplyPreviewTheme($darkLiteral);
})();
''';
}

String previewThemeApplyCall({required bool isDark}) {
  return 'window.appStudioApplyPreviewTheme(${isDark ? 'true' : 'false'});';
}
