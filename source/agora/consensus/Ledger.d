/*******************************************************************************

    The `Ledger` class binds together other components to provide a consistent
    view of the state of the node.

    The Ledger acts as a bridge between other components, e.g. the `UTXOSet`,
    `EnrollmentManager`, `IBlockStorage`, etc...
    While the `Node` is the main object in Agora, the `Ledger` is the second
    most important class, handling all business logic, relying on the the `Node`
    for anything related to network communicatiion.

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.Ledger;

import agora.common.Amount;
import agora.common.Ensure;
import agora.common.ManagedDatabase;
import agora.common.Set;
import agora.common.Types;
import agora.consensus.data.Block;
import agora.consensus.data.Enrollment;
import agora.consensus.data.Params;
import agora.consensus.data.PreImageInfo;
import agora.consensus.data.Transaction;
import agora.consensus.EnrollmentManager;
import agora.consensus.Fee;
import agora.consensus.pool.Transaction;
import agora.consensus.protocol.Data;
import agora.consensus.Reward;
import agora.consensus.state.UTXOSet;
import agora.consensus.validation;
import agora.crypto.Hash;
import agora.crypto.Key;
import agora.network.Clock;
import agora.node.BlockStorage;
import agora.script.Engine;
import agora.script.Lock;
import agora.serialization.Serializer;
import agora.utils.Log;
import agora.utils.PrettyPrinter;

import std.algorithm;
import std.conv : to;
import std.exception : assumeUnique, assumeWontThrow;
import std.format;
import std.range;
import std.typecons : Nullable, nullable;

import core.time : Duration, seconds;

version (unittest)
{
    import agora.consensus.data.genesis.Test: genesis_validator_keys;
    import agora.utils.Test;
}

/// Ditto
public class Ledger
{
    /// Logger instance
    protected Logger log;

    /// Script execution engine
    private Engine engine;

    /// data storage for all the blocks
    private IBlockStorage storage;

    /// Pool of transactions to pick from when generating blocks
    private TransactionPool pool;

    /// TX Hashes Ledger encountered but dont have in the pool
    private Set!Hash unknown_txs;

    /// The last block in the ledger
    private Block last_block;

    /// UTXO set
    private UTXOCache utxo_set;

    /// Enrollment manager
    private EnrollmentManager enroll_man;

    /// If not null call this delegate
    /// A block was externalized
    private void delegate (in Block, bool) @safe onAcceptedBlock;

    /// Parameters for consensus-critical constants
    private immutable(ConsensusParams) params;

    /// The checker of transaction data payload
    private FeeManager fee_man;

    /// Block rewards calculator
    private Reward rewards;

    /// Cache for Coinbase tx to be used during payout height
    struct CachedCoinbase
    {
        private Height height;
        private Transaction tx;
    }
    private CachedCoinbase cached_coinbase;

    /***************************************************************************

        Constructor

        Params:
            params = the consensus-critical constants
            engine = script execution engine
            utxo_set = the set of unspent outputs
            storage = the block storage
            enroll_man = the enrollmentManager
            pool = the transaction pool
            fee_man = the FeeManager
            onAcceptedBlock = optional delegate to call
                              when a block was added to the ledger

    ***************************************************************************/

    public this (immutable(ConsensusParams) params,
        Engine engine, UTXOCache utxo_set, IBlockStorage storage,
        EnrollmentManager enroll_man, TransactionPool pool,
        FeeManager fee_man,
        void delegate (in Block, bool) @safe onAcceptedBlock = null)
    {
        this.log = Logger(__MODULE__);
        this.params = params;
        this.engine = engine;
        this.utxo_set = utxo_set;
        this.storage = storage;
        this.enroll_man = enroll_man;
        this.pool = pool;
        this.onAcceptedBlock = onAcceptedBlock;
        this.fee_man = fee_man;
        this.storage.load(params.Genesis);
        this.rewards = new Reward(this.params.PayoutPeriod, this.params.BlockInterval);

        // ensure latest checksum can be read
        this.last_block = this.storage.readLastBlock();
        log.info("Last known block: #{} ({})", this.last_block.header.height,
                 this.last_block.header.hashFull());

        Block gen_block = this.storage.readBlock(Height(0));
        ensure(gen_block == params.Genesis,
                "Genesis block loaded from disk ({}) is different from the one in the config file ({})",
                gen_block.hashFull(), params.Genesis.hashFull());

        if (this.utxo_set.length == 0
            || this.enroll_man.validator_set.countActive(this.last_block.header.height + 1) == 0)
        {
            this.utxo_set.clear();
            this.enroll_man.validator_set.removeAll();

            // Calling `addValidatedBlock` will reset this value
            const HighestHeight = this.last_block.header.height;
            foreach (height; 0 .. HighestHeight + 1)
            {
                this.replayStoredBlock(this.storage.readBlock(Height(height)));
            }
        }
    }

    /***************************************************************************

        Returns the last block in the `Ledger`

        Returns:
            last block in the `Ledger`

    ***************************************************************************/

    public ref const(Block) getLastBlock () const scope @safe @nogc nothrow pure
    {
        return this.last_block;
    }

    /***************************************************************************

        Returns:
            The highest block height known to this Ledger

    ***************************************************************************/

    public Height getBlockHeight () const scope @safe @nogc nothrow pure
    {
        return this.last_block.header.height;
    }

    /***************************************************************************

        Expose the list of validators at a given height

        The `ValidatorInfo` struct contains the validator's UTXO hash, address,
        stake and currently highest known pre-image.
        It always returns valid historical data (although the pre-image might
        be the current one).

        Callers expecting the pre-image at a given height should first check
        that the `height` is above or equal their expectation, then use
        the `opIndex` method to get the correct value for the height they
        are interested in. This method doesn't expose a mean to do so directly
        because it would then need to filter out missing validators,
        which would give the caller wrong indexes for validators.

        Params:
          height = Height at which to query the validator set.
                   Accurate results are only guaranteed for
                   `height <= this.getBlockHeight() + 1`.
          empty = Whether to allow an empty return value.
                  By default, this function will throw if there is no validators
                  at `height`. If `true` is passed, it will not.

        Throws:
          If no validators are present at height `height` and `empty` is `false`.

        Returns:
            A list of validators that are active at `height`

    ***************************************************************************/

    public ValidatorInfo[] getValidators (in Height height, bool empty = false)
        scope @safe
    {
        // There are no validators at Genesis, and no one able to sign the block
        // This is by design, and to allow calling code to work correctly without
        // special-casing height == 0, we just return `null`.
        if (height == 0) return null;

        auto result = this.enroll_man.validator_set.getValidators(height);
        ensure(empty || result.length > 0,
               "Ledger.getValidators didn't find any validator at height {}", height);
        return result;
    }

    /***************************************************************************

        Add a pre-image information to a validator data

        Params:
            preimage = the pre-image information to add

        Returns:
            true if the pre-image information has been added to the validator

    ***************************************************************************/

    public bool addPreimage (in PreImageInfo preimage) @safe nothrow
    {
        return this.enroll_man.validator_set.addPreimage(preimage);
    }

    /***************************************************************************

        Add a block to the ledger.

        If the block fails verification, it is not added to the ledger.

        Params:
            block = the block to add

        Returns:
            an error message if the block is not accepted, otherwise null

    ***************************************************************************/

    public string acceptBlock (in Block block) @safe
    {
        if (auto fail_reason = this.validateBlock(block))
        {
            log.trace("Rejected block: {}: {}", fail_reason, block.prettify());
            return fail_reason;
        }

        const old_count = this.enroll_man.validator_set.countActive(block.header.height);

        this.storage.saveBlock(block);
        this.addValidatedBlock(block);

        const new_count = this.enroll_man.validator_set.countActive(block.header.height + 1);
        // there was a change in the active validator set
        const bool validators_changed = block.header.enrollments.length > 0
            || new_count != old_count;
        if (this.onAcceptedBlock !is null)
            this.onAcceptedBlock(block, validators_changed);

        return null;
    }

    /***************************************************************************

        Update the Schnorr multi-signature for an externalized block
        in the Ledger.

        Params:
            header = block header to be updated

    ***************************************************************************/

    public void updateBlockMultiSig (in BlockHeader header) @safe
    {
        this.storage.updateBlockSig(header.height, header.hashFull(),
            header.signature, header.validators);

        if (header.height == this.last_block.header.height)
            this.last_block = this.storage.readLastBlock();
    }

    /***************************************************************************

        Called when a new transaction is received.

        If the transaction is accepted it will be added to
        the transaction pool.

        If the transaction is invalid, it's rejected and false is returned.

        Params:
            tx = the received transaction
            double_spent_threshold_pct =
                          See `Config.node.double_spent_threshold_pct`
            min_fee_pct = See `Config.node.min_fee_pct`

        Returns:
            reason why invalid or null if the transaction is valid and was added
            to the pool

    ***************************************************************************/

    public string acceptTransaction (in Transaction tx,
        in ubyte double_spent_threshold_pct = 0,
        in ushort min_fee_pct = 0) @safe
    {
        const Height expected_height = this.getBlockHeight() + 1;
        auto tx_hash = hashFull(tx);

        // If we were looking for this TX, stop
        this.unknown_txs.remove(tx_hash);

        if (tx.isCoinbase)
            return "Coinbase transaction";
        if (this.pool.hasTransactionHash(tx_hash))
            return "Transaction already in the pool";

        if (auto reason = tx.isInvalidReason(this.engine,
                this.utxo_set.getUTXOFinder(),
                expected_height, &this.fee_man.check,
                &this.getPenaltyDeposit))
            return reason;

        auto min_fee = this.pool.getAverageFeeRate();
        if (!min_fee.percentage(min_fee_pct))
            assert(0);

        Amount fee_rate;
        if (auto err = this.fee_man.getTxFeeRate(tx, this.utxo_set.getUTXOFinder(),
            &this.getPenaltyDeposit, fee_rate))
            return err;
        if (fee_rate < min_fee)
            return "Fee rate is lower than this node's configured relative threshold (min_fee_pct)";
        if (!this.isAcceptableDoubleSpent(tx, double_spent_threshold_pct))
            return "Double spend comes with a less-than-acceptable fee increase";

        return this.pool.add(tx, fee_rate) ? null : "Rejected by storage";
    }

    /***************************************************************************

        Add a validated block to the Ledger.

        This will add all of the block's outputs to the UTXO set, as well as
        any enrollments that may be present in the block to the validator set.

        If not null call the `onAcceptedBlock` delegate.

        Params:
            block = the block to add

    ***************************************************************************/

    private void addValidatedBlock (in Block block) @safe
    {
        log.info("Beginning externalization of block #{}", block.header.height);
        log.info("Transactions: {} - Enrollments: {}",
                 block.txs.length, block.header.enrollments.length);
        log.info("Validators: Active: {} - Signing: {} - Slashed: {}",
                 enroll_man.validator_set.countActive(block.header.height + 1),
                 block.header.validators,
                 block.header.preimages.count!(h => h is Hash.init));
        // Keep track of the fees generated by this block, before updating the
        // validator set

        // Store the fees for this block if not Genesis
         if (block.header.height > 0)
            this.fee_man.storeValidatedBlockFees(block, this.utxo_set.getUTXOFinder,
                &this.getPenaltyDeposit);

        ManagedDatabase.beginBatch();
        {
            // rollback on failure within the scope of the db transactions
            scope (failure) ManagedDatabase.rollback();
            this.applySlashing(block.header);
            this.updateUTXOSet(block);
            this.updateValidatorSet(block);
            ManagedDatabase.commitBatch();
        }

        // Clear the unknown TXs every round (clear() is not @safe)
        this.unknown_txs = Set!Hash.init;

        // if this was a block with fees payout
        if (block.header.height >= 2 * this.params.PayoutPeriod
            && block.header.height % this.params.PayoutPeriod == 0)
        {
            // Clear out paid fees
            this.fee_man.clearBlockFeesBefore(Height(block.header.height - this.params.PayoutPeriod));
        }
        // Update the known "last block"
        this.last_block = deserializeFull!Block(serializeFull(block));
        log.info("Completed externalization of block #{}", block.header.height);
    }

    /***************************************************************************

        Update the ledger state from a block which was read from storage

        Params:
            block = block to update the state from

    ***************************************************************************/

    protected void replayStoredBlock (in Block block) @safe
    {
        // Make sure our data on disk is valid
        if (auto fail_reason = this.validateBlock(block))
            ensure(false, "A block loaded from disk is invalid: {}", fail_reason);

        this.addValidatedBlock(block);
    }

    /***************************************************************************

        Apply slashing to the current state

        When a node is slashed, two actions are taken:
        - First, it is "removed" from the validator set;
          In practice, we store the height at which a node is slashed.
        - Second, its stake is consumed: One refund is created to the key
          controlling the stake, and a penalty is sent to the commons budget.

        This is the first action that happens during block externalization,
        so that slashed UTXOs are not spent by transactions.

        Params:
            header = The `BlockHeader` containing the slashing information

    ***************************************************************************/

    protected void applySlashing (in BlockHeader header) @safe
    {
        // In the most common case, there should be no slashing information.
        // In this case, we should avoid calling `getValidators`, as it allocates,
        // and doesn't handle Genesis.
        auto slashed = header.preimages.enumerate
            .filter!(en => en.value is Hash.init).map!(en => en.index);
        if (slashed.empty)
            return;

        auto validators = this.getValidators(header.height);

        foreach (idx; slashed)
        {
            const validator = validators[idx];
            UTXO utxo_value;
            if (!this.utxo_set.peekUTXO(validator.utxo, utxo_value))
                assert(0, "UTXO for the slashed validator not found!");

            log.warn("Slashing validator {} at height {}: {} (UTXO: {})",
                     idx, header.height, validator, utxo_value);
            this.enroll_man.validator_set.slashValidator(validator.utxo, header.height);
        }
    }

    /***************************************************************************

        Update the UTXO set based on the block's transactions

        Params:
            block = the block to update the UTXO set with

    ***************************************************************************/

    protected void updateUTXOSet (in Block block) @safe
    {
        const height = block.header.height;
        // add the new UTXOs
        block.txs.each!(tx => this.utxo_set.updateUTXOCache(tx, height,
            this.params.CommonsBudgetAddress));

        // remove the TXs from the Pool
        block.txs.each!(tx => this.pool.remove(tx));
    }

    /***************************************************************************

        Update the active validator set

        Params:
            block = the block to update the Validator set with

    ***************************************************************************/

    protected void updateValidatorSet (in Block block) @safe
    {
        PublicKey pubkey = this.enroll_man.getEnrollmentPublicKey();
        UTXO[Hash] utxos = this.utxo_set.getUTXOs(pubkey);
        foreach (idx, ref enrollment; block.header.enrollments)
        {
            UTXO utxo;
            if (!this.utxo_set.peekUTXO(enrollment.utxo_key, utxo))
                assert(0);

            if (auto r = this.enroll_man.addValidator(enrollment, utxo.output.address,
                block.header.height, &this.utxo_set.peekUTXO, &this.getPenaltyDeposit, utxos))
            {
                log.fatal("Error while adding a new validator: {}", r);
                log.fatal("Enrollment #{}: {}", idx, enrollment);
                log.fatal("Validated block: {}", block);
                assert(0);
            }
            this.utxo_set.updateUTXOLock(enrollment.utxo_key, block.header.height + this.params.ValidatorCycle);
        }
    }

    /***************************************************************************

        Checks whether the `tx` is an acceptable double spend transaction.

        If `tx` is not a double spend transaction, then returns true.
        If `tx` is a double spend transaction, and its fee is considerable higher
        than the existing double spend transactions, then returns true.
        Otherwise this function returns false.

        Params:
            tx = transaction
            threshold_pct = percentage by which the fee of the new transaction has
              to be higher, than the previously highest double spend transaction

        Returns:
            whether the `tx` is an acceptable double spend transaction

    ***************************************************************************/

    public bool isAcceptableDoubleSpent (in Transaction tx, ubyte threshold_pct) @safe
    {

        Amount rate;
        if (this.fee_man.getTxFeeRate(tx, &utxo_set.peekUTXO, &this.getPenaltyDeposit, rate).length)
            return false;

        // only consider a double spend transaction, if its fee is
        // considerably higher than the current highest fee
        auto fee_threshold = getDoubleSpentHighestFee(tx);

        // if the fee_threshold is null, it means there won't be any double
        // spend transactions, after this transaction is added to the pool
        if (!fee_threshold.isNull())
            fee_threshold.get().percentage(threshold_pct + 100);

        if (!fee_threshold.isNull() &&
            (!rate.isValid() || rate < fee_threshold.get()))
            return false;

        return true;
    }

    /***************************************************************************

        Create the `Coinbase transaction` for this payout block and append it
        to the `transaction set`

        Params:
            height = block height
            tot_fee = Total fee amount (incl. data)
            tot_data_fee = Total data fee amount

        Returns:
            `Coinbase transaction`

    ***************************************************************************/

    public Transaction getCoinbaseTX (in Height height) nothrow @safe
    {
        assert(height >= 2 * this.params.PayoutPeriod);

        if (cached_coinbase.height == height)
            return cached_coinbase.tx;

        Output[] coinbase_tx_outputs;

        Amount[PublicKey] payouts;

        // pay the Validators and Commons Budget for the blocks in the penultimate payout period
        const firstPayoutHeight = Height(1 + height - 2 * this.params.PayoutPeriod);
        try
        {
            this.getBlocksFrom(firstPayoutHeight)
                .takeExactly(this.params.PayoutPeriod)
                .map!(block => block.header)
                .each!((BlockHeader header)
                    {
                        // Fetch validators at this height and filter out those who did not sign
                        // the block as they will not get paid for this block
                        auto validators = this.getValidators(header.height)
                            .enumerate.filter!(en => header.validators[en.index]).map!(en => en.value);

                        // penalty for utxos slashed on this height
                        auto slashed_penaly = this.params.SlashPenaltyAmount *
                            header.preimages.enumerate.filter!(en => en.value is Hash.init).walkLength;
                        payouts.update(this.params.CommonsBudgetAddress,
                            { return slashed_penaly; },
                            (ref Amount so_far)
                            {
                                so_far += slashed_penaly;
                                return so_far;
                            }
                        );

                        // Calculate the block rewards using the percentage of validators who signed
                        auto rewards = this.rewards.calculateBlockRewards(header.height, header.validators.percentage());

                        // Divide up the validator fees and rewards based on stakes
                        auto val_payouts = this.fee_man.getValidatorPayouts(header.height, rewards, validators);

                        // Update the payouts that will be included in the Coinbase tx for each validator
                        val_payouts.zip(validators).each!((Amount payout, ValidatorInfo validator) =>
                            payouts.update(validator.address,
                                { return payout; }, // if first for this validator use this payout
                                    (ref Amount so_far) // otherwise use delegate to keep running total
                                    {
                                        so_far += payout; // Add this payout to sum so far
                                        return so_far;
                                    }));
                        auto commons_payout = this.fee_man.getCommonsBudgetPayout(header.height, rewards, val_payouts);
                        payouts.update(this.params.CommonsBudgetAddress,
                            { return commons_payout; },
                                (ref Amount so_far)
                                    {
                                        so_far += commons_payout;
                                        return so_far;
                                    });
                    });
            assert(payouts.length > 0);
            foreach (pair; payouts.byKeyValue())
            {
                if (pair.value > Amount(0))
                    coinbase_tx_outputs ~= Output(pair.value, pair.key, OutputType.Coinbase);
                else
                    log.error("Zero valued Coinbase output for key {}\npayouts={}", pair.key, payouts);
            }
            assert(coinbase_tx_outputs.length > 0, format!"payouts=%s"(payouts));
            coinbase_tx_outputs.sort;

            cached_coinbase.height = height;
            cached_coinbase.tx = Transaction([Input(height)], coinbase_tx_outputs);
            return cached_coinbase.tx;
        }
        catch (Exception e)
        {
            assert(0, format!"getCoinbaseTX: Exception thrown:%s"(e.msg));
        }
    }

    ///
    public Amount getPenaltyDeposit (Hash utxo) @safe nothrow
    {
        UTXO utxo_val;
        if (!this.peekUTXO(utxo, utxo_val) || utxo_val.output.type != OutputType.Freeze)
            return 0.coins;
        EnrollmentState last_enrollment;
        if (this.enroll_man.getEnrollmentFinder()(utxo, last_enrollment) && last_enrollment.slashed_height != 0)
            return 0.coins;
        return this.params.SlashPenaltyAmount;
    }

    /// Error message describing the reason of validation failure
    public static enum InvalidConsensusDataReason : string
    {
        NotEnoughValidators = "Enrollment: Insufficient number of active validators",
        MayBeValid = "May be valid",
        TooManyMPVs = "More MPVs than active enrollments",
        NoUTXO = "Couldn't find UTXO for one or more Enrollment",
        NotInPool = "Transaction is not in the pool",

    }

    /***************************************************************************

        Check whether the consensus data is valid.

        Params:
            data = consensus data
            initial_missing_validators = missing validators at the beginning of
               the nomination round

        Returns:
            the error message if validation failed, otherwise null

    ***************************************************************************/

    public string validateConsensusData (in ConsensusData data,
        in uint[] initial_missing_validators) @trusted nothrow
    {
        const validating = this.getBlockHeight() + 1;
        auto utxo_finder = this.utxo_set.getUTXOFinder();

        Transaction[] tx_set;
        if (auto fail_reason = this.getValidTXSet(data, tx_set, utxo_finder))
            return fail_reason;

        // av   == active validators (this block)
        // avnb == active validators next block
        // The consensus data is for the creation of the next block,
        // so 'this block' means "current height + 1". While the ConsensusData
        // does not contain information about what block we are validating,
        // we assume that it's the block after the currently externalized one.
        size_t av   = enroll_man.validator_set.countActive(validating);
        size_t avnb = enroll_man.validator_set.countActive(validating + 1);

        // First we make sure that we do not slash too many validators,
        // as slashed validators cannot sign a block.
        // If there are 6 validators, and we're slashing 5 of them,
        // av = 6, missing_validators.length = 5, and `6 < 5 + 1` is still `true`.
        if (av < (data.missing_validators.length + Enrollment.MinValidatorCount))
            return InvalidConsensusDataReason.NotEnoughValidators;

        // We're trying to slash more validators that there are next block
        // FIXME: this check isn't 100% correct: we should check which validators
        // we are slashing. It could be that our of 5 validators, 3 are expiring
        // this round, and none of them have revealed their pre-image, in which
        // case the 3 validators we slash should not block externalization.
        if (avnb < data.missing_validators.length)
            return InvalidConsensusDataReason.TooManyMPVs;
        // FIXME: See above comment
        avnb -= data.missing_validators.length;

        // We need to make sure that we externalize a block that allows for the
        // chain to make progress, otherwise we'll be stuck forever.
        if ((avnb + data.enrolls.length) < Enrollment.MinValidatorCount)
            return InvalidConsensusDataReason.NotEnoughValidators;

        foreach (const ref enroll; data.enrolls)
        {
            UTXO utxo_value;
            if (!this.utxo_set.peekUTXO(enroll.utxo_key, utxo_value))
                return InvalidConsensusDataReason.NoUTXO;
            if (auto fail_reason = this.enroll_man.isInvalidCandidateReason(
                enroll, utxo_value.output.address, validating, utxo_finder, &this.getPenaltyDeposit))
                return fail_reason;
        }

        try if (auto fail_reason = this.validateSlashingData(validating, data, initial_missing_validators, utxo_finder))
                return fail_reason;

        catch (Exception exc)
        {
            log.error("Caught Exception while validating slashing data: {}", exc);
            return "Internal error while validating slashing data";
        }

        return null;
    }

    /***************************************************************************

        Check whether the slashing data is valid.

        Params:
            height = height
            data = consensus data
            initial_missing_validators = missing validators at the beginning of
               the nomination round
            utxo_finder = UTXO finder with double spent protection

        Returns:
            the error message if validation failed, otherwise null

    ***************************************************************************/

    public string validateSlashingData (in Height height, in ConsensusData data,
        in uint[] initial_missing_validators, scope UTXOFinder utxo_finder) @safe
    {
        return this.isInvalidPreimageRootReason(height, data.missing_validators,
            initial_missing_validators, utxo_finder);
    }

    /***************************************************************************

        Check whether the block is valid.

        Params:
            block = the block to check

        Returns:
            an error message if the block validation failed, otherwise null

    ***************************************************************************/

    public string validateBlock (in Block block) nothrow @safe
    {
        // If it's the genesis block, we only need to validate it for syntactic
        // correctness, no need to check signatures.
        if (block.header.height == 0)
            return block.isGenesisBlockInvalidReason();

        // Validate the block syntactically first, so we weed out obviously-wrong
        // blocks without complex computation.
        if (auto reason = block.isInvalidReason(
                this.engine, this.last_block.header.height,
                this.last_block.header.hashFull,
                this.utxo_set.getUTXOFinder(),
                &this.fee_man.check,
                this.enroll_man.getEnrollmentFinder(),
                &this.getPenaltyDeposit,
                block.header.validators.count))
            return reason;

        // At this point we know it is the next block and also that it isn't Genesis
        try
        {
            const validators = this.getValidators(block.header.height);
            if (validators.length != block.header.preimages.length)
                return "Block: Number of preimages does not match active validators";
            foreach (idx, const ref hash; block.header.preimages)
            {
                if (hash is Hash.init)
                {
                    // TODO: Check that the block contains a slashing transaction
                }
                // We don't have this pre-image yet
                else if (validators[idx].preimage.height < block.header.height)
                {
                    PreImageInfo pi = validators[idx].preimage;
                    pi.height = block.header.height;
                    pi.hash = hash;
                    if (!this.addPreimage(pi))
                        return "Block: Preimages include an invalid non-revealed pre-image";
                }
                else
                {
                    // TODO: By caching the 'current' hash, we can prevent a semi
                    // DoS if a node reveal a pre-image far in the future and then
                    // keep on submitting wrong blocks.
                    const expected = validators[idx].preimage[Height(block.header.height)];
                    if (hash !is expected)
                    {
                        log.error("Validator: {} - Index: {} - Expected: {} - Got: {}",
                                  validators[idx], idx, expected, hash);
                        return "Block: One of the pre-image is invalid";
                    }
                }
            }
        }
        catch (Exception exc)
        {
            log.error("Exception thrown while validating block: {}", exc);
            return "Block: Internal error while validating";
        }

        auto incoming_cb_txs = block.txs.filter!(tx => tx.isCoinbase);
        const cbTxCount = incoming_cb_txs.count;
        // If it is a payout block then a single Coinbase transaction is included
        if (block.header.height >= 2 * this.params.PayoutPeriod
            && block.header.height % this.params.PayoutPeriod == 0)
        {
            if (cbTxCount == 0)
                return "Missing expected Coinbase transaction in payout block";
            if (cbTxCount > 1)
                return "There should only be one Coinbase transaction in payout block";
        }
        else if (cbTxCount != 0)
            return "Found Coinbase transaction in a non payout block";

        // Finally, validate the signatures
        return this.validateBlockSignature(block);
    }

    /***************************************************************************

        Validate the signature of a block

        This validate that the signature in a block header is consistent with
        the enrolled validators, and cryptographically correct.
        Note that since this requires to know which nodes are validators,
        this method is contextful and can only guarantee the signature
        of the next block, as the validator set might change after that.

        Implementation_details:
          A block signature is an Schnorr signature. Schnorr signatures are
          usually a pair `(R, s)`, consisting of a point `R` and a scalar `s`.

          The signature is done on the block header, with the two fields
          used to store signatures (`validators` and `signature`) excluded.

          To allow for nodes to independently generate compatible signatures
          without an additional protocol, nodes need to know the set of signers
          and their `R`, which we refer to as signature noise.

          The set of signers is defined as all the validators having revealed
          a pre-image. For this reason, pre-images are allowed and encouraged
          to be revealed earlier than they are needed (although not too early).

          With the set of signers known, we derive the block-specific `R`
          by adding the `R` used in the enrollment to `p * B`, where `p` is
          the pre-image reduced to a scalar and `B` is Curve25519 base point.

          Hence, the signature present in the block is actually just the
          aggregated `s`. To verify this signature, we need to store which
          nodes actually signed, this is stored in the header's
          `validators` field.

        Params:
            block = the block to verify the signature of

        Returns:
            the error message if block validation failed, otherwise null

    ***************************************************************************/

    private string validateBlockSignature (in Block block) @safe nothrow
    {
        import agora.crypto.ECC;

        Point sum_K;
        Scalar sum_s;
        const Scalar challenge = hashFull(block);
        ValidatorInfo[] validators;
        try
            validators = this.getValidators(block.header.height);
        catch (Exception exc)
        {
            this.log.error("Exception thrown by getActiveValidatorPublicKey while externalizing valid block: {}", exc);
            return "Internal error: Could not list active validators at current height";
        }

        assert(validators.length == block.header.validators.count);
        // Check that more than half have signed
        auto signed = block.header.validators.setCount;
        if (signed <= validators.length / 2)
            if (auto fail_msg = this.handleNotSignedByMajority(block.header, validators))
                return fail_msg;

        log.trace("Checking signature, participants: {}/{}", signed, validators.length);
        foreach (idx, validator; validators)
        {
            const K = validator.address;
            assert(K != PublicKey.init, "Could not find the public key associated with a validator");

            if (!block.header.validators[idx])
            {
                // This is not an error, we might just receive the signature later
                log.trace("Block#{}: Validator {} (idx: {}) has not yet signed",
                          block.header.height, K, idx);
                continue;
            }

            const pi = block.header.preimages[idx];
            // TODO: Currently we consider that validators slashed at this height
            // can sign the block (e.g. they have a space in the bit field),
            // however without their pre-image they can't sign the block.
            if (pi is Hash.init)
                continue;

            sum_K = sum_K + K;
            sum_s = sum_s + Scalar(pi);
        }

        assert(sum_K != Point.init, "Block has validators but no signature");

        // If this doesn't match, the block is not self-consistent
        if (sum_s != block.header.signature.s)
        {
            log.error("Block#{}: Signature's `s` mismatch: Expected {}, got {}",
                      block.header.height, sum_s, block.header.signature.s);
            return "Block: Invalid schnorr signature (s)";
        }
        if (!BlockHeader.verify(sum_K, sum_s, block.header.signature.R, challenge))
        {
            log.error("Block#{}: Invalid signature: {}", block.header.height,
                      block.header.signature);
            return "Block: Invalid signature";
        }

        return null;
    }

    /***************************************************************************

        Used to handle behaviour when less than half the validators have signed
        the block. This is overridden in the `ValidatingLedger`

        Params:
            header = header of block we checked
            validators = validator info for the ones that did sign

    ***************************************************************************/


    protected string handleNotSignedByMajority (in BlockHeader header,
        in ValidatorInfo[] validators) @safe nothrow
    {
        log.error("Block#{}: Signatures are not majority: {}/{}, signers: {}",
            header.height, header.validators.setCount, header.validators.count, validators);
        return "The majority of validators hasn't signed this block";
    }

    /***************************************************************************

        Get a range of blocks, starting from the provided block height.

        Params:
            start_height = the starting block height to begin retrieval from

        Returns:
            the range of blocks starting from start_height

    ***************************************************************************/

    public auto getBlocksFrom (Height start_height) @safe nothrow
    {
        start_height = min(start_height, this.getBlockHeight() + 1);

        // Call to `Height.value` to work around
        // https://issues.dlang.org/show_bug.cgi?id=21583
        return iota(start_height.value, this.getBlockHeight() + 1)
            .map!(idx => this.storage.readBlock(Height(idx)));
    }

    /***************************************************************************

        Create a new block based on the current previous block.

        This function only builds a block and will not externalize it.
        See `acceptBlock` for this.

        Params:
          txs = An `InputRange` of `Transaction`s
          enrollments = New enrollments for this block (can be `null`)
          missing_validators = Indices of slashed validators (may be `null`)

        Returns:
          A newly created block based on the current block
          (See `Ledger.getLastBlock()` and `Ledger.getBlockHeight()`)

    ***************************************************************************/

    public Block buildBlock (Transactions) (Transactions txs,
        Enrollment[] enrollments, uint[] missing_validators)
        @safe
    {
        const height = this.getBlockHeight() + 1;
        const validators = this.getValidators(height);

        Hash[] preimages = validators.enumerate.map!(
            (in entry)
            {
                if (missing_validators.canFind(entry.index))
                    return Hash.init;

                if (entry.value.preimage.height < height)
                {
                    ensure(false,
                           "buildBlock: Missing pre-image ({} < {}) for index {} ('{}') " ~
                           "but index is not in missing_validators ({})",
                           entry.value.preimage.height, height,
                           entry.index, entry.value.utxo, missing_validators);
                }

                return entry.value.preimage[height];
            }).array;

        return this.last_block.makeNewBlock(txs, preimages, enrollments);
    }

    /***************************************************************************

        Forwards to `FeeManager.getTxFeeRate`, using this Ledger's UTXO.

    ***************************************************************************/

    public string getTxFeeRate (in Transaction tx, out Amount rate) @safe nothrow
    {
        return this.fee_man.getTxFeeRate(tx, &this.utxo_set.peekUTXO, &this.getPenaltyDeposit, rate);
    }

    /***************************************************************************

        Looks up transaction with hash `tx_hash`, then forwards to
        `FeeManager.getTxFeeRate`, using this Ledger's UTXO.

    ***************************************************************************/

    public string getTxFeeRate (in Hash tx_hash, out Amount rate) nothrow @safe
    {
        auto tx = this.pool.getTransactionByHash(tx_hash);
        if (tx == Transaction.init)
            return InvalidConsensusDataReason.NotInPool;
        return this.getTxFeeRate(tx, rate);
    }

    /***************************************************************************

        Returns the highest fee among all the transactions which would be
        considered as a double spent, if `tx` transaction was in the transaction
        pool.

        If adding `tx` to the transaction pool would not result in double spent
        transaction, then the return value is Nullable!Amount().

        Params:
            tx = transaction

        Returns:
            the highest fee among all the transactions which would be
            considered as a double spend, if `tx` transaction was in the
            transaction pool.

    ***************************************************************************/

    public Nullable!Amount getDoubleSpentHighestFee (in Transaction tx) @safe
    {
        Set!Hash tx_hashes;
        pool.gatherDoubleSpentTXs(tx, tx_hashes);

        const(Transaction)[] txs;
        foreach (const tx_hash; tx_hashes)
        {
            const tx_ret = this.pool.getTransactionByHash(tx_hash);
            if (tx_ret != Transaction.init)
                txs ~= tx_ret;
        }

        if (!txs.length)
            return Nullable!Amount();

        return nullable(txs.map!((tx)
            {
                Amount rate;
                this.fee_man.getTxFeeRate(tx, &utxo_set.peekUTXO, &this.getPenaltyDeposit, rate);
                return rate;
            }).maxElement());
    }

    /***************************************************************************

        Get a transaction from pool by hash

        Params:
            tx = the transaction hash

        Returns:
            Transaction or Transaction.init

    ***************************************************************************/

    public Transaction getTransactionByHash (in Hash hash) @trusted nothrow
    {
        return this.pool.getTransactionByHash(hash);
    }

    /***************************************************************************

        Get the valid TX set that `data` is representing

        Params:
            data = consensus value
            tx_set = buffer to write the found TXs
            utxo_finder = UTXO finder with double spent protection

        Returns:
            `null` if node can build a valid TX set, a string explaining
            the reason otherwise.

    ***************************************************************************/

    public string getValidTXSet (in ConsensusData data, ref Transaction[] tx_set,
        scope UTXOFinder utxo_finder)
        @safe nothrow
    {
        const expect_height = this.getBlockHeight() + 1;
        bool[Hash] local_unknown_txs;

        Amount tot_fee, tot_data_fee;
        scope checkAndAcc = (in Transaction tx, Amount sum_unspent) {
            const err = this.fee_man.check(tx, sum_unspent);
            if (!err && !tx.isCoinbase)
            {
                tot_fee.add(sum_unspent);
                tot_data_fee.add(
                    this.fee_man.getDataFee(tx.payload.length));
            }
            return err;
        };

        foreach (const ref tx_hash; data.tx_set)
        {
            auto tx = this.pool.getTransactionByHash(tx_hash);
            if (tx == Transaction.init)
                local_unknown_txs[tx_hash] = true;
            else if (auto fail_reason = tx.isInvalidReason(this.engine,
                utxo_finder, expect_height, checkAndAcc, &this.getPenaltyDeposit))
                return fail_reason;
            else
                tx_set ~= tx;
        }

        // This is payout block and we have at least two payout periods
        if (expect_height >= 2 * this.params.PayoutPeriod
            && expect_height % this.params.PayoutPeriod == 0)
        {
            auto coinbase_tx = this.getCoinbaseTX(expect_height);
            auto coinbase_tx_hash = coinbase_tx.hashFull();
            log.trace("getValidTXSet: Coinbase hash={}, tx={}", coinbase_tx_hash, coinbase_tx.prettify);
            assert(coinbase_tx.outputs.length > 0);

            // Because CB TXs are never in the pool, they will always end up in
            // local_unknown_txs.
            if (local_unknown_txs.length == 0)
                return "Missing Coinbase transaction";
            if (!local_unknown_txs.remove(coinbase_tx_hash))
                return "Missing matching Coinbase transaction"; // Coinbase tx is missing or different
            tx_set ~= coinbase_tx;
        }
        if (local_unknown_txs.length > 0)
        {
            local_unknown_txs.byKey.each!(tx => this.unknown_txs.put(tx));
            log.warn("getValidTXSet: local_unknown_txs.length={}, unknown_txs.length={}",
                local_unknown_txs.length, this.unknown_txs.length);
            return InvalidConsensusDataReason.MayBeValid;
        }

        return null;
    }

    /***************************************************************************

        Get a set of TX Hashes that Ledger is missing

        Returns:
            set of TX Hashes that Ledger is missing

    ***************************************************************************/

    public Set!Hash getUnknownTXHashes () @safe nothrow
    {
        return this.unknown_txs;
    }

    /***************************************************************************

        Check if information for pre-images and slashed validators is valid

        Params:
            height = the height of proposed block
            missing_validators = list of indices to the validator UTXO set
                which have not revealed the preimage
            missing_validators_higher_bound = missing validators at the beginning of
               the nomination round
            utxo_finder = UTXO finder with double spent protection

        Returns:
            `null` if the information is valid at the proposed height,
            otherwise a string explaining the reason it is invalid.

    ***************************************************************************/

    private string isInvalidPreimageRootReason (in Height height,
        in uint[] missing_validators, in uint[] missing_validators_higher_bound,
        scope UTXOFinder utxo_finder) @safe
    {
        import std.algorithm.setops : setDifference;

        auto validators = this.getValidators(height);
        assert(validators.length <= uint.max);

        uint[] missing_validators_lower_bound = validators.enumerate
            .filter!(kv => kv.value.preimage.height < height)
            .map!(kv => cast(uint) kv.index).array();

        // NodeA will check the candidate from NodeB in the following way:
        //
        // Current missing validators in NodeA(=sorted_missing_validators_lower_bound) ⊆
        // missing validators in the candidate from NodeB(=sorted_missing_validators) ⊆
        // missing validators in NodeA before the nomination round started
        // (=sorted_missing_validators_higher_bound)
        //
        // If both of those conditions true, then NodeA will accept the candidate.

        auto sorted_missing_validators = missing_validators.dup().sort();
        auto sorted_missing_validators_lower_bound = missing_validators_lower_bound.dup().sort();
        auto sorted_missing_validators_higher_bound = missing_validators_higher_bound.dup().sort();

        if (!setDifference(sorted_missing_validators_lower_bound, sorted_missing_validators).empty())
            return "Lower bound violation - Missing validator mismatch " ~
                assumeWontThrow(to!string(sorted_missing_validators_lower_bound)) ~
                " is not a subset of " ~ assumeWontThrow(to!string(sorted_missing_validators));

        if (!setDifference(sorted_missing_validators, sorted_missing_validators_higher_bound).empty())
            return "Higher bound violation - Missing validator mismatch " ~
                assumeWontThrow(to!string(sorted_missing_validators)) ~
                " is not a subset of " ~ assumeWontThrow(to!string(sorted_missing_validators_higher_bound));

        if (missing_validators.any!(idx => idx >= validators.length))
            return "Slashing non existing index";
        UTXO utxo;
        if (missing_validators.any!(idx => !utxo_finder(validators[idx].utxo, utxo)))
            return "Cannot slash a spent UTXO";

        return null;
    }

    /// return the last paid out block before the current block
    public Height getLastPaidHeight () const scope @safe @nogc nothrow pure
    {
        return lastPaidHeight(this.getBlockHeight, this.params.PayoutPeriod);
    }

    /***************************************************************************

        Get an UTXO, no double-spend protection.

        Params:
            hash = the hash of the UTXO (`hashMulti(tx_hash, index)`)
            value = the UTXO

        Returns:
            true if the UTXO was found

    ***************************************************************************/

    public bool peekUTXO (in Hash utxo, out UTXO value) nothrow @safe
    {
        return this.utxo_set.peekUTXO(utxo, value);
    }

    /// Returns: UTXOs for validator active at the given height
    public UTXO[Hash] getEnrolledUTXOs (in Height height) @safe nothrow
    {
        UTXO[Hash] utxos;
        Hash[] keys;
        if (this.enroll_man.validator_set.getEnrolledUTXOs(height, keys))
            foreach (key; keys)
            {
                UTXO val;
                assert(this.peekUTXO(key, val));
                utxos[key] = val;
            }
        return utxos;
    }

    /// Ditto
    public UTXO[Hash] getEnrolledUTXOs () @safe nothrow
    {
        return this.getEnrolledUTXOs(this.getBlockHeight() + 1);
    }

    /***************************************************************************

        Prepare tracking double-spent transactions and
        return the UTXOFinder delegate

        Returns:
            the UTXOFinder delegate

    ***************************************************************************/

    public UTXOFinder getUTXOFinder () nothrow @trusted
    {
        return this.utxo_set.getUTXOFinder();
    }

    /***************************************************************************

        Returns: A list of Enrollments that can be used for the next block

    ***************************************************************************/

    public Enrollment[] getCandidateEnrollments (in Height height,
        scope UTXOFinder utxo_finder) @safe
    {
        return this.enroll_man.getEnrollments(height, &this.utxo_set.peekUTXO,
            &this.getPenaltyDeposit, utxo_finder);
    }

    /***************************************************************************

        Add an enrollment data to the enrollment pool

        Params:
            enroll = the enrollment data to add
            pubkey = the public key of the enrollment
            height = block height for enrollment

        Returns:
            true if the enrollment data has been added to the enrollment pool

    ***************************************************************************/

    public bool addEnrollment (in Enrollment enroll, in PublicKey pubkey,
        in Height height) @safe nothrow
    {
        return this.enroll_man.addEnrollment(enroll, pubkey, height,
            &this.peekUTXO, &this.getPenaltyDeposit);
    }

    version (unittest):

    /// Make sure the preimages are available when the block is validated
    private void simulatePreimages (in Height height, uint[] skip_indexes = null) @safe
    {
        auto validators = this.getValidators(height);

        void addPreimageLog (in PublicKey public_key, in PreImageInfo preimage_info)
        {
            log.info("Adding test preimages for height {} for validator {}: {}", height, public_key, preimage_info);
            this.addPreimage(preimage_info);
        }
        validators.enumerate.each!((idx, val)
        {
            if (skip_indexes.length && skip_indexes.canFind(idx))
                log.info("Skip add preimage for validator idx {} at height {} as requested by test", idx, height);
            else
                addPreimageLog(val.address, PreImageInfo(val.preimage.utxo,
                    WK.PreImages[WK.Keys[val.address]][height], height));
        });
    }
}

