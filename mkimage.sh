#!/bin/sh
#-
# Copyright (c) 2013-2016 Juan Romero Pardines.
# Copyright (c) 2017 Google
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#-

readonly PROGNAME=$(basename "$0")
readonly ARCH=$(uname -m)

trap 'printf "\nInterrupted! exiting...\n"; cleanup; exit 0' INT TERM HUP

# This source pulls in all the functions from lib.sh.  This set of
# functions makes it much easier to work with chroots and abstracts
# away all the problems with running binaries with QEMU.
# shellcheck source=./lib.sh
. ./lib.sh

# This script has a special cleanup() function since it needs to
# unmount the rootfs as mounted on a loop device.  This function is
# defined after sourcing the library functions to ensure it is the
# last one defined.
cleanup() {
    umount_pseudofs
    umount -f "${ROOTFS}/boot" 2>/dev/null
    umount -f "${ROOTFS}" 2>/dev/null
    if [ -e "$LOOPDEV" ]; then
        partx -d "$LOOPDEV" 2>/dev/null
        losetup -d "$LOOPDEV" 2>/dev/null
    fi
	
    [ -d "$ROOTFS" ] && rmdir "$ROOTFS"
}


# This script is designed to take in a complete platformfs and spit
# out an image that is suitable for writing with dd.  The image is
# configurable in terms of the filesystem layout, but not in terms of
# the installed system itself.  Customization to the installed system
# should be made during the mkplatformfs step.
usage() {
    cat <<_EOF
Usage: $PROGNAME [options] <rootfs-tarball>

The <rootfs-tarball> argument expects a tarball generated by void-mkrootfs.
The platform is guessed automatically by its name.

Accepted sizes suffixes: KiB, MiB, GiB, TiB, EiB.

OPTIONS
 -b <fstype>    Set /boot filesystem type (defaults to FAT)
 -B <bsize>     Set /boot filesystem size (defaults to 64MiB)
 -r <fstype>    Set / filesystem type (defaults to EXT4)
 -s <totalsize> Set total image size (defaults to 2GB)
 -o <output>    Set image filename (guessed automatically)
 -x <num>       Use <num> threads to compress the image (dynamic if unset)
 -h             Show this help
 -V             Show version

Resulting image will have 2 partitions, /boot and /.
_EOF
    exit 0
}

# ########################################
#      SCRIPT EXECUTION STARTS HERE
# ########################################

while getopts "b:B:o:r:s:x:h:V" opt; do
    case $opt in
        b) BOOT_FSTYPE="$OPTARG";;
        B) BOOT_FSSIZE="$OPTARG";;
        o) FILENAME="$OPTARG";;
        r) ROOT_FSTYPE="$OPTARG";;
        s) IMGSIZE="$OPTARG";;
        x) COMPRESSOR_THREADS="$OPTARG" ;;
        V) version; exit 0;;
        *) usage;;
    esac
done
shift $((OPTIND - 1))
ROOTFS_TARBALL="$1"

if [ -z "$ROOTFS_TARBALL" ]; then
    usage
elif [ ! -r "$ROOTFS_TARBALL" ]; then
    # In rare cases the tarball can wind up owned by the wrong user.
    # This leads to confusing failures if execution is allowed to
    # proceed.
    die "Cannot read rootfs tarball: $ROOTFS_TARBALL"
fi

# Setup the platform variable.  Here we want just the name and
# optionally -musl if this is the musl variant.
PLATFORM="${ROOTFS_TARBALL#void-}"
PLATFORM="${PLATFORM%-PLATFORMFS*}"

# Be absolutely certain the platform is supported before continuing
case "$PLATFORM" in
    bananapi|beaglebone|cubieboard2|cubietruck|odroid-c2|odroid-u2|rpi-armv6l|rpi-armv7l|rpi-aarch64|GCP|pinebookpro|pinephone|rock64|*-musl);;
    *) die "The $PLATFORM is not supported, exiting..."
esac

# Default for bigger boot partion on rk33xx devices since it needs to
# fit at least 2 Kernels + initramfs
case "$PLATFORM" in
    pinebookpro*|rock64*)
        : "${BOOT_FSSIZE:=256MiB}"
        ;;
esac
# By default we build all platform images with a 64MiB boot partition
# formated FAT16, and an approximately 1.9GiB root partition formated
# ext4.  More exotic combinations are of course possible, but this
# combination works on all known platforms.
: "${IMGSIZE:=2G}"
: "${BOOT_FSTYPE:=vfat}"
: "${BOOT_FSSIZE:=64MiB}"
: "${ROOT_FSTYPE:=ext4}"

