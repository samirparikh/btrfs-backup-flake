{
  description = "BTRFS snapshot backup script with remote replication for NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      # NixOS module to import in your configuration
      nixosModules.default = import ./module.nix;
      
      # Also expose as 'btrfs-backup' for clarity
      nixosModules.btrfs-backup = self.nixosModules.default;

      # Standalone package (useful for testing or non-NixOS systems)
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = self.packages.${system}.btrfs-backup;
          
          btrfs-backup = pkgs.callPackage ./package.nix { };
        }
      );

      # Development shell
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              btrfs-progs
              openssh
            ];
          };
        }
      );
    };
}
