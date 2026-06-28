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
    IPermit2,
    IBalancerV3Router,
    IPermit2Allowance
} from "./interfaces/Interfaces.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";

//  ██╗   ██╗███╗   ███╗██████╗ ██████╗  █████╗
//  ██║   ██║████╗ ████║██╔══██╗██╔══██╗██╔══██╗
//  ██║   ██║██╔████╔██║██████╔╝██████╔╝███████║
//  ██║   ██║██║╚██╔╝██║██╔══██╗██╔══██╗██╔══██║
//  ╚██████╔╝██║ ╚═╝ ██║██████╔╝██║  ██║██║  ██║
//   ╚═════╝ ╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
//  Best price on PulseChain — proven on-chain before you sign.
//  We charge a flat 0.33% on every swap, hard-capped at 1% — never more.

/// @title UmbraRouterV3 — executes engine split routes across V2/V3/Balancer pools.
/// @notice Execution-only. Pulls the user's input, drives the encoded route, enforces
/// a single minAmountOut on the measured output delta, and sweeps everything to the
/// recipient. Holds no resident funds and assumes no standing user allowance. Every
/// amount is measured (balance deltas), so fee-on-transfer tokens are handled exactly.
/// @dev v4 charges a flat fee: an EIP-712 Umbra-signed quote attests `surplusFloor = 0`,
/// so the whole output counts as surplus and the contract takes `min(feeBps·output,
/// feeCapBps·output) = feeCapBps·output` (0.33% at `feeCapBps = 33`), paid to Treasury,
/// delivering `net` to the user. `feeCapBps` is hard-ceilinged at MAX_FEE_CAP_BPS (1%).
/// Ships dark (`feeBps = 0` ⇒ fee path inert).
contract UmbraRouterV3 is ReentrancyGuard {
    using SafeTransfer for address;

    // ---- immutables / config ----
    address public immutable WPLS;
    address public immutable PERMIT2;
    address[] public v3Factories; // index == forkId in the packed pool word
    mapping(address => bool) public allowedVault; // Balancer vaults we may approve
    mapping(address => bool) public allowedStablePool; // PulseX StableSwap pools we may approve
    // Balancer-V3 (Tide) routers we may route through; maps router => its Permit2 (0 = not allowed).
    mapping(address router => address permit2) public allowedV3Router;
    address public owner;
    address public pendingOwner; // two-step ownership handoff
    bool public paused;

    // ---- surplus fee config (owner-set; mirrors setStablePool/setVault pattern) ----
    uint16 public feeBps;        // share of surplus, e.g. 5000 = 50%
    uint16 public feeCapBps;     // hard ceiling as a share of output, e.g. 25 = 0.25%
    address public feeRecipient; // Treasury
    address public pendingFeeRecipient; // two-step feeRecipient handoff
    address public signer;       // Umbra quote-attestation signer
    string public constant BRAND = "Umbra - best price on PulseChain";

    // ---- on-chain protocol-stats tally (accrues only on signed swaps; tamper-proof) ----
    uint256 public totalPlsRouted;        // Σ realized outDelta * signed plsRate / 1e18
    uint256 public totalRoutingAdvantage; // Σ signed routingAdvantage (PLS, gross/before-fee)
    uint256 public swapCount;             // count of signed swaps executed

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
    uint8 private constant PT_BALV3 = 4;

    // Uniswap V3 TickMath sqrt-price bounds (±1 to disable the in-pool limit).
    uint160 private constant MIN_SQRT = 4295128739 + 1;
    uint160 private constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    uint256 private constant FEE_DEN = 1_000_000;

    // ---- EIP-712 quote attestation (binds the honest surplusFloor + route + expiry) ----
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "QuoteAttestation(address tokenIn,address tokenOut,uint256 amountIn,uint256 surplusFloor,uint256 nonce,uint256 deadline,address recipient,bytes32 routeHash,uint256 plsRate,uint256 routingAdvantage)"
    );
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// Consumed quote digests — each EIP-712 attestation is single-use (audit H-1, anti-replay).
    mapping(bytes32 => bool) public usedQuote;

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
        uint256 minAmountOut; // global floor, checked on the NET (post-fee) delta
        uint256 surplusFloor; // disjoint-route output; attested by `umbraSig`
        uint256 quoteNonce; // unique per signed quote — makes each attestation single-use (anti-replay)
        address recipient;
        uint256 deadline;
        uint8 flags;
        Path[] paths;
        bytes permit2; // (PermitTransferFrom, signature) when USE_PERMIT2; else empty
        bytes umbraSig; // EIP-712 sig over the QuoteAttestation (verified when feeBps != 0)
        uint256 plsRate; // output-token price in PLS as PLS-wei per output-wei * 1e18 (signed)
        uint256 routingAdvantage; // max(0, umbra - pulsex) valued in PLS (signed)
    }

    event Executed(
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event FeeTaken(address indexed recipient, address token, uint256 surplus, uint256 fee);

    error Paused_();
    error Expired();
    error NoPaths();
    error BadValue();
    error BadBps();
    error HopMismatch();
    error BadPoolType();
    error BadV2Pool();
    error BadV3Pool();
    error UnauthCallback();
    error InsufficientOutput();
    error OnlyWPLS();
    error NotOwner();
    error NotPendingOwner();
    error NotPendingFeeRecipient();
    error SameToken();
    error BadVault();
    error BadStablePool();
    error BadV3Router();
    error AmountTooLarge();
    error BadFeeConfig();
    error BadSig();

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

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("UmbraRouter")),
                keccak256(bytes("3")),
                block.chainid,
                address(this)
            )
        );
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

        // ---- surplus fee (only when enabled) ----
        uint256 fee;
        if (feeBps != 0) {
            _verifyQuote(p); // attests surplusFloor + binds tokenIn/out/amountIn/recipient/route/rate/advantage
            // tally the realized volume + advantage from the tamper-proof signed fields
            totalPlsRouted += (outDelta * p.plsRate) / 1e18;
            totalRoutingAdvantage += p.routingAdvantage;
            unchecked { swapCount += 1; }
            uint256 surplus = outDelta > p.surplusFloor ? outDelta - p.surplusFloor : 0;
            fee = (surplus * feeBps) / 10_000;
            uint256 cap = (outDelta * feeCapBps) / 10_000;
            if (fee > cap) fee = cap;
            if (surplus != 0) emit FeeTaken(feeRecipient, p.tokenOut, surplus, fee);
        }
        uint256 net = outDelta - fee;

        // ---- deliver: for ERC20 outputs, check minAmountOut on the recipient's ACTUAL
        // received amount (a fee-on-transfer output token can tax the final router->recipient
        // transfer; checking before transfer would under-deliver). A revert rolls back. ----
        uint256 delivered;
        if (nativeOut) {
            if (net < p.minAmountOut) revert InsufficientOutput();
            IWPLS(WPLS).withdraw(outDelta);
            p.recipient.safeTransferETH(net);
            if (fee != 0) feeRecipient.safeTransferETH(fee);
            delivered = net;
        } else {
            uint256 recBefore = _balanceOf(p.tokenOut, p.recipient);
            p.tokenOut.safeTransfer(p.recipient, net);
            delivered = _balanceOf(p.tokenOut, p.recipient) - recBefore;
            if (delivered < p.minAmountOut) revert InsufficientOutput();
            if (fee != 0) p.tokenOut.safeTransfer(feeRecipient, fee);
        }
        emit Executed(msg.sender, p.recipient, p.tokenIn, p.tokenOut, p.amountIn, delivered);
        return delivered;
    }

    // ============================================================ quote attestation

    /// Reverts BadSig() unless `umbraSig` is an EIP-712 signature by `signer` over the
    /// QuoteAttestation binding (tokenIn, tokenOut, amountIn, surplusFloor, deadline).
    /// This is the tamper-proof for `surplusFloor`: a user can't zero it out to dodge
    /// the fee, and the short `deadline` is the anti-stale guard.
    function _verifyQuote(ExecuteParams calldata p) private {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                p.tokenIn,
                p.tokenOut,
                p.amountIn,
                p.surplusFloor,
                p.quoteNonce,
                p.deadline,
                p.recipient,
                _routeHash(p.paths),
                p.plsRate,
                p.routingAdvantage
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (usedQuote[digest]) revert BadSig(); // single-use: no replay of a signed quote
        (bytes32 rr, bytes32 ss, uint8 vv) = _splitSig(p.umbraSig);
        address rec = ecrecover(digest, vv, rr, ss);
        if (rec == address(0) || rec != signer) revert BadSig();
        usedQuote[digest] = true;
    }

    function _splitSig(bytes calldata sig) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (sig.length != 65) revert BadSig();
        r = bytes32(sig[0:32]);
        s = bytes32(sig[32:64]);
        v = uint8(sig[64]);
        if (v < 27) v += 27;
    }

    /// Canonical commitment to the exact route calldata. The signer signs this value,
    /// and the contract recomputes it from `p.paths`, so a quote cannot be replayed with
    /// different pools/hops while preserving the same surplus floor.
    function _routeHash(Path[] calldata paths) private pure returns (bytes32) {
        return keccak256(abi.encode(paths));
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
            else if (pt == PT_BALV3) curAmount = _swapBalancerV3(hop, curAmount);
            else revert BadPoolType();
            curToken = hop.tokenOut;
        }
    }

    /// V2 constant-product hop. Direction derived from the pool's real token0/token1,
    /// not from caller-supplied address ordering. Reverts BadV2Pool if tokenIn/tokenOut
    /// don't match the pair's actual tokens.
    function _swapV2(Hop calldata hop, uint256 amountIn) private returns (uint256) {
        address pair = address(uint160(hop.pool));
        uint256 feeNum = (hop.pool >> 160) & 0xFFFFFF;
        if (feeNum == 0) feeNum = 997000;
        address token0 = IUniV2Pair(pair).token0();
        address token1 = IUniV2Pair(pair).token1();
        bool zeroForOne;
        if (hop.tokenIn == token0 && hop.tokenOut == token1) {
            zeroForOne = true;
        } else if (hop.tokenIn == token1 && hop.tokenOut == token0) {
            zeroForOne = false;
        } else {
            revert BadV2Pool();
        }

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

    /// Balancer V3 (Tide) hop. The pool address is in the packed word; the V3 Router is
    /// left-padded into `poolData` and must be allowlisted (which also yields its Permit2).
    /// Funds are pulled by the Router via Permit2 (two-step, idempotent): first `token`
    /// grants the Permit2 an ERC20 max-approval, then the Permit2 grants the Router a
    /// max allowance — both checked-and-skipped on subsequent swaps. Per-hop minOut is 0;
    /// the route-level minOut on actual-received is the protection. Output = balance delta.
    function _swapBalancerV3(Hop calldata hop, uint256 amountIn) private returns (uint256) {
        address pool = address(uint160(hop.pool));
        address v3router = address(uint160(uint256(hop.poolData)));
        address permit2 = allowedV3Router[v3router];
        if (permit2 == address(0)) revert BadV3Router();

        // (1) token -> Permit2: ERC20 max approval (idempotent)
        if (IERC20(hop.tokenIn).allowance(address(this), permit2) < amountIn) {
            hop.tokenIn.safeApprove(permit2, type(uint256).max);
        }
        // (2) Permit2 -> Router: AllowanceTransfer max allowance (idempotent)
        (uint160 cur,,) = IPermit2Allowance(permit2).allowance(address(this), hop.tokenIn, v3router);
        if (cur < amountIn) {
            IPermit2Allowance(permit2).approve(hop.tokenIn, v3router, type(uint160).max, type(uint48).max);
        }

        uint256 outBefore = _balanceOf(hop.tokenOut, address(this));
        IBalancerV3Router(v3router).swapSingleTokenExactIn(
            pool, hop.tokenIn, hop.tokenOut, amountIn, 0, block.timestamp, false, ""
        );
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

    /// Allow/deny a Balancer-V3 (Tide) Router the router may route through, recording the
    /// Router's own Permit2 deployment. Lets new V3 routers be added without a redeploy.
    /// Owner is trusted (use a multisig). `ok == false` clears the entry.
    function setV3Router(address v3router, address permit2, bool ok) external onlyOwner {
        allowedV3Router[v3router] = ok ? permit2 : address(0);
    }

    /// Owner sets the surplus-fee parameters. feeCapBps must stay below the frontend's
    /// slippage tolerance so the fee always fits inside the user's buffer. Owner is a
    /// timelock/multisig in production.
    /// Hard ceiling on the output-share cap (audit H-2): the most the owner can ever set.
    /// 100 bps = 1% — v4 runs at 33 bps (0.33%). Even a compromised owner cannot exceed 1%.
    uint16 public constant MAX_FEE_CAP_BPS = 100;

    function setFeeConfig(uint16 _feeBps, uint16 _feeCapBps, address _signer) external onlyOwner {
        if (_feeBps > 10_000 || _feeCapBps > MAX_FEE_CAP_BPS) revert BadFeeConfig();
        if (_feeBps != 0 && (feeRecipient == address(0) || _signer == address(0))) revert BadFeeConfig();
        feeBps = _feeBps;
        feeCapBps = _feeCapBps;
        signer = _signer;
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

    /// Two-step feeRecipient handoff: the owner nominates, the nominee accepts. Revenue
    /// can never be silently redirected by a single fat-fingered or compromised setFeeConfig
    /// call — only the nominee accepting can move the recipient. Nominating address(0) cancels.
    function proposeFeeRecipient(address addr) external onlyOwner {
        pendingFeeRecipient = addr;
    }

    function acceptFeeRecipient() external {
        if (msg.sender != pendingFeeRecipient) revert NotPendingFeeRecipient();
        feeRecipient = pendingFeeRecipient;
        pendingFeeRecipient = address(0);
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
