#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ZT_VERSION="${ZT_VERSION:-1.16.0}"
USE_LOCAL_SRC="${USE_LOCAL_SRC:-0}"
LOCAL_SRC_DIR="${LOCAL_SRC_DIR:-$SCRIPT_DIR/zerotier-one-$ZT_VERSION}"
SOURCE_URL="${SOURCE_URL:-https://github.com/zerotier/ZeroTierOne/archive/refs/tags/${ZT_VERSION}.tar.gz}"
WORK_ROOT="${WORK_ROOT:-/boot/home/zerotier-build}"
BUILD_ROOT="${BUILD_ROOT:-$WORK_ROOT/ZeroTierOne-$ZT_VERSION}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_ROOT/ZeroTierOne-$ZT_VERSION.tar.gz}"
PATCH_PATH="${PATCH_PATH:-$WORK_ROOT/zerotier-one-haiku-$ZT_VERSION.patch}"
ASSET_DIR="${ASSET_DIR:-$SCRIPT_DIR/install-zerotier-one-haiku.files}"
PATCH_SOURCE_PATH="${PATCH_SOURCE_PATH:-$ASSET_DIR/zerotier-one-haiku-$ZT_VERSION.patch}"
LOCAL_CONF_TEMPLATE_PATH="${LOCAL_CONF_TEMPLATE_PATH:-$ASSET_DIR/local.conf.json}"
POLICY_REFRESH_TEMPLATE_PATH="${POLICY_REFRESH_TEMPLATE_PATH:-$ASSET_DIR/haiku-net-family-refresh.py}"
PRELOAD_SOURCE_TEMPLATE_PATH="${PRELOAD_SOURCE_TEMPLATE_PATH:-$ASSET_DIR/haiku-net-family-preload.c}"
HOTFIX_SCRIPT_PATH="${HOTFIX_SCRIPT_PATH:-$ASSET_DIR/apply-incremental-hotfixes.py}"
PKGMAN_IPV4_REFRESH_TEMPLATE_PATH="${PKGMAN_IPV4_REFRESH_TEMPLATE_PATH:-$ASSET_DIR/haiku-pkgman-ipv4-refresh.py}"
STATE_DIR="${STATE_DIR:-/boot/system/non-packaged/var/lib/zerotier-one}"
BIN_DIR="${BIN_DIR:-/boot/system/non-packaged/bin}"
USER_BIN_DIR="${USER_BIN_DIR:-/boot/home/config/non-packaged/bin}"
USER_LIB_DIR="${USER_LIB_DIR:-/boot/home/config/non-packaged/lib}"
POLICY_STATE_FILE="${POLICY_STATE_FILE:-/boot/home/config/settings/haiku-net-family-routes.conf}"
POLICY_REFRESH_PATH="${POLICY_REFRESH_PATH:-$BIN_DIR/haiku-net-family-refresh.py}"
POLICY_PRELOAD_LIB="${POLICY_PRELOAD_LIB:-$USER_LIB_DIR/libhaiku_net_family.so}"
PKGMAN_IPV4_REFRESH_PATH="${PKGMAN_IPV4_REFRESH_PATH:-$BIN_DIR/haiku-pkgman-ipv4-refresh.py}"
PKGMAN_HOSTS_PATH="${PKGMAN_HOSTS_PATH:-/boot/system/settings/network/hosts}"
DESKTOP_ENV_FILE="${DESKTOP_ENV_FILE:-/boot/home/config/settings/launch/haiku-net-family-env}"
PROFILE_PATH="${PROFILE_PATH:-/boot/home/config/settings/profile}"
BASH_DOT_PROFILE_PATH="${BASH_DOT_PROFILE_PATH:-/boot/home/.bash_profile}"
BASH_PROFILE_PATH="${BASH_PROFILE_PATH:-/boot/home/.profile}"
BASH_RC_PATH="${BASH_RC_PATH:-/boot/home/.bashrc}"
SSHD_CONFIG_PATH="${SSHD_CONFIG_PATH:-/boot/system/settings/ssh/sshd_config}"
NET_FAMILY_POLICY_MODE="${NET_FAMILY_POLICY_MODE:-yes}"
PRIMARY_PORT="${PRIMARY_PORT:-9993}"
KEEPALIVE_INTERVAL_SECONDS="${KEEPALIVE_INTERVAL_SECONDS:-20}"
BOOT_LAUNCH_DELAY_SECONDS="${BOOT_LAUNCH_DELAY_SECONDS:-1}"
PUBLIC_NET_WATCHDOG_INITIAL_GRACE_SECONDS="${PUBLIC_NET_WATCHDOG_INITIAL_GRACE_SECONDS:-1}"
PUBLIC_NET_WATCHDOG_RETRY_WAIT_SECONDS="${PUBLIC_NET_WATCHDOG_RETRY_WAIT_SECONDS:-5}"
PUBLIC_NET_WATCHDOG_POLL_SECONDS="${PUBLIC_NET_WATCHDOG_POLL_SECONDS:-1}"
PUBLIC_NET_WATCHDOG_MAX_RETRIES="${PUBLIC_NET_WATCHDOG_MAX_RETRIES:-10}"
PUBLIC_NET_WATCHDOG_CONTROL_TIMEOUT_SECONDS="${PUBLIC_NET_WATCHDOG_CONTROL_TIMEOUT_SECONDS:-2}"
BOOT_MARKER_BEGIN="# BEGIN HAIKU ZEROTIER AUTO START"
BOOT_MARKER_END="# END HAIKU ZEROTIER AUTO START"
PROFILE_MARKER_BEGIN="# BEGIN HAIKU NET FAMILY POLICY"
PROFILE_MARKER_END="# END HAIKU NET FAMILY POLICY"
SSHD_ENV_MARKER_BEGIN="# BEGIN HAIKU NET FAMILY SSHD ENV"
SSHD_ENV_MARKER_END="# END HAIKU NET FAMILY SSHD ENV"
PKGMAN_HOSTS_MARKER_BEGIN="# BEGIN HAIKU PKGMAN IPV4 HOSTS"
PKGMAN_HOSTS_MARKER_END="# END HAIKU PKGMAN IPV4 HOSTS"

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

