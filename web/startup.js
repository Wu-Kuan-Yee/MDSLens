(() => {
  'use strict';

  const message = document.getElementById('mdslens-startup-message');
  const help = document.getElementById('mdslens-startup-help');
  let ready = false;

  // Flutter owns secondary-click handling inside its rendering surface.
  // Suppress the browser's native context menu there so the gesture reaches
  // the application's panel menu on every Web renderer.
  document.addEventListener('contextmenu', (event) => {
    if (event.target instanceof Element && event.target.closest('flutter-view')) {
      event.preventDefault();
    }
  });

  // Local Font Access is intentionally permission-gated by browsers. Expose a
  // small, typed boundary to Dart when the browser supports it. MDSLens loads
  // only the selected face, avoiding the very large memory cost of importing
  // every installed font into the Flutter renderer.
  window.mdslensLocalFontFamilies = async () => {
    if (typeof window.queryLocalFonts !== 'function') return [];
    const fonts = await window.queryLocalFonts();
    return [...new Set(fonts.map((font) => font.family).filter(Boolean))]
      .sort((left, right) => left.localeCompare(right));
  };
  window.mdslensLocalFontBytes = async (family) => {
    if (typeof window.queryLocalFonts !== 'function') return null;
    const fonts = await window.queryLocalFonts();
    const candidates = fonts.filter((font) => font.family === family);
    if (!candidates.length) return null;
    const face = candidates.find((font) => /regular|normal/i.test(font.style || ''))
      || candidates[0];
    return (await face.blob()).arrayBuffer();
  };

  const showFailure = (text, command) => {
    if (ready) return;
    message.textContent = text;
    if (command) {
      help.textContent = command;
      help.hidden = false;
    }
  };

  if (window.location.protocol === 'file:') {
    showFailure(
      'This file cannot run directly from file://. Browsers block WebAssembly modules, generated resources, and Service Workers in this context. Serve the built web directory through MDSLens Web Gateway or another HTTP/HTTPS server.',
      './scripts/build_web.sh\nMDSLENS_WEB_BIND=127.0.0.1:8088 MDSLENS_WEB_ROOT=build/web MDSLENS_WEB_SECURE_COOKIE=0 rust/target/release/mdslens-web-gateway',
    );
    return;
  }

  const markReady = () => {
    if (document.querySelector('flutter-view')) {
      ready = true;
      window.setTimeout(() => document.body.classList.add('mdslens-ready'), 120);
      return true;
    }
    return false;
  };

  if (!markReady()) {
    const observer = new MutationObserver(() => {
      if (markReady()) observer.disconnect();
    });
    observer.observe(document.documentElement, {childList: true, subtree: true});
  }

  window.addEventListener('error', (event) => {
    const detail = event.message ? ` (${event.message})` : '';
    showFailure(
      `MDSLens Web failed to load${detail}. Refresh the page. If the problem persists, confirm that the page is served over HTTP/HTTPS and that all deployed resources are present.`,
    );
  });

  window.setTimeout(() => {
    showFailure(
      'MDSLens Web is taking too long to load. Check the network, browser console, and deployed files.',
    );
  }, 30000);
})();
