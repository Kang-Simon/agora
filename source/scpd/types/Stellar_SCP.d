/*******************************************************************************

    Porting of Stellar's `Stellar_SCP.h`, itself derived from `Stellar_SCP.x`

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module scpd.types.Stellar_SCP;

import vibe.data.json;

import agora.common.Ensure;
import agora.crypto.Hash;
import agora.serialization.Serializer;

import scpd.Cpp;
import scpd.types.Stellar_types;
import scpd.types.XDRBase;

import core.stdc.config;
import core.stdc.inttypes;

extern(C++, `stellar`):

alias Value = opaque_vec!();

static assert(Value.sizeof == 24);

struct SCPBallot {
  uint32_t counter;
  Value value;
}

static assert(SCPBallot.sizeof == 32);

enum SCPStatementType : int32_t {
  SCP_ST_PREPARE = 0,
  SCP_ST_CONFIRM = 1,
  SCP_ST_EXTERNALIZE = 2,
  SCP_ST_NOMINATE = 3,
}

struct SCPNomination {
    xvector!(Value) votes;
    xvector!(Value) accepted;
}

static assert(SCPNomination.sizeof == 48);

struct SCPStatement {

    /***************************************************************************

        Note: XDRPP defines a lot of boilerplate accessors to ensure those
        tagged unions are properly accessed from code.
        We don't, and instead we just bind the size, hoping for the best.

    ***************************************************************************/

    static struct _pledges_t {
        static struct _prepare_t {
            SCPBallot ballot;
            pointer!(SCPBallot) prepared;
            pointer!(SCPBallot) preparedPrime;
            uint32_t nC;
            uint32_t nH;
        }

        static assert(_prepare_t.sizeof == 56);

        static struct _confirm_t {
            SCPBallot ballot;
            uint256 value_sig;  // used for Scalar of Signature for this ballot
            uint32_t nPrepared;
            uint32_t nCommit;
            uint32_t nH;
        }

        static assert(_confirm_t.sizeof == 80);

        static struct _externalize_t {
            SCPBallot commit;
            uint32_t nH;
        }

        static assert(_externalize_t.sizeof == 40);

        //using _xdr_case_type = xdr::xdr_traits<SCPStatementType>::case_type;
        //private:
        //_xdr_case_type type_;
        SCPStatementType type_;
        union {
            _prepare_t prepare_;
            _confirm_t confirm_;
            _externalize_t externalize_;
            SCPNomination nominate_;
        }

        /// Call `func` with one of the message types depending on the `type_`.
        /// Whether or not this call is @safe depends on the @safety of `func`
        extern(D) auto apply (alias func, T...)(auto ref T args) const
        {
            final switch (this.type_)
            {
                case SCPStatementType.SCP_ST_PREPARE:
                    auto value = () @trusted { return this.prepare_; }();
                    return func(value, args);

                case SCPStatementType.SCP_ST_CONFIRM:
                    auto value = () @trusted { return this.confirm_; }();
                    return func(value, args);

                case SCPStatementType.SCP_ST_EXTERNALIZE:
                    auto value = () @trusted { return this.externalize_; }();
                    return func(value, args);

                case SCPStatementType.SCP_ST_NOMINATE:
                    auto value = () @trusted { return this.nominate_; }();
                    return func(value, args);
            }
        }

        /// Support (de)serialization from Vibe.d
        extern(D) string toString () const @trusted
        {
            Json json = Json.emptyObject;
            final switch (this.type_)
            {
            case SCPStatementType.SCP_ST_PREPARE:
                json["prepare"] = serializeToJson(this.prepare_);
                break;
            case SCPStatementType.SCP_ST_CONFIRM:
                json["confirm"] = serializeToJson(this.confirm_);
                break;
            case SCPStatementType.SCP_ST_EXTERNALIZE:
                json["externalize"] = serializeToJson(this.externalize_);
                break;
            case SCPStatementType.SCP_ST_NOMINATE:
                json["nominate"] = serializeToJson(this.nominate_);
                break;
            }
            return json.toString();
        }

        /// Ditto
        extern(D) static _pledges_t fromString (const(char)[] input) @trusted
        {
            _pledges_t ret;
            // Need the case because `parseJsonString` expects a string,
            // but doesn't escape things past the `Json` object it returns
            auto json = parseJsonString(cast(string) input).get!(Json[string]);
            if (auto obj = "prepare" in json)
            {
                ret.type_ = SCPStatementType.SCP_ST_PREPARE;
                ret.prepare_ = (*obj).deserializeJson!_prepare_t();
            }
            else if (auto obj = "confirm" in json)
            {
                ret.type_ = SCPStatementType.SCP_ST_CONFIRM;
                ret.confirm_ = (*obj).deserializeJson!_confirm_t();
            }
            else if (auto obj = "externalize" in json)
            {
                ret.type_ = SCPStatementType.SCP_ST_EXTERNALIZE;
                ret.externalize_ = (*obj).deserializeJson!_externalize_t();
            }
            else if (auto obj = "nominate" in json)
            {
                ret.type_ = SCPStatementType.SCP_ST_NOMINATE;
                ret.nominate_ = (*obj).deserializeJson!SCPNomination();
            }
            else
                ensure(false, "Unrecognized envelope type");
            return ret;
        }

        extern(D)
        {
            /// Hashing support
            public void computeHash (scope HashDg dg) const scope
                @trusted pure @nogc nothrow
            {
                hashPart(this.type_, dg);
                switch (this.type_)
                {
                case SCPStatementType.SCP_ST_PREPARE:
                    return hashPart(this.prepare_, dg);
                case SCPStatementType.SCP_ST_CONFIRM:
                    return hashPart(this.confirm_, dg);
                case SCPStatementType.SCP_ST_EXTERNALIZE:
                    return hashPart(this.externalize_, dg);
                case SCPStatementType.SCP_ST_NOMINATE:
                    return hashPart(this.nominate_, dg);
                default:
                    assert(0);
                }
            }
        }

        ///
        extern(D) void serialize (scope SerializeDg dg) const @trusted
        {
            serializePart(this.type_, dg);
            switch (this.type_)
            {
            case SCPStatementType.SCP_ST_PREPARE:
                return serializePart(this.prepare_, dg);
            case SCPStatementType.SCP_ST_CONFIRM:
                return serializePart(this.confirm_, dg);
            case SCPStatementType.SCP_ST_EXTERNALIZE:
                return serializePart(this.externalize_, dg);
            case SCPStatementType.SCP_ST_NOMINATE:
                return serializePart(this.nominate_, dg);
            default:
                assert(0);
            }
        }

        ///
        extern(D) public static QT fromBinary (QT) (scope DeserializeDg dg,
            in DeserializerOptions opts) @safe
        {
            auto type = deserializeFull!(typeof(QT.type_))(dg, opts);
            final switch (type)
            {
            case SCPStatementType.SCP_ST_PREPARE:
                return enableNRVO!(QT, SCPStatementType.SCP_ST_PREPARE)(dg, opts);
            case SCPStatementType.SCP_ST_CONFIRM:
                return enableNRVO!(QT, SCPStatementType.SCP_ST_CONFIRM)(dg, opts);
            case SCPStatementType.SCP_ST_EXTERNALIZE:
                return enableNRVO!(QT, SCPStatementType.SCP_ST_EXTERNALIZE)(dg, opts);
            case SCPStatementType.SCP_ST_NOMINATE:
                return enableNRVO!(QT, SCPStatementType.SCP_ST_NOMINATE)(dg, opts);
            }
        }

        /***********************************************************************

            Allow `fromBinary` to do NRVO

            We need to initialize using a literal to account for type
            constructors, but we can't initialize the `union` in a generic way
            (because we need to use a different name based on the `type`).
            The normal solution is to put it in a `switch`, but since we
            declare multiple variable (one per `switch` branch),
            NRVO is disabled.
            The solution is to use `static if` to ensure the compiler only sees
            one temporary and does NRVO on this function, which in turn enables
            NRVO on the caller.

            See_Also:
              https://forum.dlang.org/thread/miuevyfxbujwrhghmiuw@forum.dlang.org

        ***********************************************************************/

        extern(D) private static QT enableNRVO (QT, SCPStatementType type) (
            scope DeserializeDg dg, in DeserializerOptions opts) @safe
        {
            static if (type == SCPStatementType.SCP_ST_PREPARE)
            {
                QT ret = {
                    type_: type,
                    prepare_: deserializeFull!(typeof(QT.prepare_))(dg, opts)
                };
                return ret;
            }
            else static if (type == SCPStatementType.SCP_ST_CONFIRM)
            {
                QT ret = {
                    type_: type,
                    confirm_: deserializeFull!(typeof(QT.confirm_))(dg, opts)
                };
                return ret;
            }
            else static if (type == SCPStatementType.SCP_ST_EXTERNALIZE)
            {
                QT ret = {
                    type_: type,
                    externalize_: deserializeFull!(typeof(QT.externalize_))(dg, opts)
                };
                return ret;
            }
            else static if (type == SCPStatementType.SCP_ST_NOMINATE)
            {
                QT ret = {
                    type_: type,
                    nominate_: deserializeFull!(typeof(QT.nominate_))(dg, opts)
                };
                return ret;
            }
            else
                static assert(0, "Unsupported statement type: " ~ type.stringof);
        }
    }

    NodeID nodeID;
    uint64_t slotIndex;
    _pledges_t pledges;
}

