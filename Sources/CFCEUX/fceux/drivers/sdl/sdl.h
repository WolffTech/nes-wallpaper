/*
 * SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 as published by
 * the Free Software Foundation.
 *
 * This program is distributed without any warranty; without even the implied
 * warranty of merchantability or fitness for a particular purpose. See
 * LICENSE for details.
 *
 * Added 2026-08-11 as a stub for the embedded driverless build. It declares
 * the frontend globals used by the FCEUX core; see vendor/VENDOR.md.
 */
#pragma once
#include "../../driver.h"

extern int dendy;
extern int pal_emulation;
extern bool swapDuty;
