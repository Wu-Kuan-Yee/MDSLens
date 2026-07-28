# Synology private-gateway deployment

This deployment gives public and private-network visitors the same MDSLens Web
application and interaction model. The only observable difference is whether a
server operation connects:

- public DNS serves the static application from GitHub Pages;
- private DNS resolves the same HTTPS hostname to Synology;
- Synology serves the matching application and same-origin Web Gateway;
- Login, SSH Tunnel and live MDS requests succeed only where the private
  Gateway is reachable.

The Synology service is not published to the Internet. Do not create a router
port-forward, Cloudflare Tunnel, QuickConnect application link or public reverse
proxy for it.

## Requirements

- A Synology model supported by Container Manager, using x86-64 or ARM64.
- A domain or subdomain you control, for example `scope.example.org`.
- A trusted TLS certificate for that exact hostname.
- Control of the private DNS used by clients on the internal network.
- The GitHub Pages custom domain configured to use the same hostname.

## 1. Start the container

Download the matching `mdslens-web-linux-<arch>.tar.gz` release and extract it.
The archive contains `deploy/container`. Review `.env.example`, especially
`MDSLENS_ALLOWED_HOSTS`, then run:

```sh
cd deploy/container
cp .env.example .env
./install.sh
```

The default image tag is `latest`. For a reproducible deployment, set
`MDSLENS_IMAGE_TAG` in `.env` to a release such as `v0.1.0`.

Alternatively, create a Container Manager Project from `compose.yaml` and enter
the same variables in its environment settings. The project deliberately:

- runs as UID/GID 65532 rather than root;
- uses a read-only root filesystem and a small in-memory `/tmp`;
- drops every Linux capability and forbids privilege escalation;
- uses a private bridge network;
- limits memory and process count;
- publishes port 18088 on `127.0.0.1` only;
- mounts no Synology shared folders or Docker socket.

The first published GitHub Container Registry package may need its visibility
changed to **Public** once in the repository package settings. No registry login
is required on Synology after that.

## 2. Configure Synology HTTPS

Import or issue a trusted certificate for `scope.example.org` under
**Control Panel > Security > Certificate**.

Create a rule under **Control Panel > Login Portal > Advanced > Reverse Proxy**:

| Setting | Value |
| --- | --- |
| Source protocol | HTTPS |
| Source hostname | `scope.example.org` |
| Source port | `443` |
| Destination protocol | HTTP |
| Destination hostname | `127.0.0.1` |
| Destination port | `18088` |
| HSTS | Enabled |

Do not expose DSM ports 5000/5001 or container port 18088 through the router.
In Synology Firewall, allow the actual internal client CIDRs and deny other
sources for this reverse-proxy entry.

## 3. Configure split DNS

Configure the public DNS and private DNS differently:

```text
Public DNS:
scope.example.org -> GitHub Pages

Private DNS:
scope.example.org -> private Synology address, for example 192.168.1.20
```

The private record can be provided by the router, an internal DNS server,
Pi-hole, AdGuard Home or Synology DNS Server. Clients must use that DNS server;
encrypted DNS configured directly in a browser may bypass the private record.

Verify from an external and an internal client:

```sh
nslookup scope.example.org
```

The external result must not reveal or route to Synology. The internal result
must be the private Synology address.

## 4. Configure GitHub Pages

Set `scope.example.org` as the repository's GitHub Pages custom domain and
enable **Enforce HTTPS**. Release builds use a relative Web base path, so the
same static artifact works at both the standard project URL and a custom-domain
root.

The `latest` container image and GitHub Pages deployment are produced from the
same highest version tag. This keeps the public and private UI synchronized.

## 5. Verify behavior

From outside the private network:

- the complete UI opens normally;
- local settings and configuration workflows remain available;
- Login, SSH Test and live waveform requests follow their normal progress UI
  and end with an ordinary `Connection failed.` result.

From inside the private network:

- the same URL and UI open;
- `/gateway/v1/health` returns JSON with `"ok": true`;
- valid Login, SSH and waveform operations can succeed.

Never use `MDSLENS_WEB_ALLOW_ANY_HOST=1`. Add only trusted API, MDS and SSH
destinations to `MDSLENS_ALLOWED_HOSTS`.

## Updating and rollback

For `latest`:

```sh
cd deploy/container
./install.sh
```

The script pulls the current image and recreates the project without changing
`.env`. To roll back, set `MDSLENS_IMAGE_TAG` to the earlier release tag and run
the script again. Gateway sessions live only in memory, so an update signs
users out but does not remove browser-local settings or configurations.
