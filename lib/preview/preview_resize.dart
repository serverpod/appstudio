/// Nudge Flutter web to relayout immediately after the CEF viewport changes.
const previewResizeNotifyScript = '''
(function () {
  window.dispatchEvent(new Event('resize'));
  if (window.visualViewport) {
    window.visualViewport.dispatchEvent(new Event('resize'));
  }
  window.dispatchEvent(new Event('orientationchange'));
})();
''';

String previewResizeNotifyCall() => previewResizeNotifyScript;
