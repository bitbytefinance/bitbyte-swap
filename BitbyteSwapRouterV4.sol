// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import './interfaces/IWETH.sol';
import './libs/SafeMath.sol';
import './libs/TransferHelper.sol';
import './interfaces/IZooswapFactoryV4.sol';
import './interfaces/IZooswapPairV4.sol';
import './interfaces/IBitbyteSwapRouterHelper.sol';
import '../libs/CfoTakeable.sol';

contract BitbyteSwapRouterV4 is CfoTakeable {
    using SafeMath for uint256;

    address public immutable factory;
    address public immutable WETH;
    address public swapMining;

    IBitbyteSwapRouterHelper public immutable routerHelper;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'ZooswapRouter: EXPIRED');
        _;
    }

    constructor(
        address _factory,
        address _weth,
        address _routerHelper
    ) {
        factory = _factory;
        WETH = _weth;
        routerHelper = IBitbyteSwapRouterHelper(_routerHelper);
    }

    receive() external payable {
        assert(msg.sender == WETH);
        // only accept BNB via fallback from the WETH contract
    }

    function pairFor(address tokenA, address tokenB) public view returns (address pair){
        pair = IZooswapFactory(factory).pairFor(tokenA, tokenB);
    }

    // function setSwapMining(address _swapMininng) external onlyOwner {
    //     swapMining = _swapMininng;
    // }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        if (IZooswapFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IZooswapFactory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB) = IZooswapFactory(factory).getReserves(tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = IZooswapFactory(factory).quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'ZooswapRouter: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = IZooswapFactory(factory).quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'ZooswapRouter: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = pairFor(tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IZooswapPair(pair).mint(to);
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = pairFor(token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value : amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IZooswapPair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = pairFor(tokenA, tokenB);
        IZooswapPair(pair).transferFrom(msg.sender, pair, liquidity);
        // send liquidity to pair
        (uint amount0, uint amount1) = IZooswapPair(pair).burn(to);
        (address token0,) = IZooswapFactory(factory).sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'ZooswapRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'ZooswapRouter: INSUFFICIENT_B_AMOUNT');
    }

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual ensure(deadline) returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual returns (uint amountA, uint amountB) {
        address pair = pairFor(tokenA, tokenB);
        uint value = approveMax ? type(uint256).max : liquidity;
        IZooswapPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual returns (uint amountToken, uint amountETH) {
        address pair = pairFor(token, WETH);
        uint value = approveMax ? type(uint256).max : liquidity;
        IZooswapPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual returns (uint amountETH) {
        address pair = pairFor(token, WETH);
        uint value = approveMax ? type(uint256).max : liquidity;
        IZooswapPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // function swapExactTokensForTokens(
    //     uint amountIn,
    //     uint amountOutMin,
    //     address[] calldata path,
    //     address to,
    //     uint deadline
    // ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
    //     amounts = IZooswapFactory(factory).getAmountsOut(amountIn, path);
    //     require(amounts[amounts.length - 1] >= amountOutMin, 'ZooswapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
    //     TransferHelper.safeTransferFrom(
    //         path[0], msg.sender, pairFor(path[0], path[1]), amounts[0]
    //     );
    //     _swap(amounts, path, to);
    // }

    // function swapTokensForExactTokens(
    //     uint amountOut,
    //     uint amountInMax,
    //     address[] calldata path,
    //     address to,
    //     uint deadline
    // ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
    //     amounts = IZooswapFactory(factory).getAmountsIn(amountOut, path);
    //     require(amounts[0] <= amountInMax, 'ZooswapRouter: EXCESSIVE_INPUT_AMOUNT');
    //     TransferHelper.safeTransferFrom(
    //         path[0], msg.sender, pairFor(path[0], path[1]), amounts[0]
    //     );
    //     _swap(amounts, path, to);
    // }

    // function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    // external
    // virtual
    // override
    // payable
    // ensure(deadline)
    // returns (uint[] memory amounts)
    // {
    //     require(path[0] == WETH, 'ZooswapRouter: INVALID_PATH');
    //     amounts = IZooswapFactory(factory).getAmountsOut(msg.value, path);
    //     require(amounts[amounts.length - 1] >= amountOutMin, 'ZooswapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
    //     IWETH(WETH).deposit{value : amounts[0]}();
    //     assert(IWETH(WETH).transfer(pairFor(path[0], path[1]), amounts[0]));
    //     _swap(amounts, path, to);
    // }

    // function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    // external
    // virtual
    // override
    // ensure(deadline)
    // returns (uint[] memory amounts)
    // {
    //     require(path[path.length - 1] == WETH, 'ZooswapRouter: INVALID_PATH');
    //     amounts = IZooswapFactory(factory).getAmountsIn(amountOut, path);
    //     require(amounts[0] <= amountInMax, 'ZooswapRouter: EXCESSIVE_INPUT_AMOUNT');
    //     TransferHelper.safeTransferFrom(
    //         path[0], msg.sender, pairFor(path[0], path[1]), amounts[0]
    //     );
    //     _swap(amounts, path, address(this));
    //     IWETH(WETH).withdraw(amounts[amounts.length - 1]);
    //     TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    // }

    // function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    // external
    // virtual
    // override
    // ensure(deadline)
    // returns (uint[] memory amounts)
    // {
    //     require(path[path.length - 1] == WETH, 'ZooswapRouter: INVALID_PATH');
    //     // amounts = IZooswapFactory(factory).getAmountsOut(amountIn, path);
    //     (uint amountToPair,bool isThird) = routerHelper.calcAmountToPair(amountIn, path);
    //     _chargeFee(path[0],amountIn,amountToPair);
    //     require(amounts[amounts.length - 1] >= amountOutMin, 'ZooswapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
    //     TransferHelper.safeTransferFrom(path[0], msg.sender, pairFor(path[0], path[1]), amounts[0]);
    //     // _swap(amounts, path, address(this));
    //     routerHelper.swap(caller, path, address(this), isThird);
    //     IWETH(WETH).withdraw(amounts[amounts.length - 1]);
    //     TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    // }

    // function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
    // external
    // virtual
    // override
    // payable
    // ensure(deadline)
    // returns (uint[] memory amounts)
    // {
    //     require(path[0] == WETH, 'ZooswapRouter: INVALID_PATH');
    //     (uint allAmount,uint amountToPair,bool isThird) = routerHelper.calcAmountToPairByOut(amountOut, path);        
    //     // amounts = IZooswapFactory(factory).getAmountsIn(amountOut, path);
    //     require(allAmount <= msg.value, 'ZooswapRouter: EXCESSIVE_INPUT_AMOUNT');
    //     IWETH(WETH).deposit{value : amountToPair}();
    //     assert(IWETH(WETH).transfer(pairFor(path[0], path[1]), amountToPair));
    //     routerHelper.swap(msg.sender, path, to, isThird);
    //     //_swap(amounts, path, to);
    //     // refund dust eth, if any
    //     if (msg.value > allAmount) TransferHelper.safeTransferETH(msg.sender, msg.value - allAmount);
    // }

    // function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {       
    //     for (uint i; i < path.length - 1; i++) {
    //         (address input, address output) = (path[i], path[i + 1]);
    //         (address token0,) = IZooswapFactory(factory).sortTokens(input, output);
    //         IZooswapPair pair = IZooswapPair(pairFor(input, output,allowThirdPair));
    //         uint amountInput;
    //         uint amountOutput;
    //         {// scope to avoid stack too deep errors
    //             (uint reserve0, uint reserve1,) = pair.getReserves();
    //             (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    //             amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
    //             amountOutput = IZooswapFactory(factory).getAmountOut(amountInput, reserveInput, reserveOutput, input, output);
    //         }
    //         if (swapMining != address(0)) {
    //             ISwapMining(swapMining).swap(msg.sender, input, output, amountOutput);
    //         }
    //         (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
    //         address to = i < path.length - 2 ? pairFor(output, path[i + 2],allowThirdPair) : _to;
    //         pair.swap(amount0Out, amount1Out, to, new bytes(0));
    //     }
    // }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual ensure(deadline) {
        (uint amountToPair,bool isThird) = routerHelper.calcAmountToPair(amountIn, path);
        _chargeFee(path[0],amountIn,amountToPair);

        TransferHelper.safeTransferFrom(path[0], msg.sender, routerHelper.pairFor(path[0], path[1]), amountToPair);
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        routerHelper.swap(msg.sender,path,to,isThird);
        require(IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,'ZooswapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
    external
    virtual
    payable
    ensure(deadline)
    {
        require(path[0] == WETH, 'ZooswapRouter: INVALID_PATH');
        uint amountIn = msg.value;
        (uint amountToPair,bool isThird) = routerHelper.calcAmountToPair(amountIn, path);

        IWETH(WETH).deposit{value : amountToPair}();
        assert(IWETH(WETH).transfer(routerHelper.pairFor(path[0], path[1]), amountToPair));
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        routerHelper.swap(msg.sender,path,to,isThird);

        require(IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,'ZooswapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
    external
    virtual
    ensure(deadline)
    {
        require(path[path.length - 1] == WETH, 'ZooswapRouter: INVALID_PATH');
        (uint amountToPair,bool isThird) = routerHelper.calcAmountToPair(amountIn, path);
        _chargeFee(path[0],amountIn,amountToPair);

        TransferHelper.safeTransferFrom(path[0], msg.sender, routerHelper.pairFor(path[0], path[1]), amountToPair);

        uint balanceBefore = IERC20(WETH).balanceOf(address(this));
        routerHelper.swap(msg.sender,path,address(this),isThird);        
        uint amountOut = IERC20(WETH).balanceOf(address(this)).sub(balanceBefore);
        require(amountOut >= amountOutMin, 'ZooswapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    function _chargeFee(address token,uint amountIn,uint amountToPair) internal {
        if(amountIn > amountToPair){
            TransferHelper.safeTransferFrom(token,msg.sender,address(this) , amountIn - amountToPair);
        }
    }

    // // **** LIBRARY FUNCTIONS ****
    // function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public view override returns (uint256 amountB) {
    //     return IZooswapFactory(factory).quote(amountA, reserveA, reserveB);
    // }

    // function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, address token0, address token1) public view override returns (uint256 amountOut){
    //     return IZooswapFactory(factory).getAmountOut(amountIn, reserveIn, reserveOut, token0, token1);
    // }

    // function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, address token0, address token1) public view override returns (uint256 amountIn){
    //     return IZooswapFactory(factory).getAmountIn(amountOut, reserveIn, reserveOut, token0, token1);
    // }

    // function getAmountsOut(uint256 amountIn, address[] memory path) public view override returns (uint256[] memory amounts){
    //     return IZooswapFactory(factory).getAmountsOut(amountIn, path);
    // }

    // function getAmountsIn(uint256 amountOut, address[] memory path) public view override returns (uint256[] memory amounts){
    //     return IZooswapFactory(factory).getAmountsIn(amountOut, path);
    // }

    // function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
    //     require(tokenA != tokenB, 'ZooswapRouter: IDENTICAL_ADDRESSES');
    //     (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    //     require(token0 != address(0), 'ZooswapRouter: ZERO_ADDRESS');
    // }

    function allPairsLength() public view returns(uint){
        return routerHelper.allPairsLength();
    }

    function getPair(address tokenA,address tokenB) external view returns(address,bool){
        return routerHelper.getPair(tokenA, tokenB);
    }

    // function getPairAddr(address tokenA,address tokenB) public view returns(address){
    //     (address pair,) = routerHelper.getPair(tokenA,tokenB);
    //     return pair;
    // }

    function getSwapPath(address tokenA,address tokenB,address[] calldata bridgeTokens) external view returns(address[] memory path,address[] memory pairPath, bool isThird){
        return routerHelper.getSwapPath(tokenA, tokenB, bridgeTokens);
    }

    function getAllPairs() public view returns(address[] memory pairs,bool[] memory isThirds, uint[] memory feeRateNumerators){
        return routerHelper.getAllPairs();
    }

    function getPairReserves(address[] calldata pairs) external view returns(address[] memory _tokens,uint[] memory _reserves){
        _tokens = new address[](pairs.length * 2);
        _reserves = new uint[](pairs.length * 2);
        for(uint i=0;i<pairs.length;i++){
            IZooswapPair pair = IZooswapPair(pairs[i]);
            _tokens[i*2] = pair.token0();
            _tokens[i*2+1] = pair.token1();

            (_reserves[i*2],_reserves[i*2+1],)= pair.getReserves();
        }
    }

    // function takeToken(address token,address to, uint amount) external onlyOwner {
    //     TransferHelper.safeTransfer(token,to,amount);
    // }

    // function takeETH(address to,uint amount)  external onlyOwner {
    //     TransferHelper.safeTransferETH(to,amount);
    // }

    // function setrouterHelper(address _routerHelper) public onlyOwner {
    //     require(_routerHelper != address(0),"_routerHelper can not be address 0");
    //     routerHelper = ISwaprouterHelper(_routerHelper);
    // }
}