/*******************************************************************************

    Types currently missing from `core.stdcpp` and some additional utilities

    Hopefully in the future we can reduce / remove this module.
    In the meantime, this is the most pragmatic way to do C++ bindings,
    as code in `core.stdcpp` needs to care about cross platform,
    cross compiler, cross C++ versions compatibility, but we have a much smaller
    target.

    The first step in reducing / removing this module would be to import
    exceptions / runtime binding for OSX to Druntime.

    See_Also:
      https://github.com/dlang-cpp-interop

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module scpd.Cpp;

import agora.crypto.Hash;
import agora.serialization.Serializer;

//import core.stdcpp.exception;
import core.stdcpp.string;
import core.stdcpp.xutility;
import std.meta;
import std.traits;

import vibe.data.json;

public enum CppCtor { Use = 0 }

public alias std_string = basic_string!char;

extern(C++) {
nothrow @nogc:
    void defaultCtorCPPObject(T) (T* ptr);
    void dtorCPPObject(T) (T* ptr);
    void opAssignCPPObject(T) (T* lhs, T* rhs);
    void copyCtorCPPObject(T) (T* ptr, inout(T)* rhs);
    void copyCtorCPPObject(T) (immutable(T)* ptr, inout(T)* rhs);
    int getCPPSizeof(T) () @safe;
    std_string sliceToStdString (const(char)* ptr, size_t length);
}

private mixin template CPPBindingMixin (T, bool Copyable = true, bool DefaultConstructable = false)
{
    extern(D)
    {
        static if (!DefaultConstructable) @disable this();
        this (CppCtor use) @trusted nothrow @nogc
        {
            defaultCtorCPPObject!T(&this);
        }

        ~this () @trusted nothrow @nogc
        {
            dtorCPPObject!T(&this);
        }

        static if (Copyable)
        this (ref return scope inout T rhs) @trusted nothrow @nogc
        {
            copyCtorCPPObject!T(&this, &rhs);
        }

        static if (Copyable)
        this (ref return scope inout T rhs) immutable @trusted nothrow @nogc
        {
            copyCtorCPPObject!T(&this, &rhs);
        }

        static if (Copyable)
        void opAssign()(auto ref T rhs) @trusted nothrow @nogc
        {
            opAssignCPPObject!T(&this, &rhs);
        }
    }
}

/// Can't import `core.stdcpp.allocator` because it transitively imports
/// `core.stdcpp.exception`
/// In this case we just need to get the name right for `vector`

extern(C++, (StdNamespace)) extern(C++, class) struct allocator (T) {}

extern(C++, (StdNamespace)) extern(C++, class) struct less (T) {}

extern(C++, `stellar`) extern(C++, class) struct RandHasher (T, Hasher = hash!T) { }

extern(C++, (StdNamespace)) extern(C++, class) struct default_delete (T) {}

// simplistic std::pair bindings
public extern(C++, (StdNamespace)) struct pair (T1, T2)
{
    T1 first;
    T2 second;
}

// fake std::hash (for mangling)
public extern(C++, (StdNamespace))  struct hash (T) {}

// fake std::equal_to (for mangling)
public extern(C++, (StdNamespace))  struct equal_to (T = void) {}

extern(C++, (StdNamespace)) {
    /// Simple binding to `std::shared_ptr`
    extern(C++, class) struct shared_ptr (T)
    {
        static if (is(T == class) || is(T == interface))
            private alias TPtr = T;
        else
            private alias TPtr = T*;

        mixin CPPBindingMixin!(shared_ptr!T);

        TPtr ptr;
        void* _control_block;
        alias ptr this;
    }

    /// Simple binding to `std::unique_ptr`
    extern(C++, class) struct unique_ptr (T, Deleter = default_delete!T)
    {
        static if (is(T == class) || is(T == interface))
            private alias TPtr = T;
        else
            private alias TPtr = T*;

        mixin CPPBindingMixin!(unique_ptr, false);

        TPtr ptr;
        alias ptr this;
    }
}

/// C++ support for foreach
extern(C++) private int cpp_set_foreach(T)(void* set, void* ctx, void* cb);

/// std::set.empty() support
nothrow pure @nogc extern(C++) private bool cpp_set_empty(T)(const(void)* set);

/// unordered map assignment support
private nothrow @nogc extern(C++) void cpp_unordered_map_assign (K, V)(
    void* map, ref const(K) key, ref const(V) value);

/// unordered map length support
private pure nothrow @nogc @safe extern(C++) size_t cpp_unordered_map_length (K, V)(
    const(void)* map);

/// Rudimentary bindings for std::unordered_map
extern(C++, (StdNamespace))
public struct unordered_map (Key, T, Hash = RandHasher!(Key), KeyEqual = equal_to!Key, Allocator = allocator!(pair!(const Key, T)))
{
    version (CppRuntime_Clang)
        private ulong[40 / ulong.sizeof] _data;
    else
        private ulong[56 / ulong.sizeof] _data;

    mixin CPPBindingMixin!unordered_map;

    void opIndexAssign (in T value, in Key key) @trusted @nogc nothrow
    {
        cpp_unordered_map_assign!(Key, T)(&this, key, value);
    }

    size_t length () pure nothrow @safe @nogc
    {
        return cpp_unordered_map_length!(Key, T)(&this);
    }
}

unittest
{
    auto map = unordered_map!(int, int)(CppCtor.Use);
    assert(map.length() == 0);
    map[1] = 1;
    assert(map.length() == 1);
    auto copy = map;
    assert(copy.length() == map.length());

    auto copy2 = unordered_map!(int, int)(CppCtor.Use);
    copy2 = copy;
    assert(copy2.length() == map.length());
}

extern(C++, `std`) {
    class runtime_error : exception { }
    class logic_error : exception { }

    /// TODO: Move to druntime
    class exception
    {
        this() nothrow {}
        const(char)* what() const nothrow;
    }
}

extern(C++, (StdNamespace)) {
    /// Binding: Needs to be instantiated on C++ side
    shared_ptr!T make_shared(T, Args...)(Args args);

    /// Fake bindings for std::set
    public extern(C++, class) struct set (Key, Compare = less!Key, Allocator = allocator!Key)
    {
        version (CppRuntime_Clang)
            private ulong[24 / ulong.sizeof] _data;
        else
            private ulong[48 / ulong.sizeof] _data;

        mixin CPPBindingMixin!set;

        /// Foreach support
        extern(D) public int opApply (scope int delegate(ref const(Key)) dg) const
        {
            extern(C++) static int wrapper (void* context, ref const(Key) value)
            {
                auto dg = *cast(typeof(dg)*)context;
                return dg(value);
            }

            return cpp_set_foreach!Key(cast(void*)&this, cast(void*)&dg,
                cast(void*)&wrapper);
        }

        /// Returns: true if the set is empty
        extern(D) bool empty () const nothrow pure @nogc
        {
            return cpp_set_empty!Key(cast(const void*)&this);
        }
    }

    /// Fake bindings for std::map
    public extern(C++, class) struct map (Key, Value, Compare = less!Key, Allocator = allocator!(pair!(const Key, Value)))
    {
        version (CppRuntime_Clang)
            private ulong[24 / ulong.sizeof] _data;
        else
            private ulong[48 / ulong.sizeof] _data;

        mixin CPPBindingMixin!map;
    }

    // only used at compile-time on the C++ side, here for mangling
    extern(C++, class) struct ratio (int _Num, int _Den = 1)
    {
    }

    /// Simple bindings to std::chrono
    extern(C++, `chrono`)
    {
        public extern(C++, class) struct duration (_Rep, _Period = ratio!1)
        {
            _Rep __r;
            alias __r this;
        }

        alias milli = ratio!(1, 1000);
        alias milliseconds = duration!(long, milli);
    }

    /// Simple wrapper around std::function
    /// note: pragma(mangle) doesn't currently work on types
    align(1) public struct CPPDelegate (Callback)
    {
    align(1):
        shared_ptr!int __ptr_;
        ubyte[24] _1;
        ubyte[24] _2;
    }

    static assert(CPPDelegate!SCPCallback.sizeof == 64);
}

/// Type of SCP function callback called by a timer
public alias SCPCallback = extern(C++) void function();

// TODO : MSVC mangling issue w.r.t. the return type
version (Posix)
{
    private extern(C++) set!uint* makeTestSet();

    unittest
    {
        auto set = makeTestSet;
        assert(!set.empty);
        uint[] values;
        foreach (val; *set)
            values ~= val;
        assert(values == [1, 2, 3, 4, 5]);
    }
}

/*******************************************************************************

    Simple bindings from `std::vector`

    Note that this binding is incomplete and possibly incorrect.
    There is a druntime version but it's likely buggy and much harder to
    reason about because it supports all runtimes:
    https://github.com/dlang/druntime/pull/2448

    It's very easy to get the memory management wrong, so prefer passing this
    by ref and do anything that modifies the memory on the C++ side
    (e.g. push_back).

    Extra items, like `ConstIterator` and `toString` / `fromString` are for
    ease of use (e.g. `to/fromString` actually allows vibe.d to deserialize it)

*******************************************************************************/

