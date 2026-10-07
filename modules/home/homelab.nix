# Kubernetes / Talos / Flux / OpenTofu tooling and shortcuts for the homelab.
{ pkgs, inputs, ... }:
let
  # Version-matched to the cluster; see nixpkgs-cluster in flake.nix
  cluster = inputs.nixpkgs-cluster.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in {
  home.packages = (with pkgs; [
    fluxcd
    kubecolor
    kubectx
    kubernetes-helm
    opentofu
    talhelper
  ]) ++ [
    cluster.kubectl
    cluster.talosctl
  ];

  programs.fish = {
    shellAliases = {
      k = "kubecolor";
      tf = "tofu";
    };
    shellAbbrs = {
      # Kubernetes
      kgd = "kubecolor get deploy";
      kgk = "kubecolor get kustomizations --all-namespaces";
      kgp = "kubecolor get pods";
      kgpv = "kubecolor get pv";
      kgpvc = "kubecolor get pvc";
      kgs = "kubecolor get services";
      kpf = "kubecolor port-forward";
      kctx = "kubectx";
      kns = "kubens";

      # Terraform / OpenTofu
      tfa = "tofu apply";
      tfi = "tofu init";
      tfp = "tofu plan";
    };
    interactiveShellInit = ''
      # Tool completions - cached to avoid slow generation on every shell start
      set -l comp_dir ~/.cache/fish/generated_completions
      mkdir -p $comp_dir
      for tool in kubectl helm flux talosctl
        if not test -f $comp_dir/$tool.fish
          command $tool completion fish > $comp_dir/$tool.fish 2>/dev/null &
        end
      end
      for f in $comp_dir/*.fish
        source $f 2>/dev/null
      end
      complete -c kubecolor -w kubectl
      complete -c k -w kubectl
    '';
  };

  programs.zsh.shellAliases = {
    k = "kubecolor";
    kgd = "kubecolor get deploy";
    kgk = "kubecolor get kustomizations --all-namespaces";
    kgp = "kubecolor get pods";
    kgpv = "kubecolor get pv";
    kgpvc = "kubecolor get pvc";
    kgs = "kubecolor get services";
    kpf = "kubecolor port-forward";
    kctx = "kubectx";
    kns = "kubens";
    tf = "tofu";
    tfa = "tofu apply";
    tfi = "tofu init";
    tfp = "tofu plan";
  };

  programs.starship.settings.kubernetes = {
    disabled = false;
    symbol = " ";
    format = "[$symbol$context( \\($namespace\\))](dimmed #7aa2f7) ";
  };
}
