#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) == 0 && $(xbps-uhelper arch) == aarch64 ]] || { echo 'Use a native aarch64 glibc Void container as root' >&2; exit 2; }
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$USERNAME" != root ]] || exit 2
[[ "$HOST_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || exit 2
[[ "$PACKAGE_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] || exit 2
case "${PACKAGE_REPOSITORY#*/}" in .|..) exit 2;; esac
case "$LOGIN_SHELL" in bash|zsh) ;; *) exit 2;; esac
# chpasswd consumes one username:password record per line.
if [[ -z "$PASSWORD" || "$PASSWORD" == *$'\n'* || "$PASSWORD" == *$'\r'* ]]; then
    echo 'Initial password must be nonempty and contain no line breaks' >&2
    exit 2
fi
case "$DESKTOP" in
    kde) desktop=(kde-plasma kde-baseapps sddm xorg-minimal xorg-server-xwayland plasma-keyboard); dm=sddm ;;
    gnome) desktop=(gnome-core gnome-console gnome-text-editor gnome-calculator gnome-system-monitor xorg-server-xwayland); dm=gdm ;;
    none) desktop=(); dm= ;;
    *) exit 2 ;;
esac
BSP="https://github.com/$PACKAGE_REPOSITORY/releases/download/repo-xbps/"
OFFICIAL=https://repo-default.voidlinux.org/current/aarch64
T=$(mktemp -d)
# Keep downloaded packages outside the filesystem that will be archived.
build_cache=$(mktemp -d)
# mktemp creates mode 0700; the installed root must be traversable by users.
chmod 0755 "$T" "$build_cache"
cleanup() {
    local m failed=0
    for m in var/cache/xbps tmp run sys proc dev; do
        if mountpoint -q "$T/$m"; then umount -R "$T/$m" || failed=1; fi
    done
    return "$failed"
}
# Never recursively remove a chroot if a mount could not be detached.
trap 'if cleanup; then rm -rf --one-file-system "$T" "$build_cache"; else echo "Failed to unmount rootfs; refusing to remove it" >&2; exit 1; fi' EXIT
ch() { chroot "$T" /usr/bin/env -i HOME=/root PATH=/usr/bin:/bin LANG=C "$@"; }

# Prepare pseudofs before the native package post-install scripts run.
install -d -m755 "$T/dev" "$T/proc" "$T/sys" "$T/run" "$T/etc/xbps.d" \
    "$T/var/db/xbps/keys" "$T/var/cache/xbps"
install -d -m1777 "$T/tmp"
mount --rbind /dev "$T/dev"; mount --make-rslave "$T/dev"
mount -t proc proc "$T/proc"
mount --rbind /sys "$T/sys"; mount --make-rslave "$T/sys"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$T/run"
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$T/tmp"
mount --bind "$build_cache" "$T/var/cache/xbps"
mount --make-private "$T/var/cache/xbps"

# Bootstrap a real base-system, not the OCI filesystem.
cp -a /var/db/xbps/keys/*.plist "$T/var/db/xbps/keys/"
XBPS_ARCH=aarch64 xbps-install -r "$T" -R "$OFFICIAL" -Sy base-system ca-certificates </dev/null
# Reconfigure base-files natively before the remaining package transactions.
ch xbps-reconfigure -f base-files
rm -f "$T/etc/resolv.conf"
cp -L /etc/resolv.conf "$T/etc/resolv.conf"
# Configure the pinned repository trust before any remote BSP transaction.
keys=(/bsp-keys/*.plist)
test "${#keys[@]}" -eq 1
install -m644 "${keys[0]}" "$T/var/db/xbps/keys/"
printf 'repository=%s\n' "$BSP" > "$T/etc/xbps.d/20-zhiyu.conf"
ch xbps-install -Sy </dev/null
# Test the official and replacement camera ABI before installing it.
upstream=$(ch xbps-query -R -p pkgver libcamera)
replacement=$(ch xbps-query -R -p pkgver libcamera-zhiyu)
series() { sed -nE 's/^[^-]+(-zhiyu)?-([0-9]+\.[0-9]+).*/\2/p' <<< "$1"; }
test -n "$(series "$upstream")"
test "$(series "$upstream")" = "$(series "$replacement")" || { echo "Camera ABI mismatch: $upstream / $replacement" >&2; exit 1; }
board=(linux-zhiyu-modules linux-zhiyu-headers linux-zhiyu-firmware linux-zhiyu-images libcamera-zhiyu zhiyu-qrtr sensh hexagonrpc zhiyu-sensord qcom-va-driver qbootctl)
ch xbps-install -y -R "$BSP" "${board[@]}" </dev/null
# base-system already provides dash and bash; install zsh only when selected.
apps=("$LOGIN_SHELL" sudo vim NetworkManager bluez dbus elogind polkit rtkit chrony
      pipewire wireplumber wireplumber-elogind alsa-pipewire libspa-bluetooth
      alsa-utils alsa-ucm-conf mesa-freedreno-dri mesa-vulkan-freedreno mesa-opencl
      vulkan-loader libva-utils noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji)
