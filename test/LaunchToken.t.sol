// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = address(0xFAC7);

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Locker");
        assertEq(token.symbol(), "LOCKER");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(0xCAFE), 1_000e18));
        assertEq(token.balanceOf(address(0xCAFE)), 1_000e18);
        assertEq(token.balanceOf(deployer), 10 ** 27 - 1_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferFromRespectsAllowance() public {
        vm.prank(deployer);
        token.approve(address(this), 5e18);
        token.transferFrom(deployer, address(this), 5e18);
        assertEq(token.balanceOf(address(this)), 5e18);
        vm.expectRevert();
        token.transferFrom(deployer, address(this), 1);
    }

    function test_noMintOrAdminSurface() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "burnFrom(address,uint256)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
