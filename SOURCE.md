<!-- SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech> -->
<!-- SPDX-License-Identifier: GPL-2.0-only -->

# Obtaining the corresponding source

The complete corresponding source code for each official NES Wallpaper binary
release is available from the same GitHub release page as the binary disk image:

<https://github.com/WolffTech/nes-wallpaper/releases>

Download `NES-Wallpaper-<version>-source.zip` for the version matching the
application's version. The source archive includes the NES Wallpaper source,
the incorporated FCEUX source, interface definitions, and the scripts used to
build and package the application.

The Sparkle update framework embedded in binary releases is a separate,
MIT-licensed work and is not part of this archive. It is fetched by Swift
Package Manager at the exact version recorded in the archive's
`Package.resolved`; its source is available from
<https://github.com/sparkle-project/Sparkle> at the matching tag.

The development repository is available at:

<https://github.com/WolffTech/nes-wallpaper>

Anyone redistributing the binaries is responsible for continuing to satisfy
the source-code distribution requirements in section 3 of the GNU General
Public License version 2.
