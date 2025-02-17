/*******************************************************************************

    Contains the script execution engine.

    Note that Bitcoin-style P2SH scripts are not detected,
    instead one should use LockType.Redeem in the Lock script tag.

    Things not currently implemented:
        - opcode weight calculation
        - opcode total cost limit

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.script.Engine;

import agora.common.Types;
import agora.consensus.data.Transaction;
import agora.crypto.Hash;
import agora.crypto.Schnorr;
import agora.crypto.Key;
import agora.script.Lock;
import agora.script.Opcodes;
import agora.script.ScopeCondition;
import agora.script.Script;
import agora.script.Signature;
import agora.script.Stack;

import std.bitmanip;
import std.conv;
import std.range;
import std.traits;
import std.algorithm;

version (unittest)
{
    import agora.crypto.Schnorr;
    import agora.utils.Test;
    import std.stdio : writefln, writeln;  // avoid importing LockType
}

/// Ditto
public class Engine
{
    /// Opcodes cannot be pushed on the stack. We use a byte array as a marker.
    /// Conditional opcodes require the top item on the stack to be one of these
    private static immutable ubyte[1] TrueValue = [OP.TRUE];
    /// Ditto
    private static immutable ubyte[1] FalseValue = [OP.FALSE];

    /// Maximum total stack size
    private immutable ulong StackMaxTotalSize;

    /// Maximum size of an item on the stack
    public immutable ulong StackMaxItemSize;

    /***************************************************************************

        Initializes the script execution engine with the configured consensus
        limits.

        Params:
            StackMaxTotalSize = the maximum allowed stack size before a
                stack overflow, which would cause the script execution to fail.
                the script execution fails.
            StackMaxItemSize = maximum allowed size for a single item on
                the stack. If exceeded, script execution will fail during the
                syntactical validation of the script.

    ***************************************************************************/

    public this (ulong StackMaxTotalSize, ulong StackMaxItemSize)
    {
        assert(StackMaxItemSize > 0 && StackMaxTotalSize >= StackMaxItemSize);
        this.StackMaxTotalSize = StackMaxTotalSize;
        this.StackMaxItemSize = StackMaxItemSize;
    }

    /***************************************************************************

        Main dispatch execution routine.

        The lock type will be examined, and based on its type execution will
        proceed to either simple script-less payments, or script-based payments.

        Params:
            lock = the lock
            unlock = may contain a `signature`, `signature, key`,
                     or `script` which only contains stack push opcodes
            tx = the spending transaction
            input = the input which contained the unlock

        Returns:
            null if there were no errors,
            or a string explaining the reason execution failed

    ***************************************************************************/

    public string execute (in Lock lock, in Unlock unlock, in Transaction tx,
        in Input input) nothrow @safe
    {
        if (auto reason = validateLockSyntax(lock, this.StackMaxItemSize))
            return reason;

        final switch (lock.type)
        {
        case LockType.Key:
        case LockType.KeyHash:
            if (auto error = this.handleBasicPayment(lock, unlock, tx, input))
                return error;
            break;

        case LockType.Script:
            if (auto error = this.executeBasicScripts(lock, unlock, tx, input))
                return error;
            break;

        case LockType.Redeem:
            if (auto error = this.executeRedeemScripts(lock, unlock, tx, input))
                return error;
            break;
        }

        return null;
    }

    /***************************************************************************

        Handle stack-less and script-less basic payments.

        If the lock is a `Lock.Key` type, the unlock must only
        contain a `signature`.
        If the lock is a `Lock.KeyHash` type, the unlock must contain a
        `signature, key` tuple.

        Params:
            lock = must contain a `pubkey` or a `hash`
            unlock = must contain a `signature` or `signature, key` tuple
            tx = the spending transaction
            input = the input which contained the unlock

        Returns:
            null if there were no errors,
            or a string explaining the reason execution failed

    ***************************************************************************/

    private string handleBasicPayment (in Lock lock, in Unlock unlock,
        in Transaction tx, in Input input) nothrow @safe
    {
        // assumed sizes
        static assert(PublicKey.sizeof == 32);
        static assert(Hash.sizeof == 64);

        switch (lock.type)
        {
        case LockType.Key:
            const PublicKey key = PublicKey(lock.bytes);

            SigPair sig_pair;
            ulong pop_count;
            if (auto reason = decodeSignature(unlock.bytes, sig_pair, pop_count))
                return "LockType.Key " ~ reason;

            if (!this.isValidSignature(key, sig_pair, tx, input))
                return "LockType.Key signature in unlock script failed validation";

            break;

        case LockType.KeyHash:
            const Hash key_hash = Hash(lock.bytes);
            const(ubyte)[] bytes = unlock.bytes;

            SigPair sig_pair;
            ulong pop_count;
            if (auto reason = decodeSignature(
                bytes, sig_pair, pop_count))
                return "LockType.KeyHash " ~ reason;
            bytes.popFrontN(pop_count);

            if (bytes.length != PublicKey.sizeof)
                return "LockType.KeyHash requires a 32-byte key in the unlock script";

            const PublicKey key = PublicKey(bytes);
            if (!key.isValid())
                return "LockType.KeyHash public key in unlock script is invalid";

            if (hashFull(key) != key_hash)
                return "LockType.KeyHash hash of key does not match key hash set in lock script";

            if (!this.isValidSignature(key, sig_pair, tx, input))
                return "LockType.KeyHash signature in unlock script failed validation";

            break;

        default:
            assert(0);
        }

        return null;
    }

    /***************************************************************************

        Execute a `LockType.Script` type of lock script with the associated
        unlock script.

        The unlock script may only contain stack pushes.
        The unlock script is ran, producing a stack.
        Thereafter, the lock script will run with the stack of the
        unlock script.

        For security reasons, the two scripts are not concatenated together
        before execution. You may read more about it here:
        https://bitcoin.stackexchange.com/q/80258/93682

        Params:
            lock = the lock script
            unlock = the unlock script
            tx = the spending transaction
            input = the input which contained the unlock

        Returns:
            null if there were no errors,
            or a string explaining the reason execution failed

    ***************************************************************************/

    private string executeBasicScripts (in Lock lock,
        in Unlock unlock, in Transaction tx, in Input input) nothrow @safe
    {
        assert(lock.type == LockType.Script);

        Script unlock_script;
        if (auto error = validateScriptSyntax(ScriptType.Unlock, unlock.bytes,
            this.StackMaxItemSize, unlock_script))
            return error;

        Script lock_script = Script.assumeValidated(lock.bytes);
        Stack stack = Stack(this.StackMaxTotalSize, this.StackMaxItemSize);
        if (auto error = this.executeScript(unlock_script, stack, tx, input))
            return error;

        if (auto error = this.executeScript(lock_script, stack, tx, input))
            return error;

        if (this.hasScriptFailed(stack))
            return "Script failed";

        return null;
    }

    /***************************************************************************

        Execute a `LockType.Redeem` type of lock script with the associated
        lock script.

        The 64-byte hash of the redeem script is read from `lock_bytes`,
        `unlock_bytes` is evaluated as a set of pushes to the stack where
        the last push is the redeem script. The redeem script is popped from the
        stack, hashed, and compared to the previously extracted hash from the
        lock script. If the hashes match, the redeem script is evaluated with
        any leftover stack items of the unlock script.

        Params:
            lock = must contain a 64-byte hash of the redeem script
            unlock = must contain only stack push opcodes, where the last
                     push is the redeem script itself
            tx = the associated spending transaction
            input = the input which contained the unlock

        Returns:
            null if there were no errors,
            or a string explaining the reason execution failed

    ***************************************************************************/

    private string executeRedeemScripts (in Lock lock, in Unlock unlock,
        in Transaction tx, in Input input) nothrow @safe
    {
        assert(lock.type == LockType.Redeem);
        const Hash script_hash = Hash(lock.bytes);

        Script unlock_script;
        if (auto error = validateScriptSyntax(ScriptType.Unlock, unlock.bytes,
            this.StackMaxItemSize, unlock_script))
            return error;

        Stack stack = Stack(this.StackMaxTotalSize, this.StackMaxItemSize);
        if (auto error = this.executeScript(unlock_script, stack, tx, input))
            return error;

        if (stack.empty())
            return "LockType.Redeem requires unlock script to push a redeem script to the stack";

        const redeem_bytes = stack.pop();
        if (hashFull(redeem_bytes) != script_hash)
            return "LockType.Redeem unlock script pushed a redeem script "
                 ~ "which does not match the redeem hash in the lock script";

        Script redeem;
        if (auto error = validateScriptSyntax(ScriptType.Redeem, redeem_bytes,
            this.StackMaxItemSize, redeem))
            return error;

        if (auto error = this.executeScript(redeem, stack, tx, input))
            return error;

        if (this.hasScriptFailed(stack))
            return "Script failed";

        return null;
    }

    /***************************************************************************

        Execute the script with the given stack and the associated spending
        transaction. This routine may be called for all types of scripts,
        lock, unlock, and redeem scripts.

        An empty script will not fail execution. It's up to the calling code
        to differentiate when this is an allowed condition.

        Params:
            script = the script to execute
            stack = the stack to use for the script. May be non-empty.
            tx = the associated spending transaction
            input = the input which contained the unlock

        Returns:
            null if there were no errors,
            or a string explaining the reason execution failed

    ***************************************************************************/

    private string executeScript (in Script script, ref Stack stack,
        in Transaction tx, in Input input) nothrow @safe
    {
        // tracks executable condition of scopes for use with IF / ELSE / etc
        ScopeCondition sc;
        const(ubyte)[] bytes = script[];
        while (!bytes.empty())
        {
            OP opcode;
            if (!bytes.front.toOPCode(opcode))
                assert(0, "Script should have been syntactically validated");
            bytes.popFront();

            if (opcode.isConditional())
            {
                if (auto error = this.handleConditional(opcode, stack, sc))
                    return error;
                continue;
            }

            // must consume payload even if the scope is currently false
            const(ubyte)[] payload;
            switch (opcode)
            {
            case OP.PUSH_DATA_1:
                if (auto reason = this.readPayload!(OP.PUSH_DATA_1)(
                    bytes, payload))
                    return reason;
                break;

            case OP.PUSH_DATA_2:
                if (auto reason = this.readPayload!(OP.PUSH_DATA_2)(
                    bytes, payload))
                    return reason;
                break;

            case 1: .. case OP.PUSH_BYTES_75:
                const payload_size = opcode;  // encoded in the opcode
                if (bytes.length < payload_size)
                    assert(0);  // should have been validated

                payload = bytes[0 .. payload_size];
                bytes.popFrontN(payload.length);
                break;

            default:
                assert(!opcode.isPayload());  // missing cases
                break;
            }

            // whether the current scope is executable
            // (all preceeding outer conditionals were true)
            if (!sc.isTrue())
                continue;

            switch (opcode)
            {
            case OP.TRUE:
                if (!stack.canPush(TrueValue))
                    return "Stack overflow while pushing TRUE to the stack";
                stack.push(TrueValue);
                break;

            case OP.FALSE:
                if (!stack.canPush(FalseValue))
                    return "Stack overflow while pushing FALSE to the stack";
                stack.push(FalseValue);
                break;

            case OP.PUSH_DATA_1:
                if (!stack.canPush(payload))
                    return "Stack overflow while executing PUSH_DATA_1";
                stack.push(payload);
                break;

            case OP.PUSH_DATA_2:
                if (!stack.canPush(payload))
                    return "Stack overflow while executing PUSH_DATA_2";
                stack.push(payload);
                break;

            case 1: .. case OP.PUSH_BYTES_75:
                if (!stack.canPush(payload))
                    return "Stack overflow while executing PUSH_BYTES_*";

                stack.push(payload);
                break;

            case OP.PUSH_NUM_1: .. case OP.PUSH_NUM_5:
                static const ubyte[1] OneByte = [0];
                if (!stack.canPush(OneByte))
                    return "Stack overflow while executing PUSH_NUM_*";

                // note: must be GC-allocated!
                // todo: replace with preallocated values just like
                // `TrueValue` and `FalseValue`
                const ubyte[] number
                    = [cast(ubyte)((opcode + 1) - OP.PUSH_NUM_1)];
                stack.push(number);
                break;

            case OP.DUP:
                if (stack.empty)
                    return "DUP opcode requires an item on the stack";

                const top = stack.peek();
                if (!stack.canPush(top))
                    return "Stack overflow while executing DUP";
                stack.push(top);
                break;

            case OP.HASH:
                if (stack.empty)
                    return "HASH opcode requires an item on the stack";

                const ubyte[] top = stack.pop();
                const Hash hash = HashNoLength(top).hashFull();
                if (!stack.canPush(hash[]))  // e.g. hash(1 byte) => 64 bytes
                    return "Stack overflow while executing HASH";
                stack.push(hash[]);
                break;

            case OP.CHECK_EQUAL:
                if (stack.count() < 2)
                    return "CHECK_EQUAL opcode requires two items on the stack";

                const a = stack.pop();
                const b = stack.pop();
                stack.push(a == b ? TrueValue : FalseValue);  // canPush() check unnecessary
                break;

            case OP.VERIFY_EQUAL:
                if (stack.count() < 2)
                    return "VERIFY_EQUAL opcode requires two items on the stack";

                const a = stack.pop();
                const b = stack.pop();
                if (a != b)
                    return "VERIFY_EQUAL operation failed";
                break;

            case OP.CHECK_SIG:
                bool is_valid;
                if (auto error = this.verifySignature!(OP.CHECK_SIG)(
                    stack, tx, input, is_valid))
                    return error;

                // canPush() check unnecessary
                stack.push(is_valid ? TrueValue : FalseValue);
                break;

            case OP.VERIFY_SIG:
                bool is_valid;
                if (auto error = this.verifySignature!(OP.VERIFY_SIG)(
                    stack, tx, input, is_valid))
                    return error;

                if (!is_valid)
                    return "VERIFY_SIG signature failed validation";
                break;

            case OP.CHECK_MULTI_SIG:
                bool is_valid;
                if (auto error = this.verifyMultiSig!(OP.CHECK_MULTI_SIG)(
                    stack, tx, is_valid))
                    return error;

                // canPush() check unnecessary
                stack.push(is_valid ? TrueValue : FalseValue);
                break;

            case OP.VERIFY_MULTI_SIG:
                bool is_valid;
                if (auto error = this.verifyMultiSig!(OP.VERIFY_MULTI_SIG)(
                    stack, tx, is_valid))
                    return error;

                if (!is_valid)
                    return "VERIFY_MULTI_SIG signature failed validation";
                break;

            case OP.CHECK_SEQ_SIG:
                bool is_valid;
                if (auto error = this.verifySequenceSignature!(OP.CHECK_SEQ_SIG)(
                    stack, tx, input, is_valid))
                    return error;

                // canPush() check unnecessary
                stack.push(is_valid ? TrueValue : FalseValue);
                break;

            case OP.VERIFY_SEQ_SIG:
                bool is_valid;
                if (auto error = this.verifySequenceSignature!(OP.VERIFY_SEQ_SIG)(
                    stack, tx, input, is_valid))
                    return error;

                if (!is_valid)
                    return "VERIFY_SEQ_SIG signature failed validation";
                break;

            case OP.VERIFY_LOCK_HEIGHT:
                if (stack.empty())
                    return "VERIFY_LOCK_HEIGHT opcode requires a lock height on the stack";

                const height_bytes = stack.pop();
                if (height_bytes.length != ulong.sizeof)
                    return "VERIFY_LOCK_HEIGHT height lock must be an 8-byte number";

                const Height lock_height = Height(littleEndianToNative!ulong(
                    height_bytes[0 .. ulong.sizeof]));
                if (lock_height > tx.lock_height)
                    return "VERIFY_LOCK_HEIGHT height lock of transaction is too low";

                break;

            case OP.VERIFY_UNLOCK_AGE:
                if (stack.empty())
                    return "VERIFY_UNLOCK_AGE opcode requires an unlock age on the stack";

                const age_bytes = stack.pop();
                if (age_bytes.length != uint.sizeof)
                    return "VERIFY_UNLOCK_AGE unlock age must be a 4-byte number";

                const uint unlock_age = littleEndianToNative!uint(
                    age_bytes[0 .. uint.sizeof]);
                if (unlock_age > input.unlock_age)
                    return "VERIFY_UNLOCK_AGE unlock age of input is too low";

                break;

            default:
                assert(0);  // should have been handled
            }
        }

        if (!sc.empty())
            return "IF / NOT_IF requires a closing END_IF";

        return null;
    }

    /***************************************************************************

        Handle a conditional opcode like `OP.IF` / `OP.ELSE` / etc.

        The initial scope is implied to be true. When a new scope is entered
        via `OP.IF` / `OP.NOT_IF`, the condition is checked. If the condition
        is false, then all the code inside the `OP.IF` / `OP.NOT_IF`` block
        will be skipped until we exit into the first scope where the condition
        is true.

        Execution will fail if there is an `OP.ELSE` or `OP.END_IF` opcode
        without an associated `OP.IF` / `OP.NOT_IF` opcode.

        Currently trailing `OP.ELSE` opcodes are not rejected.
        This is also a quirk in the Bitcoin language, and should
        be fixed here later.
        (e.g. `IF { } ELSE {} ELSE {} ELSE {}` is allowed).

        Params:
            opcode = the current conditional
            stack = the stack to evaluate for the conditional
            sc = the scope condition which may be toggled by a condition change

        Returns:
            null if there were no errors,
            or a string explaining the reason execution failed

    ***************************************************************************/

    private string handleConditional (in OP opcode,
        ref Stack stack, ref ScopeCondition sc) nothrow @safe
    {
        switch (opcode)
        {
        case OP.IF:
        case OP.NOT_IF:
            if (!sc.isTrue())
            {
                sc.push(false);  // enter new scope, remain false
                break;
            }

            if (stack.empty())
                return "IF/NOT_IF opcode requires an item on the stack";

            const top = stack.pop();
            if (top != TrueValue && top != FalseValue)
                return "IF/NOT_IF may only be used with OP.TRUE / OP.FALSE values";

            sc.push((opcode == OP.IF) ^ (top == FalseValue));
            break;

        case OP.ELSE:
            if (sc.empty())
                return "Cannot have an ELSE without an associated IF / NOT_IF";
            sc.tryToggle();
            break;

        case OP.END_IF:
            if (sc.empty())
                return "Cannot have an END_IF without an associated IF / NOT_IF";
            sc.pop();
            break;

        default:
            assert(0);
        }

        return null;
    }

    /***************************************************************************

        Checks if the script has failed execution by examining its stack.
        The script is considered sucessfully executed only if its stack
        contains exactly one item, and that item being `TrueValue`.

        Params:
            stack = the stack to check

        Returns:
            true if the script is considered to have failed execution

    ***************************************************************************/

    private bool hasScriptFailed (/*in*/ ref Stack stack) // peek() is not const
        pure nothrow @safe
    {
        return stack.empty() || stack.peek() != TrueValue;
    }

    /***************************************************************************

        Reads the length and payload of the associated `PUSH_DATA_*` opcode,
        and advances the `opcodes` array to the next opcode.

        The length is read in little endian format.

        Params:
            OP = the associated `PUSH_DATA_*` opcode
            opcodes = the opcode / data byte array
            payload = will contain the payload if successfull

        Returns:
            null if reading the payload was successfull,
            otherwise the string explaining why it failed

    ***************************************************************************/

    private string readPayload (OP op)(ref const(ubyte)[] opcodes,
        out const(ubyte)[] payload) nothrow @safe /*@nogc*/
    {
        static assert(op == OP.PUSH_DATA_1 || op == OP.PUSH_DATA_2);
        alias T = Select!(op == OP.PUSH_DATA_1, ubyte, ushort);
        if (opcodes.length < T.sizeof)
            assert(0);  // script should have been validated

        const T size = littleEndianToNative!T(opcodes[0 .. T.sizeof]);
        if (size == 0 || size > this.StackMaxItemSize)
            assert(0);  // ditto

        opcodes.popFrontN(T.sizeof);
        if (opcodes.length < size)
            assert(0);  // ditto

        payload = opcodes[0 .. size];
        opcodes.popFrontN(size);  // advance to next opcode
        return null;
    }

    /***************************************************************************

        Reads the Signature and Public key from the stack,
        and validates the signature against the provided
        spending transaction.

        If the Signature and Public key are missing or in an invalid format,
        an error string is returned.

        Otherwise the signature is validated and the `sig_valid` parameter
        is set to the validation result.

        Params:
            OP = the opcode
            stack = should contain the Signature and Public Key
            tx = the transaction that should have been signed
            input = the Input which contained the unlock script
            sig_valid = will contain the validation result

        Returns:
            an error string if the Signature and Public key are missing or
            invalid, otherwise returns null.

    ***************************************************************************/

    private string verifySignature (OP op)(ref Stack stack,
        in Transaction tx, in Input input, out bool sig_valid)
        nothrow @safe //@nogc  // stack.pop() is not @nogc
    {
        static assert(op == OP.CHECK_SIG || op == OP.VERIFY_SIG);

        // if changed, check assumptions
        static assert(PublicKey.sizeof == 32);
        static assert(Signature.sizeof == 64);

        static immutable opcode = op.to!string;
        if (stack.count() < 2)
        {
            static immutable err1 = opcode
                ~ " opcode requires two items on the stack";
            return err1;
        }

        const key_bytes = stack.pop();
        if (key_bytes.length != PublicKey.sizeof)
        {
            static immutable err2 = opcode
                ~ " opcode requires 32-byte public key on the stack";
            return err2;
        }

        const point = PublicKey(key_bytes);
        if (!point.isValid())
        {
            static immutable err3 = opcode
                ~ " 32-byte public key on the stack is invalid";
            return err3;
        }

        const sig_bytes = stack.pop();
        SigPair sig_pair;
        ulong pop_count;
        if (auto reason = decodeSignature(sig_bytes, sig_pair, pop_count))
            return opcode ~ " " ~ reason;

        sig_valid = this.isValidSignature(point, sig_pair, tx, input);
        return null;
    }

    /***************************************************************************

        Checks whether the given signature is valid for the provided key,
        SigHash type, transaction, and the input which contained the
        signature.

        Params:
            key = the key to validate the signature with
            sig_hash = selects the behavior of the signature validation
                       algorithm, potentially blanking out parts of the tx
                       before hashing the tx & validating the signature
            sig = the signature itself
            tx = the spending transaction
            input = the Input which contained the signature

        Returns:
            true if the signature is valid for the given set of parameters

    ***************************************************************************/

    private bool isValidSignature (in PublicKey key, in SigPair sig_pair,
        in Transaction tx, in Input input = Input.init)
        nothrow @safe // @nogc  // serializing allocates
    {
        // workaround: input index not explicitly passed in
        import std.algorithm : countUntil;
        const long input_idx = tx.inputs.countUntil(input);
        if (sig_pair.sig_hash != SigHash.All)
            assert(input_idx != -1, "Input does not belong to this transaction");

        if (sig_pair.output_idx >= tx.outputs.length)
            return false;

        const challenge = getChallenge(tx, sig_pair.sig_hash, input_idx, sig_pair.output_idx);
        return verify(key, sig_pair.signature, challenge);
    }

    /***************************************************************************

        Verifies a threshold multi-signature. Any `N of M` configuration up to
        5 keys and 5 signatures is allowed.

        Reads a `count` from the stack, then reads `count` number of Public
        keys from the stack, then reads `req_count` from the stack, then reads
        `req_count` number of signatures from the stack.

        There need to be exactly `req_count` valid signatures on the stack.

        For each key it will try to validate against the first signature.
        When validation fails, it tries the next key with the same signature.
        When validation succeeds, it moves on to the next signature.

        The keys and signatures must be placed in the same order on the stack.

        If any of the Signatures or Public keys are missing or in an
        invalid format, an error string is returned.

        Otherwise the mult-sig is checked and the `sig_valid` parameter
        is set to the validation result.

        Params:
            OP = the opcode
            stack = should contain the count, the public keys,
                the count of required signatures
            tx = the transaction that should have been signed

        Returns:
            an error string if the Signature and Public key are missing or
            invalid, otherwise returns null.

    ***************************************************************************/

    private string verifyMultiSig (OP op)(ref Stack stack, in Transaction tx,
        out bool sig_valid) nothrow @safe //@nogc  // stack.pop() is not @nogc
    {
        static assert(op == OP.CHECK_MULTI_SIG || op == OP.VERIFY_MULTI_SIG);

        // if changed, check assumptions
        static assert(PublicKey.sizeof == 32);
        static assert(Signature.sizeof == 64);

        // todo: move to consensus params?
        enum MAX_PUB_KEYS = 5;
        alias MAX_SIGNATURES = MAX_PUB_KEYS;

        // two counts plus the pubkeys and the signatures
        enum MAX_STACK_ITEMS = 2 + MAX_PUB_KEYS + MAX_SIGNATURES;

        // smallest possible stack is: <sig> <1> <pubkey> <1>
        if (stack.count() < 4)
        {
            static immutable err1 = op.to!string
                ~ " opcode requires at minimum four items on the stack";
            return err1;
        }

        if (stack.count() > MAX_STACK_ITEMS)
        {
            static immutable err2 = op.to!string
                ~ " opcode cannot accept more than " ~ MAX_PUB_KEYS.to!string
                ~ " keys and " ~ MAX_SIGNATURES.to!string
                ~ " signatures on the stack";
            return err2;
        }

        const pubkey_count_arr = stack.pop();
        if (pubkey_count_arr.length != 1)
        {
            static immutable err3 = op.to!string
                ~ " opcode requires 1-byte public key count on the stack";
            return err3;
        }

        const ubyte key_count = pubkey_count_arr[0];
        if (key_count < 1 || key_count > MAX_PUB_KEYS)
        {
            static immutable err4 = op.to!string
                ~ " opcode can accept between 1 to " ~ MAX_PUB_KEYS.to!string
                ~ " keys on the stack";
            return err4;
        }

        if (key_count > stack.count())
        {
            static immutable err5 = op.to!string
                ~ " not enough keys on the stack";
            return err5;
        }

        // buffer
        PublicKey[MAX_PUB_KEYS] pub_keys_buffer;
        foreach (idx, ref key; pub_keys_buffer[0 .. key_count])
        {
            const key_bytes = stack.pop();
            if (key_bytes.length != PublicKey.sizeof)
            {
                static immutable err6 = op.to!string
                    ~ " opcode requires 32-byte public key on the stack";
                return err6;
            }

            key = PublicKey(key_bytes);
            if (!key.isValid())
            {
                static immutable err7 = op.to!string
                    ~ " 32-byte public key on the stack is invalid";
                return err7;
            }
        }

        // slice
        PublicKey[] keys = pub_keys_buffer[0 .. key_count];

        const sig_count_arr = stack.pop();
        if (sig_count_arr.length != 1)
        {
            static immutable err8 = op.to!string
                ~ " opcode requires 1-byte signature count on the stack";
            return err8;
        }

        const ubyte sig_count = sig_count_arr[0];
        if (sig_count < 1 || sig_count > MAX_SIGNATURES)
        {
            static immutable err9 = op.to!string
                ~ " opcode can accept between 1 to "
                ~ MAX_SIGNATURES.to!string ~ " signatures on the stack";
            return err9;
        }

        if (sig_count > stack.count())
        {
            static immutable err10 = op.to!string
                ~ " not enough signatures on the stack";
            return err10;
        }

        if (sig_count > key_count)
        {
            static immutable err11 = op.to!string
                ~ " opcode cannot accept more signatures than there are keys";
            return err11;
        }

        // buffer
        SigPair[MAX_SIGNATURES] sigs_buffer;
        ulong pop_count;
        foreach (idx, ref sig; sigs_buffer[0 .. sig_count])
        {
            const sig_bytes = stack.pop();
            if (auto err = decodeSignature(sig_bytes, sig, pop_count))
                return err;
            if (sig_bytes.length != pop_count)
            {
                static immutable err12 = op.to!string
                    ~ " opcode found trailing bytes in signature";
                return err12;
            }
        }

        // slice
        SigPair[] sigs = sigs_buffer[0 .. sig_count];

        if (sigs.map!(s => s.sig_hash).uniq().walkLength > 1)
        {
            static immutable err13 = op.to!string
                ~ " opcode requires same sighash signatures";
            return err13;
        }

        // if there are no sigs left, validation succeeded.
        // if there are more sigs left than keys left it means we cannot reach
        // the minimum required signatures as there's not enough keys to
        // compare with.
        while (sigs.length > 0 && sigs.length <= keys.length)
        {
            if (this.isValidSignature(keys.front, sigs.front, tx))
                sigs.popFront();
            keys.popFront();
        }

        sig_valid = sigs.length == 0;
        return null;
    }

    /***************************************************************************

        Checks floating-transaction signatures for use with the Flash layer.

        Verifies the sequence signature by blanking the input, reading the
        minimum sequence, the key, the new sequence, and the signature off
        the stack and validates the signature.

        If any of the arguments expected on the stack are missing,
        an error string is returned.

        The `sig_valid` parameter will be set to the validation result
        of the signature.

        Params:
            OP = the opcode
            stack = should contain the Signature and Public Key
            tx = the transaction that should have been signed
            input = the associated Input to blank when signing
            sig_valid = will contain the signature validation result

        Returns:
            an error string if the needed arguments on the stack are missing,
            otherwise returns null

    ***************************************************************************/

    private string verifySequenceSignature (OP op)(ref Stack stack,
        in Transaction tx, in Input input, out bool sig_valid)
        nothrow @safe //@nogc  // stack.pop() is not @nogc
    {
        static assert(op == OP.CHECK_SEQ_SIG || op == OP.VERIFY_SEQ_SIG);

        // if changed, check assumptions
        static assert(PublicKey.sizeof == 32);
        static assert(Signature.sizeof == 64);

        // top to bottom: <min_seq> <key> <new_seq> <sig>
        // lock script typically pushes <min_seq> <key>
        // while the unlock script pushes <new_seq> <sig>
        if (stack.count() < 4)
        {
            static immutable err1 = op.to!string
                ~ " opcode requires 4 items on the stack";
            return err1;
        }

        const min_seq_bytes = stack.pop();
        if (min_seq_bytes.length != ulong.sizeof)
        {
            static immutable err2 = op.to!string
                ~ " opcode requires 8-byte minimum sequence on the stack";
            return err2;
        }

        const ulong min_sequence = littleEndianToNative!ulong(
            min_seq_bytes[0 .. ulong.sizeof]);

        const key_bytes = stack.pop();
        if (key_bytes.length != PublicKey.sizeof)
        {
            static immutable err3 = op.to!string
                ~ " opcode requires 32-byte public key on the stack";
            return err3;
        }

        const pubkey = PublicKey(key_bytes);
        if (!pubkey.isValid())
        {
            static immutable err4 = op.to!string
                ~ " 32-byte public key on the stack is invalid";
            return err4;
        }

        const seq_bytes = stack.pop();
        if (seq_bytes.length != ulong.sizeof)
        {
            static immutable err5 = op.to!string
                ~ " opcode requires 8-byte sequence on the stack";
            return err5;
        }

        const ulong sequence = littleEndianToNative!ulong(
            seq_bytes[0 .. ulong.sizeof]);
        if (sequence < min_sequence)
        {
            static immutable err6 = op.to!string
                ~ " sequence is not equal to or greater than min_sequence";
            return err6;
        }

        const sig_bytes = stack.pop();

        SigPair sig;
        ulong pop_count;
        if (auto err = decodeSignature(sig_bytes, sig, pop_count))
            return err;

        if (sig_bytes.length != pop_count)
        {
            static immutable err7 = op.to!string
                ~ " opcode found trailing bytes in signature";
            return err7;
        }

        // workaround: input index not explicitly passed in
        import std.algorithm : countUntil;
        const long input_idx = tx.inputs.countUntil(input);
        assert(input_idx != -1, "Input does not belong to this transaction");

        const Hash challenge = getSequenceChallenge(tx, sequence, input_idx,
            sig.output_idx, sig.sig_hash);
        sig_valid = pubkey.verify(sig.signature, challenge);
        return null;
    }
}

