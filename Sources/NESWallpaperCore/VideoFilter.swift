// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// CPU video filters run inside each nes-helper via FCEUX's vidblit
/// pipeline. Raw values are the helper's --filter names; the output sizes
/// mirror the shim's fceux_set_video_filter geometry table (and the
/// filterMap in Sources/HelperApp/main.swift) — keep all three in sync.
public enum VideoFilter: String, CaseIterable, Sendable {
    case none
    case ntscComposite = "ntsc-composite"
    case ntscSVideo = "ntsc-svideo"
    case ntscRGB = "ntsc-rgb"
    case ntscMono = "ntsc-mono"
    case hq2x
    case hq3x
    case scale2x
    case scale3x

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .ntscComposite: return "NTSC Composite"
        case .ntscSVideo: return "NTSC S-Video"
        case .ntscRGB: return "NTSC RGB"
        case .ntscMono: return "NTSC Monochrome"
        case .hq2x: return "hq2x"
        case .hq3x: return "hq3x"
        case .scale2x: return "Scale2x"
        case .scale3x: return "Scale3x"
        }
    }

    /// Frame size the helper publishes with this filter.
    public var outputSize: (width: Int, height: Int) {
        switch self {
        case .none: return (256, 240)
        case .hq2x, .scale2x: return (512, 480)
        case .ntscComposite, .ntscSVideo, .ntscRGB, .ntscMono: return (602, 480)
        case .hq3x, .scale3x: return (768, 720)
        }
    }
}
