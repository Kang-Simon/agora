/*******************************************************************************

    Defines the data structure of a block

    The design is influenced by Bitcoin, but will be ammended later.

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.data.Block;

import agora.common.Amount;
import agora.common.BitMask;
import agora.common.Types;
import agora.consensus.data.Enrollment;
import agora.consensus.data.Transaction;
import agora.crypto.ECC;
import agora.crypto.Hash;
import agora.crypto.Key;
import agora.crypto.Schnorr;
import agora.script.Lock;
import agora.script.Signature;
import agora.serialization.Serializer;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.range;

import core.bitop;

/*******************************************************************************

    The block header which contains a link to the previous block header,
    unless it's the genesis header.

*******************************************************************************/

public struct BlockHeader
{
    /// Hash of the previous block in the chain of blocks
    public Hash prev_block;

    /// The hash of the merkle root of the transactions
    public Hash merkle_root;

    /// Schnorr multisig of all validators which signed this block
    public Signature signature;

    /// BitMask containing the validators' key indices which signed the block
    public BitMask validators;

    /// Block height (genesis is #0)
    public Height height;

    /// The pre-images propagated in this block
    public Hash[] preimages;

    /// Convenience function
    public Hash randomSeed () const scope @safe pure
    {
        auto rng = this.preimages.filter!(pi => pi !is Hash.init);
        return rng.empty ? Hash.init : rng.reduce!((a, b) => hashMulti(a, b));
    }

    /// Create a mutable clone
    public BlockHeader clone () const @safe
    {
        return this.serializeFull.deserializeFull!BlockHeader;
    }

    /// Enrolled validators
    public Enrollment[] enrollments;

    /***************************************************************************

        Implements hashing support

        Note that validators bitmask bits & the signature are not hashed
        since they must sign the block header hash.

        Params:
            dg = Hashing function accumulator

    ***************************************************************************/

    public void computeHash (scope HashDg dg) const scope
        @safe pure nothrow @nogc
    {
        dg(this.prev_block[]);
        dg(this.merkle_root[]);
        hashPart(this.height.value, dg);
        foreach (const ref h; this.preimages)
            dg(h[]);
        foreach (enrollment; this.enrollments)
            hashPart(enrollment, dg);
    }

    /***************************************************************************

        Create the block signature for the given keypair

        This signature will be combined with other validator's signatures
        using Schnorr multisig. The signature is only returned,
        the current list of signer (`validators`) is not modified.

        Params:
            secret_key = node's secret
            preimage = preimage at the block height for the signing validator

        Returns:
            A new signature derived from the provided parameters

    ***************************************************************************/

    public Signature sign (in Scalar secret_key, in Hash preimage)
        const @safe nothrow
    {
        // challenge = Hash(block) to Scalar
        const Scalar challenge = this.hashFull();
        const Scalar s = Scalar(preimage);
        const Scalar rc = s - secret_key;
        const Scalar r = rc * challenge.invert();
        return Signature(r.toPoint(), s);
    }

    /***************************************************************************

        Returns:
            a copy of this block header with a different signature and
            validators bitmask

        Params:
            signature = new signature
            validators = mask to indicate who has signed

    ***************************************************************************/

    public BlockHeader updateSignature (in Signature signature,
        BitMask validators) const @safe
    {
        return BlockHeader(
                this.prev_block,
                this.merkle_root,
                signature,
                validators,
                this.height,
                this.preimages.dup,
                this.enrollments.dup);
    }

    /***************************************************************************

        Verify that the provided signature is a valid signature for `pubkey`

        This function only checks that `sig` is valid for `pubkey`.
        Whether or not `pubkey` is allowed to sign this block should be checked
        by the caller.

        Params:
          pubkey = Public key of the signing node
          preimage = Pre-image for pubkey for this round
          sig = The `R` of the signature to verify (`s` is `preimage`)
          challenge = The hash of the block header to verify

        Returns:
            `true` if the signature is valid for `pubkey`.

    ***************************************************************************/

    public bool verify (in Point pubkey, in Scalar preimage, in Point sig)
        const @safe nothrow
    {
        const Scalar challenge = this.hashFull();
        return BlockHeader.verify(pubkey, preimage, sig, challenge);
    }