# Verify that the required tooling is available
readonly REQTOOLS="sfdisk partx losetup mount truncate mkfs.${BOOT_FSTYPE} mkfs.${ROOT_FSTYPE}"
check_tools

# This is an awful hack since the script isn't using privesc
# mechanisms selectively.  This is a TODO item.
if [ "$(id -u)" -ne 0 ]; then
    die "need root perms to continue, exiting."
fi

# Set the default filename if none was provided above.  The default
# will include the platform the image is being built for and the date
# on which it was built.
if [ -z "$FILENAME" ]; then
    FILENAME="void-${PLATFORM}-$(date -u +%Y%m%d).img"
fi

# Create the base image.  This was previously accomplished with dd,
# but truncate is markedly faster.
info_msg "Creating disk image ($IMGSIZE) ..."
truncate -s "${IMGSIZE}" "$FILENAME" >/dev/null 2>&1

# Grab a tmpdir for the rootfs.  If this fails we need to halt now
# because otherwise things will go very badly for the host system.
ROOTFS=$(mktemp -d) || die "Could not create tmpdir for ROOTFS"

info_msg "Creating disk image partitions/filesystems ..."
if [ "$BOOT_FSTYPE" = "vfat" ]; then
    # The mkfs.vfat program tries to make some "intelligent" choices
    # about the type of filesystem it creates.  Instead we set options
    # if the type is vfat to ensure that the same options will be used
    # every time.
    _args="-I -F16"
fi

case "$PLATFORM" in
    cubieboard2|cubietruck|ci20*|odroid-c2*)
        # These platforms use a single partition for the entire filesystem.
        sfdisk "${FILENAME}" <<_EOF
label: dos
2048,,L
_EOF
        LOOPDEV=$(losetup --show --find --partscan "$FILENAME")
        mkfs.${ROOT_FSTYPE} -O '^64bit,^extra_isize,^has_journal' "${LOOPDEV}p1" >/dev/null 2>&1
        mount "${LOOPDEV}p1" "$ROOTFS"
        ROOT_UUID=$(blkid -o value -s UUID "${LOOPDEV}p1")
        ;;
    *)
        # These platforms use a partition layout with a small boot
        # partition (64M by default) and the rest of the space as the
        # root filesystem.  This is the generally preferred disk
        # layout for new platforms.
        case "$PLATFORM" in
            pinebookpro*|rock64*)
                # rk33xx devices use GPT and need more space reserved
                sfdisk "$FILENAME" <<_EOF
label: gpt
unit: sectors
first-lba: 32768
name=BootFS, size=${BOOT_FSSIZE}, type=L, bootable, attrs="LegacyBIOSBootable"
name=RootFS,                      type=L
_EOF
                ;;
            *)
                # The rest use MBR and need less space reserved
                sfdisk "${FILENAME}" <<_EOF
label: dos
2048,${BOOT_FSSIZE},b,*
,+,L
_EOF
                ;;
        esac
        LOOPDEV=$(losetup --show --find --partscan "$FILENAME")
        # Normally we need to quote to prevent argument splitting, but
        # we explicitly want argument splitting here.
        # shellcheck disable=SC2086
        mkfs.${BOOT_FSTYPE} $_args "${LOOPDEV}p1" >/dev/null
        case "$ROOT_FSTYPE" in
            # Because the images produced by this script are generally
            # either on single board computers using flash memory or
            # in cloud environments that already provide disk
            # durability, we shut off the journal for ext filesystems.
            # For flash memory this greatly extends the life of the
            # memory and for cloud images this lowers the overhead by
            # a small amount.
            ext[34]) disable_journal="-O ^has_journal";;
        esac
        mkfs.${ROOT_FSTYPE} ${disable_journal:+"$disable_journal"} "${LOOPDEV}p2" >/dev/null 2>&1
        mount "${LOOPDEV}p2" "$ROOTFS"
        mkdir -p "${ROOTFS}/boot"
        mount "${LOOPDEV}p1" "${ROOTFS}/boot"
        BOOT_UUID=$(blkid -o value -s UUID "${LOOPDEV}p1")
        ROOT_UUID=$(blkid -o value -s UUID "${LOOPDEV}p2")
        ROOT_PARTUUID=$(blkid -o value -s PARTUUID "${LOOPDEV}p2")
        ;;
esac

