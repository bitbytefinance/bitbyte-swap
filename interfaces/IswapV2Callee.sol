
// SPDX-License-Identifier: MIT

pragma solidity >=0.5.0;

interface IswapV2Callee {
    function swapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external;
}