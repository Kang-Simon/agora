/*******************************************************************************

    Contains supporting code for managing validators' information
    using SQLite as a backing store, including the enrolled height
    which means enrollment process is confirmed as part of consensus.

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.consensus.state.ValidatorSet;

import agora.common.Amount;
import agora.common.ManagedDatabase;
import agora.common.Types;
import agora.consensus.data.Block;
import agora.consensus.data.Enrollment;
import agora.consensus.data.Params;
import agora.consensus.data.PreImageInfo;
public import agora.consensus.data.ValidatorInfo;
import agora.consensus.PreImage;
import agora.consensus.state.UTXOCache;
import agora.crypto.ECC;
import agora.crypto.Hash;
import agora.crypto.Key;
import agora.crypto.Schnorr;
import agora.serialization.Serializer;
import agora.utils.Log;
version (unittest) import agora.consensus.PreImage;
version (unittest) import agora.utils.Test;

import d2sqlite3.library;
import d2sqlite3.results;
import d2sqlite3.sqlite3;

import std.typecons : Tuple;

/// The information that can be queried for an enrollment
public struct EnrollmentState
{
    /// The Height the enrollment was accepted at
    Height enrolled_height;

    /// The most recently revealed PreImage
    PreImageInfo preimage;

    /// The Height the validator was slashed at
    Height slashed_height;
}

/// Delegate type to query the history of Enrollments
public alias EnrollmentFinder = bool delegate (in Hash enroll_key, out EnrollmentState state) @trusted nothrow;

/// A Height and PublicKey pair to represent expiring Validators
public alias ExpiringValidator = Tuple!(Height, "enrolled_height",
    Hash, "utxo", PublicKey, "pubkey");

/// Ditto
public class ValidatorSet
{
    /// Logger instance
    protected Logger log;

    /// SQLite db instance
    private ManagedDatabase db;

    /// Parameters for consensus-critical constants
    private immutable(ConsensusParams) params;

    /***************************************************************************

        Constructor

        Params:
            db = the managed database instance
            params = the consensus-critical constants

    ***************************************************************************/

    public this (ManagedDatabase db, immutable(ConsensusParams) params)
    {
        this.db = db;
        this.params = params;
        this.log = Logger(__MODULE__);

        // create the table for validator set if it doesn't exist yet
        this.db.execute("CREATE TABLE IF NOT EXISTS validator " ~
            "(key TEXT, public_key TEXT, " ~
            "enrolled_height INTEGER, " ~
            "nonce TEXT, slashed_height INTEGER, stake INTEGER,
            PRIMARY KEY (key, enrolled_height), " ~
            "CHECK (enrolled_height >= 0 AND slashed_height >= 0 AND stake >=0))");

        // create the table for preimages if it doesn't exist yet
        this.db.execute("CREATE TABLE IF NOT EXISTS preimages " ~
            "(key TEXT, height INTEGER, preimage TEXT,
            PRIMARY KEY (key), CHECK (height >= 0))");
    }

    /***************************************************************************

        Add a enrollment data to the validators set

        Params:
            height = the current block height in the ledger
            finder = the delegate to find UTXOs with
            enroll = the enrollment data to add
            pubkey = the public key of the enrollment

        Returns:
            A string describing the error, or `null` on success

    ***************************************************************************/

    public string add (in Height height, scope UTXOFinder finder,
        scope GetPenaltyDeposit getPenaltyDeposit,
        in Enrollment enroll, in PublicKey pubkey) @safe nothrow
    {
        import agora.consensus.validation.Enrollment : isInvalidReason;

        Amount stake;
        // check validaty of the enrollment data and fetch stake `Amount`
        if (auto reason = isInvalidReason(enroll, finder, height,
            &this.findRecentEnrollment, getPenaltyDeposit, stake))
            return reason;

        // check if already exists
        if (this.hasEnrollment(height + 1, enroll.utxo_key))
            return "This validator is already enrolled";

        // check if an enrollment of the same public key is already present
        if (this.hasPublicKey(height + 1, pubkey))
            return "A validator with the same public key is already enrolled";

        try
        {
            () @trusted {
                this.db.execute("INSERT OR REPLACE INTO preimages " ~
                    "(key, height, preimage) " ~
                    "VALUES (?, ?, ?)",
                    enroll.utxo_key, height.value,
                    enroll.commitment);
                this.db.execute("INSERT INTO validator " ~
                    "(key, public_key, enrolled_height, nonce, stake) " ~
                    "VALUES (?, ?, ?, ?, ?)",
                    enroll.utxo_key,
                    pubkey,
                    height.value,
                    enroll.enroll_sig.R,
                    stake);
            }();
        }
        catch (Exception ex)
        {
            // This should never happen, hence why we log it as well
            log.error("Unexpected error while adding a validator: {} ({})",
                      ex, enroll);
            return "Internal error in `ValidatorSet.add`";
        }

        return null;
    }

    /***************************************************************************

        Remove all validators from the validator set

    ***************************************************************************/

    public void removeAll () @trusted nothrow
    {
        try
        {
            this.db.execute("DELETE FROM validator");
            this.db.execute("DELETE FROM preimages");
        }
        catch (Exception ex)
        {
            log.error("Error while calling ValidatorSet.removeAll(): {}", ex);
        }
    }

    /***************************************************************************

        Slash the validator with the given UTXO key at the given height

        Params:
            utxo_key = the UTXO key of the validator
            height = height at which it is slashed (not active from this height)

    ***************************************************************************/

    public void slashValidator (in Hash enroll_hash, in Height height) @trusted nothrow
    {
        try
        {
            () @trusted {
                this.db.execute("UPDATE validator SET slashed_height = ? WHERE key = ?", height, enroll_hash);
            }();
        }
        catch (Exception ex)
        {
            log.error("ManagedDatabase operation error: {}", ex.msg);
        }
    }

    /***************************************************************************

        In validatorSet DB, return the enrolled block height.

        Params:
            enroll_hash = key for an enrollment block height
            height = height to get enrollment

        Returns:
            the enrolled block height, or `ulong.max` if no matching key exists

    ***************************************************************************/

    public Height getEnrolledHeight (in Height height, in Hash enroll_hash) @trusted nothrow
    {
        try
        {
            auto results = this.db.execute("SELECT enrolled_height FROM validator " ~
                "WHERE key = ? AND enrolled_height >= ? AND enrolled_height <= ? " ~
                "ORDER BY enrolled_height DESC",
                enroll_hash, this.minEnrollmentHeight(height), height);
            if (results.empty)
                return Height(ulong.max);

            return Height(results.oneValue!(size_t));
        }
        catch (Exception ex)
        {

            log.error("ManagedDatabase operation error: {}", ex.msg);
            return Height(ulong.max);
        }
    }

    /***************************************************************************

        Check if a enrollment data exists in the validator set.

        Params:
            height = block height
            enroll_hash = key for enrollment data which is hash of frozen UTXO

        Returns:
            true if the validator set has the enrollment data

    ***************************************************************************/

    public bool hasEnrollment (in Height height, in Hash enroll_hash) @trusted nothrow
    {
        try
        {
            auto results = this.db.execute("SELECT EXISTS(SELECT 1 FROM " ~
                "validator WHERE key = ? " ~
                "AND enrolled_height >= ? AND enrolled_height <= ?)", enroll_hash,
               this.minEnrollmentHeight(height), height);
            return results.front().peek!bool(0);
        }
        catch (Exception ex)
        {
            log.fatal("Exception occured on hasEnrollment: {}, " ~
                "Key for enrollment: {}", ex.msg, enroll_hash);
            assert(0);
        }
    }

    /***************************************************************************

        Check with public key if an enrollment data exists in the validator set

        Params:
            height = block height for enrollment which includes the actual block
                with the enrollment as we are checking if public key is already used
            pubkey = the key by which the validator set searches enrollment

        Returns:
            true if the validator set has an enrollment for the public key

    ***************************************************************************/

    public bool hasPublicKey (in Height height, in PublicKey pubkey) @trusted nothrow
    {
        try
        {
            auto results = this.db.execute("SELECT EXISTS(SELECT 1 FROM " ~
                "validator WHERE public_key = ? " ~
                "AND enrolled_height >= ? AND enrolled_height <= ?)", pubkey,
               this.minEnrollmentHeight(height), height);
            return results.front().peek!bool(0);
        }
        catch (Exception ex)
        {
            log.fatal("Exception occured on hasEnrollment: {}, " ~
                "PublicKey for enrollment: {}", ex.msg, pubkey);
            assert(0);
        }
    }

    /***************************************************************************

        Get all the validators able to sign block at `height`

        The validators are returned sorted by UTXO (the normal sorting order).
        The list does not include validators for which the enrollment was
        accepted at height `height`, unless they were already enrolled before
        (as those will only be able to sign `height + 1`).

        Params:
            height = the block height for which we want the active validators

        Returns:
            A structure containing all infos about current validators

        Throws:
            If there is an internal error.

    ***************************************************************************/

    public ValidatorInfo[] getValidators (in Height height) @trusted
    {
        auto results = this.db.execute(
            "SELECT enrolled_height, public_key, stake, validator.key,
            preimages.preimage, preimages.height " ~
            "FROM validator " ~
            "INNER JOIN preimages on preimages.key = validator.key " ~
            "WHERE enrolled_height >= ? AND enrolled_height < ? " ~
            "AND (slashed_height is null OR slashed_height >= ?) " ~
            "ORDER BY validator.key ASC",
            this.minEnrollmentHeight(height), height, height);

        ValidatorInfo[] ret;
        foreach (row; results)
            ret ~= ValidatorInfo(
                /* enrolled: */ Height(row.peek!(ulong)(0)),
                /* address:  */ PublicKey.fromString(row.peek!(char[], PeekMode.slice)(1)),
                /* stake:    */ Amount(row.peek!(ulong)(2)),
                /* preimage: */ PreImageInfo(
                /*     utxo:   */ Hash(row.peek!(const(char)[], PeekMode.slice)(3)),
                /*     hash:   */ Hash(row.peek!(const(char)[], PeekMode.slice)(4)),
                /*     height: */ Height(row.peek!(ulong)(5)),
                    ),
                );

        return ret;
    }

    /***************************************************************************

        Get all the current validators in ascending order with the utxokey
        including the slashed as the validator index requires them

        Params:
            height = the block height
            validators = will be filled with all the validators during
                their validation cycles
        Returns:
            Return true if there was no error in getting the UTXO keys

    ***************************************************************************/

    public bool getEnrolledUTXOs (in Height height, out Hash[] utxo_keys) @trusted nothrow
    {
        try
        {
            auto results = this.db.execute("SELECT key FROM validator " ~
                "WHERE enrolled_height >= ? AND enrolled_height < ? " ~
                "AND (slashed_height is null OR slashed_height > ?) " ~
                "ORDER BY key ASC", this.minEnrollmentHeight(height), height, height);
            foreach (row; results)
                utxo_keys ~= Hash(row.peek!(char[])(0));
            return true;
        }
        catch (Exception ex)
        {
            log.error("ManagedDatabase operation error: {}", ex.msg);
            return false;
        }
    }

    /***************************************************************************

        Gets the number of active validators at a given block height.

        This function finds validators that should be active at a given height,
        provided they do not get slashed. Active validators are those
        that can sign a block.

        This can be used to look up arbitrary height in the future, as long as
        the height is not over `ValidatorCycle` distance from the known state
        of the ValidatorSet (in such case, 0 will always be returned).

        Params:
            height = height at which to count the validators

        Returns:
            Returns the number of active validators when the block height is
            `block_height`, or 0 in case of error.

    ***************************************************************************/

    public ulong countActive (in Height height) @safe nothrow
    {
        try
        {
            // E.g. for initial validators, enrolled at height 0,
            // they will validate blocks [1 .. 20] if the cycle is 20.
            return () @trusted {
                return this.db.execute("SELECT count(*) FROM validator " ~
                    "WHERE enrolled_height >= ? AND enrolled_height < ? " ~
                    "AND (slashed_height is null OR slashed_height > ?) ",
                   this.minEnrollmentHeight(height), height, height).oneValue!ulong;
            }();
        }
        catch (Exception ex)
        {
            log.error("Database operation error {}", ex);
        }

        return 0;
    }

    /***************************************************************************

        Get validator's pre-image from the validator set

        Params:
            enroll_key = The key for the enrollment in which the pre-image is
                contained.

        Returns:
            the PreImageInfo of the enrolled key if it exists,
            otherwise PreImageInfo.init

    ***************************************************************************/

    public PreImageInfo getPreimage (in Hash enroll_key) @trusted nothrow
    {
        try
        {
            auto results = this.db.execute("SELECT preimage, height FROM " ~
                "preimages WHERE key = ?", enroll_key);

            if (!results.empty && results.oneValue!(byte[]).length != 0)
            {
                auto row = results.front;
                Hash preimage = Hash(row.peek!(char[])(0));
                auto height = Height(row.peek!ulong(1));
                return PreImageInfo(enroll_key, preimage, height);
            }
        }
        catch (Exception ex)
        {
            log.error("Exception occured on getPreimage: {}, " ~
                "Key for enrollment: {}", ex.msg, enroll_key);
        }

        return PreImageInfo.init;
    }

    /***************************************************************************

        Get validators' pre-image information

        Params:
            start_height = the starting enrolled height to begin retrieval from

        Returns:
            preimages' information of the validators

    ***************************************************************************/

    public PreImageInfo[] getPreimages (in Height start_height) @trusted nothrow
    {
        PreImageInfo[] preimages;

        try
        {
            auto results = this.db.execute("SELECT key, preimage, height " ~
                "FROM preimages WHERE height >= ?", start_height);

            foreach (row; results)
            {
                Hash enroll_key = Hash(row.peek!(char[])(0));
                Hash preimage = Hash(row.peek!(char[])(1));
                auto preimage_height = Height(row.peek!ulong(2));
                preimages ~= PreImageInfo(enroll_key, preimage, preimage_height);
            }
        }
        catch (Exception ex)
        {
            log.error("Exception occured on getPreimages: {}, height {}",
                ex.msg, start_height);
        }

        return preimages;
    }

    /***************************************************************************

        Add a pre-image information to a validator data

        Params:
            preimage = the pre-image information to add

        Returns:
            true if the pre-image information has been added to the validator

    ***************************************************************************/

    public bool addPreimage (in PreImageInfo preimage) @trusted nothrow
    {
        import agora.consensus.validation.PreImage : isInvalidReason;

        const prev_preimage = this.getPreimage(preimage.utxo);

        if (prev_preimage == PreImageInfo.init)
        {
            log.info("Rejected pre-image for never-enrolled UTXO key: {}",
                preimage.hash);
            return false;
        }

        // Ignore older height pre-image because validators will gossip them
        if (prev_preimage.height >= preimage.height)
            return false;

        // Ignore preimages beyond the current cycle
        if (preimage.height - prev_preimage.height > this.params.ValidatorCycle)
            return false;

        if (auto reason = isInvalidReason(preimage, prev_preimage))
        {
            log.info("Invalid pre-image data: {}. Pre-image: {}, previous: {}",
                reason, preimage, prev_preimage);
            return false;
        }

        // update the preimage info
        try
        {
            () @trusted {
                this.db.execute("UPDATE preimages SET preimage = ?, " ~
                    "height = ? WHERE key = ?",
                    preimage.hash, preimage.height, preimage.utxo);
            }();
        }
        catch (Exception ex)
        {
            log.error("ManagedDatabase operation error on addPreimage: {}, Preimage: {}",
                ex.msg, preimage);
            return false;
        }

        return true;
    }

    /***************************************************************************

        Find the most recent Enrollment with the provided UTXO hash, regardless
        of it's active status but order by status descending so that most recent
        is returned first

        Params:
            enroll_key = The key for the enrollment
            state = struct to fill once an enrollment is found

        Returns:
            true if an enrollment with the key was ever accepted, false otherwise

    ***************************************************************************/

    bool findRecentEnrollment (in Hash enroll_key, out EnrollmentState state) @trusted nothrow
    {
        try
        {
            auto results = this.db.execute("SELECT enrolled_height, slashed_height " ~
                "FROM validator WHERE key = ? ORDER BY enrolled_height DESC", enroll_key);

            if (!results.empty && results.oneValue!(byte[]).length != 0)
            {
                auto row = results.front;
                state.enrolled_height = Height(row.peek!(size_t)(0));
                state.slashed_height = Height(row.peek!(size_t)(1));
                state.preimage = this.getPreimage(enroll_key);
                return true;
            }
        }
        catch (Exception ex)
        {
            log.error("Exception occured on findRecentEnrollment: {}, " ~
                "Key for enrollment: {}", ex.msg, enroll_key);
        }

        return false;
    }

    /***************************************************************************

        Returns:
            The lowest height an `Enrollment` had to appear at for it to be
            a validator at `height`

    ***************************************************************************/

    public Height minEnrollmentHeight (in Height height) const scope @safe
        pure nothrow @nogc
    {
        return Height(height <= this.params.ValidatorCycle ? 0
            : height - this.params.ValidatorCycle);
    }
}

