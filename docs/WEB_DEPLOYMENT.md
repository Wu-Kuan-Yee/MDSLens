# MDSLens Web / PWA Deployment

MDSLens Web is a self-contained Flutter WebAssembly application served by the
MDSLens Web Gateway. End users open one HTTPS URL and use the application
directly; they do not install Flutter, Rust, MDSplus, SSH tools, browser
extensions, or a local companion process.

The browser performs rendering, interaction, configuration editing, local
settings, file selection, drag-and-drop, and downloads. Browser sandbox rules
do not permit raw MDSip sockets or SSH, so the same-origin gateway performs
only those network operations and keeps API tokens and tunnel state in an
HttpOnly server session. A live data connection therefore still needs the
gateway; an already cached PWA can open and edit local configurations offline,
but cannot obtain new MDS data while the gateway or MDS service is unavailable.

## Build

Install Flutter 3.44.7, Rust 1.92, a C/C++ compiler, CMake, Perl, NASM and
`curl`, then run:

```sh
./scripts/build_web.sh
```

This creates:

```text
build/dist/mdslens-web-<platform>-<x64|arm64>.tar.gz
└── mdslens-web-<platform>-<arch>/
    ├── mdslens-web-gateway
    ├── web/
    ├── README.md
    ├── LICENSE
    └── NOTO_SANS_SC_LICENSE.txt
```

Tagged releases publish Linux x64 and ARM64 server archives. Local macOS builds
use a `mdslens-web-macos-<arch>.tar.gz` name. The build deliberately uses
`--no-web-resources-cdn`; CanvasKit/Skwasm, the
application WASM, icons and the Chinese fallback font are inside `web/`.

Each Linux archive also contains a hardened Compose deployment under
`deploy/container`. For a deployment in which the public UI is available to
everyone but server operations work only on the private network, follow the
[private Gateway and split-DNS guide](PRIVATE_GATEWAY_DEPLOYMENT.md). Synology
is one supported example rather than a requirement.

## Run locally

```sh
tar -xzf mdslens-web-linux-x64.tar.gz
cd mdslens-web-linux-x64
MDSLENS_WEB_BIND=127.0.0.1:8088 \
MDSLENS_WEB_ROOT=web \
MDSLENS_WEB_SECURE_COOKIE=0 \
./mdslens-web-gateway
```

Then open `http://127.0.0.1:8088/`. The insecure-cookie switch is only for
localhost development.

Do not double-click `web/index.html` or open the source template directly.
Browsers deliberately block WebAssembly modules, generated resources and
Service Workers loaded from a `file://` URL. The page now explains this instead
of remaining blank, but the application must still be served over HTTP/HTTPS.

## GitHub Pages

`https://wu-kuan-yee.github.io/MDSLens/` is the public MDSLens product website.
It introduces the application and links to the repository and release
downloads; it is not the deployable MDSLens Web application.

Tagged releases continue to publish the complete, self-contained Web frontend
and Gateway archives. Deploy one of those archives on an HTTPS server to run
the actual Web application. GitHub Pages is a static host and cannot execute
`mdslens-web-gateway`.

## Production

Run the gateway as an unprivileged service and put an HTTPS reverse proxy such
as Caddy, nginx, Apache or a cloud load balancer in front of it:

```sh
MDSLENS_WEB_BIND=127.0.0.1:8088 \
MDSLENS_WEB_ROOT=/opt/mdslens/web \
MDSLENS_WEB_ALLOWED_ORIGINS=https://mdslens.example.org \
MDSLENS_WEB_ALLOWED_HOSTS=202.127.204.12,202.127.204.26,202.127.204.41 \
/opt/mdslens/mdslens-web-gateway
```

Proxy every path, including `/gateway/v1/`, to `127.0.0.1:8088`. Keep
`MDSLENS_WEB_SECURE_COOKIE` at its default (`true`) and terminate TLS at the
proxy. Preserve the gateway's CSP, COOP and COEP response headers. Do not add a
wildcard CORS header.

`MDSLENS_WEB_ALLOWED_HOSTS` is an outbound allowlist for API, MDS and SSH
destinations. Add every trusted server used by deployed configurations; never
set it to an untrusted user-controlled range. For a controlled private
deployment only, `MDSLENS_WEB_ALLOW_ANY_HOST=1` disables that protection.

The gateway stores sessions only in memory. Restarting it logs users out,
which avoids persisting tokens or passwords to disk. For multiple gateway
instances, use sticky sessions; do not copy authentication tokens into
JavaScript-readable storage.

## Browser storage and files

- Non-sensitive settings and the last working layout use browser application
  storage and remain available after reload.
- Passwords, API tokens and SSH credentials are not written to browser local
  storage, IndexedDB, cookies readable by JavaScript, or exported configs.
- Login state uses a Secure, HttpOnly, SameSite=Strict cookie. The actual API
  token remains inside the gateway process.
- Open configuration uses the browser file picker or drag-and-drop.
- Save configuration and data export use browser downloads.
- Browser sandboxing intentionally prevents silent reads or writes to arbitrary
  system paths.

## Verification

```sh
./scripts/verify_web_bundle.sh \
  rust/target/release/mdslens-web-gateway build/web
```

The check verifies the static entry point, local WASM renderer, session cookie
attributes and gateway health endpoint. Production deployments should also
monitor `/gateway/v1/health` through the reverse proxy.
