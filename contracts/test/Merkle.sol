// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal builder for the tree shape the contract verifies: leaves are
///      double-hashed, pairs are sorted before hashing. Same convention as
///      OpenZeppelin's MerkleProof and merkletreejs, so the off-chain SDK and these
///      tests cannot drift.
library Merkle {
    function leaf(bytes32 ref, bytes32 digest) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(ref, digest))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Root of a 4-leaf tree.
    function root4(bytes32[4] memory l) internal pure returns (bytes32) {
        return pair(pair(l[0], l[1]), pair(l[2], l[3]));
    }

    /// @dev Proof for index `i` of a 4-leaf tree.
    function proof4(bytes32[4] memory l, uint256 i) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        if (i == 0) {
            p[0] = l[1];
            p[1] = pair(l[2], l[3]);
        } else if (i == 1) {
            p[0] = l[0];
            p[1] = pair(l[2], l[3]);
        } else if (i == 2) {
            p[0] = l[3];
            p[1] = pair(l[0], l[1]);
        } else {
            p[0] = l[2];
            p[1] = pair(l[0], l[1]);
        }
    }
}
