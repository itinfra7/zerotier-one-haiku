#!/boot/system/bin/python3
import socket
from pathlib import Path

HOSTS_PATH = Path(r"@PKGMAN_HOSTS_PATH@")
MARKER_BEGIN = "@PKGMAN_HOSTS_MARKER_BEGIN@"
MARKER_END = "@PKGMAN_HOSTS_MARKER_END@"
TARGET_HOSTS = (
    "eu.hpkg.haiku-os.org",
    "haiku-repository.cdn.haiku-os.org",
    "haikuports-repository.cdn.haiku-os.org",
)


def read_hosts_lines():
    try:
        return HOSTS_PATH.read_text().splitlines()
    except FileNotFoundError:
        return []


def strip_managed_block(lines):
    stripped = []
    managed = {}
    in_block = False

    for line in lines:
        if line == MARKER_BEGIN:
            in_block = True
            continue
        if line == MARKER_END:
            in_block = False
            continue
        if in_block:
            parts = line.split()
            if len(parts) >= 2:
                managed[parts[1]] = parts[0]
            continue
        stripped.append(line)

    return stripped, managed


def resolve_ipv4(hostname):
    rows = socket.getaddrinfo(hostname, 443, socket.AF_INET, socket.SOCK_STREAM)
    seen = []
    for row in rows:
        ip = row[4][0]
        if ip not in seen:
            seen.append(ip)
    return seen


def build_mapping(previous):
    mapping = dict(previous)
    for hostname in TARGET_HOSTS:
        try:
            candidates = resolve_ipv4(hostname)
        except Exception:
            continue
        if candidates:
            mapping[hostname] = candidates[0]
    return mapping


def render_hosts(lines, mapping):
    output = list(lines)
    if output and output[-1] != "":
        output.append("")
    output.append(MARKER_BEGIN)
    for hostname in TARGET_HOSTS:
        ip = mapping.get(hostname)
        if ip:
            output.append(f"{ip} {hostname}")
    output.append(MARKER_END)
    output.append("")
    return "\n".join(output)


def main():
    HOSTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    lines = read_hosts_lines()
    stripped, previous = strip_managed_block(lines)
    mapping = build_mapping(previous)
    if not any(hostname in mapping for hostname in TARGET_HOSTS):
        return
    rendered = render_hosts(stripped, mapping)
    tmp_path = HOSTS_PATH.with_suffix(".tmp")
    tmp_path.write_text(rendered)
    tmp_path.replace(HOSTS_PATH)


if __name__ == "__main__":
    main()
