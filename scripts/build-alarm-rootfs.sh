#!/usr/bin/env bash
set -eo pipefail

TARBALL_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
# Pinned qcom-va-driver: the VA-API backend for Qualcomm Iris, installed as
# /usr/lib/dri/qcom_drv_video.so together with the msm and v4l2 aliases.  It
# is built as a package in the bootstrap (that is aarch64 already), so the
# target only has to install a .pkg.tar.zst, exactly like qbootctl.
VA_DRIVER_URL=https://github.com/radxa-pkg/qcom-va-driver/archive/0980a1decf26d34c9aa71cd0a4a0d25703a7a17f.tar.gz
VA_DRIVER_SRC=qcom-va-driver-0980a1decf26d34c9aa71cd0a4a0d25703a7a17f
# Desktop-side remote procedure daemon for the ADSP (hexagonrpcd + units).
# The AUR package for this is gone; build from upstream.
HEXAGONRPC_URL=https://github.com/linux-msm/hexagonrpc/archive/da7a3742ab8d5273a281b70ee11f16fb2cb6a690.tar.gz
HEXAGONRPC_SRC=hexagonrpc-da7a3742ab8d5273a281b70ee11f16fb2cb6a690

[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "invalid username"; exit 1; }
[[ "$HOST_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo "invalid hostname"; exit 1; }
if ! [[ "$PACKAGE_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] ||
  [[ "${PACKAGE_REPOSITORY#*/}" = . || "${PACKAGE_REPOSITORY#*/}" = .. ]]; then
  echo "Invalid package repository. Use owner/repo." >&2
  exit 1
fi
PACKAGE_REPO_BASE="https://github.com/$PACKAGE_REPOSITORY/releases/download/repo-pacman"

B="$PWD/bootstrap"   # temporary "live CD" made from the ALARM tarball
T="$PWD/target"      # the new system, installed with pacstrap
mkdir -p "$B" "$T"

# The target directory has to be root owned before anything runs inside
# it.  It used to be created by the runner (uid 1001), and both the
# pacman scriptlets in arch-chroot and systemd-tmpfiles at boot refuse
# to work under a non-root owned "/" ("Detected unsafe path transition
# / (owned by 1001) -> /etc"), which is why the packed image ended up
# with / owned by 1001, /tmp/.X11-unix never created and no Xwayland.
sudo chown root:root "$B" "$T"

# ---- 1. bootstrap environment from the official tarball ----
F="$(basename "$TARBALL_URL")"
curl -fL --retry 3 -O "$TARBALL_URL"
curl -fL --retry 3 -O "$TARBALL_URL.md5"
md5sum -c "$F.md5"
sudo bsdtar -xpf "$F" -C "$B" --numeric-owner
rm -f "$F" "$F.md5"

cleanup() { sudo umount -R "$B" 2>/dev/null || sudo umount -Rl "$B" || true; }
trap cleanup EXIT
sudo mkdir -p "$B/mnt/target"
sudo mount --bind "$B" "$B"
sudo mount -t proc proc "$B/proc"
sudo mount --rbind /sys "$B/sys" && sudo mount --make-rslave "$B/sys"
sudo mount --rbind /dev "$B/dev" && sudo mount --make-rslave "$B/dev"
sudo mount -t tmpfs tmpfs "$B/run"
sudo mount -t tmpfs tmpfs "$B/tmp"
sudo mount --bind "$T" "$B/mnt/target"     # pacstrap needs a mountpoint
sudo rm -f "$B/etc/resolv.conf"
sudo cp -L /etc/resolv.conf "$B/etc/resolv.conf"

bc() { sudo chroot "$B" /usr/bin/env -i HOME=/root TERM=dumb \
         PATH=/usr/local/bin:/usr/bin LANG=C "$@"; }
c()  { bc arch-chroot /mnt/target "$@"; }   # run inside the new system

bc sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
if bc pacman -V | grep -qE 'Pacman v([7-9]|[1-9][0-9])\.'; then
  bc sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi
bc pacman-key --init
bc pacman-key --populate archlinuxarm
bc pacman -Syu --noconfirm
# protobuf-c is what sensh links against; qmic/qrtr are built below
bc pacman -S --needed --noconfirm arch-install-scripts base-devel git meson ninja pkgconf curl protobuf-c

# zstd packages for makepkg (bootstrap side)
bc sed -i -E "s/^#?PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" /etc/makepkg.conf

# ---- 1b. build qbootctl (AUR) inside the bootstrap ----
bc useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' | sudo tee "$B/etc/sudoers.d/99-builder" >/dev/null
sudo chmod 440 "$B/etc/sudoers.d/99-builder"
bc install -d -o builder -g builder /var/tmp/pkgs
bc runuser -u builder -- env PKGDEST=/var/tmp/pkgs bash -c \
  'cd ~ && git clone --depth 1 https://aur.archlinux.org/qbootctl.git && cd qbootctl && makepkg -sA --noconfirm'

# ---- 1c. build qcom-va-driver inside the bootstrap ----
# The plain upstream build (gpu_copy=auto, no CDSP/Vulkan VPP
# skeletons), which is what the board actually runs.
sudo mkdir -p "$B/var/tmp/va-pkg"
sudo tee "$B/var/tmp/va-pkg/PKGBUILD" >/dev/null <<EOF
pkgname=qcom-va-driver
pkgver=1.1.1
pkgrel=1
pkgdesc='VA-API backend for Qualcomm Iris stateful V4L2 M2M decoding and H.264/HEVC encoding'
arch=('aarch64')
url='https://github.com/radxa-pkg/qcom-va-driver'
license=('MIT')
depends=('glibc' 'gcc-libs' 'libva' 'libdrm' 'mesa' 'libglvnd')
makedepends=('meson' 'ninja' 'pkgconf')
options=('!strip')
source=("$VA_DRIVER_URL")
sha256sums=('SKIP')

build() {
  # Same configuration the board runs: GPU copy for surface
  # conversions, no CDSP/Vulkan video processing (those need ghc and
  # Vulkan headers, and VA-API decode/encode does not use them).
  meson setup build "\$srcdir/$VA_DRIVER_SRC" \\
    --buildtype=release --prefix=/usr --libdir=lib \\
    -Dgpu_copy=auto -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled
  meson compile -C build
}

package() {
  DESTDIR="\$pkgdir" meson install -C build --no-rebuild
  install -d "\$pkgdir/usr/share/doc/\$pkgname"
  cp -a "\$srcdir/$VA_DRIVER_SRC/patches" "\$pkgdir/usr/share/doc/\$pkgname/"
}
EOF
# "builder" only exists inside the bootstrap, so the chown has to run there.
bc chown -R builder:builder /var/tmp/va-pkg
bc runuser -u builder -- env PKGDEST=/var/tmp/pkgs bash -c \
  'cd /var/tmp/va-pkg && makepkg -sA --noconfirm'
bc bash -c 'ls -l /var/tmp/pkgs/*.pkg.tar.zst'

# ---- 2. pacstrap: only the base system ----
# Everything above "base" (desktop, audio, fonts, NetworkManager) is
# installed in the chroot below, where the package scriptlets run
# against a root owned target and systemd tooling works.
PKGS=(base base-devel archlinuxarm-keyring git bash zsh openssh vim)

bc pacstrap -K /mnt/target "${PKGS[@]}"

# Copy the packages built in the bootstrap into the new system.
bc bash -c 'cp /var/tmp/pkgs/*.pkg.tar.zst /mnt/target/var/tmp/'

# qbootctl and the VA-API driver were built in 1b/1c; install them
# into the new system before anything verifies them.
c bash -c 'pacman -U --noconfirm /var/tmp/qbootctl-*.pkg.tar.zst'
c bash -c 'pacman -U --noconfirm /var/tmp/qcom-va-driver-*.pkg.tar.zst'

# ---- 2b. install hexagonrpc into the new system ----
# hexagonrpcd is how the desktop reaches the ADSP (file service,
# sensors).  It is a plain meson project; install it into the target
# rootfs directly instead of packaging it, like the firmware blobs.
bc runuser -u builder -- bash -c "
  set -e
  cd ~
  curl -fsSLO '$HEXAGONRPC_URL'
  tar xf $(basename "$HEXAGONRPC_URL")
  cd $HEXAGONRPC_SRC
  meson setup build --buildtype=release --prefix=/usr --libdir=lib
  ninja -C build
  DESTDIR=\$PWD/stage meson install -C build
"
sudo cp -a "$B/home/builder/$HEXAGONRPC_SRC/stage/." "$T/"
# The sensor daemon talks to the ADSP through these two.
c systemctl enable hexagonrpcd-adsp-rootpd hexagonrpcd-adsp-sensorspd

# ---- 2c. install qmic, qrtr and sensh into the new system ----
# sensh is the QMI client that reads the SNS on the ADSP; it needs the
# qmic code generator and libqrtr at build time.  Neither is packaged
# on Arch any more (the AUR entries are gone), so build upstream.
bc runuser -u builder -- bash -c "
  set -e
  cd ~
  git clone --depth 1 https://github.com/linux-msm/qmic qmic-src
  make -C qmic-src
  sudo make -C qmic-src install
  sudo ldconfig
  git clone --depth 1 https://github.com/linux-msm/qrtr qrtr-src
  meson setup qrtr-src/build qrtr-src --buildtype=release --prefix=/usr --libdir=lib
  ninja -C qrtr-src/build
  sudo meson install -C qrtr-src/build
  sudo ldconfig
  git clone --depth 1 https://gitlab.com/flamingradian/sensh sensh-src
  meson setup sensh-src/build sensh-src --buildtype=release --prefix=/usr
  ninja -C sensh-src/build
"
sudo install -Dm755 "$B/home/builder/sensh-src/build/sensh" "$T/usr/local/bin/sensh"
sudo install -Dm755 "$B/usr/bin/qrtr-lookup" "$T/usr/bin/qrtr-lookup"
sudo cp -a "$B"/usr/lib/libqrtr.so* "$T/usr/lib/"
sudo ldconfig -r "$T"
# The daemons run as an unprivileged fastrpc user that owns the
# fastrpc device nodes and the SNS registry.
sudo install -Dm644 /dev/stdin "$T/usr/lib/sysusers.d/fastrpc.conf" >/dev/null <<'EOF'
u fastrpc - "FastRPC" /var/lib/fastrpc
d /var/lib/fastrpc 0755 fastrpc fastrpc
EOF
# The SNS config/registry now arrives with zhiyu-firmware; only the
# writable registry directory has to be created for the fastrpc user.
# The runner has no systemd-sysusers; the target does.
c systemd-sysusers
c install -d -o fastrpc -g fastrpc -m 755 /usr/share/qcom/sensors/registry
sudo sed -i '/^DisableSandbox$/d' "$T/etc/pacman.conf"
sudo rm -f "$T"/var/tmp/*.pkg.tar.zst
c test -x /usr/bin/qbootctl
c test -f /usr/lib/dri/qcom_drv_video.so

# ---- 3. application layer, inside the new system ----
# vulkan-freedreno is Turnip and opencl-mesa is rusticl: without
# them vulkaninfo finds no ICD and clinfo no platform.
APPS=(pipewire-audio pipewire-alsa pipewire-pulse wireplumber alsa-utils
      alsa-ucm-conf libva mesa libva-utils
      vulkan-freedreno opencl-mesa vulkan-tools clinfo
      networkmanager bluez bluez-utils
      noto-fonts noto-fonts-cjk noto-fonts-emoji
      tesseract-data-eng tesseract-data-chi_sim
      man-db man-pages texinfo)

case "$DESKTOP" in
  kde)
    APPS+=(plasma-meta
           kde-accessibility-meta kde-graphics-meta kde-multimedia-meta
           kde-network-meta kde-system-meta kde-utilities-meta)
    DM=plasmalogin ;;
  gnome)
    # Install the desktop pieces instead of the "gnome" group: the
    # group still contains gnome-boxes and gnome-books, whose
    # webkit2gtk dependency ALARM no longer carries, and
    # "--ignore" does not help (pacman then asks "is in
    # IgnorePkg, install anyway? [Y/n]" and --noconfirm answers Y).
    APPS+=(gnome-shell gnome-session gnome-settings-daemon
           gnome-control-center gnome-keyring gnome-backgrounds
           gnome-themes-extra gnome-disk-utility gnome-system-monitor
           gnome-text-editor gnome-console gnome-calculator
           mutter nautilus xdg-desktop-portal-gnome gvfs gdm)
    DM=gdm ;;
  plasmamobile)
    # Plasma Mobile: phone-style shell (plasma-workspace, kwin,
    # plasma-nano, plasma-keyboard, plasma-nm/pa come with it).
    # plasma-mobile is only the shell: no browser, no settings
    # app, no file manager.  Add the apps a tablet needs, plus the
    # mobile settings client.
    APPS+=(plasma-mobile sddm
           angelfish plasma-settings plasma-camera
           dolphin konsole kate okular gwenview ark spectacle
           kalk kclock calindori discover
           breeze-icons upower)
    # plasmalogin kept hanging or spawning a lock screen on this
    # board; sddm with autologin removes the greeter entirely.
    DM=sddm ;;
  none)
    DM= ;;
  *) echo "bad desktop"; exit 1 ;;
esac
c pacman -S --needed --noconfirm "${APPS[@]}"

# ---- 4. configure ----
# locale
sudo sed -i -E 's/^#(en_US\.UTF-8 UTF-8|zh_CN\.UTF-8 UTF-8)/\1/' "$T/etc/locale.gen"
c locale-gen
echo 'LANG=zh_CN.UTF-8' | sudo tee "$T/etc/locale.conf" >/dev/null

# hostname
echo "$HOST_NAME" | sudo tee "$T/etc/hostname" >/dev/null
# Identify the tablet form factor even when the kernel runs under Gunyah.
printf 'CHASSIS=tablet\n' | sudo tee "$T/etc/machine-info" >/dev/null

# users
c useradd -m -G wheel,video,render,input -s "/usr/bin/$LOGIN_SHELL" "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | c chpasswd
c passwd -l root
echo '%wheel ALL=(ALL:ALL) ALL' | sudo tee "$T/etc/sudoers.d/10-wheel" >/dev/null
sudo chmod 440 "$T/etc/sudoers.d/10-wheel"
if [ "$LOGIN_SHELL" = zsh ]; then
  sudo touch "$T/home/$USERNAME/.zshrc"
  c chown "$USERNAME:$USERNAME" "/home/$USERNAME/.zshrc"
fi

# services
c systemctl enable NetworkManager bluetooth
[ -z "$DM" ] || c systemctl enable "$DM"
c systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true

sudo tee -a "$T/etc/pacman.conf" >/dev/null <<EOF

[zhiyu]
SigLevel = Never
Server = $PACKAGE_REPO_BASE
EOF
c pacman -Sy --noconfirm
# The Arch repository only carries the 0.7 libcamera ABI: pacman has no solver
# that would hold a package back, so a 0.8 upgrade would either abort -Syu or
# break the binaries that link against it.
c pacman -S --needed --noconfirm --ask=4 \
  linux-zhiyu-modules linux-zhiyu-headers linux-zhiyu-firmware \
  libcamera-zhiyu zhiyu-sensord linux-zhiyu-images
c systemctl enable zhiyu-sensord

# /etc/resolv.conf ships as a symlink to systemd-resolved's stub
# (resolved itself is part of the systemd package), but resolved
# is not enabled by default: the stub file never exists, nothing
# resolves a name, and NetworkManager hands DNS to a service that
# is not running.  Enable it, like a normal Arch install does
# whenever the stub symlink is present.
c systemctl enable systemd-resolved
# The PMIC RTC (rtc-pm8xxx) works and sets the clock at boot, but
# nothing corrects it: without NTP the image keeps whatever stale
# value the RTC had.  timesyncd also writes the time back.
c systemctl enable systemd-timesyncd
# libcamera's software ISP (the Debayer used by the simple
# pipeline) needs a dma-buf heap.  The kernel exposes
# /dev/dma_heap/* as 0600 root:root, which locks the desktop user
# out ("Could not open any dma-buf provider"), so every GStreamer /
# QtMultimedia camera client fails while libcamera's raw capture
# still works.
# The firmware package installs the board udev rules for DMA heaps,
# the torch LED, focus lens and FastRPC devices.
c systemctl is-enabled systemd-resolved

# makepkg defaults to zstd in the new system
sudo sed -i -E "s/^#?PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" "$T/etc/makepkg.conf"
grep -E '^(PKGEXT|COMPRESSZST)' "$T/etc/makepkg.conf"

# ---- 5. default boot target ----
# Plasma Mobile is hardcoded to the phone form factor by its own
# session script (PLASMA_PLATFORM=phone:handset) even on a 12.7 inch
# tablet.  The shell's metadata does not restrict form factors, so
# ask for the tablet one.
if [ "$DESKTOP" = plasmamobile ]; then
  sudo install -Dm644 /dev/stdin "$T/etc/xdg/kdeglobals" >/dev/null <<EOF
[Icons]
Theme=breeze
EOF
  # Log straight into the mobile session: no greeter, no lock screen,
  # no on-screen keyboard needed.
  sudo install -d "$T/etc/sddm.conf.d"
  printf '[Autologin]\nUser=%s\nSession=plasma-mobile\nRelogin=true\n' "$USERNAME" |
    sudo tee "$T/etc/sddm.conf.d/10-autologin.conf" >/dev/null
fi
if [ "$DESKTOP" = plasmamobile ] && [ -f "$T/usr/bin/startplasmamobile" ]; then
  sudo sed -i 's/^export PLASMA_PLATFORM=.*/export PLASMA_PLATFORM=tablet/' \
    "$T/usr/bin/startplasmamobile"
  grep -n PLASMA_PLATFORM "$T/usr/bin/startplasmamobile"
  # The mobile lock screen asks for a PIN that nobody has set.
  sudo install -Dm644 /dev/stdin "$T/etc/xdg/kscreenlockerrc" >/dev/null <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
fi

# default boot target
c systemctl set-default graphical.target
# sshd is how a headless board is reached at all
c systemctl enable sshd

# mark the booted slot successful on every boot
sudo tee "$T/etc/systemd/system/qbootctl-mark-success.service" >/dev/null <<'EOF'
[Unit]
Description=Mark current boot slot as successful (qbootctl -m)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/qbootctl -m
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
c systemctl enable qbootctl-mark-success.service

# ---- 6. verify what we promised ----
c pacman -Qq | grep -E '^linux($|-)' || echo "no linux* packages installed"
c systemctl is-enabled NetworkManager bluetooth qbootctl-mark-success ${DM:+$DM}
find "$T/usr/lib/firmware" -type f | wc -l
find "$T/usr/share/alsa/ucm2/conf.d/sm8750" -type f | wc -l
c getent group wheel
c systemctl get-default
echo "--- packages that matter:"
c pacman -Qq qbootctl qcom-va-driver
ls -l "$T/usr/lib/dri/" | grep -E 'qcom|msm|v4l2'
echo "--- ownership:"
stat -c '%u:%g %n' "$T" "$T/etc" "$T/tmp"

# ---- 7. cleanup ----
c gpgconf --homedir /etc/pacman.d/gnupg --kill all || true
sudo rm -rf "$T"/var/cache/pacman/pkg/* "$T"/var/log/pacman.log
sudo rm -f "$T/etc/resolv.conf"
: | sudo tee "$T/etc/machine-id" >/dev/null
sudo find "$T/etc/pacman.d/gnupg" -name 'S.*' -delete 2>/dev/null || true
cleanup
trap - EXIT

sudo du -sh "$T"

# Pack the finished rootfs.
OUT="alarm-aarch64-${DESKTOP}-rootfs.tar.xz"
# The top level "." entry must be root owned in the archive too: a
# non-root owned "/" makes systemd-tmpfiles abort at boot.
sudo chown root:root target
# xz -9e is noticeably smaller than zstd -19 here and the runtime is
# acceptable for a rootfs that is downloaded once per device.
sudo tar --numeric-owner --xattrs --acls -C target \
  -I 'xz -9e -T0' -cpf "$OUT" .
sudo chown "$USER" "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
ls -lh "$OUT"