extract_quoted_assignment() {
	local file_path="$1"
	local variable_name="$2"

	[ -f "$file_path" ] || return 1
	awk -F'"' -v key="$variable_name" '$1 ~ ("^" key "=") { print $2; exit }' "$file_path"
}

extract_sleep_value() {
	local file_path="$1"

	[ -f "$file_path" ] || return 1
	awk '$1 == "sleep" { value = $2; gsub(/"/, "", value); print value; exit }' "$file_path"
}

reuse_existing_runtime_tuning() {
	local value

	if value="$(extract_sleep_value "$BIN_DIR/zerotier-launch.sh" 2>/dev/null)" && [ -n "$value" ]; then
		BOOT_LAUNCH_DELAY_SECONDS="$value"
	fi
	if value="$(extract_quoted_assignment "$BIN_DIR/public-net-watchdog.sh" "initial_grace" 2>/dev/null)" && [ -n "$value" ]; then
		PUBLIC_NET_WATCHDOG_INITIAL_GRACE_SECONDS="$value"
	fi
	if value="$(extract_quoted_assignment "$BIN_DIR/public-net-watchdog.sh" "retry_wait" 2>/dev/null)" && [ -n "$value" ]; then
		PUBLIC_NET_WATCHDOG_RETRY_WAIT_SECONDS="$value"
	fi
	if value="$(extract_quoted_assignment "$BIN_DIR/public-net-watchdog.sh" "poll_seconds" 2>/dev/null)" && [ -n "$value" ]; then
		PUBLIC_NET_WATCHDOG_POLL_SECONDS="$value"
	fi
	if value="$(extract_quoted_assignment "$BIN_DIR/public-net-watchdog.sh" "max_retries" 2>/dev/null)" && [ -n "$value" ]; then
		PUBLIC_NET_WATCHDOG_MAX_RETRIES="$value"
	fi
	if value="$(extract_quoted_assignment "$BIN_DIR/public-net-watchdog.sh" "control_timeout" 2>/dev/null)" && [ -n "$value" ]; then
		PUBLIC_NET_WATCHDOG_CONTROL_TIMEOUT_SECONDS="$value"
	fi
}

remove_marked_block() {
	local target_path="$1"
	local marker_begin="$2"
	local marker_end="$3"
	local tmp_path

	[ -e "$target_path" ] || return 0

	tmp_path="${target_path}.tmp.$$"
	awk -v begin="$marker_begin" -v end="$marker_end" '
BEGIN { skip = 0 }
$0 == begin { skip = 1; next }
$0 == end { skip = 0; next }
skip { next }
{ print }
' "$target_path" >"$tmp_path"
	mv "$tmp_path" "$target_path"
}

