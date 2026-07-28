(() => {
  'use strict';

  const message = document.getElementById('mdslens-startup-message');
  const help = document.getElementById('mdslens-startup-help');
  let ready = false;

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
