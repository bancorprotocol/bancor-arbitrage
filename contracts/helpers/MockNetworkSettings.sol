// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Token } from "../token/Token.sol";

contract MockNetworkSettings {
    // mapping for flashloan-whitelisted tokens
    mapping(Token => bool) public isTokenWhitelisted;

    /**
     * @dev add token to whitelist for flashloans
     */
    function addToWhitelist(address token) external {
        isTokenWhitelisted[Token(token)] = true;
    }

    /**
     * @dev remove token from whitelist for flashloans
     */
    function removeFromWhitelist(address token) external {
        isTokenWhitelisted[Token(token)] = false;
    }
}
