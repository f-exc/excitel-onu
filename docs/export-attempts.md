# Config-export attempts on UB5021GVWD (V2.1.08-260703-UBLL)

Goal: pull the vendor config XML, the only place the masked `pppServiceName` (and the
web-UI password hash) would be readable. All requests below are read-only in intent;
nothing was written, uploaded, restored or rebooted.

## 1. `/cgi-bin/export.cgi` — exists, but is a stub

Always the firmware's generic error page:

```
HTTP/1.0 500 Server Error
<H1>500 Server Error</H1>
System will return to the home page in 5 seconds.
```

Shapes tried (all 500, 594 B, `text/html`):

| shape | source of idea |
|---|---|
| `GET /cgi-bin/export.cgi` | baseline |
| `GET ?sExportMode=bin` | PACE V5471 unlock (`tripleoxygen`) |
| `GET ?sExportMode=text` | Arcadyan ARV7510PW |
| `GET ?Save=%3E+Back+up+your+parameterss&sExportMode=text&iExpert=3&sSuccessPage=backup.htm&sErrorPage=backup.htm` + `Referer: /admin/backup.htm` | Arcadyan ARV7510PW exploit |
| `POST` with `sExportMode=bin` | PACE |
| `GET ?type=config` | generic PIB/PDU style |
| Basic auth `-u excitel:***` on all of the above | PACE uses HTTP Basic |

Conclusion: the route is compiled in and the CGI runs, but its export branch is
unimplemented in this vendor build. Not exploitable, no payload variance helps.

## 2. `/boaform/formSaveConfig` — the *real* Realtek backup CGI, but it aborts

This is the one that works on GCOM EPON 1GE (Realtek SDK/Boa, same `ScriptAlias /boaform/ /web`
layout) and on the TOTOLINK class of devices (CVE-2019-19822 family): a plain GET returns the
entire config as XML.

Observed here: the path resolves (a nonexistent CGI gives `404`, this gives an **empty reply** —
server accepts the request, sends zero bytes, closes), i.e. the handler exists but dies.

| attempt | result |
|---|---|
| `GET /boaform/formSaveConfig` | 000, empty reply |
| `GET /boaform/admin/formSaveConfig` | 000 |
| + `Referer: /mgm_mnt_mnt.asp` | 000 |
| + `?submit-url=/mgm_mnt_mnt.asp` | 000 |
| `POST` `submit-url` + `csrftoken` | 000 |
| `POST` empty, `Content-Length: 0` | 000 |
| HTTP/1.0 and HTTP/1.1 keep-alive | 000 |
| authenticated session (verified: protected page 200) | 000 |
| `GET /formSaveConfig` (outside ScriptAlias) | 404 |

Note: an earlier classification pass ran with a **stale cookie jar**, so some of those 000s
were unauthenticated probes. Re-run after a fresh login: identical 000. Conclusion holds.

No page or JS in the entire 155-page dump references `saveconfig`, `export.cgi` or `backup`
(the only "backup" hits are VoIP `backupreg_*` fields) — the vendor removed the UI and, apparently,
disabled the handler.

## 3. Enumeration via the 404-vs-000 oracle

`404` = CGI absent, `000` = CGI present but crashing, `200/302` = live. Probed 26 names under
`/boaform/` and `/boaform/admin/`:

- present-but-dying: `formSaveConfig` (both aliases)
- live: `formLogin`, `formUpload`, `formWlanRedirect`, `formWanRedirect`
- absent: `formConfigSave`, `formCfgSave`, `formCfgBackup`, `formBackupCfg`, `formGetCfg`,
  `formGetConfig`, `formExportCfg`, `formExport`, `formDumpCfg`, `formDump`, `formXML`,
  `formSaveXML`, `formBackup`, `formRestore`, `formUploadCfg`, `formImportCfg`,
  `formLoadConfig`, `formReadConfig`, `formDownloadCfg`, `formRebootCheck`, `formDhcpLease`

