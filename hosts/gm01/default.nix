# ASUS ROG Strix B650E-I, Ryzen 7 7800X3D, 64 GB DDR5-6000, RTX 4070 Ti
# Super 16 GB. Headless gaming box streamed with Punktfunk (SteamOS-style, no
# desktop); local LLMs later. BIOS: Secure Boot off, iGPU off.
{
  config,
  lib,
  pkgs,
  utils,
  inputs,
  ...
}:
let
  llama-cpp = pkgs.callPackage ./llama-cpp.nix { };
  # The release nixpkgs used before 0.19.2 (hardware.nvidia.package below)
  patchelf_0_15 = pkgs.patchelf.overrideAttrs (
    finalAttrs: _: {
      version = "0.15.2";
      src = pkgs.fetchurl {
        url = "https://github.com/NixOS/patchelf/releases/download/${finalAttrs.version}/patchelf-${finalAttrs.version}.tar.bz2";
        hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
      };
    }
  );
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disk.nix
    ./hardware-configuration.nix
    ../common/inference-exporters.nix
    ../../modules/nixos/base.nix
  ];
  inferenceExporters.nvidiaGpu = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 1; # POST already takes a minute (memory training)
  # Memory Context Restore corrupted memory here (2x32 GB EXPO 6000); keep it
  # on Auto. memtest86+ in the boot menu to check the kit (hold Space at boot).
  boot.loader.systemd-boot.memtest86.enable = true;
  # Keep the CPU's iGPU (Raphael) idle so games and NVENC stay on the 4070 Ti
  # Super, even with the iGPU on Auto in the BIOS.
  boot.blacklistedKernelModules = [ "amdgpu" ];
  # IOMMU stays on but device DMA isn't translated (Strata streams experts
  # RAM -> GPU constantly)
  boot.kernelParams = [ "iommu=pt" ];

  boot.kernelModules = [ "nct6775" ]; # board fan/voltage sensors (Nuvoton)

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;

  # NVIDIA: proprietary kernel module with the GSP firmware off. The open
  # module needs GSP, whose heap reserves ~434 MiB of VRAM; without it the
  # 27B's 80K-context profile fits.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false;
    gsp.enable = false;
    modesetting.enable = true;
    nvidiaPersistenced = true; # driver stays initialised between engine runs
    # patchelf 0.19.2 breaks a binary when one call sets both its interpreter
    # and rpath, as the driver's builder does for nvidia-smi, nvidia-powerd,
    # nvidia-debugdump and nvidia-cuda-mps-control: their LOAD segments
    # overlap and ld.so segfaults before main (nixpkgs #576412). That took out
    # gpu-tune and the GPU exporter. The libraries are fine. The condition
    # drops the override once this nixpkgs moves to another patchelf.
    package =
      let
        driver = config.boot.kernelPackages.nvidiaPackages.${config.hardware.nvidia.branch};
      in
      if pkgs.patchelf.version == "0.19.2" then
        driver.overrideAttrs (old: {
          nativeBuildInputs = [ patchelf_0_15 ] ++ old.nativeBuildInputs;
        })
      else
        driver;
  };
  boot.extraModprobeConfig = "options nvidia NVreg_EnableGpuFirmware=0";
  # GPU tuning, applied at boot (neither setting survives a driver reload).
  # Decode is memory-bandwidth-bound, and under CUDA GeForce cards sit in P2
  # at 10251 MHz. Measured on the 27B: +2500 -> 11501 MHz, +10%; +4500 clean;
  # +5000 crashed the GPU (Xid 45/31). +3500 = 12001 MHz, +14%, with margin.
  systemd.services.gpu-tune = {
    description = "GPU power limit and memory clock offset";
    after = [ "nvidia-persistenced.service" ];
    requires = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ config.hardware.nvidia.package.bin ];
    script =
      let
        python = pkgs.python3.withPackages (p: [ p.nvidia-ml-py ]);
      in
      ''
        nvidia-smi -pl 300
        ${python}/bin/python3 -c 'from pynvml import *; nvmlInit(); nvmlDeviceSetMemClkVfOffset(nvmlDeviceGetHandleByIndex(0), 3500)'
      '';
  };
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Steam / Proton
  };

  zramSwap.enable = true;
  powerManagement.cpuFreqGovernor = "performance"; # prefill, Strata's CPU experts

  # Networking: DHCP on wired (preferred) and Wi-Fi. Both sit on the Macs'
  # subnet, so a reply to traffic that came in on one can leave via the other;
  # strict reverse-path filtering would drop those.
  networking.hostName = "gm01";
  networking.useNetworkd = true;
  networking.firewall.checkReversePath = "loose";
  systemd.network.networks."10-wired" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
  };
  # Wi-Fi (MT7922) via iwd. Credentials are entered once on the box and kept
  # by iwd in /var/lib/iwd, never in this repo:
  #   sudo iwctl station wlan0 connect <SSID>
  networking.wireless.iwd = {
    enable = true;
    settings = {
      General.EnableNetworkConfiguration = false; # networkd does DHCP
      # The AP's 5 GHz radio is on a DFS channel, which a scan often misses,
      # and iwd won't leave a strong 2.4 GHz link for it on its own
      Rank.BandModifier2_4GHz = 0.5;
    };
  };
  systemd.network.networks."20-wireless" = {
    matchConfig.Name = "wl*";
    networkConfig.DHCP = "yes";
    dhcpV4Config.RouteMetric = 2048; # wired (1024) wins when plugged in
    ipv6AcceptRAConfig.RouteMetric = 2048;
  };
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  time.timeZone = "America/New_York";

  hardware.bluetooth.enable = true; # controllers when playing locally

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # No one is logged in at the seat, so don't hold Bluetooth audio back
    # until someone is (sound cards: dm is in `audio`, below)
    wireplumber.extraConfig."10-no-seat"."wireplumber.profiles".main = {
      "monitor.bluez.seat-monitoring" = "disabled";
    };
  };

  # No desktop and no login: Punktfunk starts a headless gamescope running
  # Steam Big Picture for each client (see services.punktfunk below). dm's
  # user services (Punktfunk, PipeWire) run from boot, like im01's Halogen.
  users.users.dm.linger = true;
  # Never sleep: a suspended box can't be streamed to
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Gaming
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ]; # try Valve's Proton first
    protontricks.enable = true;
  };
  programs.gamemode.enable = true;
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  # Local play on a monitor, on demand: Steam Gaming Mode on tty1, the way
  # SteamOS runs it. Never at boot, so streams keep getting their own headless
  # gamescope at the client's resolution, with HDR.
  #   sudo systemctl start local-play   # Gaming Mode on the monitor
  #   sudo systemctl stop local-play    # back to headless (or quit Steam)
  # While it runs, a Punktfunk stream attaches to it instead: the monitor's
  # resolution, SDR. Punktfunk's handover (idle the local session for a
  # stream, give it back after) only knows SteamOS and Bazzite session units.
  programs.steam.gamescopeSession = {
    enable = true;
    # The monitor (Dell S2716DG) does 144 Hz; gamescope picks 60 unless told
    args = [
      "-W"
      "2560"
      "-H"
      "1440"
      "-r"
      "144"
    ];
    steamArgs = [
      "-gamepadui" # as in Punktfunk's sessions
      "-pipewire-dmabuf"
    ];
  };
  # A logind session on tty1 for dm (DRM master, input devices), as
  # services.cage does it
  systemd.services.local-play = {
    description = "Steam Gaming Mode on the local monitor";
    after = [
      "systemd-user-sessions.service"
      "systemd-logind.service"
      "getty@tty1.service"
    ];
    wants = [
      "dbus.socket"
      "systemd-logind.service"
    ];
    conflicts = [ "getty@tty1.service" ];
    restartIfChanged = false; # a deploy doesn't end a game
    # steam-gamescope runs gamescope and steam from PATH. With capSysNice,
    # gamescope is only the wrapper in /run/wrappers/bin. The current system
    # rather than this build's, so a game started after a deploy finds what it
    # added (heroic, for Heroic's Steam shortcuts).
    path = [
      (dirOf config.security.wrapperDir)
      "/run/current-system/sw"
    ];
    serviceConfig = {
      # Steam runs once per user: a second one hands its arguments to the
      # first and exits, and the monitor would stay dark
      ExecStartPre = [
        (pkgs.writeShellScript "local-play-check" ''
          if ${pkgs.procps}/bin/pgrep -u dm -x steam >/dev/null; then
            echo "local-play: Steam is already running (a Punktfunk stream?); disconnect it first" >&2
            exit 1
          fi
        '')
        # The LLMs take all 16 GB of VRAM. As root ("+"): stopping them is
        # one-way, where Conflicts= would let an LLM start end the game.
        "+${config.systemd.package}/bin/systemctl stop llama.service podman-strata.service"
      ];
      ExecStart = "/run/current-system/sw/bin/steam-gamescope";
      User = "dm";
      PAMName = "local-play";
      TTYPath = "/dev/tty1";
      TTYReset = "yes";
      TTYVHangup = "yes";
      TTYVTDisallocate = "yes";
      StandardInput = "tty-fail";
      StandardOutput = "journal";
      StandardError = "journal";
      UtmpIdentifier = "%n";
      UtmpMode = "user";
      IgnoreSIGPIPE = "no";
    };
  };
  # No getty on tty1, as services.greetd does it: a deploy restarts
  # getty.target, which starts autovt@tty1, and Conflicts= then ends the game.
  # dm has no password, so nothing could log in there anyway.
  systemd.services."autovt@tty1".enable = false;
  security.pam.services.local-play = {
    useDefaultRules = false;
    rules = {
      account = utils.pam.autoOrderRules [
        {
          name = "unix";
          control = "required";
          modulePath = config.security.pam.pam_unixModulePath;
        }
      ];
      session = utils.pam.autoOrderRules [
        {
          name = "unix";
          control = "required";
          modulePath = config.security.pam.pam_unixModulePath;
        }
        {
          name = "env";
          control = "required";
          modulePath = "${config.security.pam.package}/lib/security/pam_env.so";
          settings.conffile = "/etc/pam/environment";
          settings.readenv = 0;
        }
        {
          name = "systemd";
          control = "required";
          modulePath = "${config.systemd.package}/lib/security/pam_systemd.so";
        }
      ];
    };
  };

  # Streaming: Punktfunk host. Each client gets its own headless gamescope
  # ("bare spawn") at the client's resolution and refresh rate, with HDR via
  # punktfunk's patched gamescope. Pair from the web console on :47992.
  # Moonlight (GameStream) is off; enable with host.gamestream = true.
  services.punktfunk.host = {
    enable = true;
    users = [ "dm" ];
    openFirewall = true;
    autoStart = true; # with linger: up at boot, no login needed
    settings = {
      PUNKTFUNK_COMPOSITOR = "gamescope"; # no session to detect
      PUNKTFUNK_GAMESCOPE_APP = "steam -gamepadui"; # Big Picture in each stream
    };
  };

  # Local LLMs: one engine at a time on :8731 (im01's port too, so clients only
  # change the host). Never at boot: each takes most of the VRAM and tens of GB
  # of pinned RAM, so stop it before gaming.
  #   sudo systemctl start llama           # Qwen3.8 27B, llama.cpp
  #   sudo systemctl start podman-strata   # Qwen3.8 Flash Next, Strata
  # Starting one stops the other.
  virtualisation.podman.enable = true;
  hardware.nvidia-container-toolkit.enable = true; # CDI: nvidia.com/gpu=all
  virtualisation.oci-containers = {
    backend = "podman";
    # Strata's own image (published from 0.2.1 on; cuda13 covers the 4070 Ti Super). Its `strata launch` wrapper
    # writes the engine's run config from these variables and keeps it as a preset in /data, with the pack and the
    # MTP layer (the first start prepares them, ~15 min). The IQ3_S files stay where 0.1.43 downloaded them, mounted
    # read-only; shard 2 there is the Q8_0 n-gram table (README-q8-ple.txt in that folder; per-row error vs BF16
    # 0.53% against the stock table's 7.6%, same speed). The server always wants an API key: made on the first start
    # and kept in /var/lib/llm/strata2/state/api-key; clients send it as a Bearer token.
    containers.strata = {
      image = "ghcr.io/niko1221/strata:0.2.1-cuda13";
      autoStart = false;
      ports = [ "8731:8080" ];
      volumes = [
        "/var/lib/llm/strata2:/data"
        "/var/lib/llm/strata/models/IQ3_S-q8ple:/models:ro"
      ];
      environment = {
        MODEL = "IQ3_S"; # 55 GB of experts in RAM; fits with nothing else running
        MODEL_PATH = "/models";
        CONTEXT = "256k"; # agentic runs peak at ~180-230K, so 128K would compact
        PARALLEL = "1"; # as measured; 0.1.45+ can batch requests, untested here
        VISION = "off";
        TUNE = "skip";
        # 0.1.43's tuning carried over. With it 0.2.1 ties 0.1.43.1 on gm01 (2026-10-20, same probes: code ~105 vs
        # ~106 tok/s, prose 93 vs 93, 32K prefill ~3,080 vs ~3,060 tok/s); 0.2.1's own quick tune alone was 7-10%
        # slower, mostly from a lower draft acceptance (0.6-0.7 vs 0.8).
        STRATA_SET = lib.concatStringsSep " " [
          "spec-min-p=0.70"
          "pcie-frac=0.35" # setup.py --calibrate
          # From the 2026-10-13 autotune (24 arms, each kept only if >= 2% faster twice): adapting every other token
          # at twice the swaps (+2.5%), 7 expert pool workers (+2.7%), and kv-grow (+11.6%), which hands the KV
          # cells not yet used to the expert cache. Together decode +9-17%; prefill and TTFT unchanged.
          "adapt-every=2"
          "adapt-swaps=320"
          "adapt-decay=0.97"
          "pool-workers=7"
          "kv-grow=1"
          # The adaptive tier's copies overlap decode: +8% here (3 interleaved pairs on 0.1.43.1). aux-cpus keeps the
          # non-worker threads off the pinned host thread's CPU (Strata #1975).
          "STRATA_ADAPT_OVERLAP=1"
          "aux-cpus=auto"
        ];
      };
      extraOptions = [
        "--device=nvidia.com/gpu=all"
        "--ulimit=memlock=-1:-1" # pins its experts in RAM
        "--shm-size=2g"
        "--stop-timeout=120" # releasing tens of GB of pinned RAM takes a while
      ];
    };
  };
  systemd.services.podman-strata.conflicts = [ "llama.service" ];
  # Qwen3.8 27B, the profile tuned on Windows (Aug 2026) and re-measured
  # here: UD-IQ4_XS with its built-in MTP head, depth 3. 64K is the largest
  # context that fits beside MTP; 80K doesn't on this build. ~113 tok/s on
  # the Windows coding harness. Thinking is off by default: unbounded, it
  # spends whole budgets reasoning without answering. A request that turns it
  # on gets a 1K budget, which on Windows fixed the hard tasks.
  systemd.services.llama = {
    description = "llama.cpp: Qwen3.8 27B";
    conflicts = [ "podman-strata.service" ];
    after = [ "gpu-tune.service" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        "${llama-cpp}/bin/llama-server"
        "-m"
        "/var/lib/llm/gguf/Qwen3.8-27B-UD-IQ4_XS.gguf"
        "--alias"
        "qwen3.8-27b"
        "-ngl"
        "999"
        "-fa"
        "on"
        "-c"
        "65536"
        "-np"
        "1"
        "-t"
        "8"
        "-tb"
        "16"
        "-b"
        "2048"
        "-ub"
        "512"
        "-ctk"
        "q4_0"
        "-ctv"
        "q4_0"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-min"
        "1"
        "--spec-draft-n-max"
        "3"
        # the hybrid (DeltaNet) layers can't rewind; checkpoints let multi-turn
        # agents reuse their prefix instead of re-reading it every turn
        "--cache-ram"
        "8192"
        "--ctx-checkpoints"
        "8"
        "--jinja"
        "--no-mmproj"
        "--reasoning"
        "off"
        "--reasoning-budget"
        "1024"
        "--reasoning-budget-message"
        "Wait, I'm overthinking this. Stop reasoning and write the requested code now."
        "--temp"
        "0.2"
        "--top-p"
        "0.8"
        "--top-k"
        "20"
        "--min-p"
        "0"
        "--metrics"
        "--host"
        "0.0.0.0"
        "--port"
        "8731"
      ];
      DynamicUser = true;
      Nice = -5;
      Restart = "on-failure";
    };
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/llm/gguf 0755 dm users -"
    "d /var/lib/llm/strata 0755 root root -" # 0.1.43's tree: still holds the IQ3_S files
    "d /var/lib/llm/strata2 0755 root root -"
  ];
  networking.firewall.allowedTCPPorts = [ 8731 ]; # LLM API, LAN only (Strata asks for its key, llama.cpp has none)

  # SSH: key-only, same hardening as the Macs
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "dm" ];
      X11Forwarding = false;
    };
  };

  # Pinned SSH host keys (from https://api.github.com/meta)
  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  };

  users.users.dm = {
    isNormalUser = true;
    # audio: sound cards are otherwise granted only to a seat login, and
    # gm01 has none. podman: read root's containers (Strata) through
    # /run/podman/podman.sock, for Medina; the socket also allows control,
    # which wheel's passwordless sudo already gives
    extraGroups = [
      "wheel"
      "video"
      "render"
      "audio"
      "podman"
    ];
    # Login shell (bash, interactive fish): modules/nixos/base.nix
    openssh.authorizedKeys.keys = [
      # 1Password id_ed25519
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8zyMqlC1LHHWWk0v/wdfaVGYBoZSvD64xaAQZ5dOYh"
      # cm02 automation key (file key, no 1Password approval), Mac LAN only
      ''from="172.19.0.0/24" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHXho3zeypEdHDMWM11L4Km3AL1Y5wOc3/aonhcfGQPG dm@cm02 automation''
    ];
  };
  # dm has no password (key-only), so sudo can't prompt for one
  security.sudo.wheelNeedsPassword = false;

  # Common CLI tools come from modules/nixos/base.nix.
  environment.systemPackages = with pkgs; [
    llama-cpp
    mangohud # per game: `mangohud %command%`
    # Other stores, run with Proton and added to Steam as non-Steam games:
    # Heroic for GOG, Epic and Amazon; Lutris for Battle.net, EA, Ubisoft
    # and Rockstar
    heroic
    lutris
    # Hugging Face Hub CLI (`hf`): model downloads land here
    python3Packages.huggingface-hub
    nvtopPackages.nvidia
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ "@wheel" ];
    # Punktfunk's binary cache; hits only while gm01's nixpkgs follows
    # punktfunk's (see flake.nix)
    extra-substituters = [ "https://nix.unom.io" ];
    extra-trusted-public-keys = [ "punktfunk-cache-1:yhOJmHxzg6tzXpxSFzlYn6Pc6r0jHprsWqt8MZC654o=" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true; # NVIDIA, Steam
  # Fixed in nixpkgs on 2026-10-11 ("typescript-language-server: fix pnpm
  # hash"), just after the nixpkgs punktfunk pins. Drop once gm01's has it.
  nixpkgs.overlays = [
    (_final: prev: {
      typescript-language-server = prev.typescript-language-server.overrideAttrs (old: {
        pnpmDeps = old.pnpmDeps.overrideAttrs {
          outputHash = "sha256-xR/EF60lVBsITKgH7wCM2wHM46PFQevD51KfCENSUH4=";
        };
      });
    })
  ];

  system.stateVersion = "26.11";
}