render_template_file() {
	local template_path="$1"
	local output_path="$2"
	shift 2
	python3 - "$template_path" "$output_path" "$@" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
text = template_path.read_text()
for item in sys.argv[3:]:
    key, value = item.split('=', 1)
    text = text.replace(f'@{key}@', value)
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(text)
PY
}

copy_asset_file() {
	local source_path="$1"
	local output_path="$2"
	mkdir -p "$(dirname "$output_path")"
	cp "$source_path" "$output_path"
}


resolve_family_policy_mode() {
	local answer=""

	case "$NET_FAMILY_POLICY_MODE" in
		1|yes|true|on|enable|enabled)
			NET_FAMILY_POLICY_MODE="yes"
			return 0
			;;
		0|no|false|off|disable|disabled)
			NET_FAMILY_POLICY_MODE="no"
			return 0
			;;
		auto|"")
			NET_FAMILY_POLICY_MODE="yes"
			return 0
			;;
		*)
			fail "unsupported NET_FAMILY_POLICY_MODE: $NET_FAMILY_POLICY_MODE"
			;;
	esac
}

cleanup_running_zerotier() {
	for tid in $({ ps | grep '/boot/system/non-packaged/bin/public-net-watchdog.sh' | grep -v grep | awk '{ print $(NF-3) }'; } || true); do
		kill -9 "$tid" 2>/dev/null || true
	done
	for tid in $({ ps | grep '/boot/system/non-packaged/bin/zerotier-launch.sh' | grep -v grep | awk '{ print $(NF-3) }'; } || true); do
		kill -9 "$tid" 2>/dev/null || true
	done
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
	[ -f "$LOCAL_CONF_TEMPLATE_PATH" ] || fail "missing local.conf template: $LOCAL_CONF_TEMPLATE_PATH"
	render_template_file "$LOCAL_CONF_TEMPLATE_PATH" "$STATE_DIR/local.conf" PRIMARY_PORT="$PRIMARY_PORT"
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
route_refresh_path="/boot/system/non-packaged/bin/haiku-net-family-refresh.py"
monitor_ticks=0

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
	while [ "$i" -lt 120 ]; do
		if ps | grep net_server | grep -v grep >/dev/null 2>&1 && have_public_ipv4 && have_default_route; then
			return 0
		fi
		i=$((i + 1))
		sleep 5
	done
	return 1
}

refresh_family_policy_cache() {
	if [ -x "$route_refresh_path" ]; then
		"$route_refresh_path" >/tmp/haiku-net-family-refresh.out 2>/tmp/haiku-net-family-refresh.err || true
	fi
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

stop_children_for_shutdown() {
	kill_path '/boot/system/non-packaged/bin/zerotier-keepalive.sh' -9
	kill_path '/boot/system/non-packaged/bin/zerotier-cli' -9
	if [ -n "$zt_pid" ] && kill -0 "$zt_pid" 2>/dev/null; then
		kill -9 "$zt_pid" 2>/dev/null || true
	fi
	kill_path '/boot/system/non-packaged/bin/zerotier-one' -9
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

daemon_pid_from_state() {
	pidfile="$state_dir/zerotier-one.pid"
	if [ -r "$pidfile" ]; then
		pid=$(cat "$pidfile" 2>/dev/null || true)
		case "$pid" in
			''|*[!0-9]*) ;;
			*)
				if kill -0 "$pid" 2>/dev/null; then
					printf '%s\n' "$pid"
					return 0
				fi
				;;
		esac
	fi

	for tid in $(pid_list_for_path '/boot/system/non-packaged/bin/zerotier-one'); do
		printf '%s\n' "$tid"
		return 0
	done
	return 1
}

adopt_daemon_pid() {
	i=0
	while [ "$i" -lt 10 ]; do
		pid=$(daemon_pid_from_state || true)
		if [ -n "$pid" ]; then
			zt_pid="$pid"
			log "tracking zerotier-one daemon pid=\$zt_pid"
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
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
	if ! adopt_daemon_pid; then
		log "could not determine zerotier-one daemon pid attempt=$attempt"
	fi
	start_keepalive

	if wait_for_stable_online; then
		log "node stable-online attempt=$attempt"
	else
		log "node did not reach stable ONLINE before join attempt=$attempt"
	fi

	sleep 1
	join_configured_networks

	if wait_for_configured_networks; then
		refresh_family_policy_cache
		log "configured networks visible attempt=$attempt"
		return 0
	fi

	log "configured networks not visible attempt=$attempt"
	return 1
}

