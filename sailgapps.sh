#!/bin/sh

# SailGApps by Puffercat. Thanks to ubuntuscofield on Sailfish forum

set -e


WORKDIR=/home/.aliendalvik_systemimg_patch
TMPWORKDIR="$WORKDIR/tmp"
SQUASHFS_ROOT="$TMPWORKDIR/squashfs-root"
MOUNT_ROOT="$TMPWORKDIR/systemimg_mount"
SYSTEM_IMG=/opt/alien/system.img
ORIG_IMG_FILE=orig_img_path.txt

FEDORA22_REPO=https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/22/Everything/armhfp/os/Packages

OPENGAPPS_ARCH=arm64
OPENGAPPS_API=10.0
OPENGAPPS_VARIANT=pico

GOOGLE_APPS_REMOVE='carriersetup extservicesgoogle extsharedgoogle googlebackuptransport googlecontactssync googlefeedback googlepartnersetup'


log() {
    printf '%s\n' "$1" > /dev/stderr
}


install_fedora22_rpm() {
    pkgname="$1"
    pkgversion="$2"

    if ! rpm -q "$pkgname" > /dev/null; then
        pkgfile="$pkgname-$pkgversion.fc22.arm64.rpm"
        firstletter="$(printf '%s' "$pkgfile" | cut -c 1)"
        mkdir "$TMPWORKDIR/rpms"
        curl "$FEDORA22_REPO/$firstletter/$pkgfile" > "$TMPWORKDIR/rpms/$pkgfile"
        pkcon -y install-local "$TMPWORKDIR/rpms/$pkgfile"
        rm "$TMPWORKDIR/rpms/$pkgfile"
        rmdir "$TMPWORKDIR/rpms"
    fi
}

install_lzip_rpm() {
    pkgname="$1"
    pkgversion="$2"

    if ! rpm -q "$pkgname" > /dev/null; then
        pkgfile="$pkgname-$pkgversion.fc35.aarch64.rpm"
        firstletter="$(printf '%s' "$pkgfile" | cut -c 1)"
        mkdir "$TMPWORKDIR/rpms"
        curl "https://download-ib01.fedoraproject.org/pub/fedora/linux/releases/35/Everything/aarch64/os/Packages/l/lzip-1.22-3.fc35.aarch64.rpm" > "$TMPWORKDIR/rpms/$pkgfile"
        pkcon -y install-local "$TMPWORKDIR/rpms/$pkgfile"
        rm "$TMPWORKDIR/rpms/$pkgfile"
        rmdir "$TMPWORKDIR/rpms"
    fi
}

install_deps() {
    if ! rpm -q squashfs-tools > /dev/null; then
        pkcon refresh
        pkcon -y install squashfs-tools unzip rsync
        pkcon -y remove busybox-symlinks-bash
    fi

    install_lzip_rpm lzip 1.22-3
}


extract_image() {
    mkdir "$MOUNT_ROOT"
    mount -o loop,ro "$SYSTEM_IMG" "$MOUNT_ROOT"

    if [ -f "$MOUNT_ROOT/$ORIG_IMG_FILE" ]; then
        orig_image="$(cat "$MOUNT_ROOT/$ORIG_IMG_FILE")"
        log "$SYSTEM_IMG already patched, using original from $orig_image"
    else
        orig_image="$WORKDIR/system.img.orig.$(date +%Y%m%dT%H%M%S)"
        cp "$SYSTEM_IMG" "$orig_image"
        log "Copying original image $SYSTEM_IMG to $orig_image"
    fi
    umount "$MOUNT_ROOT"

    if [ ! -f "$orig_image" ]; then
        log "$orig_image not found"
        return 1
    fi

    mount -o loop,ro "$orig_image" "$MOUNT_ROOT"

    if [ -f "$MOUNT_ROOT/$ORIG_IMG_FILE" ]; then
        umount "$MOUNT_ROOT"
        rmdir "$MOUNT_ROOT"
        log "$orig_image already patched, please restore original image to $SYSTEM_IMG"
        return 1
    fi

    mkdir "$SQUASHFS_ROOT"
    # rsync needs to be run twice to copy all xattrs. Probably a bug in rsync.
    rsync -aSHAX "$MOUNT_ROOT/" "$SQUASHFS_ROOT/"
    rsync -aSHAX "$MOUNT_ROOT/" "$SQUASHFS_ROOT/"
    umount "$MOUNT_ROOT"
    rmdir "$MOUNT_ROOT"

    printf '%s' "$orig_image" > "$SQUASHFS_ROOT/$ORIG_IMG_FILE"
}