/// test for functions of ValidatorSet
unittest
{
    import agora.consensus.data.Transaction;
    import agora.consensus.EnrollmentManager;
    import std.algorithm;
    import std.conv;
    import std.range;

    const FirstEnrollHeight = Height(1);
    scope storage = new TestUTXOSet;
    auto getPenaltyDeposit = (Hash utxo)
    {
        UTXO val;
        return storage.peekUTXO(utxo, val) ? 10_000.coins : 0.coins;
    };
    scope set = new ValidatorSet(new ManagedDatabase(":memory:"),
        new immutable(ConsensusParams)());

    Hash[] utxos;
    genesisSpendable().take(8).enumerate
        .map!(en => en.value.refund(WK.Keys[en.index].address).sign(OutputType.Freeze))
        .each!((tx) {
            storage.put(tx);
            utxos ~= UTXO.getHash(tx.hashFull(), 0);
        });

    // add enrollments
    Hash cycle_seed;
    Height cycle_seed_height;
    getCycleSeed(WK.Keys[0], set.params.ValidatorCycle, cycle_seed, cycle_seed_height);
    auto enroll = EnrollmentManager.makeEnrollment(utxos[0], WK.Keys[0], FirstEnrollHeight,
        cycle_seed, cycle_seed_height);
    assert(set.add(FirstEnrollHeight, &storage.peekUTXO, getPenaltyDeposit, enroll, WK.Keys[0].address) is null);
    assert(set.countActive(FirstEnrollHeight) == 0);
    assert(set.countActive(FirstEnrollHeight + 1) == 1);    // Will be active next block
    ExpiringValidator[] ex_validators;
    assert(set.hasEnrollment(FirstEnrollHeight, utxos[0]));
    assert(set.add(FirstEnrollHeight, &storage.peekUTXO, getPenaltyDeposit, enroll, WK.Keys[0].address) == "Already enrolled at this height");

    getCycleSeed(WK.Keys[1], set.params.ValidatorCycle, cycle_seed, cycle_seed_height);
    auto enroll2 = EnrollmentManager.makeEnrollment(utxos[1], WK.Keys[1], FirstEnrollHeight,
        cycle_seed, cycle_seed_height);
    assert(set.add(FirstEnrollHeight, &storage.peekUTXO, getPenaltyDeposit, enroll2, WK.Keys[1].address) is null);
    assert(set.countActive(FirstEnrollHeight + 1) == 2);

    const SecondEnrollHeight = Height(9);
    getCycleSeed(WK.Keys[2], set.params.ValidatorCycle, cycle_seed, cycle_seed_height);
    auto enroll3 = EnrollmentManager.makeEnrollment(utxos[2], WK.Keys[2], SecondEnrollHeight,
        cycle_seed, cycle_seed_height);
    assert(set.add(SecondEnrollHeight, &storage.peekUTXO, getPenaltyDeposit, enroll3, WK.Keys[2].address) is null);
    assert(set.countActive(SecondEnrollHeight + 1) == 3);

    // check if enrolled heights are not set
    Hash[] keys;
    set.getEnrolledUTXOs(SecondEnrollHeight + 1, keys);
    assert(keys.length == 3);
    assert(keys.isStrictlyMonotonic!("a < b"));

    // slash ValidatorSet
    set.slashValidator(utxos[1], SecondEnrollHeight + 1);
    assert(set.countActive(SecondEnrollHeight + 1) == 2);
    assert(set.hasEnrollment(SecondEnrollHeight + 1,utxos[0]));
    set.slashValidator(utxos[0], SecondEnrollHeight + 1);
    // The enrollment will remain even though it is slashed
    assert(set.hasEnrollment(SecondEnrollHeight + 1, utxos[0]));
    set.removeAll();
    assert(set.countActive(SecondEnrollHeight + 1) == 0);

    Enrollment[] ordered_enrollments;
    ordered_enrollments ~= enroll;
    ordered_enrollments ~= enroll2;
    ordered_enrollments ~= enroll3;
    /// PreImageCache for the first enrollment
    auto cache = PreImageCycle(WK.Keys[0].secret, set.params.ValidatorCycle);

    // Reverse ordering
    ordered_enrollments.sort!("a.utxo_key > b.utxo_key");
    foreach (i, ordered_enroll; ordered_enrollments)
        assert(set.add(FirstEnrollHeight, storage.getUTXOFinder(),
            getPenaltyDeposit, ordered_enroll, WK.Keys[i].address) is null);
    set.getEnrolledUTXOs(FirstEnrollHeight + 1, keys);
    assert(keys.length == 3);
    assert(keys.isStrictlyMonotonic!("a < b"));

    // test for adding and getting preimage
    assert(set.getPreimage(utxos[0]) == PreImageInfo(enroll.utxo_key, enroll.commitment, FirstEnrollHeight));
    assert(cache[FirstEnrollHeight] == enroll.commitment);
    auto preimage_11 = PreImageInfo(utxos[0], cache[SecondEnrollHeight + 2], SecondEnrollHeight + 2);
    assert(set.addPreimage(preimage_11));
    assert(set.getPreimage(utxos[0]) == preimage_11);

    auto far_height = Height(10000);
    auto too_far_preimage = PreImageInfo(utxos[0], cache[far_height], far_height);
    assert(!set.addPreimage(too_far_preimage));
    assert(set.getPreimage(utxos[0]) == preimage_11);

    // test for clear up expired validators
    getCycleSeed(WK.Keys[3], set.params.ValidatorCycle, cycle_seed, cycle_seed_height);
    enroll = EnrollmentManager.makeEnrollment(utxos[3], WK.Keys[3], SecondEnrollHeight,
        cycle_seed, cycle_seed_height);
    assert(set.add(SecondEnrollHeight, &storage.peekUTXO, getPenaltyDeposit, enroll, WK.Keys[3].address) is null);
    keys.length = 0;
    assert(set.getEnrolledUTXOs(Height(set.params.ValidatorCycle + 8), keys));
    assert(keys.length == 1);
    assert(keys[0] == utxos[3]);

    // add enrollment at the genesis block:
    // validates blocks [1 .. ValidatorCycle] inclusively
    assert(set.params.ValidatorCycle > 10);
    set.removeAll();  // clear all

    assert(set.countActive(SecondEnrollHeight + 1) == 0);
    getCycleSeed(WK.Keys[0], set.params.ValidatorCycle, cycle_seed, cycle_seed_height);
    enroll = EnrollmentManager.makeEnrollment(utxos[0], WK.Keys[0], FirstEnrollHeight,
        cycle_seed, cycle_seed_height);
    assert(set.add(FirstEnrollHeight, &storage.peekUTXO, getPenaltyDeposit, enroll, WK.Keys[0].address) is null);

    // still active at height 1008
    keys.length = 0;

    assert(set.countActive(Height(set.params.ValidatorCycle)) == 1);
    assert(set.getEnrolledUTXOs(Height(set.params.ValidatorCycle), keys));
    assert(keys.length == 1);
    assert(keys[0] == utxos[0]);

    // cleared after a new cycle was started (which started at height 1 so add 2)
    assert(set.countActive(Height(set.params.ValidatorCycle + 2)) == 0);
    assert(set.getEnrolledUTXOs(Height(1010), keys));
    assert(keys.length == 0);
    set.removeAll();  // clear all
}