    /// Ditto
    public bool verify (in Point pubkey, in Hash preimage, in Point sig)
        const @safe nothrow
    {
        const Scalar challenge = this.hashFull();
        // Note: This triggers a false positive with dscanner:
        // https://github.com/dlang-community/D-Scanner/issues/851
        return BlockHeader.verify(pubkey, Scalar(preimage), sig, challenge);
    }

    /// Ditto
    public static bool verify (
        in Point pubkey, in Hash preimage, in Point sig, in Hash challenge)
        @safe nothrow
    {
        return BlockHeader.verify(pubkey, Scalar(preimage), sig, Scalar(challenge));
    }

    /// Ditto
    public static bool verify (
        in Point pubkey, in Scalar preimage, in Point sig, in Scalar challenge)
        @safe nothrow
    {
        return preimage.toPoint() == (challenge * sig + pubkey);
    }
}

/// hashing test
unittest
{
    import std.conv : to;
    auto address = `boa1xrra39xpg5q9zwhsq6u7pw508z2let6dj8r5lr4q0d0nff240fvd27yme3h`;
    PublicKey pubkey = PublicKey.fromString(address);

    Output[1] outputs = [ Output(Amount(100), pubkey) ];
    Transaction tx = Transaction(outputs[]);
    BlockHeader header = { merkle_root : tx.hashFull() };

    auto hash = hashFull(header);
    auto exp_hash = Hash("0xbcf8118c75dfab48ef62235a2908aa4a659feee8cee513dd3329b7eee5a4feab16c4802abb819b884fc2e845c65ecc348f1b5d1f5de7350b24fc08fc6c702107");
    assert(hash == exp_hash);
}

/*******************************************************************************

    The block which contains the block header and its body (the transactions).

*******************************************************************************/

public struct Block
{
    // some unittests still assume a block contains 8 txs. Once they're fixed
    // this constant should be removed.
    version (unittest)
    {
        /// number of transactions that constitutes a block
        public enum TxsInTestBlock = 8;
    }

    ///
    public BlockHeader header;

    ///
    public Transaction[] txs;

    ///
    public Hash[] merkle_tree;

    /***************************************************************************

        Computes the hash matching this block

        The hash of a block is that of its header, however it is not uncommon
        that one call `hashFull` on the block instead of the header.
        As a result, this function simply forwards to the header.


        Params:
            dg = Hashing function accumulator

    ***************************************************************************/

    public void computeHash (scope HashDg dg) const scope
        @safe pure nothrow @nogc
    {
        hashPart(this.header, dg);
    }

    /***************************************************************************

        Returns:
            a copy of this block with an updated header with different signature
            and validators bitmask

        Params:
            signature = new signature
            validators = mask to indicate who has signed

    ***************************************************************************/

    public Block updateSignature (in Signature signature, BitMask validators)
        const @safe
    {
        return updateHeader(this.header.updateSignature(signature, validators));
    }

    /***************************************************************************

        Returns:
            a copy of this block with an updated header

        Params:
            signature = new signature
            validators = mask to indicate who has signed

    ***************************************************************************/

    public Block updateHeader (in BlockHeader header)
        const @safe
    {
        return Block(
            header.clone(),
            // TODO: Optimize this by using dup for txs also
            this.txs.map!(tx =>
                tx.serializeFull.deserializeFull!Transaction).array,
            this.merkle_tree.dup);
    }

    /***************************************************************************

        Block serialization

        Params:
            dg = serialize function accumulator

    ***************************************************************************/

    public void serialize (scope SerializeDg dg) const @safe
    {
        serializePart(this.header, dg);

        serializePart(this.txs.length, dg);
        foreach (ref tx; this.txs)
            serializePart(tx, dg);

        serializePart(this.merkle_tree.length, dg);
        foreach (ref merkle; this.merkle_tree)
            dg(merkle[]);
    }

    /***************************************************************************

        Build a merkle tree and its root, and store the tree to this Block

        Returns:
            the merkle root

    ***************************************************************************/

