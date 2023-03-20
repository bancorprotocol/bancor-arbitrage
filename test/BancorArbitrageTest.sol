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
import { IBancorNetworkV2 } from "../contracts/exchanges/interfaces/IBancorNetworkV2.sol";
import { MockExchanges } from "../contracts/helpers/MockExchanges.sol";
import { TestBNT } from "../contracts/helpers/TestBNT.sol";
import { TestWETH } from "../contracts/helpers/TestWETH.sol";
import { IBancorNetwork, IFlashLoanRecipient } from "../contracts/exchanges/interfaces/IBancorNetwork.sol";
import { PPM_RESOLUTION } from "../contracts/utility/Constants.sol";
import { TestERC20Token } from "../contracts/helpers/TestERC20Token.sol";

contract BancorArbitrageTest is Test {
    using TokenLibrary for Token;

    Utilities private utils;
    BancorArbitrage private bancorArbitrage;
    TestBNT private bnt;
    TestWETH private weth;
    TestERC20Token private baseToken;
    TestERC20Token private arbToken1;
    TestERC20Token private arbToken2;
    MockExchanges private exchanges;
    ProxyAdmin private proxyAdmin;

    address payable[] private users;
    address payable private admin;

    uint private constant BNT_VIRTUAL_BALANCE = 1;
    uint private constant BASE_TOKEN_VIRTUAL_BALANCE = 2;
    uint private constant MAX_SOURCE_AMOUNT = 100_000_000 ether;
    uint private constant DEADLINE = type(uint256).max;
    uint private constant AMOUNT = 1000 ether;
    uint private constant MIN_LIQUIDITY_FOR_TRADING = 1000 ether;
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    enum ExchangeId {
        INVALID,
        BANCOR_V2,
        BANCOR_V3,
        UNISWAP_V2,
        UNISWAP_V3,
        SUSHISWAP
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
     * @dev triggered when a flash-loan is completed
     */
    event FlashLoanCompleted(Token indexed token, address indexed borrower, uint256 amount, uint256 feeAmount);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev function to set up state before tests
    function setUp() public virtual {
        utils = new Utilities();
        // create 4 users
        users = utils.createUsers(4);
        admin = users[0];

        // deploy contracts from admin
        vm.startPrank(admin);

        // deploy proxy admin
        proxyAdmin = new ProxyAdmin();
        // deploy BNT
        bnt = new TestBNT("Bancor Network Token", "BNT", 1_000_000_000 ether);
        // deploy WETH
        weth = new TestWETH();
        // deploy MockExchanges
        exchanges = new MockExchanges(IERC20(weth), 300 ether, true);
        // Deploy arbitrage contract
        bancorArbitrage = new BancorArbitrage(
            bnt,
            IBancorNetworkV2(address(exchanges)),
            IBancorNetwork(address(exchanges)),
            IUniswapV2Router02(address(exchanges)),
            ISwapRouter(address(exchanges)),
            IUniswapV2Router02(address(exchanges))
        );

        bytes memory selector = abi.encodeWithSelector(bancorArbitrage.initialize.selector);

        // deploy arb proxy
        address arbProxy = address(
            new TransparentUpgradeableProxyImmutable(address(bancorArbitrage), payable(address(proxyAdmin)), selector)
        );
        bancorArbitrage = BancorArbitrage(payable(arbProxy));

        // deploy test tokens
        baseToken = new TestERC20Token("TKN", "TKN", 1_000_000_000 ether);
        arbToken1 = new TestERC20Token("TKN1", "TKN1", 1_000_000_000 ether);
        arbToken2 = new TestERC20Token("TKN2", "TKN2", 1_000_000_000 ether);

        // send some tokens to exchange
        baseToken.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        arbToken1.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        arbToken2.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        bnt.transfer(address(exchanges), MAX_SOURCE_AMOUNT * 5);
        // send eth to exchange
        vm.deal(address(exchanges), MAX_SOURCE_AMOUNT);
        // send weth to exchange
        vm.deal(admin, MAX_SOURCE_AMOUNT);
        weth.deposit{ value: MAX_SOURCE_AMOUNT }();
        weth.transfer(address(exchanges), MAX_SOURCE_AMOUNT);
        vm.stopPrank();
    }

    /**
     * @dev Test should be able to initialize new implementation
     */
    function testShouldBeAbleToInitializeImpl() public {
        BancorArbitrage __bancorArbitrage = new BancorArbitrage(
            bnt,
            IBancorNetworkV2(address(exchanges)),
            IBancorNetwork(address(exchanges)),
            IUniswapV2Router02(address(exchanges)),
            ISwapRouter(address(exchanges)),
            IUniswapV2Router02(address(exchanges))
        );
        __bancorArbitrage.initialize();
    }

    /**
     * @dev Test revert when deploying BancorArbitrage with an invalid BNT contract
     */
    function testShouldRevertWhenInitializingWithInvalidBNTContract() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(
            IERC20(address(0)),
            IBancorNetworkV2(address(exchanges)),
            IBancorNetwork(address(exchanges)),
            IUniswapV2Router02(address(exchanges)),
            ISwapRouter(address(exchanges)),
            IUniswapV2Router02(address(exchanges))
        );
    }

    /**
     * @dev Test revert when deploying BancorArbitrage with an invalid Bancor V2 contract
     */
    function testShouldRevertWhenInitializingWithInvalidBancorV2Contract() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(
            bnt,
            IBancorNetworkV2(address(0)),
            IBancorNetwork(address(exchanges)),
            IUniswapV2Router02(address(exchanges)),
            ISwapRouter(address(exchanges)),
            IUniswapV2Router02(address(exchanges))
        );
    }

    /**
     * @dev Test revert when deploying BancorArbitrage with an invalid Bancor V3 contract
     */
    function testShouldRevertWhenInitializingWithInvalidBancorV3Contract() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(
            bnt,
            IBancorNetworkV2(address(exchanges)),
            IBancorNetwork(address(0)),
            IUniswapV2Router02(address(exchanges)),
            ISwapRouter(address(exchanges)),
            IUniswapV2Router02(address(exchanges))
        );
    }

    /**
     * @dev Test revert when deploying BancorArbitrage with an invalid Uni V2 router
     */
    function testShouldRevertWhenInitializingWithInvalidUniV2Router() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(
            bnt,
            IBancorNetworkV2(address(exchanges)),
            IBancorNetwork(address(exchanges)),
            IUniswapV2Router02(address(0)),
            ISwapRouter(address(exchanges)),
            IUniswapV2Router02(address(exchanges))
        );
    }

    /**
     * @dev Test revert when deploying BancorArbitrage with an invalid Uni V3 router
     */
    function testShouldRevertWhenInitializingWithInvalidUniV3Router() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(
            bnt,
            IBancorNetworkV2(address(exchanges)),
            IBancorNetwork(address(exchanges)),
            IUniswapV2Router02(address(exchanges)),
            ISwapRouter(address(0)),
            IUniswapV2Router02(address(exchanges))
        );
    }

    /**
     * @dev Test revert when deploying BancorArbitrage with an invalid Sushiswap router
     */
    function testShouldRevertWhenInitializingWithInvalidSushiswapRouter() public {
        vm.expectRevert(InvalidAddress.selector);
        new BancorArbitrage(
            bnt,
            IBancorNetworkV2(address(exchanges)),
            IBancorNetwork(address(exchanges)),
            IUniswapV2Router02(address(exchanges)),
            ISwapRouter(address(exchanges)),
            IUniswapV2Router02(address(0))
        );
    }

    function testShouldBeInitialized() public {
        uint version = bancorArbitrage.version();
        assertEq(version, 2);
    }

    /// --- Reward tests --- ///

    /**
     * @dev test reverting when attempting to set rewards from non-admin address
     */
    function testShouldRevertWhenSettingRewardsFromNonAdmin() public {
        vm.prank(users[1]);
        vm.expectRevert(AccessDenied.selector);
        bancorArbitrage.setRewards(arbitrageRewardsUpdated);
    }

    /**
     * @dev test that set rewards shouldn't emit the RewardsUpdated event
     * @dev testFail is a test which expects an assertion to fail
     */
    function testFailShouldIgnoreSettingSameArbRewardsSettings() public {
        vm.prank(admin);
        // this assertion will fail
        vm.expectEmit(false, false, false, false);
        emit RewardsUpdated(0, 0, 0, 0);
        bancorArbitrage.setRewards(arbitrageRewardsDefaults);
    }

    /**
     * @dev test that admin should be able to set rewards settings
     */
    function testShouldBeAbleToSetArbRewardsSettings() public {
        vm.startPrank(admin);
        bancorArbitrage.setRewards(arbitrageRewardsDefaults);
        BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();
        assertEq(rewards.percentagePPM, 100_000);

        vm.expectEmit(true, true, true, true);
        emit RewardsUpdated(
            arbitrageRewardsUpdated.percentagePPM,
            arbitrageRewardsUpdated.percentagePPM,
            arbitrageRewardsDefaults.maxAmount,
            arbitrageRewardsUpdated.maxAmount
        );
        bancorArbitrage.setRewards(arbitrageRewardsUpdated);

        rewards = bancorArbitrage.rewards();
        assertEq(rewards.percentagePPM, 40_000);
        vm.stopPrank();
    }

    /// --- Distribution and burn tests --- ///

    /**
     * @dev test reward distribution and burn on arbitrage execution
     */
    function testShouldCorrectlyDistributeRewardsAndBurnTokens() public {
        vm.startPrank(admin);
        BancorArbitrage.Route[] memory routes = getRoutes();

        // each hop through the route from MockExchanges adds 300e18 tokens to the output
        // so 3 hops = 3 * 300e18 = 900 BNT tokens more than start
        // so with 0 flashloan fees, when we repay the flashloan, we have 900 BNT tokens as totalRewards

        uint hopCount = 3;
        uint totalRewards = 300e18 * hopCount;

        bancorArbitrage.setRewards(arbitrageRewardsUpdated);

        BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();

        uint expectedUserReward = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;
        uint expectedBntBurnt = totalRewards - expectedUserReward;

        uint16[3] memory _exchangeIds = [
            uint16(ExchangeId.BANCOR_V2),
            uint16(ExchangeId.SUSHISWAP),
            uint16(ExchangeId.BANCOR_V2)
        ];
        address[4] memory _tokenPath = [address(bnt), address(arbToken1), address(arbToken2), address(bnt)];
        uint16[] memory exchangeIds = new uint16[](3);
        address[] memory tokenPath = new address[](4);
        for (uint i = 0; i < 3; ++i) {
            exchangeIds[i] = _exchangeIds[i];
            tokenPath[i] = _tokenPath[i];
        }
        tokenPath[3] = _tokenPath[3];

        vm.expectEmit(true, true, true, true);
        emit ArbitrageExecuted(admin, exchangeIds, tokenPath, AMOUNT, expectedBntBurnt, expectedUserReward);
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev test reward distribution if the rewards exceed the max set rewards
     */
    function testShouldCorrectlyDistributeRewardsToCallerIfExceedingMaxRewards() public {
        vm.startPrank(admin);
        BancorArbitrage.Route[] memory routes = getRoutes();

        // each hop through the route from MockExchanges adds 300e18 tokens to the output
        // so 3 hops = 3 * 300e18 = 900 BNT tokens more than start
        // so with 0 flashloan fees, when we repay the flashloan, we have 900 BNT tokens as totalRewards

        uint hopCount = 3;
        uint totalRewards = 300e18 * hopCount;

        // set rewards maxAmount to 100
        BancorArbitrage.Rewards memory newRewards = BancorArbitrage.Rewards({ percentagePPM: 40000, maxAmount: 100 });

        bancorArbitrage.setRewards(newRewards);

        BancorArbitrage.Rewards memory rewards = bancorArbitrage.rewards();

        // calculate expected user rewards based on total rewards and percentagePPM
        uint expectedUserReward = (totalRewards * rewards.percentagePPM) / PPM_RESOLUTION;

        // check we have exceeded the max reward amount
        assertGt(expectedUserReward, rewards.maxAmount);

        // update the expected user reward
        expectedUserReward = rewards.maxAmount;

        uint expectedBurn = totalRewards - expectedUserReward;

        uint16[3] memory _exchangeIds = [
            uint16(ExchangeId.BANCOR_V2),
            uint16(ExchangeId.SUSHISWAP),
            uint16(ExchangeId.BANCOR_V2)
        ];
        address[4] memory _tokenPath = [address(bnt), address(arbToken1), address(arbToken2), address(bnt)];
        uint16[] memory exchangeIds = new uint16[](3);
        address[] memory tokenPath = new address[](4);
        for (uint i = 0; i < 3; ++i) {
            exchangeIds[i] = _exchangeIds[i];
            tokenPath[i] = _tokenPath[i];
        }
        tokenPath[3] = _tokenPath[3];

        vm.expectEmit(true, true, true, true);
        emit ArbitrageExecuted(admin, exchangeIds, tokenPath, AMOUNT, expectedBurn, expectedUserReward);
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /// --- Flashloan tests --- ///

    /**
     * @dev Test that onFlashloan cannot be called directly
     */
    function testShouldntBeAbleToCallOnFlashloanDirectly() public {
        vm.expectRevert(BancorArbitrage.InvalidFlashLoanCaller.selector);
        bancorArbitrage.onFlashLoan(address(bancorArbitrage), IERC20(address(bnt)), 1, 0, "0x");
    }

    /**
     * @dev Test correct obtaining and repayment of flashloan
     */
    function testShouldCorrectlyObtainAndRepayFlashloan() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectEmit(true, true, true, true);
        emit FlashLoanCompleted(Token(address(bnt)), address(bancorArbitrage), AMOUNT, 0);
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev Test should revert if flashloan cannot be obtained
     */
    function testShouldRevertIfFlashloanCannotBeObtained() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectRevert();
        bancorArbitrage.execute(routes, type(uint256).max);
    }

    /// --- Trade tests --- ///

    /**
     * @dev test that trade attempt if deadline is > block.timestamp reverts
     */
    function testShouldRevertIfDeadlineIsReached() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        // move block.timestamp forward by 1000 sec
        skip(1000);
        // set deadline to 1
        routes[0].deadline = 1;
        routes[1].deadline = 1;
        routes[2].deadline = 1;
        vm.expectRevert();
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev test that trade attempt reverts if exchange id is not supported
     */
    function testShouldRevertIfExchangeIdIsNotSupported() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[0].exchangeId = 0;
        vm.expectRevert(BancorArbitrage.InvalidExchangeId.selector);
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev test that trade attempt with invalid route length
     */
    function testShouldRevertIfRouteLengthIsInvalid() public {
        // attempt to route through 11 exchanges
        BancorArbitrage.Route[] memory longRoute = new BancorArbitrage.Route[](11);

        vm.expectRevert(BancorArbitrage.InvalidRouteLength.selector);
        bancorArbitrage.execute(longRoute, AMOUNT);
        // attempt to route through 0 exchanges
        BancorArbitrage.Route[] memory emptyRoute = new BancorArbitrage.Route[](0);
        vm.expectRevert(BancorArbitrage.InvalidRouteLength.selector);
        bancorArbitrage.execute(emptyRoute, AMOUNT);
    }

    /**
     * @dev test attempting to trade with more than exchange's balance reverts
     */
    function testShouldRevertIfExchangeDoesntHaveEnoughBalance() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        bancorArbitrage.execute(routes, MAX_SOURCE_AMOUNT * 2);
    }

    /**
     * @dev test reverts if min target amount is greater than expected
     */
    function testShouldRevertIfMinTargetAmountIsGreaterThanExpected() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[0].minTargetAmount = type(uint256).max;
        vm.expectRevert("InsufficientTargetAmount");
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev test reverts if the output token of the arb isn't BNT
     */
    function testShouldRevertIfOutputTokenIsntBNT() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[2].targetToken = Token(address(arbToken2));
        routes[2].customAddress = address(arbToken2);
        vm.expectRevert(BancorArbitrage.InvalidInitialAndFinalTokens.selector);
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev test reverts if the path is invalid
     * @dev the test uses same input and output token for the second swap
     */
    function testShouldRevertIfThePathIsInvalid() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        routes[1].exchangeId = uint16(ExchangeId.BANCOR_V2);
        routes[1].targetToken = Token(address(arbToken1));
        routes[1].customAddress = address(arbToken1);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev test trade approvals for erc-20 tokens for exchanges
     * @dev should approve max amount for trading on each first swap for token and exchange
     */
    function testShouldApproveERC20TokensForEachExchange(uint16 exchangeId) public {
        // only 1 - 5 are valid exchange ids
        exchangeId = uint16(bound(exchangeId, 1, 5));
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
                BancorArbitrage.Route[] memory routes = getRoutesCustomTokens(
                    exchangeId,
                    tokensToTrade[i],
                    tokensToTrade[j],
                    500
                );
                uint allowance = arbToken1.allowance(address(bancorArbitrage), address(exchanges));
                if (allowance == 0) {
                    // expect arbToken1 to emit the approval event
                    vm.expectEmit(true, true, true, true, address(arbToken1));
                    emit Approval(address(bancorArbitrage), address(exchanges), approveAmount);
                }
                bancorArbitrage.execute(routes, AMOUNT);
            }
        }
    }

    /// --- Arbitrage tests --- ///

    /**
     * @dev test arbitrage executed event gets emitted
     */
    function testShouldEmitArbitrageExecutedOnSuccessfulArb() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        uint16[] memory exchangeIds = new uint16[](0);
        address[] memory tradePath = new address[](0);
        vm.expectEmit(false, false, false, false);
        emit ArbitrageExecuted(admin, exchangeIds, tradePath, AMOUNT, 0, 0);
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev test that any address can execute arbs
     */
    function testAnyoneCanExecuteArbs(address user) public {
        // assume user is not proxy admin or 0x0 address
        vm.assume(user != address(proxyAdmin) && user != address(0));
        BancorArbitrage.Route[] memory routes = getRoutes();
        // impersonate user
        vm.prank(user);
        bancorArbitrage.execute(routes, AMOUNT);
    }

    /**
     * @dev fuzz test arbitrage execution
     * @dev go through all exchanges and use different amounts
     */
    function testArbitrage(uint16 exchangeId, uint arbAmount, uint fee) public {
        // limit arbAmount to AMOUNT
        vm.assume(arbAmount > 0 && arbAmount < AMOUNT);
        // only 1 - 5 are valid exchange ids
        exchangeId = uint16(bound(exchangeId, 1, 5));
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
                BancorArbitrage.Route[] memory routes = getRoutesCustomTokens(
                    exchangeId,
                    tokensToTrade[i],
                    tokensToTrade[j],
                    fee
                );
                bancorArbitrage.execute(routes, arbAmount);
            }
        }
    }

    /**
     * @dev test arbitrages with different route length
     * @dev fuzz test 1 - 10 routes on any exchange with any amount
     */
    function testArbitrageWithDifferentRoutes(uint routeLength, uint16 exchangeId, uint arbAmount, uint fee) public {
        // bound route len from 1 to 10
        routeLength = bound(routeLength, 1, 10);
        // bound exchange id from 1 to 5
        exchangeId = uint16(bound(exchangeId, 1, 5));
        // bound arb amount from 1 to AMOUNT
        arbAmount = bound(arbAmount, 1, AMOUNT);
        // get routes
        BancorArbitrage.Route[] memory routes = getRoutesCustomLength(routeLength, exchangeId, fee);
        // trade
        bancorArbitrage.execute(routes, arbAmount);
    }

    /**
     * @dev test that arb attempt with 0 amount should revert
     */
    function testShouldRevertArbWithZeroAmount() public {
        BancorArbitrage.Route[] memory routes = getRoutes();
        vm.expectRevert(ZeroValue.selector);
        bancorArbitrage.execute(routes, 0);
    }

    /**
     * @dev Get 3 routes for arb testing
     */
    function getRoutes() public view returns (BancorArbitrage.Route[] memory routes) {
        routes = new BancorArbitrage.Route[](3);

        routes[0] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(address(arbToken1)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(arbToken1),
            customInt: 0
        });

        routes[1] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.SUSHISWAP),
            targetToken: Token(address(arbToken2)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(arbToken2),
            customInt: 0
        });

        routes[2] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(address(bnt)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(bnt),
            customInt: 0
        });
        return routes;
    }

    /**
     * @dev Get 3 routes for arb testing with custom tokens and 2nd exchange id
     * @param exchangeId - which exchange to use for middle swap
     * @param token1 - first swapped token
     * @param token2 - second swapped token
     * @param fee - Uni V3 fee, can be 100, 500 or 3000
     */
    function getRoutesCustomTokens(
        uint16 exchangeId,
        address token1,
        address token2,
        uint fee
    ) public view returns (BancorArbitrage.Route[] memory routes) {
        routes = new BancorArbitrage.Route[](3);

        uint customFee = 0;
        // add custom fee bps for uni v3 - 100, 500 or 3000
        if (exchangeId == uint16(ExchangeId.UNISWAP_V3)) {
            uint16[3] memory fees = [100, 500, 3000];
            // get a random fee on each run
            uint feeIndex = bound(fee, 0, 2);
            // use 100, 500 or 3000
            customFee = fees[feeIndex];
        }

        routes[0] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(token1),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token1,
            customInt: 0
        });

        routes[1] = BancorArbitrage.Route({
            exchangeId: exchangeId,
            targetToken: Token(token2),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: token2,
            customInt: customFee
        });

        routes[2] = BancorArbitrage.Route({
            exchangeId: uint16(ExchangeId.BANCOR_V2),
            targetToken: Token(address(bnt)),
            minTargetAmount: 1,
            deadline: DEADLINE,
            customAddress: address(bnt),
            customInt: 0
        });
        return routes;
    }

    /**
     * @dev Get several routes for arb testing with custom route length
     * @param routeLength - how many routes to generate
     * @param exchangeId - which exchange to perform swaps on
     * @param fee - Uni V3 fee, can be 100, 500 or 3000
     */
    function getRoutesCustomLength(
        uint routeLength,
        uint16 exchangeId,
        uint fee
    ) public view returns (BancorArbitrage.Route[] memory routes) {
        routes = new BancorArbitrage.Route[](routeLength);

        uint customFee = 0;
        // add custom fee bps for uni v3 - 100, 500 or 3000
        if (exchangeId == uint16(ExchangeId.UNISWAP_V3)) {
            uint16[3] memory fees = [100, 500, 3000];
            // get a random fee on each run
            uint feeIndex = bound(fee, 0, 2);
            // use 100, 500 or 3000
            customFee = fees[feeIndex];
        }

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
            routes[i] = BancorArbitrage.Route({
                exchangeId: exchangeId,
                targetToken: Token(targetToken),
                minTargetAmount: 1,
                deadline: DEADLINE,
                customAddress: targetToken,
                customInt: 0
            });
        }
        // last token should be BNT
        routes[routeLength - 1].targetToken = Token(address(bnt));
        routes[routeLength - 1].customAddress = address(bnt);
        return routes;
    }
}