static assert(SCPStatement.sizeof == 104);
static assert(Signature.sizeof == 64);

struct SCPEnvelope {
  SCPStatement statement;
  Signature signature;
}

static assert(SCPEnvelope.sizeof == 168);

struct SCPQuorumSet {
    uint32_t threshold;
    xvector!(NodeID) validators;
    xvector!(SCPQuorumSet) innerSets;

    /// Hashing support
    extern(D) public void computeHash (scope HashDg dg) const scope
        @safe pure nothrow @nogc
    {
        hashPart(this.threshold, dg);

        foreach (const ref node; this.validators[])
            hashPart(node, dg);

        foreach (const ref quorum; this.innerSets[])
            hashPart(quorum, dg);
    }
}

@safe unittest
{
    import agora.common.Types;
    import agora.crypto.Key;
    import agora.consensus.protocol.Config;
    import std.conv;

    const qc1 = toSCPQuorumSet(QuorumConfig(2, [0, 1]));

    assert(qc1.hashFull() == Hash.fromString(
        "0x57744ff3b19f006505cb69a617f99314119dbfa7bff94eb59b058b7088076ae8f4631085db5dca56c0b97d208e8276801a7602453f0fa57ec0ce2dfe25669db2"));

    const qc2 = toSCPQuorumSet(QuorumConfig(3, [0, 1]));

    assert(qc2.hashFull() == Hash.fromString(
        "0xdccacd796d28677dd3690c5dea888262c40c8d904e452eed3d56f99154fd209303ed4a270a81a51ed4224375889d86d1a441c914a2ec5ece78313a12a60aca72"));

    const qc3 = toSCPQuorumSet(QuorumConfig(2, [0, 1],
             [QuorumConfig(2, [0, 1])]));

    assert(qc3.hashFull() == Hash.fromString(
        "0xac26280aaea44f23c11fb6dc14eda3c83e5642288049244edb9bb0331a99f7e5f5e614e07e6d5b1009cc80e7895181f1eb0f0ad299cbb5fffe2d7994e970f6ee"));

    const qc4 = toSCPQuorumSet(QuorumConfig(2, [0, 1],
             [QuorumConfig(3, [0, 1])]));

    assert(qc4.hashFull() == Hash.fromString(
        "0xeaafeb7634d31143b235b8d1e45d57deda854d3a8cca6af0e78379d5cdb2e547e15e67d8d2da01510f4de45b7d650b418da4051d34ca1d2760a7be2772ac66d0"));
}
static assert(SCPQuorumSet.sizeof == 56);

/// From SCPDriver, here for convenience
public alias SCPQuorumSetPtr = shared_ptr!SCPQuorumSet;
