// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Stands in for the ERC-8004 identity registry. Reverts on an unregistered
///      agent exactly as an ERC-721 `ownerOf` does.
contract MockRegistry {
    error NonexistentAgent();

    mapping(uint256 => address) private _owners;

    function register(uint256 agentId, address owner) external {
        _owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address o = _owners[agentId];
        if (o == address(0)) revert NonexistentAgent();
        return o;
    }
}
