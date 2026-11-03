# U-Boot boot script of the UniXNU launcher (Orange Pi 5). make-bootscr.py turns it into boot.scr, which goes to the root of the ESP.
#
# U-Boot's distro boot finds it by itself: it looks at the first partition of each drive in boot_targets for extlinux/extlinux.conf
# (there is none), then for boot.scr, and runs it with devtype, devnum and distro_bootpart set to the partition it was found on.
# uefi-launcher.img is a small stub with the firmware volume inside (tools/stub): it moves the volume to 0x200000 and jumps into
# it, the way TF-A starts BL33 when the firmware is in flash. 0xa000000 is far from that destination and from U-Boot's own data.
# The device tree handed over is U-Boot's own (fdtcontroladdr): UniXNURamDiskDxe looks for an initrd in it and finds none, which
# is the normal case here.
echo
echo UniXNU launcher: ${devtype} ${devnum}:${distro_bootpart}
setenv launcher_addr 0xa000000
if load ${devtype} ${devnum}:${distro_bootpart} ${launcher_addr} uefi-launcher.img; then
	booti ${launcher_addr} - ${fdtcontroladdr}
else
	echo UniXNU launcher: no uefi-launcher.img on ${devtype} ${devnum}:${distro_bootpart}
fi
