# BTRFS Backup Timer - Quick Reference

## Enable Automation (Add to Your Config)

```nix
# In ~/nixos-config/hosts/nixos/default.nix or modules/services/backup.nix
{
  services.btrfs-backup = {
    enable = true;
    sshHost = "target";
    remotePath = "/mnt/storage/snapshots";
    
    subvolumes = { /* your subvolumes */ };
    
    # AUTOMATION
    enableTimer = true;
    timerSchedule = "02:00";  # Daily at 2 AM
    
    localRetentionDays = 7;
    remoteRetentionDays = 30;
  };
}
```

Rebuild: `sudo nixos-rebuild switch --flake .#nixos`

## Common Schedule Formats

| Schedule | Description |
|----------|-------------|
| `"daily"` | Once per day at midnight |
| `"02:00"` | Daily at 2:00 AM |
| `"hourly"` | Every hour |
| `"*-*-* 00/6:00:00"` | Every 6 hours |
| `"Mon *-*-* 03:00:00"` | Every Monday at 3 AM |
| `"Mon..Fri *-*-* 02:00:00"` | Weekdays at 2 AM |

## Essential Commands

### Check Timer Status
```bash
systemctl status btrfs-backup.timer
systemctl list-timers btrfs-backup.timer
```

### Trigger Backup Manually
```bash
sudo systemctl start btrfs-backup.service
```

### View Logs
```bash
# Follow live
sudo journalctl -u btrfs-backup.service -f

# Last 50 entries
sudo journalctl -u btrfs-backup.service -n 50

# Since yesterday
sudo journalctl -u btrfs-backup.service --since yesterday

# Today's backups only
sudo journalctl -u btrfs-backup.service --since today
```

### Check Backup File
```bash
sudo tail -50 /var/log/btrfs-backup.log
```

### Timer Control
```bash
# Start timer
sudo systemctl start btrfs-backup.timer

# Stop timer
sudo systemctl stop btrfs-backup.timer

# Restart timer
sudo systemctl restart btrfs-backup.timer
```

## Verify Timer is Working

1. **Check timer is active:**
   ```bash
   systemctl status btrfs-backup.timer
   # Should show: Active: active (waiting)
   ```

2. **Check next run time:**
   ```bash
   systemctl list-timers btrfs-backup.timer
   # Shows when it will run next
   ```

3. **Trigger a test run:**
   ```bash
   sudo systemctl start btrfs-backup.service
   sudo journalctl -u btrfs-backup.service -f
   ```

4. **Verify success:**
   ```bash
   sudo tail -20 /var/log/btrfs-backup.log | grep "Backup Summary"
   ```

## Check Recent Backups

```bash
# View recent snapshots
ls -lt /snapshots/*/20* | head -20

# Count snapshots
find /snapshots -type d -name "*-20*" | wc -l

# Find today's snapshots
find /snapshots -type d -name "*-$(date +%Y%m%d)*"

# Check remote snapshots
ssh target "find /mnt/storage/snapshots -type d -name '*-20*' | head -10"
```

## Troubleshooting

### Backup not running?
```bash
# Check timer is enabled
systemctl is-enabled btrfs-backup.timer

# Check for errors
sudo journalctl -u btrfs-backup.timer -u btrfs-backup.service --since today
```

### Backup failing in timer but works manually?
```bash
# Test SSH as the service runs it
sudo bash -c 'sudo -u samir ssh -F /home/samir/.ssh/config target "echo test"'
```

### Check what went wrong
```bash
# View full service logs
sudo journalctl -u btrfs-backup.service -n 100

# Check system logs for related errors
sudo journalctl -xe | grep btrfs-backup
```

## Recommended Schedules

**Desktop/Laptop:** 
- Schedule: `"20:00"` or `"22:00"`
- Keep: 3 local, 14 remote

**Workstation:**
- Schedule: `"02:00"`
- Keep: 7 local, 30 remote

**Server:**
- Schedule: `"hourly"` or `"*-*-* 00/6:00:00"`
- Keep: 14 local, 90 remote

## One-Liner Checks

```bash
# Is timer running?
systemctl is-active btrfs-backup.timer

# When did it last run?
systemctl show btrfs-backup.service -p ActiveExitTimestamp --value

# Was last run successful?
systemctl show btrfs-backup.service -p Result --value

# When will it run next?
systemctl list-timers btrfs-backup.timer --no-pager | grep btrfs-backup

# Quick status check
echo "Timer: $(systemctl is-active btrfs-backup.timer)" && \
echo "Last run: $(systemctl show btrfs-backup.service -p ActiveExitTimestamp --value)" && \
echo "Next run: $(systemctl list-timers btrfs-backup.timer --no-pager | grep btrfs-backup | awk '{print $1, $2}')"
```

## Complete Example Config

```nix
{
  services.btrfs-backup = {
    enable = true;
    
    # Connection
    sshHost = "target";
    remotePath = "/mnt/storage/snapshots";
    
    # What to backup
    subvolumes = {
      Desktop = "/home/samir/Desktop";
      Documents = "/home/samir/Documents";
      Music = "/home/samir/Music";
      Pictures = "/home/samir/Pictures";
      Videos = "/home/samir/Videos";
      sites = "/home/samir/sites";
    };
    
    # Automation
    enableTimer = true;
    timerSchedule = "02:00";  # 2 AM daily
    
    # Retention
    localRetentionDays = 7;
    remoteRetentionDays = 30;
  };
}
```

## After Changes

Always rebuild after config changes:
```bash
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#nixos
systemctl status btrfs-backup.timer
```
