# ComfyUI Stack

Self-hosted Stable Diffusion workflow manager with Tailscale sidecar for secure access.

## Quick Start

1. **Copy environment template:**
   ```bash
   cp .env.template .env
   ```

2. **Update .env file** with your Tailscale auth key

3. **Create data directories:**
   ```bash
   mkdir -p data/{models,output,input,custom_nodes,user,tailscale}
   chown -R 1000:1000 data/
   ```

4. **Deploy:**
   ```bash
   docker compose up -d
   ```

5. **Check logs:**
   ```bash
   docker compose logs -f
   ```

## Architecture

- **comfyui**: Main ComfyUI application (port 8188, internal only)
- **comfyui-nginx**: Internal reverse proxy (exposes to Tailscale network)
- **comfyui-tailscale**: Tailscale sidecar (provides secure network access)

## GPU Support

The compose file includes NVIDIA GPU support (commented out by default).

**To enable GPU acceleration:**

1. **Install NVIDIA Container Toolkit:**
   ```bash
   # Ubuntu/Debian
   distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
   curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
   curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
     sudo tee /etc/apt/sources.list.d/nvidia-docker.list
   
   sudo apt-get update
   sudo apt-get install -y nvidia-container-toolkit
   sudo systemctl restart docker
   ```

2. **Uncomment GPU section** in docker-compose.yml:
   ```yaml
   deploy:
     resources:
       reservations:
         devices:
           - driver: nvidia
             count: all
             capabilities: [gpu]
   ```

3. **Redeploy:**
   ```bash
   docker compose up -d
   ```

## Access

After deployment:

1. **Find Tailscale IP:**
   ```bash
   docker exec comfyui-tailscale tailscale ip -4
   ```

2. **Access via Tailscale:**
   - Direct: `http://<tailscale-ip>`
   - Or configure your main reverse proxy to point to this IP

## Data Persistence

All data is stored in `./data/`:

- `data/models/` - Stable Diffusion models (checkpoints, LoRAs, VAEs, etc.)
- `data/output/` - Generated images
- `data/input/` - Input images for img2img workflows
- `data/custom_nodes/` - Custom ComfyUI nodes and extensions
- `data/user/` - User settings and workflows
- `data/tailscale/` - Tailscale state

## Installing Models

Download models to `./data/models/` following this structure:

```
data/models/
├── checkpoints/          # Main SD models (.safetensors or .ckpt)
├── loras/               # LoRA models
├── vae/                 # VAE models
├── embeddings/          # Textual inversions
├── controlnet/          # ControlNet models
└── upscale_models/      # Upscaling models
```

**Example - download a checkpoint:**
```bash
cd data/models/checkpoints/
wget https://example.com/stable-diffusion-model.safetensors
```

## Backup

Models can be large (10GB+). Consider backing up separately:

```bash
# Backup outputs and workflows (small, frequent)
tar -czf comfyui-work-backup-$(date +%Y%m%d).tar.gz data/{output,user,custom_nodes}

# Backup models (large, infrequent)
tar -czf comfyui-models-backup-$(date +%Y%m%d).tar.gz data/models
```

Or use the automated backup script (see root README).

## Troubleshooting

**Can't access the web interface:**
- Check Tailscale IP: `docker exec comfyui-tailscale tailscale ip -4`
- Check logs: `docker compose logs -f comfyui-nginx`
- Verify containers are running: `docker compose ps`

**GPU not detected:**
- Verify NVIDIA drivers: `nvidia-smi`
- Check container toolkit: `docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi`
- Uncomment GPU section in docker-compose.yml

**Out of memory errors:**
- Add `--lowvram` flag to ComfyUI environment
- Use smaller models or lower resolution
- Monitor GPU memory: `nvidia-smi -l 1`

**Nginx WebSocket errors:**
- Ensure nginx.conf exists with WebSocket upgrade headers
- Check nginx logs: `docker compose logs -f comfyui-nginx`

## Performance Tips

- **Use GPU:** Essential for reasonable generation times
- **Model format:** .safetensors loads faster than .ckpt
- **Resolution:** Start with 512x512, increase gradually
- **Batch size:** Increase for faster total throughput (but uses more VRAM)

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

**Clean up old outputs:**
```bash
# Careful! This deletes all generated images
rm -rf data/output/*
```

## Security Notes

- Never commit `.env` to git - it contains secrets
- Keep your Tailscale auth keys secure
- ComfyUI runs without authentication by default - use Tailscale ACLs or add auth
- Large model downloads can fill disk space quickly - monitor usage