/*******************************************************************************

    Gets the challenge hash for the provided transaction, sequence ID.

    Params:
        tx = the transaction to sign
        sequence = the sequence ID to hash
        input_idx = the associated input index we're signing for

    Returns:
        the challenge as a hash

*******************************************************************************/

public Hash getSequenceChallenge (in Transaction tx, in ulong sequence,
    in ulong input_idx, in ulong output_idx = 0, SigHash sig_hash = SigHash.NoInput) nothrow @safe
{
    assert(input_idx < tx.inputs.length, "Input index is out of range");
    return hashMulti(tx.getChallenge(sig_hash, input_idx, output_idx), sequence);
}

version (unittest)
{
    // sensible defaults
    private const TestStackMaxTotalSize = 16_384;
    private const TestStackMaxItemSize = 512;
}

/// Helper routine to sign a whole msg (SigHash.All)
version (unittest)
public SigPair signTx (in KeyPair kp, in Transaction tx) nothrow @safe /*@nogc*/
{
    const challenge = getChallenge(tx, SigHash.All, 0);
    return SigPair(kp.sign(challenge), SigHash.All);
}

// OP.DUP
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    assert(engine.execute(
        Lock(LockType.Script, [OP.DUP]), Unlock.init, Transaction.init,
            Input.init) ==
        "DUP opcode requires an item on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [1, 2, OP.CHECK_EQUAL]), Unlock.init,
            Transaction.init, Input.init) ==
        "CHECK_EQUAL opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [1, 1, OP.DUP, OP.CHECK_EQUAL]), Unlock.init,
            Transaction.init, Input.init)
        is null);  // CHECK_EQUAL will always succeed after an OP.DUP
}

