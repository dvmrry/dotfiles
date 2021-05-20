<p align="center"><img height="250" src="https://pbs.twimg.com/media/B0L0FqdCAAAijik?format=jpg&name=4096x4096"></p>

<p align="center"><strong>An Ansible playbook to configure Debian</strong></p>
<p align="center">
  <a href="#usage">Usage</a> •
  <a href="#roles">Roles</a> •
  <a href="#license">License</a>
</p>

<h1></h1>

Ansible driven script to bootstrap a new enviornment.
Creates a user, installs necessary programs and links configuration files.
Can be used for terminal-only base utilities or full desktop enviornement.

## Usage


```sh
sh -c "$(wget -O- https://git.cleganebowl.io/ddt/adm/raw/master/adm.sh)"
```

### Applying a specific profile and/or tag

A specific profile can be applied by setting the `PROFILE` variable before the bootstraping commands. The definition of these profiles can be found in the `host_vars` directory. If no profile is specified, the [generic profile](host_vars/generic.yml) will be applied. The following example shows how to use this variable:

```sh
PROFILE=cyril.thigis sh -c "$(wget -O- https://git.cleganebowl.io/ddt/adm/raw/master/adm.sh)"
```

It is also possible to run only specifc parts by using the `--tags` options. For example, the following command will only run the bootstrap tasks, which will prepare the repositories and install some required packages:

```sh
PROFILE=cyril.thigis TAGS=bootstrap sh -c "$(wget -O- https://git.cleganebowl.io/ddt/adm/raw/master/adm.sh)"
```

### Running the playbook manually

Once the system has been bootstrapped, a copy of the git repository will be placed in `${HOME}/src/ddt/adm`. To apply the playbook manually from that repository, execute the following commands:

```sh
cd ~/src/ddt/adm
git pull origin master
ansible-playbook -i inventory playbook.yml --diff [--limit PROFILE] [--tags TAGS] --ask-become-pass
```

Note that both, limit and tags, are optional arguments.


## Roles

<table>
  <thead>
    <tr>
      <th align="left" width="130">Name</th>
      <th align="left">Description</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><a href="roles/base">base</a></td>
      <td>Installs alsa-utils, bc, build-essential, curl, dnsutils, feh, java, light, lldpd, nfs-common, scrot, sshpass, tcpdump, tlp, tree, unzip, xdg-user-dirs</a>
    </td>
    <tr>
      <td><a href="roles/brave">brave-browser</a></td>
      <td>Installs <a href="https://github.com/brave/brave-browser/">brave-browser</a>
    </td>
    <tr>
      <td><a href="roles/dunst">dunst</a></td>
      <td>Configures system notifications to use <a href="https://github.com/dunst-project/dunst/">dunst</a> </td>
    </tr>
    <tr>
      <td><a href="roles/fonts">fonts</a></td>
      <td>Installs a curated <a href="roles/fonts/vars/main.yml/">list</a> of fonts</td>
    </tr>
    <tr>
      <td><a href="roles/kitty">kitty</a></td>
      <td>Installs <a href="https://github.com/kovidgoyal/kitty/">kitty</a></td>
    </tr>
    <tr>
      <td><a href="roles/luakit">luakit</a></td>
      <td>Installs <a href="https://github.com/luakit/luakit/">luakit</a></td>
    </tr>
    <tr>
      <td><a href="roles/mpv">mpv</a></td>
      <td>Installs <a href="https://github.com/mpv-player/mpv/">mpv</a></td>
    </tr>
    <tr>
      <td><a href="roles/parsec">parsec</a></td>
      <td>Installs <a href="https://www.github.com/parsec-cloud/parsec-sdk/">parsec</a></td>
    </tr>
    <tr>
      <td><a href="roles/picom">picom</a></td>
      <td>Installs sdhand's fork of <a href="https://github.com/sdhand/picom/">picom</a></td>
    </tr>
    <tr>
      <td><a href="roles/rclone">rclone</a></td>
      <td>Installs <a href="https://github.com/rclone/rclone/">rclone</a></td>
    </tr>
    <tr>
      <td><a href="roles/rremmina">remmina</a></td>
      <td>Installs <a href="https://github.com/freerdp/remmina/">remmina</a></td>
    </tr>
    <tr>
      <td><a href="roles/rofi">rofi</a></td>
      <td>Installs <a href="https://github.com/davatorium/rofi/">rofi</a></td>
    </tr>
    <tr>
      <td><a href="roles/runelite">runelite</a></td>
      <td>Installs <a href="https://github.com/runelite/runelite/">runelite</a></td>
    </tr>
    <tr>
      <td><a href="roles/spotify">spotify</a></td>
      <td>Installs <a href="https://www.spotify.com/">spotify</a></td>
    </tr>
    <tr>
      <td><a href="roles/tmux">tmux</a></td>
      <td>Installs <a href="https://github.com/tmux/tmux/">tmux</a></td>
    </tr>
    <tr>
      <td><a href="roles/user">user</a></td>
      <td>Manages the creation of users</td>
    </tr>
    <tr>
      <td><a href="roles/xorg">xorg</a></td>
      <td>Installs <a href="https://github.com/freedesktop/xorg-xserver/">xorg</a></td>
    </tr>
        <tr>
      <td><a href="roles/vim">vim</a></td>
      <td>Installs <a href="https://github.com/vim/vim/">vim</a> along with <a href="https://github.com/junegunn/vim-plug">vim-plug</a> and assorted plugins</td>
    </tr>
    <tr>
      <td><a href="roles/wireshark">wireshark</a></td>
      <td>Installs <a href="https://github.com/wireshark/wireshark/">wireshark</a></td>
    </tr>
    <tr>
      <td><a href="roles/zsh">zsh</a></td>
      <td>Installs <a href="https://github.com/zsh-users/zsh/">zsh</a> along with a trimmed <a href="https://github.com/ohmyzsh/ohmyzsh">ohmyzsh</a> and <a href="https://github.com/zsh-users/zsh-autosuggestions">autosuggestions</a> plugin</td>
    </tr>

  </tbody>
</table>

## License

No idea but everything is fully available - maybe GNU 3.0? 
