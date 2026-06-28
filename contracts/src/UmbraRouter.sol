// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    IERC20,
    IWPLS,
    IUniV2Pair,
    IUniV3Pool,
    IUniV3Factory,
    IBalancerVault,
    IStableSwap,
    IPermit2
} from "./interfaces/Interfaces.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";

/// @title UmbraRouter — executes engine split routes across V2/V3/Balancer pools.
/// @notice Execution-only. Pulls the user's input, drives the encoded route, enforces
/// a single minAmountOut on the measured output delta, and sweeps everything to the
/// recipient. Holds no resident funds and assumes no standing user allowance. Every
/// amount is measured (balance deltas), so fee-on-transfer tokens are handled exactly.
contract UmbraRouter is ReentrancyGuard {
    using SafeTransfer for address;

    // ---- immutables / config ----
    address public immutable WPLS;
    address public immutable PERMIT2;
    address[] public v3Factories; // index == forkId in the packed pool word
    mapping(address => bool) public allowedVault; // Balancer vaults we may approve
    mapping(address => bool) public allowedStablePool; // PulseX StableSwap pools we may approve
    address public owner;
    address public pendingOwner; // two-step ownership handoff
    bool public paused;

    // V3 swap-callback guard (no EIP-1153 on PulseChain → storage flag). Bounds the
    // callback both by caller (`_v3ExpectedPool`) and amount (`_v3ExpectedAmount`),
    // and is cleared on first pay so a hostile pool can't be paid twice.
    address private _v3ExpectedPool;
    uint256 private _v3ExpectedAmount;

    // ---- flags / pool types ----
    uint8 private constant USE_PERMIT2 = 1;
    uint8 private constant INPUT_IS_NATIVE = 2;
    uint8 private constant OUTPUT_IS_NATIVE = 4;
    uint8 private constant PT_V2 = 0;
    uint8 private constant PT_V3 = 1;
    uint8 private constant PT_BAL = 2;
    uint8 private constant PT_STABLE = 3;

    // Uniswap V3 TickMath sqrt-price bounds (±1 to disable the in-pool limit).
    uint160 private constant MIN_SQRT = 4295128739 + 1;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    uint256 private constant FEE_DEN = 1_000_000;

    // ---- calldata structs (mirror umbra-core::execbuild) ----
    struct Hop {
        uint8 poolType; // 0 V2 | 1 V3 | 2 Balancer
        address tokenIn; // this hop's input (WPLS, never 0x0)
        address tokenOut; // this hop's output
        uint256 pool; // packed: [159..0]=addr [183..160]=feeNum(V2)/feeTier(V3) [191..184]=forkId(V3); Stable: [167..160]=i [175..168]=j
        bytes32 poolData; // Balancer poolId; unused for V2/V3/Stable
    }

    struct Path {
        uint16 inputBps; // share of amountIn (Σ over paths == 10_000)
        Hop[] hops;
    }

    struct ExecuteParams {
        address tokenIn; // 0x0 == native PLS
        address tokenOut; // 0x0 == native PLS
        uint256 amountIn; // == msg.value when INPUT_IS_NATIVE
        uint256 minAmountOut; // global floor, checked on the final delta
        address recipient;
        uint256 deadline;
        uint8 flags;
        Path[] paths;
        bytes permit2; // (PermitTransferFrom, signature) when USE_PERMIT2; else empty
    }

    event Executed(
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    error Paused_();
    error Expired();
    error NoPaths();
    error BadValue();
    error BadBps();
    error HopMismatch();
    error BadPoolType();
    error BadV3Pool();
    error UnauthCallback();
    error InsufficientOutput();
    error OnlyWPLS();
    error NotOwner();
    error NotPendingOwner();
    error SameToken();
    error BadVault();
    error BadStablePool();
    error AmountTooLarge();

    constructor(
        address wpls,
        address permit2,
        address[] memory factories,
        address[] memory vaults,
        address[] memory stablePools
    ) {
        WPLS = wpls;
        PERMIT2 = permit2;
        v3Factories = factories;
        for (uint256 i = 0; i < vaults.length; i++) {
            allowedVault[vaults[i]] = true;
        }
        for (uint256 i = 0; i < stablePools.length; i++) {
            allowedStablePool[stablePools[i]] = true;
        }
        owner = msg.sender;
    }

    // ============================================================ execute

    function execute(ExecuteParams calldata p) external payable nonReentrant returns (uint256) {
        if (paused) revert Paused_();
        if (block.timestamp > p.deadline) revert Expired();
        uint256 n = p.paths.length;
        if (n == 0) revert NoPaths();

        bool nativeIn = p.flags & INPUT_IS_NATIVE != 0;
        bool nativeOut = p.flags & OUTPUT_IS_NATIVE != 0;

        // ---- resolve & pull input, bound to the delta THIS call creates ----
        // All sizing is off `pulledIn` (what this tx actually brought in), never
        // `balanceOf(this)`, so any force-sent / residual balance is inert and only
        // the owner `sweep` can ever move it.
        address tokenInErc = nativeIn ? WPLS : p.tokenIn;
        uint256 inBefore = _balanceOf(tokenInErc, address(this));
        if (nativeIn) {
            if (msg.value != p.amountIn) revert BadValue();
            IWPLS(WPLS).deposit{value: p.amountIn}();
        } else {
            if (msg.value != 0) revert BadValue();
            _pullInput(p, tokenInErc);
        }
        uint256 pulledIn = _balanceOf(tokenInErc, address(this)) - inBefore; // post input-FoT

        // ---- snapshot output (delta excludes any pre-existing balance) ----
        address tokenOutErc = nativeOut ? WPLS : p.tokenOut;
        if (tokenInErc == tokenOutErc) revert SameToken();
        uint256 outBefore = _balanceOf(tokenOutErc, address(this));

        // ---- run split paths over the PULLED input only ----
        uint256 totalBps;
        uint256 consumed;
        for (uint256 i = 0; i < n; i++) {
            Path calldata path = p.paths[i];
            totalBps += path.inputBps;
            // last path takes the remaining pulled amount (absorbs rounding + FoT residue)
            uint256 pathIn = (i == n - 1) ? (pulledIn - consumed) : (pulledIn * path.inputBps) / 10_000;
            consumed += pathIn;
            if (pathIn != 0) _runPath(path, tokenInErc, pathIn);
        }
        if (totalBps != 10_000) revert BadBps();

        // ---- single slippage check on the measured delta ----
        uint256 outDelta = _balanceOf(tokenOutErc, address(this)) - outBefore;
        if (outDelta < p.minAmountOut) revert InsufficientOutput();

        // ---- deliver ----
        if (nativeOut) {
            IWPLS(WPLS).withdraw(outDelta);
            p.recipient.safeTransferETH(outDelta);
        } else {
            p.tokenOut.safeTransfer(p.recipient, outDelta);
        }
        emit Executed(msg.sender, p.recipient, p.tokenIn, p.tokenOut, p.amountIn, outDelta);
        return outDelta;
    }

    // ============================================================ funding

    function _pullInput(ExecuteParams calldata p, address token) private {
        if (p.flags & USE_PERMIT2 != 0) {
            (IPermit2.PermitTransferFrom memory permit, bytes memory sig) =
                abi.decode(p.permit2, (IPermit2.PermitTransferFrom, bytes));
            IPermit2(PERMIT2).permitTransferFrom(
                permit,
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: p.amountIn}),
                msg.sender,
                sig
            );
        } else {
            token.safeTransferFrom(msg.sender, address(this), p.amountIn);
        }
    }

    // ============================================================ path / hops

    function _runPath(Path calldata path, address tokenIn0, uint256 amount0) private {
        address curToken = tokenIn0;
        uint256 curAmount = amount0;
        uint256 h = path.hops.length;
        for (uint256 j = 0; j < h; j++) {
            Hop calldata hop = path.hops[j];
            if (hop.tokenIn != curToken) revert HopMismatch();
            uint8 pt = hop.poolType;
            if (pt == PT_V2) curAmount = _swapV2(hop, curAmount);
            else if (pt == PT_V3) curAmount = _swapV3(hop, curAmount);
            else if (pt == PT_BAL) curAmount = _swapBalancer(hop, curAmount);
            else if (pt == PT_STABLE) curAmount = _swapStable(hop, curAmount);
            else revert BadPoolType();
            curToken = hop.tokenOut;
        }
    }

    /// V2 constant-product hop. Direction derived from token ordering (pools sort
    /// token0 < token1), so nothing about direction is trusted from the caller.
    function _swapV2(Hop calldata hop, uint256 amountIn) private returns (uint256) {
        address pair = address(uint160(hop.pool));
        uint256 feeNum = (hop.pool >> 160) & 0xFFFFFF;
        if (feeNum == 0) feeNum = 997000;
        bool zeroForOne = hop.tokenIn < hop.tokenOut;

        // fund the pair; measure what it actually received (input-side FoT)
        uint256 pairBefore = _balanceOf(hop.tokenIn, pair);
        hop.tokenIn.safeTransfer(pair, amountIn);
        uint256 inActual = _balanceOf(hop.tokenIn, pair) - pairBefore;

        (uint112 r0, uint112 r1,) = IUniV2Pair(pair).getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inWithFee = inActual * feeNum;
        uint256 amountOut = (inWithFee * rOut) / (rIn * FEE_DEN + inWithFee);
        (uint256 a0, uint256 a1) = zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));

        uint256 outBefore = _balanceOf(hop.tokenOut, address(this));
        IUniV2Pair(pair).swap(a0, a1, address(this), "");
        return _balanceOf(hop.tokenOut, address(this)) - outBefore; // output-side FoT
    }

    /// V3 concentrated hop. The pool is independently authenticated via the fork's
    /// factory; the callback only pays the in-flight, factory-vouched pool.
    function _swapV3(Hop calldata hop, uint256 amountIn) private returns (uint256) {
        address pool = address(uint160(hop.pool));
        uint24 feeTier = uint24((hop.pool >> 160) & 0xFFFFFF);
        uint8 forkId = uint8((hop.pool >> 184) & 0xFF);

        address legit = IUniV3Factory(v3Factories[forkId]).getPool(hop.tokenIn, hop.tokenOut, feeTier);
        if (legit != pool || pool == address(0)) revert BadV3Pool();
        if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();

        bool zeroForOne = hop.tokenIn < hop.tokenOut;
        _v3ExpectedPool = pool; // arm: only this pool may call back...
        _v3ExpectedAmount = amountIn; // ...and only for at most this input amount
        uint256 outBefore = _balanceOf(hop.tokenOut, address(this));
        IUniV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT : MAX_SQRT,
            abi.encode(hop.tokenIn)
        );
        _v3ExpectedPool = address(0); // disarm (also cleared on pay)
        return _balanceOf(hop.tokenOut, address(this)) - outBefore;
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata data) external {
        _v3Pay(d0, d1, data);
    }

    function pancakeV3SwapCallback(int256 d0, int256 d1, bytes calldata data) external {
        _v3Pay(d0, d1, data);
    }

    /// Universal V3 swap-callback handler. The forks each rename the selector
    /// (uniswapV3/pancakeV3/libertyV3/pdexV3/9inchV3/...), but all share the
    /// (int256 amount0Delta, int256 amount1Delta, bytes data) signature. The
    /// in-flight + factory-vouched pool guard in `_v3Pay` makes this safe for any
    /// selector name — we never trust the selector, only the authenticated caller.
    fallback() external {
        if (msg.data.length < 4) revert UnauthCallback(); // guard the msg.data[4:] slice
        (int256 d0, int256 d1, bytes memory data) = abi.decode(msg.data[4:], (int256, int256, bytes));
        _v3Pay(d0, d1, data);
    }

    function _v3Pay(int256 d0, int256 d1, bytes memory data) private {
        address expected = _v3ExpectedPool;
        if (expected == address(0) || msg.sender != expected) revert UnauthCallback();
        uint256 cap = _v3ExpectedAmount; // capture before clearing
        _v3ExpectedPool = address(0); // single-shot: a hostile pool can't be paid twice
        _v3ExpectedAmount = 0; // clear alongside the pool (relies on strict-nesting of hops)
        uint256 owed = d0 > 0 ? uint256(d0) : uint256(d1);
        if (owed > cap) revert AmountTooLarge(); // never pay more than the swap's input
        address tokenIn = abi.decode(data, (address));
        tokenIn.safeTransfer(msg.sender, owed);
    }

    /// Balancer V2 (Phux) hop. External/external funds; lazy max approval to the Vault.
    function _swapBalancer(Hop calldata hop, uint256 amountIn) private returns (uint256) {
        address vault = address(uint160(hop.pool));
        // never grant an approval to a caller-supplied address; only allowlisted vaults
        if (!allowedVault[vault]) revert BadVault();
        if (IERC20(hop.tokenIn).allowance(address(this), vault) < amountIn) {
            hop.tokenIn.safeApprove(vault, type(uint256).max);
        }
        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: hop.poolData,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: hop.tokenIn,
            assetOut: hop.tokenOut,
            amount: amountIn,
            userData: ""
        });
        IBalancerVault.FundManagement memory f = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        uint256 outBefore = _balanceOf(hop.tokenOut, address(this));
        IBalancerVault(vault).swap(s, f, 0, type(uint256).max);
        return _balanceOf(hop.tokenOut, address(this)) - outBefore;
    }

    /// PulseX StableSwap (Curve-style) hop. Pool must be allowlisted (never grant
    /// an approval to a caller-supplied address); coin indices (i=in, j=out) are
    /// packed in the pool word; output measured by balance delta (FoT-safe).
    function _swapStable(Hop calldata hop, uint256 amountIn) private returns (uint256) {
        address pool = address(uint160(hop.pool));
        if (!allowedStablePool[pool]) revert BadStablePool();
        uint256 i = (hop.pool >> 160) & 0xFF;
        uint256 j = (hop.pool >> 168) & 0xFF;
        if (IERC20(hop.tokenIn).allowance(address(this), pool) < amountIn) {
            hop.tokenIn.safeApprove(pool, type(uint256).max);
        }
        uint256 outBefore = _balanceOf(hop.tokenOut, address(this));
        IStableSwap(pool).exchange(i, j, amountIn, 0);
        return _balanceOf(hop.tokenOut, address(this)) - outBefore;
    }

    // ============================================================ helpers / admin

    function _balanceOf(address token, address who) private view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }

    function v3FactoriesLength() external view returns (uint256) {
        return v3Factories.length;
    }

    receive() external payable {
        if (msg.sender != WPLS) revert OnlyWPLS();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setPaused(bool v) external onlyOwner {
        paused = v;
    }

    /// Allow/deny a PulseX StableSwap pool the router may route through. Lets new
    /// stable pools be added without a redeploy. Owner is trusted (use a multisig).
    function setStablePool(address pool, bool ok) external onlyOwner {
        allowedStablePool[pool] = ok;
    }

    function setVault(address vault, bool ok) external onlyOwner {
        allowedVault[vault] = ok;
    }

    /// Two-step ownership handoff: the current owner nominates, the nominee accepts.
    /// Prevents bricking admin by transferring to a wrong/zero address (a nominee that
    /// can't sign never accepts). Nominating address(0) cancels a pending transfer.
    function transferOwnership(address n) external onlyOwner {
        pendingOwner = n;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// Incident response: revoke a standing approval to a now-distrusted vault/pool.
    function revokeApproval(address token, address spender) external onlyOwner {
        token.safeApprove(spender, 0);
    }

    /// Rescue tokens force-sent to the router. Normal execution leaves zero balance,
    /// so this only ever moves dust/mistaken transfers. Owner is trusted (use a multisig).
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0)) to.safeTransferETH(amount);
        else token.safeTransfer(to, amount);
    }
}