# This step unpacks the platformfs tarball made by mkplatformfs.sh.
info_msg "Unpacking rootfs tarball ..."
if [ "$PLATFORM" = "beaglebone" ]; then
    # The beaglebone requires some special extra handling.  The MLO
    # program is a special first stage boot loader that brings up
    # enough of the processor to then load u-boot which loads the rest
    # of the system.  The noauto option also prevents /boot from being
    # mounted during system startup.
    fstab_args=",noauto"
    tar xfp "$ROOTFS_TARBALL" -C "$ROOTFS" ./boot/MLO
    tar xfp "$ROOTFS_TARBALL" -C "$ROOTFS" ./boot/u-boot.img
    touch "$ROOTFS/boot/uEnv.txt"
    umount "$ROOTFS/boot"
fi

# In the general case, its enough to just unpack the ROOTFS_TARBALL
# onto the ROOTFS.  This will get a system that is ready to boot, save
# for the bootloader which is handled later.
tar xfp "$ROOTFS_TARBALL" --xattrs --xattrs-include='*' -C "$ROOTFS"

# For f2fs the system should not attempt an fsck at boot.  This
# filesystem is in theory self healing and does not use the standard
# mechanisms.  All other filesystems should use fsck at boot.
fspassno="1"
if [ "$ROOT_FSTYPE" = "f2fs" ]; then
    fspassno="0"
fi

# Void images prefer uuids to nodes in /dev since these are not
# dependent on the hardware layout.  On a single board computer this
# may not matter much but it makes the cloud images easier to manage.
echo "UUID=$ROOT_UUID / $ROOT_FSTYPE defaults 0 ${fspassno}" >> "${ROOTFS}/etc/fstab"
if [ -n "$BOOT_UUID" ]; then
    echo "UUID=$BOOT_UUID /boot $BOOT_FSTYPE defaults${fstab_args} 0 2" >> "${ROOTFS}/etc/fstab"
fi

# Images are shipped with root as the only user by default, so we need to
# ensure ssh login is possible for headless setups.
sed -i "${ROOTFS}/etc/ssh/sshd_config" -e 's|^#\(PermitRootLogin\) .*|\1 yes|g'

# This section does final configuration on the images.  In the case of
# SBCs this writes the bootloader to the image or sets up other
# required binaries to boot.  In the case of images destined for a
# Cloud, this sets up the services that the cloud will expect to be
# running and a suitable bootloader.  When adding a new platform,
# please add a comment explaining what the steps you are adding do,
# and where information about your specific platform's boot process
# can be found.
info_msg "Configuring image for platform $PLATFORM"
case "$PLATFORM" in
bananapi*|cubieboard2*|cubietruck*)
    dd if="${ROOTFS}/boot/u-boot-sunxi-with-spl.bin" of="${LOOPDEV}" bs=1024 seek=8 >/dev/null 2>&1
    ;;
odroid-c2*)
    dd if="${ROOTFS}/boot/bl1.bin.hardkernel" of="${LOOPDEV}" bs=1 count=442 >/dev/null 2>&1
    dd if="${ROOTFS}/boot/bl1.bin.hardkernel" of="${LOOPDEV}" bs=512 skip=1 seek=1 >/dev/null 2>&1
    dd if="${ROOTFS}/boot/u-boot.bin" of="${LOOPDEV}" bs=512 seek=97 >/dev/null 2>&1
    ;;
odroid-u2*)
    dd if="${ROOTFS}/boot/E4412_S.bl1.HardKernel.bin" of="${LOOPDEV}" seek=1 >/dev/null 2>&1
    dd if="${ROOTFS}/boot/bl2.signed.bin" of="${LOOPDEV}" seek=31 >/dev/null 2>&1
    dd if="${ROOTFS}/boot/u-boot.bin" of="${LOOPDEV}" seek=63 >/dev/null 2>&1
    dd if="${ROOTFS}/boot/E4412_S.tzsw.signed.bin" of="${LOOPDEV}" seek=2111 >/dev/null 2>&1
    ;;
ci20*)
    dd if="${ROOTFS}/boot/u-boot-spl.bin" of="${LOOPDEV}" obs=512 seek=1 >/dev/null 2>&1
    dd if="${ROOTFS}/boot/u-boot.img" of="${LOOPDEV}" obs=1K seek=14 >/dev/null 2>&1
    ;;
rock64*)
    rk33xx_flash_uboot "${ROOTFS}/usr/lib/rock64-uboot" "$LOOPDEV"
    # populate the extlinux.conf file
    cat >"${ROOTFS}/etc/default/extlinux" <<_EOF
TIMEOUT=10
# Defaults to current kernel cmdline if left empty
CMDLINE="panic=10 coherent_pool=1M console=ttyS2,1500000 root=UUID=${ROOT_UUID} rw"
# set this to use a DEVICETREEDIR line in place of an FDT line
USE_DEVICETREEDIR="yes"
# relative dtb path supplied to FDT line, as long as above is unset
DTBPATH=""
_EOF
    mkdir -p "${ROOTFS}/boot/extlinux"
    run_cmd_chroot "${ROOTFS}" "/etc/kernel.d/post-install/60-extlinux"
    cleanup_chroot
    ;;
