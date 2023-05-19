// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IWETH } from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

import { IVault } from "../exchanges/interfaces/IVault.sol";
import { IFlashLoanRecipient as BalancerFlashloanRecipient } from "../exchanges/interfaces/IVault.sol";

import { Token } from "../token/Token.sol";
import { TokenLibrary } from "../token/TokenLibrary.sol";
import { IVersioned } from "../utility/interfaces/IVersioned.sol";
import { Upgradeable } from "../utility/Upgradeable.sol";
import { Utils, ZeroValue } from "../utility/Utils.sol";
import { IBancorNetwork, IFlashLoanRecipient } from "../exchanges/interfaces/IBancorNetwork.sol";
import { IBancorNetworkV2 } from "../exchanges/interfaces/IBancorNetworkV2.sol";
import { ICarbonController, TradeAction } from "../exchanges/interfaces/ICarbonController.sol";
import { PPM_RESOLUTION } from "../utility/Constants.sol";
import { MathEx } from "../utility/MathEx.sol";

import "hardhat/console.sol";

/**
 * @dev BancorArbitrage contract
 */
contract BancorArbitrage is ReentrancyGuardUpgradeable, Utils, Upgradeable {
    using SafeERC20 for IERC20;
    using TokenLibrary for Token;
    using Address for address payable;

    error InvalidExchangeId();
    error InvalidRouteLength();
    error InvalidInitialAndFinalTokens();
    error InvalidFlashloanStructure();
    error InvalidFlashLoanCaller();
    error MinTargetAmountTooHigh();
    error InvalidSourceToken();
    error InvalidETHAmountSent();
    error InsufficientBurn();

    // trade args
    struct Route {
        uint16 platformId;
        Token targetToken;
        uint256 minTargetAmount;
        uint256 deadline;
        address customAddress;
        uint256 customInt;
        bytes customData;
    }

    // trade args v2
    struct RouteV2 {
        uint16 platformId;
        Token sourceToken;
        Token targetToken;
        uint256 sourceAmount;
        uint256 minTargetAmount;
        uint256 deadline;
        address customAddress;
        uint256 customInt;
        bytes customData;
    }

    // rewards settings
    struct Rewards {
        uint32 percentagePPM;
        uint256 maxAmount;
    }

    struct Flashloan {
        uint16 platformId;
        IERC20[] sourceTokens;
        uint256[] sourceAmounts;
    }

    // platforms
    struct Platforms {
        IBancorNetworkV2 bancorNetworkV2;
        IBancorNetwork bancorNetworkV3;
        IUniswapV2Router02 uniV2Router;
        ISwapRouter uniV3Router;
        IUniswapV2Router02 sushiswapRouter;
        ICarbonController carbonController;
        IVault balancerVault;
    }

    // platform ids
    uint16 public constant PLATFORM_ID_BANCOR_V2 = 1;
    uint16 public constant PLATFORM_ID_BANCOR_V3 = 2;
    uint16 public constant PLATFORM_ID_UNISWAP_V2 = 3;
    uint16 public constant PLATFORM_ID_UNISWAP_V3 = 4;
    uint16 public constant PLATFORM_ID_SUSHISWAP = 5;
    uint16 public constant PLATFORM_ID_CARBON = 6;
    uint16 public constant PLATFORM_ID_BALANCER = 7;

    // minimum number of trade routes supported
    uint256 private constant MIN_ROUTE_LENGTH = 2;
    // maximum number of trade routes supported
    uint256 private constant MAX_ROUTE_LENGTH = 10;

    // the bnt contract
    IERC20 internal immutable _bnt;

    // WETH9 contract
    IERC20 internal immutable _weth;

    // bancor v2 network contract
    IBancorNetworkV2 internal immutable _bancorNetworkV2;

    // bancor v3 network contract
    IBancorNetwork internal immutable _bancorNetworkV3;

    // uniswap v2 router contract
    IUniswapV2Router02 internal immutable _uniswapV2Router;

    // uniswap v3 router contract
    ISwapRouter internal immutable _uniswapV3Router;

    // sushiSwap router contract
    IUniswapV2Router02 internal immutable _sushiSwapRouter;

    // Carbon controller contract
    ICarbonController internal immutable _carbonController;

    // Balancer Vault
    IVault internal immutable _balancerVault;

    // Dust wallet address
    address internal immutable _dustWallet;

    // rewards defaults
    Rewards internal _rewards;

    // min BNT burn for an arbitrage
    uint256 private _minBurn;

    // upgrade forward-compatibility storage gap
    uint256[MAX_GAP - 3] private __gap;

    /**
     * @dev triggered after a successful arb is executed
     */
    event ArbitrageExecuted(
        address indexed caller,
        uint16[] exchangeIds,
        address[] tokenPath,
        uint256 sourceAmount,
        uint256 burnAmount,
        uint256 rewardAmount
    );

    /**
     * @dev triggered when the rewards settings are updated
     */
    event RewardsUpdated(
        uint32 prevPercentagePPM,
        uint32 newPercentagePPM,
        uint256 prevMaxAmount,
        uint256 newMaxAmount
    );

    /**
     * @dev triggered when the min bnt burn amount is updated
     */
    event MinBurnUpdated(uint256 prevAmount, uint256 newAmount);

    /**
     * @dev a "virtual" constructor that is only used to set immutable state variables
     */
    constructor(
        IERC20 initBnt,
        address initDustWallet,
        Platforms memory platforms
    )
        validAddress(address(initBnt))
        validAddress(address(initDustWallet))
        validAddress(address(platforms.bancorNetworkV2))
        validAddress(address(platforms.bancorNetworkV3))
        validAddress(address(platforms.uniV2Router))
        validAddress(address(platforms.uniV3Router))
        validAddress(address(platforms.sushiswapRouter))
        validAddress(address(platforms.carbonController))
        validAddress(address(platforms.balancerVault))
    {
        _bnt = initBnt;
        _weth = IERC20(platforms.uniV2Router.WETH());
        _dustWallet = initDustWallet;
        _bancorNetworkV2 = platforms.bancorNetworkV2;
        _bancorNetworkV3 = platforms.bancorNetworkV3;
        _uniswapV2Router = platforms.uniV2Router;
        _uniswapV3Router = platforms.uniV3Router;
        _sushiSwapRouter = platforms.sushiswapRouter;
        _carbonController = platforms.carbonController;
        _balancerVault = platforms.balancerVault;
    }

    /**
     * @dev fully initializes the contract and its parents
     */
    function initialize() external initializer {
        __BancorArbitrage_init();
    }

    // solhint-disable func-name-mixedcase

    /**
     * @dev initializes the contract and its parents
     */
    function __BancorArbitrage_init() internal onlyInitializing {
        __ReentrancyGuard_init();
        __Upgradeable_init();

        __BancorArbitrage_init_unchained();
    }

    /**
     * @dev performs contract-specific initialization
     */
    function __BancorArbitrage_init_unchained() internal onlyInitializing {
        _rewards = Rewards({ percentagePPM: 100000, maxAmount: 100 * 1e18 });
    }

    /**
     * @dev authorize the contract to receive the native token
     */
    receive() external payable {}

    /**
     * @inheritdoc Upgradeable
     */
    function version() public pure override(Upgradeable) returns (uint16) {
        return 4;
    }

    /**
     * @dev checks whether the specified number of routes is supported
     */
    modifier validRouteLength(uint256 length) {
        // validate inputs
        _validRouteLength(length);

        _;
    }

    /**
     * @dev validRouteLength logic for gas optimization
     */
    function _validRouteLength(uint256 length) internal pure {
        if (length < MIN_ROUTE_LENGTH || length > MAX_ROUTE_LENGTH) {
            revert InvalidRouteLength();
        }
    }

    /**
     * @dev sets the rewards settings
     *
     * requirements:
     *
     * - the caller must be the admin of the contract
     */
    function setRewards(
        Rewards calldata newRewards
    ) external onlyAdmin validFee(newRewards.percentagePPM) greaterThanZero(newRewards.maxAmount) {
        uint32 prevPercentagePPM = _rewards.percentagePPM;
        uint256 prevMaxAmount = _rewards.maxAmount;

        // return if the rewards are the same
        if (prevPercentagePPM == newRewards.percentagePPM && prevMaxAmount == newRewards.maxAmount) {
            return;
        }

        _rewards = newRewards;

        emit RewardsUpdated({
            prevPercentagePPM: prevPercentagePPM,
            newPercentagePPM: newRewards.percentagePPM,
            prevMaxAmount: prevMaxAmount,
            newMaxAmount: newRewards.maxAmount
        });
    }

    /**
     * @dev set min bnt burn amount
     *
     * requirements:
     *
     * - the caller must be the admin of the contract
     */
    function setMinBurn(uint256 newMinBurn) external onlyAdmin {
        uint256 currentMinBurn = _minBurn;
        if (currentMinBurn == newMinBurn) {
            return;
        }
        _minBurn = newMinBurn;
        emit MinBurnUpdated(currentMinBurn, newMinBurn);
    }

    /**
     * @dev returns the rewards settings
     */
    function rewards() external view returns (Rewards memory) {
        return _rewards;
    }

    /**
     * @dev returns the min bnt burn amount
     */
    function minBurn() external view returns (uint256) {
        return _minBurn;
    }

    /**
     * @dev execute multi-step arbitrage trade between exchanges using a flashloan from Bancor Network V3
     * note: deprecated
     */
    function flashloanAndArb(Route[] calldata routes, Token token, uint256 sourceAmount) external {
        // convert route array to new format
        RouteV2[] memory routesV2 = _convertRouteV1toV2(routes, token, sourceAmount);
        // create flashloan struct
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory sourceAmounts = new uint256[](1);
        tokens[0] = IERC20(address(token));
        sourceAmounts[0] = sourceAmount;
        Flashloan[] memory flashloan = new Flashloan[](1);
        flashloan[0] = Flashloan({
            platformId: PLATFORM_ID_BANCOR_V3,
            sourceTokens: tokens,
            sourceAmounts: sourceAmounts
        });
        // perform arb
        flashloanAndArbV2(flashloan, routesV2);
    }

    /**
     * @dev execute multi-step arbitrage trade between exchanges using one or more flashloans
     */
    function flashloanAndArbV2(
        Flashloan[] memory flashloans,
        RouteV2[] memory routes
    ) public nonReentrant validRouteLength(routes.length) validateFlashloans(flashloans) {
        // abi encode the data to be passed in to the flashloan platform
        bytes memory encodedData = abi.encode(uint256(1), flashloans, routes);
        if (flashloans[0].platformId == PLATFORM_ID_BANCOR_V3) {
            // take a flashloan on Bancor v3, execution continues in `onFlashloan`
            _bancorNetworkV3.flashLoan(
                Token(address(flashloans[0].sourceTokens[0])),
                flashloans[0].sourceAmounts[0],
                IFlashLoanRecipient(address(this)),
                encodedData
            );
        } else if (flashloans[0].platformId == PLATFORM_ID_BALANCER) {
            // take a flashloan on Balancer, execution continues in `receiveFlashLoan`
            _balancerVault.flashLoan(
                BalancerFlashloanRecipient(address(this)),
                flashloans[0].sourceTokens,
                flashloans[0].sourceAmounts,
                encodedData
            );
        }

        // trade leftover tokens for BNT on Bancor Network V3
        for (uint256 i = 0; i < flashloans.length; i = uncheckedInc(i)) {
            IERC20[] memory tokens = flashloans[i].sourceTokens;
            for (uint256 j = 0; j < tokens.length; j = uncheckedInc(j)) {
                Token token = Token(address(tokens[j]));
                // check token is not bnt and is tradeable on bancor v3
                if (!token.isEqual(_bnt) && _bancorNetworkV3.collectionByPool(token) != address(0)) {
                    uint256 leftover = token.balanceOf(address(this));
                    // check we have > 0 balance
                    if (leftover > 0) {
                        _trade(
                            PLATFORM_ID_BANCOR_V3,
                            token,
                            Token(address(_bnt)),
                            leftover,
                            1,
                            block.timestamp,
                            address(0),
                            0,
                            ""
                        );
                    }
                }
            }
        }

        // allocate the rewards
        _allocateRewards(routes, flashloans[0].sourceAmounts[0], msg.sender);
    }

    /**
     * @dev callback function for bancor V3 flashloan
     * @dev performs the arbitrage trades
     */
    function onFlashLoan(
        address caller,
        IERC20 erc20Token,
        uint256 amount,
        uint256 feeAmount,
        bytes memory data
    ) external {
        // validate inputs
        if (msg.sender != address(_bancorNetworkV3) || caller != address(this)) {
            revert InvalidFlashLoanCaller();
        }

        // decode the arb data
        (uint256 currentIndex, Flashloan[] memory flashloans, RouteV2[] memory routes) = abi.decode(
            data,
            (uint256, Flashloan[], RouteV2[])
        );
        // if we're at the final flashloan index, perform the arbitrage
        if (currentIndex == flashloans.length) {
            _arbitrageV2(routes);
        } else {
            // else execute the next flashloan in the sequence
            // update the currentIndex in the encoded data
            incrementIndex(data, currentIndex);
            if (flashloans[currentIndex].platformId == PLATFORM_ID_BANCOR_V3) {
                _bancorNetworkV3.flashLoan(
                    Token(address(flashloans[currentIndex].sourceTokens[0])),
                    flashloans[currentIndex].sourceAmounts[0],
                    IFlashLoanRecipient(address(this)),
                    data
                );
            } else if (flashloans[currentIndex].platformId == PLATFORM_ID_BALANCER) {
                _balancerVault.flashLoan(
                    BalancerFlashloanRecipient(address(this)),
                    flashloans[currentIndex].sourceTokens,
                    flashloans[currentIndex].sourceAmounts,
                    data
                );
            }
        }

        // return the flashloan
        Token(address(erc20Token)).safeTransfer(msg.sender, amount + feeAmount);
    }

    /**
     * @dev callback function for Balancer flashloan
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        if (msg.sender != address(_balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        // decode the arb data
        (uint256 currentIndex, Flashloan[] memory flashloans, RouteV2[] memory routes) = abi.decode(
            userData,
            (uint256, Flashloan[], RouteV2[])
        );
        // if we're at the final flashloan index, perform the arbitrage
        if (currentIndex == flashloans.length) {
            _arbitrageV2(routes);
        } else {
            // else execute the next flashloan in the sequence
            // update the currentIndex in the encoded data
            incrementIndex(userData, currentIndex);
            if (flashloans[currentIndex].platformId == PLATFORM_ID_BANCOR_V3) {
                _bancorNetworkV3.flashLoan(
                    Token(address(flashloans[currentIndex].sourceTokens[0])),
                    flashloans[currentIndex].sourceAmounts[0],
                    IFlashLoanRecipient(address(this)),
                    userData
                );
            } else if (flashloans[currentIndex].platformId == PLATFORM_ID_BALANCER) {
                _balancerVault.flashLoan(
                    BalancerFlashloanRecipient(address(this)),
                    flashloans[currentIndex].sourceTokens,
                    flashloans[currentIndex].sourceAmounts,
                    userData
                );
            }
        }

        // return the flashloans
        for (uint256 i = 0; i < tokens.length; i = uncheckedInc(i)) {
            Token(address(tokens[i])).safeTransfer(msg.sender, amounts[i] + feeAmounts[i]);
        }
    }

    /**
     * @dev execute multi-step arbitrage trade between exchanges using user funds
     * @dev must approve token before executing the function
     */
    function fundAndArb(
        RouteV2[] calldata routes,
        Token token,
        uint256 sourceAmount
    ) external payable nonReentrant validRouteLength(routes.length) greaterThanZero(sourceAmount) {
        // perform validations
        _validateFundAndArbParams(token, routes[routes.length - 1].targetToken, sourceAmount, msg.value);

        // transfer the tokens from user
        token.safeTransferFrom(msg.sender, address(this), sourceAmount);

        // perform the arbitrage
        _arbitrageV2(routes);

        // return the tokens to the user
        token.safeTransfer(msg.sender, sourceAmount);

        // if initial token is not BNT, trade leftover tokens for BNT on Bancor Network V3
        if (!token.isEqual(_bnt)) {
            uint256 leftover = token.balanceOf(address(this));
            _trade(PLATFORM_ID_BANCOR_V3, token, Token(address(_bnt)), leftover, 1, block.timestamp, address(0), 0, "");
        }

        // allocate the rewards
        _allocateRewards(routes, sourceAmount, msg.sender);
    }

    /**
     * @dev perform validations for fundAndArb functions
     */
    function _validateFundAndArbParams(
        Token token,
        Token finalToken,
        uint256 sourceAmount,
        uint256 value
    ) private view {
        // verify that the last token in the process is the arb token
        if (finalToken != token) {
            revert InvalidInitialAndFinalTokens();
        }
        // validate token is tradeable on v3
        if (!token.isEqual(_bnt) && _bancorNetworkV3.collectionByPool(token) == address(0)) {
            revert InvalidSourceToken();
        }
        // validate ETH amount sent with function is correct
        if (token.isNative()) {
            if (value != sourceAmount) {
                revert InvalidETHAmountSent();
            }
        } else {
            if (value > 0) {
                revert InvalidETHAmountSent();
            }
        }
    }

    /**
     * @dev arbitrage logic
     */
    function _arbitrageV2(RouteV2[] memory routes) private {
        // perform the trade routes
        for (uint256 i = 0; i < routes.length; i = uncheckedInc(i)) {
            RouteV2 memory route = routes[i];
            uint256 sourceTokenBalance = route.sourceToken.balanceOf(address(this));
            uint256 sourceAmount;
            if (route.sourceAmount == 0 || route.sourceAmount > sourceTokenBalance) {
                sourceAmount = sourceTokenBalance;
            } else {
                sourceAmount = route.sourceAmount;
            }

            // perform the trade
            _trade(
                route.platformId,
                route.sourceToken,
                route.targetToken,
                sourceAmount,
                route.minTargetAmount,
                route.deadline,
                route.customAddress,
                route.customInt,
                route.customData
            );
        }
    }

    /**
     * @dev handles the trade logic per route
     */
    function _trade(
        uint256 platformId,
        Token sourceToken,
        Token targetToken,
        uint256 sourceAmount,
        uint256 minTargetAmount,
        uint256 deadline,
        address customAddress,
        uint256 customInt,
        bytes memory customData
    ) private {
        if (platformId == PLATFORM_ID_BANCOR_V2) {
            // allow the network to withdraw the source tokens
            _setExchangeAllowance(sourceToken, address(_bancorNetworkV2), sourceAmount);

            // build the conversion path
            address[] memory path = new address[](3);
            path[0] = address(sourceToken);
            path[1] = customAddress; // pool token address
            path[2] = address(targetToken);

            uint256 val = sourceToken.isNative() ? sourceAmount : 0;

            // perform the trade
            _bancorNetworkV2.convertByPath{ value: val }(
                path,
                sourceAmount,
                minTargetAmount,
                address(0x0),
                address(0x0),
                0
            );

            return;
        }

        if (platformId == PLATFORM_ID_BANCOR_V3) {
            // allow the network to withdraw the source tokens
            _setExchangeAllowance(sourceToken, address(_bancorNetworkV3), sourceAmount);

            uint256 val = sourceToken.isNative() ? sourceAmount : 0;

            // perform the trade
            _bancorNetworkV3.tradeBySourceAmountArb{ value: val }(
                sourceToken,
                targetToken,
                sourceAmount,
                minTargetAmount,
                deadline,
                address(0x0)
            );

            return;
        }

        if (platformId == PLATFORM_ID_UNISWAP_V2 || platformId == PLATFORM_ID_SUSHISWAP) {
            IUniswapV2Router02 router = platformId == PLATFORM_ID_UNISWAP_V2 ? _uniswapV2Router : _sushiSwapRouter;

            // allow the router to withdraw the source tokens
            _setExchangeAllowance(sourceToken, address(router), sourceAmount);

            // build the path
            address[] memory path = new address[](2);

            // perform the trade
            if (sourceToken.isNative()) {
                path[0] = address(_weth);
                path[1] = address(targetToken);
                router.swapExactETHForTokens{ value: sourceAmount }(minTargetAmount, path, address(this), deadline);
            } else if (targetToken.isNative()) {
                path[0] = address(sourceToken);
                path[1] = address(_weth);
                router.swapExactTokensForETH(sourceAmount, minTargetAmount, path, address(this), deadline);
            } else {
                path[0] = address(sourceToken);
                path[1] = address(targetToken);
                router.swapExactTokensForTokens(sourceAmount, minTargetAmount, path, address(this), deadline);
            }

            return;
        }

        if (platformId == PLATFORM_ID_UNISWAP_V3) {
            address tokenIn = sourceToken.isNative() ? address(_weth) : address(sourceToken);
            address tokenOut = targetToken.isNative() ? address(_weth) : address(targetToken);

            if (tokenIn == address(_weth)) {
                IWETH(address(_weth)).deposit{ value: sourceAmount }();
            }

            // allow the router to withdraw the source tokens
            _setExchangeAllowance(Token(tokenIn), address(_uniswapV3Router), sourceAmount);

            // build the params
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: uint24(customInt), // fee
                recipient: address(this),
                deadline: deadline,
                amountIn: sourceAmount,
                amountOutMinimum: minTargetAmount,
                sqrtPriceLimitX96: uint160(0)
            });

            // perform the trade
            _uniswapV3Router.exactInputSingle(params);

            if (tokenOut == address(_weth)) {
                IWETH(address(_weth)).withdraw(_weth.balanceOf(address(this)));
            }

            return;
        }

        if (platformId == PLATFORM_ID_CARBON) {
            // Carbon accepts 2^128 - 1 max for minTargetAmount
            if (minTargetAmount > type(uint128).max) {
                revert MinTargetAmountTooHigh();
            }
            // allow the carbon controller to withdraw the source tokens
            _setExchangeAllowance(sourceToken, address(_carbonController), sourceAmount);

            uint256 val = sourceToken.isNative() ? sourceAmount : 0;

            // decode the trade actions passed in as customData
            TradeAction[] memory tradeActions = abi.decode(customData, (TradeAction[]));

            // perform the trade
            _carbonController.tradeBySourceAmount{ value: val }(
                sourceToken,
                targetToken,
                tradeActions,
                deadline,
                uint128(minTargetAmount)
            );

            uint256 remainingSourceTokens = sourceToken.balanceOf(address(this));
            if (remainingSourceTokens > 0) {
                // transfer any remaining source tokens to a dust wallet
                sourceToken.safeTransfer(_dustWallet, remainingSourceTokens);
            }

            return;
        }

        revert InvalidExchangeId();
    }

    /**
     * @dev allocates the rewards to the caller and burns the rest
     */
    function _allocateRewards(RouteV2[] memory routes, uint256 sourceAmount, address caller) internal {
        // get the total amount
        uint256 totalAmount = _bnt.balanceOf(address(this));

        // calculate the rewards to send to the caller
        uint256 rewardAmount = MathEx.mulDivF(totalAmount, _rewards.percentagePPM, PPM_RESOLUTION);

        // limit the rewards by the defined limit
        if (rewardAmount > _rewards.maxAmount) {
            rewardAmount = _rewards.maxAmount;
        }

        // calculate the burn amount
        uint256 burnAmount = totalAmount - rewardAmount;

        // check if min bnt burn amount is hit
        if (burnAmount < _minBurn) {
            revert InsufficientBurn();
        }

        // burn the tokens
        if (burnAmount > 0) {
            _bnt.safeTransfer(address(_bnt), burnAmount);
        }

        // transfer the rewards to the caller
        if (rewardAmount > 0) {
            _bnt.safeTransfer(caller, rewardAmount);
        }

        (uint16[] memory exchangeIds, address[] memory path) = _buildArbPath(routes);
        emit ArbitrageExecuted(caller, exchangeIds, path, sourceAmount, burnAmount, rewardAmount);
    }

    /**
     * @dev build arb path from RouteV2 array
     */
    function _buildArbPath(
        RouteV2[] memory routes
    ) private pure returns (uint16[] memory exchangeIds, address[] memory path) {
        exchangeIds = new uint16[](routes.length);
        path = new address[](routes.length * 2);
        for (uint256 i = 0; i < routes.length; i = uncheckedInc(i)) {
            exchangeIds[i] = routes[i].platformId;
            path[i * 2] = address(routes[i].sourceToken);
            path[uncheckedInc(i * 2)] = address(routes[i].targetToken);
        }
    }

    /**
     * @dev extract tokens and amounts from Flashloan array
     */
    function _extractTokensAndAmounts(
        Flashloan[] memory flashloans
    ) private pure returns (IERC20[] memory, uint256[] memory) {
        uint256 totalLength = 0;
        for (uint256 i = 0; i < flashloans.length; i = uncheckedInc(i)) {
            totalLength += flashloans[i].sourceTokens.length;
        }

        IERC20[] memory tokens = new IERC20[](totalLength);
        uint256[] memory amounts = new uint256[](totalLength);

        uint256 index = 0;
        for (uint256 i = 0; i < flashloans.length; i = uncheckedInc(i)) {
            for (uint256 j = 0; j < flashloans[i].sourceTokens.length; j = uncheckedInc(j)) {
                tokens[index] = flashloans[i].sourceTokens[j];
                amounts[index] = flashloans[i].sourceAmounts[j];
                index = uncheckedInc(index);
            }
        }

        return (tokens, amounts);
    }

    /**
     * @dev convert a V1 Route array to V2
     */
    function _convertRouteV1toV2(
        Route[] calldata routes,
        Token sourceToken,
        uint256 sourceAmount
    ) private pure returns (RouteV2[] memory routesV2) {
        routesV2 = new RouteV2[](routes.length);
        if (routes.length == 0) {
            return routesV2;
        }
        routesV2[0].sourceToken = sourceToken;
        routesV2[0].sourceAmount = sourceAmount;
        // set each route details
        for (uint256 i = 0; i < routes.length; i = uncheckedInc(i)) {
            Route memory route = routes[i];
            RouteV2 memory routeV2 = routesV2[i];
            // copy mutual parts
            routeV2.platformId = route.platformId;
            routeV2.targetToken = route.targetToken;
            routeV2.minTargetAmount = route.minTargetAmount;
            routeV2.deadline = route.deadline;
            routeV2.customAddress = route.customAddress;
            routeV2.customInt = route.customInt;
            routeV2.customData = route.customData;
            // set source token and amount
            if (i != 0) {
                routeV2.sourceToken = routes[i - 1].targetToken;
                routeV2.sourceAmount = 0;
            }
        }
    }

    /**
     * @dev set exchange allowance to the max amount if it's less than the input amount
     */
    function _setExchangeAllowance(Token token, address exchange, uint256 inputAmount) private {
        if (token.isNative()) {
            return;
        }
        uint256 allowance = token.toIERC20().allowance(address(this), exchange);
        if (allowance < inputAmount) {
            // increase allowance to the max amount if allowance < inputAmount
            token.safeIncreaseAllowance(exchange, type(uint256).max - allowance);
        }
    }

    /**
     * @dev increment the abi-encoded flashloan and route data's index
     */
    function incrementIndex(bytes memory data, uint index) private pure {
        /* solhint-disable no-inline-assembly */
        assembly {
            mstore(add(data, 32), add(index, 1))
        }
        /* solhint-enable no-inline-assembly */
    }

    function uncheckedInc(uint256 i) private pure returns (uint256 j) {
        unchecked {
            j = i + 1;
        }
    }

    /**
     * @dev check if there is a mismatch between sourceTokens and sourceAmounts length for each flashloan
     *      check if any of the flashloan amounts are zero in value
     */
    modifier validateFlashloans(Flashloan[] memory flashloans) {
        for (uint256 i = 0; i < flashloans.length; i = uncheckedInc(i)) {
            Flashloan memory flashloan = flashloans[i];
            if (flashloan.sourceTokens.length != flashloan.sourceAmounts.length) {
                revert InvalidFlashloanStructure();
            }
            uint256[] memory sourceAmounts = flashloan.sourceAmounts;
            for (uint256 j = 0; j < sourceAmounts.length; j = uncheckedInc(j)) {
                if (sourceAmounts[j] == 0) {
                    revert ZeroValue();
                }
            }
        }
        _;
    }
}