ch xbps-install -y -R "$BSP" "${apps[@]}" "${desktop[@]}" </dev/null
# Complete pending package configuration, and prefer the POSIX dash shell.
ch xbps-reconfigure -a
ch xbps-alternatives -s dash
test "$(ch readlink -f /bin/sh)" = "$(ch readlink -f /usr/bin/dash)"

# NetworkManager owns DHCP and writes a regular resolv.conf directly.
# Avoid an auto-selected openresolv backend and never ship the CI resolver.
install -d -m755 "$T/etc/NetworkManager/conf.d"
printf '[main]\ndns=default\nrc-manager=file\n' > "$T/etc/NetworkManager/conf.d/10-zhiyu-dns.conf"

printf '%s\n' "$HOST_NAME" > "$T/etc/hostname"
printf '127.0.0.1 localhost %s\n::1 localhost\n' "$HOST_NAME" > "$T/etc/hosts"
printf 'CHASSIS=tablet\n' > "$T/etc/machine-info"
printf 'LANG=zh_CN.UTF-8\n' > "$T/etc/locale.conf"
sed -i -E 's/^#(en_US.UTF-8 UTF-8|zh_CN.UTF-8 UTF-8)/\1/' "$T/etc/default/libc-locales"
ch xbps-reconfigure -f glibc-locales
# The seat manager grants input devices dynamically; no permanent input access.
groups=(wheel audio video)
if ch getent group render >/dev/null; then groups+=(render); fi
for group in "${groups[@]}"; do ch getent group "$group" >/dev/null; done
group_list=$(IFS=,; echo "${groups[*]}")
login_shell="/usr/bin/$LOGIN_SHELL"
if ! ch test -x "$login_shell" || ! grep -Fxq "$login_shell" "$T/etc/shells"; then
    echo "Selected login shell is missing or not registered: $login_shell" >&2
    exit 1
fi
ch useradd -m -G "$group_list" -s "$login_shell" "$USERNAME"
# Void's chpasswd PAM stack uses pam_permit; select the hash explicitly.
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | ch chpasswd -c SHA512
ch passwd -l root
install -d "$T/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$T/etc/sudoers.d/10-wheel"
chmod 440 "$T/etc/sudoers.d/10-wheel"
if [[ "$LOGIN_SHELL" == zsh ]]; then
    touch "$T/home/$USERNAME/.zshrc"
    ch chown "$USERNAME:$USERNAME" "/home/$USERNAME/.zshrc"
fi

# Enable services in the persistent runit default runsvdir, not /var/service
# (which may point through /run during boot).
svdir="$T/etc/runit/runsvdir/default"
install -d "$svdir"
enable() {
    test -x "$T/etc/sv/$1/run" || { echo "Missing runit service: $1" >&2; exit 1; }
    ln -sfn "/etc/sv/$1" "$svdir/$1"
}
rm -f "$svdir/dhcpcd" "$svdir/wpa_supplicant"
for svc in dbus elogind NetworkManager bluetoothd sshd chronyd hexagonrpcd-adsp-rootpd hexagonrpcd-adsp-sensorspd zhiyu-sensord; do enable "$svc"; done
if [[ -n "$dm" ]]; then
    enable "$dm"
    # Do not run a second system-wide audio daemon: use the user session.
    install -d "$T/etc/xdg/autostart" "$T/etc/pipewire/pipewire.conf.d" "$T/etc/alsa/conf.d"
    for file in /usr/share/applications/pipewire.desktop /usr/share/examples/pipewire/20-pipewire-pulse.conf /usr/share/examples/wireplumber/10-wireplumber.conf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf; do test -f "$T$file"; done
    ln -sfn /usr/share/applications/pipewire.desktop "$T/etc/xdg/autostart/pipewire.desktop"
    ln -sfn /usr/share/examples/pipewire/20-pipewire-pulse.conf "$T/etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf"
    ln -sfn /usr/share/examples/wireplumber/10-wireplumber.conf "$T/etc/pipewire/pipewire.conf.d/10-wireplumber.conf"
    ln -sfn /usr/share/alsa/alsa.conf.d/50-pipewire.conf "$T/etc/alsa/conf.d/50-pipewire.conf"
    ln -sfn /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf "$T/etc/alsa/conf.d/99-pipewire-default.conf"
