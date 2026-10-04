#!/sbin/sh
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Universal repartitioner for the 7870, V1.0
# Written by @Astrako
#
# Adapted for Samsung Galaxy A2 Core - SM-A260F (a2corelte) / SM-A260G (a2coreltedd)
# Changes vs original:
#   - Auto-detects 8GB vs 16GB eMMC and picks safe SYSTEM sizes
#   - Handles CPEFS (present on a2core, absent on Astrako's devices)
#   - Fixed unquoted -z tests (OMR/CP_DEBUG/NAD_FW/NAD_REFER don't exist here)
#   - Backs up PIT + EFS + CPEFS to /tmp before modifying the GPT
#

SGDISK=/sbin/sgdisk
if [ ! -x "$SGDISK" ]; then
	SGDISK=/tmp/sgdisk
fi
if [ ! -x "$SGDISK" ]; then
	echo "ERROR: sgdisk not found (tried /sbin/sgdisk and /tmp/sgdisk)"
	exit 1
fi

DISK=/dev/block/mmcblk0
BYP=/dev/block/platform/13540000.dwmmc0/by-name

# --- Detect storage variant and pick sizes accordingly ---
# 8GB eMMC  = ~15.3M sectors  |  16GB eMMC = ~30.5M sectors
SECTORS=$($SGDISK --print $DISK | grep 'Disk /dev' | awk '{printf $3}')
if [ -n "$SECTORS" ] && [ "$SECTORS" -gt 20000000 ]; then
	echo "Detected 16GB variant ($SECTORS sectors)"
	SYSTEMSIZE=3072
else
	echo "Detected 8GB variant ($SECTORS sectors)"
	SYSTEMSIZE=1792
fi

VENDORSIZE=512
CACHESIZE=64

ODMSIZE=128 # New ODM partition size for those devices having it. Mod this value at your own risk

# --- Pre-flight backups: unbrick insurance. PULL THESE FROM /tmp VIA adb BEFORE REBOOT ---
echo "Backing up PIT, EFS and CPEFS to /tmp ..."
$SGDISK --backup=/tmp/pit_a2core_backup.bin $DISK
dd if=$BYP/EFS   of=/tmp/efs_a2core_backup.img   bs=1048576
dd if=$BYP/CPEFS of=/tmp/cpefs_a2core_backup.img bs=1048576 2>/dev/null || echo "CPEFS backup skipped (not present)"
sync
echo ">>> adb pull /tmp/pit_a2core_backup.bin /tmp/efs_a2core_backup.img /tmp/cpefs_a2core_backup.img"

CP_DEBUG=$($SGDISK --print $DISK | grep CP_DEBUG  | awk '{printf $1}')
HIDDEN=$($SGDISK --print $DISK    | grep HIDDEN    | awk '{printf $1}')
NAD_FW=$($SGDISK --print $DISK    | grep NAD_FW    | awk '{printf $1}')
NAD_REFER=$($SGDISK --print $DISK | grep NAD_REFER | awk '{printf $1}')
ODM=$($SGDISK --print $DISK       | grep ODM       | awk '{printf $1}')
OMR=$($SGDISK --print $DISK       | grep OMR       | awk '{printf $1}')
VENDOR=$($SGDISK --print $DISK    | grep VENDOR    | awk '{printf $1}')
CPEFS=$($SGDISK --print $DISK     | grep CPEFS     | awk '{printf $1}')

DISKCODE=$($SGDISK --print $DISK | grep SYSTEM | awk '{printf $6}')

function delete() {
	$SGDISK --delete=$1 $DISK
}

