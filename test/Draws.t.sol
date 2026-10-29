// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {Chess} from "../src/Chess.sol";
import {Base} from "./Base.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";

/// Each way a game ends, from exact positions: the move is applied directly and the end is checked.
contract DrawsTest is Base {
    function setUp() public {
        setUpMainDuel();
    }

    function ends(uint16 move, uint8 want) internal {
        uint32 gameNo = st().gameNo;
        vm.recordLogs();
        hook.applyMove(pool, move, address(0xA11CE), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool over;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == OVER) {
                (, uint8 result,) = abi.decode(logs[i].data, (uint32, uint8, uint16));
                assertEq(result, want, "result");
                over = true;
            }
        }
        assertTrue(over, "game over");
        IMDuelHook.Game memory g = st();
        assertEq(g.gameNo, gameNo + 1, "next game started");
        assertEq(g.ply, 0);
        assertEq(g.board, Chess.START_BOARD);
        assertEq(g.moveResult, want);
    }

    function test_checkmate() public {
        uint256 b;
        b = put(b, "g1", 6);
        b = put(b, "a1", 4);
        b = put(b, "h8", 14);
        b = put(b, "g7", 9);
        b = put(b, "h7", 9);
        hook.setPosition(id, b, side("g1"), side("h8"), 0, 0);
        ends(mv("a1", "a8"), 1); // back-rank mate: White wins
    }

    function test_stalemate() public {
        uint256 b;
        b = put(b, "f7", 6);
        b = put(b, "g5", 5);
        b = put(b, "h8", 14);
        hook.setPosition(id, b, side("f7"), side("h8"), 0, 0);
        ends(mv("g5", "g6"), 3); // Black king has no move and is not in check
    }

    function test_tooFewPiecesToMate() public {
        uint256 b;
        b = put(b, "e1", 6);
        b = put(b, "d4", 3);
        b = put(b, "e8", 14);
        b = put(b, "c6", 9);
        hook.setPosition(id, b, side("e1"), side("e8"), 0, 0);
        ends(mv("d4", "c6"), 3); // knight takes the last pawn: king and knight vs king
    }

    function test_quietMoveLimit() public {
        hook.setPosition(id, Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, 0, hook.MAX_QUIET_PLY() - 1);
        ends(mv("g1", "f3"), 3);
    }

    function test_moveCap() public {
        hook.setPosition(id, Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, hook.MAX_PLY() - 1, 0);
        ends(mv("g8", "f6"), 3);
    }

    function test_thirdRepetition() public {
        uint16[4] memory cycle = [mv("g1", "f3"), mv("g8", "f6"), mv("f3", "g1"), mv("f6", "g8")];
        for (uint256 i; i < 7; i++) {
            hook.applyMove(pool, cycle[i % 4], address(0xA11CE), 0); // a played move enters the memory at once
        }
        ends(cycle[3], 3); // the start position a third time
    }

    function test_ordinaryMoveDoesNotEndTheGame() public {
        vm.recordLogs();
        hook.applyMove(pool, mv("e2", "e4"), address(0xA11CE), 0);
        assertEq(count(vm.getRecordedLogs(), OVER), 0);
        assertEq(st().ply, 1);
    }
}
