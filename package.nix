{ lib
, writeScriptBin
, bash
, btrfs-progs
, openssh
, coreutils
, gnugrep
, gawk
, sudo
, util-linux
}:

# This is a standalone package version without NixOS module configuration
# Useful for testing or non-NixOS systems
# For NixOS, use the nixosModule instead

writeScriptBin "btrfs-backup" ''
  #!${bash}/bin/bash
  
  # This is a minimal wrapper - for full functionality, use the NixOS module
  # which provides proper configuration management
  
  PATH=${lib.makeBinPath [ 
    btrfs-progs 
    openssh 
    coreutils 
    gnugrep 
    gawk
    sudo
    util-linux
  ]}:$PATH
  
  echo "This is a standalone package of btrfs-backup."
  echo "For full functionality with configuration management,"
  echo "please use the NixOS module in your system configuration."
  echo ""
  echo "Usage: Import this flake in your NixOS configuration:"
  echo "  inputs.btrfs-backup.url = \"github:yourusername/btrfs-backup-flake\";"
  echo ""
  echo "Then in your configuration:"
  echo "  imports = [ inputs.btrfs-backup.nixosModules.default ];"
  echo "  services.btrfs-backup.enable = true;"
''
