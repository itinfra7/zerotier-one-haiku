#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="${SELF_PATH:-$0}"

case "$SELF_PATH" in
	/*) ;;
	*) SELF_PATH="$(command -v "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")" ;;
esac

ZT_VERSION="${ZT_VERSION:-1.16.0}"
USE_LOCAL_SRC="${USE_LOCAL_SRC:-0}"
LOCAL_SRC_DIR="${LOCAL_SRC_DIR:-$SCRIPT_DIR/zerotier-one-$ZT_VERSION}"
SOURCE_URL="${SOURCE_URL:-https://github.com/zerotier/ZeroTierOne/archive/refs/tags/${ZT_VERSION}.tar.gz}"
WORK_ROOT="${WORK_ROOT:-/boot/home/zerotier-build}"
BUILD_ROOT="${BUILD_ROOT:-$WORK_ROOT/ZeroTierOne-$ZT_VERSION}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_ROOT/ZeroTierOne-$ZT_VERSION.tar.gz}"
PATCH_PATH="${PATCH_PATH:-$WORK_ROOT/zerotier-one-haiku-$ZT_VERSION.patch}"
STATE_DIR="${STATE_DIR:-/boot/system/non-packaged/var/lib/zerotier-one}"
BIN_DIR="${BIN_DIR:-/boot/system/non-packaged/bin}"
PRIMARY_PORT="${PRIMARY_PORT:-9993}"
KEEPALIVE_INTERVAL_SECONDS="${KEEPALIVE_INTERVAL_SECONDS:-20}"
BOOT_MARKER_BEGIN="# BEGIN HAIKU ZEROTIER AUTO START"
BOOT_MARKER_END="# END HAIKU ZEROTIER AUTO START"

log() {
	printf '[haiku-zt-install] %s\n' "$*"
}

fail() {
	printf '[haiku-zt-install] ERROR: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

cleanup_running_zerotier() {
	for tid in $({ ps | grep '/boot/system/non-packaged/bin/zerotier-boot-start.sh' | grep -v grep | awk '{ print $(NF-3) }'; } || true); do
		kill -9 "$tid" 2>/dev/null || true
	done
	for tid in $({ ps | grep '/boot/system/non-packaged/bin/zerotier-one' | grep -v grep | awk '{ print $(NF-3) }'; } || true); do
		kill -9 "$tid" 2>/dev/null || true
	done
	for tid in $({ ps | grep '/boot/system/non-packaged/bin/zerotier-cli' | grep -v grep | awk '{ print $(NF-3) }'; } || true); do
		kill -9 "$tid" 2>/dev/null || true
	done
	for tid in $({ ps | grep '/boot/system/non-packaged/bin/zerotier-keepalive.sh' | grep -v grep | awk '{ print $(NF-3) }'; } || true); do
		kill -9 "$tid" 2>/dev/null || true
	done
	rm -rf /tmp/zerotier-boot-start.lock
}

cleanup_taps() {
	i=0
	while [ "$i" -lt 64 ]; do
		ifconfig "tap/$i" up >/dev/null 2>&1 || true
		ifconfig "tap/$i" down >/dev/null 2>&1 || true
		ifconfig --delete "tap/$i" >/dev/null 2>&1 || true
		i=$((i + 1))
	done
}

write_local_conf() {
	mkdir -p "$STATE_DIR"
	cat >"$STATE_DIR/local.conf" <<EOF
{
  "settings": {
    "primaryPort": ${PRIMARY_PORT},
    "allowSecondaryPort": false,
    "portMappingEnabled": false,
    "allowTcpFallbackRelay": true
  }
}
EOF
}

write_boot_helper() {
	mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/zerotier-boot-start.sh" <<'EOF'
#!/bin/sh
set -eu

bin_path="/boot/system/non-packaged/bin/zerotier-one"
cli_path="/boot/system/non-packaged/bin/zerotier-cli"
keepalive_path="/boot/system/non-packaged/bin/zerotier-keepalive.sh"
state_dir="/boot/system/non-packaged/var/lib/zerotier-one"
primary_port="9993"
public_device="/dev/net/virtio/0"
lock_dir="/tmp/zerotier-boot-start.lock"

shutdown_requested=0
zt_pid=""

log() {
	printf '[zerotier-boot] %s\n' "$*" >> /tmp/zerotier-boot-start.log
}

have_public_ipv4() {
	ifconfig "$public_device" 2>/dev/null | grep -q 'inet addr: [0-9]'
}

have_default_route() {
	route list 2>/dev/null | grep -Eq '(^default|^[[:space:]]*0\.0\.0\.0[[:space:]]+0\.0\.0\.0)'
}

pid_list_for_path() {
	path="$1"
	{ ps | grep "$path" | grep -v grep | awk '{ print $(NF-3) }'; } || true
}

have_path_process() {
	path="$1"
	ps | grep "$path" | grep -v grep >/dev/null 2>&1
}

kill_path() {
	path="$1"
	signal="${2:-}"
	for tid in $(pid_list_for_path "$path"); do
		if [ -n "$signal" ]; then
			kill "$signal" "$tid" 2>/dev/null || true
		else
			kill "$tid" 2>/dev/null || true
		fi
	done
}

acquire_lock() {
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" > "$lock_dir/pid"
		return 0
	fi

	if [ -r "$lock_dir/pid" ]; then
		other_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
		if [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null; then
			log "another zerotier boot supervisor is already running pid=$other_pid"
			return 1
		fi
	fi

	rm -rf "$lock_dir"
	mkdir "$lock_dir"
	printf '%s\n' "$$" > "$lock_dir/pid"
}

release_lock() {
	rm -rf "$lock_dir"
}

wait_for_boot_network() {
	i=0
	while [ "$i" -lt 600 ]; do
		if ps | grep net_server | grep -v grep >/dev/null 2>&1 && have_public_ipv4 && have_default_route; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

cleanup_taps() {
	i=0
	while [ "$i" -lt 64 ]; do
		ifconfig "tap/$i" up >/dev/null 2>&1 || true
		ifconfig "tap/$i" down >/dev/null 2>&1 || true
		ifconfig --delete "tap/$i" >/dev/null 2>&1 || true
		i=$((i + 1))
	done
}

stop_children() {
	kill_path '/boot/system/non-packaged/bin/zerotier-keepalive.sh'

	if [ -n "$zt_pid" ] && kill -0 "$zt_pid" 2>/dev/null; then
		kill "$zt_pid" 2>/dev/null || true
	fi
	kill_path '/boot/system/non-packaged/bin/zerotier-one'

	i=0
	while [ "$i" -lt 10 ]; do
		if ! have_path_process '/boot/system/non-packaged/bin/zerotier-one'; then
			break
		fi
		i=$((i + 1))
		sleep 1
	done

	kill_path '/boot/system/non-packaged/bin/zerotier-one' -9
	kill_path '/boot/system/non-packaged/bin/zerotier-cli' -9
	kill_path '/boot/system/non-packaged/bin/zerotier-keepalive.sh' -9
	zt_pid=""
}

cleanup_previous() {
	stop_children
	cleanup_taps
}

start_keepalive() {
	if [ ! -x "$keepalive_path" ]; then
		return 0
	fi
	if have_path_process "$keepalive_path"; then
		return 0
	fi
	nohup /bin/sh "$keepalive_path" >/tmp/zerotier-keepalive.out 2>/tmp/zerotier-keepalive.err </dev/null &
}

wait_for_cli() {
	i=0
	while [ "$i" -lt 60 ]; do
		if "$cli_path" -D"$state_dir" info >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

wait_for_stable_online() {
	ok_count=0
	i=0
	while [ "$i" -lt 30 ]; do
		info=$("$cli_path" -D"$state_dir" info 2>/dev/null || true)
		case "$info" in
			*" ONLINE")
				ok_count=$((ok_count + 1))
				if [ "$ok_count" -ge 2 ]; then
					return 0
				fi
				;;
			*)
				ok_count=0
				;;
		esac
		i=$((i + 1))
		sleep 1
	done
	return 1
}

configured_network_ids() {
	for path in "$state_dir"/networks.d/*.conf; do
		[ -f "$path" ] || continue
		name=$(basename "$path")
		case "$name" in
			*.local.conf) continue ;;
			*.conf) nwid=${name%.conf} ;;
			*) continue ;;
		esac
		case "$nwid" in
			''|*[!0-9a-f]*) continue ;;
		esac
		printf '%s\n' "$nwid"
	done
}

wait_for_configured_networks() {
	expected="$(configured_network_ids)"
	[ -n "$expected" ] || return 0

	i=0
	while [ "$i" -lt 120 ]; do
		nets=$("$cli_path" -D"$state_dir" listnetworks 2>/dev/null || true)
		all_seen=1
		for nwid in $expected; do
			case "$nets" in
				*"$nwid"*) ;;
				*)
					all_seen=0
					break
					;;
			esac
		done
		if [ "$all_seen" -eq 1 ]; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

join_configured_networks() {
	for nwid in $(configured_network_ids); do
		log "join $nwid"
		"$cli_path" -D"$state_dir" join "$nwid" >/dev/null 2>&1 || true
	done
}

start_cycle() {
	attempt="$1"

	log "cleaning previous zerotier state attempt=$attempt"
	cleanup_previous

	log "starting zerotier-one attempt=$attempt"
	rm -f /tmp/zerotier-one.out /tmp/zerotier-one.err
	nohup "$bin_path" -U -p"$primary_port" "$state_dir" >/tmp/zerotier-one.out 2>/tmp/zerotier-one.err </dev/null &
	zt_pid=$!

	if ! wait_for_cli; then
		log "cli did not become ready attempt=$attempt"
		return 1
	fi

	log "cli ready attempt=$attempt"
	start_keepalive

	if wait_for_stable_online; then
		log "node stable-online attempt=$attempt"
	else
		log "node did not reach stable ONLINE before join attempt=$attempt"
	fi

	sleep 1
	join_configured_networks

	if wait_for_configured_networks; then
		log "configured networks visible attempt=$attempt"
		return 0
	fi

	log "configured networks not visible attempt=$attempt"
	return 1
}

monitor_cycle() {
	while [ "$shutdown_requested" -eq 0 ]; do
		if [ -n "$zt_pid" ] && kill -0 "$zt_pid" 2>/dev/null; then
			sleep 5
			continue
		fi
		log "zerotier-one exited after successful start; restarting"
		return 1
	done
	return 0
}

handle_shutdown() {
	shutdown_requested=1
	log "shutdown signal received; stopping zerotier cleanly"
	stop_children
	cleanup_taps
	release_lock
	exit 0
}

handle_exit() {
	status=$?
	trap - EXIT INT TERM HUP QUIT
	if [ "$shutdown_requested" -eq 0 ] && [ "$status" -ne 0 ]; then
		log "boot supervisor exiting unexpectedly status=$status"
		stop_children
		cleanup_taps
	fi
	release_lock
	exit "$status"
}

trap 'handle_shutdown' INT TERM HUP QUIT
trap 'handle_exit' EXIT

: > /tmp/zerotier-boot-start.log
if ! acquire_lock; then
	exit 0
fi

log "waiting for boot network"
if ! wait_for_boot_network; then
	log "boot network wait timed out; not starting zerotier"
	exit 1
fi

log "boot network ready; waiting for tap allocation window"
sleep 2

attempt=1
while [ "$shutdown_requested" -eq 0 ]; do
	if start_cycle "$attempt"; then
		attempt=1
		monitor_cycle || true
		continue
	fi

	stop_children
	cleanup_taps
	attempt=$((attempt + 1))
	if [ "$attempt" -gt 6 ]; then
		log "zerotier boot retries exhausted"
		exit 1
	fi

	log "retrying zerotier boot after backoff"
	sleep 30
done
EOF
	chmod 755 "$BIN_DIR/zerotier-boot-start.sh"
}

write_keepalive_helper() {
	mkdir -p "$BIN_DIR"
	cat >"$BIN_DIR/zerotier-keepalive.sh" <<EOF
#!/bin/sh
set -eu

public_device="/dev/net/virtio/0"
primary_port="${PRIMARY_PORT}"
interval="${KEEPALIVE_INTERVAL_SECONDS}"

public_ipv4() {
	ifconfig "\$public_device" 2>/dev/null | awk -F'inet addr: |, Bcast:' '/inet addr:/ { print \$2; exit }'
}

while :; do
	if ps | grep '/boot/system/non-packaged/bin/zerotier-one' | grep -v grep >/dev/null 2>&1; then
		ip=\$(public_ipv4 || true)
		if [ -n "\$ip" ]; then
			printf 'zt-self-probe-0123456789abcdef' | nc -u -w 1 "\$ip" "\$primary_port" >/dev/null 2>&1 || true
		fi
	fi
	sleep "\$interval"
done
EOF
	chmod 755 "$BIN_DIR/zerotier-keepalive.sh"
}

write_embedded_patch() {
	mkdir -p "$WORK_ROOT"
	awk '
$0 == "__ZT_HAIKU_PATCH_BEGIN__" { emit = 1; next }
$0 == "__ZT_HAIKU_PATCH_END__" { exit }
emit { print }
' "$SELF_PATH" | base64 -d | gzip -dc > "$PATCH_PATH"

	[ -s "$PATCH_PATH" ] || fail "failed to extract embedded Haiku patch"
}

apply_incremental_hotfixes() {
python3 - "$BUILD_ROOT" <<'PY'
from pathlib import Path
import re
import sys

build_root = Path(sys.argv[1])

def replace_once(text, old, new, label):
    if new and new in text:
        return text
    if old not in text:
        raise SystemExit(f"unable to apply {label}")
    return text.replace(old, new, 1)

one_path = build_root / "service" / "OneService.cpp"
one_text = one_path.read_text()
one_old = """#ifdef __HAIKU__
\t\t\tif (n.tap() && (n.tap()->deviceName().compare(0, 4, "tap/") == 0)) {
\t\t\t\tInetAddress preferredV6;
\t\t\t\tfor (std::vector<InetAddress>::const_iterator ip(newManagedIps.begin()); ip != newManagedIps.end(); ++ip) {
\t\t\t\t\tif (ip->isV6() && ((! preferredV6) || (ip->netmaskBits() > preferredV6.netmaskBits()))) {
\t\t\t\t\t\tpreferredV6 = *ip;
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\tif (preferredV6) {
\t\t\t\t\tnewManagedIps.erase(
\t\t\t\t\t\tstd::remove_if(
\t\t\t\t\t\t\tnewManagedIps.begin(),
\t\t\t\t\t\t\tnewManagedIps.end(),
\t\t\t\t\t\t\t[preferredV6](const InetAddress& candidate) {
\t\t\t\t\t\t\t\treturn candidate.isV6() && (candidate != preferredV6);
\t\t\t\t\t\t\t}),
\t\t\t\t\t\tnewManagedIps.end());
\t\t\t\t}
\t\t\t}
#endif

"""
if "preferredV6" in one_text:
    one_text = replace_once(one_text, one_old, "", "OneService hotfix")
    one_path.write_text(one_text)

hpp_path = build_root / "osdep" / "BSDEthernetTap.hpp"
hpp_text = hpp_path.read_text()
hpp_old = """\t\tstd::vector<InetAddress> _haikuLocalV6Ips;\n"""
hpp_new = """\t\tstd::vector<InetAddress> _haikuLocalV6Ips;\n\t\tstd::vector<InetAddress> _haikuManagedV6Ips;\n"""
if "_haikuManagedV6Ips" not in hpp_text:
    hpp_text = replace_once(hpp_text, hpp_old, hpp_new, "BSDEthernetTap.hpp hotfix")
    hpp_path.write_text(hpp_text)

bsd_path = build_root / "osdep" / "BSDEthernetTap.cpp"
bsd_text = bsd_path.read_text()
if "___haikuAdjustIpv6OnLinkRoute" not in bsd_text:
    bsd_anchor_old = """\t\tfprintf(stderr, \"HAIKU TAP ROUTE dev=%s net=%s/%s exit=%d\" ZT_EOL_S, dev.c_str(), network, prefixLen, exitcode);\n\t\tfflush(stderr);\n\t}\n}\n\nstatic void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{"""
    bsd_anchor_new = """\t\tfprintf(stderr, \"HAIKU TAP ROUTE dev=%s net=%s/%s exit=%d\" ZT_EOL_S, dev.c_str(), network, prefixLen, exitcode);\n\t\tfflush(stderr);\n\t}\n}\n\nstatic void ___haikuAdjustIpv6OnLinkRoute(const char* op, const std::string& dev, const InetAddress& ip)\n{\n\tif ((! ip.isV6()) || (! ip.netmaskBits()))\n\t\treturn;\n\n\tInetAddress network = ip.network();\n\tchar networkBuf[128];\n\tchar prefixBuf[8];\n\tOSUtils::ztsnprintf(prefixBuf, sizeof(prefixBuf), \"%u\", ip.netmaskBits());\n\n\tlong cpid = (long)vfork();\n\tif (cpid == 0) {\n\t\t::execlp(\"route\", \"route\", op, dev.c_str(), \"inet6\", network.toIpString(networkBuf), \"prefixlen\", prefixBuf, (const char*)0);\n\t\t::_exit(-1);\n\t}\n\telse if (cpid > 0) {\n\t\tint exitcode = -1;\n\t\t::waitpid(cpid, &exitcode, 0);\n\t\tfprintf(stderr, \"HAIKU TAP ROUTE dev=%s op=%s net=%s/%s exit=%d\" ZT_EOL_S, dev.c_str(), op, network.toIpString(networkBuf), prefixBuf, exitcode);\n\t\tfflush(stderr);\n\t}\n}\n\nstatic void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{"""
    bsd_text = replace_once(bsd_text, bsd_anchor_old, bsd_anchor_new, "BSDEthernetTap route helper")

if "___haikuReconcileIpv6Routes" not in bsd_text:
    reconcile_anchor_old = """static void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{\n\t// Haiku does not auto-install the multicast routes needed for IPv6 ND on tap devices.\n\t// Without these, on-link IPv6 traffic fails with ENETUNREACH before any packet is emitted.\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff00::\", \"8\");\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff02::\", \"16\");\n}\n"""
    reconcile_anchor_new = """static void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{\n\t// Haiku does not auto-install the multicast routes needed for IPv6 ND on tap devices.\n\t// Without these, on-link IPv6 traffic fails with ENETUNREACH before any packet is emitted.\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff00::\", \"8\");\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff02::\", \"16\");\n}\n\nstatic void ___haikuReconcileIpv6Routes(const std::string& dev, const std::vector<InetAddress>& ips)\n{\n\tfor (std::vector<InetAddress>::const_iterator ip(ips.begin()); ip != ips.end(); ++ip) {\n\t\t___haikuAdjustIpv6OnLinkRoute(\"add\", dev, *ip);\n\t}\n\t___haikuEnsureIpv6MulticastRoutes(dev);\n}\n"""
    bsd_text = replace_once(bsd_text, reconcile_anchor_old, reconcile_anchor_new, "BSDEthernetTap route reconcile helper")

if "_haikuManagedV6Ips.push_back(ip);" not in bsd_text:
    bsd_add_old = """\t\t\t\t\tif (haikuTap) {\n\t\t\t\t\t\t___haikuEnsureIpv6MulticastRoutes(_dev);\n\t\t\t\t\t}\n"""
    bsd_add_new = """\t\t\t\t\tif (haikuTap) {\n\t\t\t\t\t\t_haikuManagedV6Ips.erase(\n\t\t\t\t\t\t\tstd::remove_if(\n\t\t\t\t\t\t\t\t_haikuManagedV6Ips.begin(),\n\t\t\t\t\t\t\t\t_haikuManagedV6Ips.end(),\n\t\t\t\t\t\t\t\t[ip](const InetAddress& candidate) {\n\t\t\t\t\t\t\t\t\treturn candidate.ipOnly() == ip.ipOnly();\n\t\t\t\t\t\t\t\t}),\n\t\t\t\t\t\t\t_haikuManagedV6Ips.end());\n\t\t\t\t\t\t_haikuManagedV6Ips.push_back(ip);\n\t\t\t\t\t\t___haikuReconcileIpv6Routes(_dev, _haikuManagedV6Ips);\n\t\t\t\t\t}\n"""
    bsd_text = replace_once(bsd_text, bsd_add_old, bsd_add_new, "BSDEthernetTap addIp hotfix")

if "___haikuReconcileIpv6Routes(_dev, _haikuManagedV6Ips);" not in bsd_text:
    raise SystemExit("failed to apply BSDEthernetTap addIp reconcile hotfix")

if "_haikuManagedV6Ips.erase(" not in bsd_text:
    bsd_del_old = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t}\n"""
    bsd_del_new = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t\tif (_dev.compare(0, 4, \"tap/\") == 0) {\n\t\t\t\t\t_haikuManagedV6Ips.erase(\n\t\t\t\t\t\tstd::remove_if(\n\t\t\t\t\t\t\t_haikuManagedV6Ips.begin(),\n\t\t\t\t\t\t\t_haikuManagedV6Ips.end(),\n\t\t\t\t\t\t\t[ip](const InetAddress& candidate) {\n\t\t\t\t\t\t\t\treturn candidate.ipOnly() == ip.ipOnly();\n\t\t\t\t\t\t\t}),\n\t\t\t\t\t\t_haikuManagedV6Ips.end());\n\t\t\t\t\t___haikuAdjustIpv6OnLinkRoute(\"delete\", _dev, ip);\n\t\t\t\t\t___haikuReconcileIpv6Routes(_dev, _haikuManagedV6Ips);\n\t\t\t\t}\n\t\t\t}\n"""
    bsd_text = replace_once(bsd_text, bsd_del_old, bsd_del_new, "BSDEthernetTap removeIp hotfix")

if "_haikuManagedV6Ips.erase(" not in bsd_text:
    raise SystemExit("failed to apply BSDEthernetTap removeIp reconcile hotfix")

if "___haikuFindTapBySourceV6" not in bsd_text:
    reroute_anchor_old = """static const ZeroTier::MAC ___broadcastMac((uint64_t)0xffffffffffffULL);\n"""
    reroute_anchor_new = """static const ZeroTier::MAC ___broadcastMac((uint64_t)0xffffffffffffULL);\nstatic Mutex ___haikuV6OwnerLock;\nstatic std::map<std::string,BSDEthernetTap*> ___haikuTapByV6Source;\n\nstatic inline std::string ___haikuV6SourceKey(const void* raw)\n{\n\treturn std::string(reinterpret_cast<const char*>(raw), 16);\n}\n\nstatic void ___haikuRegisterTapSourceV6(BSDEthernetTap* tap,const InetAddress& ip)\n{\n\tif ((! tap) || (! ip.isV6()))\n\t\treturn;\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\t___haikuTapByV6Source[___haikuV6SourceKey(ip.rawIpData())] = tap;\n}\n\nstatic void ___haikuUnregisterTapSourceV6(BSDEthernetTap* tap,const InetAddress& ip)\n{\n\tif ((! tap) || (! ip.isV6()))\n\t\treturn;\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\tstd::map<std::string,BSDEthernetTap*>::iterator it = ___haikuTapByV6Source.find(___haikuV6SourceKey(ip.rawIpData()));\n\tif ((it != ___haikuTapByV6Source.end()) && (it->second == tap)) {\n\t\t___haikuTapByV6Source.erase(it);\n\t}\n}\n\nstatic void ___haikuUnregisterTapSources(BSDEthernetTap* tap)\n{\n\tif (! tap)\n\t\treturn;\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\tfor (std::map<std::string,BSDEthernetTap*>::iterator it = ___haikuTapByV6Source.begin(); it != ___haikuTapByV6Source.end();) {\n\t\tif (it->second == tap) {\n\t\t\tit = ___haikuTapByV6Source.erase(it);\n\t\t}\n\t\telse {\n\t\t\t++it;\n\t\t}\n\t}\n}\n\nstatic BSDEthernetTap* ___haikuFindTapBySourceV6(const void* raw)\n{\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\tstd::map<std::string,BSDEthernetTap*>::const_iterator it = ___haikuTapByV6Source.find(___haikuV6SourceKey(raw));\n\treturn (it == ___haikuTapByV6Source.end()) ? (BSDEthernetTap*)0 : it->second;\n}\n"""
    bsd_text = replace_once(bsd_text, reroute_anchor_old, reroute_anchor_new, "BSDEthernetTap IPv6 source owner registry")

if "___haikuUnregisterTapSources(this);" not in bsd_text:
    destructor_old = """BSDEthernetTap::~BSDEthernetTap()\n{\n"""
    destructor_new = """BSDEthernetTap::~BSDEthernetTap()\n{\n#ifdef __HAIKU__\n\t___haikuUnregisterTapSources(this);\n#endif\n"""
    bsd_text = replace_once(bsd_text, destructor_old, destructor_new, "BSDEthernetTap destructor hotfix")

if "___haikuRegisterTapSourceV6(this, ip.ipOnly());" not in bsd_text:
    register_old = """\t\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t\t\t_haikuLocalV6Ips.push_back(ip.ipOnly());\n"""
    register_new = """\t\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t\t\t_haikuLocalV6Ips.push_back(ip.ipOnly());\n\t\t\t\t\t___haikuRegisterTapSourceV6(this, ip.ipOnly());\n"""
    bsd_text = replace_once(bsd_text, register_old, register_new, "BSDEthernetTap IPv6 source registration")

if "___haikuUnregisterTapSourceV6(this, ip.ipOnly());" not in bsd_text:
    unregister_old = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n"""
    unregister_new = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t___haikuUnregisterTapSourceV6(this, ip.ipOnly());\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n"""
    bsd_text = replace_once(bsd_text, unregister_old, unregister_new, "BSDEthernetTap IPv6 source unregistration")

if "HAIKU TAP REROUTE" not in bsd_text:
    reroute_pattern = re.compile(
        r'(\t+else if \(etherType == ZT_ETHERTYPE_IPV6\) \{\n'
        r'\t+___haikuRewriteNdPayloadMacs\(reinterpret_cast<uint8_t\*>\(b \+ 14\), r - 14, _nativeMac, _ztMac\);\n'
        r'\t+\}\n'
        r'\t+\}\n)'
        r'(#endif\n\t+if \(! handled\) \{\n)',
        re.MULTILINE)
    reroute_insertion = """\t\t\t\tif ((! handled) && (etherType == ZT_ETHERTYPE_IPV6) && (_dev.compare(0, 4, "tap/") == 0) && ((r - 14) >= 40)) {\n\t\t\t\t\tconst uint8_t* ipv6 = reinterpret_cast<const uint8_t*>(b + 14);\n\t\t\t\t\tBSDEthernetTap* owner = ___haikuFindTapBySourceV6(ipv6 + 8);\n\t\t\t\t\tif (owner && (owner != this)) {\n\t\t\t\t\t\tchar srcIpStr[INET6_ADDRSTRLEN];\n\t\t\t\t\t\tMAC rerouteFrom(from);\n\t\t\t\t\t\tif ((rerouteFrom == _nativeMac) || (rerouteFrom == _ztMac)) {\n\t\t\t\t\t\t\trerouteFrom = owner->_ztMac;\n\t\t\t\t\t\t}\n\t\t\t\t\t\tfprintf(stderr, "HAIKU TAP REROUTE src=%s fromdev=%s todev=%s" ZT_EOL_S, inet_ntop(AF_INET6, ipv6 + 8, srcIpStr, sizeof(srcIpStr)), _dev.c_str(), owner->_dev.c_str());\n\t\t\t\t\t\tfflush(stderr);\n\t\t\t\t\t\towner->_handler(owner->_arg, (void*)0, owner->_nwid, rerouteFrom, to, etherType, 0, (const void*)(b + 14), r - 14);\n\t\t\t\t\t\thandled = true;\n\t\t\t\t\t}\n\t\t\t\t}\n"""
    bsd_text, reroute_count = reroute_pattern.subn(lambda m: m.group(1) + reroute_insertion + m.group(2), bsd_text, count=1)
    if reroute_count != 1:
        raise SystemExit("unable to apply BSDEthernetTap IPv6 reroute hotfix")

bsd_path.write_text(bsd_text)
PY
}

prepare_source_tree() {
	mkdir -p "$WORK_ROOT"

	if [ "$USE_LOCAL_SRC" = "1" ]; then
		[ -d "$LOCAL_SRC_DIR" ] || fail "missing local patched source tree: $LOCAL_SRC_DIR"
		[ -f "$LOCAL_SRC_DIR/make-haiku.mk" ] || fail "local source tree is incomplete: $LOCAL_SRC_DIR"
		log "copying local patched source tree"
		rm -rf "$BUILD_ROOT"
		mkdir -p "$BUILD_ROOT"
		tar -C "$LOCAL_SRC_DIR" -cf - . | tar -C "$BUILD_ROOT" -xf -
	else
		[ -r "$SELF_PATH" ] || fail "cannot read installer itself: $SELF_PATH"

		log "downloading source archive: $SOURCE_URL"
		curl -L --fail -o "$ARCHIVE_PATH" "$SOURCE_URL"

		log "extracting source archive"
		rm -rf "$BUILD_ROOT"
		tar -C "$WORK_ROOT" -xf "$ARCHIVE_PATH"
		[ -d "$BUILD_ROOT" ] || fail "extracted source directory missing: $BUILD_ROOT"

		log "extracting embedded Haiku patch"
		write_embedded_patch

		log "applying Haiku patch"
		patch -p1 -d "$BUILD_ROOT" < "$PATCH_PATH"
	fi

	log "applying incremental Haiku hotfixes"
	apply_incremental_hotfixes

	[ -f "$BUILD_ROOT/make-haiku.mk" ] || fail "patched source verification failed: $BUILD_ROOT/make-haiku.mk"
	[ -f "$BUILD_ROOT/osdep/BSDEthernetTap.cpp" ] || fail "patched source verification failed: $BUILD_ROOT/osdep/BSDEthernetTap.cpp"
	[ -f "$BUILD_ROOT/service/OneService.cpp" ] || fail "patched source verification failed: $BUILD_ROOT/service/OneService.cpp"
}

register_boot_autostart() {
	bootscript="/boot/home/config/settings/boot/UserBootscript"
	tmp_bootscript="${bootscript}.tmp.$$"

	rm -f /boot/home/config/settings/launch/isolate-net-recover
	rm -f /boot/system/non-packaged/data/launch/zerotier

	mkdir -p /boot/home/config/settings/boot
	touch "$bootscript"

	awk -v begin="$BOOT_MARKER_BEGIN" -v end="$BOOT_MARKER_END" '
BEGIN { skip = 0 }
$0 == begin { skip = 1; next }
$0 == end { skip = 0; next }
skip { next }
{ print }
' "$bootscript" >"$tmp_bootscript"

	cat >>"$tmp_bootscript" <<EOF

$BOOT_MARKER_BEGIN
if ! ps | grep '/boot/system/non-packaged/bin/zerotier-one' | grep -v grep >/dev/null 2>&1; then
	/bin/sh /boot/system/non-packaged/bin/zerotier-boot-start.sh >/tmp/zerotier-boot-start-run.out 2>/tmp/zerotier-boot-start-run.err </dev/null &
fi
$BOOT_MARKER_END
EOF

	mv "$tmp_bootscript" "$bootscript"
}

start_and_verify() {
	log "starting zerotier boot helper now"
	rm -f /tmp/zerotier-boot-start.log /tmp/zerotier-one.out /tmp/zerotier-one.err /tmp/zerotier-boot-start-run.out /tmp/zerotier-boot-start-run.err /tmp/zerotier-keepalive.out /tmp/zerotier-keepalive.err
	nohup /bin/sh "$BIN_DIR/zerotier-boot-start.sh" >/tmp/zerotier-boot-start-run.out 2>/tmp/zerotier-boot-start-run.err </dev/null &

	ok_count=0
	i=0
	while [ "$i" -lt 210 ]; do
		info=$("$BIN_DIR/zerotier-cli" -D"$STATE_DIR" info 2>/dev/null || true)
		case "$info" in
			*" ONLINE")
				ok_count=$((ok_count + 1))
				if [ "$ok_count" -ge 3 ]; then
					log "zerotier is stable ONLINE"
					printf '%s\n' "$info"
					return 0
				fi
				;;
			*)
				ok_count=0
				;;
		esac
		i=$((i + 1))
		sleep 1
	done

	log "zerotier failed to reach ONLINE"
	sed -n '1,260p' /tmp/zerotier-boot-start.log 2>/dev/null || true
	sed -n '1,260p' /tmp/zerotier-one.err 2>/dev/null || true
	fail "zerotier-cli did not reach ONLINE"
}

main() {
	[ "$(uname -s)" = "Haiku" ] || fail "this script must run on Haiku"

	need_cmd awk
	need_cmd base64
	need_cmd curl
	need_cmd gcc
	need_cmd g++
	need_cmd grep
	need_cmd gzip
	need_cmd ifconfig
	need_cmd make
	need_cmd nc
	need_cmd patch
	need_cmd ps
	need_cmd sed
	need_cmd tar

	prepare_source_tree

	log "building zerotier-one"
	cd "$BUILD_ROOT"
	make OSTYPE=Haiku CC=gcc CXX=g++ clean
	make OSTYPE=Haiku CC=gcc CXX=g++ one install

	log "writing runtime configuration"
	write_local_conf

	log "installing boot helper"
	write_boot_helper
	write_keepalive_helper

	log "registering boot autostart"
	register_boot_autostart

	log "cleaning previous runtime state"
	cleanup_running_zerotier
	cleanup_taps

	start_and_verify

	printf '\n'
	printf 'Next step:\n'
	printf '  zerotier-cli join <network-id>\n'
}

main "$@"
exit 0

: <<'__ZT_HAIKU_PATCH_ARCHIVE__'
__ZT_HAIKU_PATCH_BEGIN__
H4sICORfvWkAA3plcm90aWVyLW9uZS1oYWlrdS0xLjE2LjAucGF0Y2gA7Dv9d9pGkD/bf8WGNolk
PozEhw0OuRCDY64YfIDbtGkeTyBhqxGSKgnHbpv7229mPyStEHac9l3fu3dtnpFmZ2fne2Z3wbRX
K1IONiNiHF4Yn6yV7VhkET/ul8vl1MieXtUb5WqrrOmkqrcbervaqlTFf6RYbVWr+8ViMUUBpzTL
1VpZaxFda9dr7Vqz0jpqtFqNRvWYT3nzhpT1o1KTFOGvViVv3uyTPdtdOhvTImugVHataBGalfWn
fWK5pr3aJ/tFe2X9TpTvlfF09vNlXy2dG/anjbpflGfeIBQnFtnE4j4xA8+12rDEG2t545FCACNW
YLvXpEKHKvfG2iGrwFsLwG+h5wILBZhDAYQDSLm88oK1gQ9hFFjGet9MaZQzcviLFXgz2wp61mJz
XbkB9ewY4freMfoE9T9AIccaTbSG1khZo6mhNeBvixrjO3tlWisyn58FlvV22pvPAQYQG1Txy2w+
O5/0u735oEcUx3Ov1Soh5PCQv1xbUWSbigozuAViaufdwQ9XQKv4EC0Y5SYX834ajGr6VzAQr4gS
HbVKR6R4rMNfLhFh802FEVQTir3+26t388HobKys1lGJVCoVlax8cJFopYQROEtQwmXfTUakgGjk
w3PH/Ngmz7WjsP28Ybaf642wTQoEppPCr24BsSf9aX9Wktilb2eDYX/UveiXQCPDwag/n+PT2dXo
dDYYj9jbj915d/JuOp8naixLIswd293cwTjxghS0e3k57G9BYyuq1Bh/m4oM51Z9QJ9GcB3+2zr9
7jvkIlEnfDqhJYWvlD8gqOR8wkJVgu1praNquarBP1JttatV+LcjQOV5Iiz1KsFJ9XatVWkda40j
rdnSU2FZLQEVraRBAgAnLn5HaM4ji43tmCTYOFYI+a04GJ0Or3r9aadsh/dhZK2JdQcZagB/D33I
alZ0Y23C8tL3y44dWWWtUj1ceoElssYjqKG99h3L8O0MvudbbmQ5FkwK7ukUwCl7rnMvEPeLvf4Z
sNWbw2f3ajibT8dXk9P+fnE4eAtwB1LqZy/4hEII2t7iN2sZhTSDj8GQ47f/OS12vNC0/MNu4Fc8
wp7BE/vAbAAkZgaCkaWbKPLLvhGEVkCf5+y54tEVeP0Adzkdj2aT8XDYn6glDUsIwEbj0dmk3+9o
ceVITeCDHDvDa9n13BUEB+V5L2H6eyVZh4JwrncLnm+bGCRnU1LskHIvoZ9iLKlfaT6m3dFgNvhF
MAKvZ8PuO1irvAoN147sP6yOYZqBFYZAuAvj8/ElhsC0E96vF56DCFo+bRq1nPCpIPuT4TikfE3K
fnQD9c4k3yvC3VR4RiEQf9jjE5Cp2WRw2cFSyxQ7m3RPqVpdDyrU1HBCQ6+Cwdjrebeh6eLtVIe6
1BJvl55zr9WqjYrXJowhAupiHI31x7miAS5k+Y9OeVzblmx1a4f2wgZnv+/c2KZpuflEy70R1c+D
MkNLYPusNbAhGhwnX9FUIVzRSAyY6Qlwasbp6fyie3oObhTeWMAruNMpMGJu1v7aWN5gov2LLDcQ
6SZ5WX4JshAkCZS6k9Pzwax/Orua9DutVitZndNUS3fHzXmzzl1fwtcZ7Gran79v1ufd6QV43XDa
1auanhMcMUVjbf4jBDPT1RIIAGT7kwloAmIHas9Zd9YdtqGsgBYiiMBNYJGlt4Gc6HoRWVhQnCIr
WGN9Ym3dturaJGEdqFcuz8ejn9sE6ANDQdAmJ4AAa6r5JswVhptUinBu21z8NO7peCLSBiayu2a9
HLJI0fSyEa4P4zdMZjFLeWu9vRoMe/PLYXd2Np5cdKC/ToEly2wrm6FOx2ezn7rA0NVlrzvri+zd
KfxaMO3QWDjWr4UCddH373kMgDbpE1CA4t5ZFovaEWJAELQJdNCUWa52ISqGqsiWKiKhaHuA8P49
Dgni+MxjDah75A/ocSPoccvYmD9MDmdCpVEpWRqjqjQd4A4EfLiSicYvthl5nvMY1tKxUbz0YCxz
htQ2HCbHQMdeCDjW54ohqwv4MAISLEOyhZjFCwwXcLbxcBV8aucPhZaziqwwesBMAuWJthLTUvN3
r/GQ1cR8SYkJ3+nhJXQtbhu1sYYWb0UOQE8HoriwB1q3oRlyo8BzHOgaDuIGA5+gd7i1lww5218g
jDZi5YMHvSdHB2njZwRPW3G/aOI2rk0gjrEygDYuuj9gkP5GRL3GBIrNUxglkba3/mTaAdQxWqym
s95goh4uPC86ZO3hIcgNUiw/GdeWebiw3adOuTWCQ/Cfw0wooZpXX7tmdvLSzwb2N5H5Rh5oCH/r
ZDlL/E0xGCf/BCXB1n5x48YOIlzpb9nq31TyfpGK0JZ2bqx59FBIF/YON74PW65tIN/DbQ884aQl
f/JXHbI0dDxkgb+6zs4k4p2oOOKSN+fxxhrhLjtCuRoN3sMO94d++hglC47PXfg+5RUCDLdy8zpN
6u3PUNrHkx7uNRJKCVR6kekKEsPBbDbsz/uj3qA7SlORBuCd0ZCg+RTfDt7lkEugMa0EJBGKD/3i
Qyd+mBFDsL+ZjufTq8vL8WTW70kHSzjSH3XfDvs9orFzyuoxPajU66VjZrUEW/RYczx6IAXDNQPP
Ngt7eBjWZS9Ewd2zbYVkiEctJRJ6xI7IegNlYAn7bbKygzCixxJO7snMQwtSnAI7fOtZCzBxiVwt
Nm60KZF3sDn3vBI5s0wvMEoEd+tTaENLZGKZ50ZUIqeIERLgmni4k0btObsccCcP9EyjsM0/5Bx6
sPTXX+RZ3tHSixcpKLbhTNbYZSEhHEKlNdbotdLxHez8VSn6sdVb0pDnTzzO+dsTgjs1I45oQK+1
9eNKQwfsRi2eQZ1DqzZKLfAO/IRYl85O0zFJ9kL72jUcZTp4d351WSIv5gC4Ad1D03G+8dUTCeVy
cAmGgof54N0IxsQRKkAGYwlzMJbx5CNXGLmaTjRpBgIen6Nn5+h5c9I43eHkQpZrYkHJuf+vjR1l
xBuMZjJmDs6snyXHkSTL5x0FcVfYMSR8Y8fwU5zlARLidA/qQeOorVUrNa3WqLeOG/WU99AT6lZ8
5M49v5ChCBUGwiuNUKnkVKFCKt/HGAMTYtyO7jmRbYSLTWTd7Zw+/WxHy5udk68i2wm3RsfTNJzn
UAwOyKElvSoL+8pe4XFVyINcQNeGL72DKg7tVaZ+iduELby5EfgMN75IyCCYTmZBDl9bUCdzhgIP
9LQNt+m0bF3N4YufKM3dXXyFyxvLzCwQWpH8TmODLxYD2TWUjBiZthtlqQHQ24ZBG49AtFKN3sjV
61mHpKl4CbJlrYRw21tGWWVKqTvv9kfCDL3lJ8ZZnl4QwXKs5ZY4fKaVOxAZkZCqUac3W/VSrcXk
2ieusbZC6DKhnPHrMvIn774ynCIhewmFGgItRm63oVwB1nwReIa5NMLowlgqygZ03qzPI7V6t0r9
dzUcYsKMadmwMYdCusCdIdBAF+qyA9v+7xvDCSfGZ4WtN0iGXhDbL3E2bqGrOCCB8blENi76hGUC
0Yg4lguF+k/ssK1oE7jQefhYZRX4rNjhj3WFFl0F8EinQ+oqrc18sCkPak1VZYBnZG2tl2sf8WDN
gd8zIkNRS4wBXFNF8b5sS8iVZPu39YuNAwOgqJmHqmJyoL6O59EBiMb55hCyNpYfmh9Jh/xJqndV
KFbwt4p/G1aJKBxLBY4+aB/JC4AfrYAheNU/0o/aR/LlJNEDMKIAyRJpPspp8+9wWquV+F/kjPOi
1fhnnX82nsgcY2F5YwQHyCRttwag05k3jfAOm+qjpgMz1EUAjyw2qw+DUX827/Z6k+lsMuyPPnLG
oY0Ck6LTzaH585Xu2RwxodDibJhYIpmZ4Ac4cY+n9Xb7jyh0+TVeHn6JFKoV+n8BJdr7ksgK6F8v
4wSdLSXmlim+Wlif9aA5Qv+bMqMkWhPMBgJD8l9+CjdrJR3hJgTazhDPaMMHFwwseLMCHxaeowe/
knFeK0iQshd7DCwJE6sI+3yD3wSh8f+aaFx+HC92SOxiqqL4H6ofyatX5BiyB8EApBT3fMTT6SOS
KPOXL9wKyPgukglFMYPzgqivX2MuSqZ2GBiDHpOrSoppvIzuFaFjVflvQNoRYGlD2JDpbpunsjli
LYfBUiThGGaG0RbMN+4dqAwZ43HoMLYhKiYBgtr1hhCVC1AVAol844fWxvQ+1KERReyPOA75GToF
hQ1BBoItpv2H5a04hKZnRFr69zESlYQrTBoCulqzxKTi43zNWgPzXJJ9U5wza0jIdRlZkvM1Ok/O
nBbOaRzn8VQHqWKtphSZSqTpMBJiUj3J6GkHEDWY5psz2zUvjAgvh66H3tJwoCYyu0KX1G7fQgvi
Ba9SNfn1C+Ig3sAPtzwgMoJrKxpAepGK+MrbuCa3/soLiLKLdLtNCc5tCGgDBomtiLUqC+vadhUw
K7HJs07MQwV6JwWAxaLNnQj9yy6/Tqr7rnbjwC6lOMbazwjsUX7BKAc2jWyh6ijYWBTwRY63FdCz
MjrmtZWqeLyJrj1Qb89iLZMUHvjNg2B271s54YRt3s5UiGIq8WzsXn6Zzfuz8/4EvyY2H1z+WE96
m9eQmKpCvu1QBlnZajQOToQWYQSTFE7W6/TkggFeAaDWEtpKHDGn54EZaqyzFGq6h0xnzIclakoS
1b9SIr2elQhI0zDMkyDbCz1FglRz82DQvcX7k5EFW/yFF3TNWyuI7NBaw6Y1m3u5m285R2CtvchK
BmBJHpcX2FWl8EIfECzZjV7EcDktQ9vAF2RN8rN4neSdzVPjjB3TESU1GxZ7VA17qRbmtknrNpuZ
yuU4QjP5kU5Vju/UXGCtZjWG0Ixc0+P3ZpJA6fsRvuuNRiqj0jWL5LiUKFQuAxxBr5dSqmUoad5d
A0hz3DrlyDUYh1qtyV/rMcN4Phl6jr2EfGbCDHFrnSwL9HK5AjI6paOLNyq0hm/CypWl59/PPEZD
b/JWWmqSaH0X5QHmb5f6eOFEahfar5oesyFXtJgYLWccp7YDJ1XsZD850lMVjKfVdLBgJ5h0xNbn
ABTYDfxLVtJA9lB5NE1KkYHfhqCBkYJFGN6y8zNazNcxybwi+rHwfE5CvLLZUt+S+Dolx4ihdzzr
0K0cm8rBmgBrElgX4GMJXMsnUhfgpgRuCHD9IQYxS8U58hjdB/NiLCadR6UUjiYjp7O2REp7Ei0t
TewxHxiZ/4IL1KsPugB9SRkbAgMKL+hftkmT2qRxvMsiPGjzO2cML0XqG9TYA9RkWyKsf5K4YEyB
4SCr2e4QOnB6npHPV5K2aeJI11WWAHMYZ6iM72QhugVLo3l+ZMPk8WoFyV9UD1onA2ruiBIQZQTG
QnouC90dpQ/KFuXfCC1IwLU2reZZssesiVsElvHpJIVez0fn/c82fqOdemnmT+atxvbko3x8psI0
vmmtDGhA2qnGJDEG3yEqMhnI/ir2ZLHauVpi0zF0IjCwEqUJnKRaqG37CPeTvI8N4TaYHHAFU4dL
piT+lmU2xkHPS3gWzViiii8xWU6Dt248Y0ownZ/bJQxAg3jMYJiduApAVdnkJNaV0pOMLnYBiVNK
W4GMVWGbH3MhZ9yYQn7bCrvTgZ8OsOOTHCzoR2Us0d6yoKD1upqG1BLIUzoDyk2JLVfidiql7LW1
6ENNgsTLw53Cl9zTCql9HoTQDEys3zewoco2zI/smsQRCddeen/EvSXJ5B1RcVNgTYA1CawLsEyk
lk+kLsBNCdwQ4LoEbuYTOUo42XHCk6cz1oX9v9L0LaWld+ziygMywhmkCXGdeGlEN0r60NYHANts
4Q0IcT/bZrabiG5Eu4DPWLPksy6xV+Rpgp6MhPTol9h82ZOEXnwyi9dqZ1AMFMaCQGWXG+KtYq39
6F4RK2Z/hVKg9z1k1r0kg15/NBvMfqZMdp6HuDuDKtTBZcorAxYy6e9Q+uPhfFpiYtG4Xq2cTXjD
SaonuwUTpetZDnfstoaDP8Tj4GPXoHCVlAnzoJe/ui/57c3XIAcvVSF6smYA9VjJnZViVhic0O88
moOMIWRoBSsJP62PCS/nYEQlXh+dC397d2uZ2dn8Zwt4t0T9hyVqPOJfG8u3m9UH7fhjAkNsCtQY
8BtsytanlBCKi3aeV7Sm49zhkgDLmrpEdvFcicQ9BWdMxZsqkUXwN2r0j4qLlIQGkklMQvUxV+Lz
ss0yi8HQwmoI2l7eBFv6L5GX7ZeqsBuiUl/DhzLZMhZmNC05VBL6PrfuYn3zfTsHJ4FXMfn9IMyn
iPHEalJ+017ATyMVHs831h3oZOZdNeuCuPqoR3yD8deGuzGcpxk/FvZ/wbLf6s88SeH1bNkPrJV9
h2JVc6TZsjouvs3hA0d5X1EppCpx462ty52VIi/jX24Wjr3EOScZb18armmDr1GCIeunqLcWCiX6
8bRvLx/G2vDpkhIR5Bu/I76yrw9D/HWrex0+PvvLSdzvCsEx6MRzsmvbFrZihOhf8TzeOubg+T4e
++O38rqz8/m0f9mddGfjyXxKClmeePjIeqNBmUOY+0TKH/G6Qt7c0nCGj1eQUNiNk0xcJYckd4AW
//RNRToffFXrIZOzP/IEoSbn24xa5mA7FWXi7iLXw+NvkWYPra+taGi7n4bGvRWIxJW6JGLei19s
vC2xg5W1OFbZ/m6J5PDLtakU7BVzMsJsBTBhYCBIQfgz1wOywkTfbvv4lU4FseIkXwgKcZJ/Bnhy
i5U5iKZCiSueeIzmV2ybPzQ0naZX3rG02ysQP1RwLL5jxBdYF1aStnIsRtdG8MkKWFFCBtnMAldc
m4vJmWXIwmD4iwzbTfaWdBuf9r7FB3b7SWeDGkPwiZXCVyySFqzz/K4t/yuUyIsFOB/90NiHzj5q
7KPOPhof6c5Y3MbG16+QVMWyDwdEM+3doH+YZ0s7vgW8Mzp047wHflKB1AI7bvq9GrHVFtaJt9mZ
UwGmGXCFpeNBO7fy0ymbTj6h3+qlv4MEE2yWwCb7xt0BPtD7dBmsVoUDgbU5UHkBD/Qsr/oNHsVv
OuXF0YXh5YT4J/TZL7+G17lr3UWp60tFgI01vQdTqGOp/CASe521n8bBAnybtDGMYXr4yHBwcUqH
s4PfIENYTDKFV34dGvOVsbadeyTUPcMflv+gPuShGapz04G2zHTI9oI4pKYWi10Z0GFh05kbfGcZ
O2HiIsMhfvUEUdWnugr+3EkYFW2a6y4s+dEJO78SJ++p8YsnK2NpnRvhY2kx97tt4lstmHtsH1qn
D5rOert0kvxsuHg3Bs3VwBf7DHxgef//ZDqlLpHOnqiD7Kbqn0kTO+8c+m64CaxB+kZ4gt+HfcTE
rAbwX/jLQNaYJleutIte+jbK8D/VPWlzE0myn8WvaLQB0cKSrduWGZhgsZlxLNh+PmKJ5REK2WqP
9dA1UgvDbHh/+8ujjqzqah2GncMxg911H3lXVhYH9PgMRONTbBaf8yz52d9PviTXw2lcJM/cIm6V
/gOAu+jQAUhDt4c2pJrRFHkIgGOQaoYDkr0YZklpMPv73eTLII0rRjMuIEWNzMBemnGRIwOUvZ70
E7yrXlMN3PUGKZSk4sBhdJFypLpYIu2fnVxeHOJ0SE1JUvi1A39hEy+eOMYIZ8pmpmJyuts8ZWTZ
wVMeEOQhutrZnR0VsqI/SeZ0O7u3SCcVdR0tSm+TaKTbi2gLcZJJHy9uA9s4Ov3cjo4Posk4SntT
bHdwncy3ueF/DtJbqIGN4Lk+iPiAIp+4Tjrr3dzAHFAbmkd3UDI6PD68uDw+O3z1+ufoKoHWk6g3
/qrNxwNY0hHapPvY+krQJzgv3txUq/v7CHR7TCjWr1fnerV20Zc5I9f/f3/f/Y4fRYWgUgXpjjgC
ha4Xs1kyvv5a5og4Vbyq0txtlGs1DrlUjrrTwXiMhFT9LnFqb/ZLDP+rL5StY6Wp4fdv5L3Doi3l
A7h8TjBNVRilixj+118JgAWUp1+lRxVMu+nHVVUb/gTM4qLJGC+X92MkZCppCGt3dIO8Yn45RZkf
KwK24Yz2KGpRc69d5gApEVShGw37+2+B0UbdX4bxL8PJVW8IC/caSGKaYDreNAlK5Eznu2LlFF7L
JO1+4OxZKGBSYedZpD4jAPbJ3ZzNBQPNLdkRnS5g2TToA2QOKPZsR92eqDXookirVVWxjFCkLKS3
s8kdo91sAaLIKOlScIS4yKQzUtZKmixVgZUmRkd8DgCRzQAn3bODf55BqQqWwRXAckjSWHY1KUh9
Vd+Ku9AHCZerhrSgfY3SCV1Di65pK/oCp3GYNNdmp1yvwWTb1XK7pmd7j//iP/ePKlqaNb+z21jI
8ppk/uEjn84wx/x3EfreeYKcorgDQ9hRn/ek998zgcxI+NwWi/nqb6v86o6E2mv61govJwgREoaJ
DQM1nJmTX9WzVikoT6kVTVevCPknp6MpzIeFYTUMm1Qq2/XgPz6SPjRQQuRyTqygwWfGBcmPtdCF
Cyv+lqMqLqbFMKctZJitUZByWW4hj+sW1mG8akqm9mNnWq6Qb8eixP3wBhjMUquvvkNLX5NLbzYd
UeQVcKLRlEHCSUA3DAQCkWbHuwLD7XwNQtupdqE8ipBmo3R5IUvaFShc0IUmYPnDJJnGraq3W+FO
ZEv3QvsNlhaF77Ug+zdFbYCyniBLRF6J0TA+JdEJzBkpLcafim57n4G7Q8aIPM7Gi9EVFJ7cSCkC
5IZeinZEFTOGCC8UJrobuThYzeBf9DDsQ7JDVGdA1x03BCAmVU/mDkJxQ6uJuyTtVrmQyx6FwSBy
KD6T4ci7cB1BD7q5H14w8zDfinGszR5Q7OVNwkBz40k0QmFNb1vvMzA2LK9ZG/Zzcz1Oh9hbOXrT
PT+8ePMWtCiZ9hOmodv5f04w2Nbf3568/gcZeSp02YF4z24L5Yitdr1dbireE9qfBAAHxBGzP+ob
9+fJdv3Lft4/SPTQZwQvDSHRNR81+VGXHw350ZQfrY+076HxgeQFgrgZHn/S6BZFFs7yq4JGKqvS
p6jKItzzMNtdogGRbty7BjGR+L7Qjy2e6WyH9PmJP0S1KtE/L0NTjRX8K8u+bFAAFX6LSLGvjlGo
lf3IWBRAAYNlpF+0JPgXcDWhjHUdbUxviVpQYWVZi3u6jRWhtaJts8hDKOrWlzPYDH9lCpzPXUOM
dR2+SrK00TgNC5BAYM0V+awhzGeMR9Rj057uYn+fjRyA92oo+XTH7CfKyhhETJ3uoMHmU2WIVv5I
R9NDKV11hiWQkRihvWhHJbnUEmCMsqAY+aBYWQ8Qh0Oyam4KkoaKZWHz90AAE9XUgH9c3JljxBeJ
A5kUDxN47kUxm29Ajk3R8Pt1Hnl4SRw2jJPEqDq1cq0BjGq3Vt5tayXp9wFzIwEgmOtTsjxmYBWc
WYKcPem/WSWgsnugKSwlwixms9Bji0ssNIJJhLai8wTWG2tXJuMKbjPGYSEBUIsVShCcJrP5AAd9
E90laIP6tEPFkU0tyP6AsqEvbRwEpI0DdEV+c9B9/fbk8P3hazY6LFFX8RB0xr58SV8bWGhGmJPc
3CS4Lcm/yPjCNhh5fuYW0GvmptJi2R48UrpuE6uO/O0xv/XaUBoTWcPlEMjUL/163N5k9hIb6euT
4zdHP2kjKfaf8ekwnWKO6cRz83AR3B7b/2isbNF+VIzHi+GwVFzq4SPnaJ1BvJkjFXama0tmliHf
g4RBAfbFrfOcV5yEcJrWZDTtzZK4Wo6arIfsFEuOGo9gZkx5niGi5whlni7a8/RQ6jN8WN4lA6jp
hVzexFe+opincFoFMtuMNUzCuL2ZCbEnVJoX1RQ1naB5kFEPRy730/b6Wx6qicHaZvxaD8EuM0RC
ITMPiT2c9ZuPVEv9jI6PLjI41VNoA019I/LY9bZgL4de0pZmm/2biwwhbKAlFtuat6sOA4vwbGww
BdYyv12k/cnd+JxirZxCWq6xmLfpXW8wZtAkUx0AKId6iT+kt4P5xxg2OMK/Ki85HcvjNd17VgJY
UOymugUD5Wj0i7GiUBaie2Rn/vHAf7zzgZIKudMp19rR1i6Gm1Mywu8jj/YB5meTr3mgsb6A2U+G
SZosayf/gYE1pLlipaJ6yMBuRjjUxuaNZUS9GCGh77tIwMs6WF+qjIKKe7RS0yNBMOcgxceP7f+b
DMjOY/ywgyWM05lGDo0SlKkwRSKFuEnPmU+jFChNd/aFa87VBFPTPI6acKSJr0Ns7XZaiCoidpsB
+Wg9SMXjZfxd6Q0HvSVE0fdduGLPUAEJD4YDHEIx3AOCOg8sCNoB3OHQATpqkDAFbAL6akQmMor7
Z76JIsuZN+8Xz/qLfMIqD/qLtfreys4Nrj9svg/YAQ3IhfVVwPpulc7J9hr18l5HqYDKNAtwtITS
V7KUvqKkg3Q0NX43PEqy2xGWAmfBtlaJkmGACtypG/W+KNPdHNo1XfyI9j3A3nrelcoZPjZxkIDS
+s6rWKeKaB60e7iy49p63VQFs3kUcoaV8nFWJF5ulQyeqXkb8lBmzP+tJksqPtiPCoxRUtN4RACt
wBkGZGSvP6z378I4N+sV3Yry8LfisdkKnlKHMbcSZLOVlWy2YnzO7EnlEnTLo9/KvQ4jZrWbSv7X
9ynmn9xk4aBHuRTuYRsS8cMcB28qDi2lkdiyTFeDKm3ILWhCTPU/aC0neNjBZcruYb057LCz/fsg
nWu59WFTbmfmrIAq64W2PnfacCDfD+Dl2YV/nGDVr9BhQs5B/arjhCCIB3xFl2qzrw4Ojk61OjuY
4r+KSL94sth5sgh51AWkN8fvtGzo/lZUK0vW4jvbZVVVsYiOB4J/MuXOWtlHLXOyNhPXQOKUcS0p
grXT4zfDxGWky7x62X4zmJYAeMTxTXAzvmk31Mi+44bQ0alq1vhcZA0I2j6jS1ovEzT/iOZL0Q+y
A+FKkb8TsLrOJ8krxjMjz90k43Bssxxvt6HSuc5T6+hmZpRlBzYO4GDatM5H5m7fU0imRXbifjbN
cLkzfJOr1+9TyLSYakjbdNZ9x8QbFW4r1JAKukahzOhyKh9lJKPJ5yTOFFFR0KC3TGWMg8b0bnoy
HuLF2rxS3lRE9hTAonvVu/4Uy3aeC1DQCCNdaFb6yna157lYmXv3MNiPsZajYa8Pjw+ERhcW3UFm
4FGGBFOp5Kznp5EBiyiPb8XifT6ahmPfKptWp1Hei7Y69YaOI53tNC+iHnpgwsbCdjIvj5RrPZS+
GQAscLYFK/VtgIkuk8hELc+xrdsM3xDIkrG+B3NzKfxaGB1G6Bx8Xg+dLTYrlIPiYReBLAb/0Qh8
L5XoQJRCVqYzsEhBr5t75PTT6VTLNWUFesSu7z6IThc6yIaJo+QFUfICR2RCGi4P7JoDEoTn1k1L
B5344QW78lCCdpxWXyElfTE2Srpw/8qPMvjq7DRz/U1FzfhAr4addv9++ab79vD4p4ufFcf3VOhs
RLwCH3JyBoaBfG46IMAdJj1Y7j7FdVE1/r0Jo5P1LUBPZ5NroAFHY1gTkBUgKeY9oNBYNjKgGHHZ
GaWDB+oM0+Zmj1nMMDDLD068XFK9PI5gaaOjY92IuuCtBwbikdO5dwhjF0DIcTKMsilQdkaJ8lyx
UlyyBvIU05n7ksMYJa3aCIuCYNCTDjHeNADRjBCjVFV3DbQI4Q6gnIFPCpEY3D5nw2zwKH1OtmmA
zd26vPbnBIz5lG4UelnHcYJ6NkYaXzWl6CyfdMSW1p5N4WAt9VbLJjVVBKhGS6j34ciYeLnyk42i
lCmnI7+ack1dUNoAKD7iBRV9brmNQxV261rwX00H2CNwfouPNp4l0+FXxyfQYP2aaF9wG1oW0tfn
IzLyrZhjwJ1Z9sHBdFeFMF0JFqJDyZVLMgqljwounDtC9FooxWwrA+8rcUkvhcAm45e9Hk41+Yrt
CrwztoIHh/X9DkjKZJwif+WTcC5EccGWFFpC6I+IzqcwvRcYMRj7Q2rfJ6qOzAmIvaP95oTGZ7St
1ctmxKWVhdtlM/ISv+MQlPUeFoZ4g1m3A/P0RxPiLPv7FAiTHa4MNxdGKCdkoDjpZ/PgIsX4MdDl
u1fvu+8uLmFJyPZZEeLWamlL6QDpxETzpHb5UjZa6AHX3CzsR9/Z3kiwE5Ey7gazBBpMJ9Y7DJPQ
SyTGHvNMZtyf63sTC2+W+HEUS3cJ7S9RcnByLYnRx8DebLMXCjYROtfhNmGxc6ncuSkL+u+KnsZ2
h9CrIjY6cqc6MJqE03PF1bXl1aXGvDOL0kC4cHj4O50wGXuAGBsO1gdQxFiOJmxdG83YcTAgolec
EsnoTa/doQsS4aeRa+2yQhbgtDWIT0zyHyhf5xsrQxL27yViSwnp8ap9s6OTUoT19zdEhkmcIEG6
os4Q3mOSU+i6SAtzanNWuL5j5eKuQpR9y7aUR92jQuFZbN4feVayBWqoS7yIblNYGluiZMgqV9YP
YJhaTY/L/dEEfnlQ8gyltzReTKmkyKAGRTH0oDCyShYJD82Nlf09R+aYnZB1b4FG1tR+U1Y80bDD
W6e9jxq75H1Uq9X21L3uf3v2S2M9/mk2WUxfRuPkjv6ao0tixT44p64+8tNqN9Fj+66myaH9Fxnm
Zc/IhgUambhAI3b28HMwNFCkMJ2CA41MdCCoUVJ+Vpn2ONQPlOAr3o29XZ53o2Hus9MFb45NM9LB
abDJ5/rON64yPavqztamPxYZNFfxDt9GZuEV77LYF1mmns0YH2SZ+lZiui+qzNfNRouubcCG18p7
TZ46DJ2kIFwzinyX4ivh28LvTTs8k79d/rb71EDLT1coOAGXJsHp/OhfhyYq+iaRDpax/4ufzw5f
Hbx7BSKAOtATbfgqjHOA5/SPPWVYnBrqKoumiuuKW/f8efZ6PQXuxuM/jhfLWHllTv6vSsI2M6b7
qtKVPYaxjCe4s4dHxxdnTEpt2sXRu8ODk8uLkgqY4DivZ05RdJtjviarQuJaMT9TLWt1ij7jHRWK
Y24jSF8Zc5IwM5mC+NwfDXuVqswvxlzZ529US84LONyU+waOZe32Nks6ifMfw5Fnb2sJKmhez5gA
SD65KrveWCVfOLHqrH33xpjTMKmWTapnkxomaXMxy3so59umkjnA1RHTzRGuydFR0jOHuyqs+ZWy
HNhjXV1ABTy/UtaCZkkDo9XNQLD7n0Uy+5qvm7nKmS7vKmekneksoZ1prW0y/Jz0Zbo5cF1TNSvI
Rhz17FfsMtZ75EZ61yMqy2GXnYH6R7nrmY3WsxupsLuiN1dxM4qdmZmXv9wEAwTLszf9qqaIqtmv
uk+ltpk+8vQ0qQKpZQzYopxiapmFFSp3nUV0ZXc9yFJqR+foUHJdLLUJKlFE40Tv8kx/TfyWA8tR
o4IAlQEhpdCZ0T9gLLL65oRG+CVkRXDJUtqCpTQzLMUygODbbwEDdGBIUstNJ5tT3RDPaK9FaE3I
kVxDIp1gqLBZSFTUn1gw4FCMwdiS2evJYpySH7UUs350BCF0w2BRb3mMUVlHhAVaWkeMQkYysXcl
hONL5jJTORqU9YQ/6siDSwLXvY/OL16dmStkg/6XpcKgDoST9ZRzdRqhujBg6NBlbIxlL0NIe41B
Q0DziJ64S6UgKlNIrg0HtMpM7lTttrqu9aSPIUuusYkn/f9FH05eIGy0pNrQL38Djwa5Hs/YVAJ+
xrrU9XQBCSk+RQIbgEdspDC0mujoslWr79bKNRH7i1wua7ryvYqRtUJNUmHAlukFkWK6iDZoDeOU
GxwsWlZ7/Zs+QAHe4IM/OJPEa0ijnBmDbaHw5qD7r8Ozk/ipqsTmcJusmlDJWFlL6AR1o96X0FU8
ipqCt79RJIGq7O3BkgRPTmoAy8AGR3J+eJHbiRi3Uxz1Bj+PnyePeQWemlXSc5R/aY0aL+d/7g3Z
nZZ2ereNkexq9Y4T401H3eFPhHUYyNF5dig8YesCA2saVHlg4WZC7Ykq0UxPw1V+OGlD9Ydm0mmW
a3swlUa1U25X7VwKdE7CAWyvjJGMf8gOq7IcGxr/hJ1q8E5vOrmdx7F4xYWtbVelD+2PCrjW4hd8
KIpgL3x2qsb3mYvT2Mg2NMNnMqzEXFDH2dyJDG8T9uE1K/tNtjrbTsqW0sA9arXs3oXmgmTzppUb
bTPNa+dGWU5XtrSeBVHt7YojImueU6svO364FdLbSmnh8x1Y7bzyTxkUQHhzW6KfefkZLY1/PF0N
l4hNwd4y+DobF6wHCm6guakKa+hv/JOnxfGPuzBra25qm7+7wsY/987XesqbKLtShRNllyhy/LPi
fG19fe1PpZ95Cx7WvvgnXwczQPD7aGIh2LCkXQatyhSUf296bKFm+cDDi00Jmhip54Cu9+Kx5mfu
CP/rrPTeMP57LfkUrJjnlrlfIea5jsH3Yes5nj+UVhw1sOf6PZrrKWjvFEP16hAdj6DGTVSZLY6j
3s5k3k+mO67v8PbtdBpd5WY9qlQqS2oW6tV6q1LtVGr1qFrfb9X3q53tqv6JtqqdavXR1tbWkh6w
iXal2qiAOlGtYRO1xnZjd7fa6uxVa6oJCi1VRQ97+LfGotvfeGURbLFVhFygdag2/Hx6ikvyt8H4
erjoJ1Fxe3tnPOknO69xn3vjdI4dF3GD/BJE/Dk3UB/4SH6ecyKW6QA5hF/VWwknT4Ud4GSaf6uD
M99q11CIxQWIIqDLGGBuH+CD3MLjZxoFSgz85Uj90q8aSa9w92/JTf0vgR9uFoEmu44jzqFY63Bl
V7utsCxqzRGVgnltiVAUU1TEEhVNgZBvSZNbBb/NrUKm0S2WAIR0SJ/uMTvtfORxe8qBrbN2WUrJ
PbLzXTipdGZGIdFbmDQiP/jEc0Eq5FMSaKTwL5b4B7PdkZNAqrG7nqN08TxEJgZAjWYueTBJLlkw
yZuTA6cqkYFaJ6oDGWjtV6vbnd1Ou9rodDqCDNTxaHarbiLFG5T54Q4am9wBbr/0UvFlkzon8xXV
7AbY8lfz/o56hgSr6FgftoCbydtic+df5zvYX5J648AMdEPyx4fpeMcUk7O7IEnEtdgKL93ZDy9v
400J1Dc709ivt/Zbje1qs11v1qrtptiZZodC3ncMgTbELEv1i/qqfJadLd2eYFNbTlOmkrmND7wg
yxl1wMJGi8wbDTNsfRmHMQ0E5KTfnaazH0S3L+NxcuddwhHRr+TzBtoqiTc+ryn+YlnFpeQoWSiV
DGCYw6/HFJlZ0W8U/34REQXWW6Y/19BXbAulA/M+P/jHjyRNrTP4UohUveuN8fU8usjoYImf4aCJ
n7kxnoQakCQM2mhu1xvNarPRqtYlCevsIszhr8aeutblrBW7ilS+4ScEHyAwQOvf0OaWELnw7Zej
45+655enpydnF903J5fHB1Et80YLawy4RK9HfefJxcnUfXmHo10GX2HiexDBrM+DnnypZ2rCmLiv
9Ew3eAlnGoga7LysM3Xf++HQn+cXaGrs4rtNxyel517W4dmZyMJMdorFMCo6soW6qZ5JcgNGbB4u
glcvGzLikfLLwyU0cUxzHy/C7dJbFMeqzflcP0P2gp4hQ2tD24RxaJs4DujRqqrISBPLQk38cgdf
MDQ3HAfXCEWg8KPr/XmmkjNahhD//SZ+2ixAOL8JccUrMG+Pji/ffwdiEK1BDJTi0m4iuWt12uVa
569E7hTtiIfJTZpq03e3N50OB0l/+xqP41SeCRunMj9Q8kfn5phHCtVjYF0NiFQDvhEbNcWh3meD
X25zu1eZmf45faMBcBV3BH8RUJQxqA7fX5yAdHNKoNeu7yHotfFhKX3go0+u/hIgmN01JzAkb1zl
5c1gNhdb95fYNDSCUSvdmZxcsWzmg9MpxzQpoMOCjEZARzGOIq9A6Xlw/7NyomKdjogo0hzpUKRv
LBh6dYVM2Nzdr1e392qN6u7uXlWqtbV6i8xb8KveUJDK/jaApoNZdxbjoSoKJE/7U7Ree2+f0MvC
mKFcDYh0zPkVUkyvvOyrZ0iL28USU5OcbJNvclBvxRPVg4vuwdEZe4YqjexgMCPDwyCZAxXiY82Z
76oxV2Z70ZH0a/2Gca4IRxQYpL3nscEogy6OfOFpMRzSm9nNaqdtzk3UYTpKwpE9bhISm65mZDad
QFLbnB/S4RD0znikV1iMzYuWnqJH1gtzYe9xdN49Oof9gnLb87Q7wohPxhN44+nb6F7K7XZD2Nh0
1YXd37yxZl90U4DPb+Ps4uOBtU693PmTII6zNi9obc4Of3LvD38bzEcePIH4KV91WglF5kU9giGq
LcBHepgHC8AIEbhgUg5wGe8MbYAdpcrXA79Kuiz6mDi+HTGUM3da8eMZhvupYtigybCfzC5ue+OS
5/uxGOMTETRZHhTboJQRCkTOoDmHga2483ZwNevNvu68QnnpGvTVyTg6X0ynk1m6oy1EOydjfldC
mQBXW1x061eTSboz/zpPk9HOeDKu4EOeaCrY+dyb7QwHVzu/QRcpdFGZcBcauwSfNS817qC1hh4S
m0fUQP8qwkdK0VI8uYl0m3kz5RqZHtmJi6SjJiAQmyGsvUw8oCHSYIx0zDRJYYCXx0fvQRr4xyFZ
o/K57W2A2/omZJH+YG7rG5Gh4i6aKmvNdgcEwD1pqqzVdonbwi8jF7rBeWz8pnh/n9/n1OTs66uY
cer48u1bAr6Ls8tDCygV/fL76BMQIFW2uovu+vSGHyGfCZpJ3krQxuHh+6PzCya4S6sr7AyxGN1o
TFHaU1U3i7c+U1AqaeSvgTl1uHf2d57MUO5C/DjnP5VIFc5QOx3O3GC78xvQ54e1Npqnm/XtertV
r3b26lLCahBloAdLXev09nYWkvwjPi5wevt1SSbQjnf4ivcsdLrIZZxTPSdfOS9v3zoZYqriJLDT
auBUOq2m4Xgg++PyIKnEHjAEViD5bMEv6pJOuKQAVFdFtqgInyFNZsmhegTXyb2eLpT3aTjbmpTj
mu70ZjK7Ti6up2cY380dD3C0EZBmXM4Y6bFOX/SnmHY6uNa+sMksVmS/3qgRKas36nX94K44jJ8n
6TE/On3OzwvNY3ysfHxXjsbz7blOK2mmRP6G8+0UnyxYImE65YC5kjaCtvC4tMabJvBj68IY3qUL
bIxjpEIL/Bie64Gvjq+kN+X86/haWaLP08XNDbRRJvyV/wp/XMaFarNK2FBtVct149bJnAMXfpzc
qUadgGhuso5zhlW9HBtkbTEe/LpINmkwt5sl0QbHvJDs9b/phpgdkVGF0HoHxDkBXFK7sOL6Jamn
XXkJMzhncxczMEl1JdOJ6zmYVl5yTDuWjh7LkSlxG4o41l0QpkQhz/IrXQFFKRDUng2mwYsWbEGX
veoGQruu2xYh9rqDG5NcCENCTjYH3DOZH8QoPobiMV73ADXwKSzHM0hxNZO5LRbUJOKeyElav597
O4IwZLqXM8RFjJVA44DL9sg0DQCbgRc32wMYQ7ds3Mj1Ua6MW0/IEJqflerJ9cqglwkd+YxiShJd
adXp3fNGq1UXklWhkM6+WvFdRQqxZ4c6kjxnh0443JNGrTOLRNR4zNEusM3og3pe62PRPkeU5/PM
bxPdXWcilOT6Ph7/U7/sNZm+uDx1H/Qa9cgZEgg4OkCiJLaYv3jSj3pz9rvw7prkP9X17tXrGIZV
eYnvrYmniPRIS5mbQlQYD2pj88n9B0vqASl4JKYqdG/j4jYmD3jYdSfoJMDKEflTXSf0dNIUnxHs
OifIWdkAw2Wq02Z7v8aZJ26XmYUzZliyozfdd4cXZ0evw0fQ5wCab2bw58/6LFo5AdJzRdZx/9l4
AaNF3ZSzn45VAIAWH8022o16ud4SVwTO6ap7rWrakA8NL5EOHi4c2JsDpEr3FWU6vqO3Goxn01pA
SpUrKCq4kKruP20AmHIY5Shneua1IhfkrGyTB3iCc7jXu2S39HKVIc5uLAIyG1jK7ftyA+jOuyNR
QN3pmf5gHeS0pIg+YA6Fpvu52MI2kVc5JNEi2TOwrC6siCjfph+kKOvBOvSVdBngU4LxmGvN6+4x
jCd/m4kFbLbB/njDOy0X1BdHbQtaICVpX/0SNb/DBPto3Pivzu++tN1P0t71bfww2TxfNC+MfV1A
UUEru/8/LV9TuiLPAAA=
__ZT_HAIKU_PATCH_END__
__ZT_HAIKU_PATCH_ARCHIVE__