    public Hash buildMerkleTree () nothrow @safe
    {
        return Block.buildMerkleTree(this.txs, this.merkle_tree);
    }

    /***************************************************************************

        Returns:
            a number that is power 2 aligned. If the number is already a power
            of two it returns that number. Otherwise returns the next bigger
            number which is itself a power of 2.

    ***************************************************************************/

    private static size_t getPow2Aligned (size_t value) @safe @nogc nothrow pure
    in
    {
        assert(value > 0);
    }
    do
    {
        return bsr(value) == bsf(value) ? value : (1 << (bsr(value) + 1));
    }

    ///
    unittest
    {
        assert(getPow2Aligned(1) == 1);
        assert(getPow2Aligned(2) == 2);
        assert(getPow2Aligned(3) == 4);
        assert(getPow2Aligned(4) == 4);
        assert(getPow2Aligned(5) == 8);
        assert(getPow2Aligned(7) == 8);
        assert(getPow2Aligned(8) == 8);
        assert(getPow2Aligned(9) == 16);
        assert(getPow2Aligned(15) == 16);
        assert(getPow2Aligned(16) == 16);
        assert(getPow2Aligned(17) == 32);
    }

    /***************************************************************************

        Build a merkle tree and return its root

        Params:
            txs = the transactions to use
            merkle_tree = will contain the merkle tree on function return

        Returns:
            the merkle root

    ***************************************************************************/

    public static Hash buildMerkleTree (in Transaction[] txs,
        ref Hash[] merkle_tree) nothrow @safe
    {
        if (txs.length == 0)
        {
            merkle_tree.length = 0;
            return Hash.init;
        }

        immutable pow2_size = getPow2Aligned(txs.length);
        const MerkleLength = (pow2_size * 2) - 1;

        // 'new' instead of .length: workaround for issue #127 with ldc2 on osx
        merkle_tree = new Hash[](MerkleLength);

        return Block.buildMerkleTreeImpl(pow2_size, txs, merkle_tree);
    }

    /// Ditto
    private static Hash buildMerkleTreeImpl (in size_t pow2_size,
        in Transaction[] txs, ref Hash[] merkle_tree)
        nothrow @safe @nogc
    in
    {
        assert(txs.length > 0);
    }
    do
    {
        assert(merkle_tree.length == (pow2_size * 2) - 1);

        const log2 = bsf(pow2_size);
        foreach (size_t idx, ref hash; merkle_tree[0 .. txs.length])
            hash = hashFull(txs[idx]);

        // transactions are ordered lexicographically by hash in the Merkle tree
        merkle_tree[0 .. txs.length].sort!("a < b");

        // repeat last hash if txs length was not a strict power of 2
        foreach (idx; txs.length .. pow2_size)
            merkle_tree[idx] = merkle_tree[txs.length - 1];

        immutable len = merkle_tree.length;
        for (size_t order = 0; order < log2; order++)
        {
            immutable start = len - (len >> (order));
            immutable end   = len - (len >> (order + 1));
            merkle_tree[start .. end].chunks(2)
                .map!(tup => hashMulti(tup[0], tup[1]))
                .enumerate(size_t(end))
                .each!((idx, val) => merkle_tree[idx] = val);
        }

        return merkle_tree[$ - 1];
    }

    /***************************************************************************

        Get merkle path

        Params:
            index = Sequence of transactions

        Returns:
            Return merkle path

    ***************************************************************************/

    public Hash[] getMerklePath (size_t index) const @safe nothrow
    {
        assert(this.merkle_tree.length != 0, "Block hasn't been fully initialized");

        immutable pow2_size = getPow2Aligned(this.txs.length);
        Hash[] merkle_path;
        size_t j = 0;
        for (size_t length = pow2_size; length > 1; length = (length + 1) / 2)
        {
            size_t i = min(index ^ 1, length - 1);
            merkle_path ~= this.merkle_tree[j + i];
            index >>= 1;
            j += length;
        }
        return merkle_path;
    }

