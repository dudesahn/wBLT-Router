// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IWeth {
    function deposit() external payable;
}

interface ILiquityStaking {
    function stake(uint _LQTYamount) external;

    function unstake(uint _LQTYamount) external;

    function getPendingETHGain(address _user) external view returns (uint);

    function getPendingLUSDGain(address _user) external view returns (uint);

    function stakes(address _user) external view returns (uint);
}

contract StrategyLQTYStaker is BaseStrategy {
    using SafeERC20 for IERC20;
    /* ========== STATE VARIABLES ========== */

    /// @notice LQTY staking contract
    ILiquityStaking public lqtyStaking = ILiquityStaking(0x4f9Fbb3f1E99B56e0Fe2892e623Ed36A76Fc605d);

    // this means all of our fee values are in basis points
    uint256 internal constant FEE_DENOMINATOR = 10000;

    /// @notice Address of our main rewards token, LUSD
    IERC20 public constant lusd = IERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0);
    
    /// @notice Convert our ether rewards into weth for easier swaps
    IERC20 public constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // we use this to be able to adjust our strategy's name
    string internal stratName;
    
    // basically we should have each harvest where more LQTY is transferred here also stake the LQTY and send profits back to the vault as well

    /* ========== CONSTRUCTOR ========== */

    constructor() {
        // do our approvals
        lqty.approve(address(lqtyStaking), type(uint256).max);

        // set our strategy's name
        stratName = "";
    }

    /* ========== VIEWS ========== */

    /// @notice Strategy name.
    function name() external view override returns (string memory) {
        return stratName;
    }

    /// @notice Balance of want staked in Liquity's staking contract.
    function stakedBalance() public view returns (uint256) {
        return proxy.balanceOf(gauge);
    }

    /// @notice Balance of want sitting in our strategy.
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    /// @notice Total assets the strategy holds, sum of loose and staked want.
    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + stakedBalance();
    }

    /* ========== CORE FUNCTIONS ========== */
    
    function strategyHarvest(uint256 _lqtyAmount)
        external
        onlyStrategy
    {
        address _strategy = strategy;
        if (_lqtyAmount > 0) {
            lqty.transferFrom(_strategy, address(this), _lqtyAmount);
            lqtyStaking.stake(_lqtyAmount);
        } else {
            lqtyStaking.unstake(0);
        }

        // convert our ether to weth if we have any
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWeth(address(weth)).deposit{value: ethBalance}();
        }
        
        uint256 lusdBalance = lusd.balanceOf(address(this));
        uint256 wethBalance = weth.balanceOf(address(this));

        if (lusdBalance > 0) {
            lusd.safeTransfer(_strategy, lusdBalance);
        }

        if (wethBalance > 0) {
            weth.safeTransfer(_strategy, lusdBalance);
        }
    }
    
    function unstakeAndSweep(uint256 _amount) onlyGovernance {
        // if we request more than we have, we still just get our whole stake
        lqtyStaking.unstake(_amount);
        
        // convert our ether to weth if we have any
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWeth(address(weth)).deposit{value: ethBalance}();
        }
        
        uint256 lusdBalance = lusd.balanceOf(address(this));
        uint256 wethBalance = weth.balanceOf(address(this));

        if (lusdBalance > 0) {
            lusd.safeTransfer(_strategy, lusdBalance);
        }

        if (wethBalance > 0) {
            weth.safeTransfer(_strategy, lusdBalance);
        }
        
        uint256 lqtyBalance = lqty.balanceOf(address(this));
        if (lqtyBalance > 0) {
            lqty.safeTransfer(governance, lqtyBalance);
        }
        emit LqtySwept(_amount);
    }

    // sweep out tokens sent here
    function sweep(address _token) external onlyGovernance {
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(_token).safeTransfer(governance, tokenBalance);
        }
    }

    /// @notice Calculates the profit if all claimable assets were sold for USDC (6 decimals).
    /// @dev Uses yearn's lens oracle, if returned values are strange then troubleshoot there.
    /// @return Total return in USDC from selling claimable LUSD and ETH.
    function claimableProfitInUsdc() public view returns (uint256) {
        IOracle yearnOracle = IOracle(
            0x83d95e0D5f402511dB06817Aff3f9eA88224B030
        ); // yearn lens oracle
        uint256 lusdPrice = yearnOracle.getPriceUsdcRecommended(address(lusd));
        uint256 etherPrice = yearnOracle.getPriceUsdcRecommended(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // use weth address
        
        uint256 claimableLusd = lqtyStaking.getPendingLUSDGain(address(this));
        uint256 claimableETH = lqtyStaking.getPendingETHGain(address(this));

        // Oracle returns prices as 6 decimals, so multiply by claimable amount and divide by token decimals (1e18)
        return
            (lusdPrice * claimableLusd + etherPrice * claimableETH) / 1e18;
    }

    // include so our contract plays nicely with ether
    receive() external payable {}

    /* ========== SETTERS ========== */
    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    /// @notice Use this to set or update our voter contracts.
    /// @dev For Curve strategies, this is where we send our keepCVX.
    ///  Only governance can set this.
    /// @param _strategy Address of our lqty strategy.
    function setStrategy(address _strategy) external onlyGovernance {
        strategy = _strategy;        
    }
}
