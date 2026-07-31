(() => {
  "use strict";

  const root = document.documentElement;
  const themeControl = document.querySelector(".theme-control");
  const themeButtons = Array.from(
    document.querySelectorAll("[data-theme-option]"),
  );
  const colorScheme = matchMedia("(prefers-color-scheme: dark)");
  let manuallySelectedTheme = false;

  function applyTheme(theme) {
    root.dataset.theme = theme;
    root.dataset.themeMode = theme;
    themeControl.dataset.themeChoice = theme;
    themeButtons.forEach((button) => {
      const selected = button.dataset.themeOption === theme;
      button.classList.toggle("active", selected);
      button.setAttribute("aria-pressed", String(selected));
    });
  }

  applyTheme(colorScheme.matches ? "dark" : "light");
  colorScheme.addEventListener("change", (event) => {
    if (!manuallySelectedTheme) {
      applyTheme(event.matches ? "dark" : "light");
    }
  });
  themeButtons.forEach((button) => {
    button.addEventListener("click", () => {
      manuallySelectedTheme = true;
      applyTheme(button.dataset.themeOption);
    });
  });

  const brand = document.querySelector(".brand");
  brand.addEventListener("click", (event) => {
    if (
      event.button === 0 &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.shiftKey &&
      !event.altKey
    ) {
      event.preventDefault();
      window.location.reload();
    }
  });

  let ambientFrame = 0;
  window.addEventListener(
    "pointermove",
    (event) => {
      cancelAnimationFrame(ambientFrame);
      ambientFrame = requestAnimationFrame(() => {
        root.style.setProperty("--pointer-x", `${event.clientX}px`);
        root.style.setProperty("--pointer-y", `${event.clientY}px`);
      });
    },
    { passive: true },
  );

  const canvas = document.querySelector(".waveform-demo canvas");
  const context = canvas.getContext("2d", { alpha: false });
  const modeSwitch = document.querySelector(".mode-switch");
  const modeButtons = Array.from(
    document.querySelectorAll("[data-waveform-option]"),
  );
  const state = {
    cursor: 0.58,
    darkTheme: root.dataset.theme === "dark",
    mode: "point",
    pan: 0,
    zoom: 1,
  };
  let drag = null;
  let drawFrame = 0;

  // The demo is a self-contained interaction surface. In particular, mobile
  // browsers must not turn a vertical waveform gesture into page scrolling.
  // Keep this listener in addition to CSS `touch-action: none` for older
  // WebKit versions and embedded browsers whose Pointer Events support is
  // incomplete.
  document.querySelector(".waveform-demo").addEventListener(
    "touchmove",
    (event) => event.preventDefault(),
    { passive: false },
  );

  function clamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value));
  }

  function sample(x) {
    const ramp = clamp((x - 0.17) / 0.28, 0, 1);
    const drop = 1 - clamp((x - 0.7) / 0.04, 0, 1);
    return 0.16 + ramp * drop * 0.68 + Math.sin(x * 38) * 0.012;
  }

  function worldAt(screenX, pan, zoom) {
    return 0.5 + pan + (screenX - 0.5) / zoom;
  }

  function scheduleDraw() {
    if (drawFrame) return;
    drawFrame = requestAnimationFrame(() => {
      drawFrame = 0;
      draw();
    });
  }

  function draw() {
    const rect = canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;

    const ratio = window.devicePixelRatio || 1;
    const pixelWidth = Math.max(1, Math.round(rect.width * ratio));
    const pixelHeight = Math.max(1, Math.round(rect.height * ratio));
    if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
      canvas.width = pixelWidth;
      canvas.height = pixelHeight;
    }
    context.setTransform(ratio, 0, 0, ratio, 0, 0);

    const width = rect.width;
    const height = rect.height;
    const toolbarHeight = 44;
    const panelHeight = height - toolbarHeight;
    const curveColor = state.darkTheme ? "#60d7fa" : "#078db7";
    const background = state.darkTheme ? "#0a1016" : "#e9f0f5";
    const panelBackground = state.darkTheme ? "#0d151e" : "#f7fafc";
    const gridColor = state.darkTheme
      ? "rgba(185, 204, 218, 0.09)"
      : "rgba(55, 77, 92, 0.11)";
    const crosshairColor = state.darkTheme
      ? "rgba(232, 241, 246, 0.46)"
      : "rgba(32, 55, 68, 0.38)";
    const markerColor = state.darkTheme ? "#f4f7f8" : "#142633";

    context.clearRect(0, 0, width, height);
    context.fillStyle = background;
    context.fillRect(0, 0, width, height);
    context.fillStyle = panelBackground;
    context.fillRect(0, toolbarHeight, width, panelHeight);

    context.strokeStyle = gridColor;
    context.lineWidth = 1;
    for (let column = 1; column < 7; column += 1) {
      const x = (width * column) / 7;
      context.beginPath();
      context.moveTo(x, toolbarHeight);
      context.lineTo(x, toolbarHeight + panelHeight);
      context.stroke();
    }
    for (let row = 1; row < 5; row += 1) {
      const y = toolbarHeight + (panelHeight * row) / 5;
      context.beginPath();
      context.moveTo(0, y);
      context.lineTo(width, y);
      context.stroke();
    }

    context.strokeStyle = curveColor;
    context.lineWidth = 2;
    context.beginPath();
    for (let index = 0; index <= 320; index += 1) {
      const screenX = index / 320;
      const value = sample(worldAt(screenX, state.pan, state.zoom));
      const x = screenX * width;
      const y = toolbarHeight + panelHeight - value * panelHeight;
      if (index === 0) context.moveTo(x, y);
      else context.lineTo(x, y);
    }
    context.shadowColor = curveColor;
    context.shadowBlur = state.darkTheme ? 8 : 4;
    context.stroke();
    context.shadowBlur = 0;

    if (state.mode === "point") {
      const x = state.cursor * width;
      const value = sample(worldAt(state.cursor, state.pan, state.zoom));
      const y = toolbarHeight + panelHeight - value * panelHeight;
      context.strokeStyle = crosshairColor;
      context.lineWidth = 1;
      context.beginPath();
      context.moveTo(x, toolbarHeight);
      context.lineTo(x, toolbarHeight + panelHeight);
      context.moveTo(0, y);
      context.lineTo(width, y);
      context.stroke();

      context.beginPath();
      context.arc(x, y, 4.5, 0, Math.PI * 2);
      context.fillStyle = panelBackground;
      context.fill();
      context.strokeStyle = markerColor;
      context.lineWidth = 1.5;
      context.stroke();
    }
  }

  function pointerCoordinates(event) {
    const coalesced = event.getCoalescedEvents?.();
    const latest =
      coalesced && coalesced.length > 0
        ? coalesced[coalesced.length - 1]
        : event;
    return { clientX: latest.clientX, clientY: latest.clientY };
  }

  function updatePoint(event) {
    const bounds = canvas.getBoundingClientRect();
    const point = pointerCoordinates(event);
    state.cursor = clamp(
      (point.clientX - bounds.left) / Math.max(1, bounds.width),
      0.02,
      0.98,
    );
    scheduleDraw();
  }

  canvas.addEventListener("pointerdown", (event) => {
    const point = pointerCoordinates(event);
    if (event.pointerType !== "touch") {
      canvas.setPointerCapture(event.pointerId);
    }
    drag = {
      pointerId: event.pointerId,
      pointerType: event.pointerType,
      startX: point.clientX,
      startY: point.clientY,
      startPan: state.pan,
      startZoom: state.zoom,
    };
    if (state.mode === "point") updatePoint(event);
  });

  canvas.addEventListener("pointermove", (event) => {
    if (state.mode === "point") {
      updatePoint(event);
      return;
    }
    if (!drag || drag.pointerId !== event.pointerId) return;

    const bounds = canvas.getBoundingClientRect();
    const point = pointerCoordinates(event);
    if (state.mode === "move") {
      const delta = (point.clientX - drag.startX) / Math.max(1, bounds.width);
      state.pan = clamp(
        drag.startPan - delta / drag.startZoom,
        -0.7,
        0.7,
      );
      scheduleDraw();
      return;
    }

    const zoomDistance =
      drag.pointerType === "touch"
        ? point.clientX - drag.startX
        : drag.startY - point.clientY;
    const nextZoom = clamp(
      drag.startZoom * Math.exp(zoomDistance * 0.012),
      1,
      8,
    );
    const anchor = clamp(
      (drag.startX - bounds.left) / Math.max(1, bounds.width),
      0,
      1,
    );
    const anchorWorld = worldAt(anchor, drag.startPan, drag.startZoom);
    state.zoom = nextZoom;
    state.pan = clamp(
      anchorWorld - 0.5 - (anchor - 0.5) / nextZoom,
      -0.7,
      0.7,
    );
    scheduleDraw();
  });

  function endInteraction(event) {
    if (!drag || drag.pointerId !== event.pointerId) return;
    drag = null;
    if (canvas.hasPointerCapture(event.pointerId)) {
      canvas.releasePointerCapture(event.pointerId);
    }
  }

  canvas.addEventListener("pointerup", endInteraction);
  canvas.addEventListener("pointercancel", endInteraction);
  window.addEventListener("pointerup", endInteraction, { passive: true });
  window.addEventListener("pointercancel", endInteraction, { passive: true });
  canvas.addEventListener("lostpointercapture", () => {
    drag = null;
  });
  canvas.addEventListener(
    "wheel",
    (event) => {
      event.preventDefault();
      if (state.mode !== "zoom") return;
      const bounds = canvas.getBoundingClientRect();
      const anchor = clamp(
        (event.clientX - bounds.left) / Math.max(1, bounds.width),
        0,
        1,
      );
      const anchorWorld = worldAt(anchor, state.pan, state.zoom);
      const normalizedDelta =
        event.deltaMode === 1
          ? event.deltaY * 16
          : event.deltaMode === 2
            ? event.deltaY * bounds.height
            : event.deltaY;
      const nextZoom = clamp(
        state.zoom * Math.exp(-clamp(normalizedDelta, -120, 120) * 0.002),
        1,
        8,
      );
      state.zoom = nextZoom;
      state.pan = clamp(
        anchorWorld - 0.5 - (anchor - 0.5) / nextZoom,
        -0.7,
        0.7,
      );
      scheduleDraw();
    },
    { passive: false },
  );
  canvas.addEventListener("dblclick", () => {
    state.pan = 0;
    state.zoom = 1;
    scheduleDraw();
  });

  function chooseMode(mode) {
    state.mode = mode;
    modeSwitch.dataset.waveformMode = mode;
    canvas.className = `mode-${mode}`;
    modeButtons.forEach((button) => {
      button.classList.toggle(
        "active",
        button.dataset.waveformOption === mode,
      );
    });
    scheduleDraw();
  }

  modeButtons.forEach((button) => {
    button.addEventListener("click", () => {
      chooseMode(button.dataset.waveformOption);
    });
  });

  const resizeObserver = new ResizeObserver(scheduleDraw);
  resizeObserver.observe(canvas);
  const themeObserver = new MutationObserver(() => {
    state.darkTheme = root.dataset.theme === "dark";
    scheduleDraw();
  });
  themeObserver.observe(root, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });
  scheduleDraw();
})();
