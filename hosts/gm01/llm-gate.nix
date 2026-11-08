# A door from the talos-homelab cluster to gm01's model: the engine on
# 127.0.0.1:8743, the one cm02 reaches through its SSH tunnel. For jobs in the
# cluster (the zscaler-skill KB fixer's GitHub runner). Strata accepts other
# binds only with its own API key, which loopback clients would then need too,
# so the key is checked here and loopback stays as it is.
#
# Answers, on :8744 with `Authorization: Bearer <key>`:
#   401  no key or the wrong one
#   503  an experiment holds the box: rig writes /run/llm/busy at the start of
#        a run and removes it at the end (a killed run leaves it until a reboot
#        or `sudo rm /run/llm/busy`)
#   502  nothing serves 127.0.0.1:8743 (stopped, or Dave is playing)
#   else whatever the engine answers
#
# The key is made on the box at the first start and never enters the store:
# /var/lib/llm/gate/key. The cluster's copy is in 1Password (vault talos, item
# talos-gitops-gm01-llm). Only the Talos nodes may connect (Cilium masquerades
# pod traffic to the node IP), as for the exporters.
{ pkgs, ... }:
let
  port = 8744;
  nodes = "172.18.0.30-172.18.0.32"; # tm01-03
  dir = "/var/lib/llm/gate";
in
{
  systemd.services.llm-gate-key = {
    description = "LLM gate key (made once)";
    before = [ "nginx.service" ];
    requiredBy = [ "nginx.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0750 -o root -g nginx ${dir}
      if [ ! -s ${dir}/key ]; then
        (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > ${dir}/key)
      fi
      # nginx runs as nginx, so it reads its include as that user
      printf '"Bearer %s" 1;\n' "$(cat ${dir}/key)" > ${dir}/key.map
      chown root:nginx ${dir}/key.map
      chmod 0640 ${dir}/key.map
    '';
  };

  services.nginx = {
    enable = true;
    appendHttpConfig = ''
      map $http_authorization $llm_gate_key_ok {
        default 0;
        include ${dir}/key.map;
      }
    '';
    virtualHosts.llm-gate = {
      listen = [
        {
          addr = "0.0.0.0";
          inherit port;
        }
      ];
      locations."/".extraConfig = ''
        default_type application/json;
        if ($llm_gate_key_ok = 0) {
          return 401 '{"error":{"type":"unauthorized","message":"gm01 LLM gate: missing or wrong key"}}';
        }
        if (-f /run/llm/busy) {
          return 503 '{"error":{"type":"busy","message":"gm01 is running an experiment; try later"}}';
        }
        proxy_pass http://127.0.0.1:8743;
        proxy_http_version 1.1;
        # Strata serves loopback Host headers only; it has no key of its own here
        proxy_set_header Host 127.0.0.1:8743;
        proxy_set_header Authorization "";
        proxy_buffering off; # streamed completions
        proxy_read_timeout 30m; # one long generation, queued behind another
        client_max_body_size 64m;
      '';
    };
  };

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp --dport ${toString port} -m iprange --src-range ${nodes} -j nixos-fw-accept
  '';
}
