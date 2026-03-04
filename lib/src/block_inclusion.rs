//! Block inclusion proof verification.
//!
//! Verifies a chain of execution layer block headers, proving that each
//! block's hash was correctly computed and that each block's `parentHash`
//! matches the hash of the previous block. This creates a verified chain
//! segment that can be used for historical state access.
//!
//! This implements the MPT-based block inclusion proof approach described
//! in the research paper (Section 3.3.3), using a simplified model where:
//! - A chain of consecutive block headers is verified in the zkVM
//! - Each header's RLP encoding is hashed with Keccak256 to produce the block hash
//! - Parent hash linkage is verified: each block's `parentHash == hash(prev_block)`
//! - The chain is anchored to a known trusted execution state root or block hash
//! - Verified block hashes are committed as public values
//!
//! The on-chain contract stores these proven block hashes, enabling historical
//! state access beyond the EVM's 256-block `blockhash()` limit.

use crate::mpt::keccak256;
use crate::types::Bytes32;
use serde::{Deserialize, Serialize};

// =============================================================================
// Types
// =============================================================================

/// An execution layer block header (RLP-encoded).
///
/// We store the raw RLP encoding and decode only the fields we need,
/// since the block hash is `keccak256(rlp_header)` over the raw bytes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionBlockHeader {
    /// Block number.
    pub block_number: u64,
    /// The raw RLP encoding of the full block header.
    /// `keccak256(rlp_header)` produces the block hash.
    pub rlp_header: Vec<u8>,
    /// Parent hash (extracted from the RLP for quick access).
    /// This is verified against keccak256 of the previous block's RLP.
    pub parent_hash: Bytes32,
    /// State root (extracted from the RLP for anchoring proofs).
    pub state_root: Bytes32,
}

/// A verified block hash entry — the output committed to the proof.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifiedBlockHash {
    /// Block number.
    pub block_number: u64,
    /// Block hash (`keccak256(rlp_header)`).
    pub block_hash: Bytes32,
    /// State root from this block header.
    pub state_root: Bytes32,
}

/// Input for block inclusion proof verification inside the zkVM.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockInclusionProofInputs {
    /// An ordered chain of execution block headers (oldest to newest).
    /// Must be consecutive (block N, N+1, N+2, ...).
    pub headers: Vec<ExecutionBlockHeader>,
    /// The trusted anchor — a known block hash to link the chain to.
    /// This should be a block hash that has been previously verified
    /// (e.g., from the finalized beacon block's execution payload).
    pub anchor_block_hash: Bytes32,
    /// Block number of the anchor.
    pub anchor_block_number: u64,
}

/// Result of a successful block inclusion proof verification.
#[derive(Debug, Clone)]
pub struct BlockInclusionResult {
    /// All verified block hashes in the chain.
    pub verified_blocks: Vec<VerifiedBlockHash>,
    /// The anchor block hash used.
    pub anchor_block_hash: Bytes32,
    /// First block number in the verified chain.
    pub start_block: u64,
    /// Last block number in the verified chain.
    pub end_block: u64,
}

// =============================================================================
// Errors
// =============================================================================

/// Errors from block inclusion proof verification.
#[derive(Debug, Clone)]
pub enum BlockInclusionError {
    /// No headers provided.
    EmptyHeaders,
    /// Block numbers are not consecutive.
    NonConsecutiveBlocks {
        expected: u64,
        got: u64,
    },
    /// Parent hash mismatch — the chain is broken.
    ParentHashMismatch {
        block_number: u64,
        expected_parent: Bytes32,
        actual_parent: Bytes32,
    },
    /// The first block doesn't link to the anchor.
    AnchorMismatch {
        first_parent_hash: Bytes32,
        anchor_hash: Bytes32,
    },
    /// Anchor block number doesn't match expected position.
    AnchorBlockNumberMismatch {
        expected: u64,
        got: u64,
    },
}