`formUpload` (the restore side) responds `302`, so it is wired up — but uploading a config is a
write operation and was deliberately not attempted.

## 4. Ports

```
open: 53, 80, 443, 7547
closed: 21, 22, 23, 1900, 5060, 8080, 8443
```

No telnet/SSH console to read a `show config` from.

## 5. TR-069 CWMP on 7547 (gSOAP/2.7)

`GET /` returns a SOAP fault envelope (`Server: gSOAP/2.7`, `urn:dslforum-org:cwmp-1-0`), so a
CWMP server answers unauthenticated requests. A `GetParameterValues` for
`InternetGatewayDevice.DeviceInfo.SoftwareVersion` **hangs** (20 s timeout, 0 bytes) — the CPE
treats the POST as an ACS session and waits for session semantics/digest it never gets.

Stopped after one attempt: repeated or malformed CWMP traffic can wedge the ISP's management
channel on this box. Device verified healthy afterwards — web UI 200, `inform success`,
WAN `up`.

## Bottom line

The config XML is not reachable from the LAN on this firmware: the generic route is a stub and
the Realtek route crashes. `pppServiceName` therefore stays unknown — plan on blank, then
`excitel_sys`.

> **Corrected 2026-11-18.** `pppServiceName` is `excitel`, not `excitel_sys`, and the config
> was readable after all — just not over HTTP. Once the ONU's FTP account was used (it runs
> as root, unchrooted), `/var/config/lastgood.xml` came down as 178 KB of plaintext MIB with
> `pppUser`, `pppPasswd` and `pppServiceName` in it. The `excitel_sys` guess came from
> section 6 below, which reads a *sibling* firmware's web template; it was never this
> unit's value. See `docs/onu-reference.md`.

Remaining route if it ever matters: fetch the UB5021GVWD firmware (ubiqcom.in) and inspect
`/web/formSaveConfig` for the QUERY_STRING/env it expects, or attach to the UART.

## 6. Firmware analysis — why `formSaveConfig` returns an empty reply

Obtained the sibling package `SYRO-2010_all_V2.1.08-260731_GoipBsnlver` (same HW rev V4.2E,
same V2.1.08 build tag). Structure: `rootfs` + `custconf` (both SquashFS 4.0/xz), `uImage`
(MIPS32rel2 kernel), `hw_ver`, `fwu.sh`, `md5.txt`.

`rootfs/home/httpd/boa.conf` confirms our URL layout:

```
AddType application/x-httpd-cgi asp
ScriptAlias /boaform/      /web
ScriptAlias /boaform/admin /web/admin
Auth /boaform/admin /var/boaUser.passwd
```

`formSaveConfig` is **not a file in /web** — it is a handler compiled into `bin/boa`
(ELF 32-bit MSB MIPS, uClibc). Its strings spell out the whole flow:

```
saveconfigfile
cp -f /var/config/lastgood.xml /tmp/tempconfigfile.xml
/var/config/lastgood.xml
Config File  not exists!
Content-Disposition: attachment;filename="lastgood.xml"
/etc/scripts/config_xmlconfig.sh -lc /tmp/tempconfigfile.xml
```

i.e. copy the running config to `/tmp/tempconfigfile.xml` and serve it as `lastgood.xml`.

And immediately before that block sits the gate:

```
optiLinkexcitel
Goipexcitel
Dbcexcitel
Technxtexcitel
Config File  not  allow download!
```

supported by these symbols in the same binary: `read_custname`, `custname_strstr`,
`file_permission_check`, `file_permission_check_custom`, `upload_permission_check`.

**Conclusion:** config download is whitelisted by ODM+customer code. Only builds whose
`custname` contains `optiLinkexcitel`, `Goipexcitel`, `Dbcexcitel` or `Technxtexcitel` may
download. This ONT is a **Ubiqcom** unit, so it fails the `custname_strstr` test, prints
"Config File not allow download!" and exits without writing a response — which is exactly the
0-byte "empty reply" observed. It is a deliberate policy refusal, **not** a crash and **not**
reachable by any request shape. (Note the shipped package here is `GoipBsnlver`, which also
fails the test — the check is per-ODM *and* per-customer.)

