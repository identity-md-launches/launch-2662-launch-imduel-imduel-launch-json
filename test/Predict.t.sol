// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Base} from "./Base.sol";

/// A bot that tries to know its move before it trades. In one transaction it tries each candidate size inside a call it
/// reverts (undoing everything but the answer), looks for a move of its own played by that trade, and trades for real
/// only with a size whose move captures. With instant moves this took every capture (review 3); with block turns its
/// own move is only played in a later block, rolled by its bid block's hash, so the trial never shows it.
contract Picker {
    using PoolIdLibrary for PoolKey;

    error Outcome(bool moved, uint8 captured);

    IMDuelHook immutable hook;
    PoolSwapTest immutable router;

    constructor(IMDuelHook hook_, PoolSwapTest router_, PoolKey memory key) {
        (hook, router) = (hook_, router_);
        for (uint256 i; i < 2; i++) {
            MockERC20 t = MockERC20(Currency.unwrap(i == 0 ? key.currency0 : key.currency1));
            t.mint(address(this), 1e30);
            t.approve(address(router_), type(uint256).max);
        }
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 size) internal {
        router.swap(key, SwapParams(zeroForOne, -int256(size), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
    }

    /// Makes the trade, then reverts with the move of its own it played (if any).
    function trial(PoolKey memory key, bool zeroForOne, uint256 size) external {
        require(msg.sender == address(this));
        IMDuelHook.Game memory a = hook.game(key.toId());
        _swap(key, zeroForOne, size);
        IMDuelHook.Game memory g = hook.game(key.toId());
        bool played = g.movePly != a.movePly || g.moveGameNo != a.moveGameNo;
        revert Outcome(played && g.moveOwner == address(this), g.moveCaptured);
    }

    /// Trades only if one of `tries` sizes from `size` up (1 wei apart) plays a capturing move; returns that size.
    function farm(PoolKey memory key, bool zeroForOne, uint256 size, uint256 tries) external returns (uint256 used, uint8 captured) {
        for (uint256 i; i < tries; i++) {
            try this.trial(key, zeroForOne, size + i) {} catch (bytes memory r) {
                if (bytes4(r) != Outcome.selector) continue;
                (bool moved, uint8 c) = abi.decode(_tail(r), (bool, uint8));
                if (moved && c != 0) {
                    _swap(key, zeroForOne, size + i);
                    return (size + i, c);
                }
            }
        }
    }

    function _tail(bytes memory r) internal pure returns (bytes memory out) {
        out = new bytes(r.length - 4);
        for (uint256 i; i < out.length; i++) out[i] = r[i + 4];
    }
}

contract PredictTest is Base {
    using PoolIdLibrary for PoolKey;

    /// Over a game, the bot never finds a capturing move of its own to take, while the game's captures go to the
    /// traders who bid for them blind.
    function test_aBotCannotPickItsOwnCapturingMoves() public {
        setUpMainDuel();
        Picker bot = new Picker(hook, swapRouter, pool);
        uint256 botMoves;
        uint256 botCaptures;
        uint256 otherMoves;
        uint256 otherCaptures;
        for (uint256 b; b < 160 && st().gameNo == 0; b++) {
            next(12);
            uint256 team = toMove();
            (uint256 used, uint8 captured) = bot.farm(pool, team == 1, 1e15, 8); // eight sizes, 1 wei apart
            if (used != 0) {
                botMoves++;
                if (captured != 0) botCaptures++;
                assertEq(st().moveOwner, address(bot), "its own move");
            } else {
                trade(team, 1e15, address(0)); // someone else plays the quiet move
                otherMoves++;
                if (st().moveCaptured != 0) otherCaptures++;
            }
        }
        emit log_named_uint("bot moves", botMoves);
        emit log_named_uint("other moves", otherMoves);
        emit log_named_uint("captures among other moves", otherCaptures);
        assertEq(botMoves, 0, "the bot could not see a move of its own in advance");
        assertGt(otherCaptures, 5, "the captures went to blind bids");
    }
}
