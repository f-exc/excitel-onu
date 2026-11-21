# Excitel ONU (UBIQCOM UB5021 GVW-D) — access investigation

**Date:** 2026-11-07
**Device:** UBIQCOM UB5021 GVW-D, dual-band XPON ONU/router, Realtek chipset, managed via Excitel OLT/ACS
**ISP:** Excitel (India FTTH)
**Address:** 192.168.1.1
**Goal:** regain administrative access to the ONU web UI / WAN configuration

## Symptom

Web UI at `http://192.168.1.1` redirects to `/admin/login.asp`. Login with the
credentials printed on the device label fails. ISP states the login password was
set by them and will not disclose it.

## Conclusion (short)

The lock is real and sits in the firmware: the label account `user` is flagged
**"Forbid user login"**, and the only administrator account is **`root`**, whose
password is provisioned by the ISP. No documented default matches it. No
unauthenticated path to an admin session exists. Resolution requires the ISP or a
hardware-level (UART) approach.

> **Update 2026-11-18 — superseded.** Root access was regained without the ISP and without
> UART, through the provisioning channel rather than the login pages. Short version: the
> TR-069 parameter tree returned the vendor telnet account in clear (`ServiceManage.TelnetUserName`
> = `root`, plus its password), which logs into the same restricted CLI; that CLI is what
> re-enabled the FTP service, and the FTP account from the same tree authenticates against
> `/bin/ftpd` **running as uid 0 and unchrooted**, which is full read/write on the
> filesystem. `/var/config/lastgood.xml` is the whole MIB in plaintext, and rewriting
> `/var/passwd` with `/bin/sh` instead of `/bin/cli` yields a uid-0 shell over ssh.
>
> Corrected because the "ISP or UART" conclusion above is no longer true, and because the
> `root` web password was never needed: `excitel` was uid 0 all along, only its shell was
> restricted. Details and the credential locations: `docs/onu-reference.md` and
> `tr069.md`. Credentials stay in gitignored `captures/`, not here.

## Technical findings

### Web UI / firmware

| Item | Result |
|---|---|
| Server | `boa` (Realtek SDK lineage) |
| Root path | `302 → /admin/login.asp` |
| Login endpoint | `POST /boaform/admin/formLogin` |
| Form fields | `username`, `psd`, `sec_lang`, `loginSelinit`, `ismobile`, `csrftoken` |
| CSRF | required; two `csrftoken` inputs emitted per page (one stale) |
| Captcha | code present but `verificationenable = "0"` — disabled |
| Mobile UI | `/mobile/login_mobile.asp`, same auth |
| Session cookie | none issued before authentication |
| TLS (443) | stock OpenSSL self-signed default cert (`O=Default Company Ltd`, `CN=test.org`, issued 2024-04-28) |
| ODM traces | `Added by peichao for mission#0007440`; multilingual template (en/cn/pt/es) |

Important: posting to `/admin/login.asp` instead of `/boaform/admin/formLogin`
returns 404 and silently discards the attempt. Any scripted login against the
wrong endpoint produces a failure indistinguishable from "wrong password".

### Account status (enumerated via the UI's own error messages)

The login endpoint distinguishes unknown usernames from bad passwords, which
allows enumeration without guessing passwords.

| Username | Response | Meaning |
|---|---|---|
| `admin` | `ERROR:invalid username!` | **no such account** |
| `cusadmin`, `support`, `ubnt` | `ERROR:invalid username!` | no such account |
| `user` | `Forbid user login, please log in with administrator account!` | account exists, **login policy-disabled by ISP** |
| `root` | `ERROR:bad password!` | **valid administrator account** |
| `excitel` | `ERROR:bad password!` | account exists (default ISP credentials do not work) |

Behaviour notes:
- After 3 failures the UI returns: `You have entered wrong username or password
  thrice, Please wait for 1 min before reloging !` — a 3-strike / 1-minute
  cooldown. Attempts during cooldown are not evaluated.
- Every prior attempt used username `admin`, which does not exist, so the
  password was never checked. This is why the credentials "failed".

`"Forbid user login, please log in with administrator account!"` is a known,
widespread message on Indian ISP ONTs (Syrotech, Netlink, Sharp Vision, BSNL) —
it indicates an intentional tier restriction, not a password problem.

### Password testing against `root`

Documented vendor/ISP defaults tried, all rejected:

`admin`, `admin123`, `adminisp`, `admin@123`, `exc@123`, `exc@2024`, `excitel`,
`root`, `ubiqcom`, `useradmin`, `Password`, `stdONU101`, `Syro@43210`, `Fib@123456`

(The label password, if different, should also be tried once as `root` — see
`try1.sh`.)