build_image() {
    cp "$SYSTEM_IMG" "$TMPWORKDIR/system.img.backup"
    mksquashfs "$SQUASHFS_ROOT" "$SYSTEM_IMG" -noappend -no-exports -no-duplicates -no-fragments
    rm "$TMPWORKDIR/system.img.backup"
    rm -r "$SQUASHFS_ROOT"
}


_find_opengapps() {
    downloads=/home/defaultuser/Downloads/
    name_pattern="open_gapps-$OPENGAPPS_ARCH-$OPENGAPPS_API-$OPENGAPPS_VARIANT-*.zip"
    if [ "$1" != quiet ]; then
        log "Searching for Open GApps zip at $downloads/$name_pattern"
    fi
    find "$downloads" -maxdepth 1 -name "$name_pattern" | sort | tail -n 1
}


get_opengapps_zip() {
    opengapps_zip="$(_find_opengapps)"
    if [ -z "$opengapps_zip" ]; then
        # Show the Open GApps download page to the user instead of automating
        # the download of the latest version.
        # https://opengapps.org/blog/post/2016/03/18/the-no-mirror-policy/
        log "Opening Open GApps download page"
        runuser -l defaultuser -- xdg-open "https://opengapps.org/?download=true&arch=$OPENGAPPS_ARCH&api=$OPENGAPPS_API&variant=$OPENGAPPS_VARIANT"
        log "Waiting for download to start"
        while [ -z "$opengapps_zip" ]; do
            sleep 1
            opengapps_zip="$(_find_opengapps quiet)"
        done
        log "Detected new download at $opengapps_zip"
        log "Waiting for download to finish"
        while [ -f "$opengapps_zip" ] && [ -f "$opengapps_zip.part" ]; do
            sleep 1
        done
        sleep 1
        if [ ! -f "$opengapps_zip" ]; then
            log "Download failed"
            return 1
        fi
    else
        log "Found Open GApps zip $opengapps_zip"
    fi
    printf '%s' "$opengapps_zip"
}


install_opengapps() {
    unzip "$(get_opengapps_zip)" -d "$TMPWORKDIR/opengapps/"

    for p in $GOOGLE_APPS_REMOVE; do
        rm "$TMPWORKDIR/opengapps/Core/$p-all.tar.lz"
    done

    if [ -f "$TMPWORKDIR/opengapps/Core/extservicesgoogle-all.tar.lz" ]; then
        rm -r "$SQUASHFS_ROOT/system/priv-app/ExtServices"
    fi
    if [ -f "$TMPWORKDIR/opengapps/Core/extsharedgoogle-all.tar.lz" ]; then
        rm -r "$SQUASHFS_ROOT/system/app/ExtShared"
    fi


    mkdir "$TMPWORKDIR/opengapps_2"
    for f in "$TMPWORKDIR"/opengapps/Core/*.tar.lz; do
        lzip -c -d "$f" | tar -x -C "$TMPWORKDIR/opengapps_2"
    done
    rm -r "$TMPWORKDIR/opengapps/"

    cp -r "$TMPWORKDIR"/opengapps_2/*/*/* "$SQUASHFS_ROOT/system/"

    rm -r "$TMPWORKDIR/opengapps_2/"
}


set_traps() {
    # shellcheck disable=SC2064
    trap "$*" EXIT HUP INT QUIT PIPE TERM
}

cleanup() {
    if [ ! -f "$SYSTEM_IMG" ] && [ -f "$TMPWORKDIR/system.img.backup" ]; then
        mv "$TMPWORKDIR/system.img.backup" "$SYSTEM_IMG" || :
    fi
    umount "$MOUNT_ROOT" || :
    rm -r "$TMPWORKDIR" || :
    set_traps -
    exit 1
}

set_traps cleanup

systemctl stop aliendalvik

mkdir -p "$WORKDIR"
mkdir -p "$TMPWORKDIR"

install_deps
extract_image
install_opengapps
build_image

rmdir "$TMPWORKDIR"

set_traps -
exit 0
