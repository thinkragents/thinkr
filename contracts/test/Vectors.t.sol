// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Merkle} from "./Merkle.sol";

/// @notice Writes the tree vectors the JavaScript SDK is tested against. The contract
///         is the authority on the format; `sdk/tree.js` has to match it, not the
///         other way round. Run `forge test --match-contract Vectors` to regenerate.
contract VectorsTest is Test {
    function test_write_vectors() public {
        bytes32[4] memory payments = [
            keccak256("payment-a"),
            keccak256("payment-b"),
            keccak256("payment-c"),
            keccak256("payment-d")
        ];
        bytes32[4] memory responses = [
            keccak256("response-a"),
            keccak256("response-b"),
            keccak256("response-c"),
            keccak256("response-d")
        ];

        bytes32[4] memory leaves;
        for (uint256 i; i < 4; ++i) {
            leaves[i] = Merkle.leaf(payments[i], responses[i]);
        }

        string memory obj = "v";
        vm.serializeBytes32(obj, "payments", _toDyn(payments));
        vm.serializeBytes32(obj, "responses", _toDyn(responses));
        vm.serializeBytes32(obj, "leaves", _toDyn(leaves));
        vm.serializeBytes32(obj, "proof0", Merkle.proof4(leaves, 0));
        string memory out = vm.serializeBytes32(obj, "root", Merkle.root4(leaves));

        vm.writeJson(out, "./sdk/vectors.json");
    }

    function _toDyn(bytes32[4] memory a) private pure returns (bytes32[] memory d) {
        d = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            d[i] = a[i];
        }
    }
}