// OP.HASH
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    assert(engine.execute(
        Lock(LockType.Script, [OP.HASH]), Unlock.init, Transaction.init,
            Input.init) ==
        "HASH opcode requires an item on the stack");
    const ubyte[] bytes = [42];
    const Hash hash = HashNoLength(bytes).hashFull();
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(bytes)
            ~ [ubyte(OP.HASH)]
            ~ toPushOpcode(hash[])
            ~ [ubyte(OP.CHECK_EQUAL)]),
        Unlock.init, Transaction.init, Input.init)
        is null);
}

// OP.CHECK_EQUAL
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const tx = Transaction([Input.init], [Output.init]);
    assert(engine.execute(
        Lock(LockType.Script, [OP.CHECK_EQUAL]), Unlock.init, tx, Input.init) ==
        "CHECK_EQUAL opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script, [1, 1, OP.CHECK_EQUAL]),
        Unlock.init, tx, Input.init) ==
        "CHECK_EQUAL opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [1, 1, 1, 1, OP.CHECK_EQUAL]),
        Unlock.init, tx, Input.init)
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            [1, 2, 1, 1, OP.CHECK_EQUAL]),
        Unlock.init, tx, Input.init) ==
        "Script failed");
}

// OP.VERIFY_EQUAL
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const tx = Transaction([Input.init], [Output.init]);
    assert(engine.execute(
        Lock(LockType.Script, [OP.VERIFY_EQUAL]), Unlock.init, tx, Input.init) ==
        "VERIFY_EQUAL opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script, [1, 1, OP.VERIFY_EQUAL]),
        Unlock.init, tx, Input.init) ==
        "VERIFY_EQUAL opcode requires two items on the stack");
    assert(engine.execute(   // OP.TRUE needed as VERIFY does not push to stack
        Lock(LockType.Script,
            [1, 1, 1, 1, OP.VERIFY_EQUAL, OP.TRUE]),
        Unlock.init, tx, Input.init)
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            [1, 2, 1, 1, OP.VERIFY_EQUAL, OP.TRUE]),
        Unlock.init, tx, Input.init) ==
        "VERIFY_EQUAL operation failed");
}