Side effect worth recording: this package's `custconf/home/httpd/web/net_eth_links.asp` is the
same page as ours with `pppServiceName.value = ""` for BSNL, while **our device's** copy of that
page ships `excitel_sys` as the new-connection default — confirming `pppServiceName` is an
ISP-specific template value, and that Excitel's template uses `excitel_sys`.

> **Corrected 2026-11-18:** the live MIB says `pppServiceName = excitel`. The `excitel_sys`
> value is what this *sibling* package's page carries, not what provisioning stored on our
> unit; the mistake was reading a template default as a config value. The rest of the
> section stands — the `custname` gate is real, `custname` here is
> `UbicomexcitelXPSETver`, and `boa` matches none of the four whitelisted strings.

Also present: `xml_config_encrypt` (exports may be encrypted anyway), and `VSOL`-looking
obfuscated blobs in `custconf/.sys_capability_file` and `.tmplockfile`.

**So: stop here.** The only remaining route to `lastgood.xml` is a shell on the box (UART) or
changing `custname`, neither of which is a network-only path.

## 7. Bridge mode — cannot be set over HTTP on this build

Goal: move the Internet WAN to bridge on Port_1 so the ONT becomes a dumb modem.

### What the firmware will and won't do

| attempt (WAN #0, the Internet profile) | result |
|---|---|
| save with **identical** values (no-op) | `301` redirect |
| `cmode` 2→0 only, binding/apptype untouched | `200` **"Parameters error."** |
| `cmode=0` + `apptype=1` (INTERNET) | "Parameters error." |
| `cmode=0` + `apptype=3` (IP_Bridge) | "Parameters error." |
| `cmode=0` + `itfGroup=1` (Port_1) | "Parameters error." |
| `cmode=0` + `ipmode=0` (what the UI sends for a bridge) | "Parameters error." |
| `ipmode` omitted entirely | "Parameters error." |
| **MTU 1492→1400, nothing else** | "Parameters error." |

Same on the other profiles:

| attempt | result |
|---|---|
| WAN #1 (IP_TV) enable + bind Port_1 | `Parameters error.` / **"WAN1 is fixed."**, **"WAN1 service type is fixed."** |

So it is not the payload shape: **any actual change to a WAN profile is refused**, while an
unchanged re-save is redirected silently. The WAN configuration on this unit is read-only to
the web UI regardless of privilege:

`mgm_usr_user.asp` -> `normalUser = 'user'`, `superUser = 'excitel'` — the account we use **is**
the super user, so this is not a privilege problem.

This matches the lock flags served by the page itself: `admin_configurable = 0`,
`cwmp_configurable = 1` — the ACS owns the profile; the GUI only displays it.

### Guard strings in `bin/boa` (SYRO build of the same firmware)

```
acnameflag
wanpsd / wanpsd_flag == 1 / Wrong WAN PSD.
WAN1 is fixed.
The mibentry.itfgroup is 0x%x, The Entry's itfgroup is 0x%x, the apptype is %d
Parameters error.
is_skylink_fixed_wan1
```

### Not the cause (ruled out)

- **Sandbox/network**: `curl`/`nc` from the agent are denied by the sandbox (`network-outbound`);
  Python has the grant. Early "device is dead" readings were sandbox denials, not the ONT.
- **Wedged `boa`**: after one accepted apply the UI stopped answering and the WiFi dropped for a
  few minutes, but the ONT redialled by itself; PPPoE uptime and status confirmed full recovery
  with the profile unchanged. Port_2 is reachable and serves the UI normally.
- **Port_2 being dead**: it is not — `arp` resolves `192.168.1.1` to the ONT's PON MAC
  `f4:bd:b9:aa:bb:89` and the login page returns `200` over it.

### Conclusion

Bridging this UB5021GVWD via HTTP is not possible. Remaining routes:

1. **Replace the ONU** (VSOL V2802RH, clone MAC/OUI — see `.creds`) and dial PPPoE from the
   router. This is the only clean path and removes TR-069/OMCI management too.
2. **Double NAT** behind the ONT, accepting it as the edge device.
3. ACS/OMCI driven change — only Excitel can do it.

Rollback snapshot of the (unchanged) WAN #0 object is in my working copy, not in git.

## 8. Why "Parameters error." happened — wrong field set (corrected)

`formEthernet` rejects the whole request with `Parameters error.` (HTTP 200) if it
receives **any parameter it does not know**. A real Firefox POST (HAR capture) proves
the accepted set is exactly 46 fields, in this order:

```
lkname, lkmode, IpProtocolType, ipmode, PPPoEProxyMaxUser, napt, mtu, pppUsername,
pppPassword, pppServiceName, pppCtype, ipAddr, netMask, remoteIpAddr, dnsMode, v4dns1,
v4dns2, dgw, applicationtype, chkpt x9, AddrMode, dslite_aftr_mode,
dslite_aftr_hostname, Ipv6Addr, Ipv6PrefixLen, Ipv6Gateway, dnsv6Mode, Ipv6Dns1,
Ipv6Dns2, iana, cmode, ipDhcp, itfGroup, encodePppUserName, encodePppPassword,
oldPppServiceName, lst, action, submit-url, acnameflag, csrftoken
```

Everything the `new it(...)` object exposes beyond that list (`itfenable`, `bandctl_en`,
`bandctl_us`, `bandctl_ds`, `staticIpv6`, `slacc`, `DSLiteRemoteIP`, `mVid`, `napt_v6`,
`pppAuth`, `pppACName`, `enableIgmp`, `dnsv6Mode`…) must **not** be sent. The earlier
tool sent those and therefore failed on every attempt, including a harmless MTU change.

Also learned: an accepted POST answers `301 -> /net_eth_links.asp`; a rejected one answers
`200` with the text `Parameters error.`

### Consequence — a real incident, and the fix

One rejected POST still committed `napt=0` before failing, which silently disabled NAT and
left every client without internet while the ONT itself could still ping out. Re-enabling it
through the browser worked (`napt` back to 1, `301`), proving writes are *not* locked in
general — only malformed requests are. Lesson: read back `napt` (and `strStatus`) after any
POST, don't trust the status code.

`bridge_port1.py` now emits exactly the 46-field browser set, nothing more.

## 9. Bridge retried with the exact browser field set — refused anyway

With the corrected 49-field payload (verified byte-identical in names, order and value
conventions to the captured Firefox POST), the result is decisive:

| attempt | payload | result |
|---|---|---|
| WAN0 → bridge, `applicationtype=1` (INTERNET), `itfGroup=1` | 49 fields, browser set | `200 "Parameters error."` |
| WAN0 → bridge, `applicationtype=3` (IP_Bridge), `itfGroup=1` | 49 fields, browser set | `200 "Parameters error."` |

State after both attempts, unchanged and healthy:

```
cmode=2  applicationtype=0  itfGroup=0  itfenable=1  napt=1   WAN state: up
```

So the earlier failure was **two separate things**: my malformed requests (now fixed and
proven, since an identically-shaped POST successfully re-enabled `napt`), and a real
server-side refusal of the mode change itself. The ISP lock is genuine, not a payload bug.

Note this run caused no collateral damage — `napt` stayed 1 and the WAN stayed up, because
the request is rejected before the commit step.

Final answer on bridging this UB5021GVWD over HTTP: **not possible.** Options remain
ONU replacement (VSOL V2802RH), double NAT behind the ONT, or an ACS-side change by the ISP.