    /***************************************************************************

        Calculate the merkle root using the merkle path.

        Params:
            hash = `Hash` of `Transaction`
            merkle_path  = `Hash` of merkle path
            index = Index of the hash in the array of transactions.

        Returns:
            Return `Hash` of merkle root.

    ***************************************************************************/

    public static Hash checkMerklePath (Hash hash, in Hash[] merkle_path, size_t index) @safe
    {
        foreach (const ref otherside; merkle_path)
        {
            if (index & 1)
                hash = hashMulti(otherside, hash);
            else
                hash = hashMulti(hash, otherside);

            index >>= 1;
        }

        return hash;
    }

    /***************************************************************************

        Find the sequence of transactions for the hash.

        Params:
            hash = `Hash` of `Transaction`

        Returns:
            Return sequence if found hash, otherwise Retrun the number of
            transactions.

    ***************************************************************************/

    public size_t findHashIndex (in Hash hash) const @safe nothrow
    {
        // An empty block doesn't have any transaction
        if (this.txs.length == 0)
            return 0;

        immutable pow2_size = getPow2Aligned(this.txs.length);
        assert(this.merkle_tree.length == (pow2_size * 2) - 1,
            "Block hasn't been fully initialized");

        auto index = this.merkle_tree[0 .. this.txs.length]
            .enumerate.assumeSorted.find!(res => res[1] == hash);

        return index.empty ? this.txs.length : index.front[0];
    }

    /// Returns a range of any freeze transactions in this block
    public auto frozens () const @safe pure nothrow
    {
        return this.txs.filter!(tx => tx.isFreeze);
    }

    /// Returns a range of any payment transactions in this block
    public auto payments () const @safe pure nothrow
    {
        return this.txs.filter!(tx => tx.isPayment);
    }
}

///
unittest
{
    immutable Hash merkle =
        Hash(`0xdb6e67f59fe0b30676037e4970705df8287f0de38298dcc09e50a8e85413` ~
        `959ca4c52a9fa1edbe6a47cbb6b5e9b2a19b4d0877cc1f5955a7166fe6884eecd2c3`);

    immutable address = `boa1xrra39xpg5q9zwhsq6u7pw508z2let6dj8r5lr4q0d0nff240fvd27yme3h`;
    PublicKey pubkey = PublicKey.fromString(address);

    Transaction tx = Transaction(
        [
            Output(Amount(62_500_000L * 10_000_000L), pubkey),
            Output(Amount(62_500_000L * 10_000_000L), pubkey),
            Output(Amount(62_500_000L * 10_000_000L), pubkey),
            Output(Amount(62_500_000L * 10_000_000L), pubkey),
            Output(Amount(62_500_000L * 10_000_000L), pubkey),
            Output(Amount(62_500_000L * 10_000_000L), pubkey),
            Output(Amount(62_500_000L * 10_000_000L), pubkey),
            Output(Amount(62_500_000L * 10_000_000L), pubkey)
        ]);

    auto validators = typeof(BlockHeader.validators)(6);
    validators[0] = true;
    validators[2] = true;
    validators[4] = true;

    Enrollment[] enrollments;
    enrollments ~= Enrollment.init;
    enrollments ~= Enrollment.init;

    Block block =
    {
        header:
        {
            prev_block:  Hash.init,
            height:      Height(0),
            merkle_root: merkle,
            validators:  validators,
            signature:   Signature.fromString(
                            "0x0f55e869b35fdd36a1f5147771c0c2f5ad35ec7b3e4e"
                            ~ "4f77bd37f1e0aef06d1a4b62ed5c610735b73e3175"
                            ~ "47ab3dc3402b05fd57419a2a5def798a03df2ef56a"),
            enrollments: enrollments,
        },
        txs: [ tx ],
        merkle_tree: [ merkle ],
    };
    testSymmetry!Block();
    testSymmetry(block);
    assert(block.header.validators[0]);
    assert(!block.header.validators[1]);
}

/*******************************************************************************

    Create a new block, referencing the provided previous block.

    Params:
        prev_block = the previous block
        txs = the transactions that will be contained in the new block
        preimages = Pre-images that have been revealed in this block
                    Non-revealed pre-images must be passed as `Hash.init`
                    in their respective positions.
        enrollments = the enrollments that will be contained in the new block

*******************************************************************************/

