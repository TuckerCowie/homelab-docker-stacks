# Setup the entire ARR Stack

## **Current Status Check**

First, verify everything is running and the NFS mount is working:

```bash
cd /opt/stacks/media

# Check all containers are up
docker compose ps

# CRITICAL: Verify Jellyfin can see the NAS
docker exec jellyfin ls -la /data/media/
```

**You should see:** `movies`, `tv`, `music`, `torrents` folders

If not, we need to fix the NFS mount before proceeding.

---

## **Setup Order**

1. ✅ Gluetun (VPN) - Already running
2. **qBittorrent** - Configure download client
3. **Prowlarr** - Add indexers
4. **Sonarr** - Configure for TV shows
5. **Radarr** - Configure for movies
6. **Bazarr** - Configure for subtitles
7. **Jellyfin** - Add media libraries
8. **Jellyseerr** - Configure request manager

---

## **1. qBittorrent Setup**

**Access:** `http://<VM_IP>:8080`

### **First Login:**

1. **Username:** `admin`
2. **Password:** Check logs for temporary password:
   ```bash
   docker compose logs qbittorrent | grep -i password
   ```
   Look for: `The WebUI administrator password was not set. A temporary password is provided for this session: XXXXXXXX`

### **Initial Configuration:**

**Change Password:**
1. Click **Tools** (gear icon) → **Web UI** tab
2. **Authentication** section
3. Set a new password
4. Click **Save**

**Configure Download Paths:**
1. **Tools** → **Options** → **Downloads** tab
2. **Default Save Path:** `/data/torrents/complete`
3. **Keep incomplete torrents in:** Check the box
   - Path: `/data/torrents/incomplete`
4. **Run external program on torrent completion:** Leave unchecked for now
5. Click **Save**

**Create Categories (for Sonarr/Radarr):**
1. Right-click in the **Categories** pane (left sidebar)
2. **Add category**
   - Name: `tv`
   - Save path: `/data/torrents/complete/tv`
3. **Add category**
   - Name: `movies`
   - Save path: `/data/torrents/complete/movies`

**Connection Settings:**
1. **Tools** → **Options** → **Connection** tab
2. **Listening Port:** Leave default (usually `6881`)
3. **UNCHECK** "Use UPnP/NAT-PMP port forwarding from my router" (VPN handles this)
4. **Connections Limits:**
   - Global max connections: `500`
   - Max connections per torrent: `100`
5. Click **Save**

**Speed Settings (optional):**
1. **Tools** → **Options** → **Speed** tab
2. Set limits if needed (0 = unlimited)
3. Click **Save**

**Verify VPN is Working:**
1. Open https://ipleak.net in another tab
2. Copy the **Magnet link** from the torrent test
3. In qBittorrent, click **Add Torrent Link** (or File → Add Torrent Link)
4. Paste the magnet link → **Download**
5. Watch it start, then check the **Trackers** tab
6. The IP shown should be your **ProtonVPN Swiss IP**, NOT your home IP

---

## **2. Prowlarr Setup**

**Access:** `http://<VM_IP>:9696`

### **First Launch:**

**Set Authentication:**
1. **Settings** → **General** → **Security** section
2. **Authentication:** Select "Forms (Login Page)"
3. **Username:** Create one
4. **Password:** Create one
5. Click **Save**
6. Log back in with your credentials

### **Add FlareSolverr:**

1. **Settings** → **Indexers** tab → **Indexer Proxies** section
2. Click **+** button
3. Select **FlareSolverr**
4. **Name:** `FlareSolverr`
5. **Tags:** Leave blank (applies to all)
6. **Host:** `http://flaresolverr:8191`
7. Click **Test** (should show green checkmark)
8. Click **Save**

### **Add Indexers:**

These are reliable public indexers:

**YTS (Movies - small files):**
1. **Indexers** → **Add Indexer** → Search: `YTS`
2. Select **YTS** → Click **Save** (no config needed)

**EZTV (TV Shows):**
1. Search: `EZTV`
2. Select **EZTV** → Click **Save**

**Nyaa (Anime - if you want):**
1. Search: `Nyaa`
2. Select **Nyaa** → Click **Save**

**TorrentDownload (Mixed):**
1. Search: `TorrentDownload`
2. Select it → Click **Save**

**Test All Indexers:**
1. Click the **Test All** button (wrench icon at top)
2. All should show green checkmarks
3. If any fail, remove them or troubleshoot

**Manual Search Test:**
1. Click **Search** tab at top
2. Search for a popular movie/show
3. You should see results from multiple indexers

---

## **3. Sonarr Setup**

**Access:** `http://<VM_IP>:8989`

### **First Launch:**

**Set Authentication:**
1. **Settings** → **General** → **Security**
2. **Authentication:** Forms (Login Page)
3. Create username/password
4. **Save**

### **Add Root Folder:**

1. **Settings** → **Media Management**
2. **Root Folders** section
3. Click **Add Root Folder**
4. Enter: `/data/media/tv`
5. Click checkmark to save

### **Connect to qBittorrent:**