monitor_cycle() {
	while [ "$shutdown_requested" -eq 0 ]; do
		current_pid=$(daemon_pid_from_state || true)
		if [ -z "$current_pid" ] && [ -n "$zt_pid" ] && kill -0 "$zt_pid" 2>/dev/null; then
			current_pid="$zt_pid"
		fi
		if [ -n "$current_pid" ]; then
			zt_pid="$current_pid"
			monitor_ticks=$((monitor_ticks + 1))
			if [ $((monitor_ticks % 3)) -eq 0 ]; then
				refresh_family_policy_cache
			fi
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
	log "shutdown signal received; stopping zerotier for reboot"
	stop_children_for_shutdown
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

refresh_family_policy_cache

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

write_public_net_watchdog() {
	mkdir -p "$BIN_DIR"
	cat >"$BIN_DIR/public-net-watchdog.sh" <<EOF
#!/bin/sh
set -eu

public_device="/dev/net/virtio/0"
lock_dir="/tmp/public-net-watchdog.lock"
log_file="/tmp/public-net-watchdog.log"
initial_grace="${PUBLIC_NET_WATCHDOG_INITIAL_GRACE_SECONDS}"
retry_wait="${PUBLIC_NET_WATCHDOG_RETRY_WAIT_SECONDS}"
poll_seconds="${PUBLIC_NET_WATCHDOG_POLL_SECONDS}"
max_retries="${PUBLIC_NET_WATCHDOG_MAX_RETRIES}"
control_timeout="${PUBLIC_NET_WATCHDOG_CONTROL_TIMEOUT_SECONDS}"
net_server_path="/boot/system/servers/net_server"
shutdown_requested=0
child_pid=""
sshd_path="/boot/system/bin/sshd"
sshd_stopped=0
pkgman_ipv4_refresh_path="/boot/system/non-packaged/bin/haiku-pkgman-ipv4-refresh.py"

log() {
	printf '[public-net-watchdog] %s\n' "\$*" >> "\$log_file"
}

have_public_ipv4() {
	ifconfig "\$public_device" 2>/dev/null | grep -q 'inet addr: [0-9]'
}

have_default_route() {
	route list 2>/dev/null | grep -Eq '(^default|^[[:space:]]*0\.0\.0\.0[[:space:]]+0\.0\.0\.0)'
}

boot_network_ready() {
	have_public_ipv4 && have_default_route
}

pid_list_for_path() {
	path="\$1"
	{ ps | grep "\$path" | grep -v grep | awk '{ print \$(NF-3) }'; } || true
}

net_server_running() {
	ps | grep '/boot/system/servers/net_server' | grep -v grep >/dev/null 2>&1
}

sshd_listener_pids() {
	{ ps | grep '^/boot/system/bin/sshd -D' | grep -v grep | awk '{ print \$(NF-3) }'; } || true
}

sshd_running() {
	ps | grep '^/boot/system/bin/sshd -D' | grep -v grep >/dev/null 2>&1
}

refresh_pkgman_ipv4_hosts() {
	if [ -x "\$pkgman_ipv4_refresh_path" ]; then
		"\$pkgman_ipv4_refresh_path" >/tmp/haiku-pkgman-ipv4-refresh.out 2>/tmp/haiku-pkgman-ipv4-refresh.err || true
	fi
}

acquire_lock() {
	if mkdir "\$lock_dir" 2>/dev/null; then
		printf '%s\n' "\$\$" > "\$lock_dir/pid"
		return 0
	fi

	if [ -r "\$lock_dir/pid" ]; then
		other_pid=\$(cat "\$lock_dir/pid" 2>/dev/null || true)
		if [ -n "\$other_pid" ] && kill -0 "\$other_pid" 2>/dev/null; then
			log "another watchdog is already running pid=\$other_pid"
			return 1
		fi
	fi

	rm -rf "\$lock_dir"
	mkdir "\$lock_dir"
	printf '%s\n' "\$\$" > "\$lock_dir/pid"
}

release_lock() {
	rm -rf "\$lock_dir"
}

kill_child() {
	if [ -n "\$child_pid" ] && kill -0 "\$child_pid" 2>/dev/null; then
		kill "\$child_pid" 2>/dev/null || true
		sleep 1
		kill -9 "\$child_pid" 2>/dev/null || true
		wait "\$child_pid" 2>/dev/null || true
	fi
	child_pid=""
}

wait_for_network() {
	limit="\$1"
	elapsed=0
	while [ "\$elapsed" -lt "\$limit" ]; do
		if [ "\$shutdown_requested" -eq 1 ]; then
			return 1
		fi
		if boot_network_ready; then
			return 0
		fi
		sleep "\$poll_seconds"
		elapsed=\$((elapsed + poll_seconds))
	done
	return 1
}

ensure_net_server_running() {
	if ! net_server_running && [ -x "\$net_server_path" ]; then
		"\$net_server_path" >/tmp/public-net-watchdog-net-server.out 2>/tmp/public-net-watchdog-net-server.err </dev/null &
	fi
}

wait_for_net_server_ready() {
	limit="\$1"
	elapsed=0
	while [ "\$elapsed" -lt "\$limit" ]; do
		if [ "\$shutdown_requested" -eq 1 ]; then
			return 1
		fi
		if net_server_running; then
			return 0
		fi
		sleep 1
		elapsed=\$((elapsed + 1))
	done
	return 1
}

stop_sshd_listener() {
	if [ "\$sshd_stopped" -eq 1 ]; then
		return 0
	fi
	if ! sshd_running; then
		return 0
	fi
	log "stopping sshd before network recovery"
	for tid in \$(sshd_listener_pids); do
		kill "\$tid" 2>/dev/null || true
	done
	sleep 1
	for tid in \$(sshd_listener_pids); do
		kill -9 "\$tid" 2>/dev/null || true
	done
	sshd_stopped=1
}

start_sshd_listener() {
	if [ "\$sshd_stopped" -ne 1 ]; then
		return 0
	fi
	if [ ! -x "\$sshd_path" ]; then
		return 0
	fi
	log "starting sshd after network recovery"
	"\$sshd_path" >/tmp/public-net-watchdog-sshd.out 2>/tmp/public-net-watchdog-sshd.err </dev/null || true
	sshd_stopped=0
}

run_with_timeout() {
	timeout_seconds="\$1"
	shift

	"\$@" >/tmp/public-net-watchdog-cmd.out 2>/tmp/public-net-watchdog-cmd.err &
	cmd_pid=\$!
	child_pid="\$cmd_pid"
	elapsed=0

	while kill -0 "\$cmd_pid" 2>/dev/null; do
		if [ "\$shutdown_requested" -eq 1 ]; then
			kill_child
			return 1
		fi
		if [ "\$elapsed" -ge "\$timeout_seconds" ]; then
			kill "\$cmd_pid" 2>/dev/null || true
			sleep 1
			kill -9 "\$cmd_pid" 2>/dev/null || true
			wait "\$cmd_pid" 2>/dev/null || true
			child_pid=""
			return 124
		fi
		sleep 1
		elapsed=\$((elapsed + 1))
	done

	wait "\$cmd_pid" 2>/dev/null || {
		child_pid=""
		return \$?
	}
	child_pid=""
	return 0
}

reset_interface() {
	log "resetting interface state"
	run_with_timeout "\$control_timeout" ifconfig "\$public_device" down || true
	sleep 1
	run_with_timeout "\$control_timeout" ifconfig "\$public_device" up || true
	sleep 1
}

trigger_autoconfig() {
	log "triggering DHCP auto-config"
	ensure_net_server_running
	wait_for_net_server_ready "\$control_timeout" || true
	run_with_timeout "\$retry_wait" ifconfig "\$public_device" auto-config up || true
}

restart_net_server() {
	log "restarting net_server"
	kill net_server 2>/dev/null || true
	sleep 1
	ensure_net_server_running
	wait_for_net_server_ready "\$retry_wait" || true
}

handle_shutdown() {
	shutdown_requested=1
	log "shutdown signal received; stopping watchdog cleanly"
	kill_child
	exit 0
}

handle_exit() {
	kill_child
	if [ "\$shutdown_requested" -eq 0 ]; then
		start_sshd_listener
	fi
	release_lock
}

trap 'handle_shutdown' INT TERM HUP QUIT
trap 'handle_exit' EXIT

: > "\$log_file"
if ! acquire_lock; then
	exit 0
fi

if boot_network_ready; then
	log "public network already ready"
	refresh_pkgman_ipv4_hosts
	exit 0
fi

log "waiting for stock DHCP during initial grace"
if wait_for_network "\$initial_grace"; then
	log "public network became ready without intervention"
	refresh_pkgman_ipv4_hosts
	exit 0
fi

attempt=1
while [ "\$attempt" -le "\$max_retries" ]; do
	if [ "\$shutdown_requested" -eq 1 ]; then
		exit 0
	fi
	log "public network still missing; recovery attempt=\$attempt interface reset"
	stop_sshd_listener
	ensure_net_server_running
	reset_interface
	trigger_autoconfig
	if wait_for_network "\$retry_wait"; then
		log "public network restored after interface reset attempt=\$attempt"
		refresh_pkgman_ipv4_hosts
		start_sshd_listener
		exit 0
	fi

	log "public network still missing; recovery attempt=\$attempt net_server restart"
	restart_net_server
	trigger_autoconfig
	if wait_for_network "\$retry_wait"; then
		log "public network restored after net_server restart attempt=\$attempt"
		refresh_pkgman_ipv4_hosts
		start_sshd_listener
		exit 0
	fi
	attempt=\$((attempt + 1))
done

log "public network is still unavailable after all retries"
start_sshd_listener
exit 0
EOF
	chmod 755 "$BIN_DIR/public-net-watchdog.sh"
}

write_launch_helper() {
	mkdir -p "$BIN_DIR"
	cat >"$BIN_DIR/zerotier-launch.sh" <<EOF
#!/bin/sh
set -eu

sleep "$BOOT_LAUNCH_DELAY_SECONDS"
exec /bin/sh /boot/system/non-packaged/bin/zerotier-boot-start.sh
EOF
	chmod 755 "$BIN_DIR/zerotier-launch.sh"
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

cleanup_legacy_client_family_wrappers() {
	rm -f "$USER_BIN_DIR/ping"
	rm -f "$USER_BIN_DIR/ssh"
	rm -f "$USER_BIN_DIR/haiku-net-family-policy.py"
}

write_family_policy_refresh_helper() {
	[ -f "$POLICY_REFRESH_TEMPLATE_PATH" ] || fail "missing family policy refresh template: $POLICY_REFRESH_TEMPLATE_PATH"
	render_template_file "$POLICY_REFRESH_TEMPLATE_PATH" "$POLICY_REFRESH_PATH" POLICY_STATE_FILE="$POLICY_STATE_FILE"
	chmod 755 "$POLICY_REFRESH_PATH"
}

write_pkgman_ipv4_refresh_helper() {
	[ -f "$PKGMAN_IPV4_REFRESH_TEMPLATE_PATH" ] || fail "missing pkgman IPv4 refresh template: $PKGMAN_IPV4_REFRESH_TEMPLATE_PATH"
	render_template_file \
		"$PKGMAN_IPV4_REFRESH_TEMPLATE_PATH" \
		"$PKGMAN_IPV4_REFRESH_PATH" \
		PKGMAN_HOSTS_PATH="$PKGMAN_HOSTS_PATH" \
		PKGMAN_HOSTS_MARKER_BEGIN="$PKGMAN_HOSTS_MARKER_BEGIN" \
		PKGMAN_HOSTS_MARKER_END="$PKGMAN_HOSTS_MARKER_END"
	chmod 755 "$PKGMAN_IPV4_REFRESH_PATH"
}

write_family_policy_preload_library() {
	local source_path="$WORK_ROOT/haiku-net-family-preload.c"

	[ -f "$PRELOAD_SOURCE_TEMPLATE_PATH" ] || fail "missing preload source template: $PRELOAD_SOURCE_TEMPLATE_PATH"
	mkdir -p "$WORK_ROOT" "$USER_LIB_DIR"
	render_template_file "$PRELOAD_SOURCE_TEMPLATE_PATH" "$source_path" POLICY_STATE_FILE="$POLICY_STATE_FILE"
	gcc -shared -fPIC -O2 -o "$POLICY_PRELOAD_LIB" "$source_path" -lnetwork
}

install_family_env_block() {
	local target_path="$1"
	local tmp_profile="${target_path}.tmp.$$"

	mkdir -p "$(dirname "$target_path")"
	touch "$target_path"

	awk -v begin="$PROFILE_MARKER_BEGIN" -v end="$PROFILE_MARKER_END" '
BEGIN { skip = 0 }
$0 == begin { skip = 1; next }
$0 == end { skip = 0; next }
skip { next }
{ print }
' "$target_path" >"$tmp_profile"

	cat >>"$tmp_profile" <<EOF

$PROFILE_MARKER_BEGIN
haiku_net_family_preload="$POLICY_PRELOAD_LIB"
case ":\${LD_PRELOAD:-}:" in
	*":\$haiku_net_family_preload:"*) ;;
	"::") export LD_PRELOAD="\$haiku_net_family_preload" ;;
	*) export LD_PRELOAD="\$haiku_net_family_preload:\${LD_PRELOAD}" ;;
