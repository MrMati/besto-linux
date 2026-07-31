#!/bin/sh
# mmdebstrap customize hook body. Sourced with $target set to the rootfs.
#
# Everything here runs on the build host against $target, deliberately avoiding
# chroot: qemu-user emulation of maintainer scripts is the slowest and flakiest
# part of a cross rootfs build, so anything expressible as a file edit or a
# symlink is done as a file edit or a symlink.
set -eu

: "${LUCKFOX_HOSTNAME:=luckfox}"
: "${LUCKFOX_ROOT_PASSWORD:=}"
: "${LUCKFOX_KVER:?}"

say() { printf '  . %s\n' "$*"; }

# --------------------------------------------------------------- identity ---
say "hostname: $LUCKFOX_HOSTNAME"
echo "$LUCKFOX_HOSTNAME" > "$target/etc/hostname"
cat > "$target/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$LUCKFOX_HOSTNAME
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

if [ -f "$target/etc/os-release.luckfox" ]; then
	cat "$target/etc/os-release.luckfox" >> "$target/usr/lib/os-release"
	rm -f "$target/etc/os-release.luckfox"
fi

# Every flashed card must not be the same host as far as the network is
# concerned, so the machine ID is generated on the board rather than baked in.
#
# The magic word is "uninitialized", not an empty file. Both make systemd
# generate an ID, but only this one also marks the boot as a first boot: with
# an empty file systemd logs "Initializing machine ID from random generator"
# and leaves ConditionFirstBoot=yes unsatisfied, which silently skips
# sshd-keygen.service and every other unit that only ever runs once.
echo uninitialized > "$target/etc/machine-id"

# ---------------------------------------------------------------- accounts ---
hash=""
if [ -n "$LUCKFOX_ROOT_PASSWORD" ]; then
	say "root password set (change it: passwd)"
	hash="$(openssl passwd -6 "$LUCKFOX_ROOT_PASSWORD")"
	mkdir -p "$target/etc/ssh/sshd_config.d"
	echo "PermitRootLogin yes" > "$target/etc/ssh/sshd_config.d/10-luckfox.conf"
else
	say "root account left locked; provision an SSH key to log in"
fi

# Field 2 of the root line in /etc/shadow is the hash; field 3 is the day the
# password was last changed. Debian sets field 3 to the day the image was
# built, and the board has no RTC, so the first boot comes up at systemd's
# built-in epoch -- months before the image was built as far as the clock is
# concerned. shadow then decides the password was changed in the future and
# every login prints "account root has password changed in future". Pinning
# the field to 1 (2 Jan 1970) is in the past under any clock; 0 is not usable
# because it means "must change password at next login".
awk -v h="$hash" -F: 'BEGIN{OFS=":"} $1=="root"{if (h != "") $2=h; $3=1} {print}' \
	"$target/etc/shadow" > "$target/etc/shadow.new"
mv "$target/etc/shadow.new" "$target/etc/shadow"
# Rewriting through a temporary file loses root:shadow, and unix_chkpwd is
# setgid shadow precisely so that unprivileged password checks can read this
# file. 0640 root:root silently breaks authentication for everyone but root.
chmod 640 "$target/etc/shadow"
chown "0:$(awk -F: '$1=="shadow"{print $3}' "$target/etc/group")" "$target/etc/shadow"

# The host keys must be unique per board, so generate them on first boot
# instead of baking them into the image.
rm -f "$target"/etc/ssh/ssh_host_*

# ----------------------------------------------------------------- systemd ---
enable_unit() {
	unit="$1" want="${2:-multi-user.target}"
	for d in /usr/lib/systemd/system /lib/systemd/system /etc/systemd/system; do
		if [ -f "$target$d/$unit" ]; then
			mkdir -p "$target/etc/systemd/system/$want.wants"
			ln -sf "$d/$unit" "$target/etc/systemd/system/$want.wants/$unit"
			return 0
		fi
	done
	echo "warning: unit $unit not found, not enabling" >&2
}

mask_unit() {
	mkdir -p "$target/etc/systemd/system"
	ln -sf /dev/null "$target/etc/systemd/system/$1"
}

# There is no display and never will be. Debian's default is graphical.target
# because the standard task is installed; on a headless board it only adds
# display-manager.service to the transaction and a target that means nothing.
ln -sf /usr/lib/systemd/system/multi-user.target "$target/etc/systemd/system/default.target"

# Housekeeping written for a desktop or a server, running on 256MB of RAM in
# front of an SD card or a NAND with an erase budget. apt-daily wakes up to
# download package lists into a rootfs that is expected to be reflashed;
# e2scrub wants LVM snapshots that do not exist here and still runs its reaper
# on every boot; fstrim on a card behind dw_mmc is at best a long stall.
# Nothing here is load-bearing, and all of it is one `systemctl unmask` away.
say "masking desktop-sized housekeeping"
for unit in apt-daily.timer apt-daily-upgrade.timer \
	    e2scrub_all.timer e2scrub_reap.service \
	    fstrim.timer dpkg-db-backup.timer; do
	mask_unit "$unit"
done

say "enabling services"
enable_unit systemd-networkd.service
enable_unit systemd-networkd.socket sockets.target
enable_unit systemd-resolved.service
enable_unit systemd-timesyncd.service sysinit.target
enable_unit ssh.service
enable_unit zram-swap.service swap.target
enable_unit luckfox-growroot.service sysinit.target
enable_unit luckfox-usb-gadget.service

# A serial console on UART2 is the only way in when the network is not up yet.
mkdir -p "$target/etc/systemd/system/getty.target.wants"
ln -sf /usr/lib/systemd/system/serial-getty@.service \
	"$target/etc/systemd/system/getty.target.wants/serial-getty@ttyS2.service"

# systemd-resolved owns /etc/resolv.conf.
ln -sf ../run/systemd/resolve/stub-resolv.conf "$target/etc/resolv.conf"

# ----------------------------------------------------------------- modules ---
say "depmod $LUCKFOX_KVER"
depmod -b "$target" "$LUCKFOX_KVER"

# ------------------------------------------------------------------ groups ---
# The udev rule for /dev/rknpu hands the device to the render group; make sure
# it exists even on a minimal profile that pulled in no GPU packages.
grep -q '^render:' "$target/etc/group" || echo 'render:x:993:' >> "$target/etc/group"

# ------------------------------------------------------------------ tidy up ---
say "trimming"
rm -rf "$target"/usr/share/man/?? "$target"/usr/share/man/??_* \
       "$target"/usr/share/locale/* "$target"/var/cache/apt/archives/*.deb \
       "$target"/var/lib/apt/lists/*
mkdir -p "$target/var/lib/apt/lists/partial"
find "$target/usr/share/doc" -mindepth 1 -maxdepth 1 -type d \
	-exec sh -c 'rm -rf "$1"/* 2>/dev/null; :' _ {} \; 2>/dev/null || true
