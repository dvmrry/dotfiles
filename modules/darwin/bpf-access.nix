# Packet capture without sudo, the way Wireshark's ChmodBPF does it: members of
# access_bpf get read/write on /dev/bpf*. macOS recreates the devices at boot,
# so a daemon reapplies the group and mode each time. This lets anything running
# as dm (agents included) capture every interface.
_: {
  users.knownGroups = [ "access_bpf" ];
  users.groups.access_bpf = {
    gid = 520;
    members = [ "dm" ];
    description = "BPF device access (packet capture)";
  };

  launchd.daemons.chmod-bpf = {
    script = ''
      # Devices are created on first open; pre-create them (up to the kernel's
      # limit, as ChmodBPF does) so every one gets the group
      max=$(/usr/sbin/sysctl -n debug.bpf_maxdevices)
      [ "$max" -gt 256 ] && max=256
      dev=1
      while [ "$dev" -lt "$max" ]; do
        read -r -n 0 < "/dev/bpf$dev" >/dev/null 2>&1 || break
        dev=$((dev + 1))
      done
      /usr/bin/chgrp access_bpf /dev/bpf*
      /bin/chmod g+rw /dev/bpf*
    '';
    serviceConfig = {
      RunAtLoad = true;
      StandardOutPath = "/var/log/chmod-bpf.log";
      StandardErrorPath = "/var/log/chmod-bpf.log";
    };
  };
}
