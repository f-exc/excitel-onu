# Putting the ONU into bridge mode so the JIDU can dial PPPoE

The ONU (UBIQCOM UB5021 GVW-D, `V2.1.08-260703-UBLL`) is the EPON HGU Excitel handed me and it
routes: it runs its own PPPoE session and gives the JIDU AX6000 a DHCP lease on `192.168.1.0/24`.
So the whole house is double NATed behind a box i don't control. The JIDU is the router i actually
want, so the plan is to turn the ONU into a media converter and let the JIDU dial the line.

## The web UI can't do it, the page isn't there

The boa doc root is `/home/httpd/web` and that is a symlink to `/custconf/home/httpd/web`. The WAN
pages in `admin/` (`waneth.asp`, `wanadsl.asp`, `multi_wanptm.asp`) are still in the tree, but they
are symlinks to `/home/httpd/web/waneth.asp` and friends, and those files are not in the image. The
WAN connection page was deleted from this build, it is not hidden in a menu somewhere, so there is
no bridge option to find.

Doesn't matter though. `/var/config/lastgood.xml` is the whole MIB in plaintext on a writable
partition and the FTP account from that same MIB is uid 0 and unchrooted, so the WAN table can be
edited directly and nothing about the web login is needed.

## What bridge mode is in the MIB

Each WAN connection lives in `ATM_VC_TBL` (name left over from the ADSL lineage, three slots on
this box) and `ChannelMode` is the mode. The decode is out of the box's own
`/etc/lua_script/wan_info.lua`:

| ChannelMode | mode |
|---|---|
| 0 | bridge |
| 1 | IPoE, `ChannelAddrType` 0 = static, 1 = DHCP |
| 2 | PPPoE |

`ServiceList` is the service bitmask: 1 TR069, 2 INTERNET, 4 OTHER, 8 VOIP.

How the three slots sit right now:

| idx | MacAddr | nas if | ChannelMode | ServiceList | DefaultGW | ppp user |
|---|---|---|---|---|---|---|
| 0 | `f4bdb9aabb92` | `nas0_0` | 2 (PPPoE) | 3 (TR069+INTERNET) | 1 | `<subscriber-id>`, svc `excitel` |
| 1 | `f4bdb9aabb93` | `nas0_1` | 0 (bridge) | 4 (OTHER) | 0 | none |
| 2 | `f4bdb9aabb94` | `nas0_2` | 1 (IPoE DHCP) | 8 (VOIP) | 0 | none |

Slot 2 of the vendor's own `config_default.xml` is a bridge entry too, same shape, so the factory
already knows how to do this. It's the internet slot that has to change, not the bridge slot, since
slot 0 is the one on the LLID that carries the traffic (it is the one with a live `ppp0`).

Other things that matter and are already fine: `PORT_BINDING_TBL` is all zeros so every LAN port is
plain `br0` and none is nailed to a WAN, `vid`/`vlan`/`mVid` are 0 so nothing is tagged, and the LAN
side is `eth0.2` in `br0`.

Get the credentials off the box first, `/var/ppp/pppoe.conf` is what it actually dials with and is
less ambiguous than reading `pppPasswd` out of the XML:

```sh
curl -s "ftp://$FTP_USER:$FTP_PASSWD@192.168.1.1//var/ppp/pppoe.conf"
```

## Order of operations

Do the JIDU first, the flip last. The ONU's management address is on the LAN side so the change
itself doesn't cost access, but the moment it stops routing there is no internet until the JIDU has
a session.

1. Wired laptop into a spare ONU LAN port, static `192.168.1.50/24`, no gateway. That is the way in
   if the JIDU config goes wrong.
2. JIDU: PPPoE on the device the ONU hangs off (that is `wan`, the same interface the
   `fe80::...%wan` hop uses) plus a static management interface on the same device, so
   `192.168.1.1` stays reachable afterwards:

```sh
uci set network.wan.proto='pppoe'
uci set network.wan.username='<subscriber-id>'
uci set network.wan.password='<from pppoe.conf>'
uci set network.wan.service='excitel'      # drop it if the AC doesn't filter on the name
uci set network.wan.mtu='1492'
uci set network.wan.keepalive='5 3'
uci set network.wan.ipv6='1'
uci set network.wanmgmt='interface'
uci set network.wanmgmt.device='wan'
uci set network.wanmgmt.proto='static'
uci set network.wanmgmt.ipaddr='192.168.1.2'
uci set network.wanmgmt.netmask='255.255.255.0'
uci set network.wanmgmt.defaultroute='0'
uci set network.wanmgmt.metric='200'
uci commit network
/etc/init.d/network reload
```

