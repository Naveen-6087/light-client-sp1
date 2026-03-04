// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BlockHashOracle} from "../src/BlockHashOracle.sol";
import {SP1EthereumLightClient} from "../src/SP1EthereumLightClient.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";

/// @title MockSP1VerifierBHO — mock verifier for BlockHashOracle tests.
contract MockSP1VerifierBHO is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure override {}
}

/// @title BlockHashOracleTest
/// @notice Tests for the BlockHashOracle contract and its integration
///         with SP1EthereumLightClient's block inclusion proof feature.
contract BlockHashOracleTest is Test {
    BlockHashOracle public oracle;
    SP1EthereumLightClient public lightClient;
    MockSP1VerifierBHO public mockVerifier;

    bytes32 constant PROGRAM_VKEY = bytes32(uint256(0xabcd));
    uint32 constant MIN_PARTICIPATION = 342;

    function setUp() public {
        mockVerifier = new MockSP1VerifierBHO();
        lightClient = new SP1EthereumLightClient(
            address(mockVerifier),
            PROGRAM_VKEY,
            MIN_PARTICIPATION
        );
        oracle = new BlockHashOracle(address(lightClient));
    }

    // =========================================================================
    // Helper: Compute commitment the same way the zkVM does
    // =========================================================================

    function _computeCommitment(
        uint64[] memory blockNumbers,
        bytes32[] memory blockHashValues
    ) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < blockNumbers.length; i++) {
            packed = abi.encodePacked(packed, bytes8(blockNumbers[i]), blockHashValues[i]);
        }
        return keccak256(packed);
    }

    // =========================================================================
    // Deployment Tests
    // =========================================================================

    function test_oracle_deployment() public view {
        assertEq(oracle.lightClient(), address(lightClient));
        assertEq(oracle.latestBlockNumber(), 0);
        assertEq(oracle.earliestBlockNumber(), type(uint256).max);
    }

    // =========================================================================
    // submitBlockHashes Tests
    // =========================================================================

    function test_submit_single_block_hash() public {
        uint64[] memory nums = new uint64[](1);
        bytes32[] memory hashes = new bytes32[](1);
        nums[0] = 1000;
        hashes[0] = bytes32(uint256(0xaaaa));

        bytes32 commitment = _computeCommitment(nums, hashes);

        oracle.submitBlockHashes(nums, hashes, commitment);

        assertEq(oracle.getBlockHash(1000), bytes32(uint256(0xaaaa)));
        assertTrue(oracle.isBlockVerified(1000));
        assertEq(oracle.latestBlockNumber(), 1000);
        assertEq(oracle.earliestBlockNumber(), 1000);
    }

    function test_submit_multiple_block_hashes() public {
        uint64[] memory nums = new uint64[](3);
        bytes32[] memory hashes = new bytes32[](3);
        nums[0] = 100;
        nums[1] = 101;
        nums[2] = 102;
        hashes[0] = bytes32(uint256(0x1111));
        hashes[1] = bytes32(uint256(0x2222));
        hashes[2] = bytes32(uint256(0x3333));

        bytes32 commitment = _computeCommitment(nums, hashes);

        oracle.submitBlockHashes(nums, hashes, commitment);

        assertEq(oracle.getBlockHash(100), bytes32(uint256(0x1111)));
        assertEq(oracle.getBlockHash(101), bytes32(uint256(0x2222)));
        assertEq(oracle.getBlockHash(102), bytes32(uint256(0x3333)));
        assertEq(oracle.earliestBlockNumber(), 100);
        assertEq(oracle.latestBlockNumber(), 102);
    }

    function test_submit_reverts_on_duplicate_commitment() public {
        uint64[] memory nums = new uint64[](1);
        bytes32[] memory hashes = new bytes32[](1);
        nums[0] = 500;
        hashes[0] = bytes32(uint256(0xbeef));

        bytes32 commitment = _computeCommitment(nums, hashes);
        oracle.submitBlockHashes(nums, hashes, commitment);

        vm.expectRevert(
            abi.encodeWithSelector(
                BlockHashOracle.CommitmentAlreadyProcessed.selector,
                commitment
            )
        );
        oracle.submitBlockHashes(nums, hashes, commitment);
    }

    function test_submit_reverts_on_commitment_mismatch() public {
        uint64[] memory nums = new uint64[](1);
        bytes32[] memory hashes = new bytes32[](1);
        nums[0] = 500;
        hashes[0] = bytes32(uint256(0xbeef));

        bytes32 wrongCommitment = bytes32(uint256(0xdead));

        vm.expectRevert(
            abi.encodeWithSelector(
                BlockHashOracle.CommitmentMismatch.selector,
                wrongCommitment,
                _computeCommitment(nums, hashes)
            )
        );
        oracle.submitBlockHashes(nums, hashes, wrongCommitment);
    }

    function test_submit_reverts_on_empty() public {
        uint64[] memory nums = new uint64[](0);
        bytes32[] memory hashes = new bytes32[](0);

        vm.expectRevert(BlockHashOracle.EmptyBlockData.selector);
        oracle.submitBlockHashes(nums, hashes, bytes32(0));
    }

    function test_submit_reverts_on_length_mismatch() public {
        uint64[] memory nums = new uint64[](2);
        bytes32[] memory hashes = new bytes32[](1);
        nums[0] = 1;
        nums[1] = 2;
        hashes[0] = bytes32(uint256(0x1));

        vm.expectRevert(BlockHashOracle.InvalidBlockDataLength.selector);
        oracle.submitBlockHashes(nums, hashes, bytes32(0));
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    function test_verify_block_hash() public {
        uint64[] memory nums = new uint64[](1);
        bytes32[] memory hashes = new bytes32[](1);
        nums[0] = 777;
        hashes[0] = bytes32(uint256(0xcafe));

        bytes32 commitment = _computeCommitment(nums, hashes);
        oracle.submitBlockHashes(nums, hashes, commitment);

        assertTrue(oracle.verifyBlockHash(777, bytes32(uint256(0xcafe))));
        assertFalse(oracle.verifyBlockHash(777, bytes32(uint256(0xdead))));
        assertFalse(oracle.verifyBlockHash(888, bytes32(uint256(0xcafe))));
    }

    function test_unverified_block_returns_zero() public view {
        assertEq(oracle.getBlockHash(999), bytes32(0));
        assertFalse(oracle.isBlockVerified(999));
    }

    function test_get_stored_range() public {
        uint64[] memory nums = new uint64[](2);
        bytes32[] memory hashes = new bytes32[](2);
        nums[0] = 50;
        nums[1] = 100;
        hashes[0] = bytes32(uint256(0x1));
        hashes[1] = bytes32(uint256(0x2));

        bytes32 commitment = _computeCommitment(nums, hashes);
        oracle.submitBlockHashes(nums, hashes, commitment);

        (uint256 earliest, uint256 latest) = oracle.getStoredRange();
        assertEq(earliest, 50);
        assertEq(latest, 100);
    }

    // =========================================================================
    // Integration: Light Client → Block Hash Oracle
    // =========================================================================

    function test_e2e_block_inclusion_flow() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(uint256(0xaa)), bytes32(uint256(0xbb)), scHash);

        // Simulate block hashes
        uint64[] memory nums = new uint64[](3);
        bytes32[] memory hashes = new bytes32[](3);
        nums[0] = 18000000;
        nums[1] = 18000001;
        nums[2] = 18000002;
        hashes[0] = bytes32(uint256(0xaaa1));
        hashes[1] = bytes32(uint256(0xbbb2));
        hashes[2] = bytes32(uint256(0xccc3));

        bytes32 commitment = _computeCommitment(nums, hashes);

        // Step 1: Submit a light client update with block inclusion proof data
        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;
        pv.numVerifiedBlocks = 3;
        pv.blockInclusionStart = 18000000;
        pv.blockInclusionEnd = 18000002;
        pv.blockHashCommitment = commitment;

        lightClient.update(abi.encode(pv), hex"");

        // Step 2: Verify the commitment was stored in the light client
        assertEq(lightClient.getBlockHashCommitment(200), commitment);

        // Step 3: Submit block hashes to the oracle
        oracle.submitBlockHashes(nums, hashes, commitment);

        // Step 4: Verify all blocks are accessible
        assertEq(oracle.getBlockHash(18000000), bytes32(uint256(0xaaa1)));
        assertEq(oracle.getBlockHash(18000001), bytes32(uint256(0xbbb2)));
        assertEq(oracle.getBlockHash(18000002), bytes32(uint256(0xccc3)));
        assertTrue(oracle.isBlockVerified(18000000));
        assertTrue(oracle.isBlockVerified(18000001));
        assertTrue(oracle.isBlockVerified(18000002));

        console.log("=== E2E Block Inclusion Flow ===");
        console.log("Light client update with block inclusion: PASSED");
        console.log("Block hash oracle storage: PASSED");
        console.log("Individual block hash queries: PASSED");
    }

    function test_light_client_stores_block_hash_commitment() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        bytes32 commitment = bytes32(uint256(0xdeadbeef));

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;
        pv.numVerifiedBlocks = 5;
        pv.blockInclusionStart = 1000;
        pv.blockInclusionEnd = 1004;
        pv.blockHashCommitment = commitment;

        lightClient.update(abi.encode(pv), hex"");

        assertEq(lightClient.getBlockHashCommitment(200), commitment);
    }

    function test_no_block_inclusion_leaves_commitment_zero() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;
        // numVerifiedBlocks = 0 (default)

        lightClient.update(abi.encode(pv), hex"");

        assertEq(lightClient.getBlockHashCommitment(200), bytes32(0));
    }
}
