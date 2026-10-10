# Media playback (mpv) and live view of the USB capture card (macOS only:
# capview reads the card through AVFoundation)
{ pkgs, ... }: {
  home.packages = [ pkgs.ffmpeg ];

  programs.mpv = {
    enable = true;
    config = {
      vo = "gpu-next";
      hwdec = "auto-safe";
      keep-open = "yes";
      save-position-on-quit = "yes";
      screenshot-directory = "~/Desktop";
    };
    profiles.capture = {
      profile = "low-latency";
      untimed = "yes";
      cache = "no";
      keep-open = "no";
      save-position-on-quit = "no";
      force-media-title = "capture";
    };
  };

  # mpv's own av://avfoundation input quits after a second: ffmpeg returns
  # EAGAIN between frames and mpv counts ten in a row as end of file.
  # ffmpeg waits properly, so it reads the card and mpv only displays it.
  programs.fish.functions.capview = {
    description = "Live view of the capture card (default: Hagibis, 1080p60)";
    body = ''
      set -l dev Hagibis
      set -q argv[1]; and set dev $argv[1]
      ffmpeg -hide_banner -loglevel error -f avfoundation \
        -framerate 60 -video_size 1920x1080 -pixel_format uyvy422 \
        -i "$dev:$dev" -c copy -f nut - | mpv --profile=capture -
    '';
  };
}
