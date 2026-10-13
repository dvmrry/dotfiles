# Prometheus exporters for the LAN inference boxes, scraped every 30s by the
# talos-homelab cluster's kube-prometheus-stack (talos-gitops ScrapeConfigs
# `inference-node`/`inference-gpu`). Kept off the inference path: lowest CPU,
# IO and scheduling priority, nothing heavier than one nvidia-smi per scrape,
# ports open only to the Talos nodes (Cilium masquerades off-cluster traffic
# to the node IP of whichever node runs Prometheus).
{ config, lib, ... }:
let
  cfg = config.inferenceExporters;
  scrapers = "172.18.0.30-172.18.0.32"; # tm01-03
  lowPriority = {
    Nice = 19;
    CPUWeight = 1;
    IOSchedulingClass = "idle";
  };
  allow = port: ''
    iptables -A nixos-fw -p tcp --dport ${toString port} -m iprange --src-range ${scrapers} -j nixos-fw-accept
  '';
in
{
  options.inferenceExporters = {
    nvidiaGpu = lib.mkEnableOption "the NVIDIA GPU exporter (nvidia-smi based, :9835)";
    extraCollectors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "node_exporter collectors to enable beyond its defaults (e.g. drm for an AMD iGPU).";
    };
  };

  config = {
    services.prometheus.exporters.node = {
      enable = true;
      port = 9100;
      enabledCollectors = cfg.extraCollectors;
    };
    systemd.services.prometheus-node-exporter.serviceConfig = lowPriority;

    services.prometheus.exporters.nvidia-gpu = lib.mkIf cfg.nvidiaGpu {
      enable = true;
      port = 9835;
    };
    systemd.services.prometheus-nvidia-gpu-exporter.serviceConfig = lib.mkIf cfg.nvidiaGpu lowPriority;

    networking.firewall.extraCommands = allow 9100 + lib.optionalString cfg.nvidiaGpu (allow 9835);
  };
}