// OP.CHECK_SIG
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const tx = Transaction([Input.init], [Output.init]);
    assert(engine.execute(
        Lock(LockType.Script, [OP.CHECK_SIG]), Unlock.init, tx, Input.init) ==
        "CHECK_SIG opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script, [1, 1, OP.CHECK_SIG]),
        Unlock.init, tx, Input.init) ==
        "CHECK_SIG opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [1, 1, 1, 1, OP.CHECK_SIG]),
        Unlock.init, tx, Input.init) ==
        "CHECK_SIG opcode requires 32-byte public key on the stack");

    // invalid key (crypto_core_ed25519_is_valid_point() fails)
    PublicKey invalid_key;
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(1), ubyte(1)]
            ~ [ubyte(32)] ~ invalid_key[]
            ~ [ubyte(OP.CHECK_SIG)]), Unlock.init, tx, Input.init) ==
        "CHECK_SIG 32-byte public key on the stack is invalid");

    PublicKey valid_key = PublicKey.fromString(
        "boa1xzqceczgxtdxmulc9un3wxutx330f5dv56kku38zw80k6nt9fdqygxv43qs");
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(1), ubyte(1)]
            ~ [ubyte(32)] ~ valid_key[]
            ~ [ubyte(OP.CHECK_SIG)]), Unlock.init, tx, Input.init) ==
        "CHECK_SIG Encoded signature tuple is of the wrong size");

    SigPair invalid_sig;
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(65)] ~ invalid_sig[]
            ~ [ubyte(32)] ~ valid_key[]
            ~ [ubyte(OP.CHECK_SIG)]), Unlock.init, tx, Input.init) ==
        "Script failed");
    const kp = KeyPair.random();
    const sig = signTx(kp, tx);
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(65)] ~ sig[]
            ~ [ubyte(32)] ~ kp.address[]
            ~ [ubyte(OP.CHECK_SIG)]), Unlock.init, tx, Input.init)
        is null);
}

