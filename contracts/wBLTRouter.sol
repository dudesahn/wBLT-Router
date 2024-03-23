// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./Interfaces.sol";
import {Math} from "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";
import {Ownable2Step} from "@openzeppelin/contracts@4.9.3/access/Ownable2Step.sol";

/**
 * @title wBLT Router
 * @notice This contract simplifies conversions between wBLT, BMX, and other assets
 *  using wBLT's underlying tokens as virtual pairs with wBLT.
 */

contract wBLTRouter is Ownable2Step {
    struct Route {
        address from;
        address to;
        bool stable;
    }

    /// @notice Factory address that deployed our Velodrome pool.
    address public constant factory =
        0xe21Aac7F113Bd5DC2389e4d8a8db854a87fD6951;

    IWETH public constant weth =
        IWETH(0x4200000000000000000000000000000000000006);
    uint256 internal constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes32 internal immutable pairCodeHash;
    uint256 internal immutable PRICE_PRECISION;
    uint256 internal immutable BASIS_POINTS_DIVISOR;

    /// @notice The tokens currently approved for deposit to BLT.
    address[] public bltTokens;

    // contracts used for wBLT mint/burn
    VaultAPI internal constant wBLT =
        VaultAPI(0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A);

    IBMX internal constant sBLT =
        IBMX(0x64755939a80BC89E1D2d0f93A312908D348bC8dE);

    IBMX internal constant rewardRouter =
        IBMX(0x49A97680938B4F1f73816d1B70C3Ab801FAd124B);

    IBMX internal constant morphexVault =
        IBMX(0xec8d8D4b215727f3476FF0ab41c406FA99b4272C);

    IBMX internal constant bltManager =
        IBMX(0x9fAc7b75f367d5B35a6D6D0a09572eFcC3D406C5);

    IBMX internal constant vaultUtils =
        IBMX(0xec31c83C5689C66cb77DdB5378852F3707022039);

    IShareHelper internal constant shareValueHelper =
        IShareHelper(0x4d2ED72285206D2b4b59CDA21ED0a979ad1F497f);

    constructor() {
        pairCodeHash = IPairFactory(factory).pairCodeHash();

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
     * @notice Performs chained getAmountOut calculations on any number of pairs.
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

            // if it's not depositing or withdrawing from wBLT, we can treat it like
            //  normal
            address pair = pairFor(
                _routes[i].from,
                _routes[i].to,
                _routes[i].stable
            );
            if (IPairFactory(factory).isPair(pair)) {
                amounts[i + 1] = IPair(pair).getAmountOut(
                    amounts[i],
                    _routes[i].from
                );
            }
        }
    }

    /**
     * @notice Swap wBLT or our paired token for ether.
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

        // if our first pair is mint/burn of wBLT, transfer to the router
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
                    pairFor(_routes[0].from, _routes[0].to, _routes[0].stable),
                    amounts[0]
                );
            }
        } else {
            _safeTransferFrom(
                _routes[0].from,
                msg.sender,
                pairFor(_routes[0].from, _routes[0].to, _routes[0].stable),
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
     * @notice Swap ETH for tokens, with special handling for wBLT pairs.
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
     * @notice Swap tokens for tokens, with special handling for wBLT pairs.
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

        // if our first pair is mint/burn of wBLT, transfer to the router
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
                    pairFor(_routes[0].from, _routes[0].to, _routes[0].stable),
                    amounts[0]
                );
            }
        } else {
            _safeTransferFrom(
                _routes[0].from,
                msg.sender,
                pairFor(_routes[0].from, _routes[0].to, _routes[0].stable),
                amounts[0]
            );
        }

        _swap(amounts, _routes, _to);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair or in this case, our underlying or wBLT
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
                        // if we're not done, send our underlying to the next pair
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
                        // if we're not done, directly send our wBLT to the next pair
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
                to = pairFor(
                    _routes[i + 1].from,
                    _routes[i + 1].to,
                    _routes[i + 1].stable
                );
            }

            if (directSend) {
                _safeTransfer(_routes[i].to, to, received);
            } else {
                IPair(
                    pairFor(_routes[i].from, _routes[i].to, _routes[i].stable)
                ).swap(amount0Out, amount1Out, to, new bytes(0));
            }
        }
    }

    /**
     * @notice
     *  Add liquidity for wBLT-TOKEN with an underlying token for wBLT.
     * @dev Removed the stable and tokenA params from the standard function as they're not needed and so stack isn't too
     *  deep.
     * @param _underlyingToken The token to zap into wBLT for creating the LP.
     * @param _amountToZapIn Amount of underlying token to deposit to wBLT.
     * @param token The token to pair with wBLT for the LP.
     * @param _amountWrappedBLTDesired The amount of wBLT we would like to deposit to the LP.
     * @param _amountTokenDesired The amount of other token we would like to deposit to the LP.
     * @param _amountWrappedBLTMin The minimum amount of wBLT we will accept in the LP.
     * @param _amountTokenMin The minimum amount of other token we will accept in the LP.
     * @param _to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually deposited in the LP.
     * @return amountToken Amount of our other token actually deposited in the LP.
     * @return liquidity Amount of LP token generated.
     */
    function addLiquidity(
        address _underlyingToken,
        uint256 _amountToZapIn,
        address token,
        uint256 _amountWrappedBLTDesired,
        uint256 _amountTokenDesired,
        uint256 _amountWrappedBLTMin,
        uint256 _amountTokenMin,
        address _to
    )
        external
        returns (
            uint256 amountWrappedBLT,
            uint256 amountToken,
            uint256 liquidity
        )
    {
        _safeTransferFrom(
            _underlyingToken,
            msg.sender,
            address(this),
            _amountToZapIn
        );

        // first, deposit the underlying to wBLT, deposit function checks that underlying is actually in the LP
        _amountWrappedBLTDesired = _depositToWrappedBLT(_underlyingToken);

        (amountWrappedBLT, amountToken) = _addLiquidity(
            address(wBLT),
            token,
            false, // stable LPs with wBLT would be kind dumb
            _amountWrappedBLTDesired,
            _amountTokenDesired,
            _amountWrappedBLTMin,
            _amountTokenMin
        );
        address pair = pairFor(address(wBLT), token, false);

        // wBLT will already be in the router, so transfer for it. transferFrom for other token.
        _safeTransfer(address(wBLT), pair, amountWrappedBLT);
        _safeTransferFrom(token, msg.sender, pair, amountToken);

        liquidity = IPair(pair).mint(_to);
        uint256 remainingBalance = wBLT.balanceOf(address(this));
        // return any leftover wBLT
        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }
    }

    /**
     * @notice Add liquidity for wBLT-TOKEN with ether.
     * @param _amountToZapIn Amount of ether to deposit to wBLT.
     * @param token The token to pair with wBLT for the LP.
     * @param _amountWrappedBLTDesired The amount of wBLT we would like to deposit to the LP.
     * @param _amountTokenDesired The amount of other token we would like to deposit to the LP.
     * @param _amountWrappedBLTMin The minimum amount of wBLT we will accept in the LP.
     * @param _amountTokenMin The minimum amount of other token we will accept in the LP.
     * @param _to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually deposited in the LP.
     * @return amountToken Amount of our other token actually deposited in the LP.
     * @return liquidity Amount of LP token generated.
     */
    function addLiquidityETH(
        uint256 _amountToZapIn,
        address token,
        uint256 _amountWrappedBLTDesired,
        uint256 _amountTokenDesired,
        uint256 _amountWrappedBLTMin,
        uint256 _amountTokenMin,
        address _to
    )
        external
        payable
        returns (
            uint256 amountWrappedBLT,
            uint256 amountToken,
            uint256 liquidity
        )
    {
        // deposit to weth, then everything is the same
        weth.deposit{value: _amountToZapIn}();
        if (weth.balanceOf(address(this)) != _amountToZapIn) {
            revert("WETH not sent");
        }

        // first, deposit the underlying to wBLT, deposit function checks that underlying is actually in the LP
        _amountWrappedBLTDesired = _depositToWrappedBLT(address(weth));

        (amountWrappedBLT, amountToken) = _addLiquidity(
            address(wBLT),
            token,
            false, // stable LPs with wBLT would be kind dumb
            _amountWrappedBLTDesired,
            _amountTokenDesired,
            _amountWrappedBLTMin,
            _amountTokenMin
        );
        address pair = pairFor(address(wBLT), token, false);

        // wBLT will already be in the router, so transfer for it. transferFrom for other token.
        _safeTransfer(address(wBLT), pair, amountWrappedBLT);
        _safeTransferFrom(token, msg.sender, pair, amountToken);
        liquidity = IPair(pair).mint(_to);

        // return any leftover wBLT
        uint256 remainingBalance = wBLT.balanceOf(address(this));
        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }
    }

    /**
     * @notice Remove liquidity from a wBLT-TOKEN LP, and convert wBLT to a given underlying.
     * @param _targetToken Address of our desired wBLT underlying to withdraw to.
     * @param _token The other token paired with wBLT in our LP.
     * @param _liquidity The amount of LP tokens we want to burn.
     * @param _amountWrappedBLTMin The minimum amount of wBLT we will accept from the LP.
     * @param _amountTokenMin The minimum amount of our other token we will accept from the LP.
     * @param _to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually received from the LP.
     * @return amountToken Amount of other token actually received from the LP.
     * @return amountUnderlying Amount of our underlying token received from the wBLT.
     */
    function removeLiquidity(
        address _targetToken,
        address _token,
        uint256 _liquidity,
        uint256 _amountWrappedBLTMin,
        uint256 _amountTokenMin,
        address _to
    )
        external
        returns (
            uint256 amountWrappedBLT,
            uint256 amountToken,
            uint256 amountUnderlying
        )
    {
        // stable is dumb with wBLT
        address pair = pairFor(address(wBLT), _token, false);
        // send liquidity to pair
        require(IPair(pair).transferFrom(msg.sender, pair, _liquidity));
        (uint256 amount0, uint256 amount1) = IPair(pair).burn(address(this));
        (address token0, ) = sortTokens(address(wBLT), _token);
        (amountWrappedBLT, amountToken) = address(wBLT) == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(
            amountWrappedBLT >= _amountWrappedBLTMin,
            "Router: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountToken >= _amountTokenMin,
            "Router: INSUFFICIENT_B_AMOUNT"
        );

        _safeTransfer(_token, _to, amountToken);

        amountUnderlying = _withdrawFromWrappedBLT(_targetToken);
        _safeTransfer(_targetToken, _to, amountUnderlying);
    }

    /**
     * @notice Remove liquidity from a wBLT-TOKEN LP, and convert wBLT to ether.
     * @param _token The other token paired with wBLT in our LP.
     * @param _liquidity The amount of LP tokens we want to burn.
     * @param _amountWrappedBLTMin The minimum amount of wBLT we will accept from the LP.
     * @param _amountTokenMin The minimum amount of our other token we will accept from the LP.
     * @param _to Address that will receive the LP token.
     * @return amountWrappedBLT Amount of wBLT actually received from the LP.
     * @return amountToken Amount of other token actually received from the LP.
     * @return amountUnderlying Amount of ether received from the wBLT.
     */
    function removeLiquidityETH(
        address _token,
        uint256 _liquidity,
        uint256 _amountWrappedBLTMin,
        uint256 _amountTokenMin,
        address _to
    )
        external
        returns (
            uint256 amountWrappedBLT,
            uint256 amountToken,
            uint256 amountUnderlying
        )
    {
        // stable is dumb with wBLT
        address pair = pairFor(address(wBLT), _token, false);
        // send liquidity to pair
        require(IPair(pair).transferFrom(msg.sender, pair, _liquidity));
        (uint256 amount0, uint256 amount1) = IPair(pair).burn(address(this));
        (address token0, ) = sortTokens(address(wBLT), _token);
        (amountWrappedBLT, amountToken) = address(wBLT) == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(
            amountWrappedBLT >= _amountWrappedBLTMin,
            "Router: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountToken >= _amountTokenMin,
            "Router: INSUFFICIENT_B_AMOUNT"
        );

        // send our ether and token to their final destination
        _safeTransfer(_token, _to, amountToken);
        amountUnderlying = _withdrawFromWrappedBLT(address(weth));
        weth.withdraw(amountUnderlying);
        _safeTransferETH(_to, amountUnderlying);
    }

    /**
     * @notice Exercise our oToken options using one of wBLT's underlying tokens.
     * @param _oToken The option token we are exercising.
     * @param _tokenToUse Address of our desired wBLT underlying to use for exercising our option.
     * @param _amount The amount of our token to use to generate our wBLT for exercising.
     * @param _oTokenAmount The amount of option tokens to exercise.
     * @param _discount Our discount in exercising the option; this determines our lockup time.
     * @param _deadline Deadline for transaction to complete.
     * @return paymentAmount How much wBLT we spend to exercise.
     * @return lpAmount Amount of our LP we generate.
     */
    function exerciseLpWithUnderlying(
        address _oToken,
        address _tokenToUse,
        uint256 _amount,
        uint256 _oTokenAmount,
        uint256 _discount,
        uint256 _deadline
    ) external returns (uint256 paymentAmount, uint256 lpAmount) {
        // first person does the approvals for everyone else, what a nice person!
        _checkAllowance(_oToken);

        // transfer in our funds
        _safeTransferFrom(_tokenToUse, msg.sender, address(this), _amount);
        _safeTransferFrom(_oToken, msg.sender, address(this), _oTokenAmount);
        uint256 wBltToLp = _depositToWrappedBLT(_tokenToUse);

        (paymentAmount, lpAmount) = IBMX(_oToken).exerciseLp(
            _oTokenAmount,
            wBltToLp,
            msg.sender,
            _discount,
            _deadline
        );

        // return any leftover wBLT or underlying
        IERC20 token = IERC20(_tokenToUse);
        uint256 remainingUnderlying = token.balanceOf(address(this));
        uint256 remainingBalance = wBLT.balanceOf(address(this));

        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }

        if (remainingUnderlying > 0) {
            _safeTransfer(_tokenToUse, msg.sender, remainingUnderlying);
        }
    }

    /**
     * @notice Exercise our oToken options using raw ether.
     * @param _oToken The option token we are exercising.
     * @param _amount The amount of ETH to use to generate our wBLT for exercising.
     * @param _oTokenAmount The amount of option tokens to exercise.
     * @param _discount Our discount in exercising the option; this determines our lockup time.
     * @param _deadline Deadline for transaction to complete.
     * @return paymentAmount How much wBLT we spend to exercise.
     * @return lpAmount Amount of our LP we generate.
     */
    function exerciseLpWithUnderlyingETH(
        address _oToken,
        uint256 _amount,
        uint256 _oTokenAmount,
        uint256 _discount,
        uint256 _deadline
    ) external payable returns (uint256 paymentAmount, uint256 lpAmount) {
        // first person does the approvals for everyone else, what a nice person!
        _checkAllowance(_oToken);

        // deposit to weth, then everything is the same
        weth.deposit{value: _amount}();
        if (weth.balanceOf(address(this)) != _amount) {
            revert("WETH not sent");
        }

        // pull oToken
        _safeTransferFrom(_oToken, msg.sender, address(this), _oTokenAmount);

        // deposit our WETH to wBLT
        uint256 wBltToLp = _depositToWrappedBLT(address(weth));

        // exercise as normal
        (paymentAmount, lpAmount) = IBMX(_oToken).exerciseLp(
            _oTokenAmount,
            wBltToLp,
            msg.sender,
            _discount,
            _deadline
        );

        // return any leftover wBLT or WETH
        uint256 remainingUnderlying = weth.balanceOf(address(this));
        uint256 remainingBalance = wBLT.balanceOf(address(this));

        if (remainingBalance > 0) {
            _safeTransfer(address(wBLT), msg.sender, remainingBalance);
        }

        if (remainingUnderlying > 0) {
            _safeTransfer(address(weth), msg.sender, remainingUnderlying);
        }
    }

    // helper to approve new oTokens to spend wBLT from this router
    function _checkAllowance(address _token) internal {
        if (wBLT.allowance(address(this), _token) == 0) {
            wBLT.approve(_token, type(uint256).max);
        }
    }

    /**
     * @notice Check how much underlying (or ETH) we need to exercise to LP.
     * @param _oToken The option token we are exercising.
     * @param _tokenToUse The token to deposit to wBLT.
     * @param _oTokenAmount The amount of oToken to exercise.
     * @param _discount Our discount in exercising the option; this determines our lockup time.
     * @return atomicAmount The amount of token needed if exercising atomically from this calculation.
     * @return safeAmount Add an extra 0.01% to allow for per-second wBLT share price increases.
     */
    function quoteTokenNeededToExerciseLp(
        address _oToken,
        address _tokenToUse,
        uint256 _oTokenAmount,
        uint256 _discount
    ) external view returns (uint256 atomicAmount, uint256 safeAmount) {
        // calculate the exact amount we need
        (uint256 amountNeeded, uint256 amount2) = IBMX(_oToken)
            .getPaymentTokenAmountForExerciseLp(_oTokenAmount, _discount);

        amountNeeded += amount2;

        atomicAmount = quoteMintAmountBLT(_tokenToUse, amountNeeded);

        // give ourselves 0.01% of space for wBLT share price rising
        safeAmount = (atomicAmount * 10_001) / 10_000;
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
            rewardRouter.unstakeAndRedeemGlp(
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
        uint256 newMlp = rewardRouter.mintAndStakeGlp(
            address(_fromToken),
            token.balanceOf(address(this)),
            0,
            0
        );

        // specify that router should get the vault tokens
        tokens = wBLT.deposit(newMlp, address(this));
    }

    /**
     * @notice Zap out into a wBLT LP with an underlying token.
     * @param _underlyingToken The token to zap in to wBLT.
     * @param _token The token paired with wBLT.
     * @param _amountUnderlyingDesired The amount of underlying we would like to deposit.
     * @param _amountTokenDesired The amount of token to pair with our wBLT.
     * @return amountUnderlying Amount of underlying token to deposit.
     * @return amountWrappedBLT Amount of wBLT we will deposit.
     * @return amountToken Amount of other token to deposit.
     * @return liquidity Amount of LP token received.
     */
    function quoteAddLiquidityUnderlying(
        address _underlyingToken,
        address _token,
        uint256 _amountUnderlyingDesired,
        uint256 _amountTokenDesired
    )
        external
        view
        returns (
            uint256 amountUnderlying,
            uint256 amountWrappedBLT,
            uint256 amountToken,
            uint256 liquidity
        )
    {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(
            address(wBLT),
            _token,
            false
        );
        (uint256 reserveA, uint256 reserveB) = (0, 0);
        uint256 _totalSupply = 0;

        // convert our _amountUnderlyingDesired to amountWrappedBLTDesired. make sure to underestimate the amount out
        //  here so no risk of reverting
        uint256 amountWrappedBLTDesired = getMintAmountWrappedBLT(
            _underlyingToken,
            _amountUnderlyingDesired
        );

        if (_pair != address(0)) {
            _totalSupply = IERC20(_pair).totalSupply();
            (reserveA, reserveB) = getReserves(address(wBLT), _token, false);
        }
        if (reserveA == 0 && reserveB == 0) {
            (amountWrappedBLT, amountToken) = (
                amountWrappedBLTDesired,
                _amountTokenDesired
            );
            liquidity =
                Math.sqrt(amountWrappedBLT * amountToken) -
                MINIMUM_LIQUIDITY;
        } else {
            uint256 amountTokenOptimal = _quoteLiquidity(
                amountWrappedBLTDesired,
                reserveA,
                reserveB
            );
            if (amountTokenOptimal <= _amountTokenDesired) {
                (amountWrappedBLT, amountToken) = (
                    amountWrappedBLTDesired,
                    amountTokenOptimal
                );
                liquidity = Math.min(
                    (amountWrappedBLT * _totalSupply) / reserveA,
                    (amountToken * _totalSupply) / reserveB
                );
            } else {
                uint256 amountWrappedBLTOptimal = _quoteLiquidity(
                    _amountTokenDesired,
                    reserveB,
                    reserveA
                );
                (amountWrappedBLT, amountToken) = (
                    amountWrappedBLTOptimal,
                    _amountTokenDesired
                );
                liquidity = Math.min(
                    (amountWrappedBLT * _totalSupply) / reserveA,
                    (amountToken * _totalSupply) / reserveB
                );
            }
        }
        // based on the amount of wBLT, calculate how much of our underlying token we need to zap in
        amountUnderlying = quoteMintAmountBLT(
            _underlyingToken,
            amountWrappedBLT
        );
    }

    /**
     * @notice Zap out from a wBLT LP to an underlying token.
     * @param _underlyingToken The token to withdraw from wBLT.
     * @param _token The token paired with wBLT.
     * @param _liquidity The amount of wBLT LP to burn.
     * @return amountUnderlying Amount of underlying token received.
     * @return amountWrappedBLT Amount of wBLT token received before being converted to underlying.
     * @return amountToken Amount of other token received.
     */
    function quoteRemoveLiquidityUnderlying(
        address _underlyingToken,
        address _token,
        uint256 _liquidity
    )
        external
        view
        returns (
            uint256 amountUnderlying,
            uint256 amountWrappedBLT,
            uint256 amountToken
        )
    {
        // create the pair if it doesn't exist yet
        address _pair = IPairFactory(factory).getPair(
            address(wBLT),
            _token,
            false
        );

        if (_pair == address(0)) {
            return (0, 0, 0);
        }

        (uint256 reserveA, uint256 reserveB) = getReserves(
            address(wBLT),
            _token,
            false
        );
        uint256 _totalSupply = IERC20(_pair).totalSupply();

        // using balances ensures pro-rata distribution
        amountWrappedBLT = (_liquidity * reserveA) / _totalSupply;

        // using balances ensures pro-rata distribution
        amountToken = (_liquidity * reserveB) / _totalSupply;

        // simulate zapping out of wBLT to the selected underlying
        amountUnderlying = getRedeemAmountWrappedBLT(
            _underlyingToken,
            amountWrappedBLT,
            false
        );
    }

    /* ========== UNMODIFIED FUNCTIONS ========== */

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(
        address _tokenA,
        address _tokenB,
        bool _stable
    ) public view returns (address pair) {
        (address token0, address token1) = sortTokens(_tokenA, _tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(
                                abi.encodePacked(token0, token1, _stable)
                            ),
                            pairCodeHash // init code hash
                        )
                    )
                )
            )
        );
    }

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

    // fetches and sorts the reserves for a pair
    function getReserves(
        address _tokenA,
        address _tokenB,
        bool _stable
    ) public view returns (uint256 reserveA, uint256 reserveB) {
        (address token0, ) = sortTokens(_tokenA, _tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IPair(
            pairFor(_tokenA, _tokenB, _stable)
        ).getReserves();
        (reserveA, reserveB) = _tokenA == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
    }

    // determine whether to use stable or volatile pools for a given pair of tokens
    function getAmountOut(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut
    ) public view returns (uint256 amount, bool stable) {
        address pair = pairFor(_tokenIn, _tokenOut, true);
        uint256 amountStable;
        uint256 amountVolatile;
        if (IPairFactory(factory).isPair(pair)) {
            amountStable = IPair(pair).getAmountOut(_amountIn, _tokenIn);
        }
        pair = pairFor(_tokenIn, _tokenOut, false);
        if (IPairFactory(factory).isPair(pair)) {
            amountVolatile = IPair(pair).getAmountOut(_amountIn, _tokenIn);
        }
        return
            amountStable > amountVolatile
                ? (amountStable, true)
                : (amountVolatile, false);
    }

    //@override
    //getAmountOut	:	bool stable
    //Gets exact output for specific pair-type(S|V)
    function getAmountOut(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut,
        bool _stable
    ) public view returns (uint256 amount) {
        address pair = pairFor(_tokenIn, _tokenOut, _stable);
        if (IPairFactory(factory).isPair(pair)) {
            amount = IPair(pair).getAmountOut(_amountIn, _tokenIn);
        }
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
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

    function _addLiquidity(
        address _tokenA,
        address _tokenB,
        bool _stable,
        uint256 _amountADesired,
        uint256 _amountBDesired,
        uint256 _amountAMin,
        uint256 _amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        require(_amountADesired >= _amountAMin);
        require(_amountBDesired >= _amountBMin);

        address _pair = IPairFactory(factory).getPair(
            _tokenA,
            _tokenB,
            _stable
        );
        if (_pair == address(0)) {
            _pair = IPairFactory(factory).createPair(_tokenA, _tokenB, _stable);
        }

        // desired is the amount desired to be deposited for each token
        // optimal of one asset is the amount that is equal in value to our desired of the other asset
        // so, if our optimal is less than our min, we have an issue and pricing is likely off
        (uint256 reserveA, uint256 reserveB) = getReserves(
            _tokenA,
            _tokenB,
            _stable
        );
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (_amountADesired, _amountBDesired);
        } else {
            uint256 amountBOptimal = _quoteLiquidity(
                _amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= _amountBDesired) {
                require(
                    amountBOptimal >= _amountBMin,
                    "Router: INSUFFICIENT_B_AMOUNT"
                );
                (amountA, amountB) = (_amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = _quoteLiquidity(
                    _amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= _amountADesired);
                require(
                    amountAOptimal >= _amountAMin,
                    "Router: INSUFFICIENT_A_AMOUNT"
                );
                (amountA, amountB) = (amountAOptimal, _amountBDesired);
            }
        }
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
