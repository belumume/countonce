{{flutter_js}}
{{flutter_build_config}}

// Inside the /try page (embed=1), the app may only move focus once the visitor has put focus in the app:
// by Tab, a tap, a click or a screen reader. Flutter focuses the first item of every new screen, which on
// its own page is right, but in a frame it would pull focus away from wherever the visitor is.
if (new URLSearchParams(location.search).get('embed') === '1') {
  const focus = HTMLElement.prototype.focus;
  HTMLElement.prototype.focus = function (options) {
    if (document.hasFocus()) return focus.call(this, options);
  };
}

// Every engine file and every fallback font comes from this site, never from gstatic.com,
// so the staff app also starts on networks that block Google.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'fallback-fonts/',
  },
});
