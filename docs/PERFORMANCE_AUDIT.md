# Performance, Dependencies & Size Audit

## Completed Optimizations

- Waveform rendering caches decimated geometry (2,000 points per visible series
  by default) and re-decimates the current X range when zooming, so crosshair
  movement does not rebuild unchanged geometry while zoom still reveals stored
  high-resolution samples.
- Network and FFI data fetching runs in a background isolate. New user actions
  cancel the obsolete native request, invalidate its generation, and prevent a
  stale result from replacing newer settings.
- MDS connections are pooled and reused. Cancellation drains a response when it
  is safe to preserve the protocol boundary and closes the socket when a Full
  response cannot safely be retained.
- The SSH manager is reused globally, with active tunnels torn down on settings
  changes, avoiding per-fetch manager, thread, and socket leaks.
- All Dart-side FFI input pointers are freed with the Dart allocator; Rust-returned strings are freed only by the Rust `mds_free_string`, preventing leaks and cross-allocator undefined behavior.
- Rust release builds use `opt-level=3`, Thin LTO, a single codegen unit, `panic=abort`, and debug symbol stripping.
- Removed unused `tokio`, `rayon`, `reqwest`, `bytemuck`, `thiserror`, and `flutter_rust_bridge` direct dependencies; the login path no longer creates a Tokio runtime per call.
- Android cleans stale ABI staging before each build; single-ABI release APKs no longer accidentally carry Rust libraries from previous builds.
- Material Icons shrink from ~1.6 MB to ~7 KB in release builds via Flutter tree shaking.
- Toolbars, dialogs, waveform layouts, touch/trackpad/stylus gestures, theming,
  fonts, configuration persistence, metadata, cancellation, and networking are
  covered by 100 Flutter tests and 67 Rust tests.

## Current Measurements

On a local Flutter 3.44.7 / Rust 1.92.0 release build:

- Android universal APK: ~68.6 MB;
- macOS x64 + arm64 Universal APP: ~56.5 MB;
- Rust macOS Universal dylib: ~11 MB (~5 MB per architecture);
- iOS arm64 unsigned Runner.app: ~28.8 MB (varies with signing, symbols, and
  Flutter version).

These numbers are for regression comparison and are not fixed values across all systems. Universal bundles inherently contain two sets of machine code and cannot be directly compared to single-architecture packages.

## Dependency Strategy

Dart direct runtime dependencies are kept to six: FFI, fl_chart, provider,
file_picker, shared_preferences, and url_launcher. Each provides a concrete
product capability. The small Android/iOS directory channels use platform APIs
directly, avoiding a dependency and an additional Android NDK requirement for
one path lookup.

The Rust bridge depends only on internal crates, serde/JSON, and the cryptography libraries required for login and SSH. OpenSSL, libssh2, and zlib use vendored/static builds to reduce extra runtime installation requirements on target machines. The Flutter engine, GTK, and Apple/Windows/Android system runtimes are platform foundations that cannot be eliminated by removing Cargo packages.

## Items Still Requiring Real-Workload Evaluation

- Profile 1st, 50th, and 99th percentile frame times with DevTools on a target phone, an integrated-GPU Windows laptop, and a low-memory Linux device;
- Measure isolate serialization overhead, peak memory, and network throughput with real maximum shot data;
- Decide whether to switch from JSON FFI to a binary buffer or shared memory only after real bottlenecks are confirmed, rather than preemptively adding complexity;
- Establish baselines for cold start, first SSH handshake, rapid shot switching, and background resume, and persist them in a CI performance history;
- Check for leaks and power draw with native profiling tools on every release platform.

Aggressive micro-optimization without real data tends to sacrifice correctness, maintainability, and package compatibility. The current implementation prioritizes eliminating confirmed redundant computation, blocking, leaks, stale ABIs, and unused dependencies.
