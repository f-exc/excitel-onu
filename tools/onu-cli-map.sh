#!/usr/bin/env bash
# Walk the ONU's restricted CLI and log every reply.
# Read-only: only help/?/show are sent — nothing is written to the device.
#
#   ONU_PASS='...' ./tools/onu-cli-map.sh '<fe80::link-local>%wan'
#   ONU_PASS='...' ./tools/onu-cli-map.sh '<fe80::link-local>%wan'   # from the JIDU
#
# Output: captures/onu-cli-map.log
set -u
HOST=${1:-}
if [ -z "$HOST" ]; then
    echo "usage: $0 <ONU-link-local>%wan" >&2
    exit 1
fi
ONU_USER=${ONU_USER:-excitel}
: "${ONU_PASS:?set ONU_PASS (the excitel ssh password)}"
export HOST ONU_USER ONU_PASS
mkdir -p captures
LOG=captures/onu-cli-map.log
echo "target: ${ONU_USER}@${HOST}" >"$LOG"

/usr/bin/expect <<'EOF' 2>&1 | tee -a "$LOG"
set timeout 25
spawn ssh -tt -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 $env(ONU_USER)@$env(HOST)

expect {
    eof { puts "\nCONNECTION CLOSED (unreachable, or sshd refused)"; exit 1 }
    -re "(?i)password:" { send -- "$env(ONU_PASS)\r"; exp_continue }
    -re "(?i)permission denied" { puts "\nLOGIN FAILED"; exit 1 }
    -re "(?i)host key verification failed" { puts "\nHOST KEY"; exit 1 }
    timeout { puts "\nno password prompt (unreachable?)"; exit 1 }
}

# drain helper: wait for output to settle, never match anything
proc drain {t} {
    set timeout $t
    catch {
        expect {
            eof     { return }
            -re "###NEVER###" {}
            timeout {}
        }
    }
}

drain 4

set cmds {
    help
    show ?
    config ?
    debug ?
    show help
    config help
    debug help
    show version
    show status
    show device
    show config
    show wan
    show interface
    show log
    exit
}

foreach c $cmds {
    puts "\n===== CMD: $c ====="
    if {[catch {send -- "$c\r"}]} { puts "(connection closed)"; break }
    drain 3
}

catch { send -- "exit\r" }
catch { expect { eof {} timeout {} } }
EOF

echo
echo "wrote $LOG ($(wc -l <"$LOG") lines)"