### Network exposure (nmap, full TCP range)

Open: `53` (dnsmasq 2.80), `80`, `443`, `7547` (gSOAP 2.7 CWMP), `52881`
(Realtek miniigd UPnP).

Port states with reasons:

| Port | State | Reason |
|---|---|---|
| 22 (ssh) | filtered | no-response |
| 23 (telnet) | filtered | no-response |
| 2323, 8023, 8080, 8443 | closed | reset |

Filtered = firewall drops packets on **IPv4** only. The same ports over **IPv6
link-local** behave very differently:

| Port (v6) | State |
|---|---|
| 22 (ssh) | **open — syn-ack** |
| 23 (telnet) | filtered |
| 80, 443 | open |

The ONU answers on `fe80::f6bd:b9ff:feaa:bb89` (EUI-64 of `F4:BD:B9:AA:BB:89`).
**The LAN ACL hiding port 22 is IPv4-only; the IPv6 stack bypasses it.** This is
an access-control gap in the firmware, and it makes the device shell reachable
without any web-UI credentials. This supersedes the earlier "console is
mgmt-side only" conclusion.

UPnP: SSDP silent on the ONU itself; `miniigd` on 52881 answers with
`401 Invalid Action` for all unauthenticated SOAP control requests, and its
description files 404.

CWMP: raw `GetParameterValues` to 7547 is reset — the daemon requires a valid
TR-069 session with the ACS credentials.

### Config extraction attempts

| Endpoint | Result |
|---|---|
| `/backupsettings.conf` | 404 (belongs to a different Realtek lineage) |
| `/admin/backupsettings.conf`, `/admin/backup.cfg`, `/admin/config.bin`, `/admin/nvram.dat`, `/admin/setup.cgi`, `/admin/export.cgi`, `/admin/saveconf.cgi` | no unauthenticated access |
| `/admin/*.asp` enumeration | everything outside the login page ≥ 302/404 |

### Topology / disambiguation

`192.168.0.1` is a secondary router owned by the user, operated as an extender
behind the ONU. Its SSDP banner (`MiniUPnPd/2.3.3`, IGDv2, `WANPPPConnection:1`)
is not the ONU and is not the ISP's equipment — no PPPoE credentials of interest
there.

Scanned again from a host attached **directly** to the ONU's LAN (nmap reports
`arp-response`, MAC `F4:BD:B9:AA:BB:89`, Ubiqcom India Pvt): ports 22 and 23
remain `filtered / no-response`. Ports 22 and 23 are `filtered` on IPv4 from every attachment point — the ACL is
interface- and **address-family**-based, not subnet-based. However the ACL does
not cover IPv6: the ONU's link-local address answers `syn-ack` on 22. See the
port table above.

## Exhausted

- password defaults against the real admin account
- username-based fallback accounts (`admin` does not exist)
- config backup / nvram endpoints
- UPNP control on 52881
- CWMP on 7547
- telnet/ssh from the LAN (firewalled to the mgmt interface)

## Remaining options

1. **SSH over IPv6 link-local** (see below) — the live lead. The daemon is
   reachable from any host on the ONU's LAN segment with a link-local address.
   A successful shell yields the stored configuration: web `root` password and
   PPPoE credentials. Try the label password first.
2. **ISP request** (see below) — root password, bridge mode + PPPoE credentials,
   or LAN management enabled.
3. **UART / serial console** — open the case, 4-pin header at 3.3V, 115200 8N1.
   Realtek ONUs of this class typically drop to a root shell without a password;
   the stored config then yields both the PPPoE credentials and the web
   `root` password. Non-destructive if done carefully; voids warranty.
4. **Factory reset** — last resort. Restores a vendor default for `root` (value
   unknown for this ODM), wipes the PPPoE configuration, and the device is
   likely re-provisioned/re-locked by the OLT/ACS anyway. Do not reset without
   the PPPoE credentials in writing.
5. **Replace the ONU** — clone the GPON serial from the label, configure PPPoE
   with credentials from (1) or (2). Permanent fix if the ISP stonewalls.

### IPv6 SSH access