/// This is the last block height that has had fees and rewards paid before the current block
private Height lastPaidHeight(in Height height, uint payout_period) @safe @nogc nothrow pure
{
    // We return 1 before the first payout is made as we use this for block signature catchup and Genesis is never updated
    if (height < 2 * payout_period)
        return  Height(1);
    return Height(height - (height % payout_period) - payout_period);
}

// expected is the height of last block that has had fees and rewards paid
unittest
{
    import std.range;
    import std.typecons;

    const uint paymentPeriod = 3;
    only(tuple(0,1), tuple(1,1), tuple(4,1), tuple(5,1), // test before first fee and reward block is externalized
        tuple(6,3), tuple(7,3), tuple(8,3), // test before second is externalized
        tuple(9,6), tuple(10,6)).each!( // last we test after second
        (height, expected) => assert(lastPaidHeight(Height(height), paymentPeriod) == expected));
}

/*******************************************************************************

    A ledger that participate in the consensus protocol

    This ledger is held by validators, as they need to do additional bookkeeping
    when e.g. proposing transactions.

*******************************************************************************/

public class ValidatingLedger : Ledger
{
    /// See parent class
    public this (immutable(ConsensusParams) params,
        Engine engine, UTXOSet utxo_set, IBlockStorage storage,
        EnrollmentManager enroll_man, TransactionPool pool,
        FeeManager fee_man,
        void delegate (in Block, bool) @safe onAcceptedBlock)
    {
        super(params, engine, utxo_set, storage, enroll_man, pool, fee_man,
            onAcceptedBlock);
    }