// OP.VERIFY_SIG
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const tx = Transaction([Input.init], [Output.init]);
    assert(engine.execute(
        Lock(LockType.Script, [OP.VERIFY_SIG]), Unlock.init, tx, Input.init) ==
        "VERIFY_SIG opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script, [OP.PUSH_BYTES_1, 1, OP.VERIFY_SIG]),
        Unlock.init, tx, Input.init) ==
        "VERIFY_SIG opcode requires two items on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.PUSH_BYTES_1, 1, OP.PUSH_BYTES_1, 1, OP.VERIFY_SIG]),
        Unlock.init, tx, Input.init) ==
        "VERIFY_SIG opcode requires 32-byte public key on the stack");

    // invalid key (crypto_core_ed25519_is_valid_point() fails)
    PublicKey invalid_key;
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(OP.PUSH_BYTES_1), ubyte(1)]
            ~ [ubyte(32)] ~ invalid_key[]
            ~ [ubyte(OP.VERIFY_SIG)]), Unlock.init, tx, Input.init) ==
        "VERIFY_SIG 32-byte public key on the stack is invalid");

    PublicKey valid_key = PublicKey.fromString(
        "boa1xzqceczgxtdxmulc9un3wxutx330f5dv56kku38zw80k6nt9fdqygxv43qs");
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(OP.PUSH_BYTES_1), ubyte(1)]
            ~ [ubyte(32)] ~ valid_key[]
            ~ [ubyte(OP.VERIFY_SIG)]), Unlock.init, tx, Input.init) ==
        "VERIFY_SIG Encoded signature tuple is of the wrong size");

    SigPair invalid_sig;
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(65)] ~ invalid_sig[]
            ~ [ubyte(32)] ~ valid_key[]
            ~ [ubyte(OP.VERIFY_SIG)]), Unlock.init, tx, Input.init) ==
        "VERIFY_SIG signature failed validation");

    const kp = KeyPair.random();
    const sig = signTx(kp, tx);
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(65)] ~ sig[]
            ~ [ubyte(32)] ~ kp.address[]
            ~ [ubyte(OP.VERIFY_SIG)]), Unlock.init, tx, Input.init) ==
        "Script failed");  // VERIFY_SIG does not push TRUE to the stack
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(65)] ~ sig[]
            ~ [ubyte(32)] ~ kp.address[]
            ~ [ubyte(OP.VERIFY_SIG)]), Unlock([ubyte(OP.TRUE)]), tx, Input.init)
        is null);
}

// OP.CHECK_MULTI_SIG / OP.VERIFY_MULTI_SIG
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const tx = Transaction([Input.init], [Output.init]);
    assert(engine.execute(
        Lock(LockType.Script, [OP.CHECK_MULTI_SIG]), Unlock.init, tx, Input.init) ==
        "CHECK_MULTI_SIG opcode requires at minimum four items on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.PUSH_NUM_1, OP.PUSH_NUM_1, OP.PUSH_NUM_1, OP.CHECK_MULTI_SIG]),
        Unlock.init, tx, Input.init) ==
        "CHECK_MULTI_SIG opcode requires at minimum four items on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.PUSH_NUM_1, OP.PUSH_NUM_1, OP.PUSH_NUM_1, OP.PUSH_NUM_1,
                OP.CHECK_MULTI_SIG]),
        Unlock.init, tx, Input.init) ==
        "CHECK_MULTI_SIG opcode requires 32-byte public key on the stack");
    // invalid key (crypto_core_ed25519_is_valid_point() fails)
    PublicKey invalid_key;
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_1)]  // required sigs
            ~ [ubyte(32)] ~ invalid_key[]
            ~ [ubyte(OP.PUSH_NUM_1)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ SigPair.init[]),
        tx, Input.init) ==
        "CHECK_MULTI_SIG 32-byte public key on the stack is invalid");
    // valid key, invalid signature
    PublicKey valid_key = PublicKey.fromString(
        "boa1xzqceczgxtdxmulc9un3wxutx330f5dv56kku38zw80k6nt9fdqygxv43qs");
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_1)]  // required sigs
            ~ [ubyte(32)] ~ valid_key[]
            ~ [ubyte(OP.PUSH_NUM_1)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ SigPair.init[]),
        tx, Input.init) ==
        "Script failed");

    const kp1 = KeyPair.random();
    const sig1 = SigPair(kp1.sign(tx.getChallenge()), SigHash.All);
    const kp2 = KeyPair.random();
    const sig2 = SigPair(kp2.sign(tx.getChallenge()), SigHash.All);
    const kp3 = KeyPair.random();
    const sig3 = SigPair(kp3.sign(tx.getChallenge()), SigHash.All);
    const kp4 = KeyPair.random();
    const sig4 = SigPair(kp4.sign(tx.getChallenge()), SigHash.All);
    const kp5 = KeyPair.random();
    const sig5 = SigPair(kp5.sign(tx.getChallenge()), SigHash.All);

    // valid key + signature
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_1)]  // required sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(OP.PUSH_NUM_1)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]),
        tx, Input.init)
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // fails: more sigs than keys
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(OP.PUSH_NUM_1)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig2[]),
        tx, Input.init) ==
        "CHECK_MULTI_SIG opcode cannot accept more signatures than there are keys");
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(OP.PUSH_NUM_2)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]),  // fails: not enough sigs pushed
        tx, Input.init) ==
        "CHECK_MULTI_SIG not enough signatures on the stack");
    // valid
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(OP.PUSH_NUM_2)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig2[]),
        tx, Input.init)
        is null);
    // invalid order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(OP.PUSH_NUM_2)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig2[]),
        tx, Input.init) ==
        "Script failed");
    // ditto invalid order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(OP.PUSH_NUM_2)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig2[]
             ~ [ubyte(65)] ~ sig1[]),
        tx, Input.init) ==
        "Script failed");
    // 1 of 2 is ok
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_1)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(OP.PUSH_NUM_2)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]),
        tx, Input.init)
        is null);
    // ditto 1 of 2 is ok
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_1)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(OP.PUSH_NUM_2)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig2[]),
        tx, Input.init)
        is null);
    // 1 of 5: any sig is enough
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_1)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]),
        tx, Input.init)
        is null);
    // 1 of 5: ditto
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_1)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig2[]),
        tx, Input.init)
        is null);
    // 2 of 5: ok when sigs are in the same order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig5[]),
        tx, Input.init)
        is null);
    // 2 of 5: fails when sigs are in the wrong order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig5[]
             ~ [ubyte(65)] ~ sig1[]),
        tx, Input.init) ==
        "Script failed");
    // 3 of 5: ok when sigs are in the same order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig3[]
             ~ [ubyte(65)] ~ sig5[]),
        tx, Input.init)
        is null);
    // 3 of 5: fails when sigs are in the wrong order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig5[]
             ~ [ubyte(65)] ~ sig3[]),
        tx, Input.init) ==
        "Script failed");
    // 5 of 5: ok when sigs are in the same order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_5)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig2[]
             ~ [ubyte(65)] ~ sig3[]
             ~ [ubyte(65)] ~ sig4[]
             ~ [ubyte(65)] ~ sig5[]),
        tx, Input.init)
        is null);
    // 5 of 5: fails when sigs are in the wrong order
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_5)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.CHECK_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig3[]
             ~ [ubyte(65)] ~ sig2[]
             ~ [ubyte(65)] ~ sig4[]
             ~ [ubyte(65)] ~ sig5[]),
        tx, Input.init) ==
        "Script failed");
    // ditto but with VERIFY_MULTI_SIG
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(OP.PUSH_NUM_2)]  // number of sigs
            ~ [ubyte(32)] ~ kp1.address[]
            ~ [ubyte(32)] ~ kp2.address[]
            ~ [ubyte(32)] ~ kp3.address[]
            ~ [ubyte(32)] ~ kp4.address[]
            ~ [ubyte(32)] ~ kp5.address[]
            ~ [ubyte(OP.PUSH_NUM_5)]  // number of keys
            ~ [ubyte(OP.VERIFY_MULTI_SIG)]),
        Unlock([ubyte(65)] ~ sig1[]
             ~ [ubyte(65)] ~ sig5[]
             ~ [ubyte(65)] ~ sig3[]),
        tx, Input.init) ==
        "VERIFY_MULTI_SIG signature failed validation");
}

