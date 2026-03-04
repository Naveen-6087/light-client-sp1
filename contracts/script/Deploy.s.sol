// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SP1EthereumLightClient} from "../src/SP1EthereumLightClient.sol";

/// @title DeployLightClient
/// @notice Deploy the SP1 Ethereum Light Client contract.
///
/// Usage:
///   forge script script/Deploy.s.sol:DeployLightClient \
///     --rpc-url $RPC_URL --broadcast --verify
///
/// Required environment variables:
///   SP1_VERIFIER_ADDRESS  — Address of the SP1 verifier contract
///   PROGRAM_VKEY          — Verification key hash (bytes32)
///   MIN_PARTICIPATION     — Minimum sync committee participation (uint32)
contract DeployLightClient is Script {
    function run() external {
        address verifier = vm.envAddress("SP1_VERIFIER_ADDRESS");
        bytes32 programVKey = vm.envBytes32("PROGRAM_VKEY");
        uint32 minParticipation = uint32(vm.envUint("MIN_PARTICIPATION"));

        console.log("Deploying SP1EthereumLightClient...");
        console.log("  Verifier:", verifier);
        console.log("  Min Participation:", minParticipation);

        vm.startBroadcast();

        SP1EthereumLightClient lightClient = new SP1EthereumLightClient(
            verifier,
            programVKey,
            minParticipation
        );

        console.log("  Deployed at:", address(lightClient));

        vm.stopBroadcast();
    }
}