extern(C++, (StdNamespace)) extern(C++, class) struct vector (T, Alloc = allocator!T)
{
    T* _start;
    T* _end;
    T* _end_of_storage;

    alias ElementType = T;

    extern(D)
    {
        /// TODO: Separate from `vector` definition
        private static struct ConstIterator
        {
            size_t index;
            const(vector!T)* orig;

            public ref const(T) front () const pure nothrow @nogc @trusted
            {
                return (*this.orig)[this.index];
            }
            public void popFront () pure nothrow @nogc @trusted
            {
                if (!this.empty)
                    this.index++;
            }
            public @property bool empty () const pure nothrow @safe @nogc
            {
                return !(this.index < this.orig.length);
            }
        }

        public ref inout(T) opIndex(size_t idx) inout pure nothrow @nogc @trusted
        {
            if (idx >= this.length)
                assert(0);
            return this._start[idx];
        }

        public size_t length () const pure nothrow @nogc @safe
        {
            return this._end - this._start;
        }

        public ConstIterator constIterator () const pure nothrow @nogc @safe
        {
            return ConstIterator(0, &this);
        }

        public inout(T[]) opSlice () inout pure nothrow @nogc @safe
        {
            return this.opSlice(0, this.length());
        }

        public inout(T[]) opSlice (size_t start, size_t end) inout pure nothrow @nogc @trusted
        {
            if (end > this.length())
                assert(0);
            return this._start[start .. end];
        }

        public bool opEquals (in vector rhs) const pure nothrow @nogc @safe
        {
            static assert(__traits(isRef, rhs));

            import std.range : zip;
            if (this.length != rhs.length)
                return false;

            // note: cannot do 'return this.innerSets[] == rhs.innerSets[];'
            // object.d(358,64): Error: `cast(const(vector))(cast(const(vector)*)r)[i]`
            // is not an lvalue and cannot be modified
            foreach (const ref left, const ref right; zip(this[], rhs[]))
            {
                if (left != right)
                    return false;
            }

            return true;
        }

        alias opDollar = length;

        static if (is(T : ubyte))
        {
            import vibe.data.serialization : Base64ArrayPolicy;
            package alias SerPolicy = Base64ArrayPolicy;
        }
        else
        {
            package alias SerPolicy = DefaultPolicy;
        }

        string toString() const @trusted
        {
            import std.array : appender, Appender;

            auto app = appender!string();
            serializeWithPolicy!(JsonStringSerializer!(Appender!string), SerPolicy)(this[], app);
            return app.data;
        }

        static typeof(this) fromString(string src) @safe
        {
            auto array = src.deserializeWithPolicy!(JsonStringSerializer!string, SerPolicy, T[]);
            typeof(this) vec;
            foreach (ref item; array)
                vec.push_back(item);
            return vec;
        }

        void computeHash (scope HashDg dg) const nothrow @safe @nogc
        {
            hashPart(this.opSlice(), dg);
        }

        public void serialize (scope SerializeDg dg) const @safe
        {
            serializePart(this.length, dg);
            foreach (ref entry; this.constIterator())
                serializePart(entry, dg);
        }

        static QT fromBinary (QT) (scope DeserializeDg data,
            in DeserializerOptions opts) @safe
        {
            import scpd.types.Utils;

            // Note: Unqual necessary because we can't construct an
            // `immutable` vector yet
            Unqual!(vector!(Unqual!(QT.ElementType))) ret;
            immutable len = deserializeLength(data, opts.maxLength);
            foreach (idx; 0 .. len)
            {
                auto entry = deserializeFull!(QT.ElementType)(data, opts);
                ret.push_back(entry);
            }
            return () @trusted { return cast(QT) ret; }();
        }

        static if (isBasicType!T)
        {
            /// Overload for basic types to not require a `const ref`
            public void push_back (T value) @trusted pure nothrow @nogc
            {
                import Utils = scpd.types.Utils;
                Utils.push_back(this, value);
            }
        }

        public void push_back (ref T value) @trusted pure nothrow @nogc
        {
            import Utils = scpd.types.Utils;
            import scpd.types.XDRBase;

            // Workaround for Dlang issue #20805
            static if (is(T == xvector!ubyte))
            {
                version (Windows)
                    Utils.push_back_vec(&this, &value);
                else
                    Utils.push_back(this, value);
            }
            else
            {
                Utils.push_back(this, value);
            }
        }
    }
}

