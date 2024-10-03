// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.6.6;

// Uniswap interface and library imports
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/UniswapV2Library.sol";

contract FlashLoan {
    using SafeERC20 for IERC20;
    // Factory and routing address
    address private constant PANCAKE_FACTORY =
        0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address private constant PANCAKE_ROUTER =
        0x10ED43C718714eb63d5aA57B78B54704E256024E;

    // Token addresses
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant CROX = 0x2c094F5A7D1146BB93850f629501eB749f6Ed491;
    address private constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    uint256 private deadline = block.timestamp + 1 days;
    uint256 private constant MAX_INT =
        115792089237316195423570985008687907853269984665640564039457584007913129639935;

    function checkResult(
        uint _repayAmount,
        uint _acquiredCoin
    ) pure private returns (bool) {
        return _acquiredCoin > _repayAmount;
    }

    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
    }

    function placeTrade(
        address _fromToken,
        address _toToken,
        uint _amountIn
    ) private returns (uint) {
        address pair = IUniswapV2Factory(PANCAKE_FACTORY).getPair(
            _fromToken,
            _toToken
        );
        require(pair != address(0), "Pool does not exist");

        // Making an address type empty array with the length of 2
        address[] memory path = new address[](2);

        path[0] = _fromToken;
        path[1] = _toToken;

        // Estimated amount
        uint amountRequired = IUniswapV2Router01(PANCAKE_FACTORY).getAmountsOut(
            _amountIn,
            path
        )[1];

        // Actual amount which we get
        uint amountReceived = IUniswapV2Router01(PANCAKE_FACTORY)
            .swapExactTokensForTokens(
                _amountIn,
                amountRequired,
                path,
                address(this),
                deadline
            )[1];

        require(amountReceived > 0, "Transaction Abort");

        return amountReceived;
    }

    function initiateArbitrage(address _busdBorrow, uint _amount) external {
        IERC20(BUSD).safeApprove(address(PANCAKE_ROUTER), MAX_INT);
        IERC20(CROX).safeApprove(address(PANCAKE_ROUTER), MAX_INT);
        IERC20(CAKE).safeApprove(address(PANCAKE_ROUTER), MAX_INT);

        // Access liquidity pool of BUSD and WBNB
        address pair = IUniswapV2Factory(PANCAKE_FACTORY).getPair(
            _busdBorrow,
            WBNB
        );

        require(pair != address(0), "Pool does not exist");

        // To fetch token0 and token1 address
        address token0 = IUniswapV2Pair(pair).token0(); // WBNB
        address token1 = IUniswapV2Pair(pair).token1(); // BUSD

        // Here, token0 has WBNB address and _busdBorrow has BUSD address, so it will not transfer _amout to amount0Out, it will transfer 0
        uint amount0Out = _busdBorrow == token0 ? _amount : 0;

        // Here, token1 has BUSD address and _busdBorrow has also BUSD address, so it will transfer _amout to amount1Out
        uint amount1Out = _busdBorrow == token1 ? _amount : 0;

        bytes memory data = abi.encode(_busdBorrow, _amount, msg.sender);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);
    }

    function pancakeCall(
        address _sender,
        uint _amount0,
        uint _amount1,
        bytes calldata _data
    ) external {
        // To fetch token0 and token1 address
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();

        address pair = IUniswapV2Factory(PANCAKE_FACTORY).getPair(
            token0,
            token1
        );
        require(msg.sender == pair, "Pair does not match");
        require(_sender == address(this), "Sender does not match");

        (address busdBorrow, uint amount, address myAddress) = abi.decode(
            _data,
            (address, uint, address)
        );

        // Calculate fees
        uint fee = ((amount * 3) / 997) + 1; // This formula is in documentation of UniswapV2Pair
        uint repayAmount = amount + fee;

        // Transferring BUSD amount in loanAmount
        uint loanAmount = _amount0 > 0 ? _amount0 : _amount1;

        // Triangular Arbitrage
        uint trade1Coin = placeTrade(BUSD, CROX, loanAmount);
        uint trade2Coin = placeTrade(CROX, CAKE, trade1Coin);
        uint trade3Coin = placeTrade(CAKE, BUSD, trade2Coin);

        bool profitCheck = checkResult(repayAmount, trade3Coin);
        require(profitCheck, "Arbitrage is not profitable");

        // Transferring amount in own account
        IERC20 otherToken = IERC20(BUSD);
        otherToken.transfer(myAddress, trade3Coin - repayAmount);

        // Transferring repayAmount to pool
        IERC20(busdBorrow).transfer(pair, repayAmount);
    }
}
