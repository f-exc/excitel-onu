# `/bin/cli` reversed — the hidden shell command

`/bin/cli` was pulled off the box over FTP (root, unchrooted) as `captures/ftp-cli`:
115 KB, `ELF 32-bit MSB MIPS32 rel2`, uClibc, **no section headers**, but the dynamic
symbol table survived, so every function it exports still has a name.

Tooling: `tools/cli-disasm.py` (uv inline dep on `capstone`). Apple's `llvm-objdump` has no
MIPS target. The script resolves uClibc PIC `lw t9, off(gp)` GOT slots to real import
names, and `lui`/`addiu` pairs to strings and functions, using the MIPS dynamic tags
(`DT_PLTGOT=0x42bd70`, `LOCAL_GOTNO=0x6c`, `GOTSYM=0x72`, `_gp = GOT+0x7ff0`).

```
uv run tools/cli-disasm.py captures/ftp-cli 0x408110 0x408340
```

## The command table

32-byte records at `0x429cb0`: `{name, flags, min_args, children, ?, handler, ?, help}`.

| name | flags | handler | help |
|---|---|---|---|
| config | 0 | — (subtree) | Configure system |
| debug | 2 | — (subtree) | Debug system |
| exit | 1 | `0x403910` | Exit command line interface |
| help | 1 | `0x4039a0` | Help information |
| reboot | 1 | `0x403f80` | Reboot system |
| **enterlinuxshell** | **7** | **`0x408110`** | **Enter linux shell** |
| show | 0 | — (subtree) | Show system information |

`help` filters the listing, which is why `enterlinuxshell` never appeared in
`captures/onu-cli-map.log` — that transcript has exactly six entries.

## What `0x408110` does

```c
memset(enc, 0, 60);  mib_get(438, enc);        // secret, stored encoded
flag = 0;            mib_get(437, &flag);      // 1-byte gate
dec = vs_malloc_decode(enc);                   // libvsEncDec
snprintf(pw, 128, "%s", dec);  free(dec);

if (login_state >= 2) { puts("\nNot Authorized!"); return; }
if (flag != 1) { va_cmd("/bin/sh", 0, 1); return; }   // no password asked
for (int i = 4; i; --i) {
    printf("ShellPassword: ");
    in = getpass("");
    if (!strcmp(in, pw))     { va_cmd("/bin/sh", 0, 1); return; }
    if (!strcmp(in, "exit"))   exit(0);
    puts("Error,try again!"); sleep(1);
}
exit(0);
```

- The shell is `va_cmd("/bin/sh", NULL, 1)` — exec, not fork, as whatever uid `cli` has,
  which is 0.
- The password is **not** plaintext in the MIB: it is MIB key 438, passed through
  `vs_malloc_decode` (same family as the `vsEncrypt` config blob), then copied with
  `"%s"` into a 128-byte buffer.
- `login_state` is a global at `0x42ca88`, set to `2` by `main` when `getpwuid(getuid())`
  returns NULL, `0` otherwise. With a passwd entry it is 0, so the gate is open.
- Four tries, then `exit(0)` — that ends the whole `cli` process, it is not a lockout.
  Typing `exit` at the password prompt also exits cleanly.

So the only thing standing between the CLI and a root shell is MIB key 437 holding
exactly `"1"`. Anything else — `0`, empty, absent — and `enterlinuxshell` drops straight
to `#`.

## Still open

- MIB ids **437** and **438** need names. They are enum values from a generated header, so
  they live in `libmib.so.0` (`/lib/`), not in `cli`. The XML key order does not match:
  index 437 of `config_default.xml` is `NAPT`, of `lastgood.xml` it is
  `DUAL_MGMT_MODE`.
- Whether the passwordless branch is what this firmware actually ships (i.e. what 437
  contains on the box) — test by typing `enterlinuxshell` at the CLI. Runtime only, no
  MIB write, nothing to undo except a reboot.
- `debug` has flags 2 and a subtree pointer at `0x42c1a0` that is in .bss, so it really is
  empty at runtime. Not a lead.

also worth knowing: the CLI account table is not the web account store, so rotating the CLI
account password doesn't touch the web admins. And `cli` is single-instance, a second session gets
`CLI busy !!` and whoever holds it is in `/var/run/cli.pid`.

remoteaccess takes `ftp`, `http`, `ping`, `telnet` and `tftp`. There's no ssh subcommand. Changes
are runtime only until `config save`.
