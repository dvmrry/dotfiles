# Mac Mini M6. Role still settling (desktop / living room / Plex / remote Claude).
# Import role modules here as they're decided.
{ ... }: {
  imports = [
    ../../modules/darwin/pin-hostname.nix
    ../../modules/darwin/remote-access.nix
  ];

  networking.hostName = "cm02";
  networking.computerName = "cm02";
}
