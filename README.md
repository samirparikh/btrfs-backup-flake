# BTRFS Backup Flake

A NixOS flake for automated BTRFS snapshot backups with remote replication via SSH.

> ### ⚠️ Warning
> I vibe-coded this flake using Claude AI

## Features

- 📸 **Automated BTRFS snapshots** with read-only snapshots
- 🚀 **Incremental remote backups** using `btrfs send/receive`
- 🔄 **Automatic cleanup** of old snapshots (configurable retention periods)
- ⚙️ **Fully declarative** configuration via NixOS options
- ⏱️ **Optional systemd timer** for scheduled backups
- 🔐 **SSH key-based authentication** with custom SSH config support
- 📊 **Detailed logging** with timestamps

## Quick Start

### 1. Add to Your Flake Inputs

Edit your `nixos-config/flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
    # Add this flake
    btrfs-backup = {
      url = "github:samirparikh/btrfs-backup-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, btrfs-backup, ... }: {
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      modules = [
        # Import the module
        btrfs-backup.nixosModules.default
        
        # Your other modules
        ./configuration.nix
      ];
    };
  };
}
```

### 2. Configure in Your NixOS Configuration

Minimal configuration:

```nix
# In your configuration.nix or any imported module
{
  services.btrfs-backup = {
    enable = true;
    sshHost = "backup-server";  # Host from ~/.ssh/config
    remotePath = "/mnt/storage/snapshots";
  };
}
```

### 3. Rebuild and Test

```bash
# Update flake inputs
nix flake update

# Rebuild system
sudo nixos-rebuild switch --flake .#yourhostname

# Test the connection
sudo btrfs-backup --test

# Run your first backup
sudo btrfs-backup
```

## Configuration Options

Here's a full configuration example with all available options:

```nix
{
  services.btrfs-backup = {
    enable = true;
    
    # SSH Configuration
    sshHost = "backup-server";           # Host entry in ~/.ssh/config
    sshUser = "samir";                   # User who owns SSH config
    sshConfig = "/home/samir/.ssh/config";
    sshTimeout = 10;                     # Connection timeout (seconds)
    sshStrictHostKeyChecking = "accept-new";
    
    # Paths
    remotePath = "/mnt/storage/snapshots";
    localSnapshotPath = "/snapshots";
    btrfsRoot = "/";
    
    # Subvolumes to backup
    subvolumes = {
      Desktop = "/home/samir/Desktop";
      Documents = "/home/samir/Documents";
      Music = "/home/samir/Music";
      Pictures = "/home/samir/Pictures";
      Videos = "/home/samir/Videos";
      sites = "/home/samir/sites";
    };
    
    # Retention policies
    localRetentionDays = 7;              # Keep local snapshots for 7 days
    remoteRetentionDays = 30;            # Keep remote snapshots for 30 days
    
    # Logging
    logFile = "/var/log/btrfs-backup.log";
    dateFormat = "%Y%m%d-%H%M%S";        # Snapshot timestamp format
    
    # Automation (optional)
    enableTimer = false;                 # Enable automatic backups
    timerSchedule = "daily";             # When to run (systemd calendar)
    
    # Security
    sudoRules = true;                    # Auto-configure sudo for btrfs commands
  };
}
```

## Per-Machine Configuration Example

This flake is designed to work across multiple machines with different configurations.

### Workstation Configuration

```nix
# hosts/workstation/default.nix
{
  services.btrfs-backup = {
    enable = true;
    sshHost = "home-nas";
    subvolumes = {
      home = "/home/alice";
      projects = "/home/alice/projects";
    };
    localRetentionDays = 3;
    remoteRetentionDays = 14;
  };
}
```

### Laptop Configuration

```nix
# hosts/laptop/default.nix
{
  services.btrfs-backup = {
    enable = true;
    sshHost = "cloud-backup";
    subvolumes = {
      Documents = "/home/alice/Documents";
      Pictures = "/home/alice/Pictures";
    };
    enableTimer = true;                  # Auto-backup when on network
    timerSchedule = "daily";
  };
}
```

### Server Configuration

```nix
# hosts/server/default.nix
{
  services.btrfs-backup = {
    enable = true;
    sshHost = "offsite-backup";
    sshUser = "backup";
    remotePath = "/backup/server1";
    subvolumes = {
      data = "/srv/data";
      databases = "/var/lib/postgresql";
    };
    enableTimer = true;
    timerSchedule = "02:00";             # Daily at 2 AM
    localRetentionDays = 7;
    remoteRetentionDays = 90;            # Keep 3 months of backups
  };
}
```

## Usage

### Manual Backup

```bash
# Run a full backup
sudo btrfs-backup

# Test SSH connection without backing up
sudo btrfs-backup --test

# View help
btrfs-backup --help
```

### View Logs

```bash
# Follow live log
sudo tail -f /var/log/btrfs-backup.log

# View recent entries
sudo journalctl -u btrfs-backup -n 50
```

### Systemd Timer (if enabled)

```bash
# Check timer status
systemctl status btrfs-backup.timer

# View next scheduled run
systemctl list-timers btrfs-backup

# Manually trigger a scheduled backup
sudo systemctl start btrfs-backup.service

# View service logs
sudo journalctl -u btrfs-backup.service
```

## SSH Configuration

Create an SSH config entry for your backup server in `~/.ssh/config`:

```ssh-config
Host backup-server
    HostName backup.example.com
    User samir
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    Compression yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

Make sure:
1. Your SSH key is added to the remote server's `~/.ssh/authorized_keys`
2. The remote user has sudo access for `btrfs` commands (preferably NOPASSWD)
3. The remote server has `btrfs-progs` installed

## Remote Server Setup

On the backup destination server:

```bash
# Install btrfs-progs
sudo apt-get install btrfs-progs  # Debian/Ubuntu
# or
sudo dnf install btrfs-progs      # Fedora/RHEL

# Create backup directory
sudo mkdir -p /mnt/storage/snapshots
sudo chown yourusername:yourusername /mnt/storage/snapshots

# Optional: Add NOPASSWD sudo rule for btrfs
sudo visudo
# Add: yourusername ALL=(ALL) NOPASSWD: /usr/bin/btrfs
```

## Prerequisites

### Local System
- NixOS system with BTRFS filesystem
- Directories to backup must be BTRFS subvolumes
- Network connectivity to backup server

### Remote System
- BTRFS filesystem at backup location
- `btrfs-progs` installed
- SSH access configured
- Sufficient storage space

## Snapshot Organization

Snapshots are organized by subvolume name:

```
Local:  /snapshots/Pictures/Pictures-20251123-140532
Remote: /mnt/storage/snapshots/Pictures/Pictures-20251123-140532
```

This structure allows for:
- Easy identification of snapshot sources
- Independent retention policies per subvolume
- Efficient incremental backups

## How It Works

1. **Snapshot Creation**: Creates read-only BTRFS snapshots locally
2. **Incremental Send**: Uses `btrfs send` with parent snapshots for efficiency
3. **Remote Receive**: Transfers via SSH to `btrfs receive` on remote
4. **Cleanup**: Removes old snapshots based on retention policies
5. **Logging**: Records all operations with timestamps

## Troubleshooting

### "Subvolume not found"

Ensure the path is actually a BTRFS subvolume:
```bash
sudo btrfs subvolume show /home/samir/Pictures
```

If it's a regular directory, convert it:
```bash
# Backup the directory first!
sudo btrfs subvolume create /home/samir/Pictures.new
sudo cp -a /home/samir/Pictures/* /home/samir/Pictures.new/
sudo mv /home/samir/Pictures /home/samir/Pictures.old
sudo mv /home/samir/Pictures.new /home/samir/Pictures
# After verifying, delete old: sudo rm -rf /home/samir/Pictures.old
```

### SSH Connection Failures

```bash
# Test connection manually
ssh -F ~/.ssh/config backup-server

# Test with verbose output
sudo btrfs-backup --test
```

### Permission Errors

Ensure sudo rules are in place:
```bash
# Check current config
sudo -l

# Should show: (ALL) NOPASSWD: /nix/store/.../bin/btrfs
```

## Development

```bash
# Clone the repository
git clone https://github.com/samirparikh/btrfs-backup-flake.git
cd btrfs-backup-flake

# Enter development shell
nix develop

# Test the module locally
nix flake check

# Build the package
nix build
```

## Using Local Path

During development or for personal use, you can reference the flake locally:

```nix
{
  inputs.btrfs-backup = {
    url = "path:/home/samir/projects/btrfs-backup-flake";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Or reference it directly in your rebuild command:
```bash
sudo nixos-rebuild switch --flake /home/samir/projects/btrfs-backup-flake#yourhostname
```

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test your changes
4. Submit a pull request

## License

Apache 2.0  License - see LICENSE file for details

## Acknowledgments

- Built for NixOS with declarative configuration in mind
- Uses BTRFS send/receive for efficient incremental backups
- Inspired by the need for simple, reliable backup solutions
