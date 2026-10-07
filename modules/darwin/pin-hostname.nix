# Undo mDNS conflict renames ("cm02-2", "cm02 (2)") as soon as they happen.
# macOS can't be told not to rename, so watch the SystemConfiguration prefs and
# reassert the networking.* names. Only writes when a name actually drifted, so
# it doesn't retrigger itself.
{ config, ... }:
let
  inherit (config.networking) computerName hostName localHostName;
in {
  launchd.daemons.pin-hostname = {
    script = ''
      pin() {
        if [ "$(/usr/sbin/scutil --get "$1" 2>/dev/null)" != "$2" ]; then
          echo "$(date '+%F %T') $1 drifted to '$(/usr/sbin/scutil --get "$1" 2>/dev/null)', resetting to '$2'"
          /usr/sbin/scutil --set "$1" "$2"
        fi
      }
      pin ComputerName "${computerName}"
      pin HostName "${hostName}"
      pin LocalHostName "${localHostName}"
    '';
    serviceConfig = {
      RunAtLoad = true;
      WatchPaths = [ "/Library/Preferences/SystemConfiguration/preferences.plist" ];
      # Back off if something is genuinely fighting over the name
      ThrottleInterval = 30;
      StandardOutPath = "/var/log/pin-hostname.log";
      StandardErrorPath = "/var/log/pin-hostname.log";
    };
  };
}
