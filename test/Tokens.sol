// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// Refuses transfers to blocked addresses (like a token with a blocklist).
contract BlockToken is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Block", "BLK", 18) {}

    function block_(address a) external {
        blocked[a] = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transferFrom(from, to, amount);
    }
}

/// Burns 1% of every transfer (a fee-on-transfer token).
contract SkimToken is MockERC20 {
    constructor() MockERC20("Skim", "SKM", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 cut = amount / 100;
        super.transferFrom(from, to, amount - cut);
        _burn(from, cut);
        return true;
    }
}

/// On a transfer to `target`, calls back into `callee` with `data` and fails if that fails (a re-entering token).
contract ReenterToken is MockERC20 {
    address public target;
    address public callee;
    bytes public data;

    constructor() MockERC20("Reenter", "RNT", 18) {}

    function arm(address target_, address callee_, bytes calldata data_) external {
        (target, callee, data) = (target_, callee_, data_);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == target && callee != address(0)) {
            (bool ok,) = callee.call(data);
            require(ok, "callback failed");
        }
        return super.transfer(to, amount);
    }
}

/// transfer and transferFrom return nothing (like USDT).
contract VoidToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
