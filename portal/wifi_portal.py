#!/usr/bin/env python3
import os
import subprocess
import urllib.parse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

IFACE = os.environ.get("WIFI_SETUP_IFACE", "wlan0")
TARGET_CONN = os.environ.get("WIFI_TARGET_CONN_NAME", "consus-wifi")
PORT = int(os.environ.get("WIFI_SETUP_PORT", "8080"))
HTML_FILE = os.environ.get("WIFI_SETUP_HTML_FILE", "/opt/edge-boot/portal/index.html")

def sh(cmd, timeout=6):
    try:
        return subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        class R:
            returncode = 124
            stdout = ""
            stderr = "Command timed out"
        return R()

def escape_html(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
              .replace('"', "&quot;").replace("'", "&#39;"))

def load_template() -> str:
    with open(HTML_FILE, "r", encoding="utf-8") as f:
        return f.read()

def scan_ssids():
    sh(["nmcli", "radio", "wifi", "on"], timeout=4)
    r = sh(["nmcli", "-t", "-f", "SSID", "dev", "wifi", "list", "ifname", IFACE], timeout=6)
    ssids = []
    for line in r.stdout.splitlines():
        s = line.strip()
        if s and s not in ssids:
            ssids.append(s)
    return ssids[:50]

def get_active_connections():
    r = sh(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active"], timeout=4)
    items = []
    for line in r.stdout.splitlines():
        parts = line.split(":")
        if len(parts) >= 2:
            items.append((parts[0], parts[1]))
    return items

def is_target_wifi_active():
    for name, typ in get_active_connections():
        if name == TARGET_CONN and typ == "802-11-wireless":
            return True
    return False

def iface_has_ipv4():
    r = sh(["ip", "-4", "addr", "show", "dev", IFACE], timeout=3)
    return ("inet " in r.stdout)

def internet_ok():
    # Generate_204 is a standard lightweight "internet works" check
    r = sh(["curl", "-fsS", "-m", "2", "https://clients3.google.com/generate_204"], timeout=3)
    return r.returncode == 0

def nmcli_error_classify(stderr_text: str) -> str:
    s = (stderr_text or "").lower()

    # Common NM / wpa_supplicant auth failures
    auth_markers = [
        "secrets were required", "no secrets", "invalid secrets",
        "authentication failed", "wrong password", "psk", "key management",
        "unable to authenticate", "ssid not found", "7 (wrong key)", "mismatch"
    ]
    if any(m in s for m in auth_markers):
        return "AUTH"

    # No network / no device
    if "no such device" in s or "not found" in s or "device" in s and "unavailable" in s:
        return "DEVICE"

    # Generic failure
    return "GENERIC"

def upsert_wifi(ssid: str, password: str) -> tuple[bool, str, str]:
    """
    Returns: (ok, user_message, severity)
      severity in {"ok","warn","err"}
    """
    # Replace a single profile named TARGET_CONN (prevents stacking)
    sh(["nmcli", "con", "down", TARGET_CONN], timeout=4)
    sh(["nmcli", "con", "delete", TARGET_CONN], timeout=4)

    r = sh(["nmcli", "con", "add", "type", "wifi", "ifname", IFACE, "con-name", TARGET_CONN, "ssid", ssid], timeout=6)
    if r.returncode != 0:
        msg = "Could not create the Wi-Fi configuration on the device. Please try again."
        return False, msg, "err"

    if password:
        sh(["nmcli", "con", "modify", TARGET_CONN, "wifi-sec.key-mgmt", "wpa-psk"], timeout=4)
        sh(["nmcli", "con", "modify", TARGET_CONN, "wifi-sec.psk", password], timeout=4)
    else:
        sh(["nmcli", "con", "modify", TARGET_CONN, "wifi-sec.key-mgmt", "none"], timeout=4)

    sh(["nmcli", "con", "modify", TARGET_CONN, "ipv4.method", "auto"], timeout=4)
    sh(["nmcli", "con", "modify", TARGET_CONN, "ipv6.method", "ignore"], timeout=4)

    r = sh(["nmcli", "con", "up", TARGET_CONN, "ifname", IFACE], timeout=12)
    if r.returncode != 0:
        kind = nmcli_error_classify(r.stderr)
        if kind == "AUTH":
            return False, "Could not connect. Please check the Wi-Fi password and try again.", "err"
        if kind == "DEVICE":
            return False, "Wi-Fi interface is not available on this device. Please contact support.", "err"
        return False, "Could not connect to the selected Wi-Fi network. Please try again.", "err"

    # Connected at NM level. Now distinguish internet vs captive/no-internet.
    if iface_has_ipv4():
        if internet_ok():
            return True, "Connected successfully. This setup network will close shortly.", "ok"
        else:
            return True, "Connected to Wi-Fi, but internet was not detected yet. If this is a captive network, complete sign-in and wait.", "warn"

    return True, "Connected to Wi-Fi, but no IP address was assigned yet. Please wait a moment.", "warn"

def render_page(message_html: str = "") -> bytes:
    tpl = load_template()
    ssids = scan_ssids()
    options = "\n".join([f"<option value='{escape_html(s)}'>{escape_html(s)}</option>" for s in ssids])
    if not options:
        options = "<option value=''>No networks found</option>"

    body = (tpl.replace("{{SSID_OPTIONS}}", options)
               .replace("{{MESSAGE_HTML}}", message_html))
    return body.encode("utf-8")

def json_status() -> dict:
    wifi_active = is_target_wifi_active()
    ipv4 = iface_has_ipv4()
    inet = internet_ok()
    return {
        "iface": IFACE,
        "target_conn": TARGET_CONN,
        "wifi_connected": bool(wifi_active),
        "has_ipv4": bool(ipv4),
        "internet": bool(inet),
    }

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = render_page("")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/status":
            st = json_status()
            payload = json.dumps(st).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/connect":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", errors="ignore")
        data = urllib.parse.parse_qs(raw)

        ssid = (data.get("ssid") or [""])[0].strip()
        pw = (data.get("pass") or [""])[0]

        if not ssid:
            msg = "<div class='msg err'>Please select a Wi-Fi network.</div>"
            body = render_page(msg)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)
            return

        ok, user_msg, severity = upsert_wifi(ssid, pw)
        css = "ok" if severity == "ok" else ("warn" if severity == "warn" else "err")
        msg = f"<div class='msg {css}'>{escape_html(user_msg)}</div>"

        body = render_page(msg)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body)

def main():
    srv = HTTPServer(("0.0.0.0", PORT), Handler)
    srv.serve_forever()

if __name__ == "__main__":
    main()
