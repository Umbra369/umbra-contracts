// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    IERC20,
    IWPLS,
    IUniV2Pair,
    IUniV3Pool,
    IUniV3Factory,
    IAlgebraFactory,
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
//  We charge a flat fee (currently 0.25%) on every swap, hard-capped at 1% — never more.

/// @title UmbraRouterV6 — executes engine split routes across V2/V3/Balancer pools.
/// @notice Execution-only. Pulls the user's input, drives the encoded route, enforces
/// a single minAmountOut on the measured output delta, and sweeps everything to the
/// recipient. Holds no resident funds and assumes no standing user allowance. Every
/// amount is measured (balance deltas), so fee-on-transfer tokens are handled exactly.
/// @dev v5 charges a flat fee: an EIP-712 Umbra-signed quote attests `surplusFloor = 0`,
/// so the whole output counts as surplus and the contract takes `min(feeBps·output,
/// feeCapBps·output) = feeCapBps·output` (0.25% at `feeCapBps = 25`), paid to Treasury,
/// delivering `net` to the user. `feeCapBps` is hard-ceilinged at MAX_FEE_CAP_BPS (1%).
/// v5 adds a fee-on-transfer single-tax fast-path (FIRST_HOP_DIRECT) and Algebra
/// (switch.win) execution. Ships dark (`feeBps = 0` ⇒ fee path inert).
/// @dev v6 adds LAST_HOP_DIRECT: for a taxed-OUTPUT route whose every leg ends in a V2
/// hop on tokenOut, the final pair pays the RECIPIENT directly (one taxed transfer
/// instead of pool→router→recipient's two). Because that removes output custody, the
/// flat fee on those routes is taken from the INPUT instead (`feeCapBps · amountIn`;
/// WPLS — clean — for native-in buys). minAmountOut is enforced on the recipient's
/// measured received delta, exactly as v5's delivery check. Routes without the flag
/// take v5's byte-identical custody path.
contract UmbraRouterV6 is ReentrancyGuard {
    using SafeTransfer for address;

    // ---- immutables / config ----
    address public immutable WPLS;
    address public immutable PERMIT2;
    address[] public v3Factories; // index == forkId in the packed pool word
    address[] public algebraFactories; // index == forkId for PT_ALGEBRA hops (switch.win/SwitchX)
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
    // FoT single-tax fast-path: pull the input straight to the first V2 pair
    // (transferFrom user->pair = ONE tax) instead of pulling to the router and
    // re-sending (two taxes). Only valid for a single-path route whose first hop
    // is V2 with an ERC20 input. Unsigned: the contract enforces those
    // preconditions, so a flipped flag can only revert or improve output.
    uint8 private constant FIRST_HOP_DIRECT = 8;
    // v6: single-tax DELIVERY fast-path. Every leg's final hop must be V2 on tokenOut
    // (ERC20, not native); the final pair's swap pays the recipient directly — one
    // taxed transfer instead of two. Removes output custody, so when fees are live the
    // flat fee is taken from the INPUT up-front (see execute()). Unsigned like
    // FIRST_HOP_DIRECT: preconditions are enforced on-chain (revert BadDirect), and
    // either flag state still collects the fee, so flipping it can't bypass anything.
    uint8 private constant LAST_HOP_DIRECT = 16;
    uint8 private constant PT_V2 = 0;
    uint8 private constant PT_V3 = 1;
    uint8 private constant PT_BAL = 2;
    uint8 private constant PT_STABLE = 3;
    uint8 private constant PT_BALV3 = 4;
    uint8 private constant PT_ALGEBRA = 5; // Algebra V1.x (switch.win/SwitchX) concentrated liquidity

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
    error BadAlgebraPool();
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
    error BadDirect();

    constructor(
        address wpls,
        address permit2,
        address[] memory factories,
        address[] memory vaults,
        address[] memory stablePools,
        address[] memory algebra
    ) {
        WPLS = wpls;
        PERMIT2 = permit2;
        v3Factories = factories;
        algebraFactories = algebra;
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

        // ---- resolve tokens & snapshot output up-front ----
        // All sizing is off the delta THIS call creates (`pulledIn` for the split
        // path; the pair's measured input for the direct path), never `balanceOf(this)`,
        // so any force-sent / residual balance is inert and only `sweep` can move it.
        address tokenInErc = nativeIn ? WPLS : p.tokenIn;
        address tokenOutErc = nativeOut ? WPLS : p.tokenOut;
        if (tokenInErc == tokenOutErc) revert SameToken();
        // ---- v6 LAST_HOP_DIRECT: validate up-front (before ANY external call), fail closed ----
        // Single-tax delivery: every leg's final hop pays the recipient straight from
        // the V2 pair. Output never enters custody, so (a) `delivered` is measured as
        // the recipient's balance delta, and (b) when fees are live the flat fee is
        // taken from the INPUT up-front (input custody still exists on every path).
        bool lastDirect = p.flags & LAST_HOP_DIRECT != 0;
        uint256 recBefore;
        uint256 feeIn;
        if (lastDirect) {
            if (nativeOut) revert BadDirect(); // unwrap needs custody
            if (p.recipient == address(this)) revert BadDirect(); // delta accounting integrity
            for (uint256 i = 0; i < n; i++) {
                uint256 hn = p.paths[i].hops.length;
                if (hn == 0) revert BadDirect();
                Hop calldata hl = p.paths[i].hops[hn - 1];
                if (hl.poolType != PT_V2 || hl.tokenOut != tokenOutErc) revert BadDirect();
            }
            recBefore = _balanceOf(tokenOutErc, p.recipient);
            // Attestation FIRST (single-use nonce consumed; a revert anywhere rolls it
            // back), then the input-side fee is taken during funding below.
            //
            // Design note (audit, intentional): `flags` is NOT in the signed
            // QuoteAttestation (typehash unchanged from v5 — no signer coupling). A user
            // could therefore flip LAST_HOP_DIRECT on a live signed quote. This is safe:
            // (a) the route is bound by routeHash, so the pools/hops can't change;
            // (b) the fee is still collected — feeIn = feeCapBps * amountIn (input basis)
            //     is >= the non-LHD feeCapBps * outDelta (output basis, the smaller side),
            //     so flipping the flag can only RAISE the fee the protocol receives, never
            //     bypass it; and (c) in flat-fee mode surplusFloor is always 0, so there is
            //     no surplus semantic to neuter. If true-surplus mode ever returns, the
            //     engine simply must not set LHD on surplus-priced routes.
            //
            // Fee basis (intentional): charging the input side is marginally more than v5's
            // output-side fee (input is the larger side by the pool fee + price impact),
            // but only fires on FoT-output routes where the user's tax saving dwarfs it —
            // the user always nets far more than under v5 custody.
            if (feeBps != 0) {
                _verifyQuote(p);
                feeIn = (p.amountIn * feeCapBps) / 10_000;
            }
        }
        address directTo = lastDirect ? p.recipient : address(0);

        // delta excludes any pre-existing balance; tokenIn != tokenOut, so pulling
        // the input below never disturbs this snapshot. (Unused on the LHD path,
        // whose settlement measures the recipient instead.)
        uint256 outBefore = _balanceOf(tokenOutErc, address(this));

        if (p.flags & FIRST_HOP_DIRECT != 0) {
            // ---- FoT single-tax fast-path: fund the first V2 pair DIRECTLY ----
            // Halves the tax on fee-on-transfer sells (one user->pair transfer instead
            // of user->router->pair). Restricted to a single ERC20-input path whose
            // first hop is V2; the contract reverts otherwise, so a mis-set flag is safe.
            if (nativeIn || msg.value != 0) revert BadDirect();
            if (n != 1) revert BadDirect();
            Path calldata path = p.paths[0];
            if (path.inputBps != 10_000) revert BadBps();
            Hop calldata h0 = path.hops[0];
            if (h0.poolType != PT_V2 || h0.tokenIn != tokenInErc) revert BadDirect();
            address pair = address(uint160(h0.pool));
            uint256 pairBefore = _balanceOf(tokenInErc, pair);
            uint256 pullAmount = p.amountIn;
            if (feeIn != 0) {
                // FIRST+LAST direct with fees live: no custody anywhere, so the fee is a
                // second transferFrom (user -> feeRecipient). Permit2 signs ONE transfer
                // and cannot be split — those routes must not set both flags (fail closed).
                if (p.flags & USE_PERMIT2 != 0) revert BadDirect();
                tokenInErc.safeTransferFrom(msg.sender, feeRecipient, feeIn);
                pullAmount -= feeIn;
            }
            _pullInput(p, tokenInErc, pair, pullAmount); // user -> pair directly (ONE tax)
            if (path.hops.length == 1) {
                // single-hop FoT->X: user->pair->recipient(if LHD) — zero custody
                _swapV2Funded(h0, pair, pairBefore, lastDirect ? p.recipient : address(this));
            } else {
                uint256 firstOut = _swapV2Funded(h0, pair, pairBefore, address(this));
                _runHopsFrom(path, 1, h0.tokenOut, firstOut, directTo); // remaining hops router-funded
            }
        } else {
            // ---- standard: pull to the router, then run the split paths ----
            uint256 inBefore = _balanceOf(tokenInErc, address(this));
            if (nativeIn) {
                if (msg.value != p.amountIn) revert BadValue();
                IWPLS(WPLS).deposit{value: p.amountIn}();
            } else {
                if (msg.value != 0) revert BadValue();
                _pullInput(p, tokenInErc, address(this), p.amountIn);
            }
            uint256 pulledIn = _balanceOf(tokenInErc, address(this)) - inBefore; // post input-FoT

            if (feeIn != 0) {
                // v6 input-side fee (LAST_HOP_DIRECT with fees live). Scale to what was
                // actually pulled (post input-FoT) so we never route more than we hold.
                // For native-in buys this is WPLS — a clean, untaxed fee. `safeTransfer`
                // debits exactly `feeIn` from the router regardless of the token's tax.
                feeIn = (pulledIn * feeCapBps) / 10_000;
                if (feeIn != 0) tokenInErc.safeTransfer(feeRecipient, feeIn);
                pulledIn -= feeIn;
            }

            uint256 totalBps;
            uint256 consumed;
            for (uint256 i = 0; i < n; i++) {
                Path calldata path = p.paths[i];
                totalBps += path.inputBps;
                // last path takes the remaining pulled amount (absorbs rounding + FoT residue)
                uint256 pathIn = (i == n - 1) ? (pulledIn - consumed) : (pulledIn * path.inputBps) / 10_000;
                consumed += pathIn;
                if (pathIn != 0) _runPath(path, tokenInErc, pathIn, directTo);
            }
            if (totalBps != 10_000) revert BadBps();
        }

        // ---- v6 LAST_HOP_DIRECT settlement: measure at the RECIPIENT ----
        // The output never touched the router. `delivered` is the recipient's actual
        // received delta across all legs (post every tax), the same quantity v5's
        // delivery check enforces minAmountOut on. The fee was already taken from the
        // input; the tally values the realized delivery.
        if (lastDirect) {
            uint256 delivered = _balanceOf(tokenOutErc, p.recipient) - recBefore;
            if (feeBps != 0) {
                totalPlsRouted += (delivered * p.plsRate) / 1e18;
                totalRoutingAdvantage += p.routingAdvantage;
                unchecked {
                    swapCount += 1;
                }
                // FeeTaken(recipient, token, base, fee): the LHD fee is taken in the
                // INPUT token, so every field here is input-denominated — `token` is
                // tokenInErc and `base` is the input amount the fee was computed against
                // (NOT the output `delivered`, which would mismatch units for indexers).
                emit FeeTaken(feeRecipient, tokenInErc, p.amountIn, feeIn);
            }
            if (delivered < p.minAmountOut) revert InsufficientOutput();
            emit Executed(msg.sender, p.recipient, p.tokenIn, p.tokenOut, p.amountIn, delivered);
            return delivered;
        }

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

    /// Pull `p.amountIn` of `token` from the caller to `to`. `to` is the router for the
    /// standard split path; for the FoT fast-path it is the first V2 pair, so a
    /// fee-on-transfer token is taxed once (user->pair) rather than twice. Permit2's
    /// transfer `to` is chosen by the contract (not part of the user's signed permit),
    /// so directing it to the pair is safe — the user authorized this contract to spend.
    function _pullInput(ExecuteParams calldata p, address token, address to, uint256 amount) private {
        if (p.flags & USE_PERMIT2 != 0) {
            (IPermit2.PermitTransferFrom memory permit, bytes memory sig) =
                abi.decode(p.permit2, (IPermit2.PermitTransferFrom, bytes));
            IPermit2(PERMIT2).permitTransferFrom(
                permit,
                IPermit2.SignatureTransferDetails({to: to, requestedAmount: amount}),
                msg.sender,
                sig
            );
        } else {
            token.safeTransferFrom(msg.sender, to, amount);
        }
    }

    // ============================================================ path / hops

    function _runPath(Path calldata path, address tokenIn0, uint256 amount0, address directTo) private {
        _runHopsFrom(path, 0, tokenIn0, amount0, directTo);
    }

    /// Drive hops [start..] of a path, threading the running token + amount. `start == 1`
    /// is used by the FoT fast-path, whose first hop was already executed via
    /// `_swapV2Funded` after a direct user->pair transfer. `directTo != address(0)`
    /// (v6 LAST_HOP_DIRECT) makes the FINAL hop's V2 pair pay `directTo` directly —
    /// execute() has already validated that every leg's final hop is V2 on tokenOut.
    function _runHopsFrom(Path calldata path, uint256 start, address tokenIn0, uint256 amount0, address directTo)
        private
    {
        address curToken = tokenIn0;
        uint256 curAmount = amount0;
        uint256 h = path.hops.length;
        for (uint256 j = start; j < h; j++) {
            Hop calldata hop = path.hops[j];
            if (hop.tokenIn != curToken) revert HopMismatch();
            uint8 pt = hop.poolType;
            if (pt == PT_V2) {
                curAmount = _swapV2(hop, curAmount, (directTo != address(0) && j == h - 1) ? directTo : address(this));
            }
            else if (pt == PT_V3) curAmount = _swapV3(hop, curAmount);
            else if (pt == PT_BAL) curAmount = _swapBalancer(hop, curAmount);
            else if (pt == PT_STABLE) curAmount = _swapStable(hop, curAmount);
            else if (pt == PT_BALV3) curAmount = _swapBalancerV3(hop, curAmount);
            else if (pt == PT_ALGEBRA) curAmount = _swapAlgebra(hop, curAmount);
            else revert BadPoolType();
            curToken = hop.tokenOut;
        }
    }

    /// V2 constant-product hop. Direction derived from the pool's real token0/token1,
    /// not from caller-supplied address ordering. Reverts BadV2Pool if tokenIn/tokenOut
    /// don't match the pair's actual tokens.
    function _swapV2(Hop calldata hop, uint256 amountIn, address to) private returns (uint256) {
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

        if (to == address(this)) {
            uint256 outBefore = _balanceOf(hop.tokenOut, address(this));
            IUniV2Pair(pair).swap(a0, a1, address(this), "");
            return _balanceOf(hop.tokenOut, address(this)) - outBefore; // output-side FoT
        }
        // v6 LAST_HOP_DIRECT: pair pays the recipient — ONE taxed transfer. This is the
        // final hop of a leg (validated in execute()); the return value is the pool-math
        // amountOut and is not consumed — settlement measures the recipient's delta.
        IUniV2Pair(pair).swap(a0, a1, to, "");
        return amountOut;
    }

    /// V2 hop whose pair was ALREADY funded by a direct user->pair transfer (the FoT
    /// fast-path). Identical AMM math to `_swapV2`, but instead of sending the funds it
    /// measures what the pair received as `balanceOf(pair) - pairBefore`, where
    /// `pairBefore` was snapshotted in `execute()` *before* the direct transfer. Using
    /// `pairBefore` (not the synced reserve) keeps it donation-safe: any pre-existing
    /// unsynced balance is excluded, so the computed `amountOut` never exceeds what the
    /// pair's K-invariant allows. `pair == address(uint160(hop.pool))` (same hop).
    /// A bogus pair cannot steal: the whole tx is atomic and reverts on the route-level
    /// minAmountOut, rolling back the transfer.
    function _swapV2Funded(Hop calldata hop, address pair, uint256 pairBefore, address to)
        private
        returns (uint256)
    {
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

        uint256 inActual = _balanceOf(hop.tokenIn, pair) - pairBefore; // input-side FoT, donation-safe

        (uint112 r0, uint112 r1,) = IUniV2Pair(pair).getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inWithFee = inActual * feeNum;
        uint256 amountOut = (inWithFee * rOut) / (rIn * FEE_DEN + inWithFee);
        (uint256 a0, uint256 a1) = zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));

        if (to == address(this)) {
            uint256 outBefore = _balanceOf(hop.tokenOut, address(this));
            IUniV2Pair(pair).swap(a0, a1, address(this), "");
            return _balanceOf(hop.tokenOut, address(this)) - outBefore; // output-side FoT
        }
        // v6 FIRST+LAST direct single hop: user->pair->recipient, zero custody. Return
        // value (pool-math amountOut) is not consumed; settlement measures the recipient.
        IUniV2Pair(pair).swap(a0, a1, to, "");
        return amountOut;
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

    /// Algebra V1.x (switch.win/SwitchX) concentrated hop. Structurally identical to
    /// `_swapV3`: the pool is authenticated against the Algebra factory via `poolByPair`
    /// (order-independent, one pool per pair — NO fee tier), and the swap shares Uniswap
    /// V3's exact ABI/selector (0x128acb08), so `IUniV3Pool.swap` is reused. The pool's
    /// `algebraSwapCallback` (selector 0x2c8958f6) lands in `fallback()` and is paid by
    /// `_v3Pay`, bounded by the same `_v3ExpectedPool`/`_v3ExpectedAmount` guard.
    function _swapAlgebra(Hop calldata hop, uint256 amountIn) private returns (uint256) {
        address pool = address(uint160(hop.pool));
        uint8 forkId = uint8((hop.pool >> 184) & 0xFF);

        address legit = IAlgebraFactory(algebraFactories[forkId]).poolByPair(hop.tokenIn, hop.tokenOut);
        if (legit != pool || pool == address(0)) revert BadAlgebraPool();
        if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();

        bool zeroForOne = hop.tokenIn < hop.tokenOut; // Algebra sorts token0<token1, like V3
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

    function algebraFactoriesLength() external view returns (uint256) {
        return algebraFactories.length;
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