esac
export HAIKU_NET_FAMILY_POLICY_FILE="$POLICY_STATE_FILE"
$PROFILE_MARKER_END
EOF

	mv "$tmp_profile" "$target_path"
}

install_shell_family_policy() {
	install_family_env_block "$PROFILE_PATH"
	install_family_env_block "$BASH_DOT_PROFILE_PATH"
	install_family_env_block "$BASH_PROFILE_PATH"
	install_family_env_block "$BASH_RC_PATH"
}

remove_shell_family_policy() {
	remove_marked_block "$PROFILE_PATH" "$PROFILE_MARKER_BEGIN" "$PROFILE_MARKER_END"
	remove_marked_block "$BASH_DOT_PROFILE_PATH" "$PROFILE_MARKER_BEGIN" "$PROFILE_MARKER_END"
	remove_marked_block "$BASH_PROFILE_PATH" "$PROFILE_MARKER_BEGIN" "$PROFILE_MARKER_END"
	remove_marked_block "$BASH_RC_PATH" "$PROFILE_MARKER_BEGIN" "$PROFILE_MARKER_END"
}

write_desktop_family_policy() {
	mkdir -p "$(dirname "$DESKTOP_ENV_FILE")"
	cat >"$DESKTOP_ENV_FILE" <<EOF
target desktop {
	env {
		LD_PRELOAD $POLICY_PRELOAD_LIB
		HAIKU_NET_FAMILY_POLICY_FILE $POLICY_STATE_FILE
	}
}
EOF
}