public Block makeNewBlock (Transactions)(const ref Block prev_block,
    Transactions txs, Hash[] preimages,
    Enrollment[] enrollments = null)
    @safe nothrow
{
    static assert (isInputRange!Transactions);

    Block block;
    auto preimages_rng = preimages.filter!(pi => pi !is Hash.init);
    assert(!preimages_rng.empty);

    block.header.prev_block = prev_block.header.hashFull();
    block.header.height = prev_block.header.height + 1;
    block.header.preimages = preimages;
    block.header.validators = BitMask(preimages.length);
    block.header.enrollments = enrollments;
    block.header.enrollments.sort!((a, b) => a.utxo_key < b.utxo_key);
    assert(block.header.enrollments.isStrictlyMonotonic!
        ("a.utxo_key < b.utxo_key"));  // there cannot be duplicates either

    txs.each!(tx => block.txs ~= tx);
    block.txs.sort;

    block.header.merkle_root = block.buildMerkleTree();
    return block;
}

/// only used in unittests with some defaults
version (unittest)
{
    import agora.consensus.data.genesis.Test: genesis_validator_keys;
    import agora.utils.Test;

    public Block makeNewTestBlock (Transactions)(const ref Block prev_block,
        Transactions txs,
        in KeyPair[] key_pairs = genesis_validator_keys,
        Enrollment[] enrollments = null,
        uint[] missing_validators = null) @safe nothrow
    {
        Hash[] pre_images =
            WK.PreImages.at(prev_block.header.height + 1, key_pairs)
            .enumerate.map!(en => missing_validators.canFind(en.index) ? Hash.init : en.value)
            .array;
        try
        {
            auto block = makeNewBlock(prev_block, txs, pre_images, enrollments);
            auto validators = BitMask(key_pairs.length);
            Signature[] sigs;
            key_pairs.enumerate.each!((i, k)
            {
                if (!missing_validators.canFind(i))
                {
                    validators[i] = true;
                    sigs ~= block.header.sign(k.secret, pre_images[i]);
                }
            });
            auto signed_block = block.updateSignature(multiSigCombine(sigs), validators);
            return signed_block;
        }
        catch (Exception e)
        {
            () @trusted
            {
                import std.format;
                assert(0, format!"makeNewTestBlock exception thrown during test: %s"(e));
            }();
        }
        return Block.init;
    }
}

///
@safe nothrow unittest
{
    import agora.consensus.data.genesis.Test;

    auto new_block = makeNewTestBlock(GenesisBlock, [Transaction.init]);
    auto rng_block = makeNewTestBlock(GenesisBlock, [Transaction.init].take(1));
    assert(new_block.header.prev_block == hashFull(GenesisBlock.header));
    assert(new_block == rng_block);

    Enrollment enr_1 =
    {
        utxo_key : Hash(
            "0x412ce227771d98240ffb0015ae49349670eded40267865c18f655db662d4e698f" ~
            "7caa4fcffdc5c068a07532637cf5042ae39b7af418847385480e620e1395986")
    };

    Enrollment enr_2 =
    {
        utxo_key : Hash(
            "0x412ce227771d98240ffb0015ae49349670eded40267865c18f655db662d4e698f" ~
            "7caa4fcffdc5c068a07532637cf5042ae39b7af418847385480e620e1395987")
    };

    Hash[] preimages =
        WK.PreImages.at(GenesisBlock.header.height + 1, genesis_validator_keys);

    auto block = makeNewBlock(GenesisBlock, [Transaction.init],
        preimages, [enr_1, enr_2]);
    assert(block.header.enrollments == [enr_1, enr_2]);  // ascending
    block = makeNewBlock(GenesisBlock, [Transaction.init],
        preimages, [enr_2, enr_1]);
    assert(block.header.enrollments == [enr_1, enr_2]);  // ditto
}

///
@safe nothrow unittest
{
    import agora.consensus.data.genesis.Test;
    assert(GenesisBlock.header.hashFull() == GenesisBlock.hashFull());
}

