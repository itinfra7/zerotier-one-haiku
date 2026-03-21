# zerotier-one-haiku

ZeroTier One 1.16.0 installer and runtime helper for Haiku R1/beta5 (`x86_64`).

## Keywords

Keywords: `#haiku #x86_64 #zerotier #vpn #networking #tap #ipv6 #userbootscript #virtio #keepalive`

## Overview

This repository provides a reproducible installation and boot-time recovery path for ZeroTier One 1.16.0 on Haiku R1/beta5 (`x86_64`).

The installer script covers the embedded patch, the Haiku-specific hotfixes, and the boot-time helper flow used to keep the node stable after installation.

## Technical Design

This installer downloads the official ZeroTier One 1.16.0 source tarball, extracts an embedded Haiku patch from the script body, applies additional incremental hotfixes, and builds `zerotier-one` plus `zerotier-cli` into `/boot/system/non-packaged/bin`.

The runtime configuration fixes `primaryPort` to `9993`, disables secondary-port and external port-mapping behavior, installs a boot supervisor plus a UDP self-probe keepalive helper, and registers the supervisor through `UserBootscript`.

The Haiku-specific hotfix set focuses on tap cleanup, boot-time recovery, stable `ONLINE` detection, and managed IPv4/IPv6 handling across multiple networks, including IPv6 route reconciliation and source-to-tap rerouting.

## Target Profile

- Upstream version: ZeroTier One 1.16.0
- Upstream tag: `1.16.0`
- Install media: `haiku-r1beta5-x86_64-anyboot.iso`
- Operating system: Haiku R1/beta5
- Architecture: `x86_64`
- Public interface assumption: `/dev/net/virtio/0`
- Boot integration: `UserBootscript`

## Included Files

- `install-zerotier-one-haiku.sh` downloads the official source archive, extracts the embedded Haiku patch, applies incremental hotfixes, builds and installs `zerotier-one` plus `zerotier-cli`, writes `local.conf`, installs the boot and keepalive helpers, registers `UserBootscript`, and verifies the node reaches stable `ONLINE`.

## Quick Start

Open a Terminal session on Haiku before running the installer.

The commands below are intended to be run on the target Haiku system.

```sh
wget https://github.com/itinfra7/zerotier-one-haiku/releases/latest/download/install-zerotier-one-haiku.sh
chmod +x install-zerotier-one-haiku.sh
/bin/bash ./install-zerotier-one-haiku.sh
```

## Workflow

1. Confirm the host is Haiku and verify the required build and runtime utilities.
2. Download the official ZeroTier One 1.16.0 source archive, or reuse a local source tree when `USE_LOCAL_SRC=1` is set.
3. Extract the embedded Haiku patch from the installer, apply it to the source tree, and apply the incremental Haiku hotfix set.
4. Build `zerotier-one` and `zerotier-cli` and install them into `/boot/system/non-packaged/bin`.
5. Write `local.conf` under `/boot/system/non-packaged/var/lib/zerotier-one` with a fixed `9993` primary port and the Haiku runtime options.
6. Install `zerotier-boot-start.sh` and `zerotier-keepalive.sh`.
7. Register boot-time startup in `/boot/home/config/settings/boot/UserBootscript`.
8. Clean up any previous ZeroTier processes and stale `tap/*` devices.
9. Start the boot helper immediately and wait until `zerotier-cli info` reaches stable `ONLINE`.

## Release Assets

The latest release publishes the following assets:

- `install-zerotier-one-haiku.sh`

## Credits

[ZeroTier, Inc.](https://www.zerotier.com/) and the [ZeroTierOne](https://github.com/zerotier/ZeroTierOne) project provide the upstream source code and versioning.

[Haiku](https://www.haiku-os.org/) provides the target operating system validated by this repository.

[itinfra7](https://github.com/itinfra7) is credited for the Haiku adaptation workflow, embedded patch packaging, runtime helper design, IPv6 and tap hotfixing, and installer packaging behind this repository.
