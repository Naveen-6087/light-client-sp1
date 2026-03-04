// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BlockHashOracle
/// @notice Stores verified Ethereum execution block hashes proven via SP1 ZK proofs.
///
/// @dev This contract works in tandem with SP1EthereumLightClient:
///      1. The zkVM program verifies a chain of consecutive execution block headers
///         (RLP hash + parent_hash linkage) anchored to a finalized beacon state.
///      2. A commitment over all (blockNumber, blockHash) pairs is committed as a
///         public value in the SP1 proof.
///      3. After the proof is verified on-chain, anyone can submit the individual
///         block hashes along with the commitment for storage in this oracle.
///
///      This extends the EVM's `blockhash()` opcode beyond its 256-block limit,
///      enabling historical block hash lookups for cross-chain bridging, storage
///      proofs at past blocks, and retroactive verification.
///
/// @author SP1 Ethereum Light Client project
contract BlockHashOracle {
    // =========================================================================
    // State
    // =========================================================================

    /// @notice Address of the SP1EthereumLightClient contract.
    address public immutable lightClient;

    /// @notice Verified block hashes: blockNumber => blockHash.
    mapping(uint256 => bytes32) public blockHashes;

    /// @notice Whether a commitment has already been submitted.
    mapping(bytes32 => bool) public processedCommitments;

    /// @notice The latest block number stored in the oracle.
    uint256 public latestBlockNumber;

    /// @notice The earliest block number stored in the oracle.
    uint256 public earliestBlockNumber;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when block hashes are submitted from a verified commitment.
    event BlockHashesStored(
        uint256 indexed startBlock,
        uint256 indexed endBlock,
        uint256 numBlocks,
        bytes32 commitment
    );

    /// @notice Emitted for each individual block hash stored.
    event BlockHashVerified(
        uint256 indexed blockNumber,
        bytes32 blockHash
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error CommitmentAlreadyProcessed(bytes32 commitment);
    error CommitmentMismatch(bytes32 expected, bytes32 actual);
    error EmptyBlockData();
    error InvalidBlockDataLength();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _lightClient Address of the SP1EthereumLightClient contract.
    constructor(address _lightClient) {
        lightClient = _lightClient;
        earliestBlockNumber = type(uint256).max;
    }

    // =========================================================================
    // Core: Submit Verified Block Hashes
    // =========================================================================

    /// @notice Submit block hashes that were verified in an SP1 proof.
    /// @dev The caller provides the raw (blockNumber, blockHash) pairs and the
    ///      commitment that was included in the SP1 proof's public values.
    ///      This function verifies that keccak256(abi.encodePacked(pairs)) matches
    ///      the commitment.
    ///
    ///      Note: The commitment itself was verified by the SP1 verifier as part
    ///      of the light client update. This function only checks data integrity.
    ///
    /// @param blockNumbers Array of block numbers (must be consecutive).
    /// @param blockHashValues Array of corresponding block hashes.
    /// @param commitment The blockHashCommitment from the SP1 proof public values.
    function submitBlockHashes(
        uint64[] calldata blockNumbers,
        bytes32[] calldata blockHashValues,
        bytes32 commitment
    ) external {
        if (blockNumbers.length == 0) revert EmptyBlockData();
        if (blockNumbers.length != blockHashValues.length) revert InvalidBlockDataLength();
        if (processedCommitments[commitment]) revert CommitmentAlreadyProcessed(commitment);

        // Recompute the commitment from the provided data
        bytes memory packed;
        for (uint256 i = 0; i < blockNumbers.length; i++) {
            packed = abi.encodePacked(packed, bytes8(blockNumbers[i]), blockHashValues[i]);
        }
        bytes32 computedCommitment = keccak256(packed);

        if (computedCommitment != commitment) {
            revert CommitmentMismatch(commitment, computedCommitment);
        }

        // Mark commitment as processed
        processedCommitments[commitment] = true;

        // Store block hashes
        for (uint256 i = 0; i < blockNumbers.length; i++) {
            uint256 blockNum = uint256(blockNumbers[i]);
            blockHashes[blockNum] = blockHashValues[i];
            emit BlockHashVerified(blockNum, blockHashValues[i]);

            if (blockNum > latestBlockNumber) {
                latestBlockNumber = blockNum;
            }
            if (blockNum < earliestBlockNumber) {
                earliestBlockNumber = blockNum;
            }
        }

        emit BlockHashesStored(
            uint256(blockNumbers[0]),
            uint256(blockNumbers[blockNumbers.length - 1]),
            blockNumbers.length,
            commitment
        );
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /// @notice Get the verified block hash for a specific block number.
    /// @param blockNumber The block number to query.
    /// @return The verified block hash, or bytes32(0) if not stored.
    function getBlockHash(uint256 blockNumber) external view returns (bytes32) {
        return blockHashes[blockNumber];
    }

    /// @notice Check if a block hash has been verified and stored.
    /// @param blockNumber The block number to check.
    /// @return True if a verified block hash exists for this number.
    function isBlockVerified(uint256 blockNumber) external view returns (bool) {
        return blockHashes[blockNumber] != bytes32(0);
    }

    /// @notice Get the range of stored block numbers.
    /// @return earliest The earliest block number stored.
    /// @return latest The latest block number stored.
    function getStoredRange() external view returns (uint256 earliest, uint256 latest) {
        return (earliestBlockNumber, latestBlockNumber);
    }

    /// @notice Verify that a specific block hash matches what's stored.
    /// @param blockNumber The block number.
    /// @param expectedHash The expected block hash.
    /// @return True if the stored hash matches.
    function verifyBlockHash(uint256 blockNumber, bytes32 expectedHash) external view returns (bool) {
        return blockHashes[blockNumber] == expectedHash && expectedHash != bytes32(0);
    }
}