/// Test of Merkle Path and Merkle Proof
unittest
{
    Transaction[] txs;
    Hash[] merkle_path;

    KeyPair[] key_pairs = [
        KeyPair.random(),
        KeyPair.random(),
        KeyPair.random(),
        KeyPair.random(),
        KeyPair.random(),
        KeyPair.random(),
        KeyPair.random(),
        KeyPair.random(),
        KeyPair.random()
    ];

    // Create transactions.
    Hash last_hash = Hash.init;
    for (int idx = 0; idx < 8; idx++)
    {
        auto tx = Transaction([Input(last_hash, 0)],[Output(Amount(100_000), key_pairs[idx+1].address)]);
        tx.inputs[0].unlock = genKeyUnlock(
            key_pairs[idx].sign(tx.getChallenge()));
        txs ~= tx;
    }

    Block block;

    block.header.prev_block = Hash.init;
    block.header.height = Height(0);
    block.txs ~= txs;
    block.header.merkle_root = block.buildMerkleTree();

    Hash[] hashes;
    hashes.reserve(txs.length);
    foreach (ref e; txs)
        hashes ~= hashFull(e);

    // transactions are ordered lexicographically by hash in the Merkle tree
    hashes.sort!("a < b");
    foreach (idx, hash; hashes)
        assert(block.findHashIndex(hash) == idx);

    const Hash ha = hashes[0];
    const Hash hb = hashes[1];
    const Hash hc = hashes[2];
    const Hash hd = hashes[3];
    const Hash he = hashes[4];
    const Hash hf = hashes[5];
    const Hash hg = hashes[6];
    const Hash hh = hashes[7];

    const Hash hab = hashMulti(ha, hb);
    const Hash hcd = hashMulti(hc, hd);
    const Hash hef = hashMulti(he, hf);
    const Hash hgh = hashMulti(hg, hh);

    const Hash habcd = hashMulti(hab, hcd);
    const Hash hefgh = hashMulti(hef, hgh);

    const Hash habcdefgh = hashMulti(habcd, hefgh);

    assert(block.header.merkle_root == habcdefgh);

    // Merkle Proof
    merkle_path = block.getMerklePath(2);
    assert(merkle_path.length == 3);
    assert(merkle_path[0] == hd);
    assert(merkle_path[1] == hab);
    assert(merkle_path[2] == hefgh);
    assert(block.header.merkle_root == Block.checkMerklePath(hc, merkle_path, 2));

    merkle_path = block.getMerklePath(4);
    assert(merkle_path.length == 3);
    assert(merkle_path[0] == hf);
    assert(merkle_path[1] == hgh);
    assert(merkle_path[2] == habcd);
    assert(block.header.merkle_root == Block.checkMerklePath(he, merkle_path, 4));
}

