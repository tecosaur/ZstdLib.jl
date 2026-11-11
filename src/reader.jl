# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# A frame's unverified claim of its content size is trusted as far as libzstd's default window limit
const READ_PRESIZE_MAX = 1 << 27

"""
    ZstdReader(source::Union{IO, AbstractBufReader}; dictionaries=(), windowlog=0, bufsize=$(IO_BUFFER_SIZE))
    ZstdReader(f, source; kwargs...)

Create an `AbstractBufReader` that decompresses the zstd data read from `source`.

`source` may hold several concatenated frames, which are read as one, with
skippable frames skipped and each frame decompressed with the dictionary it
names. It need not be seekable, so pipes and sockets work too. `close` closes
`source`. The second form calls `f` on the reader then closes it.

The keyword arguments are those of [`ZstdDecompressor`](@ref), plus `bufsize`,
the size of the output buffer in bytes.

Throws `ArgumentError` for invalid arguments, and `ZstdError` if the data are
corrupt or need a dictionary that was not given, after which reads throw the
same error.

# Examples

```jldoctest
julia> using ZstdLib

julia> reader = ZstdReader(IOBuffer(compress_zstd("Hello, world!")));

julia> read(reader, String)
"Hello, world!"
```
"""
mutable struct ZstdReader{T<:AbstractBufReader} <: AbstractBufReader
    const source::T
    const decompressor::ZstdDecompressor
    const buffer::Memory{UInt8}
    bytes::ImmutableMemoryView{UInt8}  # decoded, unread
    # A frame's opening bytes, read ahead to find its dictionary, and fed to the decoder first
    const header::Memory{UInt8}
    pending::ImmutableMemoryView{UInt8}
    atframestart::Bool
    position::Int
    error::Union{Nothing, Exception}
    isopen::Bool
end

function ZstdReader(source::AbstractBufReader; bufsize::Integer = IO_BUFFER_SIZE, options...)
    bufsize ≥ 1 || throw(ArgumentError("bufsize must be positive"))
    ZstdReader(source, ZstdDecompressor(; options...), Memory{UInt8}(undef, bufsize), NO_BYTES,
               Memory{UInt8}(undef, LibZstd.FRAME_HEADER_SIZE_MAX), NO_BYTES, true, 0, nothing, true)
end

ZstdReader(io::IO; kwargs...) = ZstdReader(BufReader(io, IO_BUFFER_SIZE); kwargs...)

function ZstdReader(f, source::Union{IO, AbstractBufReader}; kwargs...)
    reader = ZstdReader(source; kwargs...)
    try
        f(reader)
    finally
        close(reader)
    end
end

Base.show(io::IO, reader::ZstdReader) = print(io, ZstdReader, '(', reader.source, ')')

BufferIO.get_buffer(reader::ZstdReader) = reader.bytes

function BufferIO.consume(reader::ZstdReader, n::Int)
    @boundscheck 0 ≤ n ≤ length(reader.bytes) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    reader.bytes = @inbounds reader.bytes[n+1:end]
    reader.position += n
    nothing
end

Base.position(reader::ZstdReader) = reader.position

# Once the buffer is drained, a `dst` at least as large as it gains nothing from a refill,
# so is decoded into directly.
function BufferIO.read_into!(reader::ZstdReader, dst::MutableMemoryView{UInt8})
    isempty(dst) && return 0
    if isempty(reader.bytes) && length(dst) ≥ length(reader.buffer)
        made = decoding(reader -> decode!(reader, dst), reader)
        reader.position += made
        return made
    end
    BufferIO.fill_buffer(reader)
    n = min(length(dst), length(reader.bytes))
    copyto!(dst[1:n], reader.bytes[1:n])
    @inbounds consume(reader, n)
    n
end

function BufferIO.fill_buffer(reader::ZstdReader)
    isempty(reader.bytes) || return nothing
    made = decoding(reader -> decode!(reader, MemoryView(reader.buffer)), reader)
    reader.bytes = ImmutableMemoryView(reader.buffer)[1:made]
    made
end

# Makes room for each frame as it starts, by the size its header records, so that the
# result seldom grows part-way and never once the data end.
function Base.read(reader::ZstdReader)
    result, n = UInt8[], 0
    while true
        if reader.atframestart && isempty(reader.bytes)
            decoding(readheader!, reader) || break
            size = LibZstd.frame_contentsize(reader.pending)
            room = if size ≥ LibZstd.CONTENTSIZE_ERROR IO_BUFFER_SIZE else Int(min(size, READ_PRESIZE_MAX)) end
            # A byte over, as libzstd refuses to decode into no room, even a frame with no content
            length(result) ≤ n + room && resize!(result, n + room + 1)
        elseif n == length(result)
            resize!(result, max(2n, IO_BUFFER_SIZE))
        end
        made = BufferIO.read_into!(reader, MemoryView(result)[n+1:end])
        iszero(made) && break
        n += made
    end
    resize!(result, n)
end

Base.isopen(reader::ZstdReader) = reader.isopen

function Base.close(reader::ZstdReader)
    isopen(reader) || return nothing
    reader.bytes = NO_BYTES
    reader.isopen = false
    finalize(reader.decompressor)
    close(reader.source)
end

# Run `f(reader)`, keeping any error it throws for later reads.
function decoding(f, reader::ZstdReader)
    isopen(reader) || throw(IOError(IOErrorKinds.ClosedIO))
    isnothing(reader.error) || throw(reader.error)
    try
        f(reader)
    catch err
        reader.error = err
        rethrow()
    end
end

# Return the bytes decoded into `output`, or 0 at the end of the data.
function decode!(reader::ZstdReader, output::MutableMemoryView{UInt8})
    (; source, decompressor) = reader
    while true
        if reader.atframestart
            readheader!(reader) || return 0
            startframe!(decompressor, LibZstd.dictid_fromframe(reader.pending))
            reader.atframestart = false
        end
        frompending = !isempty(reader.pending)
        # Once the source is spent, libzstd may still hold decoded bytes that `output` lacked room for
        input = if frompending reader.pending else something(get_nonempty_buffer(source), NO_BYTES) end
        used, made, ret = LibZstd.decompressstream!(decompressor.dctx, input, output)
        if frompending
            reader.pending = reader.pending[used+1:end]
        else
            consume(source, used)
        end
        reader.atframestart = iszero(check(:decompress, ret))
        made > 0 && return made
        reader.atframestart || !isempty(input) || throw(ZstdError(:decompress, :truncated))
    end
end

# Read ahead the next frame's opening bytes, after any already pending, returning
# whether there is a next frame.
function readheader!(reader::ZstdReader)
    header = MemoryView(reader.header)
    filled = length(reader.pending)
    copyto!(header[1:filled], reader.pending)
    filled += BufferIO.read_all!(reader.source, header[filled+1:end])
    reader.pending = ImmutableMemoryView(header[1:filled])
    filled > 0
end