    // dynamic array to keep track of blocks we are externalizing so can allow
    //  less signatures than majority when validating
    // TODO: We need to clear out old entries to reduce memory footprint
    private Height[] externalizing;

    public void addHeightAsExternalizing (Height height) @safe nothrow
    {
        this.externalizing ~= height;
    }

    /***************************************************************************

        Used to handle behaviour when less than half the validators have signed
        the block. If we are in process of externalizing blocks we ignore when
        there is less than half signed as we are waiting to recieve the other
        signatures.

        Params:
            header = header of block we checked
            validators = validator info for the ones that did sign

    ***************************************************************************/

    protected override string handleNotSignedByMajority (in BlockHeader header,
        in ValidatorInfo[] validators) @safe nothrow
    {
        if (!externalizing.canFind(header.height))
            return super.handleNotSignedByMajority(header, validators);

        log.trace("Block#{}: Externalizing so ignore Signatures are not majority: {}/{}, signers: {}.",
            header.height, header.validators.setCount, header.validators.count, validators);
        return null;
    }

    /***************************************************************************

        Collect up to a maximum number of transactions to nominate

        Params:
            txs = will contain the transaction set to nominate,
                  or empty if not enough txs were found
            max_txs = the maximum number of transactions to prepare.

    ***************************************************************************/

