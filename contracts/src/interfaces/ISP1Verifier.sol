// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISP1Verifier
/// @notice Interface for the SP1 on-chain proof verifier.
/// @dev SP1 deploys canonical verifier contracts. This interface is used to call them.
interface ISP1Verifier {
    /// @notice Verifies an SP1 proof.
    /// @param programVKey The verification key of the SP1 program.
    /// @param publicValues The ABI-encoded public values committed by the program.
    /// @param proofBytes The encoded proof bytes (Groth16 or PLONK).
    function verifyProof(
        bytes32 programVKey,
        bytes calldata publicValues,
        bytes calldata proofBytes
    ) external view;
}
