# Jellyfin-ARR Stack

Self-hosted media server stack with Jellyfin, *ARR suite (Sonarr, Radarr, Prowlarr, Bazarr), qBittorrent with VPN, and Tailscale sidecar for secure access.

## Quick Start

1. **Copy environment template:**
   ```bash
   cp .env.template .env
   ```

2. **Generate secrets:**
   ```bash
   # Generate WireGuard private key (if you don't have one)
   # This is typically provided by your VPN provider
   ```

3. **Update .env file** with your Tailscale auth key and WireGuard private key

4. **Create config directories:**
   ```bash
   mkdir -p config/{jellyfin,qbittorrent,prowlarr,sonarr,radarr,bazarr,gluetun,tailscale}
   chown -R 1026:100 config/
   ```

5. **Deploy:**
   ```bash
   docker compose up -d
   ```

6. **Check logs:**
   ```bash
   docker compose logs -f
   ```

## Architecture

- **jellyfin**: Media server (port 8096)
- **sonarr**: TV show manager (port 8989)
- **radarr**: Movie manager (port 7878)
- **prowlarr**: Indexer manager (port 9696)
- **bazarr**: Subtitle manager (port 6767)
- **qbittorrent**: Torrent client (port 8080, routed through VPN)
- **gluetun**: VPN client (ProtonVPN WireGuard)
- **flaresolverr**: Cloudflare bypass service (port 8191)
- **jellyfin-tailscale**: Tailscale sidecar (provides secure network access)

## Network Configuration

The stack uses a custom network (`media-network`) with subnet `172.25.0.0/16` and integrates with Tailscale for secure remote access.

## Storage

The stack uses NFS volumes mounted from a Synology NAS:
- `synology-media`: Main media library (`:/volume1/Media`)
- `synology-torrents`: Torrent downloads (`:/volume1/Media/torrents`)

**Note:** Ensure your NAS is accessible at `100.98.188.126` and NFS is properly configured.

## VPN Configuration

qBittorrent routes through gluetun (ProtonVPN) for privacy:
- VPN provider: ProtonVPN
- VPN type: Wireguard
- Server location: Switzerland
- Port forwarding: Enabled

**To configure:**
1. Get your WireGuard private key from ProtonVPN
2. Add it to `.env` as `WIREGUARD_PRIVATE_KEY`
3. qBittorrent will automatically use the VPN connection

## Access

After deployment:

1. **Find Tailscale IP:**
   ```bash
   docker exec jellyfin-tailscale tailscale ip -4
   ```

2. **Access services via Tailscale:**
   - Jellyfin: `http://<tailscale-ip>:8096`
   - Sonarr: `http://<tailscale-ip>:8989`
   - Radarr: `http://<tailscale-ip>:7878`
   - Prowlarr: `http://<tailscale-ip>:9696`
   - Bazarr: `http://<tailscale-ip>:6767`
   - qBittorrent: `http://<tailscale-ip>:8080`

3. **Or configure your main reverse proxy** to point to the Tailscale IP

## Initial Setup

### Jellyfin
1. Access Jellyfin web UI
2. Complete the initial setup wizard
3. Add media libraries pointing to `/data/media`

### Sonarr
1. Access Sonarr web UI
2. Add Prowlarr as an indexer (Settings → Indexers)
3. Configure download client (qBittorrent)
4. Set root folders to `/data/media/TV` (or your preferred structure)

### Radarr
1. Access Radarr web UI
2. Add Prowlarr as an indexer (Settings → Indexers)
3. Configure download client (qBittorrent)
4. Set root folders to `/data/media/Movies` (or your preferred structure)

### Prowlarr
1. Access Prowlarr web UI
2. Add indexers (public or private trackers)
3. Configure FlareSolverr if needed (Settings → Apps → FlareSolverr)
4. Sync to Sonarr/Radarr (Settings → Apps)

### Bazarr
1. Access Bazarr web UI
2. Configure Sonarr/Radarr connections
3. Add subtitle providers
4. Configure languages and quality settings

### qBittorrent
1. Access qBittorrent web UI (default: admin/adminadmin)
2. Change default password immediately
3. Configure download paths:
   - Default save path: `/data/torrents`
   - Incomplete torrents: `/data/torrents/incomplete`
4. Verify VPN connection (check IP in Settings → Connection)

## Data Persistence

All configuration is stored in `./config/`:
- `config/jellyfin/` - Jellyfin configuration and metadata
- `config/sonarr/` - Sonarr database and settings
- `config/radarr/` - Radarr database and settings
- `config/prowlarr/` - Prowlarr database and settings
- `config/bazarr/` - Bazarr database and settings
- `config/qbittorrent/` - qBittorrent settings
- `config/gluetun/` - VPN client state
- `config/tailscale/` - Tailscale state

Media files are stored on the NFS-mounted Synology NAS.

## Hardware Acceleration

Jellyfin is configured with hardware acceleration support via `/dev/dri` device passthrough. This enables GPU-accelerated transcoding if your system has a compatible GPU.

**To verify:**
```bash
docker exec jellyfin ls -la /dev/dri
```

## Backup

Configuration can be backed up by copying the `./config/` directory:

```bash
tar -czf jellyfin-arr-backup-$(date +%Y%m%d).tar.gz config/
```

Media files on the NAS should be backed up separately.

Or use the automated backup script (see root README).

## Troubleshooting

**Can't access services:**
- Check Tailscale IP: `docker exec jellyfin-tailscale tailscale ip -4`
- Check logs: `docker compose logs -f [service-name]`
- Verify containers are running: `docker compose ps`

**VPN not working:**
- Check gluetun logs: `docker compose logs -f gluetun`
- Verify WireGuard key is correct in `.env`
- Check VPN connection: `docker exec gluetun wg show`

**NFS mount issues:**
- Verify NAS is accessible: `ping 100.98.188.126`
- Check NFS service on NAS is running
- Verify network connectivity to NAS

**qBittorrent not downloading:**
- Check VPN connection status
- Verify download paths are writable
- Check qBittorrent logs: `docker compose logs -f qbittorrent`

**Transcoding issues:**
- Verify GPU is accessible: `docker exec jellyfin ls -la /dev/dri`
- Check Jellyfin logs for hardware acceleration errors
- Ensure GPU drivers are installed on host

## Maintenance

**Update images:**
```bash
docker compose pull
docker compose up -d
```

**View logs:**
```bash
docker compose logs -f [service-name]
```

**Restart services:**
```bash
docker compose restart [service-name]
```

**Check VPN IP:**
```bash
docker exec gluetun wg show
```

## Security Notes

- Never commit `.env` to git - it contains secrets
- Keep your Tailscale auth keys secure
- Keep your WireGuard private key secure
- Regularly update Docker images for security patches
- All services are only accessible within the Docker network or via Tailscale
- qBittorrent routes through VPN for privacy - verify connection before downloading


