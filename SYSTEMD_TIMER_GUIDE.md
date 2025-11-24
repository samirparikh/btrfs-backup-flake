# Automating BTRFS Backups with Systemd Timers

Your flake already includes full systemd timer support! You just need to enable it in your configuration.

## Quick Start - Enable Automatic Backups

Edit your backup configuration (either in `~/nixos-config/hosts/nixos/default.nix` or `~/nixos-config/modules/services/backup.nix`):

```nix
{
  services.btrfs-backup = {
    enable = true;
    sshHost = "target";
    remotePath = "/mnt/storage/snapshots";
    
    # Your subvolumes configuration
    subvolumes = {
      Desktop = "/home/samir/Desktop";
      Documents = "/home/samir/Documents";
      Music = "/home/samir/Music";
      Pictures = "/home/samir/Pictures";
      Videos = "/home/samir/Videos";
      sites = "/home/samir/sites";
    };
    
    # Enable automatic backups
    enableTimer = true;
    timerSchedule = "daily";  # Run once per day at midnight
    
    # Optional: Adjust retention policies
    localRetentionDays = 7;   # Keep local snapshots for 7 days
    remoteRetentionDays = 30; # Keep remote snapshots for 30 days
  };
}
```

Then rebuild:

```bash
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#nixos
```

## Schedule Options

The `timerSchedule` option accepts systemd calendar format:

### Common Schedules

```nix
# Daily at midnight
timerSchedule = "daily";

# Daily at specific time (2 AM)
timerSchedule = "02:00";

# Twice daily (2 AM and 2 PM)
timerSchedule = "*-*-* 02,14:00:00";

# Every 6 hours
timerSchedule = "*-*-* 00/6:00:00";

# Hourly
timerSchedule = "hourly";

# Every Monday at 3 AM
timerSchedule = "Mon *-*-* 03:00:00";

# Weekdays at 2 AM
timerSchedule = "Mon..Fri *-*-* 02:00:00";

# First day of month at 1 AM
timerSchedule = "*-*-01 01:00:00";
```

### Advanced Examples

```nix
# Multiple times per day
timerSchedule = "*-*-* 00:00,06:00,12:00,18:00:00";

# Every 4 hours during work hours
timerSchedule = "*-*-* 08,12,16:00:00";

# Weekend backups only
timerSchedule = "Sat,Sun *-*-* 02:00:00";
```

## Managing the Timer

### View Timer Status

```bash
# List all timers (find btrfs-backup)
systemctl list-timers

# Check specific timer status
systemctl status btrfs-backup.timer

# See when it last ran and when it will run next
systemctl list-timers btrfs-backup.timer
```

### Manual Control

```bash
# Start timer (enable scheduling)
sudo systemctl start btrfs-backup.timer

# Stop timer (disable scheduling)
sudo systemctl stop btrfs-backup.timer

# Manually trigger a backup immediately
sudo systemctl start btrfs-backup.service

# View service logs
sudo journalctl -u btrfs-backup.service

# Follow logs in real-time
sudo journalctl -u btrfs-backup.service -f

# View logs since last boot
sudo journalctl -u btrfs-backup.service -b

# View last 50 log entries
sudo journalctl -u btrfs-backup.service -n 50
```

### Check Timer Configuration

```bash
# View timer unit details
systemctl cat btrfs-backup.timer

# View service unit details
systemctl cat btrfs-backup.service
```

## Complete Configuration Example

Here's a full example with all options:

```nix
{
  services.btrfs-backup = {
    enable = true;
    
    # SSH Configuration
    sshHost = "target";
    sshUser = "samir";
    sshConfig = "/home/samir/.ssh/config";
    sshTimeout = 10;
    
    # Paths
    remotePath = "/mnt/storage/snapshots";
    localSnapshotPath = "/snapshots";
    
    # What to backup
    subvolumes = {
      Desktop = "/home/samir/Desktop";
      Documents = "/home/samir/Documents";
      Music = "/home/samir/Music";
      Pictures = "/home/samir/Pictures";
      Videos = "/home/samir/Videos";
      sites = "/home/samir/sites";
    };
    
    # Retention policies
    localRetentionDays = 7;    # Keep local snapshots for 1 week
    remoteRetentionDays = 30;  # Keep remote snapshots for 1 month
    
    # Automation
    enableTimer = true;
    timerSchedule = "02:00";   # Daily at 2 AM
    
    # Logging
    logFile = "/var/log/btrfs-backup.log";
  };
}
```

## Monitoring Backups

### Check Backup Success

```bash
# View recent backup runs
sudo journalctl -u btrfs-backup.service --since "1 week ago" | grep "Backup Summary"

# Check for failures
sudo journalctl -u btrfs-backup.service --since "1 week ago" | grep ERROR

# View last backup log
sudo tail -100 /var/log/btrfs-backup.log
```

### Email Notifications (Optional)

If you want email notifications on backup failures, you can use systemd's OnFailure:

Create `~/nixos-config/modules/services/backup-notifications.nix`:

```nix
{ config, pkgs, lib, ... }:

{
  # Ensure you have mail configured (e.g., msmtp)
  systemd.services.btrfs-backup-failure = {
    description = "BTRFS Backup Failure Notification";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo \"BTRFS backup failed at $(date)\" | mail -s \"Backup Failed\" your-email@example.com'";
    };
  };

  # Link to backup service
  systemd.services.btrfs-backup = {
    onFailure = [ "btrfs-backup-failure.service" ];
  };
}
```

## Recommended Schedules by Use Case

