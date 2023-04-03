// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IWETH } from "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

import { Token } from "../token/Token.sol";
import { TokenLibrary } from "../token/TokenLibrary.sol";
import { IVersioned } from "../utility/interfaces/IVersioned.sol";
import { Upgradeable } from "../utility/Upgradeable.sol";
import { Utils } from "../utility/Utils.sol";
import { IBancorNetwork, IFlashLoanRecipient } from "../exchanges/interfaces/IBancorNetwork.sol";
import { IBancorNetworkV2 } from "../exchanges/interfaces/IBancorNetworkV2.sol";
import { ICarbonController, TradeAction } from "../exchanges/interfaces/ICarbonController.sol";
import { PPM_RESOLUTION } from "../utility/Constants.sol";
import { MathEx } from "../utility/MathEx.sol";

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
    error InvalidFlashLoanCaller();
    error MinTargetAmountTooHigh();
    error InvalidSourceToken();

    // trade args
    struct Route {
        uint16 exchangeId;
        Token targetToken;
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

    // exchanges
    struct Exchanges {
        IBancorNetworkV2 bancorNetworkV2;
        IBancorNetwork bancorNetworkV3;
        IUniswapV2Router02 uniV2Router;
        ISwapRouter uniV3Router;
        IUniswapV2Router02 sushiswapRouter;
        ICarbonController carbonController;
    }

    // exchange ids
    uint16 public constant EXCHANGE_ID_BANCOR_V2 = 1;
    uint16 public constant EXCHANGE_ID_BANCOR_V3 = 2;
    uint16 public constant EXCHANGE_ID_UNISWAP_V2 = 3;
    uint16 public constant EXCHANGE_ID_UNISWAP_V3 = 4;
    uint16 public constant EXCHANGE_ID_SUSHISWAP = 5;
    uint16 public constant EXCHANGE_ID_CARBON = 6;

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

    // Dust wallet address
    address internal immutable _dustWallet;

    // rewards defaults
    Rewards internal _rewards;

    // upgrade forward-compatibility storage gap
    uint256[MAX_GAP - 2] private __gap;

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
     * @dev a "virtual" constructor that is only used to set immutable state variables
     */
    constructor(
        IERC20 initBnt,
        address initDustWallet,
        Exchanges memory exchanges
    )
        validAddress(address(initBnt))
        validAddress(address(initDustWallet))
        validAddress(address(exchanges.bancorNetworkV2))
        validAddress(address(exchanges.bancorNetworkV3))
        validAddress(address(exchanges.uniV2Router))
        validAddress(address(exchanges.uniV3Router))
        validAddress(address(exchanges.sushiswapRouter))
        validAddress(address(exchanges.carbonController))
    {
        _bnt = initBnt;
        _weth = IERC20(exchanges.uniV2Router.WETH());
        _dustWallet = initDustWallet;
        _bancorNetworkV2 = exchanges.bancorNetworkV2;
        _bancorNetworkV3 = exchanges.bancorNetworkV3;
        _uniswapV2Router = exchanges.uniV2Router;
        _uniswapV3Router = exchanges.uniV3Router;
        _sushiSwapRouter = exchanges.sushiswapRouter;
        _carbonController = exchanges.carbonController;
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
        return 3;
    }

    /**
     * @dev checks whether the specified number of routes is supported
     */
    modifier validRouteLength(Route[] calldata routes) {
        // validate inputs
        _validRouteLength(routes);

        _;
    }

    /**
     * @dev validRouteLength logic for gas optimization
     */
    function _validRouteLength(Route[] calldata routes) internal pure {
        if (routes.length == 0 || routes.length > MAX_ROUTE_LENGTH) {
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
     * @dev returns the rewards settings
     */
    function rewards() external view returns (Rewards memory) {
        return _rewards;
    }

    /**
     * @dev execute multi-step arbitrage trade between exchanges using a flashloan from Bancor Network V3
     */
    function flashloanAndArb(
        Route[] calldata routes,
        Token token,
        uint256 sourceAmount
    ) external nonReentrant validRouteLength(routes) greaterThanZero(sourceAmount) {
        // verify that the last token in the process is the flashloan token
        if (routes[routes.length - 1].targetToken != token) {
            revert InvalidInitialAndFinalTokens();
        }

        // take a flashloan for the source amount on Bancor v3 and perform the trades
        _bancorNetworkV3.flashLoan(
            token,
            sourceAmount,
            IFlashLoanRecipient(address(this)),
            abi.encode(routes, sourceAmount)
        );

        // if flashloan token is not BNT, trade leftover tokens for BNT on Bancor Network V3
        if (!token.isEqual(_bnt)) {
            uint256 leftover = token.balanceOf(address(this));
            _trade(EXCHANGE_ID_BANCOR_V3, token, Token(address(_bnt)), leftover, 1, block.timestamp, address(0), 0, "");
        }

        // allocate the rewards
        _allocateRewards(routes, token, sourceAmount, msg.sender);
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

        // perform the arbitrage
        (Route[] memory routes, uint256 sourceAmount) = abi.decode(data, (Route[], uint256));
        _arbitrage(routes, Token(address(erc20Token)), sourceAmount);

        // return the flashloan
        Token(address(erc20Token)).safeTransfer(msg.sender, amount + feeAmount);
    }

    /**
     * @dev execute multi-step arbitrage trade between exchanges using user funds
     * @dev must approve token before executing the function
     */
    function fundAndArb(
        Route[] calldata routes,
        Token token,
        uint sourceAmount
    ) external payable nonReentrant validRouteLength(routes) greaterThanZero(sourceAmount) {
        // verify that the last token in the process is the arb token
        if (routes[routes.length - 1].targetToken != token) {
            revert InvalidInitialAndFinalTokens();
        }
        // validate token is tradeable on v3
        if (!token.isEqual(_bnt) && _bancorNetworkV3.collectionByPool(token) == address(0)) {
            revert InvalidSourceToken();
        }

        // transfer the tokens from user
        token.safeTransferFrom(msg.sender, address(this), sourceAmount);

        // perform the arbitrage
        _arbitrage(routes, token, sourceAmount);

        // return the tokens to the user
        token.safeTransfer(msg.sender, sourceAmount);

        // if flashloan token is not BNT, trade leftover tokens for BNT on Bancor Network V3
        if (!token.isEqual(_bnt)) {
            uint leftover = token.balanceOf(address(this));
            _trade(EXCHANGE_ID_BANCOR_V3, token, Token(address(_bnt)), leftover, 1, block.timestamp, address(0), 0, "");
        }

        // allocate the rewards
        _allocateRewards(routes, token, sourceAmount, msg.sender);
    }

    /**
     * @dev arbitrage logic
     */
    function _arbitrage(Route[] memory routes, Token sourceToken, uint256 sourceAmount) private {
        // perform the trade routes
        for (uint256 i = 0; i < routes.length; i++) {
            // save the current balance
            uint256 previousBalance = routes[i].targetToken.balanceOf(address(this));

            // perform the trade
            _trade(
                routes[i].exchangeId,
                sourceToken,
                routes[i].targetToken,
                sourceAmount,
                routes[i].minTargetAmount,
                routes[i].deadline,
                routes[i].customAddress,
                routes[i].customInt,
                routes[i].customData
            );

            // the current iteration target token is the source token in the next iteration
            sourceToken = routes[i].targetToken;

            // the resulting trade amount is the source amount in the next iteration
            sourceAmount = routes[i].targetToken.balanceOf(address(this)) - previousBalance;
        }
    }

    /**
     * @dev handles the trade logic per route
     */
    function _trade(
        uint256 exchangeId,
        Token sourceToken,
        Token targetToken,
        uint256 sourceAmount,
        uint256 minTargetAmount,
        uint256 deadline,
        address customAddress,
        uint256 customInt,
        bytes memory customData
    ) private {
        if (exchangeId == EXCHANGE_ID_BANCOR_V2) {
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

        if (exchangeId == EXCHANGE_ID_BANCOR_V3) {
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

        if (exchangeId == EXCHANGE_ID_UNISWAP_V2 || exchangeId == EXCHANGE_ID_SUSHISWAP) {
            IUniswapV2Router02 router = exchangeId == EXCHANGE_ID_UNISWAP_V2 ? _uniswapV2Router : _sushiSwapRouter;

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

        if (exchangeId == EXCHANGE_ID_UNISWAP_V3) {
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

        if (exchangeId == EXCHANGE_ID_CARBON) {
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
    function _allocateRewards(Route[] calldata routes, Token token, uint256 sourceAmount, address caller) internal {
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

        // burn the tokens
        if (burnAmount > 0) {
            _bnt.safeTransfer(address(_bnt), burnAmount);
        }

        // transfer the rewards to the caller
        if (rewardAmount > 0) {
            _bnt.safeTransfer(caller, rewardAmount);
        }

        // build the list of exchange ids
        uint16[] memory exchangeIds = new uint16[](routes.length);
        for (uint256 i = 0; i < routes.length; i++) {
            exchangeIds[i] = routes[i].exchangeId;
        }

        // build the token path
        address[] memory path = new address[](routes.length + 1);
        path[0] = address(token);
        for (uint256 i = 0; i < routes.length; i++) {
            path[i + 1] = address(routes[i].targetToken);
        }

        emit ArbitrageExecuted(caller, exchangeIds, path, sourceAmount, burnAmount, rewardAmount);
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
}
