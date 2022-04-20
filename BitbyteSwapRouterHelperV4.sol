// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import './interfaces/IZooswapFactoryV4.sol';
import './interfaces/IZooswapPairV4.sol';
import './interfaces/ISwapMiningV4.sol';
import './interfaces/IWETH.sol';
import './interfaces/IERC20.sol';
import './libs/SafeMath.sol';
import './libs/TransferHelper.sol';
import './interfaces/IBitbyteSwapRouterHelper.sol';
import '../libs/Adminable.sol';

contract BitbyteSwapRouterHelperV4 is Adminable,IBitbyteSwapRouterHelper {
    using SafeMath for uint256;

    address public immutable factory;
    // address public immutable WETH;

    address public immutable thirdFactory;    
    mapping(uint256 => address) public allThirdPairs;
    uint256 public allThirdPairsLength;
    mapping(address => mapping(address => uint256)) public thirdPairIndexOf;
    mapping(address => mapping(address => uint256)) public speacialFeeRateOf;
    mapping(address => mapping(address => bool)) public isSpeacialFeeRate;

    uint256 public constant feeRateDenominator = 10000;
    uint256 public constant thirdFeeRate = 25;
    uint256 public constant feeRateCap = 10000 - thirdFeeRate;
    uint256 public defaultFeeRate = 10;

    address public swapMining;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'ZooswapRouter: EXPIRED');
        _;
    }

    event PairAdded(address token0,address token1,address pair);
    event PairRemoved(address token0,address token1,address pair);

    constructor(
        address _factory,
        address _thirdFactory
    ) {
        factory = _factory;
        thirdFactory = _thirdFactory;
    }

    // receive() external payable {
    //     assert(msg.sender == WETH);
    //     // only accept BNB via fallback from the WETH contract
    // }  

    function _getReserves(address thirdPair,address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = _sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IZooswapPair(thirdPair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function _calcAmountOut(uint amountIn, uint reserveIn, uint reserveOut,uint fn,uint fd) internal pure returns (uint amountOut) {
        require(amountIn > 0, '_calcAmountOut: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, '_calcAmountOut: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(fn);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(fd).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function _calcAmountIn(uint amountOut, uint reserveIn, uint reserveOut,uint fn,uint fd) internal pure returns (uint amountIn) {
        require(amountOut > 0, '_calcAmountIn: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, '_calcAmountIn: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(fd);
        uint denominator = reserveOut.sub(amountOut).mul(fn);
        amountIn = (numerator / denominator).add(1);
    }

    // function calcAmounts(address thirdPair,uint amountIn,uint amountOut, address[] memory path,bool useInCalcOut) public view returns(uint[] memory _amounts997,uint[] memory _amounts){
    //     require(path.length ==2 ,"calcAmounts: invalid path length");
    //     _amounts997 = new uint[](2);
    //     _amounts = new uint[](2);
    //     (uint reserveIn, uint reserveOut) = _getReserves(thirdPair,path[0],path[1]);
    //     uint fn = swapTotalFeeRate;
    //     if(useInCalcOut){
    //         _amounts997[0] = amountIn;
    //         _amounts997[1] = _calcAmountOut(amountIn, reserveIn, reserveOut,fn,10000);
    //         _amounts[0] = amountIn;
    //         _amounts[1] = _calcAmountOut(amountIn, reserveIn, reserveOut,9975,10000);
    //     }else{
    //         _amounts997[0] = _calcAmountIn(amountOut, reserveIn, reserveOut,fn,10000);
    //         _amounts997[1] = amountOut;
    //         _amounts[0] = _amounts997[0];
    //         _amounts[1] = _calcAmountOut( _amounts997[0], reserveIn, reserveOut,9975,10000);
    //     }
    // }

    function pairFor(address tokenA,address tokenB) public view override returns(address) {
        (address token0,address token1) = _sortTokens(tokenA,tokenB);
        uint index = thirdPairIndexOf[token0][token1];
        if(index > 0) {
            return allThirdPairs[index];
        }

        return IZooswapFactory(factory).pairFor(tokenA, tokenB); 
    }

    function _isThirdPair(address tokenA,address tokenB) public view returns(bool){
        (address token0,address token1) = _sortTokens(tokenA, tokenB);
        return thirdPairIndexOf[token0][token1] > 0;
    }

    function calcAmountToPair(uint originalAmountIn,address[] calldata path) external view override returns(uint amountToPair,bool isThirdPair){
        isThirdPair = _isThirdPair(path[0], path[1]);
        uint feeRate_ = isThirdPair ? getFeeRate(path[0], path[1]) : 0;
        amountToPair = originalAmountIn * (feeRateCap - feeRate_) / feeRateCap;
    }

    function calcAmountToPairByOut(uint amountOut,address[] calldata path) external view override returns(uint allAmountIn,uint amountToPair,bool isThirdPair){
        isThirdPair = _isThirdPair(path[0], path[1]);        
        // (address token0,address token1) = _sortTokens(path[0], path[1]);
        address pair = isThirdPair ? IZooswapFactory(thirdFactory).getPair(path[0], path[1]) : IZooswapFactory(factory).pairFor(path[0], path[1]);
        (uint reserveIn,uint reserveOut) = _getReserves(pair, path[0], path[1]);
        if(isThirdPair){
            uint feeRate_ = isThirdPair ? getFeeRate(path[0], path[1]) : 0;
            amountToPair = _calcAmountIn(amountOut, reserveIn, reserveOut, feeRateCap, feeRateDenominator);
            allAmountIn = amountToPair * feeRateCap / (feeRateCap - feeRate_);
        }else{
            amountToPair = IZooswapFactory(factory).getAmountsIn(amountOut,path)[0];
            allAmountIn = amountToPair;
        }
    }

    function getFeeRate(address tokenA,address tokenB) public view returns(uint){
        (address token0,address token1) = _sortTokens(tokenA, tokenB);
        return isSpeacialFeeRate[token0][token1] ? speacialFeeRateOf[token0][token1] : defaultFeeRate;
    }

    function swap(address caller,address[] calldata path,address _to,bool isThird) external override {
        address factory_ = isThird ? thirdFactory : factory;
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = _sortTokens(input, output);
            IZooswapPair pair = IZooswapPair(IZooswapFactory(factory_).getPair(input, output));
            uint amountInput;
            uint amountOutput;
            {// scope to avoid stack too deep errors
                (uint reserve0, uint reserve1,) = pair.getReserves();
                (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
                if(isThird){
                    amountOutput = _calcAmountOut(amountInput, reserveInput, reserveOutput, feeRateCap, feeRateDenominator);
                }else{
                    amountOutput = IZooswapFactory(factory_).getAmountOut(amountInput, reserveInput, reserveOutput, input, output);
                }
            }
            if (swapMining != address(0)) {
                ISwapMining(swapMining).swap(caller, input, output, amountOutput);
            }
            _swap(pair,i,path,amountOutput,_to);
        }
    }

    function _swap(IZooswapPair pair,uint i,address[] calldata path, uint amountOutput,address _to) internal {
        (address token0,) = _sortTokens(path[i], path[i + 1]);
        (uint amount0Out, uint amount1Out) = path[i] == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
        address to = i < path.length - 2 ? pairFor(path[i + 1], path[i + 2]) : _to;
        pair.swap(amount0Out, amount1Out, to, new bytes(0));
    }

    function allPairs(uint index) public view returns(address){
        (address[] memory pairs,,) = getAllPairs();
        return index >= pairs.length ? address(0) : pairs[index];
    }

    function allPairsLength() public view override returns(uint){
        (address[] memory pairs,,) = getAllPairs();
        return pairs.length;
    }

    function getThirdPair(address tokenA,address tokenB) public view returns(address) {
        (address token0,address token1) = _sortTokens(tokenA,tokenB);
        uint index = thirdPairIndexOf[token0][token1];
        if(index == 0) {
            return address(0);
        }

        return allThirdPairs[index]; 
    }

    function getPair(address tokenA,address tokenB) public view override returns(address,bool){
        address pair =  getThirdPair(tokenA,tokenB);
        if(pair == address(0)){
            return (IZooswapFactory(factory).getPair(tokenA,tokenB),false);
        }else{
            return (pair,true);
        }
    }

    function getSwapPath(address tokenA,address tokenB,address[] calldata bridgeTokens) external view override returns(address[] memory path,address[] memory pairPath, bool isThird){        
        (address pair,bool isThird_) = getPair(tokenA, tokenB);
        if(pair != address(0)){
            path = new address[](2);
            path[0] = tokenA;
            path[1] = tokenB;
            pairPath = new address[](1);
            pairPath[0] = pair;
            isThird = isThird_;
        }else{
            for(uint i=0;i<bridgeTokens.length;i++){
                (pair,isThird_) = getPair(tokenA, bridgeTokens[i]);
                if(pair == address(0)){
                    continue;
                }

                address factory_ = isThird_ ? thirdFactory : factory;
                address pair2 = IZooswapFactory(factory_).getPair(bridgeTokens[i], tokenB);
                if(pair2 != address(0)){
                    path = new address[](3);
                    path[0] = tokenA;
                    path[1] = bridgeTokens[i];
                    path[2] = tokenB;
                    pairPath = new address[](2);
                    pairPath[0] = pair;
                    pairPath[1] = pair2;
                    isThird = isThird_;

                    break;
                }
            }
        }
    }
    
    function getAllPairs() public view override returns(address[] memory pairs,bool[] memory isThirds, uint[] memory feeRateNumerators){
        uint zlen = IZooswapFactory(factory).allPairsLength();
        uint tlen = allThirdPairsLength;
        uint len = zlen + tlen;
        uint rlen = len;
        address[] memory allParis_ = new address[](len);
        bool[] memory allIsThirds_ = new bool[](len);
        uint[] memory allFeeRates_ = new uint[](len);
        for(uint i=0;i<zlen;i++){
            address zpair = IZooswapFactory(factory).allPairs(i);
            (address token0,address token1) = (IZooswapPair(zpair).token0(),IZooswapPair(zpair).token1());

            uint zindex = thirdPairIndexOf[token0][token1];
            if(zindex == 0){
                allParis_[i] = zpair;
                allFeeRates_[i] = IZooswapFactory(factory).getPairFees(zpair);
                allIsThirds_[i] = false;
            }else {
                allParis_[zlen + zindex - 1] = allThirdPairs[zindex];
                allFeeRates_[zlen + zindex - 1] = getFeeRate(token0,token1);
                allIsThirds_[i] = true;
                rlen -= 1;
            }
        }
        for(uint i=1;i<=tlen;i++){
            allParis_[zlen + i - 1] = allThirdPairs[i];
            (address token0,address token1) = (IZooswapPair(allThirdPairs[i]).token0(),IZooswapPair(allThirdPairs[i]).token1());
            allFeeRates_[zlen + i - 1] = getFeeRate(token0,token1);
            allIsThirds_[i] = true;
        }

        pairs = new address[](rlen);
        feeRateNumerators = new uint[](rlen);
        isThirds = new bool[](len);
        uint pushed = 0;
        for(uint i=0;i<len;i++){
            if(allParis_[i] != address(0)){                
                pairs[pushed] = allParis_[i];
                feeRateNumerators[pushed] = allFeeRates_[i];
                isThirds[pushed] = allIsThirds_[i];

                pushed += 1;
            }
        }
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'router simulater: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'router simulater: ZERO_ADDRESS');
    }

    function addThirdPair(address tokenA,address tokenB) external onlyAdmin {
        (address token0,address token1) = _sortTokens(tokenA,tokenB);
        address pair = IZooswapFactory(thirdFactory).getPair(token0,token1);
        require(pair != address(0),"third factory has not pair of tokenA and tokenB");
        require(thirdPairIndexOf[token0][token1] == 0,"pair already exist");
        uint oldLen = allThirdPairsLength;
        allThirdPairs[oldLen + 1] = pair;
        thirdPairIndexOf[token0][token1] = oldLen + 1;        
        allThirdPairsLength = oldLen + 1;

        emit PairAdded(token0, token1, pair);
    }

    function removeThirdPair(address tokenA,address tokenB) external onlyAdmin {
        (address token0,address token1) = _sortTokens(tokenA,tokenB);
        uint index = thirdPairIndexOf[token0][token1];
        require(index > 0,"pair not exist");
        address pair = allThirdPairs[index];
        uint len = allThirdPairsLength;
        if(index != len){
            address lastPair = allThirdPairs[len];
            (address lastToken0,address lastToken1) = (IZooswapPair(lastPair).token0(),IZooswapPair(lastPair).token1());
            allThirdPairs[index] = lastPair;
            thirdPairIndexOf[lastToken0][lastToken1] = index;
        }

        allThirdPairsLength = allThirdPairsLength - 1;
        delete allThirdPairs[len];
        delete thirdPairIndexOf[token0][token1];

        emit PairRemoved(token0, token1, pair);
    }

    function setDefaultFeeRate(uint feeRate) public onlyAdmin {
        require(feeRate < feeRateCap,"fee rate must less than feeRateCap");
        defaultFeeRate = feeRate;
    }

    function addSpeacialFeeRate(address tokenA,address tokenB,uint feeRate) external onlyAdmin {
        require(feeRate < feeRateCap,"fee rate must less than feeRateCap");
        (address token0,address token1) = _sortTokens(tokenA, tokenB);
        isSpeacialFeeRate[token0][token1] = true;
        speacialFeeRateOf[token0][token1] = feeRate;
    }

    function removeSpeacialFeeRate(address tokenA,address tokenB) external onlyAdmin {
        (address token0,address token1) = _sortTokens(tokenA, tokenB);
        isSpeacialFeeRate[token0][token1] = false;
        speacialFeeRateOf[token0][token1] = 0;
    }

    function setSwapMining(address _swapMining) external onlyAdmin {
        swapMining = _swapMining;
    }
}