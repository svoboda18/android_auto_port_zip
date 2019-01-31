#!/sbin/sh

#
# Copyright (C) 2019 by SaMad SegMane (svoboda18)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses
#

###############
#             #
#  VARIABLES  #
#             #
###############

ver=0.1
ROOTDIR=/
TMPDIR=/tmp
BOOTDIR="$TMPDIR/boot"
systemprop=/system/build.prop
bootprop="$TMPDIR/boot/default.prop"
buildprop="$TMPDIR/build.prop"
defaultprop="$TMPDIR/default.prop"

###############
#             #
#  FUNCTIONS  #
#             #
###############

toupper() {
  echo "$@" | tr '[:lower:]' '[:upper:]'
}

grep_prop() {
  # a recovery getprop()
  local REGEX="s/^$1=//p"
  shift
  local FILES=$@
  [ -z "$FILES" ] && FILES='/system/build.prop'
  sed -n "$REGEX" $FILES 2>/dev/null | head -n 1
}

grep_cmdline() {
  local REGEX="s/^$1=//p"
  cat /proc/cmdline | tr '[:space:]' '\n' | sed -n "$REGEX" 2>/dev/null
}

is_mounted() {
  cat /proc/mounts | grep -q " `readlink -f $1` " 2>/dev/null
  return $?
}

mount_all() {
   # Mount system as rw
  log "- Mounting /system"
  [ -f /system/build.prop ] || is_mounted /system || mount -o rw /system 2>/dev/null
  if ! is_mounted /system && ! [ -f /system/build.prop ]; then
    SYSTEMBLOCK=`find_block system$SLOT`
    mount -t ext4 -o rw $SYSTEMBLOCK /system
  fi
  [ -f /system/build.prop ] || is_mounted /system || ex "   ! Cannot mount /system"
  grep -qE '/dev/root|/system_root' /proc/mounts && SYSTEM_ROOT=true || SYSTEM_ROOT=false
  if [ -f /system/init ]; then
    SYSTEM_ROOT=true
    mkdir /system_root 2>/dev/null
    mount --move /system /system_root
    mount -o bind /system_root/system /system
  fi
}

clean_all() {
  # Clean /tmp
  busybox rm -rf "$TMPDIR/*.img"
  busybox rm -rf "$TMPDIR/*.prop"
  busybox rm -rf "$TMPDIR/boot"
  busybox rm -rf "$TMPDIR/*.sh"
}

get_flags() {
  # Get correct flags for dm-verity/forceencrypt patch
  # override variables
  KEEPVERITY=
  KEEPFORCEENCRYPT=
  if [ -z $KEEPVERITY ]; then
    if $SYSTEM_ROOT; then
      KEEPVERITY=true
    else
      KEEPVERITY=false
    fi
  fi
  if [ -z $KEEPFORCEENCRYPT ]; then
    grep ' /data ' /proc/mounts | grep -q 'dm-' && FDE=true || FDE=false
    [ -d /data/unencrypted ] && FBE=true || FBE=false
    # No data access means unable to decrypt in recovery
    if $FDE || $FBE || ! $DATA; then
      KEEPFORCEENCRYPT=true
    else
      KEEPFORCEENCRYPT=false
    fi
  fi
}

setup_bb() {
   # Make sure this path is in the front, and install bbx
   echo $PATH | grep -q "^$TMPDIR/bin" || export PATH=$TMPDIR/bin:$PATH
   $TMPDIR/bin/busybox --install -s $TMPDIR/bin
}

setup_flashable() {
  # Required for ui_print to work correctly
  # Preserve environment varibles
  OLD_PATH=$PATH
  setup_bb
  if [ -z $OUTFD ] || readlink /proc/$$/fd/$OUTFD | grep -q /tmp; then
    # We will have to manually find out OUTFD
    for FD in `ls /proc/$$/fd`; do
      if readlink /proc/$$/fd/$FD | grep -q pipe; then
        if ps | grep -v grep | grep -q " 3 $FD "; then
          OUTFD=$FD
          break
        fi
      fi
    done
  fi
}

