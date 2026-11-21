# Podman Volume Backup

## Purpose

The systemd timer runs `/usr/local/sbin/backup-podman-volumes.sh` nightly at 02:00.
The script backs up Podman volumes labeled `backup=true`, verifies the archives,
and sends a success or failure heartbeat to Uptime Kuma.

## Add a Uptime Kuma Push monitor

1. In Uptime Kuma, add a **Push** monitor named `Podman volume backup`.
2. Set the interval to **24 hours**.
3. Add an appropriate grace period.
4. Configure the desired notification method.
5. Copy the generated Push URL.

## Configure the Push URL

Create a root-only environment file:

```bash
sudo install -d -m 0700 /etc/podman-volume-backup
sudo nano /etc/podman-volume-backup.env
```
Add
```
UPTIME_KUMA_PUSH_URL=https://uptime.example.com/api/push/MONITOR_TOKEN
```
And set permissions
```bash
sudo chown root:root /etc/podman-volume-backup.env
sudo chmod 600 /etc/podman-volume-backup.env
```
