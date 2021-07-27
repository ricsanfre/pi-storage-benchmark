#!/bin/bash
# Storage benchmark: a tweaked version of the script provided by James A. Chambers (https://jamesachambers.com/)
# https://raw.githubusercontent.com/TheRemote/PiBenchmarks/master/Storage.sh


# Terminal colors
BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
LIME_YELLOW=$(tput setaf 190)
POWDER_BLUE=$(tput setaf 153)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BRIGHT=$(tput bold)
NORMAL=$(tput sgr0)
BLINK=$(tput blink)
REVERSE=$(tput smso)
UNDERLINE=$(tput smul)

# Prints a line with color using terminal codes
Print_Style() {
  printf "%s\n" "${2}$1${NORMAL}"
}

# Get binary from string
Get_Binary() {
  local BinaryStr
  BinaryStr=$(printf "$1" | xxd -r -p | xxd -b | cut -d: -f 2 | sed 's/  .*//; s/ //g' | sed ':a;N;$!ba;s/\n//g')
  echo "$BinaryStr"
}

# Get specific bits from binary string
Get_Bits() {
  # $1 - Binary String
  # $2 - BitsStart
  # $3 - BitsCount
  # $4 - Structure size in bits
  local BitsStart=$(($4 - $2 - $3))
  local BinaryStr=$(printf "$1")
  echo "${BinaryStr:BitsStart:$3}"
}

# Get decimal from binary
Get_Decimal() {
  echo "$((2#$1))"
}

# Get hex from binary
Get_Hex() {
  printf '%x\n' "$((2#$1))"
}

