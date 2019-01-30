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

mount_all() {
# Mount system as rw
for part in system
do
	if mount | grep -q "/$part"
	then
		mount -o rw,remount "/$part" "/$part" && log "$part mounted"
	else
		mount -o rw "/$part" && log "$part mounted"
	fi
done
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

toupper() {
  echo "$@" | tr '[:lower:]' '[:upper:]'
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

grep_prop() {
  # a recovery getprop()
  local REGEX="s/^$1=//p"
  shift
  local FILES=$@
  [ -z "$FILES" ] && FILES='/system/build.prop'
  sed -n "$REGEX" $FILES 2>/dev/null | head -n 1
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
}

convert_boot_image() {
   # Convert to a raw boot.img, it required for devices with kitkat kernel and lower
   busybox dd if="$BOOTIMAGE" of="$TMPDIR/rawbootimage.img"
   [ -f /tmp/rawbootimage.img ] && BOOTIMAGEFILE="$TMPDIR/rawbootimage.img" || ex "  ! Unable to convert boot image"
}

ui_print() {
   # Sleep for 0.5 then print in gui.
   sleep 0.6
   echo -e "ui_print $1\n\nui_print" >> /proc/self/fd/$OUTFD
}

backup() {
   # Remove any old backup then backup.
   busybox rm -rf "${1}.bak"
   busybox echo $(cat "$1") >> "${1}.bak"
}

flash_image() {
   busybox dd if="$1" of="$2"
}

log() {
   echo -n -e "$@\n"
}

ex() {
   ui_print "$@"
   exit 1
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
find_boot_image

# Support kitkat kernel & older. (boot part dont have img header)
ui_print "  - Converting boot image"
convert_boot_image

# Unpack boot from partition (kitkat and older are suppprted)
ui_print "  - Unpacking boot image"
boot --unpack $BOOTIMAGEFILE || ex "  ! Unable to unpack boot image!"

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
boot --repack $BOOTIMAGEFILE || ex "  ! Unable to repack boot image!"

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

clean_all

ui_print " - Main Script Ended.."