install_sshd_family_policy() {
	local tmp_config="${SSHD_CONFIG_PATH}.tmp.$$"

	mkdir -p "$(dirname "$SSHD_CONFIG_PATH")"
	touch "$SSHD_CONFIG_PATH"

	awk -v begin="$SSHD_ENV_MARKER_BEGIN" -v end="$SSHD_ENV_MARKER_END" '
BEGIN { skip = 0 }
$0 == begin { skip = 1; next }
$0 == end { skip = 0; next }
skip { next }
{ print }
' "$SSHD_CONFIG_PATH" >"$tmp_config"

	cat >>"$tmp_config" <<EOF

$SSHD_ENV_MARKER_BEGIN
SetEnv LD_PRELOAD=$POLICY_PRELOAD_LIB HAIKU_NET_FAMILY_POLICY_FILE=$POLICY_STATE_FILE
$SSHD_ENV_MARKER_END
EOF

	/bin/sshd -t -f "$tmp_config" >/dev/null 2>&1 || fail "sshd config validation failed"
	mv "$tmp_config" "$SSHD_CONFIG_PATH"
}

sshd_family_policy_present() {
	[ -f "$SSHD_CONFIG_PATH" ] && grep -F "$SSHD_ENV_MARKER_BEGIN" "$SSHD_CONFIG_PATH" >/dev/null 2>&1
}

