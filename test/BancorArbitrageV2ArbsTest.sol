// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import { Token } from "../contracts/token/Token.sol";
import { TokenLibrary } from "../contracts/token/TokenLibrary.sol";
import { AccessDenied, ZeroValue, InvalidAddress } from "../contracts/utility/Utils.sol";
import { TransparentUpgradeableProxyImmutable } from "../contracts/utility/TransparentUpgradeableProxyImmutable.sol";
import { Utilities } from "./Utilities.t.sol";
import { BancorArbitrage } from "../contracts/arbitrage/BancorArbitrage.sol";
import { MockExchanges } from "../contracts/helpers/MockExchanges.sol";
import { TestBNT } from "../contracts/helpers/TestBNT.sol";
import { TestWETH } from "../contracts/helpers/TestWETH.sol";
import { IBancorNetworkV2 } from "../contracts/exchanges/interfaces/IBancorNetworkV2.sol";
import { IBancorNetwork, IFlashLoanRecipient } from "../contracts/exchanges/interfaces/IBancorNetwork.sol";
import { ICarbonController, TradeAction } from "../contracts/exchanges/interfaces/ICarbonController.sol";
import { PPM_RESOLUTION } from "../contracts/utility/Constants.sol";
import { TestERC20Token } from "../contracts/helpers/TestERC20Token.sol";

