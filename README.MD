
![Logo](Logo2.png)

# openconnect-ocproxy

This project aims to facilitate the setup of a secure VPN connection within a Docker container using the **OpenConnect** client, providing access to the VPN connection through a SOCKS5 proxy powered by **ocproxy**. It supports multiple VPN protocols, including Cisco's AnyConnect SSL VPN, and allows for establishing multiple simultaneous connections to supported VPNs, even those using the same protocol, with isolation at the Docker container level. Network traffic is routed through the VPN via the SOCKS5 proxy, enabling easy and secure tunneling of connections from your local environment or other applications through the VPN.

## Components Used

- [openconnect](https://gitlab.com/openconnect/openconnect) (v9.21; Alpine stable/edge package if available, otherwise built from the infradead release tarball or GitLab source tag)
- [ocproxy](https://github.com/matteosecli/ocproxy) fork (v2.0.0-rc.2; musl release binary if available, otherwise built from source)
## Getting Started

The container is a long-running service. It starts **without any credentials**, waits for you to authenticate from a terminal, and keeps running when the VPN session expires so you can simply log in again. No password or one-time code is put into Docker configuration by default.

### 1. Start the service

```bash
cd build
cp .env.example .env        # set OPENCONNECT_URL (nonsecret HTTPS URL) and, if needed, OPENCONNECT_PROTOCOL
sh build_and_run_locally.sh # builds the image and runs `docker compose up -d --build`
```

Or run the published image directly (SOCKS port published on host loopback only):

```bash
docker run -d --name openconnect-ocproxy --init \
  --user 12345:12345 --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /run/vpn:rw,nosuid,nodev,noexec,size=16m,mode=0700,uid=12345,gid=12345 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m,mode=1777 \
  -e OPENCONNECT_URL="https://vpn.example.org" \
  -e OPENCONNECT_PROTOCOL=anyconnect \
  -p 127.0.0.1:1080:9876/tcp \
  --restart unless-stopped \
  ghcr.io/matteosecli/openconnect-ocproxy:latest
```

Do not publish with a plain `-p 1080:9876`: that usually exposes the unauthenticated proxy on all host interfaces. The container needs no privileged mode, `NET_ADMIN`, TUN device or host networking.

### 2. Authenticate (and renew)

```bash
docker exec -it openconnect-ocproxy vpn-login   # real OpenConnect prompts: username, password, MFA...
docker exec openconnect-ocproxy vpn-status      # AUTH_REQUIRED | STARTING | CONNECTED | STOPPED
docker logs --tail 30 openconnect-ocproxy
```

When the helper prints `Session accepted`, you can close the terminal; the tunnel keeps running. When the gateway session expires (a reminder is logged 15 minutes before an advertised expiry), or the container restarts, run the same `vpn-login` command again. A failed or cancelled login leaves a working tunnel untouched; a successful one replaces it, which may interrupt open connections, so applications should retry. The session cookie is never persisted, so a container restart always requires a new login.

`vpn-login` only needs a real terminal and works for gateways that accept terminal (non-browser) authentication. Some identity providers require browser-only SSO, which is not supported yet.

### 3. Use the proxy

Configure applications for SOCKS5 with **remote DNS**, e.g.:

```bash
curl --noproxy '' --proxy socks5h://127.0.0.1:1080 --connect-timeout 10 --max-time 20 https://service.example.org/ -o /dev/null
```

Any HTTP status shows that HTTPS is reachable; it does not prove authorization. Some clients need a different scheme than `socks5h://` for remote DNS, so check each application. The proxy has no authentication: any local user (and other containers on the same Docker network) who can reach the port can use your VPN.

### Configuration

| Variable | Default / meaning |
|---|---|
| `OPENCONNECT_URL` | Required nonsecret HTTPS URL (no userinfo, query, fragment) |
| `OPENCONNECT_PROTOCOL` | `anyconnect` (see supported protocols below) |
| `OPENCONNECT_USER` | Optional username to prefill; the password stays interactive |
| `OPENCONNECT_SERVERCERT` / `OPENCONNECT_CAFILE` | Optional pinned certificate / private CA bundle path |
| `OPENCONNECT_USERAGENT` | Unset: OpenConnect 9.21 default. An override applies to both phases |
| `OPENCONNECT_ARGS_FILE` | Optional one-argument-per-line file of whitelisted options (see `build/arguments.example.txt`); the legacy `OPENCONNECT_OPTIONS` string is rejected |
| `VPN_DISABLE_DTLS` | `0` (DTLS allowed, TLS fallback) or `1` |
| `VPN_RECONNECT_TIMEOUT` | `600` s of OpenConnect retry after transport failure (does not extend an expired session) |
| `VPN_STARTUP_TIMEOUT` | `90` s |
| `VPN_EXPIRY_WARNING_SECONDS` | `900` s |
| `VPN_HEALTH_URL` | Optional HTTPS startup reachability probe through the SOCKS proxy; needs an image built with `--build-arg INSTALL_CURL=1` (curl is not installed by default to keep the image small) |
| `VPN_PROXY_PORT` | `9876` inside the container |

### Troubleshooting

- `vpn-status` shows `AUTH_REQUIRED` with a `reason` (`login-required`, `tunnel-exited-N`, `startup-failed`): run `vpn-login`.
- `docker logs` shows supervisor messages. The tunnel log is private (`/run/vpn/tunnel.log` in the tmpfs) and may contain connection details; do not share it blindly.
- The compose healthcheck reports unhealthy until the tunnel is `CONNECTED`; this does not restart the container.
- If the first connection is rejected on a Cisco gateway, try `OPENCONNECT_USERAGENT` as an explicit override.

### Environment compatibility mode (not recommended)

`AUTH_MODE=env` together with `OPENCONNECT_USER`, `OPENCONNECT_PASSWORD` and optionally `OPENCONNECT_MFA_CODE` makes the service authenticate once at startup with the legacy stdin sequence. **Docker stores these values in the container configuration, where authorized Docker users can read them; unsetting them inside the container does not change that.** One attempt is made (a one-time code is never retried); on failure the service stays in `AUTH_REQUIRED` and you can use `vpn-login`. Password variables alone never enable this mode.

### Development

```bash
for f in build/bin/* build/libexec/*; do bash -n "$f"; done
python3 tests/offline.py   # fake-VPN tests, no network or credentials
```

## Supported Protocols

OpenConnect supports the following VPN protocols:

- Cisco AnyConnect ``--protocol=anyconnect``
- Array Networks AG SSL VPN ``--protocol=array``
- Juniper SSL VPN ``--protocol=nc``
- Pulse Connect Secure ``--protocol=pulse``
- Palo Alto Networks GlobalProtect SSL VPN ``--protocol=gp``
- F5 Big-IP SSL VPN ``--protocol=f5``
- Fortinet Fortigate SSL VPN ``--protocol=fortinet``

For more details on these protocols and additional options, please refer to the OpenConnect [manual](https://www.infradead.org/openconnect/manual.html).
## Container Registry

You can find the Docker image for **openconnect-ocproxy** on the GitHub Container Registry. Pull the image using the following command:

```bash
docker pull ghcr.io/matteosecli/openconnect-ocproxy:latest
```

The image is published on the [GitHub Container Registry](https://github.com/matteosecli/openconnect-ocproxy/pkgs/container/openconnect-ocproxy) as a multi-arch (amd64/arm64) image. Besides `latest` and the image version (e.g. `2.0.0`), it is tagged with its components, e.g. `openconnect-9.21`, `ocproxy-2.0.0-rc.2`, `alpine-3.24.3`.

## License

This project is licensed under the [MIT](https://choosealicense.com/licenses/mit/) License.

