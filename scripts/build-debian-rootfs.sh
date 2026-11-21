#!/usr/bin/env bash
set -eo pipefail

MIRROR=http://deb.debian.org/debian
# qbootctl marks the boot slot successful (Debian packages it, our ALARM
# image has to build it from the AUR).  qcom-va-driver provides
# /usr/lib/dri/qcom_drv_video.so; Debian has it in sid only, so it is built
# from this pinned tarball when the release does not carry it.
# sid's arm64 package: needs only libva-driver-abi-1.0, libc6 >= 2.34 and
# libstdc++6 >= 14, and the .so itself asks for GLIBC <= 2.34 / GLIBCXX
# <= 3.4.30, so it installs on trixie and forky as well.
VA_DEB_URL=http://deb.debian.org/debian/pool/main/q/qcom-va-driver/qcom-va-driver_1.1.0-1_arm64.deb
VA_DRIVER_URL=https://github.com/radxa-pkg/qcom-va-driver/archive/0980a1decf26d34c9aa71cd0a4a0d25703a7a17f.tar.gz
# Desktop-side remote procedure daemon for the ADSP (hexagonrpcd + units);
# the AUR package is gone, so build upstream.
HEXAGONRPC_URL=https://github.com/linux-msm/hexagonrpc/archive/da7a3742ab8d5273a281b70ee11f16fb2cb6a690.tar.gz
HEXAGONRPC_SRC=hexagonrpc-da7a3742ab8d5273a281b70ee11f16fb2cb6a690
VA_DRIVER_SRC=qcom-va-driver-0980a1decf26d34c9aa71cd0a4a0d25703a7a17f

[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "invalid username"; exit 1; }
[[ "$HOST_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo "invalid hostname"; exit 1; }
if ! [[ "$PACKAGE_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] ||
  [[ "${PACKAGE_REPOSITORY#*/}" = . || "${PACKAGE_REPOSITORY#*/}" = .. ]]; then
  echo "Invalid package repository. Use owner/repo." >&2
  exit 1
fi
PACKAGE_REPO_BASE="https://github.com/$PACKAGE_REPOSITORY/releases/download/repo-apt"

T="$PWD/target"
mkdir -p "$T"
# Root owned from the start: the package maintainer scripts and
# systemd-tmpfiles both refuse to work under a non-root owned "/".
sudo chown root:root "$T"

# ---- 1. debootstrap ----
# mmdebstrap rather than debootstrap: it knows every suite without
# needing a script per codename and it handles usrmerge, so forky/sid
# work with whatever debootstrap the runner happens to ship.
sudo mmdebstrap --arch=arm64 --variant=apt \
  --components=main,contrib,non-free,non-free-firmware \
  --include=systemd,systemd-sysv,dbus,ca-certificates,locales,apt-utils,sudo \
  "$RELEASE" "$T" "$MIRROR"

sudo mount --bind /dev "$T/dev"
sudo mount -t proc proc "$T/proc"
sudo mount -t sysfs sysfs "$T/sys"
sudo cp -L /etc/resolv.conf "$T/etc/resolv.conf"
trap 'sudo umount -R "$T/dev" "$T/proc" "$T/sys" 2>/dev/null || true' EXIT

ch() { sudo chroot "$T" /usr/bin/env -i HOME=/root TERM=dumb \
         PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin DEBIAN_FRONTEND=noninteractive "$@"; }

cat <<EOF | sudo tee "$T/etc/apt/sources.list" >/dev/null
deb $MIRROR $RELEASE main contrib non-free non-free-firmware
deb $MIRROR $RELEASE-updates main contrib non-free non-free-firmware
EOF
if [ "$RELEASE" != "sid" ] && [ "$RELEASE" != "forky" ]; then
  echo "deb http://security.debian.org/debian-security $RELEASE-security main contrib non-free non-free-firmware" |
    sudo tee -a "$T/etc/apt/sources.list" >/dev/null
fi
ch apt-get update

# ---- 2. base system ----
ch apt-get install -y --no-install-recommends \
  sudo curl git vim zsh openssh-server kmod less man-db tzdata \
  passwd pciutils usbutils iproute2 iputils-ping rfkill

# ---- 3. application layer ----
# mesa-vulkan-drivers carries freedreno's Turnip and mesa-opencl-icd
# rusticl: without them vulkaninfo has no ICD and clinfo no platform.
APPS="qbootctl
      wireless-regdb wpasupplicant iw rfkill alsa-ucm-conf
      vainfo systemd-timesyncd xz-utils
      libgl1-mesa-dri mesa-vulkan-drivers mesa-opencl-icd clinfo
      pipewire pipewire-pulse wireplumber alsa-utils
      libva2 libva-drm2 libdrm2 libgbm1
      network-manager bluetooth bluez
      fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
      tesseract-ocr-eng tesseract-ocr-chi-sim"

# The desktop itself comes from the distribution's metapackages, with
# their Recommends: that is how Arch's plasma-meta behaves too, and it
# is what brings systemsettings, plasma-nm, plasma-pa, powerdevil and
# kscreen.  Keeping --no-install-recommends for the rest of the list
# keeps the support packages predictable.
case "$DESKTOP" in
  kde) DESKTOP_PKGS="kde-standard" ;;
  gnome)
    # gnome alone does not pull the Adwaita icon theme or Cantarell:
    # without them the shell has no symbolic icons (missing arrows,
    # missing panel icons) and falls back to an ugly font.
    DESKTOP_PKGS="gnome gdm3 adwaita-icon-theme fonts-cantarell
                  fonts-dejavu-core gnome-themes-extra" ;;
  plasmamobile)
    # plasma-mobile pulls the shell and the mobile settings client;
    # the applications a tablet needs are listed explicitly.
    DESKTOP_PKGS="plasma-mobile sddm
                  angelfish dolphin konsole kate okular gwenview
                  ark kalk kclock discover
                  breeze-icon-theme upower" ;;
  none) DESKTOP_PKGS="" ;;
  *) echo "bad desktop"; exit 1 ;;