    public void prepareNominatingSet (out ConsensusData data, ulong max_txs)
        @safe
    {
        const next_height = this.getBlockHeight() + 1;

        auto utxo_finder = this.utxo_set.getUTXOFinder();
        data.enrolls = this.getCandidateEnrollments(next_height, utxo_finder);
        data.missing_validators = this.getCandidateMissingValidators(next_height, utxo_finder);
        data.tx_set = this.getCandidateTransactions(next_height, max_txs, utxo_finder);
        if (next_height >= 2 * this.params.PayoutPeriod
            && next_height % this.params.PayoutPeriod == 0)   // This is a Coinbase payout block
            {
                auto coinbase_tx = this.getCoinbaseTX(next_height);
                auto coinbase_hash = coinbase_tx.hashFull();
                log.info("prepareNominatingSet: Coinbase hash={}, tx={}", coinbase_hash, coinbase_tx.prettify);
                data.tx_set ~= coinbase_hash;
            }
    }

    /// Validate slashing data, including checking if the node is slef slashing
    public override string validateSlashingData (in Height height, in ConsensusData data,
        in uint[] initial_missing_validators, scope UTXOFinder utxo_finder) @safe
    {
        if (auto res = super.validateSlashingData(height, data, initial_missing_validators, utxo_finder))
            return res;

        const self = this.enroll_man.getEnrollmentKey();
        foreach (index, const ref validator; this.getValidators(height))
        {
            if (self != validator.utxo())
                continue;

            return data.missing_validators.find(index).empty ? null
                : "Node is attempting to slash itself";
        }
        return null;
    }

