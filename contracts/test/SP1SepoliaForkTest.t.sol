// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SP1EthereumLightClient} from "../src/SP1EthereumLightClient.sol";
import {ISP1Verifier} from "../src/interfaces/ISP1Verifier.sol";

/// @title SP1SepoliaForkTest
/// @notice Tests the light client contract against the REAL SP1 Verifier on a Sepolia fork.
///
///   Run with:
///     forge test --match-contract SP1SepoliaForkTest \
///       --fork-url $SEPOLIA_RPC_URL -vvv
///
///   This will:
///   1. Fork Sepolia at the latest block
///   2. Use the real SP1VerifierGateway deployed on Sepolia
///   3. Deploy our light client contract
///   4. Submit the Groth16 proof fixture
///   5. Verify the proof passes the REAL on-chain verifier
contract SP1SepoliaForkTest is Test {
    using stdJson for string;

    /// @notice SP1 Verifier Gateway (Groth16) on Sepolia.
    /// Deployed by Succinct at the same address on all supported chains.
    address constant SP1_VERIFIER_GATEWAY = 0x397A5f7f3dBd538f23DE225B51f532c34448dA9B;

    uint32 constant MIN_PARTICIPATION = 342;

    struct ProofFixture {
        uint64 finalizedSlot;
        bytes32 finalizedHeaderRoot;
        bytes32 finalizedStateRoot;
        bytes32 currentSyncCommitteeHash;
        bytes32 nextSyncCommitteeHash;
        uint32 participation;
        bytes32 vkey;
        bytes publicValues;
        bytes proof;
    }

    function loadFixture(string memory filename) internal view returns (ProofFixture memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/src/fixtures/", filename);
        string memory json = vm.readFile(path);

        ProofFixture memory f;
        f.finalizedSlot = uint64(json.readUint(".finalizedSlot"));
        f.finalizedHeaderRoot = json.readBytes32(".finalizedHeaderRoot");
        f.finalizedStateRoot = json.readBytes32(".finalizedStateRoot");
        f.currentSyncCommitteeHash = json.readBytes32(".currentSyncCommitteeHash");
        f.nextSyncCommitteeHash = json.readBytes32(".nextSyncCommitteeHash");
        f.participation = uint32(json.readUint(".participation"));
        f.vkey = json.readBytes32(".vkey");
        f.publicValues = json.readBytes(".publicValues");
        f.proof = json.readBytes(".proof");
        return f;
    }

    /// @notice Verify the SP1 Verifier Gateway exists on the fork.
    function test_verifier_gateway_exists() public view {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(SP1_VERIFIER_GATEWAY)
        }
        console.log("SP1 Verifier Gateway code size:", codeSize);
        assertGt(codeSize, 0, "SP1 Verifier Gateway not deployed on this fork");
    }

    /// @notice Full end-to-end test: deploy, initialize, submit Groth16 proof.
    ///         Uses the REAL SP1 Verifier Gateway on the Sepolia fork.
    function test_groth16_real_verifier() public {
        ProofFixture memory f = loadFixture("groth16-fixture.json");

        // Skip if proof is empty (mock fixture)
        if (f.proof.length <= 2) {
            console.log("SKIP: Proof is empty (mock fixture). Need real Groth16 proof.");
            return;
        }

        console.log("=== Real Groth16 Verification on Sepolia Fork ===");
        console.log("Verifier Gateway:", SP1_VERIFIER_GATEWAY);
        console.log("VKey:");
        console.logBytes32(f.vkey);
        console.log("Finalized Slot:", f.finalizedSlot);
        console.log("Proof length:  ", f.proof.length);

        // Deploy with REAL SP1 verifier
        SP1EthereumLightClient lightClient = new SP1EthereumLightClient(
            SP1_VERIFIER_GATEWAY,
            f.vkey,
            MIN_PARTICIPATION
        );

        // Initialize before the proof's slot
        uint64 initSlot = f.finalizedSlot - 8192;
        lightClient.initialize(
            initSlot,
            bytes32(uint256(0x1111)),
            bytes32(uint256(0x2222)),
            f.currentSyncCommitteeHash
        );

        console.log("Initialized at slot:", initSlot);

        // Submit the Groth16 proof — this calls the REAL SP1 verifier
        lightClient.update(f.publicValues, f.proof);

        // If we get here, the proof was verified by the real verifier!
        assertEq(lightClient.head(), f.finalizedSlot);
        assertEq(lightClient.finalizedHeaderRoot(), f.finalizedHeaderRoot);
        assertEq(lightClient.finalizedStateRoot(), f.finalizedStateRoot);
        assertTrue(lightClient.isSlotFinalized(f.finalizedSlot));

        console.log("");
        console.log("=== RESULTS ===");
        console.log("Head:", lightClient.head());
        console.log("Header Root:");
        console.logBytes32(lightClient.finalizedHeaderRoot());
        console.log("State Root:");
        console.logBytes32(lightClient.finalizedStateRoot());
        console.log("");
        console.log("REAL GROTH16 ON-CHAIN VERIFICATION: PASSED!");
    }

    /// @notice Gas benchmark for real Groth16 verification.
    function test_groth16_gas_real_verifier() public {
        ProofFixture memory f = loadFixture("groth16-fixture.json");

        if (f.proof.length <= 2) {
            console.log("SKIP: Need real proof for gas benchmark.");
            return;
        }

        SP1EthereumLightClient lightClient = new SP1EthereumLightClient(
            SP1_VERIFIER_GATEWAY,
            f.vkey,
            MIN_PARTICIPATION
        );

        uint64 initSlot = f.finalizedSlot - 8192;
        lightClient.initialize(
            initSlot,
            bytes32(uint256(0x1111)),
            bytes32(uint256(0x2222)),
            f.currentSyncCommitteeHash
        );

        uint256 gasBefore = gasleft();
        lightClient.update(f.publicValues, f.proof);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Gas Benchmark (Real Verifier) ===");
        console.log("Total gas for update():", gasUsed);
        console.log("  (Includes: Groth16 pairing check + state updates)");
    }
}
