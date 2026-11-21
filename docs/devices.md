# Which Excitel units this applies to

The fleet isn't one box. I only had a UB5021 in front of me, the rest of this is what people
reported plus what the firmware images show. Most of them share the build tag shape, which is why
the method carries over at all.

## What's out there

| unit | firmware / family |
|---|---|
| DBC BC-323DAC-HGX | |
| Optilink OP-XONT71110AC | `V2.1.02-240416-OPL` |
| Optilink OP-EONU-95OO1Z | |
| Syrotech SY-GPON-2010-WADONT | |
| Uniway UW-101 | |
| Ubiqcom UB5021 | what the rest of this repo was written against |
| GX Group Wi-Fi 6 | MayaOS/OpenWRT, none of this applies |

`V2.1.xx-<yymmdd>-<CUSTOMER>` is the tell. DBC, Optilink, Syrotech and Ubiqcom all ship it, so
they're the same Realtek xPON MSDK lineage.

## Three keys that decide whether it transfers

All one-liners once you have a shell:

| key | this unit | what it changes |
|---|---|---|
| `SUSER_PASSWORD` | the fleet password from the README | it's the login, provisioned per device, not a code default |
| `CF_PASS_DEC_ENABLE` | `0` | `1` means `lastgood.xml` is `PWI…` blobs instead of plaintext, the Syrotech image is `1` |
| MIB 437 | not `1` | `1` closes `enterlinuxshell` and leaves only the ftp route |

## Checking your own

`tools/guess-onu.sh` derives candidates from the label and stops on the first hit. It's paced and
capped on purpose, run it against a unit you own.

Once you're in, the three keys above are the things to read. If 437 is `1` and the passthrough
stays off, the ftp route in the README is what's left.

Anything past the UB5021 I haven't run, so treat those rows as "same lineage", not "confirmed
working".