esac
ch apt-get install -y --no-install-recommends $APPS
[ -z "$DESKTOP_PKGS" ] || ch apt-get install -y $DESKTOP_PKGS

# The board's userspace (freedreno/msm) wants mesa 26 or newer.
# forky and sid already have it; trixie's main has 25.x, so pull
# mesa from backports there.
if [ "$RELEASE" = "trixie" ]; then
  echo "deb $MIRROR trixie-backports main contrib non-free non-free-firmware" |
    sudo tee -a "$T/etc/apt/sources.list" >/dev/null
  ch apt-get update
  ch apt-get install -y --no-install-recommends -t trixie-backports \
    libgl1-mesa-dri mesa-vulkan-drivers libegl-mesa0 libglx-mesa0 libgbm1
fi
MESA_VER=$(ch dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || true)
echo "mesa (libgl1-mesa-dri): $MESA_VER"
case "$MESA_VER" in
  2[6-9].*|[3-9][0-9].*) ;;
  *) echo "::error::mesa $MESA_VER is older than 26"; exit 1 ;;
esac

# ---- 4. configure ----
sudo sed -i -E 's/^# *(en_US\.UTF-8|zh_CN\.UTF-8)/\1/' "$T/etc/locale.gen"
ch locale-gen
echo 'LANG=zh_CN.UTF-8' | sudo tee "$T/etc/locale.conf" >/dev/null
echo "$HOST_NAME" | sudo tee "$T/etc/hostname" >/dev/null
# Identify the tablet form factor even when the kernel runs under Gunyah.
printf 'CHASSIS=tablet\n' | sudo tee "$T/etc/machine-info" >/dev/null
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOST_NAME" | sudo tee "$T/etc/hosts" >/dev/null
sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai "$T/etc/localtime"

