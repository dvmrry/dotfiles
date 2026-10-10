# cm02 user-level role modules (on top of modules/home/base.nix)
{ ... }: {
  imports = [
    ../../modules/home/homelab.nix
    ../../modules/home/media.nix
    ../../modules/home/secrets.nix
  ];
}
