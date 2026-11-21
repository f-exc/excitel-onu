# Web UI: boa, the login model, and what answers before auth

UBIQCOM UB5021 GVW-D, `V2.1.08-260703-UBLL`. The web UI is the only interface this box ships
enabled, so it's the one thing you can look at without getting a shell first. It runs as root and
its login is keyed on your source IP, which turned out to be the interesting part.

## The binary

| | |
|---|---|
| version string | `Boa/0.93.15`, a Realtek fork |
| arch / libc | MIPS big-endian, uClibc, 1.57 MB |
| md5 | `e591df11e8a78e6cbf60e83d87187d9c` |
| matches the live box | yes, byte-identical in the live rootfs and in the dumped image |

No `Server:` header goes out, so the version isn't fingerprintable from the outside.

## It runs as root

`rootfs/home/httpd/boa.conf` has `User 0` and `Group 0`. Nothing drops privileges, so a request
that gets past the login is already uid 0.

## The login is keyed on your IP, not a cookie

Auth happens at dispatch. Every `/boaform/*` gives `302 /admin/login.asp` when you're not logged
in, including paths that don't exist.

There's no session cookie at all. The login state is a list keyed on the source address,
`search_login_list` / `free_from_login_list_by_ip_addr` / `REMOTE_ADDR`. A bogus `sessionid`
cookie is ignored and you get the same 302 back.

So everything behind one NAT shares a single login. `WEB_MULTI_CONCURRENT_LOGIN=0`, and
`formLogin` takes 3 tries a minute.

## What answers before auth

All of these return 200 with no login:

| endpoint |
|---|
| `formLogin` |
| `formLogPassCheck` |
| `formLoginMultilang` |
| `formUserReg` |
| `formUpgradeRedirect` |
| `form_loid_burning` |

`form_loid_burning` is the one worth looking at. It runs unauthenticated and answers GET, so any
page a browser on the LAN loads can fire it cross-origin and rewrite the ONU's PON registration. I
didn't test it with parameters.

For reference, CVE-2021-35395 doesn't apply here as published. `formSysCmd`, `formRebootCheck` and
`formStaticDHCP` aren't in this binary at all. `formWsc`, `formWlanMultipleAP` and
`formWlSiteSurvey` are in it, but they sit behind the auth redirect.