    /***************************************************************************

        Returns:
            A list of Validators that have not yet revealed their PreImage for
            height `height` (based on the current Ledger's knowledge).

    ***************************************************************************/

    public uint[] getCandidateMissingValidators (in Height height,
        scope UTXOFinder findUTXO) @safe
    {
        UTXO utxo;
        return this.getValidators(height).enumerate()
            .filter!(en => en.value.preimage.height < height)
            .filter!(en => findUTXO(en.value.preimage.utxo, utxo))
            .map!(en => cast(uint) en.index)
            .array();
    }

    /***************************************************************************

        Returns:
            A list of Transaction hash that can be included in the next block

    ***************************************************************************/

    public Hash[] getCandidateTransactions (in Height height, ulong max_txs,
        scope UTXOFinder utxo_finder) @safe
    {
        Hash[] result;
        Amount tot_fee, tot_data_fee;

        foreach (ref Hash hash, ref Transaction tx; this.pool)
        {
            scope checkAndAcc = (in Transaction tx, Amount sum_unspent) {
                const err = this.fee_man.check(tx, sum_unspent);
                if (!err)
                {
                    tot_fee.add(sum_unspent);
                    tot_data_fee.add(
                        this.fee_man.getDataFee(tx.payload.length));
                }
                return err;
            };

            if (auto reason = tx.isInvalidReason(
                    this.engine, utxo_finder, height, checkAndAcc, &this.getPenaltyDeposit))
                log.trace("Rejected invalid ('{}') tx: {}", reason, tx);
            else
                result ~= hash;

            if (result.length >= max_txs)
            {
                break;
            }
        }
        result.sort();
        return result;
    }

    version (unittest):

    private string externalize (ConsensusData data) @trusted
    {
        const height = Height(this.last_block.header.height + 1);
        auto utxo_finder = this.utxo_set.getUTXOFinder();

        Transaction[] externalized_tx_set;
        if (auto fail_reason = this.getValidTXSet(data, externalized_tx_set, utxo_finder))
        {
            log.info("Ledger.externalize: can not create new block at Height {} : {}. Fail reason : {}",
                height, data.prettify, fail_reason);
            return fail_reason;
        }

        auto block = this.buildBlock(externalized_tx_set,
            data.enrolls, data.missing_validators);

        this.getValidators(height).enumerate.each!((i, v)
        {
            if (!data.missing_validators.canFind(i))
            {
                block.header.validators[i] = true;
                auto tmp = block.header.sign(WK.Keys[v.address].secret, block.header.preimages[i]);
                block.header.signature.R += tmp.R;
                block.header.signature.s += tmp.s;
            }
        });
        return this.acceptBlock(block);
    }

    /// simulate block creation as if a nomination and externalize round completed
    public void forceCreateBlock (ulong max_txs = Block.TxsInTestBlock)
    {
        const next_block = this.getBlockHeight() + 1;
        this.simulatePreimages(next_block);
        ConsensusData data;
        this.prepareNominatingSet(data, max_txs);
        assert(data.tx_set.length >= max_txs);

        // If the user provided enrollments, do not re-enroll automatically
        // If they didn't, check to see if the next block needs them
        // In which case, we simply re-enroll the validators already enrolled
        if (data.enrolls.length == 0 &&
            this.enroll_man.validator_set.countActive(next_block + 1) == 0)
        {
            auto validators = this.getValidators(this.getBlockHeight());
            foreach (v; validators)
            {
                Hash cycle_seed;
                Height cycle_seed_height;
                auto kp = WK.Keys[v.address];
                getCycleSeed(kp, this.params.ValidatorCycle, cycle_seed, cycle_seed_height);
                assert(cycle_seed != Hash.init);
                assert(cycle_seed_height != Height(0));
                auto enroll = EnrollmentManager.makeEnrollment(
                    v.utxo, kp, next_block,
                    cycle_seed, cycle_seed_height);

                data.enrolls ~= enroll;
            }
        }

        if (auto reason = this.externalize(data))
        {
            assert(0, format!"Failure in unit test. Block %s should have been externalized: %s"(
                       this.getBlockHeight() + 1, reason));
        }
    }

