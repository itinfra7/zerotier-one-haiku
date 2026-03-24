#!/boot/system/bin/python3
import ipaddress
from pathlib import Path
import subprocess

STATE_PATH = Path(r"@POLICY_STATE_FILE@")


def route_output():
    try:
        return subprocess.check_output(["route", "list"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return ""


def parse_routes():
    zt_v4 = set()
    zt_v6 = set()
    public_v6_default = False
    section = None

    for raw in route_output().splitlines():
        line = raw.strip()
        if raw.startswith("IPv4 routing table:"):
            section = 4
            continue
        if raw.startswith("IPv6 routing table:"):
            section = 6
            continue
        if not line or line.startswith("Destination"):
            continue

        parts = raw.split()
        if section == 4 and len(parts) >= 5:
            destination, netmask, gateway, flags, interface = parts[:5]
            if destination == "0.0.0.0" and netmask == "0.0.0.0" and not interface.startswith("tap/"):
                continue
            if not interface.startswith("tap/") or netmask == "-":
                continue
            try:
                network = ipaddress.IPv4Network(f"{destination}/{netmask}", strict=False)
            except Exception:
                continue
            zt_v4.add(network.with_prefixlen)
        elif section == 6 and len(parts) >= 4:
            destination, gateway, flags, interface = parts[:4]
            if destination in ("default", "::/0") and not interface.startswith("tap/"):
                public_v6_default = True
                continue
            if not interface.startswith("tap/") or "/" not in destination:
                continue
            try:
                network = ipaddress.IPv6Network(destination, strict=False)
            except Exception:
                continue
            if network.network_address.is_multicast:
                continue
            zt_v6.add(network.with_prefixlen)

    return public_v6_default, sorted(zt_v4), sorted(zt_v6)


def main():
    public_v6_default, zt_v4, zt_v6 = parse_routes()
    lines = [f"public_v6_default={1 if public_v6_default else 0}"]
    lines.extend(f"zt_v4={value}" for value in zt_v4)
    lines.extend(f"zt_v6={value}" for value in zt_v6)
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = STATE_PATH.with_suffix(".tmp")
    tmp_path.write_text("\\n".join(lines) + "\\n")
    tmp_path.replace(STATE_PATH)


if __name__ == "__main__":
    main()