ch useradd -m -G sudo,audio,video,input,render -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | ch chpasswd
echo '%sudo ALL=(ALL:ALL) ALL' | sudo tee "$T/etc/sudoers.d/10-sudo" >/dev/null
sudo chmod 440 "$T/etc/sudoers.d/10-sudo"
ch systemctl enable NetworkManager bluetooth ssh
case "$DESKTOP" in
  kde|plasmamobile)
    # Plasma Mobile installs SDDM above; KDE selects an available manager.
    if [ "$DESKTOP" = plasmamobile ]; then
      ch systemctl enable sddm
    elif ch apt-cache show plasma-login-manager >/dev/null 2>&1; then
      ch apt-get install -y --no-install-recommends plasma-login-manager
      ch systemctl enable plasmalogin
    else
      # trixie has no plasma-login-manager; sddm is the fallback
      ch apt-get install -y --no-install-recommends sddm
      ch systemctl enable sddm
    fi
    ;;
  gnome) ch systemctl enable gdm3 ;;
esac

# A 12.7 inch screen is not a handset: the Plasma Mobile session
# script hardcodes the phone form factor, so ask for tablet.  Its
# shell metadata does not restrict form factors.
if [ "$DESKTOP" = plasmamobile ]; then
  # Neither plasma-mobile nor the look-and-feel sets an icon theme
  # on this image, so everything falls back to hicolor and every
  # symbolic icon (keyboard Enter/Caps, arrows, panel) is blank.
  sudo install -Dm644 /dev/stdin "$T/etc/xdg/kdeglobals" >/dev/null <<EOF
[Icons]
Theme=breeze

[KDE]
LookAndFeelPackage=org.kde.breeze.mobile
EOF
  sudo install -d "$T/etc/sddm.conf.d"
  printf '[Autologin]\nUser=%s\nSession=plasma-mobile\nRelogin=true\n' "$USERNAME" |
    sudo tee "$T/etc/sddm.conf.d/10-autologin.conf" >/dev/null
fi
if [ "$DESKTOP" = plasmamobile ] && [ -f "$T/usr/bin/startplasmamobile" ]; then
  sudo sed -i 's/^export PLASMA_PLATFORM=.*/export PLASMA_PLATFORM=tablet/' \
    "$T/usr/bin/startplasmamobile"
  # The mobile lock screen asks for a PIN that nobody has set.
  sudo install -Dm644 /dev/stdin "$T/etc/xdg/kscreenlockerrc" >/dev/null <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
fi

ch systemctl set-default graphical.target
# sshd is how a headless board is reached at all.  Debian's
# sshd.service is a symlink to ssh.service and systemd refuses to
# enable a "linked" unit.
ch systemctl enable ssh

printf 'deb [arch=arm64 trusted=yes] %s ./\n' "$PACKAGE_REPO_BASE" |
  sudo tee "$T/etc/apt/sources.list.d/zhiyu.list" >/dev/null
ch apt-get update
# The repository carries both libcamera ABIs; ask for the 0.7 one, which is
# what the packages that link against libcamera in this image are built for.
ch apt-get install -y --no-install-recommends \
  linux-zhiyu-modules linux-zhiyu-headers linux-zhiyu-firmware \
  'libcamera-zhiyu=0.7.*' zhiyu-sensord linux-zhiyu-images
ch systemctl enable zhiyu-sensord

# ---- 5. VA-API driver ----
# Use Debian's own package (sid builds an arm64 .deb that installs
# fine on trixie and forky) and only build the pinned upstream
# tarball when it cannot be fetched.
sudo mkdir -p "$T/var/tmp/build"
if sudo curl -fsSL "$VA_DEB_URL" -o "$T/var/tmp/qcom-va-driver.deb"; then
  echo "installing Debian's qcom-va-driver package"
  ch apt-get install -y --no-install-recommends /var/tmp/qcom-va-driver.deb
