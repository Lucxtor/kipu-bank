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

// Minimal UniversalRouter interface (Uniswap V4)
interface IUniversalRouter {
    /// @notice execute arbitrary instructions (encoded according to UniswapV4 spec)
    /// @param instructions encoded route/actions
    /// @param value ETH value forwarded for the call
    function execute(bytes calldata instructions, uint256 value) external payable returns (bytes memory);
}

/**
 * @title KipuBankV3
 * @author Luis Felipe Fabiane
 * @notice KipuBank V3: accepts any token supported by Uniswap V4, swaps to USDC and credits user's USDC balance.
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN");

    // ERC-7528 canonical ETH alias
    address public constant ETH_ALIAS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    mapping(address => uint256) private usdcBalances;

    // Chainlink price feeds (canonicalized by _canon) - keep ETH feed for USD limits
    mapping(address => AggregatorV3Interface) public priceFeeds;

    uint256 public usdWithdrawLimit8; 

    uint256 public bankCapUsdc;

    uint256 public nativePerTxCapWei;

    uint256 public priceStalenessSeconds;

    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public totalBankUsdc;

    IERC20 public immutable USDC;
    IUniversalRouter public immutable universalRouter;

    // events
    event DepositUsdc(address indexed depositor, uint256 amountUsdc, uint256 newBalanceUsdc);
    event DepositAndSwapToUsdc(address indexed depositor, address indexed tokenIn, uint256 amountIn, uint256 receivedUsdc, uint256 newBalanceUsdc);
    event WithdrawUsdc(address indexed withdrawer, uint256 amountUsdc, uint256 newBalanceUsdc);
    event WithdrawEth(address indexed withdrawer, uint256 amountWei, uint256 newBalanceUsdc);
    event BalanceChange(address indexed admin, address indexed user, uint256 newBalanceUsdc);

    // errors
    error ZeroAmount();
    error BankCapExceeded(uint256 newTotal, uint256 bankCapUsdc);
    error UsdWithdrawLimitExceeded(uint256 requestedWithdrawWei, uint256 usdLimit8, uint256 maxAllowedWei);
    error InsuficientBalance(uint256 requested, uint256 currentBalanceUsdc);
    error InvalidPrice();
    error StalePrice();
    error TransferFailed();
    error NativePerTxExceeded(uint256 requested, uint256 cap);
    error NativeValueWithNonNativeToken();
    error SwapReturnedZero();

    constructor(
        address admin,
        address usdcAddress,
        address universalRouterAddress,
        uint256 _usdWithdrawLimitDollars, // specified in plain dollars (e.g. 1000)
        uint256 _bankCapUsdc, 
        AggregatorV3Interface ethFeed
    ) {
        require(admin != address(0), "admin zero");
        require(usdcAddress != address(0), "usdc zero");
        require(universalRouterAddress != address(0), "router zero");

        _grantRole(ADMIN_ROLE, admin);

        USDC = IERC20(usdcAddress);
        universalRouter = IUniversalRouter(universalRouterAddress);

        usdWithdrawLimit8 = _usdWithdrawLimitDollars * 1e8;
        bankCapUsdc = _bankCapUsdc;

        priceFeeds[ETH_ALIAS] = ethFeed;

        priceStalenessSeconds = 1 hours;
    }

    function setNativePerTxCapWei(uint256 capWei) external onlyRole(ADMIN_ROLE) {
        nativePerTxCapWei = capWei;
    }

    function setBankCapUsdc(uint256 capUsdc) external onlyRole(ADMIN_ROLE) {
        bankCapUsdc = capUsdc;
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
     * @notice Deposit ETH (token==address(0) or ETH_ALIAS) or ERC20 (token==token address).
     * - ETH: send value and pass token == address(0) or ETH_ALIAS.
     * - ERC20: safeTransferFrom + credit actual received (fee-on-transfer aware).
     */
    function deposit(address token, uint256 amount, bytes calldata routerInstructions) external payable nonReentrant {
        address canon = _canon(token);

        if (canon == ETH_ALIAS) {
            uint256 value = msg.value;
            if (value == 0) revert ZeroAmount();
            if (amount != 0) revert NativeValueWithNonNativeToken();

            uint256 before = USDC.balanceOf(address(this));

            universalRouter.execute{value: value}(routerInstructions, value);

            uint256 after = USDC.balanceOf(address(this));
            uint256 received = after - before;
            if (received == 0) revert SwapReturnedZero();

            uint256 newTotal = totalBankUsdc + received;
            if (newTotal > bankCapUsdc) revert BankCapExceeded(newTotal, bankCapUsdc);

            usdcBalances[msg.sender] += received;
            totalBankUsdc = newTotal;
            depositCount++;

            emit DepositAndSwapToUsdc(msg.sender, ETH_ALIAS, value, received, usdcBalances[msg.sender]);
            return;
        }

        if (amount == 0) revert ZeroAmount();

        if (canon == address(USDC)) {
            // direct USDC deposit
            // transfer USDC from user
            uint256 b0 = USDC.balanceOf(address(this));
            USDC.safeTransferFrom(msg.sender, address(this), amount);
            uint256 received = USDC.balanceOf(address(this)) - b0; // fee-on-transfer aware
            if (received == 0) revert ZeroAmount();

            uint256 newTotal = totalBankUsdc + received;
            if (newTotal > bankCapUsdc) revert BankCapExceeded(newTotal, bankCapUsdc);

            usdcBalances[msg.sender] += received;
            totalBankUsdc = newTotal;
            depositCount++;

            emit DepositUsdc(msg.sender, received, usdcBalances[msg.sender]);
            return;
        }

        // any other ERC20: transfer in, approve router, execute swap to USDC
        IERC20 t = IERC20(token);
        uint256 b0t = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 receivedIn = t.balanceOf(address(this)) - b0t;
        if (receivedIn == 0) revert ZeroAmount();

        t.safeApprove(address(universalRouter), 0);
        t.safeApprove(address(universalRouter), receivedIn);

        uint256 beforeUsdc = USDC.balanceOf(address(this));
        universalRouter.execute(routerInstructions, 0);
        uint256 afterUsdc = USDC.balanceOf(address(this));
        uint256 receivedUsdc = afterUsdc - beforeUsdc;

        t.safeApprove(address(universalRouter), 0);

        if (receivedUsdc == 0) revert SwapReturnedZero();

        uint256 newTotal = totalBankUsdc + receivedUsdc;
        if (newTotal > bankCapUsdc) revert BankCapExceeded(newTotal, bankCapUsdc);

        usdcBalances[msg.sender] += receivedUsdc;
        totalBankUsdc = newTotal;
        depositCount++;

        emit DepositAndSwapToUsdc(msg.sender, token, receivedIn, receivedUsdc, usdcBalances[msg.sender]);
    }

    /**
     * @notice Withdraw ETH or ERC20.
     * - Enforces USD cap for ETH (using ETH price feed normalized to 8 decimals).
     * - Enforces native per-tx wei cap when set.
     * - Uses CEI and nonReentrant.
     */
    function withdraw(address token, uint256 amount, bytes calldata routerInstructions) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        address canon = _canon(token);

        if (canon == address(USDC)) {
            uint256 userBal = usdcBalances[msg.sender];
            if (userBal < amount) revert InsuficientBalance(amount, userBal);

            // effects
            usdcBalances[msg.sender] = userBal - amount;
            totalBankUsdc -= amount;
            withdrawCount++;

            // interactions
            USDC.safeTransfer(msg.sender, amount);
            emit WithdrawUsdc(msg.sender, amount, usdcBalances[msg.sender]);
            return;
        }

        if (canon == ETH_ALIAS) {
            uint256 usdCapWei = _maxWeiFromUsdLimit8(usdWithdrawLimit8);
            if (amount > usdCapWei) revert UsdWithdrawLimitExceeded(amount, usdWithdrawLimit8, usdCapWei);

            if (nativePerTxCapWei != 0 && amount > nativePerTxCapWei) revert NativePerTxExceeded(amount, nativePerTxCapWei);

            uint256 price8 = _getEthPrice8(); // USD * 1e8 per ETH
            uint256 requiredUsdc6 = (amount * price8) / 1e20;
            if (requiredUsdc6 == 0) revert InsuficientBalance(requiredUsdc6, usdcBalances[msg.sender]);

            uint256 userBalUsdc = usdcBalances[msg.sender];
            if (userBalUsdc < requiredUsdc6) revert InsuficientBalance(requiredUsdc6, userBalUsdc);

            usdcBalances[msg.sender] = userBalUsdc - requiredUsdc6;
            totalBankUsdc -= requiredUsdc6;
            withdrawCount++;

            USDC.safeApprove(address(universalRouter), 0);
            USDC.safeApprove(address(universalRouter), requiredUsdc6);

            uint256 ethBefore = address(this).balance;
            universalRouter.execute(routerInstructions, 0);
            uint256 ethAfter = address(this).balance;
            uint256 receivedEth = ethAfter - ethBefore;

            USDC.safeApprove(address(universalRouter), 0);

            if (receivedEth < amount) {
                revert TransferFailed();
            }

            (bool ok, ) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();

            emit WithdrawEth(msg.sender, amount, usdcBalances[msg.sender]);
            return;
        }

        revert("unsupported token for withdraw");
    }

    /* ========== ADMIN: change user balance (admin override) ========== */
    function changeUserBalance(address user, uint256 amountUsdc) external onlyRole(ADMIN_ROLE) {
        uint256 prev = usdcBalances[user];
        if (amountUsdc > prev) {
            uint256 diff = amountUsdc - prev;
            uint256 newTotal = totalBankUsdc + diff;
            if (newTotal > bankCapUsdc) revert BankCapExceeded(newTotal, bankCapUsdc);
            totalBankUsdc = newTotal;
        } else if (prev > amountUsdc) {
            uint256 diff = prev - amountUsdc;
            totalBankUsdc -= diff;
        }
        usdcBalances[user] = amountUsdc;
        emit BalanceChange(msg.sender, user, amountUsdc);
    }

    function getUserBalance(address user) public view returns (uint256) {
        return usdcBalances[user];
    }

    function getMyBalance() external view returns (uint256) {
        return usdcBalances[msg.sender];
    }

    function getEthPrice8() external view returns (uint256) {
        return _getEthPrice8();
    }

    function getBankCapUsdc() external view returns (uint256) {
        return bankCapUsdc;
    }

    /* ========== ETH RECEIVE / FALLBACK ==========
     * The contract will receive ETH only during router operations. Direct sends are disallowed.
     */
    receive() external payable {
        revert("direct ETH not allowed; use deposit() with router instructions");
    }

    fallback() external payable {
        revert("use deposit()");
    }
}