find_block() {
  # function for finding device blocks
  for BLOCK in "$@"; do
    DEVICE=`find /dev/block -type l -iname $BLOCK | head -n 1` 2>/dev/null
    if [ ! -z $DEVICE ]; then
      readlink -f $DEVICE
      return 0
    fi
  done
  # Fallback by parsing sysfs uevents
  for uevent in /sys/dev/block/*/uevent; do
    local DEVNAME=`grep_prop DEVNAME $uevent`
    local PARTNAME=`grep_prop PARTNAME $uevent`
    for p in "$@"; do
      if [ "`toupper $p`" = "`toupper $PARTNAME`" ]; then
        echo /dev/block/$DEVNAME
        return 0
      fi
    done
  done
  return 1
}

find_boot_image() {
  # Find boot.img partition
  BOOTIMAGE=
  if [ ! -z $SLOT ]; then
    BOOTIMAGE=`find_block boot$SLOT ramdisk$SLOT`
  else
    BOOTIMAGE=`find_block boot ramdisk boot_a kern-a android_boot kernel lnx bootimg`
  fi
  if [ -z $BOOTIMAGE ]; then
    # Lets see what fstabs tells me
    BOOTIMAGE=`grep -v '#' /etc/*fstab* | grep -E '/boot[^a-zA-Z]' | grep -oE '/dev/[a-zA-Z0-9_./-]*' | head -n 1`
  fi
   [ ! -z $BOOTIMAGE ] && ui_print "   * Boot partition found at $BOOTIMAGE" || ex "   ! Unable to find boot partition!"
}

convert_boot_image() {
   # Convert to a raw boot.img, it required for devices with kitkat kernel and lower
   busybox dd if="$BOOTIMAGE" of="$TMPDIR/rawbootimage.img"
   [ -f /tmp/rawbootimage.img ] && BOOTIMAGEFILE="$TMPDIR/rawbootimage.img" && ui_print "   * Boot converted to rawbootimage.img" || ex "  ! Unable to convert boot image!"
}

ui_print() {
   # Sleep for 0.7 then print in gui.
   sleep 0.7
   echo -e "ui_print $1\n\nui_print" >> /proc/self/fd/$OUTFD
}

backup() {
   # Remove any old backup then backup.
   busybox rm -rf "${1}.bak"
   busybox echo $(cat "$1") >> "${1}.bak"
}

flash_image() {
   busybox dd if=$1 of=$2 && ui_print "   * Sucessfuly flashed $1" || ex "   ! Unable to flash $1!"
}

log() {
   echo -n -e "$@\n"
}

ex() {
   ui_print "$@"
   exit 1
}

fix_permissions() {
   # fix permissions for all in /system
   sleep 0.5
   # /system
   log "fixing permissions for /system"
   busybox chown 0.0 /system
   busybox chown 0.0 /system/*
   busybox chown 0.2000 /system/bin
   busybox chown 0.2000 /system/vendor
   busybox chown 0.2000 /system/xbin
   busybox chmod 755 /system/*
   find /system -type f -maxdepth 1 -exec busybox chmod 644 {} \;

  # /system/cameradata
   if [ -d "/system/cameradata" ]; then
   log "fixing permissions for /system/cameradata"
   busybox chown -R 0.0 /system/cameradata
   find /system/cameradata \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   fi

   # /system/bin
   log "fixing permissions for /system/bin"
   busybox chmod 755 /system/bin/*
   busybox chown 0.2000 /system/bin/*
   busybox chown -h 0.2000 /system/bin/*
   busybox chown 0.0 /system/bin/log /system/bin/ping
   busybox chmod 777 /system/bin/log

   # /system/csc
   if [ -d "/system/csc" ]; then
   log "fixing permissions for /system/csc"
   busybox chown -R 0.0 /system/csc
   find /system/csc \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   fi

   # /system/etc
   log "fixing permissions for /system/etc"
   busybox chown -R 0.0 /system/etc
   find /system/etc \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   busybox chown 1014.2000 /system/etc/dhcpcd/dhcpcd-run-hooks
   busybox chmod 550 /system/etc/dhcpcd/dhcpcd-run-hooks
   [ -d "/system/init.d" ] && busybox chmod 755 /system/etc/init.d/*

   # /system/finder_cp
   if [ -d "/system/finder_cp" ]; then
   log "fixing permissions for /system/      finder_cp"
   busybox chown 0.0 /system/fnder_cp/*
   busybox chmod 644 /system/finder_cp/*
   fi

   # /system/fonts
   log "fixing permissions for /system/fonts"
   busybox chown 0.0 /system/fonts/*
   busybox chmod 644 /system/fonts/*
   
   # /system/lib
   log "fixing permissions for /system/lib"
   busybox chown -R 0:0 /system/lib
   find /system/lib \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)

   # /system/lib64
   if [ -d "/system/lib64" ]; then
   log "fixing permissions for /system/lib64"
   busybox chown -R 0:0 /system/lib64
   find /system/lib64 \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   fi

   # /system/media
   log "fixing permissions for /system/media"
   busybox chown -R 0:0 /system/media
   find /system/media \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)

   # /system/sipdb
   if [ -d "/system/sipdb" ]; then
   log "fixing permissions for /system/sipdb"
   busybox chown 0.0 /system/sipdb/*
   busybox chmod 655 /system/sipdb/*
   fi

   # /system/tts
   if [ -d "/system/tts" ]; then
   log "fixing permissions for /system/tts"
   busybox chown -R 0:0 /system/tts
   find /system/tts \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   fi

  # /system/usr
   log "fixing permissions for /system/usr"
   busybox chown -R 0:0 /system/usr
   find /system/usr \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)

  # /system/vendor
   log "fixing permissions for /system/vendor"
   find /system/vendor \( -type d -exec    busybox chown 0.2000 {} + \) -o \( -type f -exec    busybox chown 0.0 {} + \)
   find /system/vendor \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)

  # /system/voicebargeindata
   if [ -d "/system/voicebargeindata" ]; then
   log "fixing permissions for /system/voicebargeindata"
   busybox chown -R 0:0 /system/voicebargeindata
   find /system/voicebargeindata \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   fi

   # /system/vold
   if [ -d "/system/vold" ]; then
   log "fixing permissions for /system/vold"
   busybox chown 0.0 /system/vold/*
   busybox chmod 644 /system/vold/*
   fi

   # /system/wallpaper
   if [ -d "/system/wallpaper" ]; then
   log "fixing permissions for /system/wakeupdata"
   busybox chown -R 0:0 /system/wakeupdata
   find /system/wakeupdata \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   fi

   # /system/wallpaper
   if [ -d "/system/wallpaper" ]; then
   log "fixing permissions for /system/wallpaper"
   busybox chown 0.0 /system/wallpaper/*
   busybox chmod 644 /system/wallpaper/*
   fi

   # /system/xbin
   log "fixing permissions for /system/xbin"
   busybox chmod 755 /system/xbin/*
   busybox chown 0.2000 /system/xbin/*
   busybox chown -h 0.2000 /system/xbin/*
   
   # /system/photoreader
   if [ -d "/system/photoreader" ]; then
   log "fixing permissions for /system/photoreader"
   busybox chown -R 0.2000 /system/photoreader/*
   find /system/photoreader/ \( -type d -exec busybox chmod 755 {} + \) -o \( -type f -exec busybox chmod 644 {} + \)
   fi
   ui_print "   * Fixed all permissions in /system"
}

prop_append() {
# Set out files paramaters
tweak="$1"
build="$2"

# Check for backup
answer=$(sed "s/BACKUP=//p;d" "$tweak")
case "$answer" in
        y|Y|yes|Yes|YES)
	    # Call backup function for system prop.
	    backup "$systemprop" ;;
	
        n|N|no|No|NO) ;;
        # Nothing
        
        *)
	    # Check if empty or invalid
	    [[ -z "$answer" || ! -d $(dirname "$answer") ]] && log "Given path is empty or parent directory does not exist" || backup "$answer" ;;
esac
sleep 2

# Required, since sed wont work without it.
echo "" >> $build

# Start appending
set -e
sed -r '/(^#|^ *$|^BACKUP=)/d;/(.*=.*|^\!|^\@.*\|.*|^\$.*\|.*)/!d' "$tweak" | while read line
do
	# Remove entry
	if echo "$line" | grep -q '^\!'
	then
		entry=$(echo "${line#?}" | sed -e 's/[\/&]/\\&/g')
		# Remove from $build if present
		grep -q "$entry" "$build" && (sed "/$entry/d" -i "$build" && ui_print "   * All lines containing \"$entry\" removed")

	# Append string
	elif echo "$line" | grep -q '^\@'
	then
		entry=$(echo "${line#?}" | sed -e 's/[\/&]/\\&/g')
		var=$(echo "$entry" | cut -d\| -f1)
		app=$(echo "$entry" | cut -d\| -f2)
		# Append string to $var's value if present in $build
		grep -q "$var" "$build" && (sed "s/^$var=.*$/&$app/" -i "$build" && ui_print "   * \"$app\" Appended to value of \"$var\"")

	# Ahange value only iif entry exists
	elif echo "$line" | grep -q '^\$'
	then
		entry=$(echo "${line#?}" | sed -e 's/[\/&]/\\&/g')
		var=$(echo "$entry" | cut -d\| -f1)
		new=$(echo "$entry" | cut -d\| -f2)
		# Change $var's value if $var present in $build
		grep -q "$var=" "$build" && (sed "s/^$var=.*$/$var=$new/" -i "$build" && ui_print "   * Value of \"$var\" changed to \"$new\"")

	# Add or override entry
	else
		var=$(echo "$line" | cut -d= -f1)
		# If variable already present in $build
		if grep -q "$var" "$build"
		then
			# Override value in $build if different
			grep -q $(grep "$var" "$tweak") "$build" || (sed "s/^$var=.*$/$line/" -i "$build" && ui_print "   * Value of \"$var\" overridden")
		# Else append entry to $build
		else
			echo "$line" >> "$build" && ui_print "   * Entry \"$line\" added"
		fi
	fi
done

# Trim empty and duplicate lines of $build
sed '/^ *$/d' -i "$build"
}

patch_ramdisk() {
script=patch.sh

# Mouve cpio for changing.
mv ramdisk.cpio $BOOTDIR/ramdisk.cpio
cd $BOOTDIR

# Check if default.prop found, add it if not then append.
ui_print "  - Adding Default.prop changes..."
if [ -f default.prop ]; then
    chmod 777 default.prop
    prop_append "$defaultprop" "$bootprop"
elif [ ! -f default.prop ]; then
    boot --cpio ramdisk.cpio \
    "extract default.prop default.prop"
    chmod 777 default.prop
    prop_append "$defaultprop" "$bootprop"
fi

# Start making a script to add all .rc at once, required since it will bootloop without it.
echo "boot --cpio ramdisk.cpio \\" >> $script

# Check if folder is empty from .rc files or not
if [[ `busybox ls | grep -Eo 'default.prop'` == *"default.prop"* ]]; then
   ui_print "   ! Boot folder empty, skipping .rc replaces"
else
   ui_print "  - Adding rc files to boot.img:"
   for file in $(busybox ls)
         do
            if [[ $file == *"ramdisk.cpio"* ]]; then
                 # Nothing
                 log "Skipped $file"
            elif [[ $file == *"patch.sh"* ]]; then
                 # Nothing
                 log "Skipped $file"
            else
                 ui_print "   * Adding ${file}"
                 echo "\"add 755 ${file} ${file}\" \\" >> $script
            fi
done
fi

# Add dm-verity/forceencrypt patch line, then run script
ui_print "   * Removing dm-verity,forceencryptition if found.."
echo "\"patch $KEEPVERITY $KEEPFORCEENCRYPT\"" >> $script
chmod 755 $script
./$script

# Ship out the new cpio, and return
cd $TMPDIR
mv $BOOTDIR/ramdisk.cpio ramdisk.cpio
}

port_boot() {
cd $TMPDIR

# Find boot.img partition from fstab, this is the advanced way
ui_print "  - Finding boot image partition"
find_boot_image

# Support kitkat kernel & older. (boot part dont have img header)
ui_print "  - Converting boot image"
convert_boot_image

# Unpack boot from partition (kitkat and older are suppprted)
ui_print "  - Unpacking boot image"
boot --unpack $BOOTIMAGEFILE && ui_print "   * Boot unpacked to $TMPDIR" || ex "  ! Unable to unpack boot image!"

# Check of zImage found. then replace kernel
if [ -f $BOOTDIR/zImage ]; then
    ui_print "  - Replacing Kernel.."
    rm -f kernel
    mv $BOOTDIR/zImage kernel
else
    ex "  ! No zImage present in boot folder, aborting.."
fi

# Call ramdisk patch function
patch_ramdisk

# Repack the boot.img as new-boot.img
ui_print "  - Repacking boot image"
boot --repack $BOOTIMAGEFILE && ui_print "   * Boot repacked to new-boot.img" || ex "  ! Unable to repack boot image!"

# Flash the new boot.img
ui_print "  - Flashing the new boot image"
flash_image new-boot.img $BOOTIMAGE

cd $ROOTDIR
}

################
#              #
# SCRIPT START #
#              #
################

# Call all functions oredred
setup_flashable

ui_print " - Main Script Started."

mount_all

get_flags

ui_print " - Adding Build.prop changes..."

prop_append "$buildprop" "$systemprop"

ui_print " - Porting Boot.img started:"

port_boot

ui_print " - Fixing /system permissions"
# Restore the old path, required since chmod,chown wont work without it
export PATH="$OLD_PATH"
fix_permissions

clean_all

ui_print " - Main Script Ended.."
