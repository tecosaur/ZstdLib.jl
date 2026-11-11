# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
    ZstdLib

Zstandard compression and decompression on BufferIO, with dictionaries.

- [`compress_zstd`](@ref) and [`decompress_zstd`](@ref) work on whole buffers,
  reusing a [`ZstdCompressor`](@ref) or [`ZstdDecompressor`](@ref) across calls,
  and [`ZstdLib.framesize`](@ref) finds where a frame ends.
- [`ZstdWriter`](@ref) compresses a stream of data to zstd.
- [`ZstdReader`](@ref) decompresses a stream of zstd data.
- [`ZstdDictionary`](@ref) and [`train_dictionary`](@ref) make small data, such
  as records, compress well, and [`ZstdLib.dictionaryid`](@ref) tells which a frame needs.
- [`ZstdError`](@ref) reports libzstd failures.
"""
module ZstdLib

export ZstdCompressor, ZstdDecompressor, ZstdWriter, ZstdReader, ZstdDictionary, ZstdError,
    compress_zstd, compress_zstd!, decompress_zstd, decompress_zstd!, train_dictionary
public framesize, dictionaryid

using BufferIO: BufferIO, AbstractBufReader, AbstractBufWriter, BufReader, BufWriter,
    IOError, IOErrorKinds, consume, get_buffer, get_nonempty_buffer, shallow_flush
using MemoryViews: ImmutableMemoryView, MemoryView, MutableMemoryView

const IO_BUFFER_SIZE = 128 * 1024  # ZSTD_CStreamInSize, ZSTD_DStreamOutSize
const NO_BYTES = ImmutableMemoryView(Memory{UInt8}())

include("libzstd.jl")
include("error.jl")
include("dictionary.jl")
include("layout.jl")
include("frames.jl")
include("writer.jl")
include("reader.jl")

# Byte vectors and files are the common cases; other sources compile on first use.
precompile(compress_zstd, (Vector{UInt8},))
precompile(decompress_zstd, (Vector{UInt8},))
precompile(compress_zstd!, (Vector{UInt8}, ZstdCompressor, Vector{UInt8}))
precompile(decompress_zstd!, (Vector{UInt8}, ZstdDecompressor, Vector{UInt8}))
precompile(ZstdWriter, (IOStream,))
precompile(write, (ZstdWriter{BufWriter{IOStream}}, Vector{UInt8}))
precompile(close, (ZstdWriter{BufWriter{IOStream}},))
precompile(ZstdReader, (IOStream,))
precompile(BufferIO.fill_buffer, (ZstdReader{BufReader{IOStream}},))
precompile(read, (ZstdReader{BufReader{IOStream}},))
precompile(close, (ZstdReader{BufReader{IOStream}},))

end
