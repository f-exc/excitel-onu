# ONU firmware: what is writable, what survives a reboot

UBIQCOM UB5021 GVW-D, `V2.1.08-260703-UBLL`. This is the stuff i needed once ssh on ipv4 started
working: where anything actually persists, the one rule that blocks port 22, and why every fix i
tried died at the next reboot. Also what came out of dumping the live firmware instead of
trusting a sibling build i found online.

## What is writable at all

Runtime mounts on this box:

| mount | device / fs | writable | survives reboot |
|---|---|---|---|
| `/` | `/dev/root` squashfs ro, 9472 KB, 100% used | no | it is the firmware |
| `rootfs` on `/` | kernel ramfs | yes, into RAM | no |
| `/var` | ramfs (`mount -t ramfs ramfs /var` in `rc2`) | yes, into RAM | no |
| `/var/config` | `/dev/mtdblock3` yaffs2, 10668 KB, ~9004 KB free | yes | **yes** |
| `/custconf` | `/dev/mtdblock8` or `9` squashfs ro, 768 KB | no | no |
| `/dev` | tmpfs, rebuilt by `mdev -s` | yes, into RAM | no |

So `/var/config` is the only persistent writable filesystem. `/var` being ramfs is why
`/var/tmp/fastfetch` only lives until the next reboot, and why the `/var/passwd` shell swap is
gone after one too.

There are two other persistent writable things that are not filesystems: the U-Boot env
(mtd1 `env` / mtd2 `env2`, written by `nv setenv`, and it is what picks the boot slot, so don't
touch it) and the firmware slots mtd4..mtd13 via `mtd_util` / `flash_erase` / the vendor `fwu.sh`
path.

`rc2` has a writable branch for `/custconf` (`mount -w /dev/mtdblock6`) that only runs when the
multiboot env vars are missing. It's `-w` on a squashfs so writes fail anyway, and this box takes
the `-r mtdblock8|9` branch.

Firmware updates don't touch `/var/config` either, `fwu.sh` only writes kernel/rootfs/custconf
into the inactive slot, so config outlives upgrades.

## ssh on 22: the inacc chain

`INPUT` policy is DROP but `br0` state NEW is accepted, and the drop on 22 is in a subchain that
runs before that:

```
-A inacc -i br0 -p tcp -m tcp --dport 22 -j DROP
```

`inacc` also drops 137, 138, 139, 445 and 69 for `-i br0`, plus two `! -i br0` rules. `libmib.so`
builds it, and the only holes it knows how to punch are MAC-scoped ones for port 23 (vendor test
rig MACs: `70:85:c2:88:31:c9`, `80:14:a8:00:5B:%02x`), which is the shape of the rule they expect.

Working rule, scoped to br0 so the WAN side stays closed:

```sh
iptables -t filter -I inacc 1 -i br0 -p tcp -m tcp --dport 22 -j ACCEPT
```

Reverse with `-D`. It dies on reboot and also on any `config save` or web config apply, because
`mib` rebuilds `inacc` from scratch. `FW_INACC` exists in `libmib.so` but is never exported into
`lastgood.xml`, so there is no MIB value that says "don't drop 22".

Don't `-F inacc` or `-X inacc`, you lose the LAN noise drops and the `! -i br0` handling too.

`show remoteaccess` printing `SSH LAN: Disabled` is dead state, `config remoteaccess` only takes
`ftp http ping telnet tftp`.

## There is no boot hook in this build

The only script-exec surface out of persistent storage in the whole firmware is this, in
`/etc/runsdk.sh`:

```sh
if [ "$pon_mode" == "PON_MODE=1" ]; then
	if [ ! -f /var/config/run_customized_sdk.sh ]; then
		cp /etc/run_customized_sdk.sh /var/config/run_customized_sdk.sh
	fi
	/var/config/run_customized_sdk.sh
```

and `PON_MODE=2` on this box (`flash get PON_MODE`, `xmlconfig -g PON_MODE`). The EPON branch runs
`runoam.sh`, which has no hooks. Grepping every binary and script for `/var/config/*.sh` returns
that one line, nothing else.

