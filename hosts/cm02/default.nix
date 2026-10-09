# Mac Mini M6. Role still settling (desktop / living room / Plex / remote Claude).
# Import role modules here as they're decided.
{ ... }: {
  imports = [
    ../../modules/darwin/pin-hostname.nix
    ../../modules/darwin/remote-access.nix
  ];

  # Mac App Store apps (installed via `mas`; must be signed in to the App Store).
  homebrew.masApps = {
    "1Password for Safari" = 1569813296;
    "TestFlight" = 899247664;
    "uBlock Origin Lite" = 6745342698;
    # Full Xcode (~10–15 GB): needed for App Intents metadata (jjang) and Apple-platform work.
    # Simulator runtimes are installed separately from Xcode as needed.
    "Xcode" = 497799835;
  };
  # Not manageable by mas, so installed by hand after a rebuild:
  #   - Prologue (1459223267) and UHF (6443751726): iPad apps from the App Store;
  #     mas can't see or install iPad-on-Mac apps.
  #   - Punktfunk: game-streaming client (Moonlight replacement), TestFlight build.

  # jjang (tiling WM) owns window placement here; macOS's own edge tiling is a second writer for the same
  # gestures (jjang throws windows to screen edges), so it's off. Option-drag and top-edge fill too.
  system.defaults.WindowManager = {
    EnableTilingByEdgeDrag = false;
    EnableTopTilingByEdgeDrag = false;
    EnableTilingOptionAccelerator = false;
  };

  networking.hostName = "cm02";
  networking.computerName = "cm02";
}
