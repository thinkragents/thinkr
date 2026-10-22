// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The slice of the ERC-8004 identity registry THINKR depends on.
/// @dev The registry is ERC-721 shaped, so an agent's owner is its token owner.
///      `ownerOf` reverts for an agent that was never registered, which is the
///      check we want: you cannot bond an identity that does not exist.
interface IIdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
}
