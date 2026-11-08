# Prometheus exporters for the LAN inference boxes, scraped every 30s by the
# talos-homelab cluster's kube-prometheus-stack (talos-gitops ScrapeConfigs
# `inference-node`/`inference-gpu`). Kept off the inference path: lowest CPU,
# IO and scheduling priority, nothing heavier than one nvidia-smi per scrape,
# ports open only to the Talos nodes (Cilium masquerades off-cluster traffic
# to the node IP of whichever node runs Prometheus).
#
# The same masquerading means any pod in the cluster arrives as a node, so the
# nodes may open connections to clusterPorts only: before this, every pod could
# reach SSH and the LLM APIs that are open to the LAN (Talos session, 2026-11-08).
{ config, lib, ... }:
let
  cfg = config.inferenceExporters;
  scrapers = "172.18.0.30-172.18.0.32"; # tm01-03
  lowPriority = {
    Nice = 19;
    CPUWeight = 1;
    IOSchedulingClass = "idle";
  };
  ports = lib.concatMapStringsSep "," toString cfg.clusterPorts;
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
    clusterPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "TCP ports the Talos nodes may connect to; they are opened to the nodes and every other new connection from them is refused.";
    };
  };

  config = {
    inferenceExporters.clusterPorts = [ 9100 ] ++ lib.optional cfg.nvidiaGpu 9835;
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

    # In mangle PREROUTING, ahead of podman's DNAT: a container's published
    # port (Halogen on im01, podman-strata on gm01) is forwarded and never
    # reaches nixos-fw (2026-11-08: im01:8731 answered a pod while :22 was
    # dropped). NEW only, so replies to this host's own connections into the
    # cluster still pass. Its own chain, so a firewall reload replaces it.
    networking.firewall.extraCommands = ''
      iptables -t mangle -N inference-cluster 2>/dev/null || iptables -t mangle -F inference-cluster
      iptables -t mangle -C PREROUTING -j inference-cluster 2>/dev/null || iptables -t mangle -I PREROUTING -j inference-cluster
      iptables -t mangle -A inference-cluster -m conntrack --ctstate NEW -m iprange --src-range ${scrapers} -p tcp -m multiport ! --dports ${ports} -j DROP
      iptables -t mangle -A inference-cluster -m conntrack --ctstate NEW -m iprange --src-range ${scrapers} -p udp -j DROP
    ''
    + lib.concatMapStrings allow cfg.clusterPorts;
    networking.firewall.extraStopCommands = ''
      iptables -t mangle -D PREROUTING -j inference-cluster 2>/dev/null || true
      iptables -t mangle -F inference-cluster 2>/dev/null || true
      iptables -t mangle -X inference-cluster 2>/dev/null || true
    '';
  };
}