### Personal Desktop/Laptop
```nix
timerSchedule = "20:00";  # 8 PM daily
localRetentionDays = 3;   # Keep 3 days local
remoteRetentionDays = 14; # Keep 2 weeks remote
```

### Workstation with Important Projects
```nix
timerSchedule = "02:00";  # 2 AM daily
localRetentionDays = 7;   # Keep 1 week local
remoteRetentionDays = 30; # Keep 1 month remote
```

### Server with Critical Data
```nix
timerSchedule = "hourly"; # Every hour
localRetentionDays = 14;  # Keep 2 weeks local
remoteRetentionDays = 90; # Keep 3 months remote
```

### Low-Activity System
```nix
timerSchedule = "daily";   # Once daily
localRetentionDays = 7;    # Keep 1 week local
remoteRetentionDays = 60;  # Keep 2 months remote
```

## Testing Your Timer

### 1. Enable the timer

```bash
cd ~/nixos-config
# Edit your configuration to add enableTimer = true
sudo nixos-rebuild switch --flake .#nixos
```

### 2. Verify timer is active

```bash
systemctl status btrfs-backup.timer
# Should show: Active: active (waiting)
```

### 3. Check when next run is scheduled

```bash
systemctl list-timers btrfs-backup.timer
# Shows: NEXT, LEFT, LAST, PASSED columns
```

### 4. Test by manually triggering

```bash
# Trigger a backup immediately
sudo systemctl start btrfs-backup.service

# Watch the logs
sudo journalctl -u btrfs-backup.service -f
```

### 5. Verify it ran successfully

```bash
# Check exit status
systemctl status btrfs-backup.service
# Should show: Active: inactive (dead) with exit code 0

# Check logs
sudo tail -50 /var/log/btrfs-backup.log
# Should end with "Backup Summary: Successful: ..."
```

## Troubleshooting

### Timer Not Running

```bash
# Check if timer is enabled
systemctl is-enabled btrfs-backup.timer

# Check timer status
systemctl status btrfs-backup.timer

# If not active, check system logs
sudo journalctl -xe | grep btrfs-backup
```

### Backups Failing in Timer but Work Manually

This usually means SSH keys aren't available to the root user running the timer.

**Solution:** The service already runs as root and uses `sudo -u samir ssh`, so it should work. If you have issues, check:

```bash
# Test SSH as root with sudo -u
sudo bash -c 'sudo -u samir ssh -F /home/samir/.ssh/config target "echo test"'
```

### Check Timer Logs

```bash
# View timer activation logs
sudo journalctl -u btrfs-backup.timer

# View service execution logs
sudo journalctl -u btrfs-backup.service

# View both together
sudo journalctl -u btrfs-backup.timer -u btrfs-backup.service
```

## Advanced: Custom Timer Configuration

If you need more control over the timer, you can override systemd options:

```nix
{
  services.btrfs-backup = {
    enable = true;
    enableTimer = true;
    timerSchedule = "02:00";
    # ... other options ...
  };

  # Override timer settings
  systemd.timers.btrfs-backup = {
    timerConfig = {
      # Add random delay to avoid multiple systems backing up simultaneously
      RandomizedDelaySec = "30m";
      
      # Run missed backups on boot
      Persistent = true;
      
      # Wait for network before starting timer
      After = [ "network-online.target" ];
    };
  };

  # Override service settings
  systemd.services.btrfs-backup = {
    serviceConfig = {
      # Timeout after 1 hour
      TimeoutStartSec = "1h";
      
      # Restart on failure
      Restart = "on-failure";
      RestartSec = "5m";
      
      # Limit CPU usage
      CPUQuota = "50%";
      
      # Lower priority
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };
}
```

## Viewing Historical Backup Data

```bash
# View all backup runs in the last month
sudo journalctl -u btrfs-backup.service --since "1 month ago" --no-pager > backup-history.txt

# Count successful backups
sudo journalctl -u btrfs-backup.service --since "1 month ago" | grep -c "Successful:"

# Find all failures
sudo journalctl -u btrfs-backup.service --since "1 month ago" | grep "Failed:"

# View backup duration
sudo journalctl -u btrfs-backup.service --since "1 week ago" | grep "Starting BTRFS\|Backup Summary"
```

## Backup Verification Script (Optional)

Create a script to verify backups are running:

```bash
#!/usr/bin/env bash
# ~/bin/check-backups.sh

# Check when last backup ran
LAST_RUN=$(systemctl show btrfs-backup.service -p ActiveExitTimestamp --value)
echo "Last backup: $LAST_RUN"

# Check if it succeeded
STATUS=$(systemctl show btrfs-backup.service -p Result --value)
echo "Last result: $STATUS"

# Check next scheduled run
NEXT_RUN=$(systemctl show btrfs-backup.timer -p NextElapseUSecRealtime --value)
echo "Next backup: $NEXT_RUN"

# Check recent snapshots
echo ""
echo "Recent local snapshots:"
ls -lt /snapshots/*/20* 2>/dev/null | head -10
```

Make it executable:
```bash
chmod +x ~/bin/check-backups.sh
```

## Summary

1. **Enable timer** by adding `enableTimer = true` to your config
2. **Set schedule** with `timerSchedule = "02:00"` (or your preferred time)
3. **Rebuild** with `sudo nixos-rebuild switch --flake .#nixos`
4. **Verify** with `systemctl list-timers btrfs-backup.timer`
5. **Monitor** with `sudo journalctl -u btrfs-backup.service`

The timer will now run automatically at your scheduled time and handle:
- Creating snapshots
- Sending to remote server
- Cleaning up old snapshots (based on retention policies)
- Logging all operations

Your backups are now fully automated! 🎉
