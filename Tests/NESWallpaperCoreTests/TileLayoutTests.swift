// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

import XCTest
@testable import NESWallpaperCore

final class TileLayoutTests: XCTestCase {
    /// Deterministic generator so collision assertions can't flake.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func tiles(_ layout: TileLayout) -> [Int] {
        (0..<layout.count).map { layout.tile(atCell: $0) }
    }

    func testShuffleMovesEveryTileOffThePrimaryOrder() {
        for seed in 0..<50 as Range<UInt64> {
            var generator = SplitMix64(state: seed)
            for count in 2...12 {
                let identity = TileLayout.identity(count: count)
                let layout = TileLayout.shuffled(
                    count: count, avoiding: [identity], using: &generator)
                XCTAssertEqual(tiles(layout).sorted(), Array(0..<count))
                XCTAssertEqual(layout.sharedCells(with: identity), 0,
                               "seed \(seed), count \(count)")
            }
        }
    }

    func testThirdDisplayAvoidsBothOthersWhenTheGridAllows() {
        var generator = SplitMix64(state: 7)
        let identity = TileLayout.identity(count: 6)
        let second = TileLayout.shuffled(count: 6, avoiding: [identity], using: &generator)
        let third = TileLayout.shuffled(
            count: 6, avoiding: [identity, second], using: &generator)
        XCTAssertEqual(third.sharedCells(with: identity), 0)
        XCTAssertEqual(third.sharedCells(with: second), 0)
    }

    func testSingleTileGridCannotShuffle() {
        let layout = TileLayout.shuffled(count: 1, avoiding: [.identity(count: 1)])
        XCTAssertEqual(layout, .identity(count: 1))
    }
}
