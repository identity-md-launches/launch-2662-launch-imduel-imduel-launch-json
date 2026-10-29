// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Bitboard} from "./Bitboard.sol";
import {Chess} from "./Chess.sol";
import {IChessEngine} from "./IChessEngine.sol";
import {Rules} from "./Rules.sol";

/// V5: an engine that plays like a person whose effort follows the trade, on the bitboard core. It chooses from the
/// legal moves and plays the choice by the rules (Rules.sol) in the same call.
///
/// Every move it looks at gets a cheap score: material and piece-square change, a bonus for check and for bringing
/// a piece to bear on the enemy king, minus the worst loss it risks, judged by the cheapest enemy attacker and our
/// other defenders. The trade's accuracy sets how hard it looks: a small trade plays like a
/// beginner (captures and checks always catch its eye, but it overlooks some quiet moves, threats to its other pieces
/// and even mates), an average trade like a club player, a big one like a strong amateur; noticing threats and taking
/// second looks come with a chance that grows with accuracy, so every step in size shows. A seeded mistake of up to
/// MAX_MISTAKE centipawns, larger at lower accuracy and leaning towards active moves, keeps games human; whales keep
/// a little of it. Second looks (up to REFINE) re-score the leader on the position after it (real threats, the
/// enemy's mate in one when our king is boxed in, repetition, stalemate) until the leader is exact.
/// Against a lone king it converts at full effort: it shrinks the king's escape squares towards the edge and brings
/// its own king closer. The longer a quiet stretch lasts (no capture or pawn move), the more it leans towards
/// progress: pawn moves, checks, pressure on the enemy king and trades that lose no material, trades mainly when
/// ahead. Risk is still scored, so it never hangs a piece to break the stretch. An enemy pawn a step from queening
/// is a risk every move is scored against, at every strength, on every square it can queen on after the move: straight
/// ahead when that square is empty, or diagonally onto a piece of ours. A move that neither takes the pawn nor leaves
/// each of those squares blocked or covered loses a queen for a pawn, and the piece it queens on.
///
/// The engine is pure: every chance above (which quiet moves it weighs, which checks it tests, its second looks and
/// its mistake) is a function of `seed` alone, so the same seed always gives the same move. The caller must draw
/// the seed from something the trader cannot choose or predict when committing the trade; otherwise a trader picks
/// a seed at which a small trade plays the strong move, or at which the engine misses a mate.
contract ChessEngineV5 is IChessEngine {
    int256 internal constant MATE = 100_000;
    uint256 internal constant MAX_MISTAKE = 400;
    uint256 internal constant REFINE = 4;
    uint256 internal constant MATE_TESTS = 6; // checks tested for mate per choice: ours, and as many again of ours that
    // box the king in (a second look tries every enemy check: a bound there saw a mate only from the low squares)
    uint256 internal constant MAX_ACCURACY = 9_000; // even a whale keeps a tenth of the mistake
    int256 internal constant CHECK_BONUS = 30;
    int256 internal constant PRESSURE = 20;
    uint256 internal constant QUIET_START = 10; // quiet half-moves before the push for progress starts
    uint256 internal constant QUIET_RAMP = 20; // ... and over how many more it reaches full strength
    int256 internal constant PROGRESS = 60; // the full push, in centipawns, for a pawn move or a capture
    /// Each square's distance to the nearest edge, two bits per square (a1 = bits 0-1).
    uint256 internal constant EDGE = 0x15541aa41be41be41aa415540000;
    uint64 internal constant FILE_A = 0x0101010101010101;
    uint64 internal constant NOT_A = 0xfefefefefefefefe; // every file but a
    uint64 internal constant NOT_H = 0x7f7f7f7f7f7f7f7f; // every file but h
    uint64 internal constant RANK_2 = 0x000000000000ff00;
    uint64 internal constant RANK_7 = 0x00ff000000000000;
    int256 internal constant PROMOTION = 800; // what an enemy pawn's promotion wins: a queen for a pawn

    /// One side's attacks, grouped by the cheapest attacker.
    struct Maps {
        uint64 pawn;
        uint64 minor;
        uint64 rook;
        uint64 queen;
        uint64 all;
    }

    struct Ctx {
        uint256 board;
        Bitboard.Pos p;
        Bitboard.Pos n; // the position after a trial move
        Bitboard.Checks checks;
        Maps enemy;
        bool white;
        uint64 own;
        uint64 opp;
        uint64 our1; // squares we attack at least once
        uint64 our2; // ... at least twice
        uint64 zone; // the enemy king and the squares around it
        // by piece type: the squares from which a piece of ours would attack the zone (current occupancy)
        uint64[7] zoneFrom;
        // effort, from the trade's accuracy (basis points)
        uint256 acc;
        uint256 seedHash;
        uint256 lookBps; // chance of considering a quiet move
        uint256 mateBps; // chance of testing a check for mate
        uint256 guardBps; // chance a second look asks whether the enemy then has a mate in one
        uint256 mateTests; // tests of our checks left
        uint256 likelyTests; // ... and of our checks that leave the enemy king no square
        bool otherThreats; // notices threats to its other pieces
        uint8 ourKing;
        uint8 enemyKing;
        uint8 sqA; // our most endangered piece, its loss, and the second worst loss
        int256 lossA;
        int256 lossB;
        int256 ours; // material without kings
        int256 theirs;
        int256 ownNonPawn;
        bool endgame;
        bool ahead; // a sparse board and at least two pawns up: drive the attack home
        bool conversion; // the enemy has only its king and we have a rook or queen
        bool history;
        uint32 gameNo;
        uint256 push; // the push for progress, 0-10,000, from the quiet half-moves
        uint64[8] previous;
        uint64 passers; // enemy pawns on their seventh rank: a step from promotion by a push or a capture
    }

    function play(
        uint256 board,
        uint32 mover,
        uint32 other,
        bool black,
        uint256 strengthBps,
        uint256 seed,
        uint64[8] calldata previous,
        uint32 gameNo,
        uint16 quiet
    ) external pure returns (uint16 m, Rules.Played memory) {
        Ctx memory c = _context(board, black ? other : mover, black ? mover : other, !black, _aware(strengthBps, seed));
        (m,) = _choose(c, strengthBps, seed, previous, gameNo, quiet);
        return (m, Rules.playLegal(board, c.p, m, black));
    }

    function playAny(uint256 board, uint32 mover, uint32 other, bool black, uint256 seed)
        external
        pure
        returns (uint16 m, Rules.Played memory)
    {
        (uint32 w, uint32 b) = black ? (other, mover) : (mover, other);
        Bitboard.Pos memory p = Bitboard.fromBoard(board, w, b);
        uint16[] memory moves = Bitboard.legalMoves(p, !black);
        require(moves.length != 0, "no legal move");
        m = moves[seed % moves.length];
        return (m, Rules.playLegal(board, p, m, black));
    }

    /// The choice alone, with how many legal moves there were (for measurements and tools).
    function choose(
        uint256 board,
        uint32 mover,
        uint32 other,
        bool black,
        uint256 strengthBps,
        uint256 seed,
        uint64[8] calldata previous,
        uint32 gameNo,
        uint16 quiet
    ) external pure returns (uint16, uint256) {
        Ctx memory c = _context(board, black ? other : mover, black ? mover : other, !black, _aware(strengthBps, seed));
        return _choose(c, strengthBps, seed, previous, gameNo, quiet);
    }

    // ---------------------------------------------------------------- choice

    /// The move for the side to move in `c` (from _context), and how many legal moves there were.
    function _choose(Ctx memory c, uint256 acc, uint256 seed, uint64[8] memory previous, uint32 gameNo, uint16 quiet)
        internal
        pure
        returns (uint16, uint256)
    {
        require(acc <= 10_000);
        c.previous = previous;
        c.gameNo = gameNo;
        if (quiet > QUIET_START) {
            uint256 q = quiet - QUIET_START;
            c.push = (q > QUIET_RAMP ? QUIET_RAMP : q) * 10_000 / QUIET_RAMP;
        }
        for (uint256 j; j < 8; j++) {
            if (previous[j] != 0) c.history = true;
        }
        (uint16[] memory moves, bool inCheck) = Bitboard.legalMovesAndCheck(c.p, c.white);
        uint256 count = moves.length;
        require(count != 0, "no legal move");
        if (c.conversion) return (_convert(c, moves), count);
        _effort(c, acc, seed);
        // a person weighs only so many quiet moves: about 8 at the weakest, about 17 at full strength
        uint256 cap = (8 + acc / 1_000) * 10_000 / count;
        if (cap < c.lookBps) c.lookBps = cap;
        // in check, with few moves, or with an enemy pawn about to queen, anyone looks at every move
        if (count <= 10 || inCheck || c.passers != 0) c.lookBps = 10_000;
        // the mistake never vanishes entirely, except when converting against a lone king
        uint256 slack = 10_000 - (acc > MAX_ACCURACY ? MAX_ACCURACY : acc);
        int256[] memory base = new int256[](count);
        int256[] memory score = new int256[](count);
        int256[] memory noise = new int256[](count);
        uint256 seen; // bit i: move i was looked at (at most 218 legal moves)
        for (uint256 pass; seen == 0; pass++) {
            if (pass == 1) c.lookBps = 10_000; // it overlooked every move it has: now it looks at them all
            for (uint256 i; i < count; i++) {
                (int256 b, int256 threat, int256 activity, bool mate, bool looked) = _cheap(c, moves[i]);
                if (mate) return (moves[i], count);
                if (!looked) continue;
                seen |= uint256(1) << i;
                base[i] = b;
                score[i] = b - threat;
                uint256 penalty = _mix(c.seedHash, moves[i]) % (MAX_MISTAKE + 1);
                noise[i] = (activity - int256(penalty)) * int256(slack);
            }
        }
        // second looks: re-score the leader on the real position after it until the leader is exact; out of looks,
        // play the best move that had one. Below 60% a player takes second looks only sometimes (a chance of
        // accuracy / 60%), else plays its first impression; two looks below 40%, three to 70%, then REFINE. Each step in
        // trade size then wins visibly more often (engine review 2026-10-22: 62-72% per step).
        bool looksAgain = c.acc >= 6_000 || (c.seedHash >> 64) % 6_000 < c.acc;
        uint256 looks = !looksAgain ? 0 : c.acc < 4_000 ? 2 : c.acc < 7_000 ? 3 : REFINE;
        uint256 lead = _best(score, noise, seen);
        uint256 refined;
        for (uint256 r; r < looks && refined >> lead & 1 == 0; r++) {
            refined |= uint256(1) << lead;
            score[lead] = _exact(c, moves[lead], base[lead]);
            lead = _best(score, noise, r + 1 == looks ? refined : seen);
        }
        return (moves[lead], count);
    }

    /// Against a lone king every candidate already has its exact escape map and terminal result.
    /// Compare them all with the same history penalty rather than spending tactical second looks.
    function _convert(Ctx memory c, uint16[] memory moves) internal pure returns (uint16 chosen) {
        int256 best = type(int256).min;
        for (uint256 i; i < moves.length; i++) {
            uint16 m = moves[i];
            uint8 from = uint8(m >> 6);
            uint8 to = uint8(m & 63);
            uint8 t = uint8(c.board >> (uint256(from) << 2)) & 7;
            bool check = Bitboard.givesCheckAs(c.p, c.checks, c.n, m, c.white, t);
            (int256 score, bool mate) = _mop(c, from, to, t, t == 1 && (to >> 3 == 7 || to >> 3 == 0), check);
            if (mate) return m;
            if (score <= best) continue;
            if (c.history) {
                Bitboard.makeMoveInto(c.p, c.n, m, c.white);
                if (_seen(c, c.n, m)) score -= 300;
            }
            if (score > best) {
                best = score;
                chosen = m;
            }
        }
    }

    function _best(int256[] memory score, int256[] memory noise, uint256 among) internal pure returns (uint256 lead) {
        int256 top = type(int256).min;
        for (uint256 i; i < score.length; i++) {
            if (among >> i & 1 == 0) continue;
            int256 k = score[i] * 10_000 + noise[i];
            if (k > top) (top, lead) = (k, i);
        }
    }

    /// How hard this trade looks. Starting points, tuned by self-play (test/EngineV5Games.t.sol).
    function _effort(Ctx memory c, uint256 acc, uint256 seed) internal pure {
        c.acc = acc;
        c.seedHash = uint256(keccak256(abi.encode(seed)));
        c.lookBps = acc >= 6_000 ? 10_000 : 4_000 + acc; // quiet moves considered: 40% .. all
        c.mateBps = 5_000 + acc / 2; // a check tested for mate: 50% .. 100%
        c.guardBps = acc < 7_000 ? 8_500 : 10_000; // only second looks use it, and a beginner takes none
        c.mateTests = MATE_TESTS;
        c.likelyTests = MATE_TESTS;
    }

    /// Whether this turn's player notices threats to its other pieces: a chance of accuracy / 50%, certain from 50%.
    function _aware(uint256 acc, uint256 seed) internal pure returns (bool) {
        return (seed >> 128) % 5_000 < acc;
    }

    /// The position as the side to move sees it; `aware` (from _aware) decides whether it scans its pieces already
    /// under attack and weighs those threats when choosing.
    function _context(uint256 board, uint32 whiteState, uint32 blackState, bool white, bool aware)
        internal
        pure
        returns (Ctx memory c)
    {
        unchecked {
            c.white = white;
            c.board = board;
            c.p = Bitboard.fromBoard(board, whiteState, blackState);
            Bitboard.Pos memory p = c.p;
            c.own = white ? p.white : p.black;
            c.opp = white ? p.black : p.white;
            uint64 empty = ~(p.white | p.black);
            int256 nonPawn;
            for (uint8 t = 1; t <= 5; t++) {
                int256 mine = int256(Bitboard.popcount(p.pc[t] & c.own)) * _value(t);
                int256 yours = int256(Bitboard.popcount(p.pc[t] & c.opp)) * _value(t);
                c.ours += mine;
                c.theirs += yours;
                if (t != 1) {
                    nonPawn += mine + yours;
                    c.ownNonPawn += mine;
                }
            }
            bool sparse = Bitboard.popcount(p.white | p.black) <= 12;
            c.endgame = nonPawn <= 2600 || sparse;
            c.ahead = sparse && c.ours - c.theirs >= 200;
            uint64 ek = p.pc[6] & c.opp;
            uint64 ok = p.pc[6] & c.own;
            c.enemyKing = ek == 0 ? 64 : Bitboard.lsb(ek);
            c.ourKing = ok == 0 ? 64 : Bitboard.lsb(ok);
            c.zone = Bitboard.kingAttacks(ek) | ek;
            c.conversion = c.theirs == 0 && ek != 0 && ok != 0 && (p.pc[4] | p.pc[5]) & c.own != 0;
            c.checks = Bitboard.checkInfo(p, white);
            if (c.conversion) return c;
            c.enemy = _maps(p, !white);
            // enemy pawns on their seventh rank: every move is scored against where they can queen after it (a push
            // onto an empty square, or a capture of a piece of ours), so a blocker never wanders off either
            c.passers = p.pc[1] & c.opp & (white ? RANK_2 : RANK_7);
            // squares we attack, and those attacked from two groups (each pawn diagonal, knights, bishops, rooks,
            // queens, king): two pieces of one group on the same square count once, so a defence is never overrated
            uint64 pawns = p.pc[1] & c.own;
            uint64 q = p.pc[5] & c.own;
            uint64[7] memory groups = [
                white ? (pawns << 9) & NOT_A : (pawns >> 7) & NOT_A,
                white ? (pawns << 7) & NOT_H : (pawns >> 9) & NOT_H,
                Bitboard.knightAttacks(p.pc[3] & c.own),
                Bitboard.bishopAttacks(p.pc[2] & c.own, empty),
                Bitboard.rookAttacks(p.pc[4] & c.own, empty),
                Bitboard.rookAttacks(q, empty) | Bitboard.bishopAttacks(q, empty),
                Bitboard.kingAttacks(p.pc[6] & c.own)
            ];
            for (uint256 i; i < 7; i++) {
                c.our2 |= c.our1 & groups[i];
                c.our1 |= groups[i];
            }
            if (ek != 0) {
                uint64 z = c.zone;
                uint64 diagonal = Bitboard.bishopAttacks(z, empty);
                uint64 straight = Bitboard.rookAttacks(z, empty);
                c.zoneFrom = [
                    uint64(0),
                    Bitboard.pawnAttacks(z, !white),
                    diagonal,
                    Bitboard.knightAttacks(z),
                    straight,
                    diagonal | straight,
                    Bitboard.kingAttacks(z)
                ];
            }
            // our pieces already in danger before the move (if this player notices)
            c.otherThreats = aware;
            uint64 hit = aware ? c.own & ~p.pc[6] & c.enemy.all : 0;
            while (hit != 0) {
                uint8 sq = Bitboard.lsb(hit);
                hit &= hit - 1;
                uint64 bit = uint64(1) << sq;
                int256 loss = _loss(c.enemy, _value(uint8(c.board >> (uint256(sq) << 2)) & 7), bit, c.our1 & bit != 0);
                if (loss > c.lossA) (c.lossB, c.lossA, c.sqA) = (c.lossA, loss, sq);
                else if (loss > c.lossB) c.lossB = loss;
            }
        }
    }

    /// The move's score without its risk (`base`), the risk (`threat`), how active it is (for low-accuracy play),
    /// and whether it mates.
    function _cheap(Ctx memory c, uint16 m)
        internal
        pure
        returns (int256 base, int256 threat, int256 activity, bool mate, bool looked)
    {
        unchecked {
            Bitboard.Pos memory p = c.p;
            uint8 from = uint8(m >> 6);
            uint8 to = uint8(m & 63);
            uint64 tb = uint64(1) << to;
            uint8 t = uint8(c.board >> (uint256(from) << 2)) & 7;
            uint8 victim = c.opp & tb != 0 ? uint8(c.board >> (uint256(to) << 2)) & 7 : 0;
            bool promo = t == 1 && (to >> 3 == 7 || to >> 3 == 0);
            bool ep = t == 1 && victim == 0 && (from & 7) != (to & 7);
            bool check = Bitboard.givesCheckAs(p, c.checks, c.n, m, c.white, t);
            // captures, checks, promotions and moves of our most endangered piece always catch the eye (and pawn moves
            // once a quiet stretch drags on); other moves only sometimes
            if (
                !check && victim == 0 && !ep && !promo && !(t == 1 && c.push != 0) && !(from == c.sqA && c.lossA != 0)
                    && _mix(c.seedHash, m ^ 0x10000) % 10_000 >= c.lookBps
            ) {
                return (0, 0, 0, false, false);
            }
            looked = true;
            base = _gain(c, from, to, t, victim, promo, ep);
            uint8 moved = promo ? 5 : t;
            // a check is worth playing for when it takes something or leaves the king at most one safe square; a
            // spite check (the king just steps aside) earns nothing, so a queen doesn't chase the king around
            bool squeeze;
            if (check) {
                uint64 room = _room(c, moved, from, to);
                squeeze = victim != 0 || ep || room & (room - 1) == 0;
                // a check that leaves the king no square (or opens a line, which _room doesn't count) is the likely
                // mate: it has its own tests, so the ordinary ones aren't all spent on checks that come first
                bool likely = (room == 0 || c.checks.disc & (uint64(1) << from) != 0) && c.likelyTests != 0;
                if ((likely || c.mateTests != 0) && _mix(c.seedHash, m ^ 0x20000) % 10_000 < c.mateBps) {
                    if (likely) c.likelyTests--;
                    else c.mateTests--;
                    Bitboard.makeMoveInto(p, c.n, m, c.white);
                    if (!Bitboard.hasLegalMove(c.n, !c.white)) return (MATE, 0, 0, true, true);
                }
                if (squeeze) {
                    base += CHECK_BONUS;
                    activity = 120;
                }
            }
            if (activity == 0 && (victim != 0 || ep)) activity = 60;
            if (t == 1 && !promo) {
                // a passed pawn is worth pushing, more so near promotion and in the endgame: races, not wandering
                int256 run = _passer(c, from, to);
                base += run;
                if (run != 0 && activity == 0) activity = 60;
            }
            base += _placement(c, from, to, t, moved, victim != 0 || ep, squeeze);
            threat = _risk(c, from, to, t, moved);
        }
    }

    /// Pressure on the enemy king's squares, closing in when ahead, and the push for progress in a quiet stretch.
    function _placement(Ctx memory c, uint8 from, uint8 to, uint8 t, uint8 moved, bool capture, bool squeeze)
        internal
        pure
        returns (int256 b)
    {
        unchecked {
            int256 near;
            if (c.enemyKing < 64) {
                // a piece brought to bear on the squares around the enemy king (or taken away from them)
                near = _zoneHits(c, moved, to) - _zoneHits(c, t, from);
                b = near * (c.ahead ? int256(24) : PRESSURE);
                if (c.ahead) {
                    int256 closer = _distance(from, c.enemyKing) - _distance(to, c.enemyKing);
                    if (t == 6 && c.theirs <= 500) b += closer * 35;
                    else if (t >= 2 && t <= 5) b += closer * 4;
                }
            }
            if (c.push != 0) b += _progress(c, t, capture, squeeze, near);
        }
    }

    /// What the move risks: the piece on its new square, and (if it notices) the worst threat to our other pieces.
    function _risk(Ctx memory c, uint8 from, uint8 to, uint8 t, uint8 moved) internal pure returns (int256 threat) {
        unchecked {
            uint64 tb = uint64(1) << to;
            if (t != 6 && c.enemy.all & tb != 0) {
                // a pawn push doesn't defend its own square; any other mover counted itself among the defenders
                bool push = t == 1 && (from & 7) == (to & 7);
                threat = _loss(c.enemy, _value(moved), tb, (push ? c.our1 : c.our2) & tb != 0);
            }
            if (c.otherThreats) {
                int256 other = from == c.sqA ? c.lossB : c.lossA;
                if (other > threat) threat = other;
            }
            if (c.passers != 0) {
                // an enemy pawn about to queen: scored on the position after the move (c.n is scratch here)
                Bitboard.makeMoveInto(c.p, c.n, (uint16(from) << 6) | to, c.white);
                int256 queen = _promotion(c, c.n);
                if (queen > threat) threat = queen;
            }
        }
    }

    /// What the enemy's pawns on their seventh rank (c.passers) win on `p`, the position after our move, on the worst
    /// of the squares each can queen on: the square ahead when it is empty, and the squares diagonally ahead holding
    /// a piece of ours (not the king). Each costs a queen for a pawn (PROMOTION), plus the piece taken, unless we
    /// attack it: then the new queen goes for the pawn when the square is undefended (so a capture costs the piece
    /// less a pawn), else for our cheapest attacker (a king takes nothing defended). A pawn the move took, or left
    /// without a square, costs nothing. Lines are read with the pawn gone from its square, so a rook behind it
    /// counts for either side.
    function _promotion(Ctx memory c, Bitboard.Pos memory p) internal pure returns (int256 loss) {
        unchecked {
            uint64 own = c.white ? p.white : p.black;
            uint64 opp = c.white ? p.black : p.white;
            uint64 pawns = c.passers & p.pc[1] & opp;
            while (pawns != 0) {
                uint64 pb = uint64(1) << Bitboard.lsb(pawns);
                pawns &= pawns - 1;
                uint64 empty = ~(own | opp) | pb; // with the pawn lifted off its square
                uint64 squares =
                    ((c.white ? pb >> 8 : pb << 8) & empty) | (Bitboard.pawnAttacks(pb, !c.white) & own & ~p.pc[6]);
                while (squares != 0) {
                    uint64 qb = uint64(1) << Bitboard.lsb(squares);
                    squares &= squares - 1;
                    int256 l = _queening(c, p, own, opp, empty, pb, qb) + _value(_typeOn(p, qb));
                    if (l > loss) loss = l;
                }
            }
        }
    }

    /// What the enemy pawn on `pb` wins by queening on `qb` (beyond the piece it takes there, if any), on `p` with
    /// `empty` the squares its lines pass through: see _promotion.
    function _queening(Ctx memory c, Bitboard.Pos memory p, uint64 own, uint64 opp, uint64 empty, uint64 pb, uint64 qb)
        internal
        pure
        returns (int256)
    {
        unchecked {
            // the squares from which each kind of piece attacks the promotion square
            uint64 straight = Bitboard.rookAttacks(qb, empty);
            uint64 diagonal = Bitboard.bishopAttacks(qb, empty);
            uint64 jumps = Bitboard.knightAttacks(qb);
            uint64 steps = Bitboard.kingAttacks(qb);
            bool defended = Bitboard.pawnAttacks(p.pc[1] & opp & ~pb, !c.white) & qb != 0
                || ((jumps & p.pc[3])
                            | (diagonal & (p.pc[2] | p.pc[5]))
                            | (straight & (p.pc[4] | p.pc[5]))
                            | (steps & p.pc[6])) & opp != 0;
            int256 a; // our cheapest attacker: 300, 500, 900, or 1 for the king alone
            if (((jumps & p.pc[3]) | (diagonal & p.pc[2])) & own != 0) a = 300;
            else if (straight & p.pc[4] & own != 0) a = 500;
            else if ((straight | diagonal) & p.pc[5] & own != 0) a = 900;
            else if (steps & p.pc[6] & own != 0) a = 1;
            return a == 0 || (defended && a == 1) ? PROMOTION : !defended ? int256(-100) : a - 100;
        }
    }

    /// The type of the piece on `bit` (a single square) in `p`, 0 for none.
    function _typeOn(Bitboard.Pos memory p, uint64 bit) internal pure returns (uint8 t) {
        for (t = 1; t <= 6; t++) {
            if (p.pc[t] & bit != 0) return t;
        }
        return 0;
    }

    /// The enemy king's safe squares after our piece of type `t` goes from `from` to `to` (our other attacks as before
    /// the move; a discovered line is not counted, so this errs towards more room).
    function _room(Ctx memory c, uint8 t, uint8 from, uint8 to) internal pure returns (uint64) {
        unchecked {
            uint64 king = uint64(1) << c.enemyKing; // lifted off the board: it can't step back along the line
            uint64 empty = (~(c.p.white | c.p.black) | (uint64(1) << from) | king) & ~(uint64(1) << to);
            uint64 b = uint64(1) << to;
            uint64 a = t == 1
                ? Bitboard.pawnAttacks(b, c.white)
                : t == 3 ? Bitboard.knightAttacks(b) : t == 6 ? Bitboard.kingAttacks(b) : 0;
            if (t == 4 || t == 5) a = Bitboard.rookAttacks(b, empty);
            if (t == 2 || t == 5) a |= Bitboard.bishopAttacks(b, empty);
            return Bitboard.kingAttacks(king) & ~c.opp & ~(c.our1 | a);
        }
    }

    /// The gain from moving a pawn from `from` to `to` when no enemy pawn can stop it on its way (its file and the
    /// two beside it): rank squared, three times as much in the endgame. 0 for a pawn that isn't passed.
    function _passer(Ctx memory c, uint8 from, uint8 to) internal pure returns (int256) {
        unchecked {
            uint256 r = to >> 3;
            uint64 file = FILE_A << (to & 7);
            uint64 lanes = file | ((file << 1) & NOT_A) | ((file >> 1) & NOT_H);
            uint64 ahead = c.white ? ~uint64(0) << ((r + 1) * 8) : (uint64(1) << (r * 8)) - 1;
            if (c.p.pc[1] & c.opp & lanes & ahead != 0) return 0;
            int256 rt = int256(c.white ? r : 7 - r);
            int256 rf = int256(uint256(c.white ? from >> 3 : 7 - (from >> 3)));
            return (rt * rt - rf * rf) * (c.endgame ? int256(3) : int256(1));
        }
    }

    /// The push for progress in a quiet stretch: pawn moves, checks and king pressure, captures (fully when ahead,
    /// a little when not, so even material doesn't trade down to a dead draw). Scaled by how long the stretch is.
    function _progress(Ctx memory c, uint8 t, bool capture, bool check, int256 near) internal pure returns (int256 p) {
        unchecked {
            if (t == 1) p = PROGRESS;
            else if (capture) p = c.ours > c.theirs ? PROGRESS : PROGRESS / 4;
            if (check) p += PROGRESS / 2;
            if (near > 0) p += near * PROGRESS / 4;
            p = p * int256(c.push) / 10_000;
        }
    }

    /// Material won and the piece-square change, with a bonus for castling and for trading pieces when ahead.
    function _gain(Ctx memory c, uint8 from, uint8 to, uint8 t, uint8 victim, bool promo, bool ep)
        internal
        pure
        returns (int256 g)
    {
        unchecked {
            bool black = !c.white;
            g = _value(victim) + (ep ? int256(100) : int256(0));
            if (promo) g += 800 + _position(5, to, black, c.endgame) - _position(1, from, black, c.endgame);
            else g += _positionGain(t, from, to, black, c.endgame);
            if (t == 6 && (to == from + 2 || from == to + 2)) g += 45;
            if (victim >= 2 && victim <= 5 && t >= 2 && t <= 5 && c.ownNonPawn > _value(t)) {
                g += _value(victim) * (c.ours - c.theirs) / (c.ours + c.theirs + 1) / 4;
            }
        }
    }

    /// The leader's score on the real position after it: exact threats against us, the enemy's mate in one,
    /// repetition and stalemate.
    function _exact(Ctx memory c, uint16 m, int256 base) internal pure returns (int256) {
        unchecked {
            Bitboard.Pos memory n = c.n;
            Bitboard.makeMoveInto(c.p, n, m, c.white);
            if (!Bitboard.inCheck(n, !c.white) && !Bitboard.hasLegalMove(n, !c.white)) {
                return c.theirs - c.ours; // stalemate: a draw, worth giving up our material lead
            }
            Maps memory e = _maps(n, !c.white);
            // whether it checks for the enemy's mate in one: only when our king is left at most one safe square
            // (where nearly every mate in one happens), and at club strength not always
            uint64 home = c.white ? n.white : n.black;
            uint64 flights = Bitboard.kingAttacks(n.pc[6] & home) & ~home & ~e.all;
            if (
                flights & (flights - 1) == 0 && _mix(c.seedHash, m ^ 0x30000) % 10_000 < c.guardBps
                    && Bitboard.mateInOne(n, !c.white) != 0
            ) {
                return -MATE;
            }
            int256 threat = c.passers != 0 ? _promotion(c, n) : int256(0);
            uint64 hit = (c.white ? n.white : n.black) & ~n.pc[6] & e.all;
            uint64 defended = hit == 0 ? 0 : Bitboard.attacksBy(n, c.white); // only asked about pieces in `hit`
            while (hit != 0) {
                uint8 sq = Bitboard.lsb(hit);
                hit &= hit - 1;
                uint64 bit = uint64(1) << sq;
                int256 loss = _loss(e, _value(_ourTypeAfter(c, m, sq)), bit, defended & bit != 0);
                if (loss > threat) threat = loss;
            }
            int256 s = base - threat;
            uint8 from = uint8(m >> 6);
            bool irreversible = c.opp & (uint64(1) << (m & 63)) != 0 || c.p.pc[1] & (uint64(1) << from) != 0;
            if (c.history && !irreversible && _seen(c, n, m)) s -= c.ours - c.theirs >= 100 ? int256(100) : int256(35);
            return s;
        }
    }

    /// The type of our piece on `sq` after our move `m`, from the packed board (cheaper than reading the bitboards):
    /// the mover on its new square (a queen if promoted), a castling rook on its new square, else as before.
    function _ourTypeAfter(Ctx memory c, uint16 m, uint8 sq) internal pure returns (uint8) {
        unchecked {
            uint8 to = uint8(m & 63);
            if (sq == to) {
                uint8 t = uint8(c.board >> ((uint256(m) >> 6) << 2)) & 7;
                return t == 1 && (to >> 3 == 7 || to >> 3 == 0) ? 5 : t;
            }
            uint8 before = uint8(c.board >> (uint256(sq) << 2)) & 7;
            return before != 0 ? before : 4;
        }
    }

    /// Whether the position `n` after our move `m` is one of this side's recent positions.
    function _seen(Ctx memory c, Bitboard.Pos memory n, uint16 m) internal pure returns (bool) {
        uint64 key = Chess.positionKey(
            Bitboard.boardAfter(c.board, c.p, m, c.white), n.whiteState, n.blackState, c.white, c.gameNo
        );
        for (uint256 j; j < 8; j++) {
            if (c.previous[j] == key) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- the lone king

    /// After our move: the enemy king's worst-case escape, scored by how close it stays to the edge, how small a box
    /// our rooks and queens leave it, and how near our king is. A check that leaves the king no square mates (it has
    /// nothing else to move); no square without a check is stalemate, and a piece left to the king loses it: both
    /// score -MATE. Our pieces after the move are worked out here rather than by playing it, since the enemy has only
    /// its king: nothing is captured and the board is our pieces plus that king.
    function _mop(Ctx memory c, uint8 from, uint8 to, uint8 t, bool promo, bool check)
        internal
        pure
        returns (int256, bool)
    {
        Bitboard.Pos memory p = c.p;
        uint64 fb = uint64(1) << from;
        uint64 tb = uint64(1) << to;
        uint64 own = (c.own & ~fb) | tb;
        uint64 pawns = p.pc[1] & c.own;
        uint64 knights = p.pc[3] & c.own;
        uint64 rooks = p.pc[4] & c.own;
        uint64 queens = p.pc[5] & c.own;
        uint64 bishops = p.pc[2] & c.own;
        uint8 ownKing = c.ourKing;
        if (t == 1) {
            pawns &= ~fb;
            if (promo) queens |= tb;
            else pawns |= tb;
        } else if (t == 2) {
            bishops = (bishops & ~fb) | tb;
        } else if (t == 3) {
            knights = (knights & ~fb) | tb;
        } else if (t == 4) {
            rooks = (rooks & ~fb) | tb;
        } else if (t == 5) {
            queens = (queens & ~fb) | tb;
        } else {
            ownKing = to;
            if (to == from + 2 || from == to + 2) {
                // castling: the rook comes to the king's other side
                uint32 state = c.white ? p.whiteState : p.blackState;
                uint64 rookFrom = uint64(1) << (uint8(to > from ? state >> 16 : state >> 24) & 63);
                uint64 rookTo = uint64(1) << (to > from ? from + 1 : from - 1);
                rooks = (rooks & ~rookFrom) | rookTo;
                own = (own & ~rookFrom) | rookTo;
            }
        }
        uint8 king = c.enemyKing;
        uint64 kb = uint64(1) << king;
        // with the king lifted off the board (the board is then just our pieces), so it can't step back along a line
        // it is attacked on
        uint64 cover = Bitboard.pawnAttacks(pawns, c.white) | Bitboard.knightAttacks(knights)
            | Bitboard.kingAttacks(uint64(1) << ownKing) | Bitboard.rookAttacks(rooks | queens, ~own)
            | Bitboard.bishopAttacks(bishops | queens, ~own);
        uint64 escapes = Bitboard.kingAttacks(kb) & ~cover;
        if (escapes == 0) return check ? (MATE, true) : (-MATE, false);
        if (escapes & own != 0) return (-MATE, false);
        uint64 majors = rooks | queens;
        int256 worst = MATE;
        int256 replies;
        unchecked {
            while (escapes != 0) {
                uint8 sq = Bitboard.lsb(escapes);
                escapes &= escapes - 1;
                replies++;
                uint256 edge = (EDGE >> (uint256(sq) << 1)) & 3;
                uint256 area = 64;
                uint64 rest = majors;
                while (rest != 0) {
                    uint8 at = Bitboard.lsb(rest);
                    rest &= rest - 1;
                    // a rook's box drives the king to the edge; once there, waiting moves and opposition finish it
                    if (edge == 0 && rooks & (uint64(1) << at) != 0) {
                        area = 0;
                        break;
                    }
                    uint256 mf = at & 7;
                    uint256 mr = at >> 3;
                    uint256 width = mf == (sq & 7) ? 8 : mf < (sq & 7) ? 7 - mf : mf;
                    uint256 height = mr == (sq >> 3) ? 8 : mr < (sq >> 3) ? 7 - mr : mr;
                    if (width * height < area) area = width * height;
                }
                int256 score = int256(3 - edge) * 150 + (14 - _steps(ownKing, sq) * 2) * 18 - int256(area) * 8;
                if (score < worst) worst = score;
            }
        }
        // Keep the escorting king off the defender's back rank: approaching along that rank can
        // leave every closer king move stalemating and make the major piece shuffle forever.
        uint256 kf = king & 7;
        uint256 kr = king >> 3;
        uint256 ownFile = ownKing & 7;
        uint256 orank = ownKing >> 3;
        // Distance from the defender's nearest edge, rather than from any edge of the board.
        uint256 ourEdge = kr == 0
            ? orank
            : kr == 7 ? 7 - orank : kf == 0 ? ownFile : kf == 7 ? 7 - ownFile : (EDGE >> (uint256(ownKing) << 1)) & 3;
        return
            (worst - _steps(ownKing, king) * 2 * 40 + int256(ourEdge > 2 ? 2 : ourEdge) * 80 + (8 - replies) * 3, false);
    }

    /// King steps between two squares.
    function _steps(uint8 a, uint8 b) internal pure returns (int256) {
        uint256 f = a & 7 > b & 7 ? (a & 7) - (b & 7) : (b & 7) - (a & 7);
        uint256 r = a >> 3 > b >> 3 ? (a >> 3) - (b >> 3) : (b >> 3) - (a >> 3);
        return int256(f > r ? f : r);
    }

    // ---------------------------------------------------------------- helpers

    function _maps(Bitboard.Pos memory p, bool white) internal pure returns (Maps memory m) {
        uint64 own = white ? p.white : p.black;
        uint64 empty = ~(p.white | p.black);
        uint64 q = p.pc[5] & own;
        m.pawn = Bitboard.pawnAttacks(p.pc[1] & own, white);
        m.minor = Bitboard.knightAttacks(p.pc[3] & own) | Bitboard.bishopAttacks(p.pc[2] & own, empty);
        m.rook = Bitboard.rookAttacks(p.pc[4] & own, empty);
        m.queen = Bitboard.rookAttacks(q, empty) | Bitboard.bishopAttacks(q, empty);
        m.all = m.pawn | m.minor | m.rook | m.queen | Bitboard.kingAttacks(p.pc[6] & own);
    }

    /// What we stand to lose on a square `bit` holding a piece worth `v`: everything if it isn't defended, else the
    /// difference to the cheapest attacker (nothing if only the king attacks it).
    function _loss(Maps memory e, int256 v, uint64 bit, bool defended) internal pure returns (int256) {
        unchecked {
            if (e.all & bit == 0) return 0;
            if (!defended) return v;
            int256 a = e.pawn & bit != 0
                ? int256(100)
                : e.minor & bit != 0
                    ? int256(300)
                    : e.rook & bit != 0 ? int256(500) : e.queen & bit != 0 ? int256(900) : int256(-1);
            if (a < 0) return 0;
            return v > a ? v - a : int256(0);
        }
    }

    /// Whether a piece of type `t` on `sq` would attack a square around the enemy king.
    function _zoneHits(Ctx memory c, uint8 t, uint8 sq) internal pure returns (int256) {
        return int256(uint256(c.zoneFrom[t] >> sq & 1));
    }

    /// A cheap per-move mix of the seed's hash (splitmix-style), for the seeded mistakes.
    function _mix(uint256 h, uint256 m) internal pure returns (uint256 z) {
        unchecked {
            z = h + m * 0x9e3779b97f4a7c15;
            z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
            z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
            z = (z ^ (z >> 31)) >> 128;
        }
    }

    function _distance(uint8 a, uint8 b) internal pure returns (int256) {
        int256 f = int256(uint256(a & 7)) - int256(uint256(b & 7));
        int256 r = int256(uint256(a >> 3)) - int256(uint256(b >> 3));
        return (f < 0 ? -f : f) + (r < 0 ? -r : r);
    }

    /// Centipawns by piece type, 16 bits each: pawn 100, bishop 320, knight 300, rook 500, queen 900.
    uint256 internal constant VALUES = (100 << 16) | (320 << 32) | (300 << 48) | (500 << 64) | (900 << 80);

    function _value(uint8 t) internal pure returns (int256) {
        return int256((VALUES >> (uint256(t) << 4)) & 0xffff);
    }

    /// File-mirrored int8 piece-square tables (from the v4 strategy helper), for the middlegame and the endgame.
    /// Entry (rank from the side's own back rank) * 4 + (file folded to a-d) is byte 31 - entry of the word.
    function _position(uint8 t, uint8 sq, bool black, bool endgame) internal pure returns (int256 v) {
        uint256 table = _table(t, endgame);
        assembly ("memory-safe") {
            let f := and(sq, 7)
            if gt(f, 3) { f := sub(7, f) }
            let r := shr(3, sq)
            if black { r := sub(7, r) }
            v := signextend(0, byte(sub(31, add(mul(r, 4), f)), table))
        }
    }

    /// The piece-square change of a piece of type `t` going from `from` to `to`: one table read for both squares.
    function _positionGain(uint8 t, uint8 from, uint8 to, bool black, bool endgame) internal pure returns (int256 v) {
        uint256 table = _table(t, endgame);
        assembly ("memory-safe") {
            function at(sq, side, word) -> e {
                let f := and(sq, 7)
                if gt(f, 3) { f := sub(7, f) }
                let r := shr(3, sq)
                if side { r := sub(7, r) }
                e := signextend(0, byte(sub(31, add(mul(r, 4), f)), word))
            }
            v := sub(at(to, black, table), at(from, black, table))
        }
    }

    /// The piece-square table word for type `t`.
    function _table(uint8 t, bool endgame) internal pure returns (uint256 table) {
        assembly ("memory-safe") {
            switch t
            case 1 {
                table := 0x403b363139342f2a322d28234034281c392d211532261a0e16110c070f0a0500
                if endgame { table := 0x7e7e7e7e7b76716c69645f5a6c6054485a4e4236483c3024211c17120f0a0500 }
            }
            case 2 { table := 0x0f0a0500140f0a0519140f0a1e19140f1e19140f19140f0a140f0a05f6f1ece7 }
            case 3 { table := 0x1003f6e91d1003f62a1d1003372a1d10372a1d102a1d10031d1003f6f7eaddd0 }
            case 4 {
                table := 0x060402001f1d1b1906040200f7f5f3f1f7f5f3f1f7f5f3f1f7f5f3f106040200
                if endgame { table := 0x060402001f1d1b19060402000604020006040200060402000604020006040200 }
            }
            case 5 {
                table := 0xd1cecbc8d9d6d3d0e1dedbd8e9e6e3e0f1eeebe8f9f6f3f00906030009060300
                if endgame { table := 0x0906030009060300090603000906030009060300090603000906030009060300 }
            }
            default {
                table := 0x8888888888888888888888889c9c9c9cb5b5b5b5cecececee7e7e7e700282800
                if endgame { table := 0x0f05fbf1190f05fb23190f052d23190f2d23190f23190f05190f05fb0f05fbf1 }
            }
        }
    }
}