function calculate() {
	SYSPART=$($SGDISK --print $DISK | grep SYSTEM | awk '{printf $1}')
	delete $SYSPART

	if [ ! -z "$VENDOR" ]; then
		VENDORPART=$($SGDISK --print $DISK | grep VENDOR | awk '{printf $1}')
		delete $VENDORPART
	fi

	CACHEPART=$($SGDISK --print $DISK | grep CACHE | awk '{printf $1}')
	delete $CACHEPART

	if [ ! -z "$ODM" ]; then
		ODMPART=$($SGDISK --print $DISK | grep ODM | awk '{printf $1}')
		if [ "$ODMPART" -gt "$SYSPART" ]; then
			delete $ODMPART
		fi
	fi

	if [ ! -z "$HIDDEN" ]; then
		HIDDENPART=$($SGDISK --print $DISK | grep HIDDEN | awk '{printf $1}')
		if [ "$HIDDENPART" -gt "$SYSPART" ]; then
			delete $HIDDENPART
		fi
	fi

	if [ ! -z "$OMR" ]; then
		OMRPART=$($SGDISK --print $DISK | grep OMR | awk '{printf $1}')
		if [ "$OMRPART" -gt "$SYSPART" ]; then
			OMRSIZE=$($SGDISK --print $DISK | grep OMR | awk '{printf $4 $5}' | sed 's/\.[0-9]*//g')
			delete $OMRPART
		fi
	fi

	if [ ! -z "$CP_DEBUG" ]; then
		CPDPART=$($SGDISK --print $DISK | grep CP_DEBUG | awk '{printf $1}')
		if [ "$CPDPART" -gt "$SYSPART" ]; then
			CPDSIZE=$($SGDISK --print $DISK | grep CP_DEBUG | awk '{printf $4 $5}' | sed 's/\.[0-9]*//g')
			delete $CPDPART
		fi
	fi

	if [ ! -z "$NAD_FW" ]; then
		NADFWPART=$($SGDISK --print $DISK | grep NAD_FW | awk '{printf $1}')
		if [ "$NADFWPART" -gt "$SYSPART" ]; then
			NADFWSIZE=$($SGDISK --print $DISK | grep NAD_FW | awk '{printf $4 $5}' | sed 's/\.[0-9]*//g')
			delete $NADFWPART
		fi
	fi

	if [ ! -z "$NAD_REFER" ]; then
		NADRFPART=$($SGDISK --print $DISK | grep NAD_REFER | awk '{printf $1}')
		if [ "$NADRFPART" -gt "$SYSPART" ]; then
			NADRFSIZE=$($SGDISK --print $DISK | grep NAD_REFER | awk '{printf $4 $5}' | sed 's/\.[0-9]*//g')
			delete $NADRFPART
		fi
	fi

	# a2core-specific: CPEFS lives in the CP group; handle it if it's after SYSTEM
	if [ ! -z "$CPEFS" ]; then
		CPEFSPART=$($SGDISK --print $DISK | grep CPEFS | awk '{printf $1}')
		if [ "$CPEFSPART" -gt "$SYSPART" ]; then
			CPEFSSIZE=$($SGDISK --print $DISK | grep CPEFS | awk '{printf $4 $5}' | sed 's/\.[0-9]*//g')
			delete $CPEFSPART
		fi
	fi

	DATAPART=$($SGDISK --print $DISK | grep USERDATA | awk '{printf $1}')
	delete $DATAPART
}

function repart() {
	$SGDISK --new=0:0:+${SYSTEMSIZE}Mib --typecode=0:$DISKCODE --change-name=0:SYSTEM $DISK
	$SGDISK --new=0:0:+${VENDORSIZE}Mib --typecode=0:$DISKCODE --change-name=0:VENDOR $DISK
	$SGDISK --new=0:0:+${CACHESIZE}Mib --typecode=0:$DISKCODE --change-name=0:CACHE $DISK

	if [ ! -z "$ODM" ] && [ "$ODMPART" -gt "$SYSPART" ]; then
		$SGDISK --new=0:0:+${ODMSIZE}Mib --typecode=0:$DISKCODE --change-name=0:ODM $DISK
	fi
	if [ ! -z "$OMR" ] && [ "$OMRPART" -gt "$SYSPART" ]; then
		$SGDISK --new=0:0:+$OMRSIZE --typecode=0:$DISKCODE --change-name=0:OMR $DISK
	fi
	if [ ! -z "$CP_DEBUG" ] && [ "$CPDPART" -gt "$SYSPART" ]; then
		$SGDISK --new=0:0:+$CPDSIZE --typecode=0:$DISKCODE --change-name=0:CP_DEBUG $DISK
	fi
	if [ ! -z "$NAD_FW" ] && [ "$NADFWPART" -gt "$SYSPART" ]; then
		$SGDISK --new=0:0:+$NADFWSIZE --typecode=0:$DISKCODE --change-name=0:NAD_FW $DISK
	fi
	if [ ! -z "$NAD_REFER" ] && [ "$NADRFPART" -gt "$SYSPART" ]; then
		$SGDISK --new=0:0:+$NADRFSIZE --typecode=0:$DISKCODE --change-name=0:NAD_REFER $DISK
	fi
	if [ ! -z "$CPEFS" ] && [ "$CPEFSPART" -gt "$SYSPART" ]; then
		$SGDISK --new=0:0:+$CPEFSSIZE --typecode=0:$DISKCODE --change-name=0:CPEFS $DISK
	fi

	$SGDISK --new=0:0:0 --typecode=0:$DISKCODE --change-name=0:USERDATA $DISK
}

# main
calculate
repart

echo "=== New partition table ==="
$SGDISK --print $DISK