Observed banner: `SSH-2.0-dropbear_2024.86` — a **current** dropbear build, offering
curve25519-sha256, ecdh-sha2-nistp256/384/521, diffie-hellman-group14-sha256,
chacha20-poly1305/aes-ctr, rsa-sha2-256. The firmware is therefore recent
(2024 or later), consistent with the 2024-04 self-signed TLS certificate. Modern
OpenSSH needs **no** legacy algorithm overrides. A 2024 dropbear also means this
is not an unfixed ancient userspace — do not assume old CVE applicability.
Host key: RSA-2048, `AAAAB3NzaC1yc2EAAAADAQABAAABAQCH9AxJeCf7hm4PZDtXKLm+h+QbtB1fQsmVeCYX1wy1A2J7CVBN6Osy3b8dwL6T753dIghXvKhrRiQe+zabdSUb9ZaGqLCisry+LaKIXmQgG7koi+JvXRUClSKaZc39M3K0L5e//qpkT+0SqOhrkQAIKeKqybIVnsdlrbU+4wAdnxNhjwSKkYPxu878iJfj46To/rGlWGdDNxoU2+0Vu6Jekoe4qJy8I5r8TE5yrpFpCQH++4nig8sjxXQM8IaTv2HM1EwLA0JljpfySdUBFB3VftvYb3LpUKdQn7Dj/FfmodbzujXtwIbFgCpRKZ88FShYrHDdsQB4nOIgZX1ugPpr`
(subject to change on firmware update — a change is worth noticing).

Target: `ssh root@fe80::f6bd:b9ff:feaa:bb89%en0` (zone id required for
link-local). Old dropbear/OpenSSH builds require legacy algorithms:

```
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 \
    -o MACs=+hmac-sha1 -o PreferredAuthentications=password,keyboard-interactive \
    root@fe80::f6bd:b9ff:feaa:bb89%en0
```

On success, extract from the device rather than guessing:

```
id; uname -a; ps
ls /proc/nvram /etc /var/tmp 2>/dev/null
cat /proc/nvram/* 2>/dev/null | strings | grep -iE 'user|pass|ppp|tr069|acs'
```

Keep attempts few — an embedded sshd may log or rate-limit, and the ONU's
3-strike habit applies to its web UI, so assume the shell has similar guards.

## Component vulnerabilities (CVE exposure)

Versions fingerprinted on the device: dropbear 2024.86, boa + Realtek
miniigd, dnsmasq 2.80, gSOAP 2.7.

### dropbear 2024.86 (released 2024-10-22)

| CVE | Severity | What it is | Reachable? |
|---|---|---|---|
| CVE-2025-47203 | low (CWE-78) | `dbclient` hostname arg reaches a shell | **client-side only** — not the ONU's sshd |
| CVE-2025-14282 | low (CWE-269) | unix socket forwarding performed as root before privilege drop; affects 2024.84–2025.88 | **post-auth, local** — needs a session already |
| CVE-2026-3706 | disputed | `unpackneg` range check in curve25519.c → signature verification; NVD marks it **DISPUTED**, Debian "unimportant" | remote but very high complexity |

Not vulnerable: **CVE-2023-48795 (Terrapin)** — mitigated since 2024.84, and the
captured KEX list advertises `kex-strict-s-v00@openssh.com`, which is the
Terrapin countermeasure.

**Conclusion: dropbear is not an entry vector.** No pre-auth issue; everything
listed is post-auth or client-side.

### The real exposure

| Component | CVE | Type | Notes |
|---|---|---|---|
| Realtek **miniigd** (port 52881) | CVE-2014-8361 | **unauth RCE**, CVSS 9.8, via crafted `NewInternalClient` in AddPortMapping | NVD: *"as exploited in the wild through 2023"*; FortiGuard reports 10k+ IPS detections/month feeding Hinata/RedGo/Goober/Mirai bots |
| Realtek SDK `wscd`/`mini_upnpd` | CVE-2021-35392 | unauth heap overflow parsing M-SEARCH `ST` header | successor to miniigd |
| Realtek SDK `mini_upnpd` | CVE-2021-35393 | unauth stack overflow (UPnP) | |
| Realtek SDK `MP Daemon`/UDPServer | CVE-2021-35394 | unauth memory corruption + **arbitrary command injection** | |
| Realtek SDK HTTP mgmt (**boa**) | CVE-2021-35395 | **pre-auth** stack overflows + command injection (formWsc, formRebootCheck) | the ONU's web server is boa |
| **dnsmasq 2.80** (port 53) | CVE-2020-25681/82/83/87 | DNSSEC memory corruption (DNSpooq) | fixed in 2.83; needs DNSSEC enabled |
| **dnsmasq 2.80** | CVE-2020-25684/85/86 | cache poisoning via weak TXID/source-port handling | fixed in 2.83 |
| **dnsmasq 2.80** | CVE-2021-3448 | fixed in 2.86 | |
| **gSOAP 2.7** (port 7547) | CVE-2019-7659, CVE-2024-4227 | DoS via crafted XML / duplicate ID attributes (7.5) | 2.7 predates every fix here |

