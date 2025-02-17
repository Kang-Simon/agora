/*******************************************************************************

    Create blocks with multiple transactions and test that they are
    read properly.

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module unit.BlockStorageMultiTx;

import agora.common.Amount;
import agora.common.Types;
import agora.consensus.data.Block;
import agora.consensus.data.genesis.Test;
import agora.consensus.data.Transaction;
import agora.node.BlockStorage;
import agora.utils.Test;

import std.algorithm;
import std.file;
import std.path;
import std.range;

/// The maximum number of block in one file
private immutable ulong MFILE_MAX_BLOCK = 100;

/// blocks to test
const size_t BlockCount = 300;

///
private void main ()
{
    auto path = makeCleanTempDir();

    BlockStorage storage = new BlockStorage(path);
    storage.load(GenesisBlock);
    const(Block)[] blocks;
    blocks ~= GenesisBlock;

    // For genesis, we need to use the outputs, not previous transactions
    Transaction[] txs = genesisSpendable().map!(txb => txb.refund(WK.Keys.A.address).sign()).array();
    foreach (block_idx; 0 .. BlockCount)
    {
        Height h = Height(block_idx + 1);
        auto preimages = WK.PreImages.at(h, genesis_validator_keys);
        auto block = makeNewBlock(blocks[$ - 1], txs, preimages);
        storage.saveBlock(block);
        blocks ~= block;
        // Prepare transactions for the next block
        txs = txs
            .map!(tx => TxBuilder(tx).refund(WK.Keys[block_idx + 1].address).sign())
            .array();
    }

    //// load
    Block[] loaded_blocks;
    loaded_blocks.length = BlockCount + 1;
    foreach (idx; 0 .. BlockCount + 1)
        loaded_blocks[idx] = storage.readBlock(Height(idx));

    // Finally compare every blocks
    assert(loaded_blocks == blocks);
}
