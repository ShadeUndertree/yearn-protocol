// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.7.0;

import "@openzeppelinV3/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV3/contracts/math/SafeMath.sol";

interface VaultAPI {
    function token() external view returns (address);

    function strategies(address _strategy)
        external
        view
        returns (
            uint256 activation,
            uint256 debtLimit,
            uint256 rateLimit,
            uint256 lastSync,
            uint256 totalDebt,
            uint256 totalReturns
        );

    /*
     * View how much the Vault would increase this strategy's borrow limit,
     * based on it's present performance (since last sync). Can be used to
     * determine expectedReturn in your strategy.
     */
    function creditAvailable() external view returns (uint256);

    /*
     * View how much the Vault expect this strategy to return at the current block,
     * based on it's present performance (since last sync). Can be used to
     * determine expectedReturn in your strategy.
     */
    function expectedReturn() external view returns (uint256);

    /*
     * This is the main contact point where the strategy interacts with the Vault.
     * It is critical that this call is handled as intended by the Strategy.
     * Therefore, this function will be called by BaseStrategy to make sure the
     * integration is correct.
     */
    function sync(uint256 _return) external;

    /*
     * This function is used in the scenario where there is a newer strategy that
     * would hold the same positions as this one, and those positions are easily
     * transferrable to the newer strategy. These positions must be able to be
     * transferred at the moment this call is made, if any prep is required to
     * execute a full transfer in one transaction, that must be accounted for
     * separately from this call.
     */
    function migrateStrategy(address _newStrategy) external;

    /*
     * This function should only be used in the scenario where the strategy is
     * being retired but no migration of the positions are possible, or in the
     * extreme scenario that the Strategy needs to be put into "Emergency Exit"
     * mode in order for it to exit as quickly as possible. The latter scenario
     * could be for any reason that is considered "critical" that the Strategy
     * exits it's position as fast as possible, such as a sudden change in market
     * conditions leading to losses, or an imminent failure in an external
     * dependency.
     */
    function revokeStrategy() external;
}

/*
 * This interface is here for the keeper bot to use
 */
interface StrategyAPI {
    function keeper() external view returns (address);

    function tendTrigger(uint256 gasCost) external view returns (bool);

    function tend() external;

    function harvestTrigger(uint256 gasCost) external view returns (bool);

    function harvest() external;
}

/*
 * BaseStrategy implements all of the required functionality to interoperate closely
 * with the core protocol. This contract should be inherited and the abstract methods
 * implemented to adapt the strategy to the particular needs it has to create a return.
 */

