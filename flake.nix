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
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, determinate, nixCats, ... }@inputs: {

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
          home-manager.users.dm.imports = [ ./modules/home/base.nix ./hosts/cm02/home.nix ];
        }
      ];
    };
  };
}