Caveats: the CVE-2021-3539x set is scoped to the Realtek AP-router "Jungle SDK"
(rtl819x v3.2–v3.4T); this is a GPON HGU on a different Realtek SDK, so exact
exposure is unconfirmed — but `miniigd` on 52881 is the same component family as
CVE-2014-8361, which is generic to Realtek SDK.

**None of these is a route to admin access.** They are DoS/poisoning, post-auth,
or unauth-RCE that must not be used (IT Act §66; ISP-owned CPE; bricks easily).
Their value is as **ammunition for the ticket and for a security disclosure**:
the device ships components with known, actively-exploited flaws and Excitel is
the only party who can patch it.

## Proven: the ISP can write this device's configuration remotely

Live Wi-Fi SSIDs are `Excitel_abcd` and `Excitel_abdc`. The factory label says
`FTTH` and `FTTH-5G`, and the two live names differ from each other by a
transposition — hand-typed. The subscriber made that change **through the
Excitel app**, i.e. Excitel cloud → ACS → TR-069 `SetParameterValues`.

This is the strongest fact in the document. The ACS demonstrably holds write
access to this CPE's configuration. Setting the web-UI administrator password
(`InternetGatewayDevice.UserInterface.1.Password` or the UBIQCOM vendor
equivalent) is the same class of operation as setting a WLAN SSID — a
provisioning action already performed on this device, not a credential
disclosure.

It also raises, without guaranteeing, the odds that a factory reset would be
re-provisioned rather than left bare: provisioning is clearly centralised
rather than hand-configured by the installer.

## Request to Excitel

> ONT UBIQCOM UB5021 GVW-D (serial: <from label>). The web UI at 192.168.1.1
> returns "Forbid user login, please log in with administrator account!" for the
> `user` account printed on the label, and the only administrator account on the
> firmware is `root`, whose password was provisioned by Excitel. Ports 22 and 23
> are firewalled on the LAN side. Please either (a) provide the `root` password,
> (b) enable bridge mode and provide my PPPoE username/password, or (c) enable
> LAN-side management access so I can configure the device.
>
> Note: I changed my Wi-Fi SSIDs to Excitel_abcd / Excitel_abdc through the
> Excitel app, so the ACS clearly writes configuration to this ONU. Please use
> the same channel to set the web admin password to a value you tell me.

Escalation ladder: front-line support → **nodal officer** → **appellate
authority** → pgportal.gov.in.

### Security disclosure (separate, shorter — this one gets routed to engineers)

> The UB5021 GVW-D supplied by Excitel fingerprints as: Realtek `miniigd` UPnP on
tcp/52881 (CVE-2014-8361, unauthenticated RCE, per NVD exploited in the wild
through 2023), a `boa` web server (CVE-2021-35395 family), dnsmasq 2.80
(DNSpooq, CVE-2020-25681–25687), gSOAP 2.7 on tcp/7547, and dropbear 2024.86 with
password auth enabled on IPv6 link-local (CVE-2025-14282). Ports 22/23 are
firewalled on IPv4 but reachable over IPv6, so the IPv4 ACL is not effective.
Please advise which firmware fixes these and whether the IPv6 ACL gap is
scheduled.

Informational, no exploitation performed — network-visible version strings only.

## Unrelated

`emudhra.we-have-a-problem.com` is a public disclosure site about the October 2026
compromise of eight eMudhra intermediate CA private keys. It has no bearing on
router access. Indirect relevance only: because those keys are public, a
padlock on the ONU's HTTPS UI currently proves nothing about who is answering.

## Artifacts

none of these are in git, they're from my local working copy:

- `recon/recon.sh`, `recon2.sh` … `recon5.sh`, `try1.sh`
- `captures/capture/` … `captures/capture5/` — raw HTTP responses per probe
- `../third-party/excitel/ssdp-out.txt` — SSDP survey
- `app/apk/myexcitel-3.41.0-base.apk` — Excitel app 3.41.0 pulled from the phone, analysed in the
  `excitel-app` repo's `APP-API.md`

## See also: `app/APP-API.md`

Static analysis of the Excitel app answers the question this file raised and could not close: the app writes
this ONU through `POST https://<selfcare>/provision/setWlanInfo` (fields `subscriberId, idx, ssid, key,
broadCastSsid, radioType, enable, mode, security, type, skipKey, vendor`) and polls
`provision/netSense/checkTaskStatus`. Auth is a session cookie named `selfcare`, no bearer token, no CSRF
token, `subscriberId` in the body. There is **no** endpoint for the web-UI admin password, reboot, port
forwarding, UPnP or TR-069 — the provision namespace is WLAN-only. `accesses.canDoOnuRemoteManagement` is a
per-account server flag that gates the whole Wi-Fi screen.