pinebookpro*)
    rk33xx_flash_uboot "${ROOTFS}/usr/lib/pinebookpro-uboot" "$LOOPDEV"
    run_cmd_chroot "${ROOTFS}" "xbps-reconfigure -f pinebookpro-kernel"
    cleanup_chroot
    ;;
pinephone*)
    sed -i "s/CMDLINE=\"\(.*\)\"\$/CMDLINE=\"\1 root=PARTUUID=${ROOT_PARTUUID}\"/" "${ROOTFS}/etc/default/pinephone-uboot-config"
    dd if="${ROOTFS}/boot/u-boot-sunxi-with-spl.bin" of="${LOOPDEV}" bs=1024 seek=8 conv=notrunc,fsync >/dev/null 2>&1
    run_cmd_chroot "${ROOTFS}" "xbps-reconfigure -f pinephone-kernel"
    cleanup_chroot
    ;;
GCP*)
    # Google Cloud Platform image configuration for Google Cloud
    # Engine.  The steps below are built in reference to the
    # documentation on building custom images available here:
    # https://cloud.google.com/compute/docs/images/import-existing-image
    # The images produced by this script are ready to upload and boot.

    # Setup GRUB
    mount_pseudofs
    run_cmd_chroot "${ROOTFS}" "grub-install ${LOOPDEV}"
    sed -i "s:page_poison=1:page_poison=1 console=ttyS0,38400n8d:" "${ROOTFS}/etc/default/grub"
    run_cmd_chroot "${ROOTFS}" update-grub

    # Setup the GCP Guest services
    for _service in dhcpcd sshd agetty-console nanoklogd socklog-unix GCP-Guest-Initialization GCP-accounts GCP-clock-skew GCP-ip-forwarding ; do
        run_cmd_chroot "${ROOTFS}" "ln -sv /etc/sv/$_service /etc/runit/runsvdir/default/$_service"
    done

    # Turn off the agetty's since we can't use them anyway
    rm -v "${ROOTFS}/etc/runit/runsvdir/default/agetty-tty"*

    # Disable root login over ssh and lock account
    sed -i "s:PermitRootLogin yes:PermitRootLogin no:" "${ROOTFS}/etc/ssh/sshd_config"
    run_cmd_chroot "${ROOTFS}" "passwd -l root"

    # Set the Timezone
    run_cmd_chroot "${ROOTFS}" "ln -svf /usr/share/zoneinfo/UTC /etc/localtime"

    # Generate glibc-locales if necessary (this is a noop on musl)
    if [ "$PLATFORM" = GCP ] ; then
        run_cmd_chroot "${ROOTFS}" "xbps-reconfigure -f glibc-locales"
    fi

    # Remove SSH host keys (these will get rebuilt on first boot)
    rm -f "${ROOTFS}/etc/ssh/*key*"
    rm -f "${ROOTFS}/etc/ssh/moduli"

    # Force the hostname since this isn't read from DHCP
    echo void-GCE > "${ROOTFS}/etc/hostname"

    # Cleanup the chroot from anything that was setup for the
    # run_cmd_chroot commands
    cleanup_chroot
    ;;
esac

# Release all the mounts, deconfigure the loop device, and remove the
# rootfs mountpoint.  Since this was just a mountpoint it should be
# empty.  If it contains stuff we bail out here since something went
# very wrong.
umount -R "$ROOTFS"
losetup -d "$LOOPDEV"
rmdir "$ROOTFS" || die "$ROOTFS not empty!"

# We've been working with this as root for a while now, so this makes
# sure the permissions are sane.
chmod 644 "$FILENAME"

# The standard images are ready to go, but the cloud images require
# some minimal additional post processing.
case "$PLATFORM" in
    GCP*)
        # This filename is mandated by the Google Cloud Engine import
        # process, the archive name is not.
        mv "$FILENAME" disk.raw
        info_msg "Compressing disk.raw"
        tar Sczf "${FILENAME%.img}.tar.gz" disk.raw
        # Since this process just produces something that can be
        # uploaded, we remove the original disk image.
        rm disk.raw
        info_msg "Sucessfully created ${FILENAME%.img}.tar.gz image."
        ;;
    *)
        info_msg "Compressing $FILENAME with xz (level 9 compression)"
        xz "-T${COMPRESSOR_THREADS:-0}" -9 "$FILENAME"
        info_msg "Successfully created $FILENAME image."
        ;;
esac