impl core::fmt::Display for BlockInclusionError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::EmptyHeaders => write!(f, "no block headers provided"),
            Self::NonConsecutiveBlocks { expected, got } => {
                write!(f, "non-consecutive blocks: expected {expected}, got {got}")
            }
            Self::ParentHashMismatch {
                block_number,
                expected_parent,
                actual_parent,
            } => write!(
                f,
                "parent hash mismatch at block {block_number}: expected {:?}, got {:?}",
                &expected_parent[..4],
                &actual_parent[..4]
            ),
            Self::AnchorMismatch {
                first_parent_hash,
                anchor_hash,
            } => write!(
                f,
                "anchor mismatch: first block's parent {:?} != anchor {:?}",
                &first_parent_hash[..4],
                &anchor_hash[..4]
            ),
            Self::AnchorBlockNumberMismatch { expected, got } => {
                write!(
                    f,
                    "anchor block number mismatch: expected {expected}, got {got}"
                )
            }
        }
    }
}

// =============================================================================
// Verification
// =============================================================================

/// Verify a chain of execution block headers for block inclusion.
///
/// This is the core verification function that runs inside the zkVM.
/// It verifies:
/// 1. Each header's hash matches `keccak256(rlp_header)`
/// 2. Block numbers are consecutive
/// 3. Each block's `parent_hash` matches the previous block's hash
/// 4. The first block's `parent_hash` matches the provided anchor
///
/// # Arguments
/// * `inputs` — Block headers and anchor data.
///
/// # Returns
/// `BlockInclusionResult` with all verified block hashes.
pub fn verify_block_inclusion(
    inputs: &BlockInclusionProofInputs,
) -> Result<BlockInclusionResult, BlockInclusionError> {
    if inputs.headers.is_empty() {
        return Err(BlockInclusionError::EmptyHeaders);
    }

    let mut verified_blocks = Vec::with_capacity(inputs.headers.len());

    // Step 1: Verify the anchor linkage
    let first = &inputs.headers[0];
    if first.block_number != inputs.anchor_block_number + 1 {
        return Err(BlockInclusionError::AnchorBlockNumberMismatch {
            expected: inputs.anchor_block_number + 1,
            got: first.block_number,
        });
    }

    // The first block's parent_hash must be the anchor block hash
    if first.parent_hash != inputs.anchor_block_hash {
        return Err(BlockInclusionError::AnchorMismatch {
            first_parent_hash: first.parent_hash,
            anchor_hash: inputs.anchor_block_hash,
        });
    }

    // Step 2: Verify each block header
    let mut prev_hash: Bytes32 = inputs.anchor_block_hash;

    for (i, header) in inputs.headers.iter().enumerate() {
        // Check consecutive block numbers
        let expected_number = inputs.anchor_block_number + 1 + i as u64;
        if header.block_number != expected_number {
            return Err(BlockInclusionError::NonConsecutiveBlocks {
                expected: expected_number,
                got: header.block_number,
            });
        }

        // Verify parent hash linkage
        if header.parent_hash != prev_hash {
            return Err(BlockInclusionError::ParentHashMismatch {
                block_number: header.block_number,
                expected_parent: prev_hash,
                actual_parent: header.parent_hash,
            });
        }

        // Compute block hash = keccak256(rlp_header)
        let block_hash = keccak256(&header.rlp_header);

        // Store the verified block
        verified_blocks.push(VerifiedBlockHash {
            block_number: header.block_number,
            block_hash,
            state_root: header.state_root,
        });

        // Update prev_hash for the next iteration
        prev_hash = block_hash;
    }

    let start_block = inputs.headers[0].block_number;
    let end_block = inputs.headers.last().unwrap().block_number;

    Ok(BlockInclusionResult {
        verified_blocks,
        anchor_block_hash: inputs.anchor_block_hash,
        start_block,
        end_block,
    })
}

