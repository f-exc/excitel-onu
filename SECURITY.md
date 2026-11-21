# Scope

All of this is my own CPE, from the LAN side. Nothing in here is aimed at Excitel's
infrastructure or at hardware I don't own.

The tools are read-only apart from `tools/guess-onu.sh`, which tries candidate passwords derived
from one unit's own label against that unit, paced and capped at 250 attempts. Run it on yours.

## Reporting

Open an issue on this repo.

## Not in scope

- ISP infrastructure
- someone else's ONU
- WAN-side scanning
- bootloader or firmware work that can brick the box
