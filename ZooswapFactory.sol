
// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0 <0.8.0;

import './interfaces/IZooswapFactory.sol';
import './libs/EnumerableSet.sol';
import './ZooswapPair.sol';

contract ZooswapFactory is IZooswapFactory {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _supportList;

    uint256 public constant FEE_RATE_DENOMINATOR = 1e4;
    uint256 public feeRateNumerator = 30;
    address public feeTo;
    address public feeToSetter;
    //uint256 public feeToRate = 5;
    //default (denominator - 1) of platform fee rate,numerator is 1
    uint256 public feeToRate = 0;
    bytes32 public initCodeHash;

    //(denominator - 1) of platform fee rates,numerator is 1
    mapping(address => uint256) public pairFeeToRate;
    mapping(address => uint256) public pairFees;
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor() public {
        feeToSetter = msg.sender;
        feeTo = msg.sender;
        initCodeHash = keccak256(abi.encodePacked(type(ZooswapPair).creationCode));
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'ZooswapFactory: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'ZooswapFactory: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'ZooswapFactory: PAIR_EXISTS');
        // single check is sufficient
        bytes memory bytecode = type(ZooswapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IZooswapPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(_feeToSetter != address(0), "ZooswapFactory: FeeToSetter is zero address");
        feeToSetter = _feeToSetter;
    }

    function addPair(address pair) external returns (bool){
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(pair != address(0), 'ZooswapFactory: pair is the zero address');
        return EnumerableSet.add(_supportList, pair);
    }

    function delPair(address pair) external returns (bool){
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(pair != address(0), 'ZooswapFactory: pair is the zero address');
        return EnumerableSet.remove(_supportList, pair);
    }

    function getSupportListLength() public view returns (uint256) {
        return EnumerableSet.length(_supportList);
    }

    function isSupportPair(address pair) public view returns (bool){
        return EnumerableSet.contains(_supportList, pair);
    }

    function getSupportPair(uint256 index) external view returns (address) {
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(index <= getSupportListLength() - 1, "index out of bounds");
        return EnumerableSet.at(_supportList, index);
    }

    // Set default fee ，max is 0.3%
    function setFeeRateNumerator(uint256 _feeRateNumerator) external {
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(_feeRateNumerator < FEE_RATE_DENOMINATOR, "ZooswapFactory: EXCEEDS_FEE_RATE_DENOMINATOR");
        feeRateNumerator = _feeRateNumerator;
    }

    // Set pair fee , max is 0.3%
    function setPairFees(address pair, uint256 fee) external {
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(fee < FEE_RATE_DENOMINATOR, 'ZooswapFactory: EXCEEDS_FEE_RATE_DENOMINATOR');
        pairFees[pair] = fee;
    }

    // Set the default fee rate ，if set to 1/10 no handling fee
    function setDefaultFeeToRate(uint256 rate) external {
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(rate > 0 && rate <= 10, "ZooswapFactory: FEE_TO_RATE_OVERFLOW");
        feeToRate = rate.sub(1);
    }

    // Set the commission rate of the pair ，if set to 1/10 no handling fee
    function setPairFeeToRate(address pair, uint256 rate) external {
        require(msg.sender == feeToSetter, 'ZooswapFactory: FORBIDDEN');
        require(rate > 0 && rate <= 10, "ZooswapFactory: FEE_TO_RATE_OVERFLOW");
        pairFeeToRate[pair] = rate.sub(1);
    }

    //get swap fee rate
    function getPairFees(address pair) public view returns (uint256){
        require(pair != address(0), 'ZooswapFactory: pair is the zero address');
        if (isSupportPair(pair)) {
            return pairFees[pair];
        } else {
            return feeRateNumerator;
        }
    }

    //get platform fee rate
    function getPairRate(address pair) external view returns (uint256) {
        require(pair != address(0), 'ZooswapFactory: pair is the zero address');
        if (isSupportPair(pair)) {
            return pairFeeToRate[pair];
        } else {
            return feeToRate;
        }
    }

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'ZooswapFactory: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'ZooswapFactory: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                address(this),
                keccak256(abi.encodePacked(token0, token1)),
                initCodeHash
            ))));
    }
    
    // fetches and sorts the reserves for a pair
    function getReserves(address tokenA, address tokenB) public view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IZooswapPair(pairFor(tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) public pure returns (uint amountB) {
        require(amountA > 0, 'ZooswapFactory: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'ZooswapFactory: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, address token0, address token1) public view returns (uint amountOut) {
        require(amountIn > 0, 'ZooswapFactory: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'ZooswapFactory: INSUFFICIENT_LIQUIDITY');
        uint256 fee = getPairFees(pairFor(token0, token1));
        uint amountInWithFee = amountIn.mul(FEE_RATE_DENOMINATOR.sub(fee));
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(FEE_RATE_DENOMINATOR).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut, address token0, address token1) public view returns (uint amountIn) {
        require(amountOut > 0, 'ZooswapFactory: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'ZooswapFactory: INSUFFICIENT_LIQUIDITY');
        uint256 fee = getPairFees(pairFor(token0, token1));
        uint numerator = reserveIn.mul(amountOut).mul(FEE_RATE_DENOMINATOR);
        uint denominator = reserveOut.sub(amountOut).mul(FEE_RATE_DENOMINATOR.sub(fee));
        amountIn = (numerator / denominator).add(1);
    }
    
    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, 'ZooswapFactory: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, path[i], path[i + 1]);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(uint amountOut, address[] memory path) public view returns (uint[] memory amounts) {
        require(path.length >= 2, 'ZooswapFactory: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, path[i - 1], path[i]);
        }
    }
}