# Get string of text from binary
Get_Text() {
  for a in $1; do printf "%x\n" $((2#$a)); done | xxd -r -p
}

# 
Missing_Package () {
  Print_Style "Missing package $1" "$RED"
  exit 1
}

# Check if script is running as root first
if [[ "$(whoami)" != "root" ]]; then
  Print_Style "Benchmarks must be ran as root!  Example: sudo ./Storage.sh" "$RED"
  exit 1
fi

# Trim drives for more accurate benchmarking
fstrim -av
sync
sync

# Initialize variables
Score=0
DDWriteResult=0
fio4kRandReadIOPS=0
fio4kRandWriteIOPS=0
IO4kRead=0
IO4kWrite=0
IO4kRandRead=0
IO4kRandWrite=0

# Did the user give a folder ?
ChosenPartition=""
if [ "$1" = "" ]; then
  # User did not provide a partition/folder, change directory to rootfs
  cd /
else
  if [ ! -d "$1" ]; then
    Print_Style "Your chosen partition (folder) does not exist! Provide a good one or run without parameters to check the rootfs" "$RED"
    exit 1
  else
    ChosenPartition="$1"
    cd "$ChosenPartition"
  fi
fi

# Get host board information
HostArchitecture=$(uname -m)
HostOSInfo=$(cat /etc/os-release | sed 's/;/!/g')
HostOS=$(echo "$HostOSInfo" | grep "PRETTY_NAME" | cut -d= -f2 | xargs)

if [[ "$HostArchitecture" == *"x86"* || "$HostArchitecture" == *"amd64"* ]]; then
  # X86 or X86_64 system -- use dmidecode
  HostModel=$(dmidecode -t1 | grep 'Product Name' -m 1 | cut -d: -f2 | xargs)
  HostManufacturer=$(dmidecode -t1 | grep 'Manufacturer' -m 1 | cut -d: -f2 | xargs)
else
  # ARM system
  HostModel=$(tr -d '\0' </proc/device-tree/model)
  if [[ "$HostModel" == *"Raspberry Pi"* ]]; then
    HostManufacturer="Raspberry Pi Foundation"
  elif [[ "$HostModel" == *"Tinker Board"* ]]; then
    HostManufacturer="ASUSTeK"
  else
    HostManufacturer=""
  fi
fi
Print_Style "Board information: Manufacturer: $HostManufacturer - Model: $HostModel - Architecture: $HostArchitecture - OS: $HostOS" "$YELLOW"

# Checking required components
Print_Style "Checking required components ..." "$YELLOW"


# Check required packages
if [ -z "$(which lshw)" ]; then Missing_Package "lshw"; fi
if [ -z "$(which lspci)" ]; then Missing_Package "pciutils"; fi
if [ -z "$(which lsusb)" ]; then Missing_Package "usbutils"; fi
if [ -z "$(which lsscsi)" ]; then Missing_Package "lsscsi"; fi
if [ -z "$(which bc)" ]; then Missing_Package "bc"; fi
if [ -z "$(which curl)" ]; then Missing_Package "curl"; fi
if [ -z "$(which hwinfo)" ]; then Missing_Package "hwinfo"; fi
if [ -z "$(which hdparm)" ]; then Missing_Package "hdparm"; fi
if [ -z "$(which dmidecode)" ]; then Missing_Package "dmidecode"; fi
if [ -z "$(which fio)" ]; then Missing_Package "fio"; fi
if [ -z "$(which iozone)" ]; then Missing_Package "iozone3"; fi
if [ -z "$(which nvme)" ]; then Missing_Package "nvme-cli"; fi
if [ -z "$(which smartctl)" ]; then Missing_Package "smartmontools"; fi
if [ -z "$(which sdparm)" ]; then Missing_Package "sdparm"; fi
if [ -z "$(which xxd)" ]; then Missing_Package xxd -y; fi

DpkgArch=$(dpkg --print-architecture)

# Get clock speeds
if [[ "$HostArchitecture" == *"x86"* || "$HostArchitecture" == *"amd64"* ]]; then
  # X86 or X86_64 system -- use dmidecode
  HostCPUClock=$(dmidecode -t4 | grep -m 1 'Max Speed' | cut -d: -f2 | cut -d' ' -f2 | xargs)
  HostCoreClock=""
  HostRAMClock=$(dmidecode -t17 | grep -m 1 "Speed: " | cut -d' ' -f2 | xargs)
else
  # Check for vcgencmd
  if [ -n "$(which vcgencmd)" ]; then
    HostConfig=$(vcgencmd get_config int)
    HostCPUClock=$(echo "$HostConfig" | grep -m 1 arm_freq= | cut -d= -f2 | xargs)
    if [ -z "$HostCPUClock" ]; then
      HostCPUClock=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq | xargs)
      HostCPUClock=$(echo "scale=0; $HostCPUClock / 1000" | bc)
    fi
    HostCoreClock=$(echo "$HostConfig" | grep -m 1 core_freq= | cut -d= -f2 | xargs)
    if [ -z "$HostCoreClock" ]; then
      HostCoreClock=$(echo "$HostConfig" | grep -m 1 gpu_freq= | cut -d= -f2 | xargs)
    fi
    if [ -z "$HostCoreClock" ]; then
      HostCoreClock=$(vcgencmd measure_clock core | cut -d= -f2 | xargs)
      HostCoreClock=$(echo "scale=0; $HostCoreClock / 1000000" | bc)
    fi
    HostRAMClock=$(echo "$HostConfig" | grep -m 1 sdram_freq= | cut -d= -f2 | xargs)
    if [ -z "$HostRAMClock" ]; then
      HostRAMClock=""
    fi
    HostConfig+=$(echo " ")
    HostConfig+=$(vcgencmd get_config str)
  else
    HostConfig+=$(echo " ")
    HostCPUClock=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
    HostCPUClock=$(echo "scale=0; $HostCPUClock / 1000" | bc)
    HostCoreClock=""
    HostRAMClock=""
  fi
fi
Print_Style "Clock speeds: CPU: $HostCPUClock - Core: $HostCoreClock - RAM: $HostRAMClock" "$YELLOW"

# Run sync to make sure all changes have been written to disk
sync

if [ -z "$ChosenPartition" ]; then
  # User did not provide a partition/folder, continue with rootfs
  # --Get system boot drive information--
  # Find from mountpoint first
  BootDrive=$(findmnt -n -o SOURCE /)

  # Find by matching device IDs to / next
  if [ -z "$BootDrive" ]; then
    RDEV=$(mountpoint -d /)

    for file in /dev/*; do
      DeviceIDP1=$(stat --printf="0x%t" "$file")
      DeviceIDP2=$(stat --printf="0x%T" "$file")
      DeviceID=$(printf "%d:%d" "$DeviceIDP1" "$DeviceIDP2")
      if [ "$DeviceID" = "$RDEV" ]; then
        BootDrive=$file
        break
      fi
    done
  fi

  # Fall back to finding from lsblk
  if [ -z "$BootDrive" ]; then
    BootDrive=$(lsblk -l | grep -v "0 part /boot" | grep -m 1 "0 part /" | awk 'NR==1{ print $1 }')
    if [ -n "$BootDrive" ]; then
      BootDrive="/dev/"$BootDrive
    fi
  fi

  # Fall back to finding from df
  if [ -z "$BootDrive" ]; then
    BootDrive=$(df -H | grep -m 1 boot | awk 'NR==1{ print $1 }')
  fi
else
  BootDrive=$(findmnt -n -o SOURCE "$ChosenPartition")
fi

# Detect BootDrive suffix
BootDriveSuffix=$(echo "$BootDrive" | cut -d"/" -f3)
if [ -z "$BootDriveSuffix" ]; then
  BootDriveSuffix=$(echo "$BootDrive" | cut -d"/" -f2)
fi
if [ -z "$BootDriveSuffix" ]; then
  BootDriveSuffix=$(echo "$BootDrive" | cut -d"/" -f1)
fi
if [ -z "$BootDriveSuffix" ]; then
  BootDriveSuffix="$BootDrive"
fi

if [ -z "$ChosenPartition" ]; then
  Print_Style "System rootfs drive (/) has been detected as $BootDrive ($BootDriveSuffix)" "$YELLOW"
else
  Print_Style "Chosen partition ($ChosenPartition) has been detected as $BootDrive ($BootDriveSuffix)" "$YELLOW"
fi

Print_Style "Starting INXI hardware identification..." "$YELLOW"
# Retrieve inxi hardware identification utility (https://github.com/smxi/inxi for more info)
curl -o inxi https://raw.githubusercontent.com/smxi/inxi/master/inxi
chmod +x inxi
Test_inxi=$(./inxi -F -v8 -c0 -M -m -d -f -i -l -m -o -p -r -t -u -xxx 2>&1 | sed 's/;/!/g')
./inxi -v4 -d -c0 2>&1
rm -f inxi

Print_Style "Running additional hardware identification tests..." "$YELLOW"
Test_udevadm=$(udevadm info -a -n "$BootDrive" 2>&1 | sed 's/;/!/g' | sed '/^[[:space:]]*$/d')
Test_lsblk=$(lsblk -l -o NAME,FSTYPE,LABEL,MOUNTPOINT,SIZE,MODEL 2>&1 | sed 's/;/!/g')
Test_lshw=$(lshw 2>&1 | sed 's/;/!/g')
Test_lsusb=$(lsusb 2>&1 | sed 's/;/!/g')
Test_lsscsi=$(lsscsi -Lv 2>&1 | sed 's/;/!/g')
Test_lscpu=$(lscpu 2>&1 | sed 's/;/!/g')
Test_lspci=$(lspci -v 2>&1 | sed 's/;/!/g')
Test_findmnt=$(findmnt -n 2>&1 | sed 's/;/!/g')
Test_diskbyid=$(ls /dev/disk/by-id 2>&1 | sed 's/;/!/g')
Test_df=$(df -h 2>&1 | sed 's/;/!/g')
Test_cpuinfo=$(cat /proc/cpuinfo 2>&1 | sed 's/;/!/g')
Test_dmesg=$(dmesg -Lnever 2>&1 | grep usb | sed 's/;/!/g')
Test_fstab=$(cat /etc/fstab 2>&1 | sed 's/;/!/g')
Test_dmidecode=$(dmidecode 2>&1 | sed 's/;/!/g')
Test_hwinfo=$(hwinfo --arch --bios --block --bridge --disk --framebuffer --gfxcard --hub --ide --isapnp --listmd --memory --mmc-ctrl --monitor --netcard --partition --pci --pcmcia --pcmcia-ctrl --redasd --scsi --sound --storage-ctrl --sys --tape --usb --usb-ctrl 2>&1 | sed 's/;/!/g')
Test_nvme=$(nvme list -o json 2>&1)
Test_nvme+=$(nvme show-regs "$BootDrive" -H 2>&1 | sed 's/;/!/g')
Test_smartctl=$(smartctl -x "$BootDrive" 2>&1 | sed 's/;/!/g')
Test_smartctl=$(sudo sdparm --long --verbose "$BootDrive" 2>&1 | sed 's/;/!/g')
Capacity=$(lsblk -l 2>&1 | grep "$BootDriveSuffix" -m 1 | awk 'NR==1{ print $4 }' | sed 's/,/./g')

# Check for Micro SD / MMC card
if [[ "$BootDrive" == *"mmcblk"* ]]; then
  # Determine if MMC or Micro SD
  RootDrive=$(echo "$BootDrive" | cut -dp -f1 | cut -d/ -f3)
  MMCType=$(cat /sys/block/"$RootDrive"/device/type)

  # Get card information
  Manufacturer=$(echo "$Test_udevadm" | grep -m 1 "manfid" | cut -d= -f3 | cut -d\" -f2 | xargs)
  if [ -z "$Manufacturer" ]; then
    Manufacturer=$(cat /sys/block/"$RootDrive"/device/manfid)
    Product=$(cat /sys/block/"$RootDrive"/device/type)
    Firmware=$(cat /sys/block/"$RootDrive"/device/fwrev)
    DateManufactured=$(cat /sys/block/"$RootDrive"/device/date)
    Model=$(cat /sys/block/"$RootDrive"/device/name)
    Version=$(cat /sys/block/"$RootDrive"/device/hwrev)
    Vendor=$(cat /sys/block/"$RootDrive"/device/oemid)
    SSR=$(cat /sys/block/"$RootDrive"/device/ssr)
    SCR=$(cat /sys/block/"$RootDrive"/device/scr)
    CID=$(cat /sys/block/"$RootDrive"/device/cid)
    CSD=$(cat /sys/block/"$RootDrive"/device/csd)
    OCR=$(cat /sys/block/"$RootDrive"/device/ocr)
  else
    Product=$(echo "$Test_udevadm" | grep -m 1 "{type}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    Firmware=$(echo "$Test_udevadm" | grep -m 1 "{fwrev}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    DateManufactured=$(echo "$Test_udevadm" | grep -m 1 "date" | cut -d= -f3 | cut -d\" -f2 | xargs)
    Model=$(echo "$Test_udevadm" | grep -m 1 "{name}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    Version=$(echo "$Test_udevadm" | grep -m 1 "{hwrev}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    Vendor=$(echo "$Test_udevadm" | grep -m 1 "oemid" | cut -d= -f3 | cut -d\" -f2 | xargs | xxd -r)
    SSR=$(echo "$Test_udevadm" | grep -m 1 "{ssr}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    SCR=$(echo "$Test_udevadm" | grep -m 1 "{scr}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    CID=$(echo "$Test_udevadm" | grep -m 1 "{cid}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    CSD=$(echo "$Test_udevadm" | grep -m 1 "{csd}" | cut -d= -f3 | cut -d\" -f2 | xargs)
    OCR=$(echo "$Test_udevadm" | grep -m 1 "{ocr}" | cut -d= -f3 | cut -d\" -f2 | xargs)
  fi

  if [[ "$MMCType" == *"SD"* ]]; then
    # MicroSD hardware identification
    Print_Style "Starting SD card identification..." "$YELLOW"

    HostSDClock=$(grep "actual clock" /sys/kernel/debug/mmc0/ios 2>/dev/null | awk '{printf("%0.1f", $3/1000000)}')

    # Parse SSR status register
    SSRBinary=$(Get_Binary "$SSR")
    SSRAppClass=$(Get_Decimal "$(Get_Bits "$SSRBinary" 336 4 512)")
    SSRVideoClass=$(Get_Decimal "$(Get_Bits "$SSRBinary" 384 8 512)")
    SSRUHSClass=$(Get_Decimal "$(Get_Bits "$SSRBinary" 396 4 512)")
    SSRSpeedClass=$(Get_Decimal "$(Get_Bits "$SSRBinary" 440 8 512)")

    # Parse CID status register
    CIDBinary=$(Get_Binary "$CID")
    CIDMID=$(Get_Hex "$(Get_Bits "$CIDBinary" 120 8 128)")
    CIDMDateM=$(Get_Decimal "$(Get_Bits "$CIDBinary" 8 4 128)")
    CIDMDateY=$(Get_Decimal "$(Get_Bits "$CIDBinary" 12 8 128)")
    CIDMDate="$CIDMDateM/20$CIDMDateY"
    CIDOID=$(Get_Text "$(Get_Bits "$CIDBinary" 104 16 128)")
    CIDPNM=$(Get_Text "$(Get_Bits "$CIDBinary" 64 40 128)")
    CIDPRVHW=$(Get_Hex "$(Get_Bits "$CIDBinary" 60 4 128)")
    CIDPRVFW=$(Get_Hex "$(Get_Bits "$CIDBinary" 56 4 128)")
    CIDPRV="$CIDPRVHW.$CIDPRVFW"

    # Parse CSD status register
    CSDBinary=$(Get_Binary "$CSD")
    CSDMID=$(Get_Hex "$(Get_Bits "$CSDBinary" 120 8 128)")
    Print_Style "Card CSD status register: MID: $CIDMID OID: $CIDOID PNM: $CIDPNM PRV: $CIDPRV MDATE: $CIDMDate" "$YELLOW"

    # Parse SCR status register
    SCRBinary=$(Get_Binary "$SCR")
    SCRSDSpec=$(Get_Decimal "$(Get_Bits "$SCRBinary" 56 4 64)")
    SCRSDSpec3=$(Get_Decimal "$(Get_Bits "$SCRBinary" 47 1 64)")
    SCRSDSpec4=$(Get_Decimal "$(Get_Bits "$SCRBinary" 42 1 64)")
    SCRSDSpecX=$(Get_Decimal "$(Get_Bits "$SCRBinary" 38 4 64)")

    # Get SD physical layer specification version
    if [ "$SCRSDSpecX" == "2" ]; then # 6.XX
      SCRSDSpecVer="6"
    elif [ "$SCRSDSpecX" == "1" ]; then # 5.XX
      SCRSDSpecVer="5"
    elif [ "$SCRSDSpec4" == "1" ]; then # 4.XX
      SCRSDSpecVer="4"
    elif [ "$SCRSDSpec3" == "1" ]; then # 3.XX
      SCRSDSpecVer="3"
    elif [ "$SCRSDSpec" == "2" ]; then # 2.00
      SCRSDSpecVer="2"
    elif [ "$SCRSDSpec" == "1" ]; then # 1.10
      SCRSDSpecVer="1.1"
    elif [ "$SCRSDSpec" == "0" ]; then # 1.0
      SCRSDSpecVer="1"
    fi
    Print_Style "Card SCR status register: SD Physical Version Specification: $SCRSDSpecVer" "$YELLOW"

    # Check for known manufacturers
    case "$Manufacturer" in
    0x000001)
      Manufacturer="Panasonic"
      ;;
    0x000002)
      Manufacturer="Toshiba"
      ;;
    0x000003)
      Manufacturer="SanDisk"
      ;;
    0x000008)
      Manufacturer="Silicon Power"
      ;;
    0x000018)
      Manufacturer="Infineon"
      ;;
    0x00001b)
      Manufacturer="Samsung"
      ;;
    0x00001d)
      Manufacturer="Corsair/AData"
      ;;
    0x000027)
      Manufacturer="Phison"
      ;;
    0x000028)
      Manufacturer="Lexar"
      ;;
    0x000030)
      Manufacturer="SanDisk"
      ;;
    0x000031)
      Manufacturer="Silicon Power"
      ;;
    0x000033)
      Manufacturer="STMicroelectronics"
      ;;
    0x000041)
      Manufacturer="Kingston"
      ;;
    0x000045)
      Manufacturer="Team Group"
      ;;
    0x00006f)
      Manufacturer="STMicroelectronics"
      ;;
    0x000073)
      Manufacturer="Hama"
      ;;
    0x000074)
      Manufacturer="Transcend"
      ;;
    0x000076)
      Manufacturer="Patriot"
      ;;
    0x000082)
      Manufacturer="Sony"
      ;;
    0x000092)
      Manufacturer="Sony"
      ;;
    0x00009c)
      Manufacturer="Sony"
      ;;
    0x00009e)
      Manufacturer="Lexar"
      ;;
    0x00009f)
      Manufacturer="Texas Instruments"
      ;;
    0x0000ff)
      Manufacturer="Netac"
      ;;
    *) ;;

    esac

    # Identify card classifications
    Class=""
    if [[ $SSRAppClass -gt 0 ]]; then
      Class="A$SSRAppClass"
    fi
    case "$SSRSpeedClass" in
    0)
      Class="$Class Class 0"
      ;;
    1)
      Class="$Class Class 2"
      ;;
    2)
      Class="$Class Class 4"
      ;;
    3)
      Class="$Class Class 6"
      ;;
    4)
      Class="$Class Class 10"
      ;;
    *)
      Class="$Class ?"
      ;;
    esac
    if [[ $SSRVideoClass -gt 0 ]]; then
      Class="$Class V$SSRVideoClass"
    fi
    if [[ $SSRUHSClass -gt 0 ]]; then
      Class="$Class U$SSRUHSClass"
    fi
    Class=$(echo "$Class" | xargs)
    Print_Style "MicroSD information: Clock Speed: $HostSDClock - Manufacturer: $Manufacturer - Model: $Model - Vendor: $Vendor - Product: $Product - HW Version: $Version - FW Version: $Firmware - Date Manufactured: $DateManufactured - Class: $Class" "$YELLOW"
  elif [[ "$MMCType" == *"MMC"* ]]; then
    # Attempt to identify MMC device

    HostSDClock=""

    case "$Manufacturer" in
    0x000000)
      Manufacturer="SanDisk"
      ;;
    0x000002)
      Manufacturer="Kingston/SanDisk"
      ;;
    0x000003)
      Manufacturer="Toshiba"
      ;;
    0x000011)
      Manufacturer="Toshiba"
      ;;
    0x000015)
      Manufacturer="Samsung/SanDisk/LG"
      ;;
    0x000037)
      Manufacturer="KingMax"
      ;;
    0x000044)
      Manufacturer="SanDisk"
      ;;
    0x000090)
      Manufacturer="SK Hynix"
      ;;
    0x00002c)
      Manufacturer="Kingston"
      ;;
    0x000070)
      Manufacturer="Kingston"
      ;;
    *) ;;

    esac

    # Get capacity
    DriveCapacity=$(cat /sys/block/"$RootDrive"/device/emmc_total_size)
    if [ -n "$DriveCapacity" ]; then
      if [ "$DriveCapacity" -eq "$DriveCapacity" ] 2>/dev/null; then
        Capacity=$DriveCapacity"G"
      fi
    fi

    # Parse CSD register
    CSDBinary=$(Get_Binary "$CSD")
    CSDSpecVersion=$(Get_Decimal "$(Get_Bits "$CSDBinary" 122 4 128)")

    # Parse CID register
    CIDBinary=$(Get_Binary "$CID")
    CIDCBX=$(Get_Decimal "$(Get_Bits "$CIDBinary" 112 1 128)")

    # Check CBX value to see if MMC is embedded or removable
    case "$CIDCBX" in
    0)
      Product="MMC"
      Class="MMC v$CSDSpecVersion (Card)"
      ;;
    1)
      Product="eMMC"
      Class="eMMC v$CSDSpecVersion (Embedded)"
      ;;
    10)
      Product="MMC"
      Class="MMC v$CSDSpecVersion (POP)"
      ;;
    *) ;;

    esac

    Print_Style "MMC Type: $Class - Manufacturer: $Manufacturer - Model: $Model - Size: $Capacity" "$YELLOW"

  fi
else
  # Not a MicroSD card
  Print_Style "Starting mass storage device identification..." "$YELLOW"

  HDParmInfo=$(hdparm -Ii "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
  if [ -z "$HDParmInfo" ]; then
    HDParmInfo=$(hdparm -I "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
  fi
  Test_hdparm=$(echo "$HDParmInfo")

  HostSDClock=""
  DateManufactured=""

  # Attempt to identify drive model
  Model=$(echo "$Test_udevadm" | grep -m 1 "{model}" | cut -d= -f3 | cut -d\" -f2 | xargs)
  Vendor=$(echo "$Test_udevadm" | grep -m 1 "{vendor}" | cut -d= -f3 | cut -d\" -f2 | xargs)
  Manufacturer=$(echo "$Test_udevadm" | grep -m 1 "{manufacturer}" | cut -d= -f3 | cut -d\" -f2 | xargs)

  case "$Model" in
  "ASM105x")
    # This is the ASMedia USB TO 2.5" SATA adapter chipset
    Product="SSD"
    FormFactor="2.5"
    Class="SSD (2.5\" SATA)"
    Adapter="ASMedia ASM105x"
    Model=
    Manufacturer=
    ;;
  "SABRENT")
    # This is the Sabrent USB TO 2.5" SATA adapter chipset
    Product="SSD"
    FormFactor="2.5"
    Class="SSD (2.5\" SATA)"
    Adapter="Sabrent"
    Model=
    Manufacturer=
    ;;
  "2105")
    # ASMedia adapter 2105
    Product="SSD"
    FormFactor="2.5"
    Class="SSD (2.5\" SATA)"
    Adapter="ASMedia 2105"
    Model=
    Manufacturer=
    ;;
  "2115")
    # ASMedia adapter 2115
    Product="SSD"
    FormFactor="2.5"
    Class="SSD (2.5\" SATA)"
    Adapter="ASMedia 2115"
    Model=
    Manufacturer=
    ;;
  "USB 3.0 Device")
    # ASMedia USB to SATA adapter (generic)
    Product="SSD"
    FormFactor="2.5"
    Class="SSD (2.5\" SATA)"
    Adapter="ASMedia 3.0 Generic"
    Model=
    Manufacturer=
    ;;
  "AQ3120")
    # Geekworm x855
    Product="SSD"
    FormFactor="2.5"
    Class="SSD (mSATA)"
    Adapter="Geekworm x855"
    Model=
    Manufacturer=
    ;;
  *) ;;

  esac
  if [ -z "$Model" ]; then
    Model=$(echo "$Test_hdparm" | grep -m 1 "Model Number:" | awk 'NR==1{ print $3 }' | grep "_" | cut -d_ -f2 | xargs)
  fi
  if [ -z "$Model" ]; then
    Model=$(echo "$Test_hdparm" | grep -m 1 "Model Number:" | awk 'NR==1{ print $3 }' | grep " " | cut -d" " -f2 | xargs)
  fi
  if [ -z "$Model" ]; then
    Model=$(echo "$Test_hdparm" | grep -m 1 "Model Number:" | awk 'NR==1{ print $3$4$5$6$7$8$9 }' | xargs)
  fi
  if [ -z "$Model" ]; then
    Model=$(echo "$Test_hdparm" | grep -m 1 "Model Number:" | awk 'NR==1{ print $3$4$5$6$7$8$9 }' | xargs)
  fi

  # Attempt to identify drive manufacturer
  if [ -z "$Manufacturer" ]; then
    Manufacturer=$(echo "$Test_hdparm" | grep -m 1 "Model Number:" | grep "_" | awk 'NR==1{ print $3 }' | cut -d_ -f1 | xargs)
  fi
  if [ -z "$Manufacturer" ]; then
    Manufacturer=$(echo "$Test_hdparm" | grep -m 1 "Model Number:" | grep " " | awk 'NR==1{ print $3 }' | cut -d" " -f1 | xargs)
  fi
  if [ -z "$Manufacturer" ]; then
    Manufacturer=$(echo "$Test_hdparm" | grep -m 1 "Model Number:" | awk 'NR==1{ print $3 }' | xargs)
  fi

  # Identify drive type, form factor
  if [ -z "$FormFactor" ]; then
    FormFactor=$(echo "$Test_hdparm" | grep -m 1 "Form Factor:" | cut -d: -f2 | cut -d' ' -f1 | xargs)
    if [ -z "$FormFactor" ]; then
      FormFactor="2.5"
    fi
  fi

  # Attempt to get drive capacity
  DriveCapacity=$(echo "$Test_hdparm" | grep -m 1 "device size with M = 1000*" | cut -d\( -f2 | cut -d' ' -f1 | xargs)
  if [ -n "$DriveCapacity" ]; then
    if [ "$DriveCapacity" -eq "$DriveCapacity" ] 2>/dev/null; then
      Capacity=$DriveCapacity"G"
    fi
  fi

  # Attempt to identify drive type
  DriveType=$(echo "$Test_hdparm" | grep -m 1 "Nominal Media Rotation Rate:" | cut -d: -f2 | xargs)
  case "$DriveType" in
  5400 | 7200 | 10000)
    Product="HDD"
    Class="HDD ($FormFactor\" SATA)"
    ;;
  "Solid State Device")
    Product="SSD"
    Class="SSD ($FormFactor\" SATA)"
    ;;
  *)
    Product="USB Flash"
    Class="USB Flash Drive"
    ;;
  esac

  # Identify hardware and firmware versions of drive
  Version=$(echo "$Test_udevadm" | grep -m 1 "{version}" | cut -d= -f3 | cut -d\" -f2 | xargs)
  Firmware=$(echo "$Test_hdparm" | grep -m 1 "Firmware Revision:" | awk 'NR==1{ print $3$4$5$6 }')
  if [ -n "$Firmware" ]; then
    Firmware=$(echo "$Test_hdparm" | grep -m 1 "Firmware Revision:" | awk 'NR==1{ print $3$4$5$6 }')
  fi
fi

# Run HDParm tests
Print_Style "Running HDParm tests ..." "$YELLOW"
sync
sync
HDParm=$(hdparm -Tt --direct "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
if [ -z "$HDParm" ]; then
  HDParm=$(hdparm -Tt "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
fi
if [ -z "$HDParm" ]; then
  HDParm=$(hdparm -T --direct "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
fi
if [ -z "$HDParm" ]; then
  HDParm=$(hdparm -T "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
fi
if [ -z "$HDParm" ]; then
  HDParm=$(hdparm -t --direct "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
fi
if [ -z "$HDParm" ]; then
  HDParm=$(hdparm -t "$BootDrive" 2>/dev/null | sed '/^[[:space:]]*$/d')
fi
Print_Style "$HDParm" "$NORMAL"
HDParmDisk=$(echo "$HDParm" | grep "disk reads:" | awk 'NR==1{ print $11 }' | sed 's/;/!/g')
HDParmCached=$(echo "$HDParm" | grep "cached reads:" | awk 'NR==1{ print $11 }' | sed 's/;/!/g')
Print_Style "HDParm: $HDParmDisk MB/s - HDParmCached: $HDParmCached MB/s" "$YELLOW"

# Run DD tests
Print_Style "Running dd tests ..." "$YELLOW"
sync
sync
DDWrite=$(dd if=/dev/zero of=test bs=4k count=80k conv=fsync 2>&1 | sed '/^[[:space:]]*$/d')
DDWriteResult=$(echo "$DDWrite" | tail -n 1 | awk 'NR==1{ print $(NF-1) }' | sed 's/,/./g')

echo "$DDWrite"
Print_Style "DD Write Speed: $DDWriteResult MB/s" "$YELLOW"
rm -f test

# Run fio tests
Print_Style "Running fio write test ..." "$YELLOW"
sync
sync
fio4kRandWrite=$(fio --minimal --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=test --bs=4k --iodepth=64 --size=80M --readwrite=randwrite | sed 's/;/!/g')
fio4kRandWriteIOPS=$(echo "$fio4kRandWrite" | awk -F '!' '{print $49}')
fio4kRandWriteSpeed=$(echo "$fio4kRandWrite" | awk -F '!' '{print $48}')
rm -f test
Print_Style "Running fio read test ..." "$YELLOW"
sync
sync
fio4kRandRead=$(fio --minimal --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=test --filename=test --bs=4k --iodepth=64 --size=80M --readwrite=randread | sed 's/;/!/g')
fio4kRandReadIOPS=$(echo "$fio4kRandRead" | awk -F '!' '{print $8}')
fio4kRandReadSpeed=$(echo "$fio4kRandRead" | awk -F '!' '{print $7}')
Print_Style "FIO results - 4k RandWrite: $fio4kRandWriteIOPS IOPS ($fio4kRandWriteSpeed KB/s) - 4k RandRead: $fio4kRandReadIOPS IOPS ($fio4kRandReadSpeed KB/s)" "$YELLOW"
rm -f test

# Run iozone tests
Print_Style "Running iozone test ..." "$YELLOW"
sync
sync
if [ -z "$(which iozone)" ]; then
  IOZone=$(iozone/src/current/./iozone -a -e -I -i 0 -i 1 -i 2 -s 80M -r 4k)
else
  IOZone=$(iozone -a -e -I -i 0 -i 1 -i 2 -s 80M -r 4k)
fi
IO4kRandRead=$(echo "$IOZone" | tail -n 3 | awk 'NR==1{ print $7 }')
IO4kRandWrite=$(echo "$IOZone" | tail -n 3 | awk 'NR==1{ print $8 }')
IO4kRead=$(echo "$IOZone" | tail -n 3 | awk 'NR==1{ print $5 }')
IO4kWrite=$(echo "$IOZone" | tail -n 3 | awk 'NR==1{ print $3 }')
echo "$IOZone"
IOZone=$(echo "$IOZone" | sed '/^[[:space:]]*$/d')
Print_Style "RandRead: $IO4kRandRead - RandWrite: $IO4kRandWrite - Read: $IO4kRead - Write: $IO4kWrite" "$YELLOW"

# Calculate score
Score=$(echo "scale=2; $DDWriteResult * 1024" | bc)
ScratchPad=$(echo "scale=2; $fio4kRandReadIOPS * 4" | bc)
Score=$(echo "scale=2; $Score + $ScratchPad" | bc)
ScratchPad=$(echo "scale=2; $fio4kRandWriteIOPS * 10" | bc)
Score=$(echo "scale=2; $Score + $ScratchPad" | bc)
Score=$(echo "scale=2; $Score + $IO4kRead" | bc) 
Score=$(echo "scale=2; $Score + $IO4kWrite" | bc)
ScratchPad=$(echo "scale=2; $IO4kRandRead * 4" | bc)
Score=$(echo "scale=2; $Score + $ScratchPad" | bc)
ScratchPad=$(echo "scale=2; $IO4kRandWrite * 10" | bc)
Score=$(echo "scale=2; $Score + $ScratchPad" | bc)
Score=$(echo "scale=0; $Score / 100" | bc)

# Display results
printf "\n$BRIGHT$UNDERLINE%-25s %-25s %-25s\n" "     Category" "     Test" '     Result     '"$NORMAL$CYAN"
printf "%-25s %-25s %-25s\n" "HDParm" "Disk Read" "$HDParmDisk MB/s"
printf "%-25s %-25s %-25s\n" "HDParm" "Cached Disk Read" "$HDParmCached MB/s"
printf "%-25s %-25s %-25s\n" "DD" "Disk Write" "$DDWriteResult MB/s"
printf "%-25s %-25s %-25s\n" "FIO" "4k random read" "$fio4kRandReadIOPS IOPS ($fio4kRandReadSpeed KB/s)"
printf "%-25s %-25s %-25s\n" "FIO" "4k random write" "$fio4kRandWriteIOPS IOPS ($fio4kRandWriteSpeed KB/s)"
printf "%-25s %-25s %-25s\n" "IOZone" "4k read" "$IO4kRead KB/s"
printf "%-25s %-25s %-25s\n" "IOZone" "4k write" "$IO4kWrite KB/s"
printf "%-25s %-25s %-25s\n" "IOZone" "4k random read" "$IO4kRandRead KB/s"
printf "%-25s %-25s %-25s\n" "IOZone" "4k random write" "$IO4kRandWrite KB/s"
printf "\n$BRIGHT$MAGENTA$UNDERLINE%-25s %-25s %-25s\n" " " "Score: $Score" " "

Print_Style "End Test" "$NORMAL"
# Return to home directory
cd ~ || return
