#!/bin/sh
# Dumps the live firmware off the ONU over ssh and unpacks the squashfs images.
#   ./tools/dump-onu-firmware.sh            -> build/onu/
# The login shell must be a real shell: excitel's shell field is /bin/cli after a reboot,
# and then ssh accepts the login and silently eats every command.
set -u

HOST=${ONU_HOST:-192.168.1.1}
USER=${ONU_USER:-excitel}
DEST=${DEST:-build/onu}
XML=${MIB_DUMP:-captures/ftp-lastgood.xml}
KEY=${ONU_KEY:-$HOME/.ssh/id_ed25519}
SSH_OPTS="-T -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mibval() { grep -o "Name=\"$1\" Value=\"[^\"]*\"" "$XML" 2>/dev/null | sed 's/.*Value="//;s/"$//'; }

# the ssh password is the web super-user one; sshpass -e keeps it out of argv
PASS=${ONU_PASS:-$(mibval SUSER_PASSWORD)}
use_key=/dev/null
if [ -f "$KEY" ] && ssh -i "$KEY" $SSH_OPTS -o BatchMode=yes -o PreferredAuthentications=publickey \
        "$USER@$HOST" true 2>/dev/null; then
    use_key=$KEY
fi

if [ "$use_key" != /dev/null ]; then
    ssh_box() { ssh -i "$use_key" $SSH_OPTS "$USER@$HOST" "$@"; }
elif [ -n "$PASS" ] && command -v sshpass >/dev/null 2>&1; then
    ssh_box() { SSHPASS="$PASS" sshpass -e ssh $SSH_OPTS "$USER@$HOST" "$@"; }
else
    say "note: no key and no password, ssh will prompt"
    ssh_box() { ssh $SSH_OPTS "$USER@$HOST" "$@"; }
fi
say "auth: $( [ "$use_key" != /dev/null ] && echo "key $use_key" || { [ -n "$PASS" ] && echo sshpass || echo prompt; } )"

mkdir -p "$DEST" || die "cannot create $DEST"

# once per boot: drop our public key in /tmp/.ssh (home is /tmp for this user), after that
# every ssh in here is key-only and never asks for a password
if [ "${1:-}" = --install-key ]; then
    [ -f "$KEY.pub" ] || die "no $KEY.pub to install"
    say "==> installing $KEY.pub into /tmp/.ssh/authorized_keys"
    ssh_box "mkdir -p /tmp/.ssh; chmod 700 /tmp/.ssh; cat >> /tmp/.ssh/authorized_keys; \
        chmod 600 /tmp/.ssh/authorized_keys; cat /tmp/.ssh/authorized_keys" < "$KEY.pub" \
        || die "install failed (shell is /bin/cli?)"
    say "done - rerun without --install-key"
    exit 0
fi

####################
# 1. probe          #
####################
# this busybox has no id, uname, whoami, head or tail, so the probe only uses applets and
# /proc that are actually there; /proc/self/status is the reliable privilege check
say "==> probing ssh $USER@$HOST"
probe=$(ssh_box 'echo ONUSHELL; cat /proc/self/status | grep -i "^Uid:"; cat /proc/version' 2>&1 | tr -d '\r')
say "$probe"
case $probe in
    *ONUSHELL*)
        case $probe in *"Uid:	0"*) ;; *) say "    warning: not uid 0, reading a block device will fail" ;; esac ;;
    *) die "ssh gives no shell: $USER's shell field is /bin/cli, not /bin/sh.
    One-time fix per boot, from a shell you already have (telnet on 23, same credentials):
      sed -i 's|:/bin/cli$|:/bin/sh|' /var/passwd
    then rerun this script. /var is ramfs, so a reboot reverts it." ;;
esac

####################
# 2. what to read   #
####################
mounts=$(ssh_box 'cat /proc/mounts' 2>&1 | tr -d '\r')
[ -n "$mounts" ] || die "could not read /proc/mounts"

