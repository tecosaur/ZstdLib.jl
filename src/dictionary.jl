# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

const DICTIONARY_SIZE_MIN = 256        # ZDICT_DICTSIZE_MIN
const DEFAULT_DICTIONARY_SIZE = 112_640  # as `zstd --train`

"""
    ZstdDictionary(data::AbstractVector{UInt8})

The zstd dictionary held in `data`: either one made by [`train_dictionary`](@ref)
or `zstd --train`, or any other bytes, used as raw content.

A dictionary primes compression with what a kind of data has in common, which
makes small inputs, such as individual records, compress far better. Data
compressed with a dictionary need it again to decompress. Trained dictionaries
have an `id`, which frames compressed with them record so that a decompressor
given several can pick the right one. Raw content has the `id` `0`, as do the
frames compressed with it. The dictionary's bytes are its `data`.

Dictionaries may be shared between tasks. Each prepares itself once per
compression level, on first use. Save one with `write(io, dictionary)`.

Throws `ArgumentError` when `data` is empty, or begins like a trained
dictionary but is malformed.

# Examples

```jldoctest
julia> using ZstdLib

julia> samples = ["{\\"id\\": \$i, \\"name\\": \\"item \$i\\", \\"tags\\": [\\"a\\", \\"b\\"]}" for i in 1:1000];

julia> dictionary = train_dictionary(samples; size = 1024);

julia> ZstdDictionary(sprint(write, dictionary) |> codeunits) == dictionary
true
```
"""
mutable struct ZstdDictionary
    const data::Memory{UInt8}
    const id::UInt32
    const ddict::Ptr{Cvoid}
    const cdicts::Dict{Int, Ptr{Cvoid}}  # by compression level, made on first use
    const lock::ReentrantLock  # guards `cdicts`
end

function ZstdDictionary(data::AbstractVector{UInt8})
    isempty(data) && throw(ArgumentError("a dictionary cannot be empty"))
    memory = Memory{UInt8}(data)
    ddict = LibZstd.createddict(memory)
    if ddict == C_NULL
        istrained = length(memory) ≥ 8 && ntuple(i -> memory[i], 4) == LibZstd.DICT_MAGIC
        throw(if istrained
            ArgumentError("data begin like a trained zstd dictionary, but are malformed")
        else
            ZstdError(:decompress, :memory)
        end)
    end
    dictionary = ZstdDictionary(memory, LibZstd.dictid_fromdict(memory), ddict, Dict{Int, Ptr{Cvoid}}(), ReentrantLock())
    finalizer(dictionary) do dictionary
        foreach(LibZstd.freecdict, values(dictionary.cdicts))
        LibZstd.freeddict(dictionary.ddict)
    end
end

Base.:(==)(a::ZstdDictionary, b::ZstdDictionary) = a.data == b.data
Base.hash(dictionary::ZstdDictionary, h::UInt) = hash(dictionary.data, hash(ZstdDictionary, h))

Base.write(io::IO, dictionary::ZstdDictionary) = write(io, dictionary.data)

Base.show(io::IO, dictionary::ZstdDictionary) =
    print(io, ZstdDictionary, "(id=", dictionary.id, ", ", length(dictionary.data), " bytes)")

function compression_dictionary(dictionary::ZstdDictionary, level::Int)
    @lock dictionary.lock get!(dictionary.cdicts, level) do
        cdict = LibZstd.createcdict(dictionary.data, level)
        cdict == C_NULL && throw(ZstdError(:compress, :memory))
        cdict
    end
end

"""
    train_dictionary(samples; size=$DEFAULT_DICTIONARY_SIZE)::ZstdDictionary

Train a dictionary of at most `size` bytes on `samples`, a collection of byte
vectors or strings representative of the data to be compressed.

Training wants plenty of samples: around a hundred times `size` in total is a
good rule. A larger dictionary helps only when the samples have enough in
common to fill it, so compare a few sizes on held-out data.

Throws `ArgumentError` if `size` is under $DICTIONARY_SIZE_MIN bytes, and
`ZstdError` (code `:samples`) if the samples cannot train a dictionary.
"""
function train_dictionary(samples; size::Integer = DEFAULT_DICTIONARY_SIZE)
    size ≥ DICTIONARY_SIZE_MIN || throw(ArgumentError("dictionary size must be at least $DICTIONARY_SIZE_MIN bytes"))
    concatenated = UInt8[]
    sizes = Csize_t[]
    for sample in samples
        bytes = ImmutableMemoryView(sample)
        append!(concatenated, bytes)
        push!(sizes, length(bytes))
    end
    dictionary = Vector{UInt8}(undef, size)
    made = check(:train, LibZstd.trainfrombuffer!(dictionary, concatenated, sizes))
    ZstdDictionary(resize!(dictionary, made))
end

"""
    ZstdLib.dictionaryid(frame)::UInt32

The ID of the dictionary needed to decompress `frame`, the start of a zstd frame
as a byte vector, string, or memory view, or `0` if it names none (or is not zstd
data). Frames compressed with raw content, or by `zstd --no-dictID`, name none.
"""
dictionaryid(frame) = LibZstd.dictid_fromframe(ImmutableMemoryView(frame))