The file sitting in `/var/config` is a fossil, either baked into the factory config image or copied
on a much earlier boot when `PON_MODE` was still 1. `pondetect` is what flips the mode
(`flash set PON_MODE %d` then `pon auto detect: MIB_PON_MODE set to mode=%d, and then reboot`), so
a change only lands on the following boot. Don't set `PON_MODE=1` to use the hook, you'd boot the
GPON stack on an EPON line and `pondetect` would flip it back and reboot, which is a boot loop with
the ONU off the PON.

Also worth knowing it's a root exec surface that pre-boot state can re-arm by changing one MIB key.
If `PON_MODE` ever reads 1, whatever is in that file runs as root before the network is up.

The one other code path out of `/var/config` is Lua, and it's inert:

```lua
-- /etc/lua_script/info_monitor_process.lua
local setting = common_api.safe_require("mqtt_info_monitor_setting","/var/config/?.lua")
```

`safe_require` sets `package.path` and calls `require`, so that file would be executed. But
`info_monitor_process.lua` is loaded by `mqtt_vccm`, which isn't running, and the MIB says why:
`MQTT_ENABLE=0` with every `MQTT_*` value empty. `MQTT_*` is ACS-writable, so if that ever gets
provisioned the ONU has a root-level Lua channel from the config partition.

## The live firmware dump

`tools/dump-onu-firmware.sh` pulls it over ssh, no staging on the box. It resolves the mounted
devices instead of trusting the mtd table, `cat`s the block devices (there is no `dd` in this
busybox), tars `/bin /etc /lib /usr /home` uncompressed (no gzip applet either), and unpacks the
squashfs images with `tools/unsquashfs.py`. That extractor needed fixing first, it was dropping
every symlink, 146 of them per image, including `bin/iptables -> xtables-multi` and the busybox
applets.

`/proc/mounts` lists `/` twice (`rootfs / rootfs rw` then `/dev/root / squashfs ro`), so
device resolution has to skip the kernel's own entry and go through `root=` in `/proc/cmdline`,
falling back to the partition literally named `rootfs` in `/proc/mtd`. `/dev/root` itself may not
exist in `/dev` at all.

Live build against the Goip/Bsnl image that was pulled off the internet:

| | live (Excitel/UBIQCOM) | Goip |
|---|---|---|
| busybox md5 | `fdf2094b87acb61f1fb942cb17b0cdd3` | `0eb27b9ed967e90b27e3ff39f001eb8f` |
| files / symlinks | 827 / 146 | 547 / 147 |
| `dd`, `head`, `tail`, `wc`, `od` | absent | absent, has `hd` and `hexdump` |
| `ubi*` tools | none | 13 of them |
| vendor extras | `vs_log`, `vs_lua_custom_translator`, `mqtt_vccm`, `wlan_cli_mgm`, `handleVINCEPktHeader`, `vlist_monitor` | none |

Applets that exist on this box: `arping ash awk bash btftp busybox cat chmod cmp cp crond df diff
echo egrep expr fgrep find free fuser grep halt ifconfig init insmod kill killall klogd linuxrc ls
lsmod md5sum mdev mkdir mknod mount mv nc netstat nslookup pgrep pidof ping ping6 poweroff ps
reboot rm rmmod route sed sh sleep stty sync tar timeout top touch traceroute traceroute6 umount
uptime vconfig wget xargs`.

`/etc/inetd.conf` on the live box, all four services spawned by inetd:

```
tftp  dgram  udp wait   root /bin/tftpd
telnet stream tcp nowait root /bin/telnetd
ftp    stream tcp nowait root /bin/ftpd
ssh    stream tcp nowait root /bin/dropbear -i
```

For reference, `flash` is not in PATH, it's `/etc/scripts/flash` and it's a wrapper around
`/bin/xmlconfig -g`.

So the honest options for keeping a firewall rule across a reboot are: re-apply it per boot, or
patch the rootfs and flash it. There is no file to drop, no MIB key to set.