remove_sshd_family_policy() {
	remove_marked_block "$SSHD_CONFIG_PATH" "$SSHD_ENV_MARKER_BEGIN" "$SSHD_ENV_MARKER_END"
}

remove_desktop_family_policy() {
	rm -f "$DESKTOP_ENV_FILE"
}

remove_family_policy_artifacts() {
	remove_shell_family_policy
	remove_desktop_family_policy
	remove_sshd_family_policy
	rm -f "$POLICY_PRELOAD_LIB" "$POLICY_REFRESH_PATH" "$POLICY_STATE_FILE"
}

refresh_pkgman_ipv4_hosts_now() {
	if [ -x "$PKGMAN_IPV4_REFRESH_PATH" ]; then
		"$PKGMAN_IPV4_REFRESH_PATH" >/tmp/haiku-pkgman-ipv4-refresh.out 2>/tmp/haiku-pkgman-ipv4-refresh.err || true
	fi
}

restart_sshd_listener() {
	for tid in $({ ps | grep '^/boot/system/bin/sshd -D' | grep -v grep | awk '{ print $(NF-3) }'; } || true); do
		kill "$tid" 2>/dev/null || true
	done
	sleep 1
	/bin/sshd
}

write_patch_asset() {
	[ -f "$PATCH_SOURCE_PATH" ] || fail "missing patch asset: $PATCH_SOURCE_PATH"
	mkdir -p "$WORK_ROOT"
	cp "$PATCH_SOURCE_PATH" "$PATCH_PATH"
	[ -s "$PATCH_PATH" ] || fail "failed to prepare Haiku patch asset"
}

