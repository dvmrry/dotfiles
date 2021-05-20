#alias feh='feh -. -B black -g 628x580'

# cd to dotfiles
alias dotfiles='cd $DOTFILES'

# Brave
alias brave='brave-browser'

# openbsd commands 
alias zzz='systemctl suspend'
alias ZZZ='systemctl hibernate'
alias doas='sudo'

# network util replacement with ip
alias ifconfig='ip a l'
alias route='ip route'

# RuneLite
alias rcbad='java -jar ~/.runelite/RuneLite.jar'

# Kitty SSH
alias kssh='kitty +kitten ssh $1'

# Launcher
# alias launcher='rofi -show run -theme slate'

# Record Screen
alias record='ffmpeg -video_size 2560x1440 -framerate 25 -f x11grab -i :0.0 -f alsa -ac 2 -i hw:0 output.mp4'

# Transfer.sh Upload
transfer() {
  if [ $# -eq 0 ]; then
    echo -e "No arguments specified. Usage:\necho transfer /tmp/test.md\ncat /tmp/test.md | transfer test.md";
    return 1;
  fi
  tmpfile=$( mktemp -t transferXXX );
  if tty -s; then
    basefile=$(basename "$1" | sed -e 's/[^a-zA-Z0-9._-]/-/g');
    curl --retry 3 --connect-timeout 60 --progress-bar --upload-file "$1" "https://transfer.sh/$basefile" >> $tmpfile;
  else
    curl --retry 3 --connect-timeout 60 --progress-bar --upload-file "-" "https://transfer.sh/$1" >> $tmpfile ;
  fi;
  cat $tmpfile;
  rm -f $tmpfile;
}

# Colorized man pages
man() {
    LESS_TERMCAP_mb=$'\e[0;31m' \
        LESS_TERMCAP_md=$'\e[01;35m' \
        LESS_TERMCAP_me=$'\e[0m' \
        LESS_TERMCAP_se=$'\e[0m' \
        LESS_TERMCAP_so=$'\e[01;31;31m' \
        LESS_TERMCAP_ue=$'\e[0m' \
        LESS_TERMCAP_us=$'\e[0;36m' \
        command man "$@"
}
