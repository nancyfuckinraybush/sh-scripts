#!/usr/bin/env sh
# Copyright (C) 2026, Philip R. Simonson. All rights reserved.
set -euo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
	echo "[-] Please run this script as root..."
	exit 1
fi

WORK_DIR="/tmp/custom_arch"
PROFILE_DIR="${WORK_DIR}/profile"
AIROOTFS="${PROFILE_DIR}/airootfs"
DEV_USER="user"

# Install required build tools on the host system
echo "[+] Installing archiso and dependencies on host..."
pacman -Sy --needed --noconfirm archiso xorriso base-devel git wget

echo "[+] Setting up fresh build environment..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/work" "${WORK_DIR}/out"
cp -R /usr/share/archiso/configs/releng/ "${PROFILE_DIR}"

# Enable multilib in pacman.conf
echo "[+] Enabling multilib repository..."
cat << 'EOF' >> "${PROFILE_DIR}/pacman.conf"

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

# Copy the default releng profile
echo "[+] Configuring package manifest..."
cat << 'EOF' >> "${PROFILE_DIR}/packages.x86_64"
# Hardware Firmware & Microcode
linux-firmware
intel-ucode
amd-ucode

# Xorg Server, ArchLinux LM & i3 Environment
xorg
xorg-xserver
xorg-xinit
xorg-xrandr
xorg-xdm
xdm-archlinux
i3-wm
i3lock
i3status
dmenu
feh
picom
nitrogen
kitty
alacritty

# System Utilities & Fonts
leafpad
nano
vim
git
base-devel
wget
curl
htop
tmux
unzip
zip
p7zip
polkit-gnome
networkmanager
network-manager-applet
ttf-dejavu
ttf-liberation
ttf-font-awesome
noto-fonts
terminus-font
rxvt-unicode

# --- Linux, Windows & Android Development
git
cmake
make
gcc
gdb
clang
llvm
ninja
python
python-pip
nodejs
npm
docker

# Windows Cross Development
mingw-w64
wine
wine-mono
wine-gecko
winetricks

# Android Development Prerequisites
platform-tools
android-tools
jdk17-openjdk

# System Utilities
libx11
libxft
libxinerama
pkgconf
openssh
wget
curl

# Miscellaneous
discord
firefox

# Gaming & Multimedia Audio
steam
pipewire
pipewire-alsa
pipewire-pulse
pipewire-jack
pulseaudio
pulseaudio-alsa
pulseaudio-bluetooth
wireplumber
pavucontrol

# Complete Vulkan & GPU Drivers
vulkan-tools
clinfo

# Intel
mesa
lib32-mesa
vulkan-intel
lib32-vulkan-intel
intel-media-driver
xf86-video-intel

# AMD
amdvlk
lib32-amdvlk
vulkan-radeon
lib32-vulkan-radeon
xf86-video-amdgpu

# NVIDIA / Nouveau
nvidia-dkms
nvidia-utils
lib32-nvidia-utils
vulkan-icd-loader
lib32-vulkan-icd-loader
xf86-video-nouveau

# Fallback & Software Vulkan
xf86-video-vesa
vulkan-swrast

# Virtualization Tools (VirtualBox, VMware, QEMU/KVM)
open-vm-tools
xf86-video-vmware
virtualbox-guest-utils
virtualbox-guest-modules-arch
spice-vdagent

EOF

# Create post-boot configuration
# inside the live user skeleton
echo "[+] Configuring user environment scripts..."
mkdir -p "${AIROOTFS}/etc/skel"


# Create .xinitrc to launch i3 automatically
cat << 'EOF' > "${AIROOTFS}/etc/skel/.Xsession"
#!/bin/sh
exec 
EOF
chmod +x "${AIROOTFS}/etc/skel/.xinitrc"

# Create a setup script to pull CLion and
# Android Studio inside the booted environment
mkdir -p "${AIROOTFS}/usr/local/bin"
cat << 'EOF' > "${AIROOTFS}/usr/local/bin/dev-setup.sh"
#!/usr/bin/env sh
# This script runs inside the booted live system to deploy
# IDEs to cowspace/RAM.

set -e

# Expand cowspace runtime contraint if needed
sudo mount -o remountsize=4G /run/archiso/cowspace || true

mkdir -p "${HOME}/ide"
cd "${HOME}/ide"

# Download and extract CLion standalone Linux tarball
echo "[+] Fetching CLion..."
wget -q --show-progress "https://download.jetbrains.com/cpp/CLion-2023.3.4.tar.gz" -O clion.tar.gz
tar -xzf clion.tar.gz
rm clion.tar.gz
mv clion-* clion

# Download and extract Android Studio
echo "[+] Fetching Android Studio..."
wget -q --show-progress "https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2023.1.1.28/android-studio-2023.1.1.28-linux.tar.gz -O android-studio.tar.gz
tar -zxf android-studio.tar.gz
rm android-studio.tar.gz

echo ""
echo "[+] Setup Complete!"
EOF


