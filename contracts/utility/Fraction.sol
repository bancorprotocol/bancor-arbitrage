// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

struct Fraction {
    uint256 n;
    uint256 d;
}

struct Fraction112 {
    uint112 n;
    uint112 d;
}

error InvalidFraction();
