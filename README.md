# zerotier-one-haiku

ZeroTier One 1.16.0 installer, runtime supervisors, and release asset set for Haiku R1/beta5 (`x86_64`).

## Keywords

Keywords: `#haiku #x86_64 #zerotier #vpn #networking #tap #ipv6 #userbootscript #watchdog #sshd #ldpreload #dhcp`

## Overview

This repository provides a reproducible build, installation, boot-time recovery, and address-family policy path for ZeroTier One 1.16.0 on Haiku R1/beta5 (`x86_64`).

The `v1.1.0` installer is intentionally no longer a self-contained patch blob. The user downloads only `install-zerotier-one-haiku.sh`, and that script immediately downloads the release assets `zerotier-one-haiku-1.16.0.patch`, `local.conf.json`, `haiku-net-family-refresh.py`, `haiku-net-family-preload.c`, and `apply-incremental-hotfixes.py` from this repository's `v1.1.0` release into the build workspace before installation continues.

Running the installer changes the Haiku system in all of the following ways:

- Builds ZeroTier One 1.16.0 locally from the official upstream source tarball after applying the Haiku patch and incremental hotfixes.
- Installs `/boot/system/non-packaged/bin/zerotier-one`.
- Installs `/boot/system/non-packaged/bin/zerotier-cli` as a symlink to `zerotier-one`.
- Installs `/boot/system/non-packaged/bin/zerotier-idtool` as a symlink to `zerotier-one`.
- Creates `/boot/system/non-packaged/var/lib/zerotier-one`.
- Writes `/boot/system/non-packaged/var/lib/zerotier-one/local.conf`.
- Writes `/boot/system/non-packaged/bin/zerotier-boot-start.sh`.
- Writes `/boot/system/non-packaged/bin/public-net-watchdog.sh`.
- Writes `/boot/system/non-packaged/bin/zerotier-launch.sh`.
- Writes `/boot/system/non-packaged/bin/zerotier-keepalive.sh`.
- Writes `/boot/system/non-packaged/bin/haiku-net-family-refresh.py`.
- Builds and installs `/boot/home/config/non-packaged/lib/libhaiku_net_family.so`.
- Writes `/boot/home/config/settings/haiku-net-family-routes.conf`.
- Adds managed `LD_PRELOAD` and `HAIKU_NET_FAMILY_POLICY_FILE` blocks to `/boot/home/config/settings/profile`, `/boot/home/.bash_profile`, `/boot/home/.profile`, and `/boot/home/.bashrc`.
- Writes `/boot/home/config/settings/launch/haiku-net-family-env` so desktop-target processes inherit the same address-family policy.
- Adds a managed `SetEnv LD_PRELOAD=... HAIKU_NET_FAMILY_POLICY_FILE=...` block to `/boot/system/settings/ssh/sshd_config`.
- Adds a managed ZeroTier boot block to `/boot/home/config/settings/boot/UserBootscript`.
- Removes legacy files when present: `/boot/home/config/settings/launch/isolate-net-recover`, `/boot/system/non-packaged/data/launch/zerotier`, `/boot/home/config/non-packaged/bin/ping`, `/boot/home/config/non-packaged/bin/ssh`, and `/boot/home/config/non-packaged/bin/haiku-net-family-policy.py`.
- Stops previous ZeroTier/helper processes, clears stale `tap/*` devices, and starts the new supervisor immediately until `zerotier-cli info` reaches stable `ONLINE`.

## Technical Design

The original `v1.0.0` release had a severe defect in its single-file release model. In `v1.1.0`, the patch, JSON template, Python helpers, preload C source, and incremental hotfix logic are published as separate release assets, and the installer always downloads those exact files from the `v1.1.0` release before continuing.

The runtime design is broader than a normal package installer. `zerotier-boot-start.sh` acts as a supervisor that waits for public IPv4 plus a default route, starts ZeroTier, rejoins saved networks, refreshes the family-policy cache, and restarts the daemon when it dies. `public-net-watchdog.sh` separately repairs public-NIC DHCP failures by resetting `virtio/0`, re-running `auto-config`, and restarting `net_server` when needed, while isolating `sshd` listener handling from shutdown-time cleanup.

The family-policy fix is global. The installer ships `haiku-net-family-refresh.py` plus `libhaiku_net_family.so`, builds the preload library locally, and injects the environment into shell, desktop, and SSH entry points. That preload hook reorders `getaddrinfo()` results so ZeroTier destinations prefer the matching routed family, while general internet traffic prefers IPv4 when the host lacks a public IPv6 default route.

The Haiku hotfix set also addresses multi-network IPv6 correctness by removing the previous preferred-single-IPv6 behavior, reconciling on-link IPv6 routes for each tap, maintaining source-to-tap IPv6 ownership, and rerouting outbound IPv6 frames back to the correct tap when Haiku selects the wrong interface.

## Target Profile

- Upstream version: ZeroTier One 1.16.0
- Upstream tag: `1.16.0`
- Release asset tag: `v1.1.0`
- Release asset set: `install-zerotier-one-haiku.sh`, `zerotier-one-haiku-1.16.0.patch`, `local.conf.json`, `haiku-net-family-refresh.py`, `haiku-net-family-preload.c`, `apply-incremental-hotfixes.py`
- Install media: `haiku-r1beta5-x86_64-anyboot.iso`
- Operating system: Haiku R1/beta5
- Architecture: `x86_64`
- Public interface assumption: `/dev/net/virtio/0`
- Boot integration: `UserBootscript`

## Included Files

- `install-zerotier-one-haiku.sh` downloads `zerotier-one-haiku-1.16.0.patch`, `local.conf.json`, `haiku-net-family-refresh.py`, `haiku-net-family-preload.c`, and `apply-incremental-hotfixes.py` from the repository `v1.1.0` release into the build workspace, downloads the official upstream source archive, applies the Haiku patch and incremental hotfixes, builds and installs ZeroTier, writes runtime configuration, installs the watchdog/launch/boot/keepalive helpers, applies the global family-policy fix, updates `UserBootscript`, reloads `sshd` when required, and verifies stable `ONLINE`.
- `install-zerotier-one-haiku.files/zerotier-one-haiku-1.16.0.patch` is the main Haiku patch applied to the upstream ZeroTierOne source tree.
- `install-zerotier-one-haiku.files/apply-incremental-hotfixes.py` applies the post-patch Haiku IPv6 and tap-owner hotfixes that are intentionally kept separate from the large base patch.
- `install-zerotier-one-haiku.files/local.conf.json` is the `local.conf` template that the installer renders with the configured primary port.
- `install-zerotier-one-haiku.files/haiku-net-family-refresh.py` generates the route-policy cache consumed by the preload library.
- `install-zerotier-one-haiku.files/haiku-net-family-preload.c` is the preload source used to build `libhaiku_net_family.so`.

## Quick Start

Open a Terminal session on Haiku before running the installer.

The commands below are intended to be run on the target Haiku system. The script then downloads the matching `v1.1.0` asset zip by itself and continues from there.

```sh
wget https://github.com/itinfra7/zerotier-one-haiku/releases/latest/download/install-zerotier-one-haiku.sh
chmod +x install-zerotier-one-haiku.sh
/bin/bash ./install-zerotier-one-haiku.sh
```

## Workflow

1. Confirm the host is Haiku and verify the required tools: `awk`, `curl`, `gcc`, `g++`, `grep`, `ifconfig`, `make`, `nc`, `patch`, `ps`, `python3`, `sed`, and `tar`.
2. Download `zerotier-one-haiku-1.16.0.patch`, `local.conf.json`, `haiku-net-family-refresh.py`, `haiku-net-family-preload.c`, and `apply-incremental-hotfixes.py` from the repository `v1.1.0` release, remove any previous asset staging directory, and refresh the build workspace asset set.
3. Download the official ZeroTier One 1.16.0 source archive, or reuse a local source tree when `USE_LOCAL_SRC=1` is set.
4. Copy `zerotier-one-haiku-1.16.0.patch` from the refreshed release asset set, apply it to the upstream tree, and then run `apply-incremental-hotfixes.py`.
5. Build `zerotier-one` with `make OSTYPE=Haiku CC=gcc CXX=g++ clean` and `make OSTYPE=Haiku CC=gcc CXX=g++ one install`.
6. Install the runtime binaries and state layout under `/boot/system/non-packaged`, then render `local.conf` with `primaryPort=9993`, `allowSecondaryPort=false`, `portMappingEnabled=false`, and `allowTcpFallbackRelay=true`.
7. Install `zerotier-boot-start.sh`, `public-net-watchdog.sh`, `zerotier-launch.sh`, and `zerotier-keepalive.sh`.
8. Build and install the global family-policy stack: `haiku-net-family-refresh.py`, `libhaiku_net_family.so`, `/boot/home/config/settings/haiku-net-family-routes.conf`, shell profile blocks, desktop launch env, and managed `sshd_config` environment.
9. Update `/boot/home/config/settings/boot/UserBootscript` so the public-network watchdog and delayed ZeroTier launch start automatically at boot.
10. Remove legacy wrapper files, stop previous ZeroTier/helper processes, clear stale `tap/*` interfaces, and reload `sshd` when the managed SSH environment changed.
11. Start the new boot supervisor immediately, wait until `zerotier-cli info` reports stable `ONLINE`, and then leave the machine ready for `zerotier-cli join <network-id>`.

## Release Assets

The latest release publishes the following assets:

- `install-zerotier-one-haiku.sh`
- `zerotier-one-haiku-1.16.0.patch`
- `local.conf.json`
- `haiku-net-family-refresh.py`
- `haiku-net-family-preload.c`
- `apply-incremental-hotfixes.py`

Release `v1.0.0` has a severe defect and is retained only as a historical artifact. General users should use `v1.1.0` or later.

## Credits

[ZeroTier, Inc.](https://www.zerotier.com/) and the [ZeroTierOne](https://github.com/zerotier/ZeroTierOne) project provide the upstream source code and versioning.

[Haiku](https://www.haiku-os.org/) provides the target operating system and runtime environment validated by this repository.

[itinfra7](https://github.com/itinfra7) is credited for the Haiku patch set, incremental IPv6 hotfixes, release asset packaging, public-NIC watchdog design, ZeroTier boot supervision, family-policy preload workflow, and repository packaging behind this release.
