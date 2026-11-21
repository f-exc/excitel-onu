Excitel a few months ago blocked the login to router admin page, and i wanted to change a few settings (ssid and disable the `www.excitel.com` wifi), but as i cant login the only way was to get root shell. The ISP gave me a UBIQCOM UB5021 GVW-D for an EPON line, and the box is locked. The label `user` account answers `Forbid user login, please log in with administrator account!` and the only admin account is `root` with a password you don't get.

| | |
|---|---|
| Model | UBIQCOM UB5021 GVW-D, EPON HGU |
| SoC / kernel | RTL9607C, Linux 3.18 |
| Userspace | busybox 1.22.1, uClibc, MIPS32r2 big-endian |
| Firmware | `V2.1.08-260703-UBLL` |
| Web UI | `boa` 0.93.15, runs as uid 0 |
| ssh | dropbear 2024.86 |
| Network services | telnet/ftp/ssh spawned by `inetd` as root |
| Config | one plaintext MIB at `/var/config/lastgood.xml`, 178 KB, `CF_PASS_DECRY_ENABLE=0` |

Doesn't matter, there's a super-user account on the same box and its password is the same on every unit they ship.

## The password

The super-user password sits in that MIB as `SUSER_PASSWORD`. I pulled mine off the board's 3.3V UART header, you don't need to, it's the same string on every device.

| what | user | password | opens |
|---|---|---|---|
| super user (`SUSER_*`) | `excitel` | `Kl!4fz0Nbsu$` | web UI, ssh, `/bin/cli` |
| telnet (`TELNET_*`) | `root` | `Kl!4fz0Nbsu$` | `/bin/cli` on 23, once telnet is on |
| web root (`MGMACC_*`) | `root` | `Excitel@root123#` | web UI only, not in `/var/passwd` |
| ftp (`FTP_*`) | `e8ftp` | `e8ftp` | root FTP, unchrooted, whole filesystem |

`excitel` is already uid 0. `/etc/passwd` is a symlink to `/var/passwd` and the line is `0:0` with `/bin/cli` as the shell, so the lock was the shell field and not the privilege level.

## Logging in

Both ways below start here, there are only two accounts that matter and both land on the same `/bin/cli`.

Port 22 is dropped by the firewall on IPv4 from every path:

```
-A inacc -i br0 -p tcp -m tcp --dport 22 -j DROP
```

IPv6 isn't covered by that rule, so the link-local address answers. Link-local doesn't route, so you have to be on the ONU's L2 segment, plug into one of its LAN ports or run it from a router whose WAN sits on that segment. (like in my case i ran all of this from an ssh shell in my JIDU router)

The address is the EUI-64 of the ONU MAC, flip the U/L bit and put `ff:fe` in the middle, so `F4:BD:B9:AA:BB:89` is `fe80::f6bd:b9ff:feaa:bb89`. Or ask the segment:

```sh
ping6 -c1 ff02::1%en0          # macos
ndp -an | grep fe80

ping -6 -c1 ff02::1%eth0       # linux
ip -6 neigh | grep fe80
```

Then:

```sh
ssh excitel@fe80::f6bd:b9ff:feaa:bb89%en0
```

Password is the super-user one. dropbear is a 2024 build so no legacy algorithm flags are needed. You land on a `>` prompt, that's `/bin/cli`, and `help` only lists `config show debug exit reboot`, but there is a hidden seventh command and it is filtered out of it:

```
> enterlinuxshell
```

That one is the whole of the first way. The second way never uses it.

## The ssh way

Type the hidden command. It execs `/bin/sh` as whatever uid cli has (ie. `0`), and on this build it goes straight to `#` without asking for anything. Busybox has no `id`, `uname`, `whoami`, and `ps` takes no options, so check it like this:

```sh
cat /proc/self/status | grep -i uid
# Uid:    0       0       0       0
```

Nothing is written and nothing is saved, so a reboot takes it back to the CLI and you type it again. That is the cheapest way in, it depends on the gate byte not being set in whatever build you're on.

## The ftp way

Use this one if `enterlinuxshell` asks for a password on your build. `/bin/ftpd` runs as root with no chroot, so it is a write primitive to `/var/passwd`, which is where the login shell comes from.

Turn it on from the CLI:

```
> config remoteaccess ftp lan "allow" wan "deny"
```

Both files are one curl, the read is the MIB:

```sh
curl -s "ftp://e8ftp:e8ftp@192.168.1.1//var/config/lastgood.xml" -o lastgood.xml
```

The login dir is `/var/tmp` and curl makes the first path segment relative to it, so one
slash is `550 var: No such file or directory`. Two slashes and it's absolute. lftp and plain
ftp don't hit this, it's curl doing the `CWD`.

The write is the account file. Take the `excitel` line in a copy of `/var/passwd` and change the shell field from `/bin/cli` to `/bin/sh`, then put it back:

```sh
curl -T passwd "ftp://e8ftp:e8ftp@192.168.1.1//var/passwd"
```

Next ssh or telnet login is `#` instead of the CLI, no hidden command involved. `/var` is ramfs and `configd` regenerates the file from the MIB on any account write, so a reboot puts `/bin/cli` back and you repeat the STOR.

## Once you have a shell

Same shell either way. `lastgood.xml` has the lot, `SUSER_*`, `TELNET_*`, `FTP_*`, `MGMACC_*`, `pppUser`/`pppPasswd`/`pppServiceName` (service name is `excitel`), the ACS url and both of its passwords, the wifi PSKs.

`/` is squashfs read-only, `/var` is ramfs, `/custconf` is read-only. Only `/var/config` on `/dev/mtdblock3` is writable and persistent, so nothing you do in `/var` survives a reboot. There's no boot hook to abuse either, the only exec surface out of persistent storage is `/etc/runsdk.sh` calling `/var/config/run_customized_sdk.sh` when `PON_MODE=1`, and this box is EPON with `PON_MODE=2`. Don't set it to 1 to try, you'd boot the GPON stack on an EPON line and pondetect would flip it back and reboot.

What does survive is the remoteaccess flags, so keep whichever door you like open:

```
> config remoteaccess telnet lan "allow" wan "deny"
> config save
```

Then `telnet 192.168.1.1`, `root` and the super-user password, `enterlinuxshell`, `#`, and the next boot is a telnet away instead of a ssh hop. `config save` writes the MIB so the flag sticks.

also: cli is single instance, a second session gets `CLI busy !!` and the holder is in `/var/run/cli.pid`. Leave `mtd_util`, `flash_erase`, `xmlconfig -w` and `nv setenv` alone, that's the config partition and the boot slot. A TR-069 `Download` is a full MIB write and can re-lock the box. And changing the super-user password in the web UI moves the ssh password with it, telnet keeps whatever `TELNET_PASSWD` holds.