apply_incremental_hotfixes() {
	[ -f "$HOTFIX_SCRIPT_PATH" ] || fail "missing incremental hotfix script: $HOTFIX_SCRIPT_PATH"
	python3 "$HOTFIX_SCRIPT_PATH" "$BUILD_ROOT"
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
		log "downloading source archive: $SOURCE_URL"
		curl -L --fail -o "$ARCHIVE_PATH" "$SOURCE_URL"

		log "extracting source archive"
		rm -rf "$BUILD_ROOT"
		tar -C "$WORK_ROOT" -xf "$ARCHIVE_PATH"
		[ -d "$BUILD_ROOT" ] || fail "extracted source directory missing: $BUILD_ROOT"

		log "copying Haiku patch asset"
		write_patch_asset

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
if ! ps | grep '/boot/system/non-packaged/bin/public-net-watchdog.sh' | grep -v grep >/dev/null 2>&1; then
	/bin/sh /boot/system/non-packaged/bin/public-net-watchdog.sh >/tmp/public-net-watchdog-run.out 2>/tmp/public-net-watchdog-run.err </dev/null &
fi
if ! ps | grep '/boot/system/non-packaged/bin/zerotier-one' | grep -v grep >/dev/null 2>&1; then
	/bin/sh /boot/system/non-packaged/bin/zerotier-launch.sh >/tmp/zerotier-boot-start-run.out 2>/tmp/zerotier-boot-start-run.err </dev/null &
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
	local sshd_reload_required=0

	[ "$(uname -s)" = "Haiku" ] || fail "this script must run on Haiku"

	need_cmd awk
	need_cmd curl
	need_cmd gcc
	need_cmd g++
	need_cmd grep
	need_cmd ifconfig
	need_cmd make
	need_cmd nc
	need_cmd patch
	need_cmd ps
	need_cmd python3
	need_cmd sed
	need_cmd tar

	prepare_source_tree

	log "building zerotier-one"
	cd "$BUILD_ROOT"
	make OSTYPE=Haiku CC=gcc CXX=g++ clean
	make OSTYPE=Haiku CC=gcc CXX=g++ one install

	log "writing runtime configuration"
	write_local_conf

	log "installing boot helpers"
	reuse_existing_runtime_tuning
	write_boot_helper
	write_public_net_watchdog
	write_launch_helper
	write_keepalive_helper
	write_pkgman_ipv4_refresh_helper
	cleanup_legacy_client_family_wrappers

	resolve_family_policy_mode
	if [ "$NET_FAMILY_POLICY_MODE" = "yes" ]; then
		log "installing global network family policy fix"
		write_family_policy_refresh_helper
		write_family_policy_preload_library
		install_shell_family_policy
		write_desktop_family_policy
		install_sshd_family_policy
		sshd_reload_required=1
	else
		log "skipping global network family policy fix"
		if sshd_family_policy_present; then
			sshd_reload_required=1
		fi
		remove_family_policy_artifacts
	fi

	log "registering boot autostart"
	register_boot_autostart
	refresh_pkgman_ipv4_hosts_now

	if [ "$sshd_reload_required" -eq 1 ]; then
		log "reloading sshd listener"
		restart_sshd_listener
	fi

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