fi
# Only mark the current slot after boot; never call qbootctl on the CI runner.
install -d "$T/etc/sv/qbootctl-mark-success"
cat > "$T/etc/sv/qbootctl-mark-success/run" <<'EOF'
#!/bin/sh
exec 2>&1
until /usr/bin/qbootctl -m; do sleep 5; done
exec sleep infinity
EOF
chmod 755 "$T/etc/sv/qbootctl-mark-success/run"
enable qbootctl-mark-success

# The board boots with Android boot images from the BSP, not a distro kernel.
test -x "$T/sbin/init"
test -x "$T/usr/bin/qbootctl"
ch xbps-query -p pkgver "${board[0]}"
for pkg in "${board[@]}"; do ch xbps-query -p pkgver "$pkg"; done
if [[ $(readlink "$T/etc/mtab") == /proc/mounts ]]; then ln -sfn /proc/self/mounts "$T/etc/mtab"; fi
ch xbps-pkgdb -a
# Check execution and path traversal with the real service/user credentials.
# A root-only loader check cannot detect EACCES after chpst drops privileges.
test "$(stat -c '%a:%u:%g' "$T")" = '755:0:0'
ch chpst -u fastrpc:fastrpc /usr/bin/test -x /usr/bin/hexagonrpcd
ch chpst -u fastrpc:fastrpc /usr/bin/true
ch chpst -u "$USERNAME" /usr/bin/true
loader=/usr/lib/ld-linux-aarch64.so.1
for f in /usr/bin/qbootctl /usr/bin/zhiyu-sensord /usr/bin/sensh /usr/bin/hexagonrpcd /usr/lib/dri/qcom_drv_video.so; do
    test -f "$T$f"
    deps=$(ch "$loader" --list "$f")
    printf '%s\n%s\n' "$f" "$deps"
    if grep -q 'not found' <<< "$deps"; then exit 1; fi
done
shopt -s nullglob
camera=("$T"/usr/lib/libcamera.so.*)
((${#camera[@]} > 0))
for f in "${camera[@]}"; do ch "$loader" --list "${f#"$T"}"; done

# Keep the XBPS database and trusted keys, but detach the external cache.
echo "--- External XBPS cache:"
du -sh "$build_cache"
rm -f "$T"/etc/ssh/ssh_host_* "$T/etc/resolv.conf" "$T/var/lib/dbus/machine-id" "$T/etc/.pwd.lock"
: > "$T/etc/machine-id"
install -m644 /dev/null "$T/etc/resolv.conf"
cleanup
# The runtime mounts and external package cache must not enter the archive.
cache="$T/var/cache/xbps"
[[ -d "$cache" && ! -L "$cache" && "$(realpath "$cache")" == "$(realpath "$T")/var/cache/xbps" ]]
find "$cache" -mindepth 1 -delete
if [[ -n "$(find "$cache" -mindepth 1 -print -quit)" ]]; then
    echo 'XBPS package cache is not empty after cleanup' >&2
    exit 1
fi
# Leave ordinary empty directories for first boot and preserve sticky /tmp.
for dir in run tmp var/tmp; do
    path="$T/$dir"
    [[ -d "$path" && ! -L "$path" && "$(realpath "$path")" == "$(realpath "$T")/$dir" ]]
    find "$path" -mindepth 1 -delete
done
chmod 1777 "$T/tmp" "$T/var/tmp"
test "$(stat -c '%a:%u:%g' "$T")" = '755:0:0'
# Never publish a rootfs with a missing or locked initial user password.
# Verify the SHA-512 crypt format without printing the hash or password.
if ! awk -F: -v user="$USERNAME" '
    $1 == user && $2 ~ /^\$6\$(rounds=[0-9]+\$)?[^$]+\$[^$]+$/ { ok=1 }
    END { exit !ok }
' "$T/etc/shadow"; then
    echo "Initial password hash is missing, locked or invalid for $USERNAME" >&2
    exit 1
fi
echo "Initial user password hash verified."
echo "--- Rootfs size before compression:"
du -sh "$T"
out="void-aarch64-$DESKTOP-rootfs.tar.xz"
tar --numeric-owner --acls --xattrs -C "$T" -I 'xz -9e -T0' -cpf "$out" .
sha256sum "$out" > "$out.sha256"
ls -lh "$out" "$out.sha256"