    /// Generate a new block by creating transactions, then calling `forceCreateBlock`
    private Transaction[] makeTestBlock (
        Transaction[] last_txs, ulong txs = Block.TxsInTestBlock)
    {
        assert(txs > 0);

        // Special case for genesis
        if (!last_txs.length)
        {
            assert(this.getBlockHeight() == 0);

            last_txs = genesisSpendable().take(Block.TxsInTestBlock).enumerate()
                .map!(en => en.value.refund(WK.Keys.A.address).sign())
                .array();
            last_txs.each!(tx => this.acceptTransaction(tx));
            this.forceCreateBlock(txs);
            return last_txs;
        }

        last_txs = last_txs.map!(tx => TxBuilder(tx).sign()).array();
        last_txs.each!(tx => assert(this.acceptTransaction(tx) is null));
        this.forceCreateBlock(txs);
        return last_txs;
    }
}

/// Note: these unittests historically assume a block always contains
/// 8 transactions - hence the use of `TxsInTestBlock` appearing everywhere.
version (unittest)
{
    import agora.consensus.PreImage;
    import agora.node.Config;
    import core.stdc.time : time;

    /// A `Ledger` with sensible defaults for `unittest` blocks
    public final class TestLedger : ValidatingLedger
    {
        public this (KeyPair key_pair,
            const(Block)[] blocks = null,
            immutable(ConsensusParams) params_ = null,
            void delegate (in Block, bool) @safe onAcceptedBlock = null)
        {
            const params = (params_ !is null)
                ? params_
                : (blocks.length > 0
                   // Use the provided Genesis block
                   ? new immutable(ConsensusParams)(
                       cast(immutable)blocks[0], WK.Keys.CommonsBudget.address,
                       ConsensusConfig(ConsensusConfig.init.genesis_timestamp))
                   // Use the unittest genesis block
                   : new immutable(ConsensusParams)());

            ValidatorConfig vconf = ValidatorConfig(true, key_pair);
            getCycleSeed(key_pair, params.ValidatorCycle, vconf.cycle_seed, vconf.cycle_seed_height);
            assert(vconf.cycle_seed != Hash.init);
            assert(vconf.cycle_seed_height != Height(0));

            auto stateDB = new ManagedDatabase(":memory:");
            auto cacheDB = new ManagedDatabase(":memory:");
            super(params,
                new Engine(TestStackMaxTotalSize, TestStackMaxItemSize),
                new UTXOSet(stateDB),
                new MemBlockStorage(blocks),
                new EnrollmentManager(stateDB, cacheDB, vconf, params),
                new TransactionPool(cacheDB),
                new FeeManager(stateDB, params),
                onAcceptedBlock);
        }

        ///
        protected override void replayStoredBlock (in Block block) @safe
        {
            if (block.header.height > 0)
                this.simulatePreimages(block.header.height);
            super.replayStoredBlock(block);
        }

        /// Property for Enrollment manager
        @property public EnrollmentManager enrollment_manager () @safe nothrow
        {
            return this.enroll_man;
        }
    }

    // sensible defaults
    private const TestStackMaxTotalSize = 16_384;
    private const TestStackMaxItemSize = 512;
}

///
unittest
{
    scope ledger = new TestLedger(WK.Keys.NODE3);
    assert(ledger.getBlockHeight() == 0);

    auto blocks = ledger.getBlocksFrom(Height(0)).take(10);
    assert(blocks[$ - 1] == ledger.params.Genesis);

    Transaction[] last_txs;
    void genBlockTransactions (size_t count)
    {
        foreach (_; 0 .. count)
            last_txs = ledger.makeTestBlock(last_txs);
    }

    genBlockTransactions(2);
    blocks = ledger.getBlocksFrom(Height(0)).take(10);
    assert(blocks[0] == ledger.params.Genesis);
    assert(blocks.length == 3);  // two blocks + genesis block

    /// now generate 98 more blocks to make it 100 + genesis block (101 total)
    genBlockTransactions(98);
    assert(ledger.getBlockHeight() == 100);

    blocks = ledger.getBlocksFrom(Height(0)).takeExactly(10);
    assert(blocks[0] == ledger.params.Genesis);
    assert(blocks.length == 10);

    /// lower limit
    blocks = ledger.getBlocksFrom(Height(0)).takeExactly(5);
    assert(blocks[0] == ledger.params.Genesis);
    assert(blocks.length == 5);

    /// different indices
    blocks = ledger.getBlocksFrom(Height(1)).takeExactly(10);
    assert(blocks[0].header.height == 1);
    assert(blocks.length == 10);

    blocks = ledger.getBlocksFrom(Height(50)).takeExactly(10);
    assert(blocks[0].header.height == 50);
    assert(blocks.length == 10);

    blocks = ledger.getBlocksFrom(Height(95)).take(10);  // only 6 left from here (block 100 included)
    assert(blocks.front.header.height == 95);
    assert(blocks.walkLength() == 6);

    blocks = ledger.getBlocksFrom(Height(99)).take(10);  // only 2 left from here (ditto)
    assert(blocks.front.header.height == 99);
    assert(blocks.walkLength() == 2);

    blocks = ledger.getBlocksFrom(Height(100)).take(10);  // only 1 block available
    assert(blocks.front.header.height == 100);
    assert(blocks.walkLength() == 1);

    // over the limit => return up to the highest block
    assert(ledger.getBlocksFrom(Height(0)).take(1000).walkLength() == 101);

    // higher index than available => return nothing
    assert(ledger.getBlocksFrom(Height(1000)).take(10).walkLength() == 0);
}

/// basic block verification
unittest
{
    scope ledger = new TestLedger(genesis_validator_keys[0]);

    Block invalid_block;  // default-initialized should be invalid
    assert(ledger.acceptBlock(invalid_block));
}

/// Situation: Ledger is constructed with blocks present in storage
/// Expectation: The UTXOSet is populated with all up-to-date UTXOs
unittest
{
    import agora.consensus.data.genesis.Test;

    const(Block)[] blocks = [
        GenesisBlock,
        makeNewTestBlock(GenesisBlock, GenesisBlock.spendable().map!(txb => txb.sign()))
    ];
    // Make 3 more blocks to put in storage
    foreach (idx; 2 .. 5)
    {
        blocks ~= makeNewTestBlock(
            blocks[$ - 1],
            blocks[$ - 1].spendable().map!(txb => txb.sign()));
    }

    // And provide it to the ledger
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks);

    assert(ledger.utxo_set.length
           == /* Genesis, Frozen */ 6 + 8 /* Block #1 Payments*/);

    // Ensure that all previously-generated outputs are in the UTXO set
    {
        auto findUTXO = ledger.utxo_set.getUTXOFinder();
        UTXO utxo;
        assert(
            blocks[$ - 1].txs.all!(
                tx => iota(tx.outputs.length).all!(
                    (idx) {
                        return findUTXO(UTXO.getHash(tx.hashFull(), idx), utxo) &&
                            utxo.output == tx.outputs[idx];
                    }
                )
            )
        );
    }
}

// Return Genesis block plus 'count' number of blocks
version (unittest)
private immutable(Block)[] genBlocksToIndex (
    size_t count, scope immutable(ConsensusParams) params)
{
    const(Block)[] blocks = [ params.Genesis ];
    scope ledger = new TestLedger(genesis_validator_keys[0]);
    foreach (_; 0 .. count)
    {
        auto txs = blocks[$ - 1].spendable().map!(txb => txb.sign());
        blocks ~= makeNewTestBlock(blocks[$ - 1], txs);
    }
    if (blocks)
    {
        ledger.simulatePreimages(blocks[$ - 1].header.height);
    }
    return blocks.assumeUnique;
}

/// test enrollments in the genesis block
unittest
{
    import std.exception : assertThrown;

    // Default test genesis block has 6 validators
    {
        scope ledger = new TestLedger(WK.Keys.A);
        assert(ledger.getValidators(Height(1)).length == 6);
    }

    // One block before `ValidatorCycle`, validator is still active
    {
        const ValidatorCycle = 20;
        auto params = new immutable(ConsensusParams)(ValidatorCycle);
        const blocks = genBlocksToIndex(ValidatorCycle - 1, params);
        scope ledger = new TestLedger(WK.Keys.A, blocks, params);
        Hash[] keys;
        assert(ledger.getValidators(Height(ValidatorCycle)).length == 6);
    }

    // Past `ValidatorCycle`, validator is inactive
    {
        const ValidatorCycle = 20;
        auto params = new immutable(ConsensusParams)(ValidatorCycle);
        const blocks = genBlocksToIndex(ValidatorCycle, params);
        // Enrollment: Insufficient number of active validators
        auto ledger = new TestLedger(WK.Keys.A, blocks, params);
        assertThrown(ledger.getValidators(Height(ValidatorCycle + 1)));
    }
}

