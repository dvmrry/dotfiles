# Network engineering kit for the hosts Dave works from (cm02, and cm01 as a
# jumpbox), Mac or NixOS. The handful every box gets (dig, mtr, iperf3,
# tcpdump) stay in cli.nix. System packages rather than home ones, so sudo
# finds the tools that need root. On the Macs, capture (tshark, termshark,
# ngrep) needs sudo unless Wireshark's ChmodBPF helper is installed.
{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    # Path and latency
    trippy # mtr-style TUI with per-hop graphs (`trip`)
    gping

    # Discovery
    arping
    fping
    nmap

    # Capture
    ngrep
    termshark # Wireshark-style TUI over tshark
    wireshark-cli # tshark, dumpcap, editcap, mergecap

    # Traffic and bandwidth
    bandwhich # per process
    iftop

    # DNS, addressing, lookup
    doggo # dig with DoH/DoT and JSON output
    ipcalc
    sipcalc
    whois

    # Plumbing, TLS and PKI
    openssl
    socat
    step-cli

    # Serial console (console cables to switches)
    tio

    # Management protocols
    gnmic # gNMI
    grpcurl
    net-snmp # snmpwalk, snmpget
  ];
}