// OP.CHECK_SEQ_SIG / OP.VERIFY_SEQ_SIG
unittest
{
    // Expected top to bottom on stack: <min_seq> <key> [<new_seq> <sig>]
    //
    // Unlock script pushes in order: [<sig>, <new_seq>]
    // Lock script pushes in order: <key>, <min_seq>
    //
    // Stack:
    //   <min_seq>
    //   <key>
    //   <new_seq>
    //   <sig>

    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const Transaction tx = Transaction([Input.init], [Output.init]);
    assert(engine.execute(
        Lock(LockType.Script, [OP.CHECK_SEQ_SIG]), Unlock.init, tx, tx.inputs[0]) ==
        "CHECK_SEQ_SIG opcode requires 4 items on the stack");
    assert(engine.execute(
        Lock(LockType.Script, [OP.VERIFY_SEQ_SIG]), Unlock.init, tx, tx.inputs[0]) ==
        "VERIFY_SEQ_SIG opcode requires 4 items on the stack");
    assert(engine.execute(
        Lock(LockType.Script, [1, 42, 1, 42, 1, 42, OP.CHECK_SEQ_SIG]),
        Unlock.init, tx, tx.inputs[0]) ==
        "CHECK_SEQ_SIG opcode requires 4 items on the stack");
    assert(engine.execute(
        Lock(LockType.Script,
            [1, 42, 1, 42, 1, 42, 1, 42, OP.CHECK_SEQ_SIG]),
        Unlock.init, tx, tx.inputs[0]) ==
        "CHECK_SEQ_SIG opcode requires 8-byte minimum sequence on the stack");

    const seq_0 = ulong(0);
    const seq_1 = ulong(1);
    const seq_0_bytes = nativeToLittleEndian(seq_0);
    const seq_1_bytes = nativeToLittleEndian(seq_1);

    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(1), ubyte(1)]  // wrong pubkey size
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ SigPair.init[]
            ~ toPushOpcode(seq_0_bytes)), tx, tx.inputs[0]) ==
        "CHECK_SEQ_SIG opcode requires 32-byte public key on the stack");

    // invalid key (crypto_core_ed25519_is_valid_point() fails)
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ PublicKey.init[]  // size ok, form is wrong
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ SigPair.init[]
            ~ toPushOpcode(seq_0_bytes)), tx, tx.inputs[0]) ==
        "CHECK_SEQ_SIG 32-byte public key on the stack is invalid");

    PublicKey rand_key = PublicKey.fromString(
        "boa1xzqceczgxtdxmulc9un3wxutx330f5dv56kku38zw80k6nt9fdqygxv43qs");
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ rand_key[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ SigPair.init[]
            // wrong sequence size
            ~ toPushOpcode(nativeToLittleEndian(ubyte(1)))), tx, tx.inputs[0]) ==
        "CHECK_SEQ_SIG opcode requires 8-byte sequence on the stack");

    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ rand_key[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ SigPair.init[]
            ~ toPushOpcode(seq_0_bytes)), tx, tx.inputs[0]) ==
        "Script failed");

    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ rand_key[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(1)] ~ [ubyte(1)]  // wrong signature size
            ~ toPushOpcode(seq_0_bytes)), tx, tx.inputs[0]) ==
        "Encoded signature tuple is of the wrong size");

    const kp = KeyPair.random();
    const bad_sig = SigPair(kp.sign(tx.getChallenge()), SigHash.All);
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ rand_key[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ bad_sig[]
            ~ toPushOpcode(seq_0_bytes)), tx, tx.inputs[0]) ==
        "Script failed");  // still fails, signature didn't hash the sequence

    // create the proper signature which blanks the input and encodes the sequence
    const challenge_0 = getSequenceChallenge(tx, seq_0, 0);
    const seq_0_sig = SigPair(kp.sign(challenge_0), SigHash.NoInput);
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ kp.address[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ seq_0_sig[]
            ~ toPushOpcode(seq_0_bytes)), tx, tx.inputs[0])
        is null);

    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ kp.address[]
            ~ toPushOpcode(seq_1_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ seq_0_sig[]
            ~ toPushOpcode(seq_0_bytes)), tx, tx.inputs[0]) ==
        "CHECK_SEQ_SIG sequence is not equal to or greater than min_sequence");

    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ kp.address[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ seq_0_sig[]
            ~ toPushOpcode(seq_1_bytes)), tx, tx.inputs[0]),
        "Script failed");

    const challenge_1 = getSequenceChallenge(tx, seq_1, 0);
    const seq_1_sig = SigPair(kp.sign(challenge_1), SigHash.NoInput);
    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ kp.address[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.CHECK_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ seq_1_sig[]
            ~ toPushOpcode(seq_1_bytes)), tx, tx.inputs[0])
        is null);

    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ rand_key[]  // key mismatch
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.VERIFY_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ seq_1_sig[]
            ~ toPushOpcode(seq_1_bytes)), tx, tx.inputs[0]) ==
        "VERIFY_SEQ_SIG signature failed validation");

    assert(engine.execute(
        Lock(LockType.Script,
              [ubyte(32)] ~ kp.address[]
            ~ toPushOpcode(seq_0_bytes)
            ~ [ubyte(OP.VERIFY_SEQ_SIG)]),
        Unlock(
            [ubyte(65)] ~ seq_0_sig[]
            ~ toPushOpcode(seq_1_bytes)), tx, tx.inputs[0]) ==  // sig mismatch
        "VERIFY_SEQ_SIG signature failed validation");
}

// OP.VERIFY_LOCK_HEIGHT
unittest
{
    const height_9 = nativeToLittleEndian(ulong(9));
    const height_10 = nativeToLittleEndian(ulong(10));
    const height_11 = nativeToLittleEndian(ulong(11));

    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const Transaction tx_10 = Transaction([Input.init], [Output.init], Height(10));
    const Transaction tx_11 = Transaction([Input.init], [Output.init], Height(11));
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(height_9)
            ~ [ubyte(OP.VERIFY_LOCK_HEIGHT), ubyte(OP.TRUE)]),
        Unlock.init, tx_10, Input.init)
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(height_10)
            ~ [ubyte(OP.VERIFY_LOCK_HEIGHT), ubyte(OP.TRUE)]),
        Unlock.init, tx_10, Input.init)  // tx with matching unlock height
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(height_11)
            ~ [ubyte(OP.VERIFY_LOCK_HEIGHT), ubyte(OP.TRUE)]),
        Unlock.init, tx_10, Input.init) ==
        "VERIFY_LOCK_HEIGHT height lock of transaction is too low");
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(height_11)
            ~ [ubyte(OP.VERIFY_LOCK_HEIGHT), ubyte(OP.TRUE)]),
        Unlock.init, tx_11, Input.init)  // tx with matching unlock height
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(nativeToLittleEndian(ubyte(9)))
            ~ [ubyte(OP.VERIFY_LOCK_HEIGHT), ubyte(OP.TRUE)]),
        Unlock.init, tx_10, Input.init) ==
        "VERIFY_LOCK_HEIGHT height lock must be an 8-byte number");
    assert(engine.execute(
        Lock(LockType.Script,
            [ubyte(OP.VERIFY_LOCK_HEIGHT), ubyte(OP.TRUE)]),
        Unlock.init, tx_10, Input.init) ==
        "VERIFY_LOCK_HEIGHT opcode requires a lock height on the stack");
}

// OP.VERIFY_UNLOCK_AGE
unittest
{
    const age_9 = nativeToLittleEndian(uint(9));
    const age_10 = nativeToLittleEndian(uint(10));
    const age_11 = nativeToLittleEndian(uint(11));
    const age_overflow = nativeToLittleEndian(ulong.max);

    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const Input input_10 = Input(Hash.init, 0, 10 /* unlock_age */);
    const Input input_11 = Input(Hash.init, 0, 11 /* unlock_age */);
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(age_9)
            ~ [ubyte(OP.VERIFY_UNLOCK_AGE), ubyte(OP.TRUE)]),
        Unlock.init, Transaction.init, input_10)
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(age_10)
            ~ [ubyte(OP.VERIFY_UNLOCK_AGE), ubyte(OP.TRUE)]),
        Unlock.init, Transaction.init, input_10)  // input with matching unlock age
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(age_11)
            ~ [ubyte(OP.VERIFY_UNLOCK_AGE), ubyte(OP.TRUE)]),
        Unlock.init, Transaction.init, input_10) ==
        "VERIFY_UNLOCK_AGE unlock age of input is too low");
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(age_11)
            ~ [ubyte(OP.VERIFY_UNLOCK_AGE), ubyte(OP.TRUE)]),
        Unlock.init, Transaction.init, input_11)  // input with matching unlock age
        is null);
    assert(engine.execute(
        Lock(LockType.Script,
            toPushOpcode(age_overflow)
            ~ [ubyte(OP.VERIFY_UNLOCK_AGE), ubyte(OP.TRUE)]),
        Unlock.init, Transaction.init, input_10) ==
        "VERIFY_UNLOCK_AGE unlock age must be a 4-byte number");
    assert(engine.execute(
        Lock(LockType.Script,
            [ubyte(OP.VERIFY_UNLOCK_AGE), ubyte(OP.TRUE)]),
        Unlock.init, Transaction.init, input_10) ==
        "VERIFY_UNLOCK_AGE opcode requires an unlock age on the stack");
}

// LockType.Key (Native P2PK - Pay to Public Key), consumes 33 bytes
unittest
{
    const kp = KeyPair.random();
    const tx = Transaction([Input.init], [Output.init]);
    const sig = signTx(kp, tx);

    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    assert(engine.execute(
        Lock(LockType.Key, kp.address[]), Unlock(sig[]), tx, Input.init) ==
        null);
    const tx2 = Transaction([Input(hashFull(42))], [Output.init]);
    const bad_sig = signTx(kp, tx2);
    assert(engine.execute(
        Lock(LockType.Key, kp.address[]), Unlock(bad_sig[]), tx, Input.init) ==
        "LockType.Key signature in unlock script failed validation");
    const bad_key = KeyPair.random().address;
    assert(engine.execute(
        Lock(LockType.Key, bad_key[]), Unlock(sig[]), tx, Input.init) ==
        "LockType.Key signature in unlock script failed validation");
    assert(engine.execute(
        Lock(LockType.Key, ubyte(42).repeat(64).array),
        Unlock(sig[]), tx, Input.init) ==
        "LockType.Key requires 32-byte key argument in the lock script");
    assert(engine.execute(
        Lock(LockType.Key, ubyte(0).repeat(32).array),
        Unlock(sig[]), tx, Input.init) ==
        "LockType.Key 32-byte public key in lock script is invalid");
    assert(engine.execute(
        Lock(LockType.Key, kp.address[]),
        Unlock(ubyte(42).repeat(32).array), tx, Input.init) ==
        "LockType.Key Encoded signature tuple is of the wrong size");
    assert(engine.execute(
        Lock(LockType.Key, kp.address[]),
        Unlock(ubyte(42).repeat(66).array), tx, Input.init) !is null);
}

