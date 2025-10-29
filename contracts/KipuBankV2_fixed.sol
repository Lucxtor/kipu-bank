// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/**
 * @title KipuBank
 * @author Luis Felipe Fabiane
 * @notice Basic vault: ETH/ERC20 deposits & withdrawals with USD-based per-tx limit for ETH,
 *         native wei cap, oracle hygiene, SafeERC20 usage, reentrancy guard, and ERC-7528 canonicalization.
 */
contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN");

    // ERC-7528 canonical ETH alias
    address public constant ETH_ALIAS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    mapping(address => mapping(address => uint256)) private tokenBalances;
    mapping(address => AggregatorV3Interface) public priceFeeds;

    uint256 public usdWithdrawLimit8;

    uint256 public bankCapWei;

    uint256 public nativePerTxCapWei;

    uint256 public priceStalenessSeconds;

    uint256 public depositCount;
    uint256 public withdrawCount;

    // events
    event Deposit(address indexed depositor, uint256 amount, uint256 newBalance);
    event TokenDeposit(address indexed token, address indexed depositor, uint256 amount, uint256 newBalance);
    event Withdraw(address indexed withdrawer, uint256 amount, uint256 newBalance);
    event TokenWithdraw(address indexed token, address indexed withdrawer, uint256 amount, uint256 newBalance);
    event BalanceChange(address indexed admin, address indexed user, address token, uint256 newBalance);

    // errors
    error ZeroAmount();
    error BankCapExceeded(uint256 newBalance, uint256 bankCap);
    error UsdWithdrawLimitExceeded(uint256 requestedWithdraw, uint256 usdLimit8, uint256 maxAllowedWei);
    error InsuficientBalance(uint256 requestedWithdraw, uint256 currentBalance);
    error InvalidPrice();
    error StalePrice();
    error TransferFailed();
    error NativePerTxExceeded(uint256 requested, uint256 cap);
    error NativeValueWithNonNativeToken();

    constructor(
        address admin,
        uint256 _usdWithdrawLimitDollars, // specified in plain dollars (e.g. 1000)
        uint256 _bankCapWei,
        AggregatorV3Interface ethFeed
    ) {
        require(admin != address(0), "admin zero");
        _grantRole(ADMIN_ROLE, admin);

        usdWithdrawLimit8 = _usdWithdrawLimitDollars * 1e8;
        bankCapWei = _bankCapWei;

        priceFeeds[ETH_ALIAS] = ethFeed;

        priceStalenessSeconds = 1 hours;
    }

    function setNativePerTxCapWei(uint256 capWei) external onlyRole(ADMIN_ROLE) {
        nativePerTxCapWei = capWei;
    }

    function setBankCapWei(uint256 capWei) external onlyRole(ADMIN_ROLE) {
        bankCapWei = capWei;
    }

    function setUsdWithdrawLimitDollars(uint256 dollars) external onlyRole(ADMIN_ROLE) {
        usdWithdrawLimit8 = dollars * 1e8;
    }

    function setPriceFeed(address token, AggregatorV3Interface feed) external onlyRole(ADMIN_ROLE) {
        priceFeeds[_canon(token)] = feed;
    }

    function setPriceStalenessSeconds(uint256 seconds_) external onlyRole(ADMIN_ROLE) {
        priceStalenessSeconds = seconds_;
    }

    function _canon(address t) internal pure returns (address) {
        return (t == address(0) || t == ETH_ALIAS) ? ETH_ALIAS : t;
    }

    /// @dev get price normalized to 8 decimals from provided feed; validates >0 and freshness 
    function _getPrice8ForFeed(AggregatorV3Interface feed) internal view returns (uint256 p8) {
        if (address(feed) == address(0)) revert InvalidPrice();

        (uint80 roundId, int256 ans, , uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (ans <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert StalePrice();
        if (block.timestamp - updatedAt > priceStalenessSeconds) revert StalePrice();
        if (answeredInRound < roundId) revert InvalidPrice();

        uint8 dec = feed.decimals();
        uint256 p = uint256(ans);

        if (dec == 8) {
            p8 = p;
        } else if (dec > 8) {
            p8 = p / (10 ** (dec - 8));
        } else {
            // dec < 8
            p8 = p * (10 ** (8 - dec));
        }
    }

    /// @dev returns ETH price normalized to 8 decimals using priceFeeds[ETH_ALIAS]
    function _getEthPrice8() internal view returns (uint256) {
        AggregatorV3Interface feed = priceFeeds[ETH_ALIAS];
        return _getPrice8ForFeed(feed);
    }

    /// @dev compute max allowed wei from the configured usdWithdrawLimit8
    function _maxWeiFromUsdLimit8(uint256 usdLimit8_) internal view returns (uint256) {
        uint256 price8 = _getEthPrice8();
        return (usdLimit8_ * 1e18) / price8;
    }

    /**
     * @dev bank cap guard for ETH: post-deposit contract balance must not exceed bankCapWei.
     * Note: when called during a payable call, address(this).balance already reflects msg.value,
     * so checking address(this).balance <= bankCapWei is sufficient.
     */
    modifier _bankCapCheck(address token) {
        address canon = _canon(token);
        if (canon == ETH_ALIAS) {
            if (address(this).balance > bankCapWei) {
                revert BankCapExceeded(address(this).balance, bankCapWei);
            }
        }
        _;
    }

    /**
     * @notice Deposit ETH (token==address(0) or ETH_ALIAS) or ERC20 (token==token address).
     * - ETH: send value and pass token == address(0) or ETH_ALIAS.
     * - ERC20: safeTransferFrom + credit actual received (fee-on-transfer aware).
     */
    function deposit(address token, uint256 amount) external payable _bankCapCheck(token) {
        address canon = _canon(token);

        if (msg.value > 0 && canon != ETH_ALIAS) revert NativeValueWithNonNativeToken();
        if (msg.value == 0 && canon == ETH_ALIAS) {
            revert ZeroAmount();
        }

        if (canon == ETH_ALIAS) {
            uint256 value = msg.value;
            if (value == 0) revert ZeroAmount();

            tokenBalances[ETH_ALIAS][msg.sender] += value;
            depositCount++;

            emit Deposit(msg.sender, value, tokenBalances[ETH_ALIAS][msg.sender]);
            return;
        }

        // ERC20 deposit
        if (amount == 0) revert ZeroAmount();
        if (msg.value != 0) revert NativeValueWithNonNativeToken(); // extra safety

        IERC20 t = IERC20(token);
        uint256 b0 = t.balanceOf(address(this));

        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - b0;
        if (received == 0) revert ZeroAmount();

        tokenBalances[canon][msg.sender] += received;
        depositCount++;

        emit TokenDeposit(canon, msg.sender, received, tokenBalances[canon][msg.sender]);
    }

    /**
     * @notice Withdraw ETH or ERC20.
     * - Enforces USD cap for ETH (using ETH price feed normalized to 8 decimals).
     * - Enforces native per-tx wei cap when set.
     * - Uses CEI and nonReentrant.
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address canon = _canon(token);

        uint256 userBal = tokenBalances[canon][msg.sender];
        if (userBal < amount) revert InsuficientBalance(amount, userBal);

        if (canon == ETH_ALIAS) {
            uint256 usdCapWei = _maxWeiFromUsdLimit8(usdWithdrawLimit8);
            if (amount > usdCapWei) revert UsdWithdrawLimitExceeded(amount, usdWithdrawLimit8, usdCapWei);

            if (nativePerTxCapWei != 0 && amount > nativePerTxCapWei) {
                revert NativePerTxExceeded(amount, nativePerTxCapWei);
            }
        }

        // effects
        tokenBalances[canon][msg.sender] = userBal - amount;
        withdrawCount++;

        // interactions
        if (canon == ETH_ALIAS) {
            (bool ok, ) = msg.sender.call{value: amount}("");
            if (!ok) {
                tokenBalances[canon][msg.sender] += amount;
                withdrawCount--;
                revert TransferFailed();
            }
            emit Withdraw(msg.sender, amount, tokenBalances[canon][msg.sender]);
        } else {
            IERC20(canon).safeTransfer(msg.sender, amount);

            emit TokenWithdraw(canon, msg.sender, amount, tokenBalances[canon][msg.sender]);
        }
    }

    // Admin: change user balance (admin override)
    function changeUserBalance(address user, address token, uint256 amount) external onlyRole(ADMIN_ROLE) {
        address canon = _canon(token);
        tokenBalances[canon][user] = amount;
        emit BalanceChange(msg.sender, user, canon, amount);
    }

    function getUserBalance(address user, address token) public view onlyRole(ADMIN_ROLE) returns (uint256) {
        return tokenBalances[_canon(token)][user];
    }

    function getMyBalance(address token) external view returns (uint256) {
        return tokenBalances[_canon(token)][msg.sender];
    }

    function getEthPrice8() external view returns (uint256) {
        return _getEthPrice8();
    }

    function getBankCapWei() external view returns (uint256) {
        return bankCapWei;
    }

    /* ========== ETH RECEIVE / FALLBACK ==========
     * Users MUST call deposit(...) to send ETH so caps/accounting are enforced.
     */
    receive() external payable {
        revert("direct ETH not allowed; use deposit()");
    }

    fallback() external payable {
        revert("use deposit()");
    }
}