// test when the number of txs is not a strict power of 2
unittest
{
    auto kp = KeyPair.random();
    Transaction[] txs;
    Hash[] hashes;

    foreach (amount; 0 .. 9)
    {
        txs ~= Transaction(
            [Input(Hash.init, 0)],
            [Output(Amount(amount + 1), kp.address)]);
        hashes ~= hashFull(txs[$ - 1]);
    }

    Block block;
    block.txs = txs;
    block.header.merkle_root = block.buildMerkleTree();

    // transactions are ordered lexicographically by hash in the Merkle tree
    hashes.sort!("a < b");
    foreach (idx, hash; hashes)
        assert(block.findHashIndex(hash) == idx);

    const Hash ha = hashes[0];
    const Hash hb = hashes[1];
    const Hash hc = hashes[2];
    const Hash hd = hashes[3];
    const Hash he = hashes[4];
    const Hash hf = hashes[5];
    const Hash hg = hashes[6];
    const Hash hh = hashes[7];
    const Hash hi = hashes[8];
    const Hash hj = hashes[8];
    const Hash hk = hashes[8];
    const Hash hl = hashes[8];
    const Hash hm = hashes[8];
    const Hash hn = hashes[8];
    const Hash ho = hashes[8];
    const Hash hp = hashes[8];

    const Hash hab = hashMulti(ha, hb);
    const Hash hcd = hashMulti(hc, hd);
    const Hash hef = hashMulti(he, hf);
    const Hash hgh = hashMulti(hg, hh);
    const Hash hij = hashMulti(hi, hj);
    const Hash hkl = hashMulti(hk, hl);
    const Hash hmn = hashMulti(hm, hn);
    const Hash hop = hashMulti(ho, hp);

    const Hash habcd = hashMulti(hab, hcd);
    const Hash hefgh = hashMulti(hef, hgh);
    const Hash hijkl = hashMulti(hij, hkl);
    const Hash hmnop = hashMulti(hmn, hop);

    const Hash habcdefgh = hashMulti(habcd, hefgh);
    const Hash hijklmnop = hashMulti(hijkl, hmnop);

    const Hash habcdefghijklmnop = hashMulti(habcdefgh, hijklmnop);

    assert(block.header.merkle_root == habcdefghijklmnop);

    auto merkle_path = block.getMerklePath(2);
    assert(merkle_path.length == 4);
    assert(merkle_path[0] == hd);
    assert(merkle_path[1] == hab);
    assert(merkle_path[2] == hefgh);
    assert(merkle_path[3] == hijklmnop);
    assert(block.header.merkle_root == Block.checkMerklePath(hc, merkle_path, 2));

    merkle_path = block.getMerklePath(4);
    assert(merkle_path.length == 4);
    assert(merkle_path[0] == hf);
    assert(merkle_path[1] == hgh);
    assert(merkle_path[2] == habcd);
    assert(merkle_path[3] == hijklmnop);
    assert(block.header.merkle_root == Block.checkMerklePath(he, merkle_path, 4));

    merkle_path = block.getMerklePath(8);
    assert(merkle_path.length == 4);
    assert(merkle_path[0] == hj);
    assert(merkle_path[1] == hkl);
    assert(merkle_path[2] == hmnop);
    assert(merkle_path[3] == habcdefgh);
    assert(block.header.merkle_root == Block.checkMerklePath(hi, merkle_path, 8));
}

/// demonstrate signing two blocks at height 1 to reveal private node key
unittest
{
    import agora.consensus.data.genesis.Test: GenesisBlock;
    import agora.crypto.ECC: Scalar, Point;
    import agora.utils.Test;
    import std.format;

    const TimeOffset = 1;
    auto preimages =
        WK.PreImages.at(GenesisBlock.header.height + 1, genesis_validator_keys);

    // Generate two blocks at height 1
    auto block1 = GenesisBlock.makeNewBlock(
        genesisSpendable().take(1).map!(txb => txb.refund(WK.Keys.A.address).sign()),
        preimages);
    auto block2 = GenesisBlock.makeNewBlock(
        genesisSpendable().take(1).map!(txb => txb.refund(WK.Keys.Z.address).sign()),
        preimages);

    // Two messages
    auto c1 = block1.hashFull();
    auto c2 = block2.hashFull();
    assert(c1 != c2);

    // Sign with same s twice
    auto key = genesis_validator_keys[0].secret;
    Signature sig1 = block1.header.sign(key, preimages[0]);
    Signature sig2 = block2.header.sign(key, preimages[0]);

    // Verify signatures
    assert(block1.header.verify(genesis_validator_keys[0].address, block1.header.preimages[0], sig1.R));
    assert(block2.header.verify(genesis_validator_keys[0].address, block1.header.preimages[0], sig2.R));

    // Calculate the private key by subtraction
    // `s = (c * r) + v`
    // Reusing the same `s` (pre-image) means we end up with the following system:
    // s = (c1 * r1) + v
    // s = (c2 * r2) + v
    // We know `s`, `c1` and `c2`.

    // Note: Since the scheme was changed, `r` is not reused, and this might
    // not be possible anymore, and could require an on-chain mechanism for slashing.
    version (none)
    {
        Scalar s = (sig1.s - sig2.s);
        Scalar c = (c1 - c2);

        Scalar secret = s * c.invert();
        assert(secret == v,
               format!"Key %s is not matching key %s"
               (secret.toString(PrintMode.Clear), v.toString(PrintMode.Clear)));
    }
}
