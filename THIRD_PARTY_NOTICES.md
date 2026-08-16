<!-- SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech> -->
<!-- SPDX-License-Identifier: GPL-2.0-only -->

# Third-party software notices

NES Wallpaper incorporates the software listed below. The complete source for
the FCEUX-derived components is included in the repository under
`Sources/CFCEUX/`; Sparkle is fetched by Swift Package Manager at the exact
version pinned in `Package.resolved`.

## Sparkle

Sparkle is copyright (c) 2006 Andy Matuschak and the Sparkle Project
contributors, and is distributed under the MIT License, with bundled
components (bspatch, ed25519, SHA-1, and others) under compatible permissive
licenses. See `ThirdPartyLicenses/Sparkle.txt` for the complete license text.

Binary releases of NES Wallpaper embed `Sparkle.framework`, consumed as the
prebuilt XCFramework published by the Sparkle project.

- Upstream: <https://github.com/sparkle-project/Sparkle>
- Version: pinned in `Package.resolved` (source available from upstream at
  the matching tag)
- License text: `ThirdPartyLicenses/Sparkle.txt`

## FCEUX

FCEUX is copyright its respective contributors and is distributed under the
GNU General Public License, version 2. The vendored source generally permits
use under version 2 or, at the recipient's option, a later version. NES
Wallpaper distributes the combined work under version 2.

- Upstream: <https://github.com/TASEmulators/fceux>
- Vendored revision: `a62b868e9247c4aafd66f597cdfa8d2609704087`
- License text: `LICENSE`
- Vendoring and modification details: `vendor/VENDOR.md`

The FCEUX source includes components under compatible licenses, including the
following notices.

## hq2x, hq3x, and nes_ntsc filters

The hq2x and hq3x filters are copyright (C) 2003 MaxSt. The nes_ntsc filter is
copyright (C) 2006-2007 Shay Green. These components are distributed under the
GNU Lesser General Public License, version 2.1 or, at the recipient's option,
any later version. See `ThirdPartyLicenses/LGPL-2.1-or-later.txt`.

## DeSmuME EMUFILE

Copyright (C) 2009-2010 DeSmuME team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## backward.hpp

Copyright 2013 Google Inc. All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## MiniZip

Copyright (C) 1998-2010 Gilles Vollant

Modifications of Unzip for Zip64 copyright (C) 2007-2008 Even Rouault.
Modifications for Zip64 support copyright (C) 2009-2010 Mathias Svensson.

This software is provided "as-is", without any express or implied warranty.
In no event will the authors be held liable for any damages arising from the
use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a
   product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

## ConvertUTF.h

The vendored FCEUX source includes `utils/ConvertUTF.h`. Its Windows-driver
conversion declarations are conditionally included by `utils/xstring.cpp`;
the header remains part of the distributed corresponding source even though
that code path is not active in NES Wallpaper's macOS build.

Copyright 2001-2004 Unicode, Inc.

Disclaimer

This source code is provided as is by Unicode, Inc. No claims are made as to
fitness for any particular purpose. No warranties of any kind are expressed
or implied. The recipient agrees to determine applicability of information
provided. If this file has been purchased on magnetic or optical media from
Unicode, Inc., the sole remedy for any claim will be exchange of defective
media within 90 days of receipt.

Limitations on Rights to Redistribute This Code

Unicode, Inc. hereby grants the right to freely use the information supplied
in this file in the creation of products supporting the Unicode Standard, and
to make copies of this file in any form for internal or external distribution
as long as this notice remains attached.

## TASVideos movies and metadata

NES Wallpaper does not bundle any TASVideos content. At the user's request it
downloads tool-assisted movie files and catalog metadata (titles, authors,
durations, links) from <https://tasvideos.org>. That content is copyright its
respective authors and is licensed under the Creative Commons Attribution 2.0
license (CC BY 2.0). The app displays each movie's authors and links to its
TASVideos publication page in the browser used to download it.

- Site license: <https://tasvideos.org/SiteLicense>
- License text: <https://creativecommons.org/licenses/by/2.0/>
