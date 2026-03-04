// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SP1EthereumLightClient} from "../src/SP1EthereumLightClient.sol";

/// @title DeployAndVerify
/// @notice Deploy the light client to Sepolia and submit the Groth16 proof on-chain.
///
/// Usage:
///   # First copy .env.example to .env and fill in your keys
///
///   # Deploy only:
///   forge script script/DeployAndVerify.s.sol:DeployAndVerify \
///     --sig "deployOnly()" --rpc-url $SEPOLIA_RPC_URL --broadcast
///
///   # Deploy + Initialize + Submit Proof (all-in-one):
///   forge script script/DeployAndVerify.s.sol:DeployAndVerify \
///     --sig "deployAndVerify()" --rpc-url $SEPOLIA_RPC_URL --broadcast
///
///   # Submit proof to existing contract:
///   LIGHT_CLIENT_ADDRESS=0x... forge script script/DeployAndVerify.s.sol:DeployAndVerify \
///     --sig "submitProof()" --rpc-url $SEPOLIA_RPC_URL --broadcast
contract DeployAndVerify is Script {
    using stdJson for string;

    // Fixture data
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

    function loadGroth16Fixture() internal view returns (ProofFixture memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/src/fixtures/groth16-fixture.json");
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

    /// @notice Deploy only — no initialization or proof submission.
    function deployOnly() external {
        address verifier = vm.envAddress("SP1_VERIFIER_ADDRESS");
        bytes32 programVKey = vm.envBytes32("PROGRAM_VKEY");
        uint32 minParticipation = uint32(vm.envUint("MIN_PARTICIPATION"));

        console.log("=== Deploying SP1EthereumLightClient to Sepolia ===");
        console.log("SP1 Verifier Gateway:", verifier);
        console.log("Program VKey:");
        console.logBytes32(programVKey);
        console.log("Min Participation:", minParticipation);

        vm.startBroadcast();

        SP1EthereumLightClient lightClient = new SP1EthereumLightClient(
            verifier,
            programVKey,
            minParticipation
        );

        vm.stopBroadcast();

        console.log("");
        console.log("CONTRACT DEPLOYED AT:", address(lightClient));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Set LIGHT_CLIENT_ADDRESS in your .env");
        console.log("  2. Run submitProof() to initialize and submit proof");
    }

    /// @notice Deploy + Initialize + Submit Groth16 Proof (all-in-one).
    function deployAndVerify() external {
        address verifier = vm.envAddress("SP1_VERIFIER_ADDRESS");
        bytes32 programVKey = vm.envBytes32("PROGRAM_VKEY");
        uint32 minParticipation = uint32(vm.envUint("MIN_PARTICIPATION"));

        ProofFixture memory f = loadGroth16Fixture();

        console.log("=== Deploy + Initialize + Verify ===");
        console.log("SP1 Verifier:", verifier);
        console.log("VKey:");
        console.logBytes32(f.vkey);
        console.log("Finalized Slot:", f.finalizedSlot);
        console.log("Participation: ", f.participation);
        console.log("Proof length:  ", f.proof.length, "bytes");

        // Verify the vkey matches
        require(f.vkey == programVKey, "Fixture vkey != env PROGRAM_VKEY");

        vm.startBroadcast();

        // Step 1: Deploy
        SP1EthereumLightClient lightClient = new SP1EthereumLightClient(
            verifier,
            programVKey,
            minParticipation
        );
        console.log("");
        console.log("Contract deployed:", address(lightClient));

        // Step 2: Initialize at a slot BEFORE the proof's finalized slot
        uint64 initSlot = f.finalizedSlot - 8192;
        lightClient.initialize(
            initSlot,
            bytes32(uint256(0x1111)),          // placeholder header root
            bytes32(uint256(0x2222)),          // placeholder state root
            f.currentSyncCommitteeHash         // must match proof's SC hash
        );
        console.log("Initialized at slot:", initSlot);

        // Step 3: Submit the Groth16 proof to advance the head
        lightClient.update(f.publicValues, f.proof);

        vm.stopBroadcast();

        // Verify results
        console.log("");
        console.log("=== VERIFICATION RESULTS ===");
        console.log("Head advanced to:", lightClient.head());
        console.log("Finalized slot:  ", lightClient.isSlotFinalized(f.finalizedSlot) ? "YES" : "NO");
        console.log("");
        console.log("ON-CHAIN GROTH16 VERIFICATION: SUCCESS!");
        console.log("Contract address:", address(lightClient));
    }

    /// @notice Submit proof to an already-deployed contract.
    function submitProof() external {
        address contractAddr = vm.envAddress("LIGHT_CLIENT_ADDRESS");
        SP1EthereumLightClient lightClient = SP1EthereumLightClient(contractAddr);
        ProofFixture memory f = loadGroth16Fixture();

        console.log("=== Submitting Groth16 Proof ===");
        console.log("Contract:", contractAddr);
        console.log("Finalized Slot:", f.finalizedSlot);
        console.log("Proof length:  ", f.proof.length, "bytes");

        vm.startBroadcast();

        if (!lightClient.initialized()) {
            console.log("Contract not initialized, initializing...");
            uint64 initSlot = f.finalizedSlot - 8192;
            lightClient.initialize(
                initSlot,
                bytes32(uint256(0x1111)),
                bytes32(uint256(0x2222)),
                f.currentSyncCommitteeHash
            );
            console.log("Initialized at slot:", initSlot);
        }

        lightClient.update(f.publicValues, f.proof);

        vm.stopBroadcast();

        console.log("");
        console.log("=== RESULT ===");
        console.log("Head:", lightClient.head());
        console.log("SUCCESS: Groth16 proof verified on-chain!");
    }
}
