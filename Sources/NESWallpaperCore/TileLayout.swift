// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-2.0-only

/// Which tile each grid cell shows on one display. Every display draws the
/// same tiles; a shuffled layout only moves them to different cells, so it
/// costs no extra emulation. Cells are row-major from the top-left, matching
/// TileGridRenderer and TileGridHitTest.
public struct TileLayout: Equatable {
    /// cells[cell] is the tile drawn in that cell. Always a permutation of
    /// 0..<count; the private init keeps it that way.
    private let cells: [Int]

    private init(cells: [Int]) { self.cells = cells }

    public static func identity(count: Int) -> TileLayout {
        TileLayout(cells: Array(0..<max(0, count)))
    }

    public var count: Int { cells.count }

    public func tile(atCell cell: Int) -> Int { cells[cell] }

    /// Cells that show the same tile in both layouts.
    func sharedCells(with other: TileLayout) -> Int {
        guard other.count == count else { return 0 }
        return zip(cells, other.cells).filter { $0 == $1 }.count
    }

    /// A random layout that keeps as few tiles as possible in the same cell
    /// as any of `others` (the layouts already on other displays). Small
    /// grids cannot always avoid every collision, so this takes the best of
    /// a bounded number of random draws instead of searching exhaustively.
    public static func shuffled<G: RandomNumberGenerator>(
        count: Int, avoiding others: [TileLayout], using generator: inout G
    ) -> TileLayout {
        guard count > 1 else { return identity(count: count) }
        var best = identity(count: count)
        var bestScore = Int.max
        for _ in 0..<64 {
            let candidate = TileLayout(cells: Array(0..<count).shuffled(using: &generator))
            let score = others.reduce(0) { $0 + candidate.sharedCells(with: $1) }
            if score < bestScore {
                best = candidate
                bestScore = score
                if score == 0 { break }
            }
        }
        return best
    }

    public static func shuffled(count: Int, avoiding others: [TileLayout]) -> TileLayout {
        var generator = SystemRandomNumberGenerator()
        return shuffled(count: count, avoiding: others, using: &generator)
    }
}