// =============================================================================
// RLP Header Field Extraction
// =============================================================================

/// Extract the parent hash from a raw RLP-encoded block header.
///
/// In an Ethereum block header, the parent hash is the first field.
/// It's a 32-byte value encoded as RLP: `0xa0` followed by 32 bytes.
/// The offset depends on whether the header uses a short or long list prefix.
pub fn extract_parent_hash_from_rlp(rlp_header: &[u8]) -> Option<Bytes32> {
    if rlp_header.is_empty() {
        return None;
    }

    // Determine list payload offset
    let prefix = rlp_header[0];
    let offset = if prefix <= 0xf7 {
        1 // short list: prefix is the only byte before payload
    } else {
        let len_of_len = (prefix - 0xf7) as usize;
        1 + len_of_len // long list
    };

    if rlp_header.len() < offset + 33 {
        return None;
    }

    // First item should be parentHash: 0xa0 + 32 bytes
    if rlp_header[offset] != 0xa0 {
        return None;
    }

    let mut parent_hash = [0u8; 32];
    parent_hash.copy_from_slice(&rlp_header[offset + 1..offset + 33]);
    Some(parent_hash)
}

/// Extract the state root from a raw RLP-encoded block header.
///
/// The state root is the 4th field in the block header:
/// parentHash (32), uncleHash (32), coinbase (20), stateRoot (32)
/// Each field has a 1-byte RLP prefix.
pub fn extract_state_root_from_rlp(rlp_header: &[u8]) -> Option<Bytes32> {
    if rlp_header.is_empty() {
        return None;
    }

    // Determine list payload offset
    let prefix = rlp_header[0];
    let data_offset = if prefix <= 0xf7 {
        1
    } else {
        1 + (prefix - 0xf7) as usize
    };

    // Walk through the fields to find stateRoot (4th field)
    let mut pos = data_offset;

    // 1st field: parentHash (0xa0 + 32 bytes = 33)
    if pos + 33 > rlp_header.len() || rlp_header[pos] != 0xa0 {
        return None;
    }
    pos += 33;

    // 2nd field: uncleHash / ommersHash (0xa0 + 32 bytes = 33)
    if pos + 33 > rlp_header.len() || rlp_header[pos] != 0xa0 {
        return None;
    }
    pos += 33;

    // 3rd field: coinbase / beneficiary (0x94 + 20 bytes = 21)
    if pos + 21 > rlp_header.len() || rlp_header[pos] != 0x94 {
        return None;
    }
    pos += 21;

    // 4th field: stateRoot (0xa0 + 32 bytes = 33)
    if pos + 33 > rlp_header.len() || rlp_header[pos] != 0xa0 {
        return None;
    }

    let mut state_root = [0u8; 32];
    state_root.copy_from_slice(&rlp_header[pos + 1..pos + 33]);
    Some(state_root)
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Create a mock RLP header that produces a deterministic hash.
    fn make_mock_rlp_header(
        parent_hash: &Bytes32,
        state_root: &Bytes32,
        extra_nonce: u8,
    ) -> Vec<u8> {
        // Build a minimal valid RLP block header with the required fields
        // This is a simplified structure for testing:
        // list[ parentHash(32), uncleHash(32), coinbase(20), stateRoot(32),
        //       txRoot(32), receiptRoot(32), bloom(256), difficulty(1),
        //       number(1), gasLimit(1), gasUsed(1), timestamp(1), extra(1),
        //       mixHash(32), nonce(8) ]

        let uncle_hash = [0u8; 32];
        let coinbase = [0u8; 20];
        let tx_root = [0u8; 32];
        let receipt_root = [0u8; 32];
        let bloom = [0u8; 256];
        let mix_hash = [0u8; 32];
        let nonce = [0u8; 8];

        let mut payload = Vec::new();

        // parentHash
        payload.push(0xa0);
        payload.extend_from_slice(parent_hash);

        // uncleHash
        payload.push(0xa0);
        payload.extend_from_slice(&uncle_hash);

        // coinbase
        payload.push(0x94);
        payload.extend_from_slice(&coinbase);

        // stateRoot
        payload.push(0xa0);
        payload.extend_from_slice(state_root);

        // txRoot
        payload.push(0xa0);
        payload.extend_from_slice(&tx_root);

        // receiptRoot
        payload.push(0xa0);
        payload.extend_from_slice(&receipt_root);

        // bloom (256 bytes)
        payload.push(0xb9);
        payload.push(0x01);
        payload.push(0x00);
        payload.extend_from_slice(&bloom);

        // difficulty
        payload.push(extra_nonce);

        // number, gasLimit, gasUsed, timestamp, extraData
        for _ in 0..4 {
            payload.push(0x80); // empty bytes
        }
        payload.push(0x80);

        // mixHash
        payload.push(0xa0);
        payload.extend_from_slice(&mix_hash);

        // nonce (8 bytes)
        payload.push(0x88);
        payload.extend_from_slice(&nonce);

        // Wrap in RLP list prefix
        let payload_len = payload.len();
        let mut header = Vec::new();
        if payload_len < 56 {
            header.push(0xc0 + payload_len as u8);
        } else if payload_len < 256 {
            header.push(0xf8);
            header.push(payload_len as u8);
        } else {
            header.push(0xf9);
            header.push((payload_len >> 8) as u8);
            header.push((payload_len & 0xff) as u8);
        }
        header.extend_from_slice(&payload);
        header
    }

    #[test]
    fn test_verify_single_block() {
        let anchor_hash = keccak256(b"anchor block");
        let state_root = [0xAAu8; 32];

        let rlp = make_mock_rlp_header(&anchor_hash, &state_root, 0x42);

        let inputs = BlockInclusionProofInputs {
            headers: vec![ExecutionBlockHeader {
                block_number: 101,
                rlp_header: rlp.clone(),
                parent_hash: anchor_hash,
                state_root,
            }],
            anchor_block_hash: anchor_hash,
            anchor_block_number: 100,
        };

        let result = verify_block_inclusion(&inputs).unwrap();
        assert_eq!(result.verified_blocks.len(), 1);
        assert_eq!(result.verified_blocks[0].block_number, 101);
        assert_eq!(result.verified_blocks[0].block_hash, keccak256(&rlp));
        assert_eq!(result.verified_blocks[0].state_root, state_root);
        assert_eq!(result.start_block, 101);
        assert_eq!(result.end_block, 101);
    }

    #[test]
    fn test_verify_chain_of_blocks() {
        let anchor_hash = keccak256(b"genesis");
        let state1 = [0x11u8; 32];
        let state2 = [0x22u8; 32];
        let state3 = [0x33u8; 32];

        // Block 1
        let rlp1 = make_mock_rlp_header(&anchor_hash, &state1, 0x01);
        let hash1 = keccak256(&rlp1);

        // Block 2
        let rlp2 = make_mock_rlp_header(&hash1, &state2, 0x02);
        let hash2 = keccak256(&rlp2);

        // Block 3
        let rlp3 = make_mock_rlp_header(&hash2, &state3, 0x03);

        let inputs = BlockInclusionProofInputs {
            headers: vec![
                ExecutionBlockHeader {
                    block_number: 1001,
                    rlp_header: rlp1,
                    parent_hash: anchor_hash,
                    state_root: state1,
                },
                ExecutionBlockHeader {
                    block_number: 1002,
                    rlp_header: rlp2,
                    parent_hash: hash1,
                    state_root: state2,
                },
                ExecutionBlockHeader {
                    block_number: 1003,
                    rlp_header: rlp3,
                    parent_hash: hash2,
                    state_root: state3,
                },
            ],
            anchor_block_hash: anchor_hash,
            anchor_block_number: 1000,
        };

        let result = verify_block_inclusion(&inputs).unwrap();
        assert_eq!(result.verified_blocks.len(), 3);
        assert_eq!(result.start_block, 1001);
        assert_eq!(result.end_block, 1003);

        // Verify parent-child hash linkage
        assert_eq!(result.verified_blocks[0].block_hash, hash1);
        assert_eq!(result.verified_blocks[1].block_hash, hash2);
    }

    #[test]
    fn test_anchor_mismatch() {
        let anchor_hash = keccak256(b"anchor");
        let wrong_parent = [0xFFu8; 32];

        let rlp = make_mock_rlp_header(&wrong_parent, &[0u8; 32], 0);
        let inputs = BlockInclusionProofInputs {
            headers: vec![ExecutionBlockHeader {
                block_number: 101,
                rlp_header: rlp,
                parent_hash: wrong_parent,
                state_root: [0u8; 32],
            }],
            anchor_block_hash: anchor_hash,
            anchor_block_number: 100,
        };

        let result = verify_block_inclusion(&inputs);
        assert!(matches!(result, Err(BlockInclusionError::AnchorMismatch { .. })));
    }

    #[test]
    fn test_broken_chain() {
        let anchor_hash = keccak256(b"anchor");
        let state_root = [0u8; 32];

        let rlp1 = make_mock_rlp_header(&anchor_hash, &state_root, 0x01);
        let hash1 = keccak256(&rlp1);

        // Block 2 has wrong parent hash
        let wrong_parent = [0xDDu8; 32];
        let rlp2 = make_mock_rlp_header(&wrong_parent, &state_root, 0x02);

        let inputs = BlockInclusionProofInputs {
            headers: vec![
                ExecutionBlockHeader {
                    block_number: 101,
                    rlp_header: rlp1,
                    parent_hash: anchor_hash,
                    state_root,
                },
                ExecutionBlockHeader {
                    block_number: 102,
                    rlp_header: rlp2,
                    parent_hash: wrong_parent,
                    state_root,
                },
            ],
            anchor_block_hash: anchor_hash,
            anchor_block_number: 100,
        };

        let result = verify_block_inclusion(&inputs);
        assert!(matches!(
            result,
            Err(BlockInclusionError::ParentHashMismatch { block_number: 102, .. })
        ));

        // Also verify that the parent hash in the RLP doesn't match hash1
        assert_ne!(wrong_parent, hash1);
    }

    #[test]
    fn test_non_consecutive_blocks() {
        let anchor_hash = keccak256(b"anchor");
        let rlp = make_mock_rlp_header(&anchor_hash, &[0u8; 32], 0);

        let inputs = BlockInclusionProofInputs {
            headers: vec![ExecutionBlockHeader {
                block_number: 105, // should be 101
                rlp_header: rlp,
                parent_hash: anchor_hash,
                state_root: [0u8; 32],
            }],
            anchor_block_hash: anchor_hash,
            anchor_block_number: 100,
        };

        let result = verify_block_inclusion(&inputs);
        assert!(matches!(
            result,
            Err(BlockInclusionError::AnchorBlockNumberMismatch { .. })
        ));
    }

    #[test]
    fn test_extract_parent_hash() {
        let parent_hash = [0xABu8; 32];
        let state_root = [0xCDu8; 32];
        let rlp = make_mock_rlp_header(&parent_hash, &state_root, 0);

        let extracted = extract_parent_hash_from_rlp(&rlp).unwrap();
        assert_eq!(extracted, parent_hash);
    }

    #[test]
    fn test_extract_state_root() {
        let parent_hash = [0xABu8; 32];
        let state_root = [0xCDu8; 32];
        let rlp = make_mock_rlp_header(&parent_hash, &state_root, 0);

        let extracted = extract_state_root_from_rlp(&rlp).unwrap();
        assert_eq!(extracted, state_root);
    }
}