1. **Settings** → **Download Clients**
2. Click **+** → Select **qBittorrent**
3. Configure:
   - **Name:** `qBittorrent`
   - **Enable:** Checked
   - **Host:** `gluetun` (because qBittorrent uses gluetun's network)
   - **Port:** `8080`
   - **Username:** `admin`
   - **Password:** Your qBittorrent password
   - **Category:** `tv`
4. Click **Test** (should succeed)
5. Click **Save**

### **Connect to Prowlarr (Auto-sync Indexers):**

1. Go to **Prowlarr** (`http://<VM_IP>:9696`)
2. **Settings** → **Apps**
3. Click **+** → Select **Sonarr**
4. Configure:
   - **Prowlarr Server:** `http://prowlarr:9696`
   - **Sonarr Server:** `http://sonarr:8989`
   - **API Key:** Get from Sonarr → Settings → General → API Key (copy it)
5. Click **Test** → **Save**

Back in **Sonarr**, verify:
1. **Settings** → **Indexers**
2. You should now see all your Prowlarr indexers automatically added
3. If not, wait 30 seconds and refresh

### **Quality Profiles (optional customization):**

1. **Settings** → **Profiles**
2. Review/edit the default profiles
3. Common setup:
   - **Any** - accepts any quality (fastest downloads)
   - **HD-1080p** - only 1080p (better quality)
   - **HD-720p/1080p** - accepts both

### **Add a Test Show:**

1. Click **Series** (top menu) → **Add New**
2. Search for a popular show (e.g., "Breaking Bad")
3. Select it
4. Configure:
   - **Root Folder:** `/data/media/tv`
   - **Quality Profile:** HD-1080p (or your preference)
   - **Series Type:** Standard
   - **Season Folder:** Checked
5. **Add** button

**Monitor Episodes:**
1. After adding, click the show
2. Click **Automatic** or manually select episodes to monitor
3. Sonarr will start searching

**Watch it Work:**
1. **Activity** → **Queue** - Shows active downloads
2. Click the show → **History** - Shows search/download history

---

## **4. Radarr Setup**

**Access:** `http://<VM_IP>:7878`

### **Configure (Same as Sonarr):**

**Authentication:**
1. **Settings** → **General** → **Security**
2. Forms login, create credentials

**Root Folder:**
1. **Settings** → **Media Management** → **Root Folders**
2. Add: `/data/media/movies`

**Download Client:**
1. **Settings** → **Download Clients** → **+**
2. Select **qBittorrent**
   - **Host:** `gluetun`
   - **Port:** `8080`
   - **Username/Password:** Your qBittorrent credentials
   - **Category:** `movies`
3. Test → Save

**Connect to Prowlarr:**
1. Go to **Prowlarr** → **Settings** → **Apps** → **+**
2. Select **Radarr**
   - **Prowlarr Server:** `http://prowlarr:9696`
   - **Radarr Server:** `http://radarr:7878`
   - **API Key:** Get from Radarr → Settings → General
3. Test → Save

**Verify Indexers:**
1. Radarr → **Settings** → **Indexers**
2. Should show all Prowlarr indexers

**Add a Test Movie:**
1. **Movies** → **Add New**
2. Search for a popular movie
3. Configure:
   - **Root Folder:** `/data/media/movies`
   - **Quality Profile:** HD-1080p
   - **Add Movie**

---

## **5. Bazarr Setup**

**Access:** `http://<VM_IP>:6767`

### **First Launch Wizard:**

1. **Languages:** Add your preferred subtitle languages (English, etc.)
2. **Provider Credentials:** Skip for now (can add later)
3. Click **Next** through wizard

**Set Authentication:**
1. **Settings** → **General** → **Security**
2. Authentication method: Forms
3. Create credentials

### **Connect to Sonarr:**

1. **Settings** → **Sonarr**
2. **Enabled:** Check
3. **Address:** `http://sonarr:8989`
4. **API Key:** Get from Sonarr → Settings → General
5. Click **Test** → **Save**

### **Connect to Radarr:**

1. **Settings** → **Radarr**
2. **Enabled:** Check
3. **Address:** `http://radarr:7878`
4. **API Key:** Get from Radarr → Settings → General
5. Click **Test** → **Save**

### **Add Subtitle Providers:**

1. **Settings** → **Providers**
2. Click **+** and add:
   - **OpenSubtitles** (free, requires account)
   - **Subscene**
   - **Addic7ed**
3. Configure credentials if required
4. **Save**

**Set Languages:**
1. **Settings** → **Languages**
2. **Languages Filter:** Add English (or your preferences)
3. **Save**

Bazarr will now automatically download subtitles for shows/movies added to Sonarr/Radarr.

---

## **6. Jellyfin Setup**

**Access:** `http://<VM_IP>:8096`

### **Initial Setup Wizard:**

**Language Selection:**
- Select your language → **Next**

**Create Admin Account:**
- **Username:** Create one
- **Password:** Create one
- **Next**

**Add Media Libraries:**

**Add TV Library:**
1. **Add Media Library**
2. **Content type:** Shows
3. **Display name:** TV Shows
4. **Folders:** Click **+** → Browse to `/data/media/tv` → **OK**
5. **Next** through the settings (defaults are fine)
6. **OK**

**Add Movies Library:**
1. **Add Media Library**
2. **Content type:** Movies
3. **Display name:** Movies
4. **Folders:** `/data/media/movies`
5. **OK**

**Add Music Library (optional):**
1. **Content type:** Music
2. **Folders:** `/data/media/music`
3. **OK**

**Preferred Metadata Language:**
- Select your language
- **Next**

**Remote Access:**
- Leave defaults
- **Next**

**Finish:**
- Click **Finish**

### **Enable Hardware Transcoding:**

1. **Dashboard** (top right) → **Playback**
2. **Transcoding** section
3. **Hardware acceleration:** Select **Intel QuickSync (QSV)**
4. **Enable hardware encoding for:** Check all (H264, HEVC, VP9, etc.)
5. **Save**

### **Scan Libraries:**

1. **Dashboard** → **Libraries**
2. Click **Scan All Libraries**
3. Wait for it to find your media (any files in movies/tv folders)

---

## **7. Jellyseerr Setup**

**Access:** `http://<VM_IP>:5055`

### **Initial Setup Wizard:**

**Welcome Screen:**
- Click **Get Started**

**Create Admin Account:**
1. **Username:** Create one
2. **Email:** (optional)
3. **Password:** Create a strong password
4. Click **Next**

**Configure Jellyfin:**
1. **Server Name:** `Jellyfin` (or your preference)
2. **Server URL:** `http://jellyfin:8096`
3. **API Key:** 
   - Go to Jellyfin → **Dashboard** → **API Keys** → **New API Key**
   - Name it "Jellyseerr" → **Save**
   - Copy the API key and paste it here
4. Click **Test Connection** (should show green checkmark)
5. Click **Next**

**Configure Sonarr:**
1. **Server Name:** `Sonarr`
2. **Server URL:** `http://sonarr:8989`
3. **API Key:** Get from Sonarr → **Settings** → **General** → **API Key**
4. **Base URL:** Leave blank (unless you configured one)
5. Click **Test Connection**
6. Click **Next**

**Configure Radarr:**
1. **Server Name:** `Radarr`
2. **Server URL:** `http://radarr:7878`
3. **API Key:** Get from Radarr → **Settings** → **General** → **API Key**
4. **Base URL:** Leave blank (unless you configured one)
5. Click **Test Connection**
6. Click **Next**

**Configure Default Settings:**
1. **Default Server (4K):** Leave as "None" (unless you have a 4K setup)
2. **Enable 4K Requests:** Uncheck (unless you want 4K)
3. **Movie Request Limit:** Set a limit (e.g., `10` per user)
4. **Series Request Limit:** Set a limit (e.g., `20` per user)
5. Click **Next**

**Finish Setup:**
- Click **Complete Setup**

### **Additional Configuration:**

**User Management:**
1. **Settings** → **Users**
2. You can invite users via email or create local accounts
3. Set permissions for each user (Admin, Auto-Approve, etc.)

**Notification Settings (optional):**
1. **Settings** → **Notifications**
2. Configure email, Discord, Slack, etc. if desired
3. Set up notifications for when requests are approved/available

**Request Settings:**
1. **Settings** → **General**
2. **Auto-Request Movies:** Enable if you want automatic approval
3. **Auto-Request Series:** Enable if you want automatic approval
4. **Partial Season Requests:** Enable if you want users to request individual seasons

**Quality Profiles:**
1. **Settings** → **Services** → **Sonarr** or **Radarr**
2. **Default Quality Profile:** Select your preferred profile (e.g., "HD-1080p")
3. **Default Root Folder:** Should auto-detect from Sonarr/Radarr

### **Test Jellyseerr:**

1. **Discover** tab → Search for a movie or TV show
2. Click **Request** on a title
3. If auto-approval is enabled, it should immediately send to Sonarr/Radarr
4. If not, approve it in **Requests** → **Pending**
5. Watch it appear in Sonarr/Radarr and start downloading

---

## **Verify Everything Works**

### **Test Download Flow:**

1. **Sonarr** → Add a TV show → Monitor an episode
2. **Activity** → Watch it search Prowlarr indexers
3. See it send to qBittorrent
4. **qBittorrent** → See download start
5. Check VPN IP in qBittorrent trackers (should be Swiss)
6. When complete, Sonarr moves it to `/data/media/tv/`
7. **Jellyfin** → Scan library → Show appears

### **Check Each Service:**

```bash
# View logs if anything isn't working
docker compose logs -f sonarr
docker compose logs -f radarr
docker compose logs -f qbittorrent
```

---

## **Quick Reference - Service URLs**

```
Jellyfin:     http://<VM_IP>:8096
Jellyseerr:   http://<VM_IP>:5055
qBittorrent:  http://<VM_IP>:8080
Sonarr:       http://<VM_IP>:8989
Radarr:       http://<VM_IP>:7878
Prowlarr:     http://<VM_IP>:9696
Bazarr:       http://<VM_IP>:6767
FlareSolverr: http://<VM_IP>:8191
```
