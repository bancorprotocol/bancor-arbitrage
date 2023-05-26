// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import { Token } from "../token/Token.sol";
import { TokenLibrary } from "../token/TokenLibrary.sol";
import { BancorArbitrage } from "../arbitrage/BancorArbitrage.sol";
import { IFlashLoanRecipient } from "../exchanges/interfaces/IBancorNetwork.sol";
import { IFlashLoanRecipient as BalancerFlashloanRecipient } from "../exchanges/interfaces/IBalancerVault.sol";

import { TradeAction } from "../exchanges/interfaces/ICarbonController.sol";

contract MockExchanges {
    using SafeERC20 for IERC20;
    using TokenLibrary for Token;

    // the address that represents the native token reserve
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    IERC20 private immutable _weth;

    address private immutable _bnt;

    // what amount is added or subtracted to/from the input amount on swap
    uint private _outputAmount;

    // true if the gain amount is added to the swap input, false if subtracted
    bool private _profit;

    // mapping for flashloan-whitelisted tokens
    mapping(address => bool) public isWhitelisted;

    // mapping for tokens tradeable on v3
    mapping(Token => address) public collectionByPool;

    error InsufficientFlashLoanReturn();
    error NotWhitelisted();
    error ZeroValue();

    /**
     * @dev triggered when a flash-loan is completed
     */
    event FlashLoanCompleted(Token indexed token, address indexed borrower, uint256 amount, uint256 feeAmount);

    constructor(IERC20 weth, address bnt, uint initOutputAmount, bool initProfit) {
        _weth = weth;
        _bnt = bnt;
        _outputAmount = initOutputAmount;
        _profit = initProfit;
    }

    receive() external payable {}

    //solhint-disable-next-line func-name-mixedcase
    function WETH() external view returns (IERC20) {
        return _weth;
    }

    function outputAmount() external view returns (uint) {
        return _outputAmount;
    }

    function profit() external view returns (bool) {
        return _profit;
    }

    /**
     * @dev v3 network flashloan mock
     */
    function flashLoan(Token token, uint256 amount, IFlashLoanRecipient recipient, bytes calldata data) external {
        // check if token is whitelisted
        if (!isWhitelisted[address(token)]) {
            revert NotWhitelisted();
        }
        uint feeAmount = 0;
        uint prevBalance = token.balanceOf(address(this));
        uint prevWethBalance = _weth.balanceOf(address(this));

        // transfer funds to flashloan recipient
        token.safeTransfer(payable(address(recipient)), amount);

        // trigger flashloan callback
        recipient.onFlashLoan(msg.sender, token.toIERC20(), amount, feeAmount, data);

        // account for net gain in the token which is sent from this contract
        // decode data to count the swaps
        (, , BancorArbitrage.TradeRoute[] memory routes) = abi.decode(
            data,
            (uint256, BancorArbitrage.Flashloan[], BancorArbitrage.TradeRoute[])
        );
        uint swapCount = address(token) == _bnt ? routes.length : routes.length + 1;
        uint gain = swapCount * _outputAmount;
        uint expectedBalance;
        if (_profit) {
            expectedBalance = prevBalance - gain;
        } else {
            expectedBalance = prevBalance + gain;
        }
        // account for weth gains if token is native (uni v3 swaps convert eth to weth)
        if (token.isNative()) {
            uint wethBalance = _weth.balanceOf(address(this));
            uint wethGain = wethBalance - prevWethBalance;
            expectedBalance -= wethGain;
        }

        if (token.balanceOf(address(this)) < expectedBalance) {
            revert InsufficientFlashLoanReturn();
        }
        emit FlashLoanCompleted({ token: token, borrower: msg.sender, amount: amount, feeAmount: feeAmount });
    }

    /**
     * @dev set profit and output amount
     */
    function setProfitAndOutputAmount(bool newProfit, uint256 newOutputAmount) external {
        _profit = newProfit;
        _outputAmount = newOutputAmount;
    }

    /**
     * @dev add token to whitelist for flashloans
     */
    function addToWhitelist(address token) external {
        isWhitelisted[token] = true;
    }

    /**
     * @dev remove token from whitelist for flashloans
     */
    function removeFromWhitelist(address token) external {
        isWhitelisted[token] = false;
    }

    /**
     * @dev set collection by pool
     */
    function setCollectionByPool(Token token) external {
        collectionByPool[token] = address(token);
    }

    /**
     * @dev reset collection by pool
     */
    function resetCollectionByPool(Token token) external {
        collectionByPool[token] = address(0);
    }

    /**
     * Bancor v2 trade
     */
    function convertByPath(
        address[] memory _path,
        uint256 _amount,
        uint256 _minReturn,
        address /* _beneficiary */,
        address /* _affiliateAccount */,
        uint256 /* _affiliateFee */
    ) external payable returns (uint256) {
        Token sourceToken = Token(_path[0]);
        Token targetToken = Token(_path[_path.length - 1]);
        return mockSwap(sourceToken, targetToken, _amount, msg.sender, block.timestamp, _minReturn);
    }

    /**
     * Bancor v3 trade
     */
    function tradeBySourceAmountArb(
        Token sourceToken,
        Token targetToken,
        uint256 sourceAmount,
        uint256 minReturnAmount,
        uint256 deadline,
        address /* beneficiary */
    ) external payable returns (uint256) {
        if (minReturnAmount == 0) {
            revert ZeroValue();
        }
        return mockSwap(sourceToken, targetToken, sourceAmount, msg.sender, deadline, minReturnAmount);
    }

    /**
     * Carbon controller trade
     */
    function tradeBySourceAmount(
        Token sourceToken,
        Token targetToken,
        TradeAction[] calldata tradeActions,
        uint256 deadline,
        uint128 minReturn
    ) external payable returns (uint128) {
        // calculate total source amount from individual trade actions
        uint256 sourceAmount = 0;
        for (uint i = 0; i < tradeActions.length; ++i) {
            sourceAmount += uint128(tradeActions[i].amount);
        }
        return uint128(mockSwap(sourceToken, targetToken, sourceAmount, msg.sender, deadline, minReturn));
    }

    /**
     * Uniswap v2 + Sushiswap trades
     */
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address /* to */,
        uint deadline
    ) external returns (uint[] memory) {
        uint[] memory amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = mockSwap(Token(path[0]), Token(path[1]), amountIn, msg.sender, deadline, amountOutMin);
        return amounts;
    }

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address /* to */,
        uint deadline
    ) external payable returns (uint[] memory) {
        uint[] memory amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = mockSwap(
            Token(NATIVE_TOKEN_ADDRESS),
            Token(path[1]),
            msg.value,
            msg.sender,
            deadline,
            amountOutMin
        );
        return amounts;
    }

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address /* to */,
        uint deadline
    ) external returns (uint[] memory) {
        uint[] memory amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = mockSwap(
            Token(path[0]),
            Token(NATIVE_TOKEN_ADDRESS),
            amountIn,
            msg.sender,
            deadline,
            amountOutMin
        );
        return amounts;
    }

    /**
     * Uniswap v3 trade
     */
    function exactInputSingle(ISwapRouter.ExactInputSingleParams memory params) external returns (uint256 amountOut) {
        return
            mockSwap(
                Token(params.tokenIn),
                Token(params.tokenOut),
                params.amountIn,
                msg.sender,
                params.deadline,
                params.amountOutMinimum
            );
    }

    function mockSwap(
        Token sourceToken,
        Token targetToken,
        uint256 amount,
        address trader,
        uint deadline,
        uint minTargetAmount
    ) private returns (uint256) {
        require(deadline >= block.timestamp, "Swap timeout");
        require(sourceToken != targetToken, "Invalid swap");
        require(amount > 0, "Source amount should be > 0");
        // withdraw source amount
        sourceToken.safeTransferFrom(trader, address(this), amount);

        // transfer target amount
        // receive outputAmount tokens per swap
        uint targetAmount;
        if (_profit) {
            targetAmount = amount + _outputAmount;
        } else {
            targetAmount = amount - _outputAmount;
        }
        require(targetAmount >= minTargetAmount, "InsufficientTargetAmount");
        targetToken.safeTransfer(trader, targetAmount);
        return targetAmount;
    }
}
