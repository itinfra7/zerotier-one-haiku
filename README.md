# zerotier-one-haiku

## Keywords

Keywords: `#haiku #x86_64 #zerotier #vpn #networking #tap #ipv6 #userbootscript #watchdog #sshd #ldpreload #dhcp`

## Overview

This repository provides a reproducible build, installation, boot-time recovery, and address-family policy path for ZeroTier One 1.16.0 on Haiku R1/beta5 (`x86_64`).

The current installer expects `install-zerotier-one-haiku.sh` and the local `install-zerotier-one-haiku.files` asset directory to be present side by side. The release publishes the same installer asset files in that flat asset set.

## Target Profile

- Upstream version: ZeroTier One 1.16.0
- Upstream tag: `1.16.0`
- Release asset tag: `v1.1.2`
- Install media: `haiku-r1beta5-x86_64-anyboot.iso`
- Operating system: Haiku R1/beta5
- Architecture: `x86_64`
- Public interface assumption: `/dev/net/virtio/0`
- Boot integration: `UserBootscript`

## Quick Start

Open a Terminal session on Haiku before running the installer.

```sh
git clone https://github.com/itinfra7/zerotier-one-haiku.git
cd zerotier-one-haiku
chmod +x install-zerotier-one-haiku.sh
/bin/bash ./install-zerotier-one-haiku.sh
```

After install:

```sh
zerotier-cli join <network-id>
```

## Technical Design

The original `v1.0.0` release had a severe defect in its single-file release model. The first `v1.1.0` release switched to direct release assets, but it still shipped a malformed route-policy cache writer and did not include the pkgman IPv4 hosts workaround. The current `v1.1.2` release keeps the same asset set, changes the installer to consume those assets from the local `install-zerotier-one-haiku.files` directory, fixes supervisor PID tracking so daemonized parent exit is not misdetected as a crash, and changes the rendered `local.conf` default to `allowTcpFallbackRelay=false`.

The runtime design is broader than a normal package installer. `zerotier-boot-start.sh` acts as a supervisor that waits for public IPv4 plus a default route, starts ZeroTier, rejoins saved networks, refreshes the family-policy cache, and restarts the daemon when it dies. The supervisor adopts the real daemon PID from `zerotier-one.pid` so daemonization does not trigger a false restart and `9993` bind conflict. `public-net-watchdog.sh` separately repairs public-NIC DHCP failures by resetting `virtio/0`, re-running `auto-config`, and restarting `net_server` when needed, while isolating `sshd` listener handling from shutdown-time cleanup.

The family-policy fix is global. The installer ships `haiku-net-family-refresh.py` plus `libhaiku_net_family.so`, builds the preload library locally, and injects the environment into shell, desktop, and SSH entry points. That preload hook reorders `getaddrinfo()` results so ZeroTier destinations prefer the matching routed family, while general internet traffic prefers IPv4 when the host lacks a public IPv6 default route. The route-cache writer emits real line breaks, and the preload library still accepts older malformed cache entries that embedded literal `\n` text.

The Haiku hotfix set also addresses multi-network IPv6 correctness by removing the previous preferred-single-IPv6 behavior, reconciling on-link IPv6 routes for each tap, maintaining source-to-tap IPv6 ownership, and rerouting outbound IPv6 frames back to the correct tap when Haiku selects the wrong interface. The installer also installs `haiku-pkgman-ipv4-refresh.py`, which pins Haiku package repository hostnames to current IPv4 addresses in a managed hosts-file block so `pkgman` can work on systems that have ZeroTier IPv6 but no public IPv6 default route.

## Included Files

- `install-zerotier-one-haiku.sh` reads `zerotier-one-haiku-1.16.0.patch`, `local.conf.json`, `haiku-net-family-refresh.py`, `haiku-net-family-preload.c`, `apply-incremental-hotfixes.py`, and `haiku-pkgman-ipv4-refresh.py` from the local `install-zerotier-one-haiku.files` directory, downloads the official upstream source archive, applies the Haiku patch and incremental hotfixes, builds and installs ZeroTier, writes runtime configuration, installs the watchdog/launch/boot/keepalive helpers, installs the pkgman IPv4 hosts refresh helper, applies the global family-policy fix, updates `UserBootscript`, refreshes managed package-host IPv4 overrides, reloads `sshd` when required, and verifies stable `ONLINE`.
- `install-zerotier-one-haiku.files/zerotier-one-haiku-1.16.0.patch` is the main Haiku patch applied to the upstream ZeroTierOne source tree.
- `install-zerotier-one-haiku.files/apply-incremental-hotfixes.py` applies the post-patch Haiku IPv6 and tap-owner hotfixes that are intentionally kept separate from the large base patch.
- `install-zerotier-one-haiku.files/local.conf.json` is the `local.conf` template that the installer renders with the configured primary port.
- `install-zerotier-one-haiku.files/haiku-net-family-refresh.py` generates the route-policy cache consumed by the preload library.
- `install-zerotier-one-haiku.files/haiku-net-family-preload.c` is the preload source used to build `libhaiku_net_family.so`.
- `install-zerotier-one-haiku.files/haiku-pkgman-ipv4-refresh.py` manages IPv4-only hosts-file overrides for the Haiku package repository CDN endpoints.

## Workflow

1. Confirm the host is Haiku and verify the required tools: `awk`, `curl`, `gcc`, `g++`, `grep`, `ifconfig`, `make`, `nc`, `patch`, `ps`, `python3`, `sed`, and `tar`.
2. Read `zerotier-one-haiku-1.16.0.patch`, `local.conf.json`, `haiku-net-family-refresh.py`, `haiku-net-family-preload.c`, `apply-incremental-hotfixes.py`, and `haiku-pkgman-ipv4-refresh.py` from the local `install-zerotier-one-haiku.files` directory next to the installer.
3. Download the official ZeroTier One 1.16.0 source archive, or reuse a local source tree when `USE_LOCAL_SRC=1` is set.
4. Copy `zerotier-one-haiku-1.16.0.patch` from the local asset set, apply it to the upstream tree, and then run `apply-incremental-hotfixes.py`.
5. Build `zerotier-one` with `make OSTYPE=Haiku CC=gcc CXX=g++ clean` and `make OSTYPE=Haiku CC=gcc CXX=g++ one install`.
6. Install the runtime binaries and state layout under `/boot/system/non-packaged`, then render `local.conf` with `primaryPort=9993`, `allowSecondaryPort=false`, `portMappingEnabled=false`, and `allowTcpFallbackRelay=false`.
7. Install `zerotier-boot-start.sh`, `public-net-watchdog.sh`, `zerotier-launch.sh`, and `zerotier-keepalive.sh`.
8. Install `haiku-pkgman-ipv4-refresh.py`, write or refresh the managed IPv4 host override block in `/boot/system/settings/network/hosts`, and let the watchdog refresh those host entries whenever public networking returns.
9. Build and install the global family-policy stack: `haiku-net-family-refresh.py`, `libhaiku_net_family.so`, `/boot/home/config/settings/haiku-net-family-routes.conf`, shell profile blocks, desktop launch env, and managed `sshd_config` environment.
10. Update `/boot/home/config/settings/boot/UserBootscript` so the public-network watchdog and delayed ZeroTier launch start automatically at boot.
11. Remove legacy wrapper files, stop previous ZeroTier/helper processes, clear stale `tap/*` interfaces, and reload `sshd` when the managed SSH environment changed.
12. Start the new boot supervisor immediately, wait until `zerotier-cli info` reports stable `ONLINE`, and then leave the machine ready for `zerotier-cli join <network-id>`.

## Credits

[ZeroTier, Inc.](https://www.zerotier.com/) and the [ZeroTierOne](https://github.com/zerotier/ZeroTierOne) project provide the upstream source code and versioning.

[Haiku](https://www.haiku-os.org/) provides the target operating system and runtime environment validated by this repository.

[itinfra7](https://github.com/itinfra7) is credited for the Haiku patch set, incremental IPv6 hotfixes, pkgman IPv4 fallback workaround, release asset packaging, public-NIC watchdog design, ZeroTier boot supervision, family-policy preload workflow, and repository packaging behind this release.
