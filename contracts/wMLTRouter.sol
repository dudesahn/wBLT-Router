// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Math} from "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";
import {Ownable2Step} from "@openzeppelin/contracts@4.9.3/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts@4.9.3/proxy/Clones.sol";
import {IFactoryRegistry, IPoolFactory, IPool} from "./interfaces/AerodromeInterfaces.sol";
import {IERC20, IWETH, IBMX, VaultAPI, IShareHelper} from "./interfaces/BMXInterfaces.sol";

/**
 * @title wMLT Router
 * @notice This contract simplifies conversions between wMLT, BMX, and other assets
 *  using wMLT's underlying tokens as virtual pools with wMLT. Built on top of Velodrome on Mode.
 */

contract wMLTRouter is Ownable2Step {
    struct Route {
        address from;
        address to;
        bool stable;
    }

    /// @notice Velodrome V2 (vAMM/sAMM) Mode pool factory
    address public constant defaultFactory =
        0x31832f2a97Fd20664D76Cc421207669b55CE4BC0;

    IWETH public constant weth =
        IWETH(0x4200000000000000000000000000000000000006);
    uint256 internal immutable PRICE_PRECISION;
    uint256 internal immutable BASIS_POINTS_DIVISOR;

    /// @notice The tokens currently approved for deposit to BLT.
    address[] public bltTokens;

    // contracts used for wBLT mint/burn
    VaultAPI internal constant wBLT =
        VaultAPI(0x8b2EeA0999876AAB1E7955fe01A5D261b570452C);

    IBMX internal constant sBLT =
        IBMX(0x0Eb231766cD891ed6aA4FafEeF60E1c01b18c12a);

    IBMX internal constant rewardRouter =
        IBMX(0x73bF80506F891030570FDC4D53a71f44a442353C);

    IBMX internal constant morphexVault =
        IBMX(0xff745bdB76AfCBa9d3ACdCd71664D4250Ef1ae49);

    IBMX internal constant bltManager =
        IBMX(0xf9Fc0B2859f9B6d33fD1Cea5B0A9f1D56C258178);

    IBMX internal constant vaultUtils =
        IBMX(0x7Fb62EfF63DEE8b6D6654858c75E925C08811B46);

    IShareHelper internal constant shareValueHelper =
        IShareHelper(0xC3a1216913B392a1B216c296410Dc9CaA1c6289F);

    constructor() {
        // do approvals for wBLT
        sBLT.approve(address(wBLT), type(uint256).max);

        // update our allowances
        updateAllowances();

        PRICE_PRECISION = morphexVault.PRICE_PRECISION();
        BASIS_POINTS_DIVISOR = morphexVault.BASIS_POINTS_DIVISOR();
    }

    modifier ensure(uint256 _deadline) {
        require(_deadline >= block.timestamp, "Router: EXPIRED");
        _;
    }

    // only accept ETH via fallback from the WETH contract
    receive() external payable {
        assert(msg.sender == address(weth));
    }

    /* ========== NEW/MODIFIED FUNCTIONS ========== */

    /**
     * @notice Checks for current tokens in BLT, approves them, and updates our stored array.
     * @dev This is may only be called by owner.
     */
    function updateAllowances() public onlyOwner {
        // first, set all of our allowances to zero
        for (uint256 i = 0; i < bltTokens.length; ++i) {
            IERC20 token = IERC20(bltTokens[i]);
            token.approve(address(bltManager), 0);
        }

        // clear out our saved array
        delete bltTokens;

        // add our new tokens
        uint256 tokensCount = morphexVault.whitelistedTokenCount();
        for (uint256 i = 0; i < tokensCount; ++i) {
            IERC20 token = IERC20(morphexVault.allWhitelistedTokens(i));
            token.approve(address(bltManager), type(uint256).max);
            bltTokens.push(address(token));
        }
    }

    /**
     * @notice Performs chained getAmountOut calculations on any number of pools.
     * @dev This is mainly used when conducting swaps.
     * @param _amountIn The amount of our first token to swap.
     * @param _routes Array of structs that we use for our swap path.
     * @return amounts Amount of each token in the swap path.
     */
    function getAmountsOut(
        uint256 _amountIn,
        Route[] memory _routes
    ) public view returns (uint256[] memory amounts) {
        require(_routes.length >= 1, "Router: INVALID_PATH");
        amounts = new uint256[](_routes.length + 1);
        amounts[0] = _amountIn;
        for (uint256 i = 0; i < _routes.length; i++) {
            // check if we need to convert to or from wBLT
            if (_routes[i].from == address(wBLT)) {
                // check to make sure it's one of the tokens in BLT
                if (_isBLTToken(_routes[i].to)) {
                    amounts[i + 1] = getRedeemAmountWrappedBLT(
                        _routes[i].to,
                        amounts[i],
                        false
                    );
                    continue;
                }
            } else if (_routes[i].to == address(wBLT)) {
                // check to make sure it's one of the tokens in BLT
                if (_isBLTToken(_routes[i].from)) {
                    // make sure to underestimate the amount out here
                    amounts[i + 1] = getMintAmountWrappedBLT(
                        _routes[i].from,
                        amounts[i]
                    );
                    continue;
                }
            }

            // if it's not depositing or withdrawing from wBLT, we can treat it like normal
            address pool = poolFor(
                _routes[i].from,
                _routes[i].to,
                _routes[i].stable
            );
            if (IPoolFactory(defaultFactory).isPool(pool)) {
                amounts[i + 1] = IPool(pool).getAmountOut(
                    amounts[i],
                    _routes[i].from
                );
            }
        }
    }

    /**
     * @notice Swap wBLT or our pooled token for ether.
     * @param _amountIn The amount of our first token to swap.
     * @param _amountOutMin Minimum amount of ether we must receive.
     * @param _routes Array of structs that we use for our swap path.
     * @param _to Address that will receive the ether.
     * @param _deadline Deadline for transaction to complete.
     * @return amounts Amount of each token in the swap path.
     */
    function swapExactTokensForETH(
        uint256 _amountIn,
        uint256 _amountOutMin,
        Route[] calldata _routes,
        address _to,
        uint256 _deadline
    ) external ensure(_deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(_amountIn, _routes);
        require(
            amounts[amounts.length - 1] >= _amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        require(
            _routes[_routes.length - 1].to == address(weth),
            "Router: END_ROUTE_IN_ETH_BOZO"
        );

        // if our first pool is mint/burn of wBLT, transfer to the router
        if (
            _routes[0].from == address(wBLT) || _routes[0].to == address(wBLT)
        ) {
            if (_isBLTToken(_routes[0].from) || _isBLTToken(_routes[0].to)) {
                _safeTransferFrom(
                    _routes[0].from,
                    msg.sender,
                    address(this),
                    amounts[0]
                );
            } else {
                // if it's not wBLT AND an underlying, it's just a normal wBLT swap (likely w/ BMX)
                _safeTransferFrom(
                    _routes[0].from,
                    msg.sender,
                    poolFor(_routes[0].from, _routes[0].to, _routes[0].stable),
                    amounts[0]
                );
            }
        } else {
            _safeTransferFrom(
                _routes[0].from,
                msg.sender,
                poolFor(_routes[0].from, _routes[0].to, _routes[0].stable),
                amounts[0]
            );
        }

        _swap(amounts, _routes, address(this));

        // WETH -> ETH
        uint256 amountUnderlying = weth.balanceOf(address(this));
        weth.withdraw(amountUnderlying);
        _safeTransferETH(_to, amountUnderlying);
    }

    /**
     * @notice Swap ETH for tokens, with special handling for wBLT pools.
     * @param _amountIn The amount of ether to swap.
     * @param _amountOutMin Minimum amount of our final token we must receive.
     * @param _routes Array of structs that we use for our swap path.
     * @param _to Address that will receive the final token in the swap path.
     * @param _deadline Deadline for transaction to complete.
     * @return amounts Amount of each token in the swap path.
     */
    function swapExactETHForTokens(
        uint256 _amountIn,
        uint256 _amountOutMin,
        Route[] calldata _routes,
        address _to,
        uint256 _deadline
    ) public payable ensure(_deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(_amountIn, _routes);
        require(
            amounts[amounts.length - 1] >= _amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        // deposit to weth first
        weth.deposit{value: _amountIn}();
        if (weth.balanceOf(address(this)) != _amountIn) {
            revert("WETH not sent");
        }

        if (
            _routes[0].from != address(weth) || _routes[0].to != address(wBLT)
        ) {
            revert("Route must start WETH -> wBLT");
        }

        _swap(amounts, _routes, _to);
    }

    /**
     * @notice Swap tokens for tokens, with special handling for wBLT pools.
     * @param _amountIn The amount of our first token to swap.
     * @param _amountOutMin Minimum amount of our final token we must receive.
     * @param _routes Array of structs that we use for our swap path.
     * @param _to Address that will receive the final token in the swap path.
     * @param _deadline Deadline for transaction to complete.
     * @return amounts Amount of each token in the swap path.
     */
    function swapExactTokensForTokens(
        uint256 _amountIn,
        uint256 _amountOutMin,
        Route[] calldata _routes,
        address _to,
        uint256 _deadline
    ) external ensure(_deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(_amountIn, _routes);
        require(
            amounts[amounts.length - 1] >= _amountOutMin,
            "Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        // if our first pool is mint/burn of wBLT, transfer to the router
        if (
            _routes[0].from == address(wBLT) || _routes[0].to == address(wBLT)
        ) {
            if (_isBLTToken(_routes[0].from) || _isBLTToken(_routes[0].to)) {
                _safeTransferFrom(
                    _routes[0].from,
                    msg.sender,
                    address(this),
                    amounts[0]
                );
            } else {
                // if it's not wBLT AND an underlying, it's just a normal wBLT swap (likely w/ BMX)
                _safeTransferFrom(
                    _routes[0].from,
                    msg.sender,
                    poolFor(_routes[0].from, _routes[0].to, _routes[0].stable),
                    amounts[0]
                );
            }
        } else {
            _safeTransferFrom(
                _routes[0].from,
                msg.sender,
                poolFor(_routes[0].from, _routes[0].to, _routes[0].stable),
                amounts[0]
            );
        }

        _swap(amounts, _routes, _to);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pool or in this case, our underlying or wBLT
    //  to have been sent to the router
    function _swap(
        uint256[] memory _amounts,
        Route[] memory _routes,
        address _to
    ) internal virtual {
        for (uint256 i = 0; i < _routes.length; i++) {
            (address token0, ) = sortTokens(_routes[i].from, _routes[i].to);
            uint256 amountOut = _amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = _routes[i].from == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));

            // only if we're doing a wBLT deposit/withdrawal in the middle of a route
            bool directSend;
            uint256 received;
            address to;

            // check if we need to convert to or from wBLT
            if (_routes[i].from == address(wBLT)) {
                // check to see if it's one of the tokens in BLT
                if (_isBLTToken(_routes[i].to)) {
                    received = _withdrawFromWrappedBLT(_routes[i].to);
                    if (i < (_routes.length - 1)) {
                        // if we're not done, send our underlying to the next pool
                        directSend = true;
                    } else {
                        // if this is the last token, send to our _to address
                        _safeTransfer(_routes[i].to, _to, received);
                        return;
                    }
                }
            } else if (_routes[i].to == address(wBLT)) {
                // check to make sure it's one of the tokens in BLT
                if (_isBLTToken(_routes[i].from)) {
                    received = _depositToWrappedBLT(_routes[i].from);
                    if (i < (_routes.length - 1)) {
                        // if we're not done, directly send our wBLT to the next pool
                        directSend = true;
                    } else {
                        // if this is the last token, send to our _to address
                        _safeTransfer(_routes[i].to, _to, received);
                        return;
                    }
                }
            }

            if (i == _routes.length - 1) {
                // end of the route, send to the receiver
                to = _to;
            } else if (
                (_isBLTToken(_routes[i + 1].from) &&
                    _routes[i + 1].to == address(wBLT)) ||
                (_isBLTToken(_routes[i + 1].to) &&
                    _routes[i + 1].from == address(wBLT))
            ) {
                // if we're about to go underlying -> wBLT or wBLT -> underlying, then make sure we get our needed token
                //  back to the router
                to = address(this);
            } else {
                // normal mid-route swap
                to = poolFor(
                    _routes[i + 1].from,
                    _routes[i + 1].to,
                    _routes[i + 1].stable
                );
            }

            if (directSend) {
                _safeTransfer(_routes[i].to, to, received);
            } else {
                IPool(
                    poolFor(_routes[i].from, _routes[i].to, _routes[i].stable)
                ).swap(amount0Out, amount1Out, to, new bytes(0));
            }
        }
    }

    /**
     * @notice Check how much wBLT we get from a given amount of underlying.
     * @dev Since this uses minPrice, we likely underestimate wBLT received. By using normal solidity division, we are
     *  also truncating (rounding down) all operations.
     * @param _token The token to deposit to wBLT.
     * @param _amount The amount of the token to deposit.
     * @return wrappedBLTMintAmount Amount of wBLT received.
     */
    function getMintAmountWrappedBLT(
        address _token,
        uint256 _amount
    ) public view returns (uint256 wrappedBLTMintAmount) {
        require(_amount > 0, "invalid _amount");

        // calculate aum before buyUSDG
        (uint256 aumInUsdg, uint256 bltSupply) = _getBltInfo(true);
        uint256 price = morphexVault.getMinPrice(_token);

        // save some gas
        uint256 _precision = PRICE_PRECISION;
        uint256 _divisor = BASIS_POINTS_DIVISOR;

        uint256 usdgAmount = (_amount * price) / _precision;
        usdgAmount = morphexVault.adjustForDecimals(
            usdgAmount,
            _token,
            morphexVault.usdg()
        );

        uint256 feeBasisPoints = vaultUtils.getBuyUsdgFeeBasisPoints(
            _token,
            usdgAmount
        );
        uint256 afterFeeAmount = (_amount * (_divisor - feeBasisPoints)) /
            _divisor;

        uint256 usdgMintAmount = (afterFeeAmount * price) / _precision;
        usdgMintAmount = morphexVault.adjustForDecimals(
            usdgMintAmount,
            _token,
            morphexVault.usdg()
        );
        uint256 BLTMintAmount = aumInUsdg == 0
            ? usdgMintAmount
            : (usdgMintAmount * bltSupply) / aumInUsdg;

        // convert our BLT amount to wBLT
        wrappedBLTMintAmount = shareValueHelper.amountToShares(
            address(wBLT),
            BLTMintAmount,
            false
        );
    }

    /**
     * @notice Check how much underlying we get from redeeming a given amount of wBLT.
     * @dev By default we round down and use getMaxPrice to underestimate underlying received. This is important so that
     *  we don't ever revert in a swap due to overestimation, as getAmountsOut calls this function.
     * @param _tokenOut The token to withdraw from wBLT.
     * @param _amount The amount of wBLT to burn.
     * @param _roundUp Whether we round up or not.
     * @return underlyingReceived Amount of underlying token received.
     */
    function getRedeemAmountWrappedBLT(
        address _tokenOut,
        uint256 _amount,
        bool _roundUp
    ) public view returns (uint256 underlyingReceived) {
        require(_amount > 0, "invalid _amount");

        // convert our wBLT amount to BLT
        _amount = shareValueHelper.sharesToAmount(
            address(wBLT),
            _amount,
            _roundUp
        );

        // convert our BLT to bUSD (USDG)
        (uint256 aumInUsdg, uint256 bltSupply) = _getBltInfo(false);
        uint256 usdgAmount;

        // round up if needed
        if (_roundUp) {
            usdgAmount = Math.ceilDiv((_amount * aumInUsdg), bltSupply);
        } else {
            usdgAmount = (_amount * aumInUsdg) / bltSupply;
        }

        // use min or max price depending on how we want to estimate
        uint256 price;
        if (_roundUp) {
            price = morphexVault.getMinPrice(_tokenOut);
        } else {
            price = morphexVault.getMaxPrice(_tokenOut);
        }

        // convert USDG to _tokenOut amounts. no need to round this one since we adjust decimals and compensate below
        uint256 redeemAmount = (usdgAmount * PRICE_PRECISION) / price;

        redeemAmount = morphexVault.adjustForDecimals(
            redeemAmount,
            morphexVault.usdg(),
            _tokenOut
        );

        // add one wei to compensate for truncating when adjusting decimals
        if (_roundUp) {
            redeemAmount += 1;
        }

        // calculate our fees
        uint256 feeBasisPoints = vaultUtils.getSellUsdgFeeBasisPoints(
            _tokenOut,
            usdgAmount
        );

        // save some gas
        uint256 _divisor = BASIS_POINTS_DIVISOR;

        // adjust for fees, round up if needed
        if (_roundUp) {
            underlyingReceived = Math.ceilDiv(
                (redeemAmount * (_divisor - feeBasisPoints)),
                _divisor
            );
        } else {
            underlyingReceived = ((redeemAmount * (_divisor - feeBasisPoints)) /
                _divisor);
        }
    }

    /**
     * @notice Check how much wBLT we need to redeem for a given amount of underlying.
     * @dev Here we do everything we can, including adding an additional Wei of Defeat, to ensure that our estimated
     *  wBLT amount always provides enough underlying.
     * @param _underlyingToken The token to withdraw from wBLT.
     * @param _amount The amount of underlying we need.
     * @return wBLTAmount Amount of wBLT needed.
     */
    function quoteRedeemAmountBLT(
        address _underlyingToken,
        uint256 _amount
    ) external view returns (uint256 wBLTAmount) {
        require(_amount > 0, "invalid _amount");

        // add an additional wei to our input amount because of persistent rounding issues, AKA the Wei of Defeat
        _amount += 1;

        // get our info for BLT
        (uint256 aumInUsdg, uint256 bltSupply) = _getBltInfo(false);

        // convert our underlying amount to USDG
        uint256 underlyingPrice = morphexVault.getMaxPrice(_underlyingToken);
        uint256 usdgNeeded = Math.ceilDiv(
            (_amount * underlyingPrice),
            PRICE_PRECISION
        );

        // convert USDG needed to BLT. no need for rounding here since we will truncate in the next step anyway
        uint256 bltAmount = (usdgNeeded * bltSupply) / aumInUsdg;

        bltAmount = morphexVault.adjustForDecimals(
            bltAmount,
            morphexVault.usdg(),
            _underlyingToken
        );

        // add one wei since adjustForDecimals truncates instead of rounding up
        bltAmount += 1;

        // save some gas
        uint256 _divisor = BASIS_POINTS_DIVISOR;

        // check current fees
        uint256 feeBasisPoints = vaultUtils.getSellUsdgFeeBasisPoints(
            _underlyingToken,
            usdgNeeded
        );

        // adjust for fees
        bltAmount = Math.ceilDiv(
            (bltAmount * _divisor),
            (_divisor - feeBasisPoints)
        );

        // convert our BLT to wBLT
        wBLTAmount = shareValueHelper.amountToShares(
            address(wBLT),
            bltAmount,
            true
        );
    }

    /**
     * @notice Check how much underlying we need to mint a given amount of wBLT.
     * @dev Since this uses minPrice, we likely overestimate underlying needed. To be cautious of rounding down, use
     *  ceiling division.
     * @param _underlyingToken The token to deposit to wBLT.
     * @param _amount The amount of wBLT we need.
     * @return startingTokenAmount Amount of underlying token needed.
     */
    function quoteMintAmountBLT(
        address _underlyingToken,
        uint256 _amount
    ) public view returns (uint256 startingTokenAmount) {
        require(_amount > 0, "invalid _amount");

        // convert our wBLT amount to BLT
        _amount = shareValueHelper.sharesToAmount(address(wBLT), _amount, true);

        // convert our BLT to bUSD (USDG)
        // maximize here to use max BLT price, to make sure we get enough BLT out
        (uint256 aumInUsdg, uint256 bltSupply) = _getBltInfo(true);
        uint256 usdgAmount = Math.ceilDiv((_amount * aumInUsdg), bltSupply);

        // price is returned in 1e30 from vault
        uint256 tokenPrice = morphexVault.getMinPrice(_underlyingToken);

        startingTokenAmount = Math.ceilDiv(
            usdgAmount * PRICE_PRECISION,
            tokenPrice
        );

        startingTokenAmount = morphexVault.adjustForDecimals(
            startingTokenAmount,
            morphexVault.usdg(),
            _underlyingToken
        );

        // add one wei since adjustForDecimals truncates instead of rounding up
        startingTokenAmount += 1;

        // calculate extra needed due to fees
        uint256 feeBasisPoints = vaultUtils.getBuyUsdgFeeBasisPoints(
            _underlyingToken,
            usdgAmount
        );

        // save some gas
        uint256 _divisor = BASIS_POINTS_DIVISOR;

        startingTokenAmount = Math.ceilDiv(
            startingTokenAmount * _divisor,
            (_divisor - feeBasisPoints)
        );
    }

    // standard data needed to calculate BLT pricing
    function _getBltInfo(
        bool _maximize
    ) internal view returns (uint256 aumInUsdg, uint256 bltSupply) {
        bltSupply = sBLT.totalSupply();
        aumInUsdg = bltManager.getAumInUsdg(_maximize);
    }

    // check if a token is in BLT
    function _isBLTToken(address _tokenToCheck) internal view returns (bool) {
        for (uint256 i = 0; i < bltTokens.length; ++i) {
            if (bltTokens[i] == _tokenToCheck) {
                return true;
            }
        }
        return false;
    }

    // withdraw all of the wBLT we have to a given underlying token
    function _withdrawFromWrappedBLT(
        address _targetToken
    ) internal returns (uint256) {
        if (!_isBLTToken(_targetToken)) {
            revert("Token not in wBLT");
        }

        // withdraw from the vault first, make sure it comes here
        uint256 toWithdraw = wBLT.withdraw(type(uint256).max, address(this));

        // withdraw our targetToken
        return
            rewardRouter.unstakeAndRedeemBlt(
                _targetToken,
                toWithdraw,
                0,
                address(this)
            );
    }

    // deposit all of the underlying we have to wBLT
    function _depositToWrappedBLT(
        address _fromToken
    ) internal returns (uint256 tokens) {
        if (!_isBLTToken(_fromToken)) {
            revert("Token not in wBLT");
        }

        // deposit to BLT and then the vault
        IERC20 token = IERC20(_fromToken);
        uint256 newMlp = rewardRouter.mintAndStakeBlt(
            address(_fromToken),
            token.balanceOf(address(this)),
            0,
            0
        );

        // specify that router should get the vault tokens
        tokens = wBLT.deposit(newMlp, address(this));
    }

    /* ========== AERODROME-SPECIFIC FUNCTIONS ========== */

    function poolFor(
        address _tokenA,
        address _tokenB,
        bool _stable
    ) public view returns (address pool) {
        (address token0, address token1) = sortTokens(_tokenA, _tokenB);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, _stable));
        pool = Clones.predictDeterministicAddress(
            IPoolFactory(defaultFactory).implementation(),
            salt,
            defaultFactory
        );
    }

    /* ========== UNMODIFIED V1 FUNCTIONS ========== */

    function sortTokens(
        address _tokenA,
        address _tokenB
    ) public pure returns (address token0, address token1) {
        require(_tokenA != _tokenB, "Router: IDENTICAL_ADDRESSES");
        (token0, token1) = _tokenA < _tokenB
            ? (_tokenA, _tokenB)
            : (_tokenB, _tokenA);
        require(token0 != address(0), "Router: ZERO_ADDRESS");
    }

    // fetches and sorts the reserves for a pool
    function getReserves(
        address _tokenA,
        address _tokenB,
        bool _stable
    ) public view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = sortTokens(_tokenA, _tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IPool(
            poolFor(_tokenA, _tokenB, _stable)
        ).getReserves();
        (reserveA, reserveB) = _tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // determine whether to use stable or volatile pools for a given pool of tokens
    function getAmountOut(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut
    ) public view returns (uint256 amount, bool stable) {
        address pool = poolFor(_tokenIn, _tokenOut, true);
        uint256 amountStable;
        uint256 amountVolatile;
        if (IPoolFactory(defaultFactory).isPool(pool)) {
            amountStable = IPool(pool).getAmountOut(_amountIn, _tokenIn);
        }
        pool = poolFor(_tokenIn, _tokenOut, false);
        if (IPoolFactory(defaultFactory).isPool(pool)) {
            amountVolatile = IPool(pool).getAmountOut(_amountIn, _tokenIn);
        }
        return
            amountStable > amountVolatile
                ? (amountStable, true)
                : (amountVolatile, false);
    }

    //@override
    //getAmountOut	:	bool stable
    //Gets exact output for specific pool-type(S|V)
    function getAmountOut(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut,
        bool _stable
    ) public view returns (uint256 amount) {
        address pool = poolFor(_tokenIn, _tokenOut, _stable);
        if (IPoolFactory(defaultFactory).isPool(pool)) {
            amount = IPool(pool).getAmountOut(_amountIn, _tokenIn);
        }
    }

    // given some amount of an asset and pool reserves, returns an equivalent amount of the other asset
    function _quoteLiquidity(
        uint256 _amountA,
        uint256 _reserveA,
        uint256 _reserveB
    ) internal pure returns (uint256 amountB) {
        require(_amountA > 0, "Router: INSUFFICIENT_AMOUNT");
        require(
            _reserveA > 0 && _reserveB > 0,
            "Router: INSUFFICIENT_LIQUIDITY"
        );
        amountB = (_amountA * _reserveB) / _reserveA;
    }

    function _safeTransferETH(address _to, uint256 _value) internal {
        (bool success, ) = _to.call{value: _value}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    function _safeTransfer(
        address _token,
        address _to,
        uint256 _value
    ) internal {
        require(_token.code.length > 0);
        (bool success, bytes memory data) = _token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, _to, _value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(
        address _token,
        address _from,
        address _to,
        uint256 _value
    ) internal {
        require(_token.code.length > 0);
        (bool success, bytes memory data) = _token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                _from,
                _to,
                _value
            )
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
