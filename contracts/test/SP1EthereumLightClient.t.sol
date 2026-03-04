// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {SP1EthereumLightClient} from "../src/SP1EthereumLightClient.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";

/// @title MockSP1Verifier
/// @notice A mock verifier that always succeeds, for testing only.
contract MockSP1Verifier is ISP1Verifier {
    function verifyProof(
        bytes32,
        bytes calldata,
        bytes calldata
    ) external pure override {
        // Always succeeds — mock verifier
    }
}

/// @title SP1EthereumLightClientTest
/// @notice Tests for the on-chain Ethereum light client contract.
contract SP1EthereumLightClientTest is Test {
    SP1EthereumLightClient public lightClient;
    MockSP1Verifier public mockVerifier;

    bytes32 constant PROGRAM_VKEY = bytes32(uint256(0x1234));
    uint32 constant MIN_PARTICIPATION = 342; // 2/3 of 512

    function setUp() public {
        mockVerifier = new MockSP1Verifier();
        lightClient = new SP1EthereumLightClient(
            address(mockVerifier),
            PROGRAM_VKEY,
            MIN_PARTICIPATION
        );
    }

    // =========================================================================
    // Initialization Tests
    // =========================================================================

    function test_initialize() public {
        uint64 slot = 13724960;
        bytes32 headerRoot = bytes32(uint256(0xaabb));
        bytes32 stateRoot = bytes32(uint256(0xccdd));
        bytes32 scHash = bytes32(uint256(0xeeff));

        lightClient.initialize(slot, headerRoot, stateRoot, scHash);

        assertEq(lightClient.head(), slot);
        assertEq(lightClient.finalizedHeaderRoot(), headerRoot);
        assertEq(lightClient.finalizedStateRoot(), stateRoot);
        assertEq(lightClient.currentSyncCommitteeHash(), scHash);
        assertTrue(lightClient.initialized());
        assertTrue(lightClient.isSlotFinalized(slot));
    }

    function test_initialize_reverts_if_already_initialized() public {
        lightClient.initialize(100, bytes32(0), bytes32(0), bytes32(0));

        vm.expectRevert(SP1EthereumLightClient.AlreadyInitialized.selector);
        lightClient.initialize(200, bytes32(0), bytes32(0), bytes32(0));
    }

    // =========================================================================
    // Update Tests
    // =========================================================================

    function test_update_advances_head() public {
        // Initialize at slot 100
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(uint256(0xaa)), bytes32(uint256(0xbb)), scHash);

        // Create public values for slot 200
        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.nextSyncCommitteeHash = bytes32(0);
        pv.participation = 500;

        bytes memory publicValues = abi.encode(pv);
        bytes memory proofBytes = hex"dead"; // Mock verifier accepts anything

        lightClient.update(publicValues, proofBytes);

        assertEq(lightClient.head(), 200);
        assertEq(lightClient.finalizedHeaderRoot(), pv.finalizedHeaderRoot);
        assertEq(lightClient.finalizedStateRoot(), pv.finalizedStateRoot);
    }

    function test_update_reverts_if_not_initialized() public {
        bytes memory publicValues = new bytes(192);
        bytes memory proofBytes = hex"dead";

        vm.expectRevert(SP1EthereumLightClient.NotInitialized.selector);
        lightClient.update(publicValues, proofBytes);
    }

    function test_update_reverts_if_slot_not_newer() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(200, bytes32(0), bytes32(0), scHash);

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 100; // Older than head
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;

        bytes memory publicValues = abi.encode(pv);

        vm.expectRevert(
            abi.encodeWithSelector(
                SP1EthereumLightClient.SlotNotNewer.selector,
                uint64(200),
                uint64(100)
            )
        );
        lightClient.update(publicValues, hex"dead");
    }

    function test_update_reverts_if_insufficient_participation() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 100; // Below MIN_PARTICIPATION (342)

        bytes memory publicValues = abi.encode(pv);

        vm.expectRevert(
            abi.encodeWithSelector(
                SP1EthereumLightClient.InsufficientParticipation.selector,
                uint32(100),
                MIN_PARTICIPATION
            )
        );
        lightClient.update(publicValues, hex"dead");
    }

    function test_update_reverts_on_committee_mismatch() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.currentSyncCommitteeHash = bytes32(uint256(0x9999)); // Wrong committee
        pv.participation = 500;

        bytes memory publicValues = abi.encode(pv);

        vm.expectRevert(
            abi.encodeWithSelector(
                SP1EthereumLightClient.SyncCommitteeMismatch.selector,
                scHash,
                bytes32(uint256(0x9999))
            )
        );
        lightClient.update(publicValues, hex"dead");
    }

    // =========================================================================
    // Sync Committee Rotation Tests
    // =========================================================================

    function test_sync_committee_rotation() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        // Update with next sync committee
        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xaa));
        pv.finalizedStateRoot = bytes32(uint256(0xbb));
        pv.currentSyncCommitteeHash = scHash;
        pv.nextSyncCommitteeHash = bytes32(uint256(0x2222));
        pv.participation = 500;

        lightClient.update(abi.encode(pv), hex"dead");
        assertEq(lightClient.nextSyncCommitteeHash(), bytes32(uint256(0x2222)));

        // Now cross the period boundary: current = old next
        SP1EthereumLightClient.LightClientPublicValues memory pv2;
        pv2.finalizedSlot = 300;
        pv2.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv2.finalizedStateRoot = bytes32(uint256(0xdd));
        pv2.currentSyncCommitteeHash = bytes32(uint256(0x2222)); // Was nextSC
        pv2.nextSyncCommitteeHash = bytes32(uint256(0x3333));    // New next
        pv2.participation = 500;

        lightClient.update(abi.encode(pv2), hex"dead");

        // Current should now be 0x2222, next should be 0x3333
        assertEq(lightClient.currentSyncCommitteeHash(), bytes32(uint256(0x2222)));
        assertEq(lightClient.nextSyncCommitteeHash(), bytes32(uint256(0x3333)));
    }

    // =========================================================================
    // View Function Tests
    // =========================================================================

    function test_getState() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(uint256(0xaa)), bytes32(uint256(0xbb)), scHash);

        (uint64 h, bytes32 hr, bytes32 sr, bytes32 csc, bytes32 nsc) = lightClient.getState();
        assertEq(h, 100);
        assertEq(hr, bytes32(uint256(0xaa)));
        assertEq(sr, bytes32(uint256(0xbb)));
        assertEq(csc, scHash);
        assertEq(nsc, bytes32(0));
    }

    function test_historical_roots() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(uint256(0xaa)), bytes32(uint256(0xbb)), scHash);

        // Update to slot 200
        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;

        lightClient.update(abi.encode(pv), hex"dead");

        // Both slots should be queryable
        assertEq(lightClient.getFinalizedHeaderRoot(100), bytes32(uint256(0xaa)));
        assertEq(lightClient.getFinalizedHeaderRoot(200), bytes32(uint256(0xcc)));
        assertEq(lightClient.getFinalizedStateRoot(100), bytes32(uint256(0xbb)));
        assertEq(lightClient.getFinalizedStateRoot(200), bytes32(uint256(0xdd)));

        // Unverified slot returns zero
        assertEq(lightClient.getFinalizedHeaderRoot(150), bytes32(0));
    }

    // =========================================================================
    // Storage Proof Tests
    // =========================================================================

    function test_update_with_storage_proof() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;
        pv.numStorageSlots = 3;
        pv.storageProofAddress = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
        pv.storageProofStorageRoot = bytes32(uint256(0xabcd));

        lightClient.update(abi.encode(pv), hex"dead");

        assertEq(
            lightClient.getVerifiedStorageRoot(200, address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)),
            bytes32(uint256(0xabcd))
        );
    }

    function test_update_with_l2_state_root() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;
        pv.numL2StorageSlots = 2;
        pv.l2StateRoot = bytes32(uint256(0x5678));

        lightClient.update(abi.encode(pv), hex"dead");

        assertEq(lightClient.getVerifiedL2StateRoot(200), bytes32(uint256(0x5678)));
    }

    function test_no_storage_proof_leaves_zero() public {
        bytes32 scHash = bytes32(uint256(0x1111));
        lightClient.initialize(100, bytes32(0), bytes32(0), scHash);

        SP1EthereumLightClient.LightClientPublicValues memory pv;
        pv.finalizedSlot = 200;
        pv.finalizedHeaderRoot = bytes32(uint256(0xcc));
        pv.finalizedStateRoot = bytes32(uint256(0xdd));
        pv.currentSyncCommitteeHash = scHash;
        pv.participation = 500;
        // numStorageSlots = 0 (default)

        lightClient.update(abi.encode(pv), hex"dead");

        assertEq(lightClient.getVerifiedStorageRoot(200, address(0)), bytes32(0));
        assertEq(lightClient.getVerifiedL2StateRoot(200), bytes32(0));
    }
}