/// test atomicity of adding blocks and rolling back
unittest
{
    import std.conv;
    import std.exception : assertThrown;
    import core.stdc.time : time;

    static class ThrowingLedger : Ledger
    {
        bool throw_in_update_utxo;
        bool throw_in_update_validators;

        public this (KeyPair kp, const(Block)[] blocks, immutable(ConsensusParams) params)
        {
            auto stateDB = new ManagedDatabase(":memory:");
            auto cacheDB = new ManagedDatabase(":memory:");
            ValidatorConfig vconf = ValidatorConfig(true, kp);
            super(params, new Engine(TestStackMaxTotalSize, TestStackMaxItemSize),
                new UTXOSet(stateDB),
                new MemBlockStorage(blocks),
                new EnrollmentManager(stateDB, cacheDB, vconf, params),
                new TransactionPool(cacheDB),
                new FeeManager(stateDB, params));
        }

        ///
        protected override void replayStoredBlock (in Block block) @safe
        {
            if (block.header.height > 0)
                this.simulatePreimages(block.header.height);
            super.replayStoredBlock(block);
        }

        override void updateUTXOSet (in Block block) @safe
        {
            super.updateUTXOSet(block);
            if (this.throw_in_update_utxo)
                throw new Exception("");
        }

        override void updateValidatorSet (in Block block) @safe
        {
            super.updateValidatorSet(block);
            if (this.throw_in_update_validators)
                throw new Exception("");
        }
    }

    const params = new immutable(ConsensusParams)();

    // throws in updateUTXOSet() => rollback() called, UTXO set reverted,
    // Validator set was not modified
    {
        const blocks = genBlocksToIndex(params.ValidatorCycle, params);
        assert(blocks.length == params.ValidatorCycle + 1);  // +1 for genesis

        scope ledger = new ThrowingLedger(
            WK.Keys.A, blocks.takeExactly(params.ValidatorCycle), params);
        assert(ledger.getValidators(Height(params.ValidatorCycle)).length == 6);
        auto utxos = ledger.utxo_set.getUTXOs(WK.Keys.Genesis.address);
        assert(utxos.length == 8);
        utxos.each!(utxo => assert(utxo.unlock_height == params.ValidatorCycle));

        ledger.throw_in_update_utxo = true;
        auto next_block = blocks[$ - 1];
        assertThrown!Exception(ledger.addValidatedBlock(next_block));
        assert(ledger.last_block == blocks[$ - 2]);  // not updated
        utxos = ledger.utxo_set.getUTXOs(WK.Keys.Genesis.address);
        assert(utxos.length == 8);
        utxos.each!(utxo => assert(utxo.unlock_height == params.ValidatorCycle));  // reverted
        // not updated
        assert(ledger.getValidators(Height(params.ValidatorCycle)).length == 6);
    }

    // throws in updateValidatorSet() => rollback() called, UTXO set and
    // Validator set reverted
    {
        const blocks = genBlocksToIndex(params.ValidatorCycle, params);
        assert(blocks.length == 21);  // +1 for genesis

        scope ledger = new ThrowingLedger(
            WK.Keys.A, blocks.takeExactly(params.ValidatorCycle), params);
        assert(ledger.getValidators(Height(params.ValidatorCycle)).length == 6);
        auto utxos = ledger.utxo_set.getUTXOs(WK.Keys.Genesis.address);
        assert(utxos.length == 8);
        utxos.each!(utxo => assert(utxo.unlock_height == params.ValidatorCycle));

        ledger.throw_in_update_validators = true;
        auto next_block = blocks[$ - 1];
        assertThrown!Exception(ledger.addValidatedBlock(next_block));
        assert(ledger.last_block == blocks[$ - 2]);  // not updated
        utxos = ledger.utxo_set.getUTXOs(WK.Keys.Genesis.address);
        assert(utxos.length == 8);
        utxos.each!(utxo => assert(utxo.unlock_height == params.ValidatorCycle));  // reverted
        assert(ledger.getValidators(ledger.last_block.header.height).length == 6);
    }
}

/// throw if the gen block in block storage is different to the configured one
unittest
{
    import agora.consensus.data.genesis.Test;
    import agora.consensus.data.genesis.Coinnet : CoinGenesis = GenesisBlock;

    // ConsensusParams is instantiated by default with the test genesis block
    immutable params = new immutable(ConsensusParams)(CoinGenesis, WK.Keys.CommonsBudget.address);

    try
    {
        scope ledger = new TestLedger(WK.Keys.A, [GenesisBlock], params);
        assert(0);
    }
    catch (Exception ex)
    {
        assert(ex.message ==
               "Genesis block loaded from disk " ~
               "(0x6db06ab1cae5c4b05e806401e2c42d526ebf4ac81411d0fcd82344561b5" ~
               "a25ae0d29728f5c1c9bec6cf254f621c183be71858a6ed5339c06fc5b34d7881b9b23) "~
               "is different from the one in the config file " ~
               "(0x47f30089ca49c3eacb09f2d96e4a27e1049697bbfe1002862344fd0b33b" ~
               "72d1b3b69467148905626e0a0f4845f5cdca69c25d2ec2663622acd45c38c974d0d91)");
    }

    immutable good_params = new immutable(ConsensusParams)();
    // will not fail
    scope ledger = new TestLedger(WK.Keys.A, [GenesisBlock], good_params);
    // Neither will the default
    scope other_ledger = new TestLedger(WK.Keys.A, [GenesisBlock]);
}

unittest
{
    scope ledger = new TestLedger(genesis_validator_keys[0]);
    scope fee_man = new FeeManager();

    // Generate payment transactions to the first 8 well-known keypairs
    auto txs = genesisSpendable().enumerate()
        .map!(en => en.value.refund(WK.Keys[en.index].address).sign())
        .array;
    txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
    ledger.forceCreateBlock();
    assert(ledger.getBlockHeight() == 1);

    // Create data with nomal size
    ubyte[] data;
    data.length = 64;
    foreach (idx; 0 .. data.length)
        data[idx] = cast(ubyte)(idx % 256);

    // Calculate fee
    Amount data_fee = fee_man.getDataFee(data.length);

    // Generate a block with data stored transactions
    txs = txs.enumerate()
        .map!(en => TxBuilder(en.value)
              .deduct(data_fee)
              .payload(data)
              .sign())
              .array;
    txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
    ledger.forceCreateBlock();
    assert(ledger.getBlockHeight() == 2);
    auto blocks = ledger.getBlocksFrom(Height(0)).take(10).array;
    assert(blocks.length == 3);
    assert(blocks[2].header.height == 2);

    auto not_coinbase_txs = blocks[2].txs.filter!(tx => tx.isPayment).array;
    foreach (ref tx; not_coinbase_txs)
    {
        assert(tx.outputs.any!(o => o.type != OutputType.Coinbase));
        assert(tx.outputs.length > 0);
        assert(tx.payload == data);
    }

    // Generate a block to reuse transactions used for data storage
    txs = txs.enumerate()
        .map!(en => TxBuilder(en.value)
              .refund(WK.Keys[Block.TxsInTestBlock + en.index].address)
              .sign())
              .array;
    txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
    ledger.forceCreateBlock();
    assert(ledger.getBlockHeight() == 3);
    blocks = ledger.getBlocksFrom(Height(0)).take(10).array;
    assert(blocks.length == 4);
    assert(blocks[3].header.height == 3);
}

// create slashing data and check validity for that
unittest
{
    import agora.consensus.data.genesis.Test;
    import agora.consensus.PreImage;

    auto params = new immutable(ConsensusParams)(20);
    const(Block)[] blocks = [ GenesisBlock ];
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks, params);

    Transaction[] genTransactions (Transaction[] txs)
    {
        return txs.enumerate()
            .map!(en => TxBuilder(en.value).refund(WK.Keys[en.index].address)
                .sign())
            .array;
    }

    Transaction[] genGeneralBlock (Transaction[] txs)
    {
        auto new_txs = genTransactions(txs);
        new_txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
        ledger.forceCreateBlock(Block.TxsInTestBlock);
        return new_txs;
    }

    // generate payment transaction to the first 8 well-known keypairs
    auto genesis_txs = genesisSpendable().array;
    auto txs = genesis_txs[0 .. 4].enumerate()
        .map!(en => en.value.refund(WK.Keys[en.index].address).sign()).array;
    txs ~= genesis_txs[4 .. 8].enumerate()
        .map!(en => en.value.refund(WK.Keys[en.index].address).sign()).array;
    txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
    ledger.forceCreateBlock();
    assert(ledger.getBlockHeight() == 1);

    // generate a block with only freezing transactions
    auto new_txs = txs[0 .. 4].enumerate()
        .map!(en => TxBuilder(en.value).refund(WK.Keys[en.index].address)
            .sign(OutputType.Freeze)).array;
    new_txs ~= txs[4 .. 7].enumerate()
        .map!(en => TxBuilder(en.value).refund(WK.Keys[en.index].address).sign())
        .array;
    new_txs ~= TxBuilder(txs[$ - 1]).split(WK.Keys[0].address.repeat(8)).sign();
    new_txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
    ledger.forceCreateBlock();
    assert(ledger.getBlockHeight() == 2);

    // UTXOs for enrollments
    Hash[] utxos = [
        UTXO.getHash(hashFull(new_txs[0]), 0),
        UTXO.getHash(hashFull(new_txs[1]), 0),
        UTXO.getHash(hashFull(new_txs[2]), 0),
        UTXO.getHash(hashFull(new_txs[3]), 0)
    ];

    new_txs = iota(new_txs[$ - 1].outputs.length).enumerate
        .map!(en => TxBuilder(new_txs[$ - 1], cast(uint)en.index)
            .refund(WK.Keys[en.index].address).sign())
        .array;
    new_txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
    ledger.forceCreateBlock();
    assert(ledger.getBlockHeight() == 3);

    foreach (height; 4 .. params.ValidatorCycle)
    {
        new_txs = genGeneralBlock(new_txs);
        assert(ledger.getBlockHeight() == Height(height));
    }

    // add four new enrollments
    Enrollment[] enrollments;
    auto pairs = iota(4).map!(idx => WK.Keys[idx]).array;
    foreach (idx, kp; pairs)
    {
        Hash cycle_seed;
        Height cycle_seed_height;
        getCycleSeed(kp, params.ValidatorCycle, cycle_seed, cycle_seed_height);
        assert(cycle_seed != Hash.init);
        assert(cycle_seed_height != Height(0));
        auto enroll = EnrollmentManager.makeEnrollment(
            utxos[idx], kp, Height(params.ValidatorCycle),
            cycle_seed, cycle_seed_height);
        assert(ledger.addEnrollment(enroll, kp.address,
            Height(params.ValidatorCycle)));
        enrollments ~= enroll;
    }

    foreach (idx, hash; utxos)
    {
        Enrollment stored_enroll = ledger.enrollment_manager.getEnrollment(hash);
        assert(stored_enroll == enrollments[idx]);
    }

    // create the last block of the cycle to make the `Enrollment`s enrolled
    new_txs = genGeneralBlock(new_txs);
    assert(ledger.getBlockHeight() == Height(20));
    auto b20 = ledger.getBlocksFrom(Height(20))[0];
    assert(b20.header.enrollments.length == 4);

    // block 21
    new_txs = genGeneralBlock(new_txs);
    assert(ledger.getBlockHeight() == Height(21));

    // check missing validators not revealing pre-images.
    auto temp_txs = genTransactions(new_txs);
    temp_txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));

    // Add preimages for validators at height 22 but skip for a couple
    uint[] skip_indexes = [ 1, 3 ];
    ledger.simulatePreimages(Height(22), skip_indexes);

    ConsensusData data;
    ledger.prepareNominatingSet(data, Block.TxsInTestBlock);
    assert(data.missing_validators.length == 2);
    assert(data.missing_validators == skip_indexes);

    // check validity of slashing information
    assert(ledger.validateSlashingData(Height(22), data, skip_indexes, ledger.utxo_set.getUTXOFinder()) == null);
    ConsensusData forged_data = data;
    forged_data.missing_validators = [3, 2, 1];
    assert(ledger.validateSlashingData(Height(22), forged_data, skip_indexes, ledger.utxo_set.getUTXOFinder()) != null);

    // Now reveal for all active validators at height 22
    ledger.simulatePreimages(Height(22));

    // there's no missing validator at the height of 22
    // after revealing preimages
    temp_txs.each!(tx => ledger.pool.remove(tx));
    temp_txs = genTransactions(new_txs);
    temp_txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));

    ledger.prepareNominatingSet(data, Block.TxsInTestBlock);
    assert(data.missing_validators.length == 0);
}

