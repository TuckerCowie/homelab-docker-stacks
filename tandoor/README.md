# Tandoor Recipes Stack

Self-hosted recipe manager with Tailscale sidecar for secure access.

## Quick Start

1. **Copy environment template:**
   ```bash
   cp .env.template .env
   ```

2. **Generate secrets:**
   ```bash
   # Generate Django secret key
   openssl rand -base64 45
   
   # Generate PostgreSQL password
   openssl rand -base64 32
   ```

3. **Update .env file** with your generated secrets and Tailscale auth key

4. **Create data directories:**
   ```bash
   mkdir -p data/{db,staticfiles,mediafiles,tailscale}
   chown -R 1000:1000 data/
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

- **tandoor-db**: PostgreSQL database (port 5432, internal only)
- **tandoor-web**: Tandoor application (port 8080, internal only)
- **tandoor-nginx**: Internal reverse proxy (exposes to Tailscale network)
- **tandoor-tailscale**: Tailscale sidecar (provides secure network access)

## Access

After deployment:

1. **Find Tailscale IP:**
   ```bash
   docker exec tandoor-tailscale tailscale ip -4
   ```

2. **Access via Tailscale:**
   - Direct: `http://<tailscale-ip>`
   - Or configure your main reverse proxy to point to this IP

## Data Persistence

All data is stored in `./data/`:

- `data/db/` - PostgreSQL database
- `data/mediafiles/` - Uploaded recipe images
- `data/staticfiles/` - Static assets
- `data/tailscale/` - Tailscale state

## Backup

Data can be backed up by copying the `./data/` directory:

```bash
tar -czf tandoor-backup-$(date +%Y%m%d).tar.gz data/
```

Or use the automated backup script (see root README).

## Troubleshooting

**Can't access the web interface:**
- Check Tailscale IP: `docker exec tandoor-tailscale tailscale ip -4`
- Check logs: `docker compose logs -f tandoor-nginx`
- Verify containers are running: `docker compose ps`

**Database connection errors:**
- Wait for database to be healthy: `docker compose logs -f tandoor-db`
- Check credentials in .env match

**Nginx config issues:**
- Ensure nginx.conf exists in stack directory
- Restart nginx: `docker compose restart tandoor-nginx`

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

## Security Notes

- Never commit `.env` to git - it contains secrets
- Keep your Tailscale auth keys secure
- Regularly update Docker images for security patches
- The database is only accessible within the Docker network