else
  echo "cannot fetch the Debian package, building $VA_DRIVER_SRC"
  ch apt-get install -y --no-install-recommends \
    meson ninja-build pkg-config g++ libva-dev libdrm-dev \
    libgbm-dev libegl-dev libgles-dev
  sudo curl -fsSL "$VA_DRIVER_URL" -o "$T/var/tmp/build/va.tar.gz"
  ch tar -xzf /var/tmp/build/va.tar.gz -C /var/tmp/build
  ch meson setup /var/tmp/build/va-build "/var/tmp/build/$VA_DRIVER_SRC" \
    --buildtype=release --prefix=/usr --libdir=lib \
    -Dgpu_copy=auto -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled
  ch meson compile -C /var/tmp/build/va-build
  ch env DESTDIR=/var/tmp/va-root meson install \
    -C /var/tmp/build/va-build --no-rebuild
  sudo install -d "$T/var/tmp/va-root/DEBIAN"
  printf 'Package: qcom-va-driver\nVersion: 1.1.1-1\nArchitecture: arm64\nMaintainer: rootfs-builder\nDepends: libva2, libdrm2, libgbm1, libegl1, libgles2\nDescription: VA-API backend for Qualcomm Iris stateful V4L2 M2M\n' |
    sudo tee "$T/var/tmp/va-root/DEBIAN/control" >/dev/null
  sudo chown -R root:root "$T/var/tmp/va-root"
  sudo dpkg-deb --build --root-owner-group "$T/var/tmp/va-root" "$T/var/tmp/qcom-va-driver.deb" >/dev/null
  ch dpkg -i /var/tmp/qcom-va-driver.deb
fi

# ---- 5c. hexagonrpc (ADSP remote procedure daemon) ----
# hexagonrpcd + its systemd units; the sensor daemon and anything
# else talking to the ADSP needs these.
sudo mkdir -p "$T/var/tmp/build"
sudo curl -fsSL "$HEXAGONRPC_URL" -o "$T/var/tmp/build/hrpc.tar.gz"
ch tar -xzf /var/tmp/build/hrpc.tar.gz -C /var/tmp/build
ch apt-get install -y --no-install-recommends meson ninja-build pkg-config g++ libsystemd-dev curl
ch meson setup /var/tmp/build/hrpc-build "/var/tmp/build/$HEXAGONRPC_SRC" \
  --buildtype=release --prefix=/usr --libdir=lib
ch meson compile -C /var/tmp/build/hrpc-build
ch env DESTDIR=/var/tmp/build/hrpc-root meson install \
  -C /var/tmp/build/hrpc-build --no-rebuild
sudo cp -a "$T/var/tmp/build/hrpc-root/." "$T/"
ch systemctl enable hexagonrpcd-adsp-rootpd hexagonrpcd-adsp-sensorspd

# ---- 5d. sensh (SNS client) and its build-time deps ----
# sensh reads the ADSP sensor service over QMI; it needs the qmic
# code generator and libqrtr.  None of this is packaged in Debian,
# so build it from upstream inside the chroot.
ch apt-get install -y --no-install-recommends \
  build-essential meson ninja-build pkg-config git \
  libprotobuf-c-dev protobuf-c-compiler
ch git clone --depth 1 https://github.com/linux-msm/qmic /var/tmp/qmic-src
ch make -C /var/tmp/qmic-src
ch make -C /var/tmp/qmic-src install
ch git clone --depth 1 https://github.com/linux-msm/qrtr /var/tmp/qrtr-src
ch meson setup /var/tmp/qrtr-src/build /var/tmp/qrtr-src \
  --buildtype=release --prefix=/usr --libdir=lib
ch meson compile -C /var/tmp/qrtr-src/build
ch meson install -C /var/tmp/qrtr-src/build
ch git clone --depth 1 https://gitlab.com/flamingradian/sensh /var/tmp/sensh-src
ch meson setup /var/tmp/sensh-src/build /var/tmp/sensh-src \
  --buildtype=release --prefix=/usr
ch meson compile -C /var/tmp/sensh-src/build
ch install -Dm755 /var/tmp/sensh-src/build/sensh /usr/local/bin/sensh
ch ldconfig
# fastrpc user + device node group, and the SNS registry/config that
# hexagonrpcd serves to the ADSP (from the stock vendor image).
sudo install -Dm644 /dev/stdin "$T/usr/lib/sysusers.d/fastrpc.conf" >/dev/null <<'EOF'
u fastrpc - "FastRPC" /var/lib/fastrpc
d /var/lib/fastrpc 0755 fastrpc fastrpc
EOF
# The SNS config/registry arrives with zhiyu-firmware; only the
# writable registry directory has to be created for the fastrpc user.
ch systemd-sysusers || true
ch install -d -o fastrpc -g fastrpc -m 755 /usr/share/qcom/sensors/registry