It will just sit there failing to dial while the ONU still owns the PPPoE session, which is fine.
`wanmgmt` in the `wan` firewall zone keeps it out of the LAN's routing table; forward from `lan` has
to be allowed separately if the ONU should be reachable from clients and not just from the JIDU.

3. ONU: edit `/var/config/lastgood.xml`, `ATM_VC_TBL` index 0, four values only.

```
ChannelMode      2 -> 0
ConPPPInstNum    1 -> 0
ConIPInstNum     0 -> 1
DefaultGW        1 -> 0
```

Leave `MacAddr`, `ifIndex`, `RGWANIndex`, `NAPT` (the factory bridge slot also has 1), `MTU`,
`ChannelAddrType`, `BridgeType`, `ServiceList` alone. The `pppUser`/`pppPasswd`/`pppServiceName`
values go inert once the mode is 0, leaving them makes the revert a one-line change.

Push it, then reboot:

```sh
curl -s -T lastgood.new "ftp://$FTP_USER:$FTP_PASSWD@192.168.1.1//var/tmp/lastgood.new"
# from a root shell on the box (telnet 192.168.1.1 after the /var/passwd shell swap):
/bin/xmlconfig -c /var/tmp/lastgood.new    # exits 0 if the file parses
cp /var/config/lastgood.xml /var/config/lastgood.xml.bak
cp /var/tmp/lastgood.new /var/config/lastgood.xml
reboot
```

The `.bak` is worth the extra step because `config_xmlconfig.sh -b` at boot loads `lastgood.xml`,
and if that fails it falls back to `lastgood.xml.bak` automatically, then to the province config,
then to factory defaults. So a file that doesn't parse rolls itself back instead of wiping the
PPPoE provisioning.

Also, `/etc/scripts/config_xmlconfig.sh -d` is the factory-reset branch despite the letter, don't
reach for it thinking it saves anything. The commit path is `xmlconfig -of /var/config/lastgood.xml`.

4. Verify. On the ONU, `br0` should hold the LAN side and the PON uplink, with `ppp0` gone:

```
brctl show                    # eth0.2 + nas0_0 in br0
ifconfig nas0_0               # up, no inet addr
show wan interface            # connection 1 = bridge, no ppp instance
```

On the JIDU:

```sh
tcpdump -i wan -n -e ether proto 0x8863 or ether proto 0x8864   # PADI/PADO/PADR/PADS
ifstatus wan
```

## If it doesn't come up

- No PADI/PADO at all means the frames aren't crossing the bridge. Check `brctl show` first, and if
  `nas0_0` isn't in `br0` the mode flag alone wasn't enough: `/bin/cli` on this firmware does have
  the `config wan` subtree (`channel`, `add`, `delete`, modes `br2684`/`rt2684`/`pppoe`), poke the
  syntax with `?` and let it build the entry.
- PADI goes out and nothing answers: Excitel may bind the session to the ONU's WAN MAC. Clone
  `f4:bd:b9:aa:bb:92` (slot 0's `MacAddr`, which is `nas0_0`) onto the JIDU's `wan`.
- `PROVINCE_DISABLE_BRIDGE_V4V6_FILTER` is 0, which lets libmib install its bridge IPv4/IPv6
  filter. Setting it to 1 is the knob to try if traffic looks filtered rather than unbridged.
- Try the JIDU on ONU LAN port 1 specifically. The GEM to UNI map is the OLT's business and it
  isn't visible from here.

Also, the ONU is offline on its own once it's bridged, so its NTP, DNS and ACS lookups fail. That's
expected, the clock will drift until the JIDU's session is up.

Two things can silently undo the edit. OMCI from the OLT can push the WAN config back to routed;
`omci_configured` is 0 today so it isn't doing that yet. And TR-069, which is disabled and saved
(`config tr069 disable` + `config save`), can replace the whole MIB with a `Download` FileType 3.
Keep it off. A factory reset also wipes the PPPoE credentials, so have them written down before
starting.
