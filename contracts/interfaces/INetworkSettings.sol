// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Token } from "../token/Token.sol";

/**
 * NetworkSettings interface
 */
interface INetworkSettings {
    /**
     * @dev checks whether a given token is whitelisted
     */
    function isTokenWhitelisted(Token pool) external view returns (bool);
}
