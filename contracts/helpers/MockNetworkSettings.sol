// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

contract MockNetworkSettings {
    // mapping for flashloan-whitelisted tokens
    mapping(address => bool) public isWhitelisted;

    error NotWhitelisted();

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
}
