{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.btrfs-backup;
  
  # Convert subvolumes attrset to bash associative array
  subvolumesArray = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: path: "    [\"${name}\"]=\"${path}\"")
    cfg.subvolumes
  );

  # Package the backup script with configuration injected
  btrfs-backup-script = pkgs.writeScriptBin "btrfs-backup" ''
    #!${pkgs.bash}/bin/bash
    #
    # BTRFS Snapshot Backup Script for NixOS
    # Performs snapshots of BTRFS subvolumes and sends them to remote backup server
    #

    set -euo pipefail

    # Set PATH to include all necessary commands
    PATH=${lib.makeBinPath [ 
      pkgs.btrfs-progs 
      pkgs.openssh 
      pkgs.coreutils 
      pkgs.gnugrep 
      pkgs.gawk
      pkgs.sudo
      pkgs.util-linux
    ]}:$PATH

    # ============================================================================
    # Configuration (injected from NixOS configuration)
    # ============================================================================

    # Remote backup configuration
    SSH_HOST="${cfg.sshHost}"
    REMOTE_PATH="${cfg.remotePath}"

    # SSH configuration
    SSH_USER="${cfg.sshUser}"
    SSH_CONFIG="${cfg.sshConfig}"
    SSH_OPTS="-F $SSH_CONFIG -o ConnectTimeout=${toString cfg.sshTimeout} -o StrictHostKeyChecking=${cfg.sshStrictHostKeyChecking}"
    SSH_CMD="sudo -u $SSH_USER ssh $SSH_OPTS"

    # Local paths
    BTRFS_ROOT="${cfg.btrfsRoot}"
    LOCAL_SNAPSHOT_BASE="${cfg.localSnapshotPath}"

    # Subvolumes to backup
    declare -A SUBVOLUMES=(
${subvolumesArray}
    )

    # Snapshot settings
    DATE_FORMAT="${cfg.dateFormat}"
    LOCAL_SNAPSHOT_RETENTION_DAYS=${toString cfg.localRetentionDays}
    REMOTE_SNAPSHOT_RETENTION_DAYS=${toString cfg.remoteRetentionDays}

    # Log file
    LOG_FILE="${cfg.logFile}"

    # ============================================================================
    # Functions
    # ============================================================================

    # Logging function
    log() {
        local level="$1"
        shift
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" >&2
    }

    # Error handler
    error_exit() {
        log "ERROR" "$1"
        exit 1
    }

    # Check if running as root
    check_root() {
        if [[ $EUID -ne 0 ]]; then
            error_exit "This script must be run as root"
        fi
    }

    # Check SSH configuration
    check_ssh_config() {
        log "INFO" "Using SSH config for host '$SSH_HOST'"
        log "INFO" "SSH config file: $SSH_CONFIG"
        
        if [[ ! -f "$SSH_CONFIG" ]]; then
            error_exit "SSH config file not found at $SSH_CONFIG"
        fi
        
        if [[ ! -r "$SSH_CONFIG" ]]; then
            error_exit "SSH config file is not readable: $SSH_CONFIG"
        fi
        
        # Verify the host is defined in the config
        if ! grep -q "^Host $SSH_HOST$" "$SSH_CONFIG"; then
            log "WARN" "Host '$SSH_HOST' not found in $SSH_CONFIG"
            log "WARN" "Make sure your SSH config has a 'Host $SSH_HOST' entry"
        else
            log "INFO" "Found host '$SSH_HOST' in SSH config"
        fi
    }

    # Verify btrfs filesystem
    verify_btrfs() {
        if ! command -v btrfs >/dev/null 2>&1; then
            error_exit "btrfs command not found"
        fi
        
        if ! btrfs filesystem show "$BTRFS_ROOT" >/dev/null 2>&1; then
            error_exit "$BTRFS_ROOT is not a btrfs filesystem"
        fi
    }

    # Test SSH connection
    test_ssh_connection() {
        log "INFO" "Testing SSH connection to $SSH_HOST..."
        
        # First, try to check if we can connect at all
        if ! $SSH_CMD "$SSH_HOST" "echo 'Connection test successful'" 2>&1 | grep -q "Connection test successful"; then
            log "ERROR" "Cannot connect to $SSH_HOST"
            log "ERROR" "Testing with verbose output..."
            sudo -u $SSH_USER ssh -v $SSH_OPTS "$SSH_HOST" "echo 'test'" 2>&1 | head -20 | while IFS= read -r line; do
                log "DEBUG" "$line"
            done
            log "ERROR" "Please ensure:"
            log "ERROR" "  1. The SSH config for host '$SSH_HOST' is correct in $SSH_CONFIG"
            log "ERROR" "  2. The SSH key is added to the remote's ~/.ssh/authorized_keys"
            log "ERROR" "  3. The remote host is accessible"
            return 1
        fi
        
        log "INFO" "SSH connection successful"
        
        # Then check if the remote base path exists
        if ! $SSH_CMD "$SSH_HOST" "test -d $REMOTE_PATH" 2>/dev/null; then
            log "WARN" "Remote path $REMOTE_PATH does not exist, attempting to create it..."
            if $SSH_CMD "$SSH_HOST" "sudo mkdir -p $REMOTE_PATH && sudo chown \$USER:\$USER $REMOTE_PATH" 2>/dev/null; then
                log "INFO" "Successfully created remote path $REMOTE_PATH"
            else
                log "ERROR" "Failed to create remote path $REMOTE_PATH"
                log "ERROR" "Please run on remote host: sudo mkdir -p $REMOTE_PATH && sudo chown \$USER:\$USER $REMOTE_PATH"
                return 1
            fi
        fi
        
        # Check if remote has btrfs-progs installed
        if ! $SSH_CMD "$SSH_HOST" "which btrfs" >/dev/null 2>&1; then
            log "ERROR" "btrfs command not found on remote host"
            log "ERROR" "Please install btrfs-progs on remote host"
            return 1
        fi
        
        # Check if remote user has sudo access for btrfs commands
        if ! $SSH_CMD "$SSH_HOST" "sudo -n btrfs --version" >/dev/null 2>&1; then
            log "WARN" "Remote user may need sudo password for btrfs commands"
            log "WARN" "Consider adding to sudoers: \$USER ALL=(ALL) NOPASSWD: /usr/bin/btrfs"
        fi
        
        # Check if remote path is a btrfs filesystem or in one
        if ! $SSH_CMD "$SSH_HOST" "btrfs filesystem show $REMOTE_PATH 2>/dev/null || btrfs filesystem show \$(df $REMOTE_PATH | tail -1 | awk '{print \$6}') 2>/dev/null" >/dev/null 2>&1; then
            log "WARN" "Unable to verify if remote path $REMOTE_PATH is on a btrfs filesystem"
            log "WARN" "This check may fail if the path doesn't exist yet or requires different permissions"
            log "WARN" "The backup will fail later if the filesystem doesn't support btrfs receive"
        else
            log "INFO" "Verified remote path is on a btrfs filesystem"
        fi
        
        log "INFO" "Remote path is ready for backups"
        return 0
    }

    # Create a read-only snapshot
    create_snapshot() {
        local subvol_name="$1"
        local subvol_path="$2"
        local timestamp=$(date +"$DATE_FORMAT")
        local snapshot_dir="''${LOCAL_SNAPSHOT_BASE}/''${subvol_name}"
        local snapshot_name="''${subvol_name}-''${timestamp}"
        local snapshot_path="''${snapshot_dir}/''${snapshot_name}"
        
        log "INFO" "Creating snapshot of $subvol_path as $snapshot_name..."
        
        # Create snapshot directory if it doesn't exist
        if [[ ! -d "$snapshot_dir" ]]; then
            log "INFO" "Creating snapshot directory: $snapshot_dir"
            if ! mkdir -p "$snapshot_dir" 2>/dev/null; then
                log "ERROR" "Failed to create snapshot directory: $snapshot_dir"
                return 1
            fi
        fi
        
        # Create read-only snapshot
        log "INFO" "Attempting: btrfs subvolume snapshot -r \"$subvol_path\" \"$snapshot_path\""
        if btrfs subvolume snapshot -r "$subvol_path" "$snapshot_path" 2>&1 | tee -a "$LOG_FILE" >&2; then
            log "INFO" "Successfully created snapshot: $snapshot_path"
            
            # Verify it's actually a subvolume
            if btrfs subvolume show "$snapshot_path" >/dev/null 2>&1; then
                log "INFO" "Verified snapshot is a valid btrfs subvolume"
            else
                log "ERROR" "Snapshot was created but is NOT a btrfs subvolume!"
                return 1
            fi
            
            echo "$snapshot_path"
        else
            log "ERROR" "Failed to create snapshot of $subvol_path"
            return 1
        fi
    }

    # Send snapshot to remote server
    send_snapshot_to_remote() {
        local snapshot_path="$1"
        local subvol_name="$2"
        local snapshot_name=$(basename "$snapshot_path")
        local remote_subvol_path="''${REMOTE_PATH}/''${subvol_name}"
        
        log "INFO" "Sending $snapshot_name to remote server..."
        
        # Verify snapshot exists and is valid before sending
        if [[ ! -d "$snapshot_path" ]]; then
            log "ERROR" "Snapshot path does not exist: $snapshot_path"
            return 1
        fi
        
        if ! btrfs subvolume show "$snapshot_path" >/dev/null 2>&1; then
            log "ERROR" "Snapshot is not a valid btrfs subvolume: $snapshot_path"
            ls -la "$snapshot_path" 2>&1 | head -5 | while read line; do log "DEBUG" "$line"; done
            return 1
        fi
        
        # Create remote directory if it doesn't exist
        if ! $SSH_CMD "$SSH_HOST" "sudo mkdir -p $remote_subvol_path" 2>/dev/null; then
            log "ERROR" "Failed to create remote directory $remote_subvol_path"
            return 1
        fi
        
        # Find the most recent parent snapshot
        local parent_snapshot=""
        local parent_path=""
        local snapshot_date=$(echo "$snapshot_name" | grep -oP '\d{8}-\d{6}')
        
        if [[ -n "$snapshot_date" ]]; then
            for existing in "$LOCAL_SNAPSHOT_BASE/$subvol_name/$subvol_name"-*; do
                if [[ -d "$existing" ]] && [[ "$existing" != "$snapshot_path" ]]; then
                    local existing_name=$(basename "$existing")
                    local existing_date=$(echo "$existing_name" | grep -oP '\d{8}-\d{6}')
                    if [[ -n "$existing_date" ]] && [[ "$existing_date" < "$snapshot_date" ]]; then
                        if $SSH_CMD "$SSH_HOST" "test -d $remote_subvol_path/$(basename $existing)" 2>/dev/null; then
                            parent_snapshot=$(basename "$existing")
                            parent_path="$existing"
                        fi
                    fi
                done
            done
        fi
        
        # Send the snapshot (with or without parent)
        if [[ -n "$parent_path" ]]; then
            log "INFO" "Using incremental send with parent: $parent_snapshot"
            if btrfs send -p "$parent_path" "$snapshot_path" 2>&1 | \
               $SSH_CMD "$SSH_HOST" "sudo btrfs receive $remote_subvol_path" 2>&1 | \
               tee -a "$LOG_FILE" >&2; then
                log "INFO" "Successfully sent snapshot $snapshot_name to remote (incremental)"
                return 0
            else
                log "WARN" "Incremental send failed, trying full send..."
            fi
        fi
        
        # Full send (either no parent or incremental failed)
        log "INFO" "Performing full send of snapshot"
        if btrfs send "$snapshot_path" 2>&1 | \
           $SSH_CMD "$SSH_HOST" "sudo btrfs receive $remote_subvol_path" 2>&1 | \
           tee -a "$LOG_FILE" >&2; then
            log "INFO" "Successfully sent snapshot $snapshot_name to remote (full)"
            return 0
        else
            log "ERROR" "Failed to send snapshot to remote"
            log "ERROR" "Snapshot path: $snapshot_path"
            log "ERROR" "Try manually: sudo btrfs send \"$snapshot_path\" | sudo -u $SSH_USER ssh -F $SSH_CONFIG $SSH_HOST \"sudo mkdir -p $remote_subvol_path && sudo btrfs receive $remote_subvol_path\""
            return 1
        fi
    }

    # Clean up old local snapshots
    cleanup_local_snapshots() {
        local subvol_name="$1"
        local retention_days="$2"
        local snapshot_dir="''${LOCAL_SNAPSHOT_BASE}/''${subvol_name}"
        
        log "INFO" "Cleaning up local snapshots older than $retention_days days for $subvol_name..."
        
        if [[ ! -d "$snapshot_dir" ]]; then
            log "INFO" "No snapshot directory found for $subvol_name"
            return 0
        fi
        
        local cutoff_date=$(date -d "$retention_days days ago" +'%Y%m%d')
        
        # Find and delete old snapshots
        local count=0
        for snapshot_path in "$snapshot_dir"/''${subvol_name}-*; do
            if [[ ! -d "$snapshot_path" ]]; then
                continue
            fi
            
            local snapshot_name=$(basename "$snapshot_path")
            # Extract date from format: SubvolName-YYYYMMDD-HHMMSS
            local snapshot_date=$(echo "$snapshot_name" | grep -oP '(?<=-)\d{8}(?=-\d{6})' || true)
            
            if [[ -n "$snapshot_date" ]] && [[ "$snapshot_date" -lt "$cutoff_date" ]]; then
                log "INFO" "Deleting old snapshot: $snapshot_path"
                if btrfs subvolume delete "$snapshot_path" >/dev/null 2>&1; then
                    ((count++))
                else
                    log "WARN" "Failed to delete $snapshot_path"
                fi
            fi
        done
        
        if [[ $count -gt 0 ]]; then
            log "INFO" "Deleted $count old local snapshot(s) for $subvol_name"
        else
            log "INFO" "No old snapshots to clean up for $subvol_name"
        fi
    }

    # Clean up old remote snapshots
    cleanup_remote_snapshots() {
        local subvol_name="$1"
        local retention_days="$2"
        local remote_subvol_path="''${REMOTE_PATH}/''${subvol_name}"
        
        log "INFO" "Cleaning up remote snapshots older than $retention_days days for $subvol_name..."
        
        local result=$($SSH_CMD "$SSH_HOST" "
            cutoff_date=\$(date -d '$retention_days days ago' +'%Y%m%d')
            count=0
            
            if [[ ! -d '$remote_subvol_path' ]]; then
                echo 'No remote snapshots directory found'
                exit 0
            fi
            
            for snapshot in $remote_subvol_path/''${subvol_name}-*; do
                if [[ ! -d \"\$snapshot\" ]]; then
                    continue
                fi
                
                snapshot_name=\$(basename \"\$snapshot\")
                # Extract date from format: SubvolName-YYYYMMDD-HHMMSS
                snapshot_date=\$(echo \"\$snapshot_name\" | grep -oP '(?<=-)\d{8}(?=-\d{6})' || true)
                
                if [[ -n \"\$snapshot_date\" ]] && [[ \"\$snapshot_date\" -lt \"\$cutoff_date\" ]]; then
                    if sudo btrfs subvolume delete \"\$snapshot\" >/dev/null 2>&1; then
                        ((count++))
                        echo \"Deleted: \$snapshot\"
                    else
                        echo \"Warning: Failed to delete \$snapshot\"
                    fi
                fi
            done
            
            echo \"Total deleted: \$count\"
        " 2>/dev/null || true)
        
        if [[ -n "$result" ]]; then
            echo "$result" | while IFS= read -r line; do
                if [[ "$line" == "Total deleted:"* ]]; then
                    log "INFO" "$line remote snapshot(s) for $subvol_name"
                elif [[ "$line" == "Warning:"* ]]; then
                    log "WARN" "$line"
                elif [[ "$line" == "No remote snapshots directory found" ]]; then
                    log "INFO" "$line for $subvol_name"
                fi
            done
        fi
    }

    # Main backup function for a single subvolume
    backup_subvolume() {
        local name="$1"
        local subvol_path="$2"
        
        log "INFO" "=== Starting backup for $name ==="
        
        # Create snapshot
        local snapshot_path=$(create_snapshot "$name" "$subvol_path")
        if [[ -z "$snapshot_path" ]]; then
            log "ERROR" "Skipping remote backup for $name due to snapshot creation failure"
            return 1
        fi
        
        # Send to remote
        if send_snapshot_to_remote "$snapshot_path" "$name"; then
            log "INFO" "Backup completed successfully for $name"
            
            # Cleanup old snapshots
            cleanup_local_snapshots "$name" "$LOCAL_SNAPSHOT_RETENTION_DAYS"
            cleanup_remote_snapshots "$name" "$REMOTE_SNAPSHOT_RETENTION_DAYS"
        else
            log "ERROR" "Remote backup failed for $name"
            return 1
        fi
        
        log "INFO" "=== Finished backup for $name ==="
        return 0
    }

    # ============================================================================
    # Main Script
    # ============================================================================

    main() {
        log "INFO" "=========================================="
        log "INFO" "Starting BTRFS Backup Script"
        log "INFO" "=========================================="
        
        # Perform checks
        check_root
        check_ssh_config
        verify_btrfs
        
        # Test SSH connection
        if ! test_ssh_connection; then
            error_exit "SSH connection test failed. Please check the error messages above."
        fi
        
        # Track failures
        local failed_backups=()
        local successful_backups=()
        
        # Backup each subvolume
        for name in "''${!SUBVOLUMES[@]}"; do
            subvol_path="''${SUBVOLUMES[$name]}"
            
            # Check if subvolume/directory exists
            if ! btrfs subvolume show "$subvol_path" >/dev/null 2>&1; then
                log "WARN" "Subvolume $subvol_path not found, skipping..."
                continue
            fi
            
            if backup_subvolume "$name" "$subvol_path"; then
                successful_backups+=("$name")
            else
                failed_backups+=("$name")
            fi
            
            # Small delay between backups
            sleep 2
        done
        
        # Summary
        log "INFO" "=========================================="
        log "INFO" "Backup Summary:"
        if [[ ''${#successful_backups[@]} -gt 0 ]]; then
            log "INFO" "Successful: ''${successful_backups[*]}"
        fi
        if [[ ''${#failed_backups[@]} -gt 0 ]]; then
            log "ERROR" "Failed: ''${failed_backups[*]}"
        fi
        log "INFO" "=========================================="
        
        # Exit with error if any backups failed
        if [[ ''${#failed_backups[@]} -gt 0 ]]; then
            exit 1
        fi
    }

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --test)
                # Just test the connection
                check_root
                check_ssh_config
                if test_ssh_connection; then
                    log "INFO" "All connection tests passed!"
                    exit 0
                else
                    error_exit "Connection test failed"
                fi
                ;;
            --help|-h)
                echo "Usage: $0 [--test] [--help]"
                echo ""
                echo "Options:"
                echo "  --test     Only test SSH connection and configuration"
                echo "  --help     Show this help message"
                echo ""
                echo "Configuration:"
                echo "  SSH Host:  $SSH_HOST (from $SSH_CONFIG)"
                echo "  Remote:    $REMOTE_PATH"
                echo ""
                echo "The script uses SSH config entry '$SSH_HOST' from $SSH_CONFIG"
                echo "Make sure your SSH config is properly configured with host, user, and identity file."
                exit 0
                ;;
            *)
                log "WARN" "Unknown option: $1"
                shift
                ;;
        esac
    done

    # Run main function
    main
  '';

in {
  options.services.btrfs-backup = {
    enable = mkEnableOption "BTRFS snapshot backup service";

    sshHost = mkOption {
      type = types.str;
      default = "target";
      description = "SSH host from ~/.ssh/config to use for remote backups";
      example = "backup-server";
    };

    sshUser = mkOption {
      type = types.str;
      default = "samir";
      description = "User who owns the SSH configuration";
    };

    sshConfig = mkOption {
      type = types.str;
      default = "/home/samir/.ssh/config";
      description = "Path to SSH configuration file";
    };

    sshTimeout = mkOption {
      type = types.int;
      default = 10;
      description = "SSH connection timeout in seconds";
    };

    sshStrictHostKeyChecking = mkOption {
      type = types.str;
      default = "accept-new";
      description = "SSH StrictHostKeyChecking setting";
      example = "yes";
    };

    remotePath = mkOption {
      type = types.str;
      default = "/mnt/storage/snapshots";
      description = "Remote path for storing backups";
      example = "/backup/snapshots";
    };

    btrfsRoot = mkOption {
      type = types.str;
      default = "/";
      description = "BTRFS root filesystem path";
    };

    localSnapshotPath = mkOption {
      type = types.str;
      default = "/snapshots";
      description = "Local directory for storing snapshots";
    };

    subvolumes = mkOption {
      type = types.attrsOf types.str;
      default = {
        Desktop = "/home/samir/Desktop";
        Documents = "/home/samir/Documents";
        Music = "/home/samir/Music";
        Pictures = "/home/samir/Pictures";
        Videos = "/home/samir/Videos";
        sites = "/home/samir/sites";
      };
      description = "Attribute set of subvolume names to paths to backup";
      example = {
        home = "/home/user";
        projects = "/home/user/projects";
      };
    };

    dateFormat = mkOption {
      type = types.str;
      default = "%Y%m%d-%H%M%S";
      description = "Date format for snapshot names";
    };

    localRetentionDays = mkOption {
      type = types.int;
      default = 7;
      description = "Number of days to keep local snapshots";
    };

    remoteRetentionDays = mkOption {
      type = types.int;
      default = 30;
      description = "Number of days to keep remote snapshots";
    };

    logFile = mkOption {
      type = types.str;
      default = "/var/log/btrfs-backup.log";
      description = "Path to log file";
    };

    enableTimer = mkOption {
      type = types.bool;
      default = false;
      description = "Enable automatic backups via systemd timer";
    };

    timerSchedule = mkOption {
      type = types.str;
      default = "daily";
      description = "When to run backups (systemd calendar format)";
      example = "02:00";
    };

    sudoRules = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically add sudo rules for btrfs commands";
    };
  };

  config = mkIf cfg.enable {
    # Install the script
    environment.systemPackages = [ btrfs-backup-script ];

    # Ensure btrfs-progs is available system-wide
    environment.systemPackages = with pkgs; [
      btrfs-progs
    ];

    # Create log file and snapshot directory with proper permissions
    systemd.tmpfiles.rules = [
      "f ${cfg.logFile} 0644 root root -"
      "d ${cfg.localSnapshotPath} 0755 root root -"
    ];

    # Optional: Add sudo rules for the SSH user
    security.sudo.extraRules = mkIf cfg.sudoRules [
      {
        users = [ cfg.sshUser ];
        commands = [
          {
            command = "${pkgs.btrfs-progs}/bin/btrfs";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # Systemd service for backups
    systemd.services.btrfs-backup = mkIf cfg.enableTimer {
      description = "BTRFS Snapshot Backup";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${btrfs-backup-script}/bin/btrfs-backup";
        User = "root";
        
        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = false;  # Need sudo
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ cfg.localSnapshotPath cfg.logFile ];
      };
    };

    # Systemd timer for scheduled backups
    systemd.timers.btrfs-backup = mkIf cfg.enableTimer {
      description = "BTRFS Snapshot Backup Timer";
      wantedBy = [ "timers.target" ];
      
      timerConfig = {
        OnCalendar = cfg.timerSchedule;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