// LockType.KeyHash (Native P2PKH - Pay to Public Key Hash), consumes 65 bytes
unittest
{
    const kp = KeyPair.random();
    const key_hash = hashFull(kp.address);
    const tx = Transaction([Input.init], [Output.init]);
    const sig = signTx(kp, tx);
    const kp2 = KeyPair.random();
    const sig2 = signTx(kp2, tx);  // valid sig, but for a different key-pair

    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]), Unlock(sig[] ~ kp.address[]), tx, Input.init)
        is null);
    const tx2 = Transaction([Input(hashFull(42))], [Output.init]);
    const bad_sig = signTx(kp, tx2)[];
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]), Unlock(bad_sig[] ~ kp.address[]), tx, Input.init) ==
        "LockType.KeyHash signature in unlock script failed validation");
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]), Unlock(sig2[] ~ kp2.address[]), tx, Input.init) ==
        "LockType.KeyHash hash of key does not match key hash set in lock script");
    const bad_key = KeyPair.random().address;
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]), Unlock(sig[] ~ bad_key[]), tx, Input.init) ==
        "LockType.KeyHash hash of key does not match key hash set in lock script");
    assert(engine.execute(
        Lock(LockType.KeyHash, ubyte(42).repeat(63).array),
        Unlock(sig[] ~ kp.address[]), tx, Input.init) ==
        "LockType.KeyHash requires a 64-byte key hash argument in the lock script");
    assert(engine.execute(
        Lock(LockType.KeyHash, ubyte(42).repeat(65).array),
        Unlock(sig[] ~ kp.address[]), tx, Input.init) ==
        "LockType.KeyHash requires a 64-byte key hash argument in the lock script");
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]), Unlock(sig[]), tx, Input.init) ==
        "LockType.KeyHash requires a 32-byte key in the unlock script");
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]), Unlock(kp.address[]), tx, Input.init) ==
        "LockType.KeyHash Encoded signature tuple is of the wrong size");
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]), Unlock(sig[] ~ kp.address[] ~ [ubyte(0)]),
        tx, Input.init) ==
        "LockType.KeyHash requires a 32-byte key in the unlock script");
    assert(engine.execute(
        Lock(LockType.KeyHash, key_hash[]),
        Unlock(sig[] ~ ubyte(0).repeat(32).array), tx, Input.init) ==
        "LockType.KeyHash public key in unlock script is invalid");
}

// LockType.Script
unittest
{
    const kp = KeyPair.random();
    const tx = Transaction([Input.init], [Output.init]);
    const sig = signTx(kp, tx);
    const key_hash = hashFull(kp.address);
    // emulating bitcoin-style P2PKH
    const Script lock = createLockP2PKH(key_hash);
    const Script unlock = createUnlockP2PKH(sig.signature, sig.sig_hash, kp.address);

    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    assert(engine.execute(
        Lock(LockType.Script, lock[]), Unlock(unlock[]), tx, Input.init)
        is null);
    // simple push
    assert(engine.execute(
        Lock(LockType.Script,
            ubyte(42).repeat(65).array.toPushOpcode
            ~ ubyte(42).repeat(65).array.toPushOpcode
            ~ [ubyte(OP.CHECK_EQUAL)]),
        Unlock(unlock[]), tx, Input.init)
        is null);

    Script bad_key_unlock = createUnlockP2PKH(sig.signature, sig.sig_hash, KeyPair.random.address);
    assert(engine.execute(
        Lock(LockType.Script, lock[]), Unlock(bad_key_unlock[]), tx, Input.init) ==
        "VERIFY_EQUAL operation failed");

    // native script stack overflow test
    scope small = new Engine(TestStackMaxItemSize * 2, TestStackMaxItemSize);
    assert(small.execute(
        Lock(LockType.Script, lock[]),
        Unlock(
            ubyte(42).repeat(TestStackMaxItemSize).array.toPushOpcode()
            ~ ubyte(42).repeat(TestStackMaxItemSize).array.toPushOpcode()
            ~ ubyte(42).repeat(TestStackMaxItemSize).array.toPushOpcode()), tx,
        Input.init) ==
        "Stack overflow while executing PUSH_DATA_2");
}

// LockType.Redeem (Pay to Script Hash)
unittest
{
    const kp = KeyPair.random();
    const tx = Transaction([Input.init], [Output.init]);
    const Script redeem = makeScript(
        [ubyte(32)] ~ kp.address[] ~ [ubyte(OP.CHECK_SIG)]);
    const redeem_hash = hashFull(redeem);
    const sig = signTx(kp, tx);

    // lock is: <redeem hash>
    // unlock is: <push(sig)> <redeem>
    // redeem is: check sig against the key embedded in the redeem script
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    assert(engine.execute(
        Lock(LockType.Redeem, redeem_hash[]),
        Unlock([ubyte(65)] ~ sig[] ~ toPushOpcode(redeem[])),
        tx, Input.init)
        is null);
    assert(engine.execute(
        Lock(LockType.Redeem, ubyte(42).repeat(32).array),
        Unlock([ubyte(65)] ~ sig[] ~ toPushOpcode(redeem[])),
        tx, Input.init) ==
        "LockType.Redeem requires 64-byte script hash in the lock script");
    assert(engine.execute(
        Lock(LockType.Redeem, ubyte(42).repeat(65).array),
        Unlock([ubyte(65)] ~ sig[] ~ toPushOpcode(redeem[])),
        tx, Input.init) ==
        "LockType.Redeem requires 64-byte script hash in the lock script");
    assert(engine.execute(
        Lock(LockType.Redeem, redeem_hash[]),
        Unlock(null),
        tx, Input.init) ==
        "LockType.Redeem requires unlock script to push a redeem script to the stack");
    scope small = new Engine(TestStackMaxItemSize * 2, TestStackMaxItemSize);
    assert(small.execute(
        Lock(LockType.Redeem, redeem_hash[]),
        Unlock(ubyte(42).repeat(TestStackMaxItemSize * 2).array.toPushOpcode()),
        tx, Input.init) ==
        "PUSH_DATA_2 opcode payload size is not within StackMaxItemSize limits");
    assert(small.execute(
        Lock(LockType.Redeem, redeem_hash[]),
        Unlock(
            ubyte(42).repeat(TestStackMaxItemSize).array.toPushOpcode()
            ~ ubyte(42).repeat(TestStackMaxItemSize).array.toPushOpcode()
            ~ ubyte(42).repeat(TestStackMaxItemSize).array.toPushOpcode()),
        tx, Input.init) ==
        "Stack overflow while executing PUSH_DATA_2");
    const Script wrong_redeem = makeScript([ubyte(32)] ~ KeyPair.random.address[]
        ~ [ubyte(OP.CHECK_SIG)]);
    assert(engine.execute(
        Lock(LockType.Redeem, redeem_hash[]),
        Unlock([ubyte(65)] ~ sig[] ~ toPushOpcode(wrong_redeem[])),
        tx, Input.init) ==
        "LockType.Redeem unlock script pushed a redeem script which does "
        ~ "not match the redeem hash in the lock script");
    const tx2 = Transaction([Input(hashFull(42))], [Output.init]);
    auto wrong_sig = signTx(kp, tx2);
    assert(engine.execute(
        Lock(LockType.Redeem, redeem_hash[]),
        Unlock([ubyte(65)] ~ wrong_sig[] ~ toPushOpcode(redeem[])),
        tx, Input.init) ==
        "Script failed");

    // note: a redeem script cannot contain an overflown payload size
    // which exceeds `MaxItemSize` because the redeem script itself would need
    // to contain this payload, but since the redeem script itself is pushed by
    // the unlock script then the unlock script validation would have already
    // failed before the redeem script validation could ever fail.
    const Script bad_opcode_redeem = makeScript([ubyte(255)]);
    assert(small.execute(
        Lock(LockType.Redeem, bad_opcode_redeem.hashFull()[]),
        Unlock(toPushOpcode(bad_opcode_redeem[])),
        tx, Input.init) ==
        "Script contains an unrecognized opcode");

    // however it may include opcodes which overflow the stack during execution.
    // here 1 byte => 64 bytes, causing a stack overflow
    scope tiny = new Engine(10, 10);
    const Script overflow_redeem = makeScript([OP.TRUE, OP.HASH]);
    assert(tiny.execute(
        Lock(LockType.Redeem, overflow_redeem.hashFull()[]),
        Unlock(toPushOpcode(overflow_redeem[])),
        tx, Input.init) ==
        "Stack overflow while executing HASH");
}

// Basic invalid script verification
unittest
{
    auto kp = KeyPair.random();
    const tx = Transaction([Input.init], [Output.init]);
    const sig = signTx(kp, tx);

    const key_hash = hashFull(kp.address);
    Script lock = createLockP2PKH(key_hash);
    Script unlock = createUnlockP2PKH(sig.signature, sig.sig_hash, kp.address);

    const invalid_script = makeScript([255]);
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    assert(engine.execute(
        Lock(LockType.Script, lock[]), Unlock(unlock[]), tx, Input.init)
        is null);
    // invalid scripts / sigs
    assert(engine.execute(
        Lock(LockType.Script, []), Unlock(unlock[]), tx, Input.init) ==
        "Lock script must not be empty");
    assert(engine.execute(
        Lock(LockType.Script, invalid_script[]), Unlock(unlock[]), tx, Input.init) ==
        "Script contains an unrecognized opcode");
    assert(engine.execute(
        Lock(LockType.Script, lock[]), Unlock(invalid_script[]), tx, Input.init) ==
        "Script contains an unrecognized opcode");
}