/* solhint-disable max-states-count */
contract BancorArbitrageV2ArbsTest is Test {
    using TokenLibrary for Token;

    Utilities private utils;
    BancorArbitrage private bancorArbitrage;
    TestBNT private bnt;
    TestWETH private weth;
    TestERC20Token private arbToken1;
    TestERC20Token private arbToken2;
    TestERC20Token private nonWhitelistedToken;
    MockExchanges private exchanges;
    ProxyAdmin private proxyAdmin;

    BancorArbitrage.Exchanges private exchangeStruct;

    address[] private whitelistedTokens;

    address payable[] private users;
    address payable private admin;
    address payable private user1;
    address payable private burnerWallet;

    uint private constant BNT_VIRTUAL_BALANCE = 1;
    uint private constant BASE_TOKEN_VIRTUAL_BALANCE = 2;
    uint private constant MAX_SOURCE_AMOUNT = 100_000_000 ether;
    uint private constant DEADLINE = type(uint256).max;
    uint private constant AMOUNT = 1000 ether;
    uint private constant MIN_LIQUIDITY_FOR_TRADING = 1000 ether;
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint private constant FIRST_EXCHANGE_ID = 1;
    uint private constant LAST_EXCHANGE_ID = 6;

    enum ExchangeId {
        INVALID,
        BANCOR_V2,
        BANCOR_V3,
        UNISWAP_V2,
        UNISWAP_V3,
        SUSHISWAP,
        CARBON
    }

    BancorArbitrage.Rewards private arbitrageRewardsDefaults =
        BancorArbitrage.Rewards({ percentagePPM: 30000, maxAmount: 100 ether });

    BancorArbitrage.Rewards private arbitrageRewardsUpdated =
        BancorArbitrage.Rewards({ percentagePPM: 40000, maxAmount: 200 ether });

    // Events
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
    event MinBurnUpdated(
        uint256 prevAmount,
        uint256 newAmount
    );

    /**
     * @dev triggered when a flash-loan is completed
     */
    event FlashLoanCompleted(Token indexed token, address indexed borrower, uint256 amount, uint256 feeAmount);

    /**
     * @dev emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev function to set up state before tests
    function setUp() public virtual {
        utils = new Utilities();
        // create 4 users
        users = utils.createUsers(4);
        admin = users[0];
        user1 = users[1];
        burnerWallet = users[3];

        // deploy contracts from admin
        vm.startPrank(admin);

        // deploy proxy admin
        proxyAdmin = new ProxyAdmin();
        // deploy BNT
        bnt = new TestBNT("Bancor Network Token", "BNT", 1_000_000_000 ether);
        // deploy WETH
        weth = new TestWETH();
        // deploy MockExchanges
        exchanges = new MockExchanges(IERC20(weth), address(bnt), 300 ether, true);
        // init exchanges struct
        exchangeStruct = getExchangeStruct(address(exchanges));
        // Deploy arbitrage contract
        bancorArbitrage = new BancorArbitrage(bnt, burnerWallet, exchangeStruct);

        bytes memory selector = abi.encodeWithSelector(bancorArbitrage.initialize.selector);

        // deploy arb proxy
        address arbProxy = address(
            new TransparentUpgradeableProxyImmutable(address(bancorArbitrage), payable(address(proxyAdmin)), selector)
        );
        bancorArbitrage = BancorArbitrage(payable(arbProxy));

        // deploy test tokens
        arbToken1 = new TestERC20Token("TKN1", "TKN1", 1_000_000_000 ether);
        arbToken2 = new TestERC20Token("TKN2", "TKN2", 1_000_000_000 ether);
        nonWhitelistedToken = new TestERC20Token("TKN", "TKN", 1_000_000_000 ether);

        // send some tokens to exchange
        nonWhitelistedToken.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        arbToken1.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        arbToken2.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        bnt.transfer(address(exchanges), MAX_SOURCE_AMOUNT * 5);
        // send eth to exchange
        vm.deal(address(exchanges), MAX_SOURCE_AMOUNT);
        // send weth to exchange
        vm.deal(admin, MAX_SOURCE_AMOUNT * 2);
        weth.deposit{ value: MAX_SOURCE_AMOUNT * 2 }();
        weth.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        // send tokens to user
        nonWhitelistedToken.transfer(user1, MAX_SOURCE_AMOUNT * 2);
        arbToken1.transfer(user1, MAX_SOURCE_AMOUNT * 2);
        arbToken2.transfer(user1, MAX_SOURCE_AMOUNT * 2);
        bnt.transfer(user1, MAX_SOURCE_AMOUNT * 5);

        // whitelist tokens in exchanges mock
        exchanges.addToWhitelist(address(bnt));
        exchanges.addToWhitelist(address(arbToken1));
        exchanges.addToWhitelist(address(arbToken2));
        exchanges.addToWhitelist(NATIVE_TOKEN_ADDRESS);
        // set pool collections for v3
        exchanges.setCollectionByPool(Token(address(bnt)));
        exchanges.setCollectionByPool(Token(address(arbToken1)));
        exchanges.setCollectionByPool(Token(address(arbToken2)));
        exchanges.setCollectionByPool(Token(NATIVE_TOKEN_ADDRESS));

        vm.stopPrank();
    }

    /// --- Distribution and burn tests --- ///

    /**
     * @dev test reward distribution and burn on arbitrage execution
     * @dev test with different flashloan tokens
     */
    function testShouldCorrectlyDistributeRewardsAndBurnTokens(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes;
        address[4] memory tokens = [address(arbToken1), address(arbToken2), NATIVE_TOKEN_ADDRESS, address(bnt)];
        // try different flashloan tokens
        for (uint i = 0; i < 4; ++i) {
            // first and second target tokens must be different from each other and the flashloan token
            routes = getRoutesCustomTokens(uint16(ExchangeId.BANCOR_V2), tokens[(i + 1) % 4], tokens[(i + 2) % 4], tokens[i], AMOUNT, 500);

            // each hop through the route from MockExchanges adds 300e18 tokens to the output
            // so 3 hops = 3 * 300e18 = 900 BNT tokens more than start
            // if we take a flashloan in a token other than BNT, we make one more swap to BNT, making the hops 4 in total
            // so with 0 flashloan fees, when we repay the flashloan, we have 900 or 1200 BNT tokens as totalRewards

            uint hopCount = tokens[i] == address(bnt) ? 3 : 4;
            uint totalRewards = 300e18 * hopCount;

            vm.prank(admin);
            bancorArbitrage.setRewards(arbitrageRewardsUpdated);

            BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();

            uint expectedUserReward = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;
            uint expectedBntBurn = totalRewards - expectedUserReward;

            uint16[] memory exchangeIds = new uint16[](3);
            address[] memory tokenPath = new address[](4);

            exchangeIds[0] = uint16(ExchangeId.BANCOR_V2);
            exchangeIds[1] = uint16(ExchangeId.BANCOR_V2);
            exchangeIds[2] = uint16(ExchangeId.BANCOR_V2);

            tokenPath[0] = tokens[i];
            tokenPath[1] = tokens[(i + 1) % 4];
            tokenPath[2] = tokens[(i + 2) % 4];
            tokenPath[3] = tokens[i];

            vm.startPrank(user1);
            // approve token if user-funded arb
            if (userFunded) {
                Token(tokens[i]).safeApprove(address(bancorArbitrage), AMOUNT);
            }

            vm.expectEmit(true, true, true, true);
            emit ArbitrageExecuted(user1, exchangeIds, tokenPath, AMOUNT, expectedBntBurn, expectedUserReward);
            vm.stopPrank();
            executeArbitrageNoApproval(routes, Token(tokens[i]), AMOUNT, userFunded);
        }
    }

    /**
     * @dev test reward distribution if the rewards exceed the max set rewards
     * @dev test with different flashloan tokens
     */
    function testShouldCorrectlyDistributeRewardsToCallerIfExceedingMaxRewards(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes;
        address[4] memory tokens = [address(arbToken1), address(arbToken2), NATIVE_TOKEN_ADDRESS, address(bnt)];
        // try different flashloan tokens
        for (uint i = 0; i < 4; ++i) {
            // first and second target tokens must be different from each other and the flashloan token
            routes = getRoutesCustomTokens(uint16(ExchangeId.BANCOR_V2), tokens[(i + 1) % 4], tokens[(i + 2) % 4], tokens[i], AMOUNT, 500);

            // each hop through the route from MockExchanges adds 300e18 tokens to the output
            // so 3 hops = 3 * 300e18 = 900 BNT tokens more than start
            // if we take a flashloan in a token other than BNT, we make one more swap to BNT, making the hops 4 in total
            // so with 0 flashloan fees, when we repay the flashloan, we have 900 or 1200 BNT tokens as totalRewards

            uint hopCount = tokens[i] == address(bnt) ? 3 : 4;
            uint totalRewards = 300e18 * hopCount;

            // set rewards maxAmount to 100
            vm.prank(admin);
            bancorArbitrage.setRewards(BancorArbitrage.Rewards({ percentagePPM: 40000, maxAmount: 100 }));

            BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();

            // calculate expected user rewards based on total rewards and percentagePPM
            uint expectedUserReward = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;

            // check we have exceeded the max reward amount
            assertGt(expectedUserReward, rewards.maxAmount);

            // update the expected user reward
            expectedUserReward = rewards.maxAmount;

            uint expectedBntBurn = totalRewards - expectedUserReward;

            uint16[] memory exchangeIds = new uint16[](3);
            address[] memory tokenPath = new address[](4);

            exchangeIds[0] = uint16(ExchangeId.BANCOR_V2);
            exchangeIds[1] = uint16(ExchangeId.BANCOR_V2);
            exchangeIds[2] = uint16(ExchangeId.BANCOR_V2);

            tokenPath[0] = tokens[i];
            tokenPath[1] = tokens[(i + 1) % 4];
            tokenPath[2] = tokens[(i + 2) % 4];
            tokenPath[3] = tokens[i];

            vm.startPrank(user1);
            // approve token if user-funded arb
            if (userFunded) {
                Token(tokens[i]).safeApprove(address(bancorArbitrage), AMOUNT);
            }

            vm.expectEmit(true, true, true, true);
            emit ArbitrageExecuted(user1, exchangeIds, tokenPath, AMOUNT, expectedBntBurn, expectedUserReward);
            vm.stopPrank();
            executeArbitrageNoApproval(routes, Token(tokens[i]), AMOUNT, userFunded);
        }
    }

    /// --- Flashloan tests --- ///

    /**
     * @dev test that onFlashloan cannot be called directly
     */
    function testShouldntBeAbleToCallOnFlashloanDirectly() public {
        vm.expectRevert(BancorArbitrage.InvalidFlashLoanCaller.selector);
        bancorArbitrage.onFlashLoan(address(bancorArbitrage), IERC20(address(bnt)), 1, 0, "0x");
    }

    /**
     * @dev test correct obtaining and repayment of flashloan
     */
    function testShouldCorrectlyObtainAndRepayFlashloan() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        vm.expectEmit(true, true, true, true);
        emit FlashLoanCompleted(Token(address(bnt)), address(bancorArbitrage), AMOUNT, 0);
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test should revert if flashloan cannot be obtained
     */
    function testShouldRevertIfFlashloanCannotBeObtained() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        vm.expectRevert();
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), type(uint256).max);
    }

    /// --- Trade tests --- ///

    /**
     * @dev test that trade attempt if deadline is > block.timestamp reverts
     */
    function testShouldRevertIfDeadlineIsReached() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        // move block.timestamp forward by 1000 sec
        skip(1000);
        // set deadline to 1
        routes[0].deadline = 1;
        routes[1].deadline = 1;
        routes[2].deadline = 1;
        vm.expectRevert();
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test that trade attempt reverts if exchange id is not supported
     */
    function testShouldRevertIfExchangeIdIsNotSupported(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        routes[0].exchangeId = 0;
        vm.startPrank(user1);
        Token(address(bnt)).safeApprove(address(bancorArbitrage), AMOUNT);
        vm.expectRevert(BancorArbitrage.InvalidExchangeId.selector);
        vm.stopPrank();
        executeArbitrageNoApproval(routes, Token(address(bnt)), AMOUNT, userFunded);
    }

    /**
     * @dev test that trade attempt with invalid route length
     */
    function testShouldRevertIfRouteLengthIsInvalid(bool userFunded) public {
        // attempt to route through 11 exchanges
        BancorArbitrage.RouteV2[] memory longRoute = new BancorArbitrage.RouteV2[](11);

        vm.expectRevert(BancorArbitrage.InvalidRouteLength.selector);
        executeArbitrageNoApproval(longRoute, Token(address(bnt)), AMOUNT, userFunded);
        // attempt to route through 0 exchanges
        BancorArbitrage.RouteV2[] memory emptyRoute = new BancorArbitrage.RouteV2[](0);
        vm.expectRevert(BancorArbitrage.InvalidRouteLength.selector);
        executeArbitrageNoApproval(emptyRoute, Token(address(bnt)), AMOUNT, userFunded);
    }

    /**
     * @dev test attempting to trade with more than exchange's balance reverts
     */
    function testShouldRevertIfExchangeDoesntHaveEnoughBalanceForFlashloan() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), MAX_SOURCE_AMOUNT * 2);
    }

    /**
     * @dev test reverts if min target amount is greater than expected
     * @dev test both user-funded and flashloan arbs
     */
    function testShouldRevertIfMinTargetAmountIsGreaterThanExpected(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        routes[0].minTargetAmount = type(uint256).max;
        vm.startPrank(user1);
        Token(address(bnt)).safeApprove(address(bancorArbitrage), AMOUNT);
        vm.expectRevert("InsufficientTargetAmount");
        vm.stopPrank();
        executeArbitrageNoApproval(routes, Token(address(bnt)), AMOUNT, userFunded);
    }

    /**
     * @dev test reverts if the output token of the arb isn't the source token
     * @dev test user-funded and flashloan arbs
     */
    function testShouldRevertIfOutputTokenIsntTheArbToken(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        routes[2].targetToken = Token(address(arbToken2));
        routes[2].customAddress = address(arbToken2);
        address[3] memory tokens = [address(bnt), address(arbToken1), NATIVE_TOKEN_ADDRESS];
        for (uint i = 0; i < 3; ++i) {
            Token(tokens[i]).safeApprove(address(bancorArbitrage), AMOUNT);
            vm.expectRevert(BancorArbitrage.InvalidInitialAndFinalTokens.selector);
            executeArbitrageNoApproval(routes, Token(address(bnt)), AMOUNT, userFunded);
        }
    }

    /**
     * @dev test reverts if the source token isn't whitelisted
     * @dev test flashloan arbs
     */
    function testShouldRevertIfFlashloanTokenIsntWhitelisted() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        // set last token to be the non-whitelisted token
        routes[2].targetToken = Token(address(nonWhitelistedToken));
        routes[2].customAddress = address(nonWhitelistedToken);
        vm.expectRevert(MockExchanges.NotWhitelisted.selector);
        // make arb with the non-whitelisted token
        executeArbitrageNoApproval(routes, Token(address(nonWhitelistedToken)), AMOUNT, false);
    }

    /**
     * @dev test reverts if the source token isn't tradeable on bancor network v3
     * @dev test user-funded arb
     */
    function testShouldRevertIfUserFundedTokenIsntTradeable() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        // set last token to be the non-whitelisted token
        routes[2].targetToken = Token(address(nonWhitelistedToken));
        routes[2].customAddress = address(nonWhitelistedToken);
        vm.expectRevert(BancorArbitrage.InvalidSourceToken.selector);
        // make arb with the non-whitelisted token
        executeArbitrageNoApproval(routes, Token(address(nonWhitelistedToken)), AMOUNT, true);
    }

    /**
     * @dev test reverts if the path is invalid
     * @dev the test uses same input and output token for the second swap
     */
    function testShouldRevertIfThePathIsInvalid() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        routes[1].exchangeId = uint16(ExchangeId.BANCOR_V2);
        routes[1].targetToken = Token(address(arbToken1));
        routes[1].customAddress = address(arbToken1);
        vm.expectRevert("Invalid swap");
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test trade approvals for erc-20 tokens for exchanges
     * @dev should approve max amount for trading on each first swap for token and exchange
     */
    function testShouldApproveERC20TokensForEachExchange(uint16 exchangeId, bool userFunded) public {
        // bound to valid exchange ids
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, LAST_EXCHANGE_ID));
        address[] memory tokensToTrade = new address[](3);
        tokensToTrade[0] = address(arbToken1);
        tokensToTrade[1] = address(arbToken2);
        tokensToTrade[2] = NATIVE_TOKEN_ADDRESS;
        uint approveAmount = type(uint256).max;

        // test with all token combinations
        for (uint i = 0; i < 3; ++i) {
            for (uint j = 0; j < 3; ++j) {
                if (i == j) {
                    continue;
                }
                BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
                    exchangeId,
                    tokensToTrade[i],
                    tokensToTrade[j],
                    address(bnt),
                    AMOUNT,
                    500
                );
                uint allowance = arbToken1.allowance(address(bancorArbitrage), address(exchanges));
                if (allowance == 0) {
                    // expect arbToken1 to emit the approval event
                    vm.expectEmit(true, true, true, true, address(arbToken1));
                    emit Approval(address(bancorArbitrage), address(exchanges), approveAmount);
                }
                executeArbitrage(routes, Token(address(bnt)), AMOUNT, userFunded);
            }
        }
    }

    /// --- Arbitrage tests --- ///

    /**
     * @dev test arbitrage executed event gets emitted
     */
    function testShouldEmitArbitrageExecutedOnSuccessfulFlashloanArb() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        uint16[] memory exchangeIds = new uint16[](0);
        address[] memory tradePath = new address[](0);
        vm.expectEmit(false, false, false, false);
        emit ArbitrageExecuted(admin, exchangeIds, tradePath, AMOUNT, 0, 0);
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test arbitrage executed event gets emitted
     */
    function testShouldEmitArbitrageExecutedOnSuccessfulUserFundedArb() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        uint16[] memory exchangeIds = new uint16[](0);
        address[] memory tradePath = new address[](0);
        vm.startPrank(admin);
        bnt.approve(address(bancorArbitrage), AMOUNT);
        vm.expectEmit(false, false, false, false);
        emit ArbitrageExecuted(admin, exchangeIds, tradePath, AMOUNT, 0, 0);
        bancorArbitrage.fundAndArbV2(routes, Token(address(bnt)), AMOUNT);
        vm.stopPrank();
    }

    /**
     * @dev test that any address can execute arbs
     */
    function testAnyoneCanExecuteArbs(address user) public {
        // assume user is not proxy admin or 0x0 address
        vm.assume(user != address(proxyAdmin) && user != address(0));
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        // impersonate user
        vm.prank(user);
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev fuzz test arbitrage execution
     * @dev go through all exchanges and use different amounts
     * @dev test both user-funded and flashloan arbs
     */
    function testArbitrage(uint16 exchangeId, uint arbAmount, uint fee, bool userFunded) public {
        // limit arbAmount to AMOUNT
        vm.assume(arbAmount > 0 && arbAmount < AMOUNT);
        // test exchange ids 1 - 5 (w/o Carbon)
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, 5));
        address[] memory tokensToTrade = new address[](3);
        tokensToTrade[0] = address(arbToken1);
        tokensToTrade[1] = address(arbToken2);
        tokensToTrade[2] = NATIVE_TOKEN_ADDRESS;

        // test with all token combinations
        for (uint i = 0; i < 3; ++i) {
            for (uint j = 0; j < 3; ++j) {
                if (i == j) {
                    continue;
                }
                BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
                    exchangeId,
                    tokensToTrade[i],
                    tokensToTrade[j],
                    address(bnt),
                    arbAmount,
                    fee
                );
                executeArbitrage(routes, Token(address(bnt)), arbAmount, userFunded);
            }
        }
    }

    /**
     * @dev test arbitrages with different route length
     * @dev fuzz test 2 - 10 routes on any exchange with any amount
     * @dev test both user-funded and flashloan arbs
     */
    function testArbitrageWithDifferentRoutes(
        uint routeLength,
        uint16 exchangeId,
        uint arbAmount,
        uint fee,
        bool userFunded
    ) public {
        // bound route len from 2 to 10
        routeLength = bound(routeLength, 2, 10);
        // bound exchange id to valid exchange ids
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, LAST_EXCHANGE_ID));
        // bound arb amount from 1 to AMOUNT
        arbAmount = bound(arbAmount, 1, AMOUNT);
        // get routes
        BancorArbitrage.RouteV2[] memory routes = getRoutesCustomLength(routeLength, exchangeId, fee, arbAmount);
        // trade
        executeArbitrage(routes, Token(address(bnt)), arbAmount, userFunded);
    }

    /**
     * @dev fuzz test arbs on carbon
     * @dev use different arb amounts and 1 to 11 trade actions for the carbon arb
     * @dev test both user-funded and flashloan arbs
     */
    function testArbitrageOnCarbon(uint arbAmount, uint tradeActionCount, bool userFunded) public {
        // bound arb amount from 1 to AMOUNT
        arbAmount = bound(arbAmount, 1, AMOUNT);
        BancorArbitrage.RouteV2[] memory routes = getRoutesCarbon(
            address(arbToken1),
            address(arbToken2),
            arbAmount,
            tradeActionCount
        );
        executeArbitrage(routes, Token(address(bnt)), arbAmount, userFunded);
    }

    /**
     * @dev test transferring leftover source tokens from the carbon trade to the burner wallet
     * @dev test both user-funded and flashloan arbs
     * @param arbAmount arb amount to test with
     * @param leftoverAmount amount of tokens left over after the carbon trade
     */
    function testShouldTransferLeftoverSourceTokensFromCarbonTrade(
        uint arbAmount,
        uint leftoverAmount,
        bool userFunded
    ) public {
        // bound arb amount from 1 to AMOUNT
        arbAmount = bound(arbAmount, 1, AMOUNT);
        // bound leftover amount from 1 to 300 units
        leftoverAmount = bound(leftoverAmount, 1, 300 ether);
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        routes[1].exchangeId = uint16(ExchangeId.CARBON);
        uint sourceTokenAmountForCarbonTrade = arbAmount + 300 ether;
        // encode less tokens for the trade than the source token balance at this point in the arb
        routes[1].customData = getCarbonData(sourceTokenAmountForCarbonTrade - leftoverAmount);

        // get source token balance in the burner wallet before the trade
        uint sourceBalanceBefore = arbToken1.balanceOf(burnerWallet);

        // execute arb
        executeArbitrage(routes, Token(address(bnt)), arbAmount, userFunded);

        // get source token balance in the burner wallet after the trade
        uint sourceBalanceAfter = arbToken1.balanceOf(burnerWallet);
        uint sourceBalanceTransferred = sourceBalanceAfter - sourceBalanceBefore;

        // assert that the entire leftover amount is transferred to the burner wallet
        assertEq(leftoverAmount, sourceBalanceTransferred);
        // assert that no source tokens are left in the arb contract
        assertEq(arbToken1.balanceOf(address(bancorArbitrage)), 0);
    }

    /**
     * @dev fuzz test arbitrage execution with different initial tokens
     * @dev go through all exchanges and use different amounts
     * @dev test both user-funded and flashloan arbs
     */
    function testArbitrageWithDifferentTokens(uint16 exchangeId, uint arbAmount, uint fee, bool userFunded) public {
        // limit arbAmount to AMOUNT
        vm.assume(arbAmount > 0 && arbAmount < AMOUNT);
        // test exchange ids 1 - 5 (w/o Carbon)
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, 5));
        address[] memory tokensToTrade = new address[](3);
        tokensToTrade[0] = address(arbToken1);
        tokensToTrade[1] = address(arbToken2);
        tokensToTrade[2] = NATIVE_TOKEN_ADDRESS;

        // test with all token combinations
        for (uint i = 0; i < 3; ++i) {
            for (uint j = 0; j < 3; ++j) {
                for(uint k = 0 ; k < 3 ; ++k) {
                    if (i == j || i == k || j == k) {
                        continue;
                    }
                    BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
                        exchangeId,
                        tokensToTrade[i],
                        tokensToTrade[j],
                        tokensToTrade[k],
                        arbAmount,
                        fee
                    );
                    executeArbitrage(routes, Token(tokensToTrade[k]), arbAmount, userFunded);
                }
            }
        }
    }

    /**
     * @dev fuzz test arbitrage execution with different initial tokens
     * @dev go through all exchanges and use different amounts
     */
    function testUserFundedArbsReturnUsersTokens(uint16 exchangeId, uint arbAmount, uint fee) public {
        // limit arbAmount to AMOUNT
        vm.assume(arbAmount > 0 && arbAmount < AMOUNT);
        // test exchange ids 1 - 5 (w/o Carbon)
        exchangeId = uint16(bound(exchangeId, FIRST_EXCHANGE_ID, 5));
        address[] memory tokensToTrade = new address[](3);
        tokensToTrade[0] = address(arbToken1);
        tokensToTrade[1] = address(arbToken2);
        tokensToTrade[2] = NATIVE_TOKEN_ADDRESS;

        // test with all token combinations
        for (uint i = 0; i < 3; ++i) {
            for (uint j = 0; j < 3; ++j) {
                for(uint k = 0 ; k < 3 ; ++k) {
                    if (i == j || i == k || j == k) {
                        continue;
                    }
                    BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
                        exchangeId,
                        tokensToTrade[i],
                        tokensToTrade[j],
                        tokensToTrade[k],
                        arbAmount,
                        fee
                    );
                    uint balanceBefore = Token(tokensToTrade[k]).balanceOf(user1);
                    executeArbitrage(routes, Token(tokensToTrade[k]), arbAmount, true);
                    uint balanceAfter = Token(tokensToTrade[k]).balanceOf(user1);
                    assertGe(balanceAfter, balanceBefore);
                }
            }
        }
    }

    /**
     * @dev test that arb hop with 0 source amount for routes will take the available source amount
     */
    function testShouldTakeAvailableBalanceIfSourceAmountIsZero(bool userFunded) public {
        // getRoutes returns routes with 0 sourceAmount for each Route
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        uint balanceBefore = bnt.balanceOf(user1);
        vm.startPrank(user1);
        if(userFunded) {
            Token(address(bnt)).safeApprove(address(bancorArbitrage), AMOUNT);
        }
        vm.stopPrank();
        // make arb with AMOUNT
        executeArbitrageNoApproval(routes, Token(address(bnt)), AMOUNT, userFunded);
        // get user gain and calculate expected gain
        uint balanceAfter = bnt.balanceOf(user1);
        uint gain = balanceAfter - balanceBefore;
        uint hopGain = exchanges.outputAmount();
        uint totalRewards = routes.length * hopGain;
        BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();
        uint expectedGain = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;
        // check that the user has received exactly the expected tokens
        assertEq(gain, expectedGain);
    }

    /**
     * @dev test that arb hop with > available source amount will be capped to the currently available source amount
     */
    function testShouldTakeAvailableBalanceIfSourceAmountIsLarger(bool userFunded, uint firstHopSourceAmount) public {
        // bound the firstHopSourceAmount to a value larger than the arb amount 
        bound(firstHopSourceAmount, AMOUNT + 1, type(uint256).max);
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        routes[0].sourceAmount = firstHopSourceAmount; // set first hop source amount to firstHopSourceAmount
        uint balanceBefore = bnt.balanceOf(user1);
        vm.startPrank(user1);
        if(userFunded) {
            Token(address(bnt)).safeApprove(address(bancorArbitrage), AMOUNT);
        }
        vm.stopPrank();
        // make arb with AMOUNT
        executeArbitrageNoApproval(routes, Token(address(bnt)), AMOUNT, userFunded);
        // get user gain and calculate expected gain
        uint balanceAfter = bnt.balanceOf(user1);
        uint gain = balanceAfter - balanceBefore;
        uint hopGain = exchanges.outputAmount();
        uint totalRewards = routes.length * hopGain;
        BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();
        uint expectedGain = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;
        // check that the user has received exactly the expected tokens
        assertEq(gain, expectedGain);
    }

    /**
     * @dev test that arb hop will take only the specified source amount as input
     *      leftover tokens stay in the contract
     */
    function testArbHopShouldTakeOnlyTheSpecifiedSourceAmountAsInput(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        // set second hop to AMOUNT + 200 arb token 1 as input
        // after the first hop, we have AMOUNT + 300 arbToken1 tokens available
        routes[1].sourceAmount = AMOUNT + 200e18;
        // set third hop to AMOUNT + 400 arb token 2 as input
        // after the second hop, we have AMOUNT + 500 arbToken2 tokens available
        routes[2].sourceAmount = AMOUNT + 400e18;
        vm.startPrank(user1);
        if(userFunded) {
            Token(address(bnt)).safeApprove(address(bancorArbitrage), AMOUNT);
        }
        vm.stopPrank();
        uint userBalanceBefore = bnt.balanceOf(user1);
        uint balanceBefore1 = arbToken1.balanceOf(address(bancorArbitrage));
        uint balanceBefore2 = arbToken2.balanceOf(address(bancorArbitrage));
        // make arb with AMOUNT
        executeArbitrageNoApproval(routes, Token(address(bnt)), AMOUNT, userFunded);
        // get user and arb contract balances
        uint userBalanceAfter = bnt.balanceOf(user1);
        uint balanceAfter1 = arbToken1.balanceOf(address(bancorArbitrage));
        uint balanceAfter2 = arbToken2.balanceOf(address(bancorArbitrage));
        uint userGain = userBalanceAfter - userBalanceBefore;
        // calculate expected user gain
        uint hopGain = exchanges.outputAmount();
        uint totalRewards = routes.length * hopGain - 200e18;
        BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();
        uint expectedUserGain = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;
        // assert that 100 arbToken1 and arbToken2 tokens remain in the contract's balance
        assertEq(balanceAfter1, balanceBefore1 + 100e18);
        assertEq(balanceAfter2, balanceBefore2 + 100e18);
        // assert that user will gain exactly the expected amount
        assertEq(userGain, expectedUserGain);
    }

    /**
     * @dev test setting custom source token which doesn't match the previous target token
     */
    function testShouldRevertArbIfNoTokenBalanceInGivenHop() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        // setting 2nd hop source token to bnt (rather than arbToken1) - bnt balance is 0 at this point
        routes[1].sourceToken = Token(address(bnt));
        // we should send a swap tx with 0 sourceAmount
        vm.expectRevert("Source amount should be > 0");
        executeArbitrage(routes, Token(address(bnt)), AMOUNT, false);
    }

    /**
     * @dev test that arb attempt with 0 amount should revert
     */
    function testShouldRevertArbWithZeroAmount(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        vm.expectRevert(ZeroValue.selector);
        executeArbitrageNoApproval(routes, Token(address(bnt)), 0, userFunded);
    }

    /**
     * @dev test that arb attempt which burns amount below the min burn amount should revert
     */
    function testShouldRevertArbIfBelowMinBurnAmount(bool userFunded) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        // set min bnt burn to 30 BNT
        vm.prank(admin);
        bancorArbitrage.setMinBurn(30 ether);
        
        // set swap profit from mock exchanges to 10
        exchanges.setProfitAndOutputAmount(true, 10 ether);

        vm.startPrank(user1);
        if(userFunded) {
            Token(address(bnt)).safeApprove(address(bancorArbitrage), AMOUNT);
        }
        vm.expectRevert(BancorArbitrage.InsufficientBurn.selector);
        vm.stopPrank();
        // execute arb
        executeArbitrageNoApproval(routes, Token(address(bnt)), AMOUNT, userFunded);
    }

    function testShouldRevertETHUserArbIfNotEnoughETHSent() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
            uint16(ExchangeId.BANCOR_V2),
            address(arbToken1),
            address(arbToken2),
            NATIVE_TOKEN_ADDRESS,
            AMOUNT,
            500
        );
        vm.expectRevert(BancorArbitrage.InvalidETHAmountSent.selector);
        bancorArbitrage.fundAndArbV2{ value: AMOUNT - 1 }(routes, Token(NATIVE_TOKEN_ADDRESS), AMOUNT);
    }

    function testShouldRevertNonETHUserArbIfETHIsSent() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
            uint16(ExchangeId.BANCOR_V2),
            NATIVE_TOKEN_ADDRESS,
            address(arbToken2),
            address(arbToken1),
            AMOUNT,
            500
        );
        vm.expectRevert(BancorArbitrage.InvalidETHAmountSent.selector);
        bancorArbitrage.fundAndArbV2{ value: 1 }(routes, Token(address(arbToken1)), AMOUNT);
    }

    function testShouldRevertArbWithUserFundsIfTokensHaventBeenApproved(uint) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutes();
        vm.expectRevert("ERC20: insufficient allowance");
        bancorArbitrage.fundAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test that arb attempt on carbon with invalid trade data should revert
     */
    function testShouldRevertArbOnCarbonWithInvalidData(bytes memory data) public {
        BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
            uint16(ExchangeId.CARBON),
            address(arbToken1),
            address(arbToken2),
            address(bnt),
            AMOUNT,
            500
        );
        routes[1].customData = data;
        vm.expectRevert();
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev test that arb attempt on carbon with invalid trade data should revert
     */
    function testShouldRevertArbOnCarbonWithLargerThanUint128TargetAmount() public {
        BancorArbitrage.RouteV2[] memory routes = getRoutesCustomTokens(
            uint16(ExchangeId.CARBON),
            address(arbToken1),
            address(arbToken2),
            address(bnt),
            AMOUNT,
            500
        );
        routes[1].minTargetAmount = 2 ** 128;
        vm.expectRevert(BancorArbitrage.MinTargetAmountTooHigh.selector);
        bancorArbitrage.flashloanAndArbV2(routes, Token(address(bnt)), AMOUNT);
    }

    /**
     * @dev get 3 routes for arb testing
     */
    function getRoutes() public view returns (BancorArbitrage.RouteV2[] memory routes) {
        routes = new BancorArbitrage.RouteV2[](3);

        routes[0] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            sourceToken: Token(address(bnt)),
            targetToken: Token(address(arbToken1)),
            sourceAmount: 0,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(arbToken1),
            customInt: 0,
            customData: ""
        });

        routes[1] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.SUSHISWAP),
            sourceToken: Token(address(arbToken1)),
            targetToken: Token(address(arbToken2)),
            sourceAmount: 0,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(arbToken2),
            customInt: 0,
            customData: ""
        });

        routes[2] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            sourceToken: Token(address(arbToken2)),
            targetToken: Token(address(bnt)),
            sourceAmount: 0,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(bnt),
            customInt: 0,
            customData: ""
        });
        return routes;
    }

    /**
     * @dev get 3 routes for arb testing with custom tokens and 2nd exchange id
     * @param exchangeId - which exchange to use for middle swap
     * @param token1 - first swapped token
     * @param token2 - second swapped token
     * @param token2 - flashloan token
     * @param arbAmount - initial arb amount
     * @param fee - Uni V3 fee, can be 100, 500 or 3000
     */
    function getRoutesCustomTokens(
        uint16 exchangeId,
        address token1,
        address token2,
        address flashloanToken,
        uint arbAmount,
        uint fee
    ) public view returns (BancorArbitrage.RouteV2[] memory routes) {
        routes = new BancorArbitrage.RouteV2[](3);

        uint customFee = 0;
        // add custom fee bps for uni v3 - 100, 500 or 3000
        if (exchangeId == uint16(ExchangeId.UNISWAP_V3)) {
            uint16[3] memory fees = [100, 500, 3000];
            // get a random fee on each run
            uint feeIndex = bound(fee, 0, 2);
            // use 100, 500 or 3000
            customFee = fees[feeIndex];
        }
        bytes memory data = "";
        // add custom data for carbon
        if (exchangeId == uint16(ExchangeId.CARBON)) {
            TradeAction[] memory tradeActions = new TradeAction[](1);
            tradeActions[0] = TradeAction({ strategyId: 0, amount: uint128(AMOUNT + 300 ether) });
            data = abi.encode(tradeActions);
        }

        uint hopGain = exchanges.outputAmount();

        routes[0] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            sourceToken: Token(flashloanToken),
            targetToken: Token(token1),
            sourceAmount: arbAmount,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token1,
            customInt: 0,
            customData: ""
        });

        routes[1] = BancorArbitrage.RouteV2({
            exchangeId: exchangeId,
            sourceToken: Token(token1),
            targetToken: Token(token2),
            sourceAmount: arbAmount + hopGain,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token2,
            customInt: customFee,
            customData: data
        });

        routes[2] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            sourceToken: Token(token2),
            targetToken: Token(flashloanToken),
            sourceAmount: arbAmount + hopGain * 2,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: flashloanToken,
            customInt: 0,
            customData: ""
        });
        return routes;
    }

    /**
     * @dev get several routes for arb testing with custom route length
     * @param routeLength - how many routes to generate
     * @param exchangeId - which exchange to perform swaps on
     * @param fee - Uni V3 fee, can be 100, 500 or 3000
     * @param arbAmount - initial arb amount
     */
    function getRoutesCustomLength(
        uint routeLength,
        uint16 exchangeId,
        uint fee,
        uint arbAmount
    ) public view returns (BancorArbitrage.RouteV2[] memory routes) {
        routes = new BancorArbitrage.RouteV2[](routeLength);

        uint customFee = 0;
        // add custom fee bps for uni v3 - 100, 500 or 3000
        if (exchangeId == uint16(ExchangeId.UNISWAP_V3)) {
            uint16[3] memory fees = [100, 500, 3000];
            // get a random fee on each run
            uint feeIndex = bound(fee, 0, 2);
            // use 100, 500 or 3000
            customFee = fees[feeIndex];
        }
        bytes memory data = "";
        uint currentAmount = arbAmount;
        uint hopGain = exchanges.outputAmount();

        address sourceToken = address(bnt);
        address targetToken = address(arbToken1);

        // generate route for trading
        for (uint i = 0; i < routeLength; ++i) {
            if (i % 3 == 0) {
                targetToken = address(arbToken1);
            } else if (i % 3 == 1) {
                targetToken = address(arbToken2);
            } else {
                targetToken = NATIVE_TOKEN_ADDRESS;
            }
            data = getCarbonData(currentAmount);
            routes[i] = BancorArbitrage.RouteV2({
                exchangeId: exchangeId,
                sourceToken: Token(sourceToken),
                targetToken: Token(targetToken),
                sourceAmount: currentAmount,
                minTargetAmount: 1,
                deadline: DEADLINE,
                customAddress: targetToken,
                customInt: customFee,
                customData: data
            });
            currentAmount += hopGain;
            sourceToken = targetToken;
        }
        // last token should be BNT
        routes[routeLength - 1].targetToken = Token(address(bnt));
        routes[routeLength - 1].customAddress = address(bnt);
        return routes;
    }

    /**
     * @dev get 3 routes for arb testing with custom tokens and 2nd exchange = carbon
     * @param token1 - first swapped token
     * @param token2 - second swapped token
     * @param tradeActionCount - count of individual trade actions passed to carbon trade
     */
    function getRoutesCarbon(
        address token1,
        address token2,
        uint arbAmount,
        uint tradeActionCount
    ) public view returns (BancorArbitrage.RouteV2[] memory routes) {
        routes = new BancorArbitrage.RouteV2[](3);

        // generate from 1 to 11 actions
        // each action will trade `amount / tradeActionCount`
        tradeActionCount = bound(tradeActionCount, 1, 11);
        TradeAction[] memory tradeActions = new TradeAction[](tradeActionCount + 1);
        // source amount at the point of carbon trade is arbAmount + _outputAmount = 300
        uint totalSourceAmount = arbAmount + 300 ether;
        for (uint i = 1; i <= tradeActionCount; ++i) {
            tradeActions[i] = TradeAction({ strategyId: i, amount: uint128(totalSourceAmount / tradeActionCount) });
        }
        // add remainder of the division to the last trade action
        // goal is for strategies sum to be exactly equal to the source amount
        tradeActions[tradeActionCount].amount += uint128(totalSourceAmount % tradeActionCount);
        bytes memory customData = abi.encode(tradeActions);

        uint hopGain = exchanges.outputAmount();

        routes[0] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            sourceToken: Token(address(bnt)),
            targetToken: Token(token1),
            sourceAmount: arbAmount,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token1,
            customInt: 0,
            customData: ""
        });

        routes[1] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.CARBON),
            sourceToken: Token(token1),
            targetToken: Token(token2),
            sourceAmount: arbAmount + hopGain,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token2,
            customInt: 0,
            customData: customData
        });

        routes[2] = BancorArbitrage.RouteV2({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            sourceToken: Token(token2),
            targetToken: Token(address(bnt)),
            sourceAmount: arbAmount + hopGain * 2,
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(bnt),
            customInt: 0,
            customData: ""
        });
        return routes;
    }

    /**
     * @dev get custom data for trading on Carbon
     * @param amount the amount to be traded
     * @return data the encoded trading data
     */
    function getCarbonData(uint amount) public pure returns (bytes memory data) {
        TradeAction[] memory tradeActions = new TradeAction[](1);
        tradeActions[0] = TradeAction({ strategyId: 0, amount: uint128(amount) });
        data = abi.encode(tradeActions);
    }

    /**
     * @dev execute user-funded or flashloan arb
     * @dev user-funded arb gets approved before execution
     */
    function executeArbitrage(
        BancorArbitrage.RouteV2[] memory routes,
        Token token,
        uint sourceAmount,
        bool userFunded
    ) public {
        vm.startPrank(user1);
        if (userFunded) {
            token.safeIncreaseAllowance(address(bancorArbitrage), sourceAmount);
            uint val = token.isNative() ? sourceAmount : 0;
            bancorArbitrage.fundAndArbV2{ value: val }(routes, token, sourceAmount);
        } else {
            bancorArbitrage.flashloanAndArbV2(routes, token, sourceAmount);
        }
        vm.stopPrank();
    }

    /**
     * @dev execute user-funded or flashloan arb
     * @dev no approvals for token if user-funded
     */
    function executeArbitrageNoApproval(
        BancorArbitrage.RouteV2[] memory routes,
        Token token,
        uint sourceAmount,
        bool userFunded
    ) public {
        vm.startPrank(user1);
        if (userFunded) {
            uint val = token.isNative() ? sourceAmount : 0;
            bancorArbitrage.fundAndArbV2{ value: val }(routes, token, sourceAmount);
        } else {
            bancorArbitrage.flashloanAndArbV2(routes, token, sourceAmount);
        }
        vm.stopPrank();
    }

    /**
     * @dev get exchange struct for initialization of bancor arbitrage
     */
    function getExchangeStruct(address _exchanges) public pure returns (BancorArbitrage.Exchanges memory exchangeList) {
        exchangeList = BancorArbitrage.Exchanges({
            bancorNetworkV2: IBancorNetworkV2(_exchanges),
            bancorNetworkV3: IBancorNetwork(_exchanges),
            uniV2Router: IUniswapV2Router02(_exchanges),
            uniV3Router: ISwapRouter(_exchanges),
            sushiswapRouter: IUniswapV2Router02(_exchanges),
            carbonController: ICarbonController(_exchanges)
        });
    }

    /**
     * @dev mofidy target token in an arb route
     */
    function modifyRouteTargetToken(BancorArbitrage.RouteV2 memory route, address token) public pure {
        route.targetToken = Token(token);
        route.customAddress = token;
    }
}