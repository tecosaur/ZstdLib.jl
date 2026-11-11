# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

const STATUS_CODES = Dict{Cint, Symbol}(
    LibZstd.ERROR_PREFIX_UNKNOWN => :format,
    LibZstd.ERROR_VERSION_UNSUPPORTED => :format,
    LibZstd.ERROR_FRAMEPARAMETER_UNSUPPORTED => :format,
    LibZstd.ERROR_CORRUPTION_DETECTED => :corrupt,
    LibZstd.ERROR_CHECKSUM_WRONG => :corrupt,
    LibZstd.ERROR_LITERALS_HEADER_WRONG => :corrupt,
    LibZstd.ERROR_DICTIONARY_CORRUPTED => :corrupt,
    LibZstd.ERROR_DSTSIZE_TOOSMALL => :corrupt,  # output room comes from the frame's own claim of its content size
    LibZstd.ERROR_SRCSIZE_WRONG => :truncated,
    LibZstd.ERROR_DICTIONARY_WRONG => :dictionary,
    LibZstd.ERROR_WINDOW_TOO_LARGE => :memlimit,
    LibZstd.ERROR_MEMORY_ALLOCATION => :memory)

const EXPLANATIONS = (
    format = ("the input is not zstd data", "check the input is positioned at the start of zstd data"),
    corrupt = ("the compressed data are corrupt", "verify the file with `zstd --test`"),
    truncated = ("the compressed data end early", "verify the file with `zstd --test`"),
    dictionary = ("the data need a dictionary that was not given", "pass the dictionary they were compressed with"),
    memlimit = ("decoding needs a larger window than `windowlog` allows", "raise `windowlog`"),
    memory = ("memory could not be allocated", "free some memory"),
    samples = ("the samples are too few or too small to train a dictionary of that size",
               "give more samples, or ask for a smaller dictionary"),
    internal = ("libzstd reported misuse, which is a bug in ZstdLib", "please report it"))

"""
    ZstdError <: Exception

Failure to `operation` zstd data (`:compress`, `:decompress`, or `:train` a
dictionary), because of `code`:

$(join(("- `:$code`: $reason" for (code, (reason, _)) in pairs(EXPLANATIONS)), '\n'))

Of these, `:format`, `:corrupt`, `:truncated`, and `:dictionary` mean the data
are at fault. For `:dictionary`, `dictionary` is the ID of the dictionary
needed, when known, and `0` otherwise.
"""
struct ZstdError <: Exception
    operation::Symbol
    code::Symbol
    dictionary::UInt32
end

ZstdError(operation::Symbol, code::Symbol) = ZstdError(operation, code, 0)

function ZstdError(operation::Symbol, ret::Csize_t)
    code = get(STATUS_CODES, LibZstd.errorcode(ret), :internal)
    ZstdError(operation, if operation === :train && code !== :memory; :samples else code end)
end

check(operation::Symbol, ret::Csize_t) = if LibZstd.iserror(ret) throw(ZstdError(operation, ret)) else Int(ret) end

function Base.showerror(io::IO, err::ZstdError)
    reason, remedy = EXPLANATIONS[err.code]
    print(io, "ZstdError: could not ", if err.operation === :train "train a dictionary" else err.operation end,
          ": ", reason)
    iszero(err.dictionary) || print(io, ", ID ", err.dictionary)
    print(io, " (", remedy, ")")
end