// Item size & stack size limits checks
unittest
{
    import std.algorithm;
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const tx = Transaction([Input.init], [Output.init]);
    const StackMaxItemSize = 512;
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(1), ubyte(42)] ~ [ubyte(OP.TRUE)]),
        Unlock.init, tx, Input.init)
        is null);

    assert(engine.execute(
        Lock(LockType.Script, ubyte(42).repeat(TestStackMaxItemSize + 1)
            .array.toPushOpcode()
            ~ [ubyte(OP.TRUE)]),
        Unlock.init, tx, Input.init) ==
        "PUSH_DATA_2 opcode payload size is not within StackMaxItemSize limits");

    const MaxItemPush = ubyte(42).repeat(TestStackMaxItemSize).array
        .toPushOpcode();
    const MaxPushes = TestStackMaxTotalSize / TestStackMaxItemSize;
    // strict power of two to make the tests easy to write
    assert(TestStackMaxTotalSize % TestStackMaxItemSize == 0);

    // overflow with PUSH_DATA_1
    scope tiny = new Engine(120, 77);
    assert(tiny.execute(
        Lock(LockType.Script,
            ubyte(42).repeat(76).array.toPushOpcode()
            ~ ubyte(42).repeat(76).array.toPushOpcode()
            ~ ubyte(42).repeat(76).array.toPushOpcode()
            ~ [ubyte(OP.TRUE)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while executing PUSH_DATA_1");

    // ditto with PUSH_DATA_2
    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes + 1).joiner.array
            ~ [ubyte(OP.TRUE)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while executing PUSH_DATA_2");

    // within limit, but missing OP.TRUE on stack
    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes).joiner.array),
        Unlock.init, tx, Input.init) ==
        "Script failed");

    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes).joiner.array
            ~ [ubyte(OP.TRUE)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while pushing TRUE to the stack");

    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes).joiner.array
            ~ [ubyte(OP.FALSE)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while pushing FALSE to the stack");

    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes).joiner.array
            ~ [ubyte(1), ubyte(1)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while executing PUSH_BYTES_*");

    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes).joiner.array
            ~ [ubyte(1), ubyte(1)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while executing PUSH_BYTES_*");

    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes).joiner.array
            ~ [ubyte(OP.DUP)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while executing DUP");

    // will fit, pops TestStackMaxItemSize and pushes 64 bytes
    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes).joiner.array
            ~ [ubyte(OP.HASH), ubyte(OP.TRUE)]),
        Unlock.init, tx, Input.init)
        is null);

    assert(engine.execute(
        Lock(LockType.Script, MaxItemPush.repeat(MaxPushes - 1).joiner.array
            ~ [ubyte(1), ubyte(1)].repeat(TestStackMaxItemSize).joiner.array
            ~ ubyte(OP.HASH) ~ [ubyte(OP.TRUE)]),
        Unlock.init, tx, Input.init) ==
        "Stack overflow while executing HASH");

    // stack overflow in only one of the branches.
    // will only overflow if that branch is taken, else payload is discarded.
    // note that syntactical validation is still done for the entire script,
    // so `StackMaxItemSize` is still checked
    Lock lock_if = Lock(LockType.Script,
        [ubyte(OP.IF)]
            ~ ubyte(42).repeat(76).array.toPushOpcode()
            ~ ubyte(42).repeat(76).array.toPushOpcode()
            ~ ubyte(42).repeat(76).array.toPushOpcode()
         ~ [ubyte(OP.ELSE),
            ubyte(OP.TRUE),
         ubyte(OP.END_IF)]);

    assert(tiny.execute(
        lock_if, Unlock([ubyte(OP.TRUE)]), tx, Input.init) ==
        "Stack overflow while executing PUSH_DATA_1");
    assert(tiny.execute(
        lock_if, Unlock([ubyte(OP.FALSE)]), tx, Input.init)
        is null);
}

// IF, NOT_IF, ELSE, END_IF conditional logic
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const tx = Transaction([Input.init], [Output.init]);

    // IF true => execute if branch
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.TRUE, OP.IF, OP.TRUE, OP.ELSE, OP.FALSE, OP.END_IF]),
        Unlock.init, tx, Input.init)
        is null);

    // IF false => execute else branch
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.FALSE, OP.IF, OP.TRUE, OP.ELSE, OP.FALSE, OP.END_IF]),
        Unlock.init, tx, Input.init) ==
        "Script failed");

    // NOT_IF true => execute if branch
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.FALSE, OP.NOT_IF, OP.TRUE, OP.ELSE, OP.FALSE, OP.END_IF]),
        Unlock.init, tx, Input.init)
        is null);

    // NOT_IF false => execute else branch
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.TRUE, OP.NOT_IF, OP.TRUE, OP.ELSE, OP.FALSE, OP.END_IF]),
        Unlock.init, tx, Input.init) ==
        "Script failed");

    // dangling IF / NOT_IF
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.TRUE, OP.IF]),
        Unlock.init, tx, Input.init) ==
        "IF / NOT_IF requires a closing END_IF");

    // ditto
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.TRUE, OP.NOT_IF]),
        Unlock.init, tx, Input.init) ==
        "IF / NOT_IF requires a closing END_IF");

    // unmatched ELSE
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.TRUE, OP.ELSE]),
        Unlock.init, tx, Input.init) ==
        "Cannot have an ELSE without an associated IF / NOT_IF");

    // unmatched END_IF
    assert(engine.execute(
        Lock(LockType.Script,
            [OP.TRUE, OP.END_IF]),
        Unlock.init, tx, Input.init) ==
        "Cannot have an END_IF without an associated IF / NOT_IF");

    /* nested conditionals */

    // IF true => IF true => OP.TRUE
    const Lock lock_1 =
        Lock(LockType.Script,
            [OP.IF,
                 OP.IF,
                    OP.TRUE,
                 OP.ELSE,
                    OP.FALSE,
                 OP.END_IF,
             OP.ELSE,
                 OP.IF,
                    OP.FALSE,
                 OP.ELSE,
                    OP.FALSE,
                 OP.END_IF,
             OP.END_IF]);

    assert(engine.execute(lock_1, Unlock([OP.TRUE, OP.TRUE]), tx, Input.init)
        is null);
    assert(engine.execute(lock_1, Unlock([OP.TRUE, OP.FALSE]), tx, Input.init) ==
        "Script failed");
    assert(engine.execute(lock_1, Unlock([OP.FALSE, OP.TRUE]), tx, Input.init) ==
        "Script failed");
    assert(engine.execute(lock_1, Unlock([OP.FALSE, OP.FALSE]), tx, Input.init) ==
        "Script failed");

    // IF true => NOT_IF true => OP.TRUE
    const Lock lock_2 =
        Lock(LockType.Script,
            [OP.IF,
                 OP.NOT_IF,
                    OP.TRUE,
                 OP.ELSE,
                    OP.FALSE,
                 OP.END_IF,
             OP.ELSE,
                 OP.IF,
                    OP.FALSE,
                 OP.ELSE,
                    OP.FALSE,
                 OP.END_IF,
             OP.END_IF]);

    // note: remember that it's LIFO, second push is evaluted first!
    assert(engine.execute(lock_2, Unlock([OP.TRUE, OP.TRUE]), tx, Input.init) ==
        "Script failed");
    assert(engine.execute(lock_2, Unlock([OP.TRUE, OP.FALSE]), tx, Input.init) ==
        "Script failed");
    assert(engine.execute(lock_2, Unlock([OP.FALSE, OP.TRUE]), tx, Input.init) ==
        null);
    assert(engine.execute(lock_2, Unlock([OP.FALSE, OP.FALSE]), tx, Input.init) ==
        "Script failed");

    /* syntax checks */
    assert(engine.execute(
        Lock(LockType.Script, [OP.IF]),
        Unlock.init, tx, Input.init) ==
        "IF/NOT_IF opcode requires an item on the stack");

    assert(engine.execute(
        Lock(LockType.Script, [ubyte(1), ubyte(2), OP.IF]),
        Unlock.init, tx, Input.init) ==
        "IF/NOT_IF may only be used with OP.TRUE / OP.FALSE values");

    assert(engine.execute(
        Lock(LockType.Script, [OP.TRUE, OP.IF]),
        Unlock.init, tx, Input.init) ==
        "IF / NOT_IF requires a closing END_IF");
}

// SigHash.NoInput / SigHash.All
unittest
{
    scope engine = new Engine(TestStackMaxTotalSize, TestStackMaxItemSize);
    const input_1 = Input(hashFull(1));
    const input_2 = Input(hashFull(2));
    auto tx_1 = Transaction([input_1], [Output.init], Height(0));
    auto tx_2 = Transaction([input_2], [Output.init], Height(0));
    const kp = KeyPair.random();

    SigPair sigpair_noinput;
    sigpair_noinput.sig_hash = SigHash.NoInput;
    const challenge_noinput = getChallenge(tx_1, SigHash.NoInput, 0);
    sigpair_noinput.signature = kp.sign(challenge_noinput);

    assert(engine.execute(
        Lock(LockType.Script, [ubyte(32)] ~ kp.address[] ~ [ubyte(OP.CHECK_SIG)]),
        Unlock([ubyte(65)] ~ sigpair_noinput[]),
        tx_1,
        tx_1.inputs[0]) ==
        null);
    // SigHash.NoInput can bind to a different input with the same keypair
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(32)] ~ kp.address[] ~ [ubyte(OP.CHECK_SIG)]),
        Unlock([ubyte(65)] ~ sigpair_noinput[]),
        tx_2,
        tx_2.inputs[0]) ==
        null);

    SigPair sigpair_all;
    sigpair_all.sig_hash = SigHash.All;
    const challenge_all = getChallenge(tx_1, SigHash.All, 0);
    sigpair_all.signature = kp.sign(challenge_all);

    assert(engine.execute(
        Lock(LockType.Script, [ubyte(32)] ~ kp.address[] ~ [ubyte(OP.CHECK_SIG)]),
        Unlock([ubyte(65)] ~ sigpair_all[]),
        tx_1,
        tx_1.inputs[0]) ==
        null);
    // SigHash.All cannot bind to a different Input
    assert(engine.execute(
        Lock(LockType.Script, [ubyte(32)] ~ kp.address[] ~ [ubyte(OP.VERIFY_SIG)]),
        Unlock([ubyte(65)] ~ sigpair_all[]),
        tx_2,
        tx_2.inputs[0]) ==
        "VERIFY_SIG signature failed validation");
}