abstract contract BaseStrategy {
    using SafeMath for uint256;

    VaultAPI public vault;
    address public strategist;
    address public keeper;
    address public governance;
    address public pendingGovernance;

    IERC20 public want;

    // Adjust this to keep some of the position in reserve in the strategy,
    // to accomodate larger variations needed to sustain the strategy's core positon(s)
    uint256 public reserve = 0;

    uint256 public performanceFee = 500;
    uint256 public constant PERFORMANCE_MAX = 10000;

    bool public emergencyExit;

    constructor(address _vault, address _governance) public {
        vault = VaultAPI(_vault);
        want = IERC20(vault.token());
        want.approve(_vault, uint256(-1)); // Give Vault unlimited access (might save gas)
        strategist = msg.sender;
        keeper = msg.sender;
        governance = _governance;
    }

    // 2-stage commit to takeover governance role
    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        pendingGovernance = _governance;
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "!governance");
        governance = pendingGovernance;
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == strategist || msg.sender == governance, "!governance");
        strategist = _strategist;
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == strategist || msg.sender == governance, "!governance");
        keeper = _keeper;
    }

    function setPerformanceFee(uint256 _performanceFee) external {
        require(msg.sender == governance, "!governance");
        performanceFee = _performanceFee;
    }

    /*
     * Provide an accurate expected value for the return this strategy
     * would provide to the Vault the next time `sync()` is called
     * (since the last time it was called)
     */
    function expectedReturn() public virtual view returns (uint256);

    /*
     * Perform any strategy unwinding or other calls necessary to capture
     * the "free return" this strategy has generated since the last time it's
     * core position(s) were adusted. Examples include unwrapping extra rewards.
     * This call is only used during "normal operation" of a Strategy, and should
     * be optimized to minimize losses as much as possible. It is okay to report
     * "no returns", however this will affect the credit limit extended to the
     * strategy and reduce it's overall position if lower than expected returns
     * are sustained for long periods of time.
     */
    function prepareReturn() internal virtual;

    /*
     * Perform any adjustments to the core position(s) of this strategy given
     * what change the Vault made in the "free return" available to the strategy.
     * Note that all "free returns" in the strategy after the sync are available
     * for reinvestment. Also note that this number could be 0, and you should
     * handle that scenario accordingly.
     */
    function adjustPosition() internal virtual;

    /*
     * Make as much capital as possible "free" for the Vault to take. Some slippage
     * is allowed, since when this method is called the strategist is no longer receiving
     * their performance fee. The goal is for the strategy to divest as quickly as possible
     * while not suffering exorbitant losses. This function is used instead of prepareReturn()
     */
    function exitPosition() internal virtual;

    /*
     * Provide a signal to the keeper that `tend()` should be called. The keeper will provide
     * the estimated gas cost that they would pay to call `tend()`, and this function should
     * use that estimate to make a determination if calling it is "worth it" for the keeper.
     * This is not the only consideration into issuing this trigger, for example if the position
     * would be negatively affected if `tend()` is not called shortly, then this can return `true`
     * even if the keeper might be "at a loss" (keepers are always reimbursed by yEarn)
     *
     * NOTE: this call and `harvestTrigger` should never return `true` at the same time.
     * NOTE: if `tend()` is never intended to be called, it should always return `false`
     */
    function tendTrigger(uint256 gasCost) public virtual view returns (bool);

    function tend() external {
        require(msg.sender == keeper || msg.sender == strategist || msg.sender == governance);
        // NOTE: Don't take profits with this call, but adjust for better gains
        adjustPosition();
    }

    /*
     * Provide a signal to the keeper that `harvest()` should be called. The keeper will provide
     * the estimated gas cost that they would pay to call `harvest()`, and this function should
     * use that estimate to make a determination if calling it is "worth it" for the keeper.
     * This is not the only consideration into issuing this trigger, for example if the position
     * would be negatively affected if `harvest()` is not called shortly, then this can return `true`
     * even if the keeper might be "at a loss" (keepers are always reimbursed by yEarn)
     *
     * NOTE: this call and `tendTrigger` should never return `true` at the same time.
     */
    function harvestTrigger(uint256 gasCost) public virtual view returns (bool);

    function harvest() external {
        require(msg.sender == keeper || msg.sender == strategist || msg.sender == governance);

        if (emergencyExit) {
            exitPosition(); // Free up as much capital as possible
            // NOTE: Don't take performance fee in this scenario
        } else {
            prepareReturn(); // Free up returns for Vault to pull
            // Send strategist their performance fee
            uint256 _fee = want.balanceOf(address(this)).sub(reserve).mul(performanceFee).div(PERFORMANCE_MAX);
            want.transfer(strategist, _fee);
        }

        if (reserve > want.balanceOf(address(this))) reserve = want.balanceOf(address(this));

        // Allow Vault to take up to the "free" balance of this contract
        vault.sync(want.balanceOf(address(this)).sub(reserve));

        adjustPosition(); // Check if free returns are left, and re-invest them
        // TODO: Could move fee calculation here, would actually bias more towards growth
    }

    /*
     * Do anything necesseary to prepare this strategy for migration, such
     * as transfering any reserve or LP tokens, CDPs, or other tokens or stores of value.
     */
    function prepareMigration(address _newStrategy) internal virtual;

    function migrate(address _newStrategy) external {
        require(msg.sender == strategist || msg.sender == governance);
        require(BaseStrategy(_newStrategy).vault() == vault);
        prepareMigration(_newStrategy);
        vault.migrateStrategy(_newStrategy);
    }

    function setEmergencyExit() external {
        require(msg.sender == strategist || msg.sender == governance);
        emergencyExit = true;
        exitPosition();
        vault.revokeStrategy();
        if (reserve > want.balanceOf(address(this))) reserve = want.balanceOf(address(this));
        vault.sync(want.balanceOf(address(this)).sub(reserve));
    }

    function sweep(address _token) external {
        require(_token != address(want), "!want");
        IERC20(_token).transfer(governance, IERC20(_token).balanceOf(address(this)));
    }
}
