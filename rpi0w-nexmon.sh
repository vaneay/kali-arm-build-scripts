#!/bin/bash

# This is the Raspberry Pi Kali 0-W Nexmon ARM build script - http://www.kali.org/downloads
# A trusted Kali Linux image created by Offensive Security - http://www.offensive-security.com
# Maintained by @binkybear

if [[ $# -eq 0 ]] ; then
    echo "Please pass version number, e.g. $0 2.0"
    exit 0
fi

basedir=`pwd`/rpi0w-nexmon-$1
TOPDIR=`pwd`

# Package installations for various sections.
# This will build a minimal XFCE Kali system with the top 10 tools.
# This is the section to edit if you would like to add more packages.
# See http://www.kali.org/new/kali-linux-metapackages/ for meta packages you can
# use. You can also install packages, using just the package name, but keep in
# mind that not all packages work on ARM! If you specify one of those, the
# script will throw an error, but will still continue on, and create an unusable
# image, keep that in mind.

arm="abootimg cgpt fake-hwclock ntpdate vboot-utils vboot-kernel-utils u-boot-tools"
base="kali-menu kali-defaults initramfs-tools sudo parted e2fsprogs usbutils"
desktop="fonts-croscore fonts-crosextra-caladea fonts-crosextra-carlito gnome-theme-kali gtk3-engines-xfce kali-desktop-xfce kali-root-login lightdm network-manager network-manager-gnome xfce4 xserver-xorg-video-fbdev xserver-xorg-input-evdev xserver-xorg-input-synaptics mate-core mate-desktop mate-desktop-environment mate-notification-daemon xrdp"
tools="passing-the-hash winexe aircrack-ng hydra john sqlmap wireshark libnfc-bin mfoc nmap ethtool usbutils net-tools hostapd isc-dhcp-server"
services="openssh-server apache2"
extras="iceweasel xfce4-terminal wpasupplicant"
# kernel sauces take up space
size=7000 # Size of image in megabytes

packages="${arm} ${base} ${desktop} ${tools} ${services} ${extras}"
architecture="armel"
# If you have your own preferred mirrors, set them here.
# After generating the rootfs, we set the sources.list to the default settings.
mirror=http.kali.org

# Check to ensure that the architecture is set to ARMEL since the RPi is the
# only board that is armel.
if [[ $architecture != "armel" ]] ; then
    echo "The Raspberry Pi cannot run the Debian armhf binaries"
    exit 0
fi

# Set this to use an http proxy, like apt-cacher-ng, and uncomment further down
# to unset it.
#export http_proxy="http://localhost:3142/"

mkdir -p ${basedir}
cd ${basedir}

# create the rootfs - not much to modify here, except maybe the hostname.
debootstrap --foreign --arch $architecture kali-rolling kali-$architecture http://$mirror/kali

cp /usr/bin/qemu-arm-static kali-$architecture/usr/bin/

LANG=C chroot kali-$architecture /debootstrap/debootstrap --second-stage
cat << EOF > kali-$architecture/etc/apt/sources.list
deb http://$mirror/kali kali-rolling main contrib non-free
EOF

# Set hostname
echo "kali" > kali-$architecture/etc/hostname

# So X doesn't complain, we add kali to hosts
cat << EOF > kali-$architecture/etc/hosts
127.0.0.1       kali    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Cofigure dhcp server for AP
cat << EOF > kali-$architecture/etc/dhcp/dhcpd.conf
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.42.0 netmask 255.255.255.0 {
	range 192.168.42.10 192.168.42.50;
	option broadcast-address 192.168.42.255;
	option routers 192.168.42.1;
	default-lease-time 600;
	max-lease-time 7200;
	option domain-name "kali.evil.local";
	option domain-name-servers 8.8.8.8, 8.8.4.4;
}
EOF

cat << EOF > kali-$architecture/etc/hostapd/hostapd.conf
interface=wlan0
# driver=rtl871xdrv
# driver=nl80211
ssid=Kali_AP
country_code=FR
hw_mode=g
channel=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=Raspberry
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
wpa_group_rekey=86400
ieee80211n=1
wme_enabled=1
EOF

cat << EOF > kali-$architecture/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto usb0
iface usb0 inet dhcp

allow-hotplug wlan0
iface wlan0 inet static
  address 192.168.42.1
  netmask 255.255.255.0
EOF

cat << EOF > kali-$architecture/etc/resolv.conf
nameserver 8.8.8.8
EOF

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

mount -t proc proc kali-$architecture/proc
mount -o bind /dev/ kali-$architecture/dev/
mount -o bind /dev/pts kali-$architecture/dev/pts

cat << EOF > kali-$architecture/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF

# Create monitor mode start/remove
cat << EOF > kali-$architecture/usr/bin/monstart
#!/bin/bash
echo "Bringing interface wlan0 down"
ifconfig wlan0 down
rmmod brcmfmac
modprobe brcmutil
echo "Copying modified firmware"
cp /opt/nexmon/firmware/brcmfmac43430-sdio.bin /lib/firmware/brcm/brcmfmac43430-sdio.bin
insmod /opt/nexmon/firmware/brcmfmac.ko
ifconfig wlan0 up 2> /dev/null
EOF
chmod +x kali-$architecture/usr/bin/monstart

cat << EOF > kali-$architecture/usr/bin/monstop
#!/bin/bash
echo "Bringing interface wlan0 down"
ifconfig wlan0 down
echo "Copying original firmware"
cp /opt/nexmon/firmware/brcmfmac43430-sdio.orig.bin /lib/firmware/brcm/brcmfmac43430-sdio.bin
rmmod brcmfmac
sleep 1
echo "Reloading brcmfmac"
modprobe brcmfmac
ifconfig wlan0 up 2> /dev/null
echo "Monitor mode stopped"
EOF
chmod +x kali-$architecture/usr/bin/monstop

cat << EOF > kali-$architecture/lib/systemd/system/regenerate_ssh_host_keys.service
#
[Unit]
Description=Regenerate SSH host keys

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c "if [ -e /dev/hwrng ]; then dd if=/dev/hwrng of=/dev/urandom count=1 bs=4096; fi"
ExecStart=/usr/bin/ssh-keygen -A
ExecStartPost=/bin/rm /lib/systemd/system/regenerate_ssh_host_keys.service ; /usr/sbin/update-rc.d regenerate_ssh_host_keys remove

[Install]
WantedBy=multi-user.target
EOF
chmod 755 kali-$architecture/lib/systemd/system/regenerate_ssh_host_keys.service

cat << EOF > kali-$architecture/third-stage
#!/bin/bash
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get --yes --force-yes install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools u-boot-tools
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
export DEBIAN_FRONTEND=noninteractive
apt-get --yes --force-yes install $packages
apt-get --yes --force-yes dist-upgrade
apt-get --yes --force-yes autoremove

# Because copying in authorized_keys is hard for people to do, let's make the
# image insecure and enable root login with a password.

echo "Making the image insecure"
sed -i -e 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
rm -f /etc/ssh/ssh_host_*_key*

systemctl enable regenerate_ssh_host_keys

updat-rc.d ssh enable

sed -i -e 's/#DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/' /etc/default/hostapd
sed -i -e 's/# DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/' /etc/default/hostapd
sed -i -e 's/DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/' /etc/default/hostapd

update-rc.d hostapd enable

sed -i -e 's/#INTERFACES=""/INTERFACES="wlan0"/' /etc/default/isc-dhcp-server
sed -i -e 's/# INTERFACES=""/INTERFACES="wlan0"/' /etc/default/isc-dhcp-server
sed -i -e 's/INTERFACES=""/INTERFACES="wlan0"/' /etc/default/isc-dhcp-server

update-rc.d isc-dhcp-server enable

# libinput seems to fail hard on RaspberryPi devices, so we make sure it's not
# installed here (and we have xserver-xorg-input-evdev and
# xserver-xorg-input-synaptics packages installed above!)
apt-get --yes --force-yes purge xserver-xorg-input-libinput

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d

rm -f /third-stage
EOF

chmod +x kali-$architecture/third-stage
LANG=C chroot kali-$architecture /third-stage

cat << EOF > kali-$architecture/cleanup
#!/bin/bash
rm -rf /root/.bash_history
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod +x kali-$architecture/cleanup
LANG=C chroot kali-$architecture /cleanup

umount kali-$architecture/proc/sys/fs/binfmt_misc
umount kali-$architecture/dev/pts
umount kali-$architecture/dev/
umount kali-$architecture/proc

# Create the disk and partition it
echo "Creating image file for Raspberry Pi"
dd if=/dev/zero of=${basedir}/kali-$1-rpi0w-nexmon.img bs=1M count=$size
parted kali-$1-rpi0w-nexmon.img --script -- mklabel msdos
parted kali-$1-rpi0w-nexmon.img --script -- mkpart primary fat32 0 64
parted kali-$1-rpi0w-nexmon.img --script -- mkpart primary ext4 64 -1

# Set the partition variables
loopdevice=`losetup -f --show ${basedir}/kali-$1-rpi0w-nexmon.img`
device=`kpartx -va $loopdevice| sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2

# Create file systems
mkfs.vfat $bootp
mkfs.ext4 $rootp

# Create the dirs for the partitions and mount them
mkdir -p ${basedir}/bootp ${basedir}/root
mount $bootp ${basedir}/bootp
mount $rootp ${basedir}/root

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${basedir}/kali-$architecture/ ${basedir}/root/

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttyAMA0 115200 vt100" >> ${basedir}/root/etc/inittab

cat << EOF > ${basedir}/root/etc/apt/sources.list
deb http://http.kali.org/kali kali-rolling main non-free contrib
deb-src http://http.kali.org/kali kali-rolling main non-free contrib
EOF

# Uncomment this if you use apt-cacher-ng otherwise git clones will fail.
#unset http_proxy

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.

git clone --depth 1 https://github.com/raspberrypi/tools ${basedir}/tools

export ARCH=arm
export CROSS_COMPILE=${basedir}/tools/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian/bin/arm-linux-gnueabihf-

# We build kernel and brcmfmac modules here
cd ${TOPDIR}
git clone --depth 1 https://github.com/nethunteros/bcm-rpi3.git ${TOPDIR}/bcm-rpi3
git submodule update --init --recursive
cd ${TOPDIR}/bcm-rpi3
git checkout master
git pull
git submodule update --init --recursive
cd kernel
git checkout remotes/origin/rpi-4.4.y-re4son

# Get nexmon into /opt folder for later build
cd ${TOPDIR}
git clone --depth 1 https://github.com/seemoo-lab/nexmon.git ${basedir}/root/opt/nexmon
mkdir -p ${basedir}/root/opt/nexmon/firmware # Create firmware folder for loading preloading
touch .scmversion
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-

# RPI Firmware
git clone --depth 1 https://github.com/raspberrypi/firmware.git rpi-firmware
cp -rf rpi-firmware/boot/* ${basedir}/bootp/
rm -rf ${basedir}/root/lib/firmware  # Remove /lib/firmware to copy linux firmware
rm -rf rpi-firmware

# Linux Firmware
cd ${basedir}/root/lib
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git firmware
rm -rf ${basedir}/root/lib/firmware/.git

# Setup build
cd ${TOPDIR}/bcm-rpi3/
git submodule update --recursive --remote
source setup_env.sh
ln -s /usr/include/asm-generic /usr/include/asm
cd ${TOPDIR}/bcm-rpi3/kernel
git checkout rpi-4.4.y-re4son

# Set default defconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- bcmrpi_defconfig

# Build kernel
cd ${TOPDIR}/bcm-rpi3/firmware_patching/nexmon
make
cp brcmfmac/brcmfmac.ko ${basedir}/root/opt/nexmon/firmware

# Make kernel modules
cd ${TOPDIR}/bcm-rpi3/kernel/
make modules_install INSTALL_MOD_PATH=${basedir}/root

# Copy kernel to boot
cd ${TOPDIR}/bcm-rpi3/kernel/
perl scripts/mkknlimg --dtok ${TOPDIR}/bcm-rpi3/kernel/arch/arm/boot/zImage ${basedir}/bootp/kernel.img
cp ${TOPDIR}/bcm-rpi3/kernel/arch/arm/boot/dts/*.dtb ${basedir}/bootp/
cp ${TOPDIR}/bcm-rpi3/kernel/arch/arm/boot/dts/overlays/*.dtb* ${basedir}/bootp/overlays/
cp ${TOPDIR}/bcm-rpi3/kernel/arch/arm/boot/dts/overlays/README ${basedir}/bootp/overlays/

# Make firmware and headers
make ARCH=arm firmware_install INSTALL_MOD_PATH=${basedir}/root
make ARCH=arm headers_install INSTALL_HDR_PATH=${basedir}/root/usr

cp -rf ${TOPDIR}/bcm-rpi3/kernel ${basedir}/root/usr/src/kernel

# Fix up the symlink for building external modules
# kernver is used so we don't need to keep track of what the current compiled
# version is
kernver=$(ls ${basedir}/root/lib/modules/)
cd ${basedir}/root/lib/modules/$kernver
rm build
rm source
ln -s /usr/src/kernel build
ln -s /usr/src/kernel source
cd ${basedir}


# Create cmdline.txt file
cat << EOF > ${basedir}/bootp/cmdline.txt
dwc_otg.lpm_enable=0 console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait modules-load=dwc2,g_ether
EOF


# Create config.txt file
cat << EOF > ${basedir}/bootp/config.txt
### enable overlay USB dual mode module host + otg
dtoverlay=dwc2
EOF

# systemd doesn't seem to be generating the fstab properly for some people, so
# let's create one.
cat << EOF > ${basedir}/root/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p1  /boot           vfat    defaults          0       2
/dev/mmcblk0p2  /               ext4    defaults,noatime  0       1
EOF

# rpi-wiggle
mkdir -p ${basedir}/root/scripts
wget https://raw.github.com/dweeber/rpiwiggle/master/rpi-wiggle -O ${basedir}/root/scripts/rpi-wiggle.sh
chmod 755 ${basedir}/root/scripts/rpi-wiggle.sh

# Firmware needed for rpi3 wifi (default to standard aka not nexmon)
mkdir -p ${basedir}/root/lib/firmware/brcm/
cp ${basedir}/../misc/rpi3/brcmfmac43430-sdio.txt ${basedir}/root/lib/firmware/brcm/
cp ${basedir}/../misc/rpi3/brcmfmac43430-sdio.bin ${basedir}/root/lib/firmware/brcm/

# Copy firmware for original backup for Nexmon
cp ${basedir}/../misc/rpi3/brcmfmac43430-sdio.txt ${basedir}/root/opt/nexmon/firmware/brcmfmac43430-sdio.txt
cp ${basedir}/../misc/rpi3/brcmfmac43430-sdio.bin ${basedir}/root/opt/nexmon/firmware/brcmfmac43430-sdio.orig.bin

# Copy nexmon firmware to /opt/nexmon/firmware folder
cp ${basedir}/../misc/rpi3/brcmfmac43430-sdio-nexmon.bin ${basedir}/root/opt/nexmon/firmware/brcmfmac43430-sdio.bin

cd ${basedir}

cp ${basedir}/../misc/zram ${basedir}/root/etc/init.d/zram
chmod +x ${basedir}/root/etc/init.d/zram

# Load custom modules
echo "dwc2" >> ${basedir}/root/etc/modules
echo "g_ether" >> ${basedir}/root/etc/modules

echo mate-session> ${basedir}/root/root/.xsession
cp ${basedir]/root/root/.xsession ${basedir}/root/etc/skel

# Unmount partitions
umount $bootp
umount $rootp
kpartx -dv $loopdevice
losetup -d $loopdevice

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Cleaning up the temporary build files..."
rm -rf ${basedir}/kernel ${basedir}/bootp ${basedir}/root ${basedir}/kali-$architecture ${basedir}/boot ${basedir}/tools ${basedir}/patches ${TOPDIR}/bcm-rpi3

# If you're building an image for yourself, comment all of this out, as you
# don't need the sha1sum or to compress the image, since you will be testing it
# soon.
echo "Generating sha1sum for kali-$1-rpi0w-nexmon.img"
sha1sum kali-$1-rpi0w-nexmon.img > ${basedir}/kali-$1-rpi0w-nexmon.img.sha1sum
# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing kali-$1-rpi0w-nexmon.img"
pixz ${basedir}/kali-$1-rpi0w-nexmon.img ${basedir}/kali-$1-rpi0w-nexmon.img.xz
rm ${basedir}/kali-$1-rpi0w-nexmon.img
echo "Generating sha1sum for kali-$1-rpi0w-nexmon.img.xz"
sha1sum kali-$1-rpi0w-nexmon.img.xz > ${basedir}/kali-$1-rpi0w-nexmon.img.xz.sha1sum
fi
