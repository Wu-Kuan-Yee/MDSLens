# Private-network Web Gateway deployment

This design is not specific to a NAS vendor. It works on an internal server
that can run the MDSLens Gateway and reach the trusted API, MDS and SSH
destinations.

Public and private-network visitors use the same HTTPS URL and the same
MDSLens UI:

```text
Public DNS  -> GitHub Pages static application
Private DNS -> internal HTTPS reverse proxy -> MDSLens Web Gateway
```

Only the network result differs. Where the private Gateway is unreachable,
Login, SSH and live waveform requests retain their normal progress UI and end
with `Connection failed.`. The application does not expose deployment details.

## Supported server environments

The published multi-architecture container supports:

- x86-64 Linux servers and virtual machines;
- ARM64 Linux servers and virtual machines;
- NAS platforms that support standard Linux containers, including Synology;
- Docker-compatible container hosts on either architecture.

The container isolates the application from the host distribution, so the same
image can run on Debian, Ubuntu, Fedora, RHEL-compatible systems, Arch Linux and
other current distributions with a compatible container runtime.

The release archive also contains a native Linux Gateway for its matching
architecture. It can run without Docker under an unprivileged service account.
Container deployment is recommended because it provides the simplest
reproducible isolation.

The published image does not cover 32-bit, LoongArch, RISC-V, FreeBSD or a host
without a Linux-compatible container runtime. Windows and macOS can run the
Linux image through a supported container VM, but a maintained Linux server or
VM is the recommended production host.

## Requirements

- Docker Engine with the Compose plugin, or a compatible container platform.
- A controlled domain or subdomain, for example `scope.example.org`.
- A trusted TLS certificate for that exact hostname.
- An internal DNS service or router capable of overriding one host record.
- Network reachability from the Gateway to the approved API, MDS and SSH hosts.

No inbound Internet route to the private server is required. Do not configure a
router port-forward, public tunnel or public reverse proxy to the Gateway.

## Start or update the container

Download and extract the matching `mdslens-web-linux-<arch>.tar.gz` release:

```sh
cd deploy/container
cp .env.example .env
./install.sh
```

Before starting it, edit `MDSLENS_ALLOWED_HOSTS` in `.env`. This is the outbound
allowlist for user-entered API URLs, signal servers and SSH hosts.

The default `latest` image follows the highest MDSLens version tag. Pin
`MDSLENS_IMAGE_TAG` to a release such as `v0.1.0` when deterministic rollback is
more important than automatic updates.

The Compose project:

- runs as a non-root UID/GID;
- has a read-only root filesystem and memory-backed `/tmp`;
- drops all Linux capabilities and forbids privilege escalation;
- mounts no host directories or container-management socket;
- uses a private bridge network;
- limits memory and process count;
- publishes the Gateway on host loopback only.

The first GitHub Container Registry package may need to be changed to **Public**
once in the repository package settings. Public packages can then be pulled
without storing GitHub credentials on the internal server.

## Add HTTPS on the same host

The container listens on `127.0.0.1:18088`, so an HTTPS reverse proxy must run
on the same host by default. Keeping the clear-text hop on loopback prevents
other internal devices from bypassing HTTPS.

Example Caddy configuration:

```caddyfile
scope.example.org {
    reverse_proxy 127.0.0.1:18088
}
```

Example nginx location:

```nginx
server {
    listen 443 ssl;
    server_name scope.example.org;

    ssl_certificate     /etc/ssl/scope.example.org/fullchain.pem;
    ssl_certificate_key /etc/ssl/scope.example.org/privkey.pem;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:18088;
    }
}
```

Apache, HAProxy, Traefik and a NAS reverse proxy are also suitable. Proxy every
path, including `/gateway/v1/`, and preserve the Gateway's security headers.
Keep secure cookies enabled.

If the reverse proxy must run on another machine, explicitly bind the container
port to a dedicated private interface and use host firewall rules that allow
only the reverse-proxy address. Do not bind it to every interface without such
rules.

## Configure split DNS

Configure the hostname differently on public and private DNS:

```text
Public:
scope.example.org -> GitHub Pages

Private:
scope.example.org -> internal Gateway/reverse-proxy address
```

Configure the same hostname as the GitHub Pages custom domain and enable
**Enforce HTTPS**. Release Pages artifacts use relative resource paths, so they
work at both the normal repository URL and a custom-domain root.

Internal clients must use the internal DNS service. Browser-level encrypted DNS
that bypasses the organization resolver may receive the public record instead;
the UI still works, but live operations will fail as they would on any
unreachable network.

## Firewall and isolation

Recommended host and network policy:

1. Allow inbound HTTPS only from actual internal client CIDRs.
2. Do not expose container port 18088 beyond host loopback.
3. Allow Gateway egress only to required DNS and approved API/MDS/SSH
   destinations and ports.
4. Do not mount user files, backups, private keys, Docker Socket or host root
   paths into the container.
5. Keep the host, container runtime and image updated.
6. Never set `MDSLENS_WEB_ALLOW_ANY_HOST=1`.

For a high-value internal network, run the container in a dedicated VM or VLAN
with no access to unrelated systems.

## Verify

From a public network:

- the complete application opens;
- local configuration and settings work;
- Login, SSH Test and live data requests end with `Connection failed.`.

From the private network:

```sh
curl https://scope.example.org/gateway/v1/health
```

The response must contain `"ok":true`, and valid server operations can succeed.
Both clients should see the same MDSLens release and UI.

## Platform-specific notes

- Synology: follow the
  [Container Manager and reverse-proxy example](SYNOLOGY_WEB_DEPLOYMENT.md).
- Ordinary Linux: use Docker Compose plus Caddy or nginx as shown above.
- Existing Kubernetes platform: deploy the published x64/ARM64 image as a
  non-root, read-only workload and expose it only through an internal HTTPS
  Ingress. The supplied Compose limits should be translated into the
  corresponding SecurityContext, NetworkPolicy and resource limits.
