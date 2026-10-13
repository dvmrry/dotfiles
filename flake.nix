{
  description = "macOS system configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Cluster-facing CLIs (talosctl, kubectl) pinned to match talos-homelab
    # (talos-gitops talconfig.yaml: Talos v1.12.x, Kubernetes v1.35.x).
    # Bump this rev when the cluster is upgraded.
    nixpkgs-cluster.url = "github:NixOS/nixpkgs/6ebfbc3";

    nix-darwin = {
      url = "github:LnL7/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";

    nixCats.url = "github:BirdeeHub/nixCats-nvim";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Game streaming host for gm01. gm01 is built from punktfunk's own nixpkgs
    # so the host and its patched gamescope come from punktfunk's binary cache
    # (built against any other nixpkgs, every update compiles for ~1 h).
    # nix-stable moves only on releases, and only to cached commits.
    punktfunk.url = "git+https://git.unom.io/unom/punktfunk?ref=nix-stable&shallow=1";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      home-manager,
      determinate,
      nixCats,
      ...
    }@inputs:
    {

      # MacBook Air M1 - headless devbox (legacy layout, not yet on modules/)
      darwinConfigurations."cm01" = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        modules = [
          determinate.darwinModules.default
          ./hosts/cm01/configuration.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            home-manager.users.dm = import ./hosts/cm01/home.nix;
          }
        ];
      };

      # Mac Mini M6 - role TBD, so only the shared base for now
      darwinConfigurations."cm02" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit inputs; };
        modules = [
          determinate.darwinModules.default
          ./modules/darwin/base.nix
          ./hosts/cm02
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            # Rename pre-existing dotfiles instead of failing activation
            home-manager.backupFileExtension = "before-hm";
            home-manager.users.dm.imports = [
              ./modules/home/base.nix
              ./hosts/cm02/home.nix
            ];
          }
        ];
      };

      # GMKtec EVO-X2 (Strix Halo) - headless inference box, NixOS
      nixosConfigurations."im01" = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/im01
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            home-manager.backupFileExtension = "before-hm";
            home-manager.users.dm.imports = [ ./modules/home/base.nix ];
          }
        ];
      };

      # Desktop (7800X3D + RTX 4070 Ti Super) - headless-ish gaming box, NixOS.
      # Uses punktfunk's nixpkgs (see the input), not this flake's.
      nixosConfigurations."gm01" = inputs.punktfunk.inputs.nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          inputs.punktfunk.nixosModules.default
          ./hosts/gm01
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            home-manager.backupFileExtension = "before-hm";
            home-manager.users.dm.imports = [ ./modules/home/base.nix ];
          }
        ];
      };
    };
}
