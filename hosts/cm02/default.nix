# Mac Mini M6. Role still TBD (desktop / living room / Plex / remote Claude).
# Import role modules here as they're decided.
{ ... }: {
  imports = [
    ../../modules/darwin/pin-hostname.nix
  ];

  networking.hostName = "cm02";
  networking.computerName = "cm02";
}
