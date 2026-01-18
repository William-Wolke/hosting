# Self-Hosted Infrastructure

Personal self-hosted services running on Docker Swarm.

## Architecture

**Docker Swarm** was chosen over plain Docker Compose for:
- Native secrets management (no plaintext env files for sensitive data)
- Config management (deploy config files without rebuilding images)
- Rolling updates and health-check-based deployments
- Single-node setup today, easy to scale later if needed

**Exception:** `gluetun-qb` runs as Docker Compose because Swarm doesn't support `network_mode: container:...` which is required to route torrent traffic through the VPN container.

## Services

| Service | Purpose | Why This One |
|---------|---------|--------------|
| **Caddy** | Reverse proxy, TLS | Automatic HTTPS, simple config, built-in DuckDNS support |
| **CrowdSec** | Security/WAF | Community-driven threat intelligence, Caddy integration |
| **Authentik** | SSO/Identity | Self-hosted alternative to Auth0, supports OIDC/SAML |
| **Vaultwarden** | Password manager | Lightweight Bitwarden-compatible server |
| **WireGuard (wg-easy)** | VPN | Simple UI for WireGuard, easy client management |
| **Technitium** | DNS server | Ad-blocking DNS for VPN clients |
| **SearXNG** | Search engine | Privacy-respecting metasearch, no tracking |
| **Mealie** | Recipe manager | Clean UI, supports OIDC, good recipe import |
| **Uptime Kuma** | Monitoring | Simple uptime monitoring with notifications |
| **Copyparty** | File sharing | Lightweight file server with web UI |
| **qBittorrent** | Torrent client | Runs through gluetun VPN, VueTorrent UI |
| **Prowlarr** | Indexer manager | Manages torrent indexers for *arr apps |
| **Gluetun** | VPN client | Routes container traffic through Mullvad VPN |
| **Red-DiscordBot** | Discord bot | Modular Python bot |
| **Crafty** | Minecraft server | Web-based Minecraft server manager |
| **DuckDNS** | Dynamic DNS | Free DDNS, updates IP automatically |
| **Tasks.md** | Task management | Markdown-based task lists |

## Network Architecture

```
Internet
    │
    ▼
┌─────────┐
│  Caddy  │◄─── TLS termination, CrowdSec filtering
└────┬────┘
     │ proxy-net (overlay)
     ▼
┌─────────────────────────────────┐
│  Services (Swarm)               │
│  mealie, vaultwarden, searxng,  │
│  authentik, uptime-kuma, etc.   │
└─────────────────────────────────┘
     │
     │ proxy-net
     ▼
┌─────────────────────────────────┐
│  gluetun (Compose)              │
│  └─► qbittorrent, prowlarr      │──► Mullvad VPN
│      flaresolverr               │
└─────────────────────────────────┘
```

## Usage

```bash
# Deploy a service
make <service>

# Check status
make swarm-status

# Manage secrets
make check-secrets
make create-secrets

# gluetun-qb (docker-compose)
make gluetun-qb
```

See `make help` for all commands.
