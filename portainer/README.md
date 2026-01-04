# Portainer Stack

Self-hosted Docker management GUI with Tailscale sidecar for secure access.

## Quick Start

1. **Copy environment template:**
   ```bash
   cp .env.template .env
   ```

2. **Update .env file** with your Tailscale auth key

3. **Create data directories:**
   ```bash
   mkdir -p data/tailscale
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

- **portainer**: Docker management GUI (port 9000, internal only)
- **portainer-tailscale**: Tailscale sidecar (provides secure network access)

## Access

After deployment:

1. **Find Tailscale IP:**
   ```bash
   docker exec portainer-tailscale tailscale ip -4
   ```

2. **Access via Tailscale:**
   - Direct: `http://<tailscale-ip>`
   - Or configure your main reverse proxy to point to this IP

3. **Initial Setup:**
   - First access will prompt you to create an admin account
   - Choose "Docker" as the environment type
   - Portainer will automatically detect the local Docker socket

## Managing Stacks

Portainer can discover and manage your existing Docker stacks:

1. **View all containers:**
   - Navigate to "Containers" in the sidebar
   - All running containers from your stacks will be visible

2. **Import existing stacks:**
   - Go to "Stacks" → "Add stack"
   - Choose "Web editor" or "Git repository"
   - Paste your docker-compose.yml content
   - Add environment variables from your .env files
   - Deploy

3. **Monitor resources:**
   - View container stats, logs, and resource usage
   - Set up alerts for resource limits

4. **Update images:**
   - Use the "Pull image" feature
   - Or recreate containers with updated images

## Data Persistence

Portainer data is stored in a Docker volume:
- `portainer-data` volume - Contains Portainer configuration, users, and settings

**To backup:**
```bash
docker run --rm -v portainer_portainer-data:/data -v $(pwd):/backup alpine tar czf /backup/portainer-backup-$(date +%Y%m%d).tar.gz /data
```

**To restore:**
```bash
docker run --rm -v portainer_portainer-data:/data -v $(pwd):/backup alpine sh -c "cd /data && tar xzf /backup/portainer-backup-YYYYMMDD.tar.gz"
```

## Security Notes

- Portainer has full access to your Docker daemon via the socket mount
- Keep your Tailscale auth keys secure
- Use strong passwords for the Portainer admin account
- Consider enabling 2FA in Portainer settings
- Regularly update Portainer for security patches
- Access is restricted to Tailscale network only

## Features

- **Container Management:** Start, stop, restart, remove containers
- **Stack Management:** Deploy and manage Docker Compose stacks
- **Image Management:** Pull, push, remove images
- **Volume Management:** Create and manage volumes
- **Network Management:** View and manage Docker networks
- **Logs Viewer:** Real-time container logs
- **Stats Dashboard:** Resource usage monitoring
- **User Management:** Multi-user support with role-based access

## Troubleshooting

**Can't access the web interface:**
- Check Tailscale IP: `docker exec portainer-tailscale tailscale ip -4`
- Check logs: `docker compose logs -f portainer-nginx`
- Verify containers are running: `docker compose ps`

**Portainer can't see containers:**
- Verify Docker socket is mounted: `docker exec portainer ls -la /var/run/docker.sock`
- Check Portainer logs: `docker compose logs -f portainer`

**Nginx config issues:**
- Ensure nginx.conf exists in stack directory
- Restart nginx: `docker compose restart portainer-nginx`
- Check nginx logs: `docker compose logs -f portainer-nginx`

**Permission errors:**
- Ensure Docker socket is accessible
- On some systems, you may need to add the container to the docker group

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

**Backup Portainer data:**
```bash
docker run --rm -v portainer_portainer-data:/data -v $(pwd):/backup alpine tar czf /backup/portainer-backup-$(date +%Y%m%d).tar.gz /data
```

## Integration with Other Stacks

Portainer can manage all your other stacks:
- Import docker-compose.yml files from other stack directories
- Monitor all containers in one place
- Set up automated image updates
- Configure resource limits per stack
- View centralized logs

## Best Practices

1. **Regular Backups:** Backup Portainer data volume regularly
2. **Updates:** Keep Portainer updated for security patches
3. **Access Control:** Use role-based access for team members
4. **Monitoring:** Set up alerts for container failures
5. **Documentation:** Document stack configurations in Portainer notes