unittest
{
    import std.algorithm : each;
    import std.conv : to;
    import std.range : iota;

    vector!ubyte vec_ubyte;
    iota(5).each!((num) {ubyte b = cast(ubyte)num; vec_ubyte.push_back(b);});
    auto serialized = vec_ubyte.toString();
    assert(serialized == `"AAECAwQ="`, "actual serialized: " ~ serialized);
    auto deserialized = vec_ubyte.fromString(serialized)[];
    assert(deserialized == [0, 1, 2, 3, 4], "actual deserialized: " ~ to!string(deserialized));
}

unittest
{
    import scpd.types.Utils;
    vector!ubyte vec;
    assert(vec.length == 0);
    assert(vec[] == []);

    ubyte x = 1;
    vec.push_back(x);
    x = 2;
    vec.push_back(x);
    x = 3;
    vec.push_back(x);
    assert(vec.length == 3);
    assert(vec[] == [1, 2, 3]);
    assert(vec[0 .. $] == [1, 2, 3]);
    assert(vec[0..2] == [1, 2]);
    assert(vec[1..3] == [2, 3]);

    vector!ubyte vec2;
    assert(vec2 != vec);

    x = 1;
    vec2.push_back(x);
    x = 2;
    vec2.push_back(x);
    x = 3;
    vec2.push_back(x);
    assert(vec2 == vec);

    vector!ubyte vec3;
    vec3.push_back(x);
    x = 2;
    vec3.push_back(x);
    x = 3;
    vec3.push_back(x);
    assert(vec3 != vec);
}

unittest
{
    checkFromBinary!(vector!ubyte);
}

/// Invoke an std::function pointer (note: must be void* due to mangling issues)
extern(C++) void callCPPDelegate (void* cb);

public mixin template NonMovableOrCopyable ()
{
    @disable this ();
    @disable this (this);
    @disable ref typeof (this) opAssign () (auto ref typeof(this) rhs);
}

unittest
{
    assert(unordered_map!(int,int).sizeof == getCPPSizeof!(unordered_map!(int,int))());
    assert(shared_ptr!int.sizeof == getCPPSizeof!(shared_ptr!int)());
    assert(set!int.sizeof == getCPPSizeof!(set!int)());
    assert(map!(int,int).sizeof == getCPPSizeof!(map!(int,int))());
}
