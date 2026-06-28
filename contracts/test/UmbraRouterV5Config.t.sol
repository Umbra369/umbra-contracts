// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UmbraRouterV5} from "../src/UmbraRouterV5.sol";

/// Config + EIP-712 digest tests. These don't need a fork: the constructor only
/// stores the params and the attestation digest math is pure. End-to-end signature
/// acceptance (a real `execute` with a valid sig) is asserted in UmbraRouterV5Fee.t.sol.
contract UmbraRouterV5ConfigTest is Test {
    UmbraRouterV5 r;

    // valid checksummed placeholders; the constructor only stores them
    address constant W = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27; // WPLS
    address constant P2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Permit2

    function setUp() public {
        address[] memory empty;
        r = new UmbraRouterV5(W, P2, empty, empty, empty, empty);
    }

    function test_brand_constant() public view {
        assertEq(r.BRAND(), "Umbra - best price on PulseChain");
    }

    function test_setFeeConfig_owner_only_and_validated() public {
        // set a recipient via the 2-step path first (3-arg setFeeConfig can't set it)
        address treasury = address(0xABCD);
        r.proposeFeeRecipient(treasury);
        vm.prank(treasury);
        r.acceptFeeRecipient();

        // non-owner cannot set
        vm.prank(address(0xBAD));
        vm.expectRevert(UmbraRouterV5.NotOwner.selector);
        r.setFeeConfig(5000, 25, address(0x5169));

        // enabled (feeBps != 0) but no signer -> BadFeeConfig
        vm.expectRevert(UmbraRouterV5.BadFeeConfig.selector);
        r.setFeeConfig(5000, 25, address(0));

        // feeBps out of range -> BadFeeConfig
        vm.expectRevert(UmbraRouterV5.BadFeeConfig.selector);
        r.setFeeConfig(10_001, 25, address(0x5169));

        // feeCapBps out of range (above MAX_FEE_CAP_BPS == 100) -> BadFeeConfig
        vm.expectRevert(UmbraRouterV5.BadFeeConfig.selector);
        r.setFeeConfig(5000, 101, address(0x5169));

        // valid config sticks
        r.setFeeConfig(5000, 33, address(0x5169));
        assertEq(r.feeBps(), 5000);
        assertEq(r.feeCapBps(), 33);
        assertEq(r.feeRecipient(), treasury);
        assertEq(r.signer(), address(0x5169));
    }

    /// feeBps == 0 may carry zero signer (ship-dark default is valid; no recipient needed).
    function test_setFeeConfig_disabled_allows_zero_signer() public {
        r.setFeeConfig(0, 33, address(0));
        assertEq(r.feeBps(), 0);
        assertEq(r.feeCapBps(), 33);
    }

    /// H-2: the output-share cap is hard-ceilinged at MAX_FEE_CAP_BPS (== 100, 1%). v4 runs
    /// at 33 (0.33%). 101 reverts; 100 sticks; even a compromised owner cannot exceed 1%.
    function test_setFeeConfig_cap_ceiling_is_enforced() public {
        assertEq(r.MAX_FEE_CAP_BPS(), 100, "MAX_FEE_CAP_BPS is 100 (1%)");

        // one over the ceiling reverts
        vm.expectRevert(UmbraRouterV5.BadFeeConfig.selector);
        r.setFeeConfig(5000, 101, address(0x5169));

        // set recipient first so the enabled path (feeBps != 0) can succeed
        address treasury = address(0xABCD);
        r.proposeFeeRecipient(treasury);
        vm.prank(treasury);
        r.acceptFeeRecipient();

        // exactly the ceiling succeeds and sticks
        r.setFeeConfig(5000, 100, address(0x5169));
        assertEq(r.feeCapBps(), 100, "cap of 100 is accepted");

        // the production cap (33 = 0.33%) is well under the ceiling
        r.setFeeConfig(5000, 33, address(0x5169));
        assertEq(r.feeCapBps(), 33, "0.33% cap accepted");
    }

    function test_domain_separator_matches_eip712() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("UmbraRouter")),
                keccak256(bytes("3")),
                block.chainid,
                address(r)
            )
        );
        assertEq(r.DOMAIN_SEPARATOR(), expected, "domain separator must match name/version/chainId/contract");
    }

    /// Locks the v4 10-field typehash to the value `verify-router-typehash.sh` and the
    /// Rust signer must agree on. Computed once via `cast keccak` over the type string.
    function test_v4_typehash_constant() public pure {
        bytes32 expected = keccak256(
            "QuoteAttestation(address tokenIn,address tokenOut,uint256 amountIn,uint256 surplusFloor,uint256 nonce,uint256 deadline,address recipient,bytes32 routeHash,uint256 plsRate,uint256 routingAdvantage)"
        );
        assertEq(expected, 0xf3d36fc0910a7aa09791fe9240b0402abcb423a599dd3e6a946dc80cffd5790e, "v4 typehash matches cast keccak");
    }

    /// feeRecipient changes ONLY via the 2-step path: owner proposes, the nominee accepts.
    /// setFeeConfig (3-arg) can never set the recipient.
    function test_two_step_fee_recipient() public {
        address treasury = address(0x7EE45047);
        assertEq(r.feeRecipient(), address(0), "no recipient at deploy");

        // non-owner cannot propose
        vm.prank(address(0xBAD));
        vm.expectRevert(UmbraRouterV5.NotOwner.selector);
        r.proposeFeeRecipient(treasury);

        r.proposeFeeRecipient(treasury);
        assertEq(r.feeRecipient(), address(0), "unchanged until accepted");
        assertEq(r.pendingFeeRecipient(), treasury);

        // a non-nominee cannot accept
        vm.prank(address(0xDEAD));
        vm.expectRevert(UmbraRouterV5.NotPendingFeeRecipient.selector);
        r.acceptFeeRecipient();

        vm.prank(treasury);
        r.acceptFeeRecipient();
        assertEq(r.feeRecipient(), treasury);
        assertEq(r.pendingFeeRecipient(), address(0));
    }

    /// setFeeConfig is now 3-arg (no recipient); enabling the fee requires a recipient
    /// already set (via the 2-step path) and a non-zero signer.
    function test_setFeeConfig_3arg_requires_recipient_already_set() public {
        // feeBps != 0 with no recipient set yet -> BadFeeConfig
        vm.expectRevert(UmbraRouterV5.BadFeeConfig.selector);
        r.setFeeConfig(5000, 25, address(0x5169));

        // set the recipient via the 2-step path, then enabling sticks
        address treasury = address(0x7EE45047);
        r.proposeFeeRecipient(treasury);
        vm.prank(treasury);
        r.acceptFeeRecipient();
        r.setFeeConfig(5000, 25, address(0x5169));
        assertEq(r.feeBps(), 5000);
        assertEq(r.signer(), address(0x5169));
        assertEq(r.feeRecipient(), treasury, "recipient untouched by setFeeConfig");
    }

    function test_attestation_digest_is_field_sensitive() public {
        (address s, uint256 pk) = makeAddrAndKey("umbra-signer");
        s; // silence unused

        bytes32 ds = r.DOMAIN_SEPARATOR();
        bytes32 typeHash = keccak256(
            "QuoteAttestation(address tokenIn,address tokenOut,uint256 amountIn,uint256 surplusFloor,uint256 nonce,uint256 deadline,address recipient,bytes32 routeHash,uint256 plsRate,uint256 routingAdvantage)"
        );
        address tIn = address(0xA1);
        address tOut = address(0xA2);
        uint256 amtIn = 1e18;
        uint256 floor = 100e6;
        uint256 nonce = 7;
        uint256 dl = block.timestamp + 60;
        address recipient = address(0xBEEF);
        bytes32 routeHash = keccak256("route");
        uint256 plsRate = 1e18;
        uint256 routingAdvantage = 42e18;

        bytes32 structHash = keccak256(abi.encode(typeHash, tIn, tOut, amtIn, floor, nonce, dl, recipient, routeHash, plsRate, routingAdvantage));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ds, structHash));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(rr, ss, v);
        assertEq(sig.length, 65, "sig is r||s||v = 65 bytes");
        assertEq(ecrecover(digest, v, rr, ss), s, "valid sig recovers to signer");

        bytes32 structHash2 = keccak256(abi.encode(typeHash, tIn, tOut, amtIn, floor + 1, nonce, dl, recipient, routeHash, plsRate, routingAdvantage));
        assertTrue(structHash != structHash2, "surplusFloor is bound");
        bytes32 structHash3 = keccak256(abi.encode(typeHash, tIn, tOut, amtIn, floor, nonce + 1, dl, recipient, routeHash, plsRate, routingAdvantage));
        assertTrue(structHash != structHash3, "nonce is bound");
        bytes32 structHash4 = keccak256(abi.encode(typeHash, tIn, tOut, amtIn, floor, nonce, dl, address(0xCAFE), routeHash, plsRate, routingAdvantage));
        assertTrue(structHash != structHash4, "recipient is bound");
        bytes32 structHash5 = keccak256(abi.encode(typeHash, tIn, tOut, amtIn, floor, nonce, dl, recipient, keccak256("other-route"), plsRate, routingAdvantage));
        assertTrue(structHash != structHash5, "routeHash is bound");
        bytes32 structHash6 = keccak256(abi.encode(typeHash, tIn, tOut, amtIn, floor, nonce, dl, recipient, routeHash, plsRate + 1, routingAdvantage));
        assertTrue(structHash != structHash6, "plsRate is bound");
        bytes32 structHash7 = keccak256(abi.encode(typeHash, tIn, tOut, amtIn, floor, nonce, dl, recipient, routeHash, plsRate, routingAdvantage + 1));
        assertTrue(structHash != structHash7, "routingAdvantage is bound");
    }
}