# ---- 6. boot slot marking ----
# Trigger the packaged service from udev and wait for both slot links.
ch systemctl disable qbootctl.service
sudo install -Dm644 /dev/stdin "$T/etc/udev/rules.d/90-zhiyu-qbootctl.rules" <<'EOF'
SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_SCHEME}=="gpt", ENV{ID_PART_ENTRY_NAME}=="boot_b", TAG+="systemd", ENV{SYSTEMD_WANTS}+="qbootctl.service"
EOF
sudo install -Dm644 /dev/stdin "$T/etc/systemd/system/qbootctl.service.d/10-zhiyu.conf" <<'EOF'
[Unit]
ConditionPathExistsGlob=
Requires=dev-disk-by\x2dpartlabel-boot_a.device dev-disk-by\x2dpartlabel-boot_b.device
Requisite=multi-user.target
After=multi-user.target dev-disk-by\x2dpartlabel-boot_a.device dev-disk-by\x2dpartlabel-boot_b.device
EOF

# ---- 7. verify ----
UNITS="NetworkManager bluetooth"
case "$DESKTOP" in
  kde) UNITS="$UNITS plasmalogin || true" ;;
  plasmamobile) UNITS="$UNITS sddm" ;;
  gnome) UNITS="$UNITS gdm3" ;;
esac
ch systemctl is-enabled $UNITS || true
ch systemctl is-enabled display-manager 2>/dev/null || true
ch systemctl get-default
ch dpkg-query -W --showformat='${Package} ${Version}\n' qbootctl qcom-va-driver mesa-libgallium 2>/dev/null || true
# Debian's libva looks in /usr/lib/<triplet>/dri; find avoids the
# ls exit status of a directory that does not exist (set -o pipefail).
find "$T/usr/lib" -name '*_drv_video.so' 2>/dev/null | head || true
ls -ld "$T/usr/share/alsa/ucm2/conf.d/sm8750" || echo "::warning::UCM profile missing in the image"
find "$T/usr/lib/firmware" -type f | wc -l
md5sum "$T/usr/lib/firmware/qcom/sm8750/sm8750-tplg.bin"
stat -c '%u:%g %n' "$T" "$T/etc" "$T/tmp"

# Debian has no systemd-resolved (it is a separate package there and
# nothing symlinks /etc/resolv.conf to its stub, unlike Arch), so
# there is nothing to enable: NetworkManager writes resolv.conf.
# The PMIC RTC (rtc-pm8xxx) works and sets the clock at boot, but
# nothing corrects it: without NTP the image keeps whatever stale
# value the RTC had.  timesyncd also writes the time back.
ch systemctl enable systemd-timesyncd
# libcamera's software ISP (the Debayer used by the simple
# pipeline) needs a dma-buf heap.  The kernel exposes
# /dev/dma_heap/* as 0600 root:root, which locks the desktop user
# out ("Could not open any dma-buf provider"), so every GStreamer /
# QtMultimedia camera client fails while libcamera's raw capture
# still works. The firmware package provides the board DMA/LED/V4L
# udev rules.
# ---- 8. cleanup ----
# Unmount the chroot pseudo filesystems before measuring the tree:
# du would otherwise walk /proc of the runner and return 1, which
# set -e turns into a failed job after everything else succeeded.
sudo umount -R "$T/proc" 2>/dev/null || true
sudo umount -R "$T/sys" 2>/dev/null || true
sudo umount -R "$T/dev" 2>/dev/null || true
trap - EXIT
sudo rm -rf "$T/var/tmp/build" "$T/var/tmp/va-root" "$T/var/tmp/qcom-va-driver.deb"
sudo rm -f "$T/etc/resolv.conf"
ch apt-get clean
sudo rm -rf "$T/var/lib/apt/lists"/* "$T/var/log/apt"/* || true
: | sudo tee "$T/etc/machine-id" >/dev/null
sudo du -sh "$T" 2>/dev/null || true

# Pack the finished rootfs.
OUT="debian-${RELEASE}-aarch64-${DESKTOP}-rootfs.tar.xz"
sudo chown root:root target
sudo tar --numeric-owner --xattrs --acls -C target -I 'xz -9e -T0' -cpf "$OUT" .
sudo chown "$USER" "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"
ls -lh "$OUT"