unittest
{
    import agora.consensus.data.genesis.Test;
    import agora.consensus.PreImage;
    import agora.utils.WellKnownKeys : CommonsBudget;

    ConsensusConfig config = { validator_cycle: 20, payout_period: 5 };
    auto params = new immutable(ConsensusParams)(GenesisBlock,
        CommonsBudget.address, config);

    const(Block)[] blocks = [ GenesisBlock ];
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks, params);

    // Add preimages for all validators (except for two of them) till end of cycle
    uint[] skip_indexes = [ 2, 5 ];

    ledger.simulatePreimages(Height(params.ValidatorCycle), skip_indexes);

    // Block with no fee
    auto no_fee_txs = blocks[$-1].spendable.map!(txb => txb.sign()).array();
    no_fee_txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));

    ConsensusData data;
    ledger.prepareNominatingSet(data, Block.TxsInTestBlock);

    assert(ledger.validateConsensusData(data, skip_indexes) is null);

    data.missing_validators = [2,3,5];
    assert(ledger.validateConsensusData(data, [2,3,5,7,9]) is null);

    data.missing_validators = [2,5];
    assert(ledger.validateConsensusData(data, [2]) == "Higher bound violation - Missing validator mismatch [2, 5] is not a subset of [2]");

    data.missing_validators = [5];
    assert(ledger.validateConsensusData(data, [2]) == "Lower bound violation - Missing validator mismatch [2, 5] is not a subset of [5]");
}

/// Testing accumulated fees paid to Commons Budget and non slashed Validators
unittest
{
    import agora.consensus.data.genesis.Test;
    import agora.consensus.PreImage;
    import agora.utils.WellKnownKeys : CommonsBudget;

    const testPayoutPeriod = 5;
    ConsensusConfig config = { validator_cycle: 20, payout_period: testPayoutPeriod };
    auto params = new immutable(ConsensusParams)(GenesisBlock,
        CommonsBudget.address, config);
    assert(params.PayoutPeriod == testPayoutPeriod);
    const(Block)[] blocks = [ GenesisBlock ];
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks, params);

    // Add preimages for all validators (except for two of them) till end of cycle
    uint[] skip_indexes = [ 2, 5 ];

    auto validators = ledger.getValidators(Height(1));
    UTXO[] mpv_stakes;
    foreach (skip; skip_indexes)
        assert(ledger.utxo_set.peekUTXO(validators[skip].utxo, mpv_stakes[(++mpv_stakes.length) - 1]));

    ledger.simulatePreimages(Height(params.ValidatorCycle), skip_indexes);

    assert(ledger.params.BlockInterval.total!"seconds" == 600);
    Amount allocated_validator_rewards = Amount.UnitPerCoin * 27 * (600 / 5);
    assert(allocated_validator_rewards == 3_240.coins);
    Amount commons_reward = Amount.UnitPerCoin * 50 * (600 / 5);
    assert(commons_reward == 6_000.coins);
    Amount total_rewards = (allocated_validator_rewards + commons_reward) * testPayoutPeriod;

    auto tx_set_fees = Amount(0);
    auto total_fees = Amount(0);
    Amount[] next_payout_total;
    // Create blocks from height 1 to 11 (only block 5 and 10 should have a coinbase tx)
    foreach (height; 1..11)
    {
        auto txs = blocks[$-1].spendable.map!(txb => txb.sign()).array();
        txs.each!(tx => assert(ledger.acceptTransaction(tx) is null));
        tx_set_fees = txs.map!(tx => tx.getFee(&ledger.utxo_set.peekUTXO, &ledger.getPenaltyDeposit)).reduce!((a,b) => a + b);

        // Add the fees for this height
        total_fees += tx_set_fees;

        auto data = ConsensusData.init;
        ledger.prepareNominatingSet(data, Block.TxsInTestBlock);

        // Do some Coinbase tests with the data tx_set
        if (height >= 2 * testPayoutPeriod && height % testPayoutPeriod == 0)
        {
            // Remove the coinbase TX
            data.tx_set = data.tx_set[0 .. $ - 1];
            assert(ledger.validateConsensusData(data, skip_indexes) == "Missing Coinbase transaction");
            // Add different hash to tx_set
            data.tx_set ~= "Not Coinbase tx".hashFull();
            assert(ledger.validateConsensusData(data, skip_indexes) == "Missing matching Coinbase transaction");
        }

        // Now externalize the block
        ledger.prepareNominatingSet(data, Block.TxsInTestBlock);

        total_fees += ledger.params.SlashPenaltyAmount * data.missing_validators.length;
        if (height % testPayoutPeriod == 0)
        {
            next_payout_total ~= total_fees + total_rewards;
            total_fees = Amount(0);
        }

        assert(ledger.externalize(data) is null);
        assert(ledger.getBlockHeight() == blocks.length);
        blocks ~= ledger.getBlocksFrom(Height(blocks.length))[0];

        auto cb_txs = blocks[$-1].txs.filter!(tx => tx.isCoinbase).array;
        if (height >= 2 * testPayoutPeriod && height % testPayoutPeriod == 0)
        {
            assert(cb_txs.length == 1);
            // Payout block should pay the CommonsBudget + all validators (excluding slashed validators)
            assert(cb_txs[0].outputs.length == 1 + genesis_validator_keys.length - skip_indexes.length);
            assert(cb_txs[0].outputs.map!(o => o.value).reduce!((a,b) => a + b) == next_payout_total[0]);
            next_payout_total = next_payout_total[1 .. $];
            // Slashed validators should never be paid
            mpv_stakes.each!((mpv_stake)
            {
                assert(cb_txs[0].outputs.filter!(output => output.address ==
                    mpv_stake.output.address).array.length == 0);
            });
        }
        else
            assert(cb_txs.length == 0);
    }
}

unittest
{
    import agora.consensus.data.genesis.Test;
    import agora.consensus.PreImage;

    auto params = new immutable(ConsensusParams)(20);
    const(Block)[] blocks = [ GenesisBlock ];
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks, params);

    ushort min_fee_pct = 80;

    auto average_tx = genesisSpendable().front().refund(WK.Keys[0].address).deduct(10.coins).sign();
    assert(ledger.acceptTransaction(average_tx, 0, min_fee_pct) is null);

    // switch to a different input, with low fees this should be rejected because of average of fees in the pool
    auto different_tx = genesisSpendable().dropOne().front().refund(WK.Keys[0].address).deduct(1.coins).sign();
    assert(ledger.acceptTransaction(different_tx, 0, min_fee_pct) !is null);

    // lower than average, but enough
    auto enough_fee_tx = genesisSpendable().dropOne().front().refund(WK.Keys[0].address).deduct(9.coins).sign();
    assert(ledger.acceptTransaction(enough_fee_tx, 0, min_fee_pct) is null);

    // overwrite the old TX
    auto high_fee_tx = genesisSpendable().dropOne().front().refund(WK.Keys[0].address).deduct(11.coins).sign();
    assert(ledger.acceptTransaction(high_fee_tx, 0, min_fee_pct) is null);
}

unittest
{
    import std.stdio;
    import agora.consensus.data.genesis.Test;
    import agora.consensus.PreImage;

    auto params = new immutable(ConsensusParams)(20);
    const(Block)[] blocks = [ GenesisBlock ];
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks, params);

    auto missing_validator = 0;

    ledger.simulatePreimages(Height(params.ValidatorCycle), [missing_validator]);
    assert(ledger.getPenaltyDeposit(GenesisBlock.header.enrollments[missing_validator].utxo_key) != 0.coins);

    ConsensusData data;
    ledger.prepareNominatingSet(data, Block.TxsInTestBlock);
    assert(data.missing_validators.canFind(missing_validator));
    assert(ledger.externalize(data) is null);
    // slashed stake should not have penalty deposit
    assert(ledger.getPenaltyDeposit(GenesisBlock.header.enrollments[missing_validator].utxo_key) == 0.coins);
}

unittest
{
    import agora.consensus.data.genesis.Test;

    auto params = new immutable(ConsensusParams)();
    const(Block)[] blocks = [ GenesisBlock ];
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks, params);
    ledger.simulatePreimages(Height(params.ValidatorCycle));

    auto freeze_tx = GenesisBlock.txs.find!(tx => tx.isFreeze).front();
    auto melting_tx = TxBuilder(freeze_tx, 0).sign();

    // enrolled stake can't be spent
    assert(ledger.acceptTransaction(melting_tx) !is null);
}

unittest
{
    import agora.consensus.data.genesis.Test;

    auto params = new immutable(ConsensusParams)();
    const(Block)[] blocks = [ GenesisBlock ];
    scope ledger = new TestLedger(genesis_validator_keys[0], blocks, params);
    ledger.simulatePreimages(Height(params.ValidatorCycle));

    KeyPair kp = WK.Keys.GG;
    auto freeze_tx = genesisSpendable().front().refund(kp.address).sign(OutputType.Freeze);
    assert(ledger.acceptTransaction(freeze_tx) is null);
    ledger.forceCreateBlock(1);

    auto melting_tx = TxBuilder(freeze_tx, 0).sign();
    assert(ledger.acceptTransaction(melting_tx) is null);

    ConsensusData data;
    ledger.prepareNominatingSet(data, Block.TxsInTestBlock);
    assert(data.tx_set.canFind(melting_tx.hashFull()));
    assert(ledger.validateConsensusData(data, []) is null);

    // can't enroll and spend the stake at the same height
    data.enrolls ~= EnrollmentManager.makeEnrollment(UTXO.getHash(freeze_tx.hashFull, 0), kp, Height(1));

    import std.stdio;
    assert(ledger.validateConsensusData(data, []) !is null);
}
