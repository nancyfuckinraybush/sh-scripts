#!/usr/bin/env sh
# Copyright (C) 2026, Philip R. Simonson. All rights reserved.
set -euo pipefail

# --- Configuration ---
USERID=$(id | awk '{ print $1 }' | cut -d '=' -f2 | cut -d '(' -f1)
TARGET_ROOT="/dev/nvme0n1p2"
TARGET_BOOT="/dev/nvme0n1p1"
MOUNT_DIR="/mnt/target" # Do NOT edit this

# --- Environment & Usage Checks ---
if [ ! ${USERID} -eq 0 ]; then
	echo "[!] ERROR: This script can ONLY run in ROOT..."
	exit 1
fi
if [ $# -gt 0 ]; then
	echo "Usage: $0"
	exit 1
fi

# --- Create and mount filesystem ---
echo "[+] Creating and mounting directories..."
mkdir -p "${MOUNT_DIR}"
mkfs.ext3 -j "${TARGET_ROOT}"
mount -t ext3 "${TARGET_ROOT}" "${MOUNT_DIR}"
mkdir -p "${MOUNT_DIR}/boot"
mkfs.vfat -F32 "${TARGET_BOOT}"
mount -t vfat "${TARGET_BOOT}" "${MOUNT_DIR}/boot"

# --- Sync live ISO to target device ---
rsync -aupgonLDPHAX --numeric-ids --ignore-existing --progress \
 --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
 / "${MOUNT_DIR}/"
rsync -aupgonLDPHAX --numeric-ids --ignore-existing --progress /run/archiso/bootmnt/EFI/ "${MOUNT_DIR}/boot/"
rsync -aupgonLDPHAX --numeric-ids --ignore-existing --progress /run/archiso/bootmnt/sysresccd/boot/ "${MOUNT_DIR}/boot/"

# --- Copy itself info /root ---
echo "[+] Replicating to /root..."
mkdir -p "${MOUNT_DIR}/root/.backup"
cp "$0" "${MOUNT_DIR}/root/.backup/"
chmod -R 0600 "${MOUNT_DIR}/root/.backup/"
chmod 0700 "${MOUNT_DIR}/root/.backup"

# --- Re-create virtual directories ---
echo "[+] Re-creating virtual directories..."
mkdir -p "${MOUNT_DIR}"/{dev,proc,sys,tmp,run,mnt}

# --- Generate fstab ---
echo "[+] Generating /etc/fstab..."
genfstab -U "${MOUNT_DIR}" > "${MOUNT_DIR}/etc/fstab"

# --- Configuring System via chroot ---
echo "[+] Configuring system via chroot..."
arch-chroot "${MOUNT_DIR}" /bin/sh << 'EOF'
# Configuration of system.
# Copyright (C) 2026, Philip R. Simonson. All rights reserved.
set -euo pipefail

# --- More Configuration ---
ROOT_PASS="toor"
USER_NAME="user"
USER_PASS="resu"

# 1. Set Machine ID (Required for systemd-boot)
dbus-uuidgen > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# 2. Install systemd-boot to TARGET_BOOT partition
bootctl install

# 3. Create global loader configuration
cat << 'LOADER' > /boot/loader/loader.conf
default arch.conf
timeout 5
console-mode max
editor no
LOADER

# 4. Identify root UUID for boot entry
ROOT_UUID=$(blkid -s UUID -o value $(df --output=source / | tail -n1))

# 5. Create arch linux boot entry
cat << 'ENTRY' > /boot/loader/entries/arch.conf
title Arch Linux
linux /x86_64/vmlinuz
initrd /initramfs.img
ENTRY
echo "options root=UUID=${ROOT_UUID} rw" >> /boot/loader/entries/arch.conf

# 6. Configure mkinitcpio.conf and regenerate initramfs.img
echo "[+] Detecting active kernel modules..."
LOADED_MODULES=$(lsmod | awk 'NR>1 {print $1}' | sort -u | tr '\n' ' ')

echo -e "[+] Updating /etc/mkinitcpio.conf MODULES array...     "
if [ -f "/etc/mkinitcpio.conf" ]; then
	sed -i "s/^MODULES=(.*/MODULES=(${LOADED_MODULES})/" "/etc/mkinitcpio.conf"
	if [ $? -eq 0 ]; then
		echo "[DONE]"
	else
		echo "[FAIL]"
	fi
else
	echo "[FAIL]"
fi

# Rebuild initramfs inside target system
if [ -x "/usr/bin/mkinitcpio" ]; then
	echo -e "[+] Rebuilding initramfs image in target system...     "
	mkinitcpio --kernelimage /boot/x86_64/vmlinuz -g /boot/initramfs.img
	if [ $? -eq 0 ]; then
		echo "[DONE]"
	else
		echo "[FAIL]"
	fi
else
	echo "[-] mkinitcpio executable not found, failed!"
	exit 1
fi

# 7. Adjust hostname
cat << 'HOST' > /etc/hostname
archbox
HOST

# 8. Adjust time and date
ln -sf /usr/share/zoneinfo/America/Detroit /etc/localtime

# 9. Setup root password
echo "[+] Setting up root account..."
echo -e "${ROOT_PASS}\n${ROOT_PASS}\n" | passwd root

# 10. Setup user and password for user
echo "[+] Setting up a user account..."
useradd -m -G users,wheel,audio,video,storage "${USER_NAME}"
echo -e "${USER_PASS}\n${USER_PASS}\n" | passwd "${USER_NAME}"

# 11. Setup pacman.conf for pacman
cat << 'PACMAN' > /etc/pacman.conf
#
# /etc/pacman.conf
#
# See the pacman.conf(5) manpage for option and repository directives

#
# GENERAL OPTIONS
#
[options]
# The following paths are commented out with their default values listed.
# If you wish to use different paths, uncomment and update the paths.
#RootDir     = /
#DBPath      = /var/lib/pacman/
#CacheDir    = /var/cache/pacman/pkg/
#LogFile     = /var/log/pacman.log
#GPGDir      = /etc/pacman.d/gnupg/
#HookDir     = /etc/pacman.d/hooks/
HoldPkg     = pacman glibc
#XferCommand = /usr/bin/curl -L -C - -f -o %o %u
#XferCommand = /usr/bin/wget --passive-ftp -c -O %o %u
#CleanMethod = KeepInstalled
Architecture = auto

# Pacman won't upgrade packages listed in IgnorePkg and members of IgnoreGroup
#IgnorePkg   =
#IgnoreGroup =

#NoUpgrade   =
#NoExtract   =

# Misc options
#UseSyslog
Color
#NoProgressBar
#CheckSpace
#VerbosePkgLists
ParallelDownloads = 5

# By default, pacman accepts packages signed by keys that its local keyring
# trusts (see pacman-key and its man page), as well as unsigned packages.
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
#RemoteFileSigLevel = Required

# NOTE: You must run `pacman-key --init` before first using pacman; the local
# keyring can then be populated with the keys of all official Arch Linux
# packagers with `pacman-key --populate archlinux`.

#
# REPOSITORIES
#   - can be defined here or included from another file
#   - pacman will search repositories in the order defined here
#   - local/custom mirrors can be added here or in separate files
#   - repositories listed first will take precedence when packages
#     have identical names, regardless of version number
#   - URLs will have $repo replaced by the name of the current repo
#   - URLs will have $arch replaced by the name of the architecture
#
# Repository entries are of the format:
#       [repo-name]
#       Server = ServerName
#       Include = IncludePath
#
# The header [repo-name] is crucial - it must be present and
# uncommented to enable the repo.
#

# The testing repositories are disabled by default. To enable, uncomment the
# repo name header and Include lines. You can add preferred servers immediately
# after the header, and they will be used before the default mirrors.

#[testing]
#Include = /etc/pacman.d/mirrorlist

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

#[community-testing]
#Include = /etc/pacman.d/mirrorlist

[community]
Include = /etc/pacman.d/mirrorlist

# If you want to run 32 bit applications on your x86_64 system,
# enable the multilib repositories as required here.

#[multilib-testing]
#Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

# An example of a custom package repository.  See the pacman manpage for
# tips on creating your own repositories.
#[custom]
#SigLevel = Optional TrustAll
#Server = file:///home/custompkgs

[blackarch]
Include = /etc/pacman.d/blackarch-mirrorlist
PACMAN

# 12. Create a sudoers config file
cat << 'SUDOERS' > /etc/sudoers.d/wheel.conf
%wheel ALL=(ALL:ALL) ALL
SUDOERS

# 13. Hardening system
echo -e "[+] Hardening system...     "

HARDEN_SCRIPT="/usr/local/sbin/hardening.sh"
mkdir -p "/usr/local/sbin"

cat << 'HARDENING_SCRIPT' > "${HARDEN_SCRIPT}"
#!/usr/bin/env sh
# Hardening script executed on target system using systemd.
# Copyright (C) 2026, Philip R. Simonson. All rights reserved.
set -euo pipefail

echo "[+] Executing local system hardening script..."

# 1. Disable TTY1 Auto-login
mkdir -p /etc/systemd/system/getty@.service.d
cat << 'SERVICE_OVERRIDE' > /etc/systemd/system/getty@.service.d/10-autologin.conf
[Service]
ExecStart=
ExecStart=/sbin/agetty --noclear tty1 $TERM
SERVICE_OVERRIDE

# 2. Secure OpenSSH Server
cat << 'SSH_CONF' > /etc/ssh/sshd_config
# Include drop-in configurations
Include /etc/ssh/sshd_config.d/*.conf

# This is the sshd server system-wide configuration file.  See
# sshd_config(5) for more information.

# This sshd was compiled with PATH=/usr/local/sbin:/usr/local/bin:/usr/bin

# The strategy used for options in the default sshd_config shipped with
# OpenSSH is to specify options with their default value where
# possible, but leave them commented.  Uncommented options override the
# default value.

Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Ciphers and keying
RekeyLimit default none

# Logging
SyslogFacility AUTH
LogLevel INFO

# Authentication:

LoginGraceTime 2m
PermitRootLogin prohibit-password
AllowUsers user
StrictModes yes
MaxAuthTries 3
MaxSessions 1

PubkeyAuthentication yes

# The default is to check both .ssh/authorized_keys and .ssh/authorized_keys2
# but this is overridden so installations will only check .ssh/authorized_keys
AuthorizedKeysFile	.ssh/authorized_keys

#AuthorizedPrincipalsFile none

#AuthorizedKeysCommand none
#AuthorizedKeysCommandUser nobody

# For this to work you will also need host keys in /etc/ssh/ssh_known_hosts
#HostbasedAuthentication no
# Change to yes if you don't trust ~/.ssh/known_hosts for
# HostbasedAuthentication
#IgnoreUserKnownHosts no
# Don't read the user's ~/.rhosts and ~/.shosts files
#IgnoreRhosts yes

# To disable tunneled clear text passwords, change to "no" here!
PasswordAuthentication no
PermitEmptyPasswords no

# Change to "no" to disable keyboard-interactive authentication.  Depending on
# the system's configuration, this may involve passwords, challenge-response,
# one-time passwords or some combination of these and other methods.
#KbdInteractiveAuthentication yes

# Kerberos options
#KerberosAuthentication no
#KerberosOrLocalPasswd yes
#KerberosTicketCleanup yes
#KerberosGetAFSToken no

# GSSAPI options
#GSSAPIAuthentication no
#GSSAPICleanupCredentials yes

# Set this to 'yes' to enable PAM authentication, account processing,
# and session processing. If this is enabled, PAM authentication will
# be allowed through the KbdInteractiveAuthentication and
# PasswordAuthentication.  Depending on your PAM configuration,
# PAM authentication via KbdInteractiveAuthentication may bypass
# the setting of "PermitRootLogin prohibit-password".
# If you just want the PAM account and session checks to run without
# PAM authentication, then enable this but set PasswordAuthentication
# and KbdInteractiveAuthentication to 'no'.
#UsePAM no

AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
X11DisplayOffset 10
X11UseLocalhost yes
PermitTTY yes
PrintMotd yes
PrintLastLog yes
TCPKeepAlive yes
PermitUserEnvironment no
Compression delayed
ClientAliveInterval 0
ClientAliveCountMax 3
UseDNS no
PidFile /run/sshd.pid
MaxStartups 10:30:100
PermitTunnel no
ChrootDirectory none
VersionAddendum none

# no default banner path
Banner none

# override default of no subsystems
Subsystem	sftp	/usr/lib/ssh/sftp-server

# Example of overriding settings on a per-user basis
#Match User anoncvs
#	X11Forwarding no
#	AllowTcpForwarding no
#	PermitTTY no
#	ForceCommand cvs server
SSH_CONF

# 3. Kernel Sysctl Tweaks
cat << 'SYSCTL_CONF' > /etc/sysctl.d/99-hardened.conf
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
SYSCTL_CONF

# 4. Global Restrictive Umask
grep -q "umask 077" /etc/profile || echo "umask 077" >> /etc/profile

# 5. Ensure correct file permissions on injected configurations
chmod 644 /etc/systemd/system/getty@.service.d/10-autologin.conf
chmod 640 /etc/ssh/sshd_config
chmod 644 /etc/sysctl.d/99-hardened.conf

echo "[+] Hardening completed successfully!"
HARDENING_SCRIPT
EOF

# 6. Configure systemd First-Boot Hardening Service
echo "[+] Registering first-boot systemd hardening service..."

SYSTEMD_SERVICE="${MOUNT_DIR}/etc/systemd/system/firstboot-hardening.service"

cat << 'EOF' > "${SYSTEMD_SERVICE}"
[Unit]
Description=Linux First Boot Hardening Script
After=local-fs.target
Before=ssh.service getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/bin/sh /usr/local/sbin/hardening.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chown root:root "${HARDEN_SCRIPT}"
chmod 700 "${HARDEN_SCRIPT}"
chown root:root "${SYSTEMD_SERVICE}"
chmod 700 "${SYSTEMD_SERVICE}"

# Enable the service inside the target system
mkdir -p "${MOUNT_DIR}/etc/systemd/system/multi-user.target.wants"
ln -sf "${MOUNT_DIR}/etc/systemd/system/firstboot-hardening.service" \
 "${MOUNT_DIR}/etc/systemd/system/multi-user.target.wants/firstboot-hardening.service"

echo "[+] Syncing disks..."
sync

echo "[SUCCESS] Installation complete! You can reboot into your new system..."