# /proc/mounts lists / twice (rootfs, then the real squashfs), so ignore the kernel's own
# rootfs/none entries and keep the first device that is actually backed by an mtd block
dev_of() {
    printf '%s\n' "$mounts" | while read -r dev mnt fstype rest; do
        [ "$mnt" = "$1" ] || continue
        case $fstype in rootfs|none|proc|sysfs|tmpfs|ramfs|devpts) continue ;; esac
        echo "$dev"; break
    done
}

mtd_dev_by_name() { # mtd partition name -> /dev/mtdblockN, last match wins
    n=$(ssh_box 'cat /proc/mtd' 2>/dev/null | tr -d '\r' | grep "\"$1\"" | tail -1 | sed 's/^mtd\([0-9]*\):.*/\1/')
    case $n in ''|*[!0-9]*) return 1 ;; esac
    echo "/dev/mtdblock$n"
}

# /dev/root is a kernel alias and may not even exist in /dev, so never hand it to cat.
# the cmdline on this box says `root=31:5`, a major:minor, not a /dev path
root_dev=$(dev_of /)
case $root_dev in
    /dev/mtdblock*) ;;
    *)
        root_dev=$(ssh_box 'cat /proc/cmdline' 2>/dev/null | tr -d '\r' | tr ' ' '\n' | \
            grep '^root=' | tail -1 | sed 's|^root=||')
        case $root_dev in
            31:[0-9]*) root_dev=/dev/mtdblock${root_dev#31:} ;;
            /dev/mtdblock*) ;;
            *) root_dev=$(mtd_dev_by_name rootfs) || die "cannot resolve the rootfs block device" ;;
        esac
        ;;
esac
cust_dev=$(dev_of /custconf)

say "rootfs device:   ${root_dev:-unknown}"
say "custconf device: ${cust_dev:-not mounted}"
[ -n "$root_dev" ] || die "cannot resolve the mounted rootfs"

####################
# 3. pull           #
####################
pull_dev() { # block device, output name
    say "==> $2 from $1"
    ssh_box "cat $1" > "$DEST/$2"
    [ -s "$DEST/$2" ] || die "$2 came back empty"
    ls -l "$DEST/$2"
}

pull_dev "$root_dev" rootfs.img
[ -n "$cust_dev" ] && pull_dev "$cust_dev" custconf.img

# /etc and the generated files live in the ramfs overlay, so take the live tree too;
# no gzip applet here, so plain tar
say "==> livefs.tar from /bin /etc /lib /usr /home"
ssh_box 'cd / && tar cf - bin etc lib usr home 2>/dev/null' > "$DEST/livefs.tar" || true
ls -l "$DEST/livefs.tar"

####################
# 4. verify         #
####################
if ssh_box 'command -v md5sum' >/dev/null 2>&1; then
    for pair in "$root_dev:rootfs.img" "${cust_dev:-none}:custconf.img"; do
        dev=${pair%%:*}; img=${pair##*:}
        [ -s "$DEST/$img" ] || continue
        remote=$(ssh_box "md5sum $dev" 2>/dev/null | awk '{print $1}')
        if command -v md5sum >/dev/null 2>&1; then local=$(md5sum "$DEST/$img" | awk '{print $1}'); else local=$(md5 -q "$DEST/$img"); fi
        [ "$remote" = "$local" ] && say "md5 ok   $img" || say "md5 FAIL $img ($remote != $local)"
    done
else
    say "no md5sum on the box, skipped checksum"
fi

####################
# 5. unpack         #
####################
export UV_CACHE_DIR="$PWD/build/.uv-cache"
for img in rootfs custconf; do
    [ -s "$DEST/$img.img" ] || continue
    uv run -q --with PySquashfsImage python tools/unsquashfs.py "$DEST/$img.img" "$DEST/$img" \
        || say "    $img.img is not squashfs (first bytes: $(head -c 4 "$DEST/$img.img" | od -An -tx1 | tr -d ' '))"
done
say "==> done, see $DEST"
