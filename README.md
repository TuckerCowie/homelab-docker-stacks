# Docker Stacks Repository

Production Docker Compose stacks with Tailscale sidecars for secure remote access.

## Repository Structure

```
.
├── tandoor/
│   ├── docker-compose.yml
│   ├── .env.template
│   ├── nginx.conf (not in git)
│   ├── data/ (not in git)
│   └── README.md
├── comfyui/
│   ├── docker-compose.yml
│   ├── .env.template
│   ├── nginx.conf (not in git)
│   ├── data/ (not in git)
│   └── README.md
├── media/
│   ├── docker-compose.yml
│   ├── .env.template
│   └── README.md
├── backup-to-nas.sh
└── README.md (this file)
```

## Quick Start

### Initial Setup

1. **Clone this repository:**
   ```bash
   cd /opt
   git clone <your-repo-url> stacks
   cd stacks
   ```

2. **For each stack:**
   ```bash
   cd <stack-name>
   cp .env.template .env
   # Edit .env with your secrets
   mkdir -p data
   docker compose up -d
   ```

### Individual Stack Setup

See the README.md in each stack directory for detailed instructions:

- [Tandoor](./tandoor/README.md) - Recipe manager
- [ComfyUI](./comfyui/README.md) - Stable Diffusion workflow manager
- [Media](./media/README.md) - Jellyfin, Sonarr, Radarr stack

## Architecture Pattern

All stacks follow a common pattern:

1. **Application container(s)** - The main service
2. **Internal nginx** - Reverse proxy for the application
3. **Tailscale sidecar** - Provides secure network access
4. **Data persistence** - All data in `./data/` directory

This provides:
- ✅ Secure remote access via Tailscale
- ✅ No port forwarding required
- ✅ Easy backups (just backup `./data/`)
- ✅ GitOps-friendly (compose files in git, data excluded)

## Tailscale Setup

Each stack needs a Tailscale auth key:

1. **Go to:** https://login.tailscale.com/admin/settings/keys
2. **Generate auth key** with these settings:
   - ✅ Reusable (for redeployments)
   - ✅ Ephemeral (optional - keys expire when container stops)
3. **Add to .env file** in each stack

## Backup Strategy

### Automated Backups

The included `backup-to-nas.sh` script backs up all stack data to your Synology NAS:

1. **Copy script:**
   ```bash
   cp backup-to-nas.sh /opt/stacks/
   chmod +x /opt/stacks/backup-to-nas.sh
   ```

2. **Configure NFS mount** (edit script if needed):
   ```bash
   nano /opt/stacks/backup-to-nas.sh
   # Update NFS_SERVER and NFS_EXPORT
   ```

3. **Test manually:**
   ```bash
   /opt/stacks/backup-to-nas.sh
   ```

4. **Add to crontab** (runs daily at 2 AM):
   ```bash
   (crontab -l 2>/dev/null; echo "0 2 * * * /opt/stacks/backup-to-nas.sh >> /var/log/nas-backup.log 2>&1") | crontab -
   ```

5. **View backup logs:**
   ```bash
   tail -f /var/log/nas-backup.log
   ```

### Manual Backups

For individual stacks:

```bash
cd /opt/stacks/<stack-name>
tar -czf ~/backup-$(date +%Y%m%d).tar.gz data/ docker-compose.yml
```

## Common Commands

### Manage All Stacks

```bash
# Start all stacks
for stack in tandoor comfyui media; do
  cd /opt/stacks/$stack && docker compose up -d
done

# Stop all stacks
for stack in tandoor comfyui media; do
  cd /opt/stacks/$stack && docker compose stop
done

# Update all stacks
for stack in tandoor comfyui media; do
  cd /opt/stacks/$stack && docker compose pull && docker compose up -d
done
```

### Manage Individual Stack

```bash
cd /opt/stacks/<stack-name>

# Start
docker compose up -d

# Stop
docker compose stop

# Restart
docker compose restart

# View logs
docker compose logs -f

# Update
docker compose pull
docker compose up -d

# Check status
docker compose ps
```

## Monitoring

### Check Tailscale IPs

```bash
# Tandoor
docker exec tandoor-tailscale tailscale ip -4

# ComfyUI
docker exec comfyui-tailscale tailscale ip -4

# Media stack
docker exec jellyfin-tailscale tailscale ip -4
```

### Check Resource Usage

```bash
# All containers
docker stats

# Specific stack
cd /opt/stacks/<stack-name>
docker compose ps
docker stats $(docker compose ps -q)
```

## Troubleshooting

### Container Won't Start

```bash
cd /opt/stacks/<stack-name>

# Check logs
docker compose logs -f

# Check configuration
docker compose config

# Restart fresh
docker compose down
docker compose up -d
```

### Can't Access Via Tailscale

```bash
# Check Tailscale is connected
docker exec <stack>-tailscale tailscale status

# Get Tailscale IP
docker exec <stack>-tailscale tailscale ip -4

# Test connectivity
curl http://<tailscale-ip>
```

### Data Not Persisting

```bash
# Check data directory exists and has correct permissions
ls -la /opt/stacks/<stack-name>/data/

# Fix permissions if needed
chown -R 1000:1000 /opt/stacks/<stack-name>/data/
```

## Security Best Practices

1. **Never commit `.env` files** - They contain secrets
2. **Keep Tailscale keys secure** - Rotate regularly
3. **Regular updates** - Run `docker compose pull` weekly
4. **Monitor access logs** - Check nginx logs for suspicious activity
5. **Use Tailscale ACLs** - Restrict access to specific devices/users
6. **Backup encryption** - Encrypt backups if stored off-site

## Portainer Integration

These stacks can be imported into Portainer while maintaining CLI control:

1. **Deploy via CLI first** (as documented above)
2. **Access Portainer** at http://your-server:9000
3. **Portainer will auto-discover** running containers
4. **To convert to stack in Portainer:**
   - Stacks → Add stack → Web editor
   - Paste compose file
   - Add environment variables
   - Deploy (will replace running containers)

Benefits:
- ✅ Visual monitoring in Portainer
- ✅ CLI control still works
- ✅ Best of both worlds

## Maintenance Schedule

Suggested maintenance tasks:

- **Daily:** Automated backups (via cron)
- **Weekly:** Check logs for errors
- **Weekly:** Update Docker images
- **Monthly:** Review disk usage
- **Monthly:** Test backup restoration
- **Quarterly:** Rotate Tailscale keys
- **Quarterly:** Review and update compose files

## Contributing

When making changes:

1. **Test locally first**
2. **Document in README**
3. **Update .env.template if needed**
4. **Never commit secrets**
5. **Use semantic commit messages**

## License

Private repository - all rights reserved.

## Support

For issues or questions:
- Check individual stack README files
- Review Docker Compose logs
- Check Tailscale status
- Verify NFS mounts (for media stack)
