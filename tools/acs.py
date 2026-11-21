#!/usr/bin/env python3
"""Minimal TR-069 ACS that only ever reads: waits for a CPE Inform, walks the
parameter tree, then re-reads every credential-shaped leaf.

Point the ONU's ACS url at this listener, wait for its Inform, and the tree
lands in `captures/acs-<stamp>.log` (raw XML) and `.json` (parsed values).
Nothing is written to the device: only InformResponse, GetParameterNames,
GetParameterValues and 204 ever leave here. There is no --set on purpose.

    python3 tools/acs.py --bind 0.0.0.0 --port 7547
    python3 tools/acs.py --reset          # forget a previous walk

Progress lives in the state file, so a session the CPE drops resumes on its
next Inform instead of replaying the whole tree.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import threading
import time
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

ROOTS = ["InternetGatewayDevice.", "Device."]
READ_RE = re.compile(r"pass|pwd|secret|user|account|admin|credential", re.I)
SECRET_RE = re.compile(r"pass|pwd|secret", re.I)
STAMP = time.strftime("%Y%m%d-%H%M%S")
LOCK = threading.Lock()
ARGS: argparse.Namespace
STATE: dict
JOURNAL: list[Path] = []
NS = "urn:dslforum-org:cwmp-1-0"


def local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def texts(el: ET.Element, name: str) -> list[str]:
    return [c.text or "" for c in el.iter() if local(c.tag) == name]


def first(el: ET.Element, name: str, default: str = "") -> str:
    return next(iter(texts(el, name)), default)


def envelope(inner: str) -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"'
        ' xmlns:soap-enc="http://schemas.xmlsoap.org/soap/encoding/"'
        ' xmlns:xsd="http://www.w3.org/2001/XMLSchema"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
        f' xmlns:cwmp="{NS}">'
        f"<soap:Header/><soap:Body>{inner}</soap:Body></soap:Envelope>"
    ).encode()


INFORM_RESPONSE = envelope(
    "<cwmp:InformResponse><MaxEnvelopes>1</MaxEnvelopes></cwmp:InformResponse>"
)


def rpc_names(path: str) -> str:
    return f"GetParameterNames {path}"


def rpc_values(names: list[str]) -> str:
    return f"GetParameterValues {len(names)} name(s)"


def build_upload() -> bytes:
    return envelope(
        "<cwmp:Upload>"
        f"<FileType>{escape(ARGS.upload_filetype)}</FileType>"
        f"<URL>{escape(ARGS.upload_url)}</URL>"
        "<Username></Username><Password></Password><DelaySeconds>0</DelaySeconds>"
        "</cwmp:Upload>"
    )


def build(item: dict) -> bytes:
    if item["rpc"] == "names":
        return envelope(
            "<cwmp:GetParameterNames>"
            f"<ParameterPath>{escape(item['path'])}</ParameterPath>"
            "<NextLevel>1</NextLevel></cwmp:GetParameterNames>"
        )
    names = "".join(f"<string>{escape(n)}</string>" for n in item["names"])
    return envelope(
        "<cwmp:GetParameterValues>"
        f'<ParameterNames soap-enc:arrayType="xsd:string[{len(item["names"])}]">'
        f"{names}</ParameterNames></cwmp:GetParameterValues>"
    )


def note(msg: str, raw: bytes | None = None) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with JOURNAL[0].open("ab") as fh:
        fh.write((line + "\n").encode())
        if raw is not None:
            fh.write(raw.rstrip() + b"\n")


def save() -> None:
    JOURNAL[1].write_text(json.dumps(STATE, indent=1))


def mask(name: str, value: str) -> str:
    return "<redacted>" if SECRET_RE.search(name) and not ARGS.show_secrets else value


def enqueue_names(path: str, why: str = "") -> None:
    STATE["queue"].append({"rpc": "names", "path": path})
    note(f"queue {rpc_names(path)} {why}".rstrip())


def next_rpc() -> bytes | None:
    if ARGS.all_values and not STATE.get("all_read"):
        names = sorted(
            k for k, v in STATE["params"].items() if not k.endswith(".") and "value" not in v
        )
        STATE["all_read"] = True
        STATE["reads"] = names + [n for n in STATE["reads"] if n not in set(names)]
        note(f"-- all-values: {len(names)} names queued for reading")

    if (
        ARGS.upload_url
        and STATE.get("done")
        and not STATE.get("upload_done")
        and not STATE.get("upload_sent")
        and STATE.get("upload_tries", 0) < 2
    ):
        STATE["upload_sent"] = True
        STATE["upload_tries"] = STATE.get("upload_tries", 0) + 1
        _awaiting["last"] = "upload"
        note(f">> Upload {ARGS.upload_filetype} -> {ARGS.upload_url}")
        return build_upload()

    if STATE["reads"]:
        fresh = [n for n in STATE["reads"] if "value" not in STATE["params"].get(n, {})]
        STATE["reads"] = fresh
        if fresh:
            names, STATE["reads"] = fresh[: ARGS.batch], fresh[ARGS.batch :]
            STATE["requests"] += 1
            note(">> " + rpc_values(names))
            return build({"rpc": "values", "names": names})

    while STATE["queue"]:
        if STATE["requests"] >= ARGS.max_requests:
            note(f"max-requests {ARGS.max_requests} reached, stopping the walk")
            STATE["queue"].clear()
            STATE["reads"].clear()
            break
        item = STATE["queue"].pop(0)
        STATE["requests"] += 1
        note(">> " + (rpc_names(item["path"]) if item["rpc"] == "names" else rpc_values(item["names"])))
        _awaiting["GetParameterNames"] = item["path"]
        return build(item)

    if STATE["root"] and not STATE["done"]:
        STATE["done"] = True
        note(f"tree complete: {len(STATE['params'])} parameters, {len(STATE['objects'])} objects")
    return None


def start_walk() -> None:
    root = ROOTS[1] if STATE["roots_tried"] else ROOTS[0]
    STATE["root"] = root
    STATE["roots_tried"].append(root)
    enqueue_names(root, "(start of walk)")


def on_inform(root: ET.Element) -> None:
    STATE["informs"] += 1
    events = texts(root, "EventCode")
    note(
        f"<< Inform #{STATE['informs']} from OUI {first(root, 'OUI')}"
        f" class {first(root, 'ProductClass')} sn {first(root, 'SerialNumber')}"
        f" events {events or '-'}",
        ET.tostring(root, encoding="utf-8"),
    )
    if not STATE["root"] and not STATE["queue"]:
        start_walk()


def on_names(root: ET.Element, path: str) -> None:
    infos = []
    for struct in root.iter():
        if local(struct.tag) != "ParameterInfoStruct":
            continue
        name = first(struct, "Name")
        if name:
            infos.append((name, first(struct, "Writable", "0")))

    if not infos:
        note(f"<< GetParameterNamesResponse {path} -> empty")
        if path in ROOTS and len(STATE["roots_tried"]) < len(ROOTS):
            start_walk()
        return

    leaves = 0
    for name, writable in infos:
        STATE["params"].setdefault(name, {})["writable"] = int(writable or 0)
        if name.endswith("."):
            if name in STATE["objects"]:
                continue
            STATE["objects"].append(name)
            if name.count(".") - STATE["root"].count(".") < ARGS.depth:
                enqueue_names(name)
        else:
            leaves += 1
            if READ_RE.search(name) and name not in STATE["reads"] and "value" not in STATE["params"][name]:
                STATE["reads"].append(name)
    note(f"<< GetParameterNamesResponse {path} -> {len(infos)} ({leaves} leaf/leaves)")


def on_values(root: ET.Element) -> None:
    for struct in root.iter():
        if local(struct.tag) != "ParameterValueStruct":
            continue
        name = first(struct, "Name")
        if not name:
            continue
        value = first(struct, "Value")
        entry = STATE["params"].setdefault(name, {})
        entry["value"] = value
        entry["type"] = first(struct, "Type")
        note(f"   = {name} = {mask(name, value)}")


def on_fault(root: ET.Element, path: str) -> None:
    code = first(root, "faultcode") or first(root, "FaultCode")
    string = first(root, "faultstring") or first(root, "FaultString")
    detail = first(root, "SetParameterValuesFault") or ""
    note(f"<< Fault {code} {string} {detail}".rstrip())
    if _awaiting.get("last") == "upload":
        STATE["upload_sent"] = False
        note("-- upload refused, will retry once")
    if code in {"9005", "9003"} and path == STATE["root"] and len(STATE["roots_tried"]) < len(ROOTS):
        STATE["roots_tried"].append("(fault)")
        start_walk()


def parse(raw: bytes) -> tuple[str | None, ET.Element | None]:
    if not raw.strip():
        return None, None
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        note(f"!! unparsable body: {exc}")
        return "Unparsable", None
    body = next((e for e in root.iter() if local(e.tag) == "Body"), None)
    if body is None or not len(body):
        return None, None
    return local(body[0].tag), body[0]


def dispatch(raw: bytes, path: str, host: str = "") -> bytes | None:
    name, msg = parse(raw)
    note(f"<< {host}{path} {name or 'empty body'} ({len(raw)} B)")
    if name == "Inform" and msg is not None:
        on_inform(msg)
        return INFORM_RESPONSE
    if name in {"TransferComplete", "TransferCompleteResponse"}:
        return envelope("<cwmp:TransferCompleteResponse/>")
    if name in {"GetParameterNamesResponse", "GetParameterValuesResponse", "Fault"} and msg is not None:
        asked, _awaiting["GetParameterNames"] = _awaiting.get("GetParameterNames", ""), ""
        if name == "GetParameterNamesResponse":
            on_names(msg, asked)
        elif name == "GetParameterValuesResponse":
            on_values(msg)
        else:
            on_fault(msg, asked)
    return next_rpc()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "acs-readonly"
    sys_version = ""

    def log_message(self, *_args) -> None:
        pass

    def do_GET(self) -> None:
        self.reply(200, b"read-only TR-069 ACS, waiting for an Inform\n", "text/plain; charset=utf-8")

    def do_PUT(self) -> None:
        raw = self.read_body()
        kind = "xml" if raw[:200].lstrip().startswith((b"<?xml", b"<Config")) else "bin"
        out = JOURNAL[0].parent / f"onu-upload-{STAMP}.{kind}"
        out.write_bytes(raw)
        note(f"<< PUT {self.path} {len(raw)} B -> {out} (head {raw[:16].hex()})")
        with LOCK:
            STATE["upload_done"] = True
            save()
        self.reply(200, b"")

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        if ARGS.path and path != ARGS.path:
            note(f"<< {self.headers.get('Host', '')}{path} -> 404, path guard (--path {ARGS.path})")
            self.close_connection = True
            self.reply(404, b"")
            return
        raw = self.read_body()
        with LOCK:
            auth = self.headers.get("Authorization", "")
            if auth:
                scheme, _, payload = auth.partition(" ")
                try:
                    user = base64.b64decode(payload).decode(errors="replace").split(":", 1)[0]
                except Exception:
                    user = "?"
                note(f"<< auth {scheme} user={user} (ignored)")
            payload = dispatch(raw, path, self.headers.get("Host", ""))
            save()
        if payload is None:
            self.close_connection = True
            self.reply(204, b"")
            note("<< 204, session closed")
            return
        self.reply(200, payload)

    def read_body(self) -> bytes:
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            out = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if not size:
                    self.rfile.readline()
                    return out
                out += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def reply(self, code: int, payload: bytes, ctype: str = 'text/xml; charset="utf-8"') -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)


_awaiting: dict[str, str] = {}


def main() -> int:
    global ARGS, STATE, NS, _awaiting
    ap = argparse.ArgumentParser(description="read-only TR-069 ACS for a parameter dump")
    ap.add_argument("--bind", default="0.0.0.0", help="listen address (default all)")
    ap.add_argument("--port", type=int, default=7547)
    ap.add_argument("--ns", default="urn:dslforum-org:cwmp-1-0", help="CWMP namespace")
    ap.add_argument("--path", default="/acs", help="only serve this path (empty serves any)")
    ap.add_argument("--upload-url", default="", help="send Upload and accept the PUT here")
    ap.add_argument(
        "--upload-filetype", default="3 Vendor Configuration File", help="Upload FileType"
    )
    ap.add_argument("--out", default="captures", help="directory for the log and state")
    ap.add_argument("--state", default="", help="state file (default <out>/acs-state.json)")
    ap.add_argument("--depth", type=int, default=8, help="object levels below the root")
    ap.add_argument("--batch", type=int, default=16, help="names per GetParameterValues")
    ap.add_argument("--max-requests", type=int, default=5000)
    ap.add_argument("--reset", action="store_true", help="discard the state file first")
    ap.add_argument("--all-values", action="store_true", help="read every leaf, not just credentials")
    ap.add_argument("--show-secrets", action="store_true", help="print secret values unmasked")
    ARGS = ap.parse_args()
    NS = ARGS.ns

    out = Path(ARGS.out)
    out.mkdir(parents=True, exist_ok=True)
    JOURNAL.append(out / f"acs-{STAMP}.log")
    JOURNAL.append(Path(ARGS.state or out / "acs-state.json"))

    if ARGS.reset and JOURNAL[1].exists():
        JOURNAL[1].unlink()
    blank = {
        "root": "",
        "roots_tried": [],
        "queue": [],
        "reads": [],
        "params": {},
        "objects": [],
        "requests": 0,
        "informs": 0,
        "done": False,
        "upload_sent": False,
        "upload_done": False,
        "upload_tries": 0,
        "all_read": False,
    }
    STATE = json.loads(JOURNAL[1].read_text()) if JOURNAL[1].exists() else blank
    for key, value in blank.items():
        STATE.setdefault(key, value)
    _awaiting = {}

    note(f"acs up on {ARGS.bind}:{ARGS.port}, ns {ARGS.ns}")
    note(f"args: {' '.join(sys.argv[1:]) or '(none)'}")
    note(f"state {JOURNAL[1]}  ({STATE['requests']} requests, {len(STATE['params'])} params so far)")
    server = ThreadingHTTPServer((ARGS.bind, ARGS.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        note("stopped")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
