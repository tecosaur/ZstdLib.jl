# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

"""
    ZstdWriter(sink::Union{IO, AbstractBufWriter}; level=$DEFAULT_LEVEL, dictionary=nothing, checksum=false, threads=1, bufsize=$(IO_BUFFER_SIZE))
    ZstdWriter(f, sink; kwargs...)

Create an `AbstractBufWriter` that compresses what is written to it into a zstd
frame written to `sink`.

`flush` makes everything written so far decodable. `close` ends the frame and
closes `sink`. The second form calls `f` on the writer then closes it, unless
`f` throws, in which case the frame is left unfinished so that it doesn't pass
for complete. Likewise, if compressing or writing to `sink` fails, the writer
closes itself and `sink`, leaving the frame unfinished.

The keyword arguments are those of [`ZstdCompressor`](@ref), plus `bufsize`, the
size of the input buffer in bytes. With more than one thread, output is written
in chunks of a few megabytes, as compression of each completes.

Throws `ArgumentError` for invalid arguments, and `ZstdError` if libzstd fails.

# Examples

```jldoctest
julia> using ZstdLib

julia> path = tempname();

julia> ZstdWriter(open(path, "w"); level = 19) do writer
           write(writer, "Hello, world!")
       end
13

julia> String(decompress_zstd(read(path)))
"Hello, world!"
```
"""
mutable struct ZstdWriter{T<:AbstractBufWriter} <: AbstractBufWriter
    const sink::T
    const compressor::ZstdCompressor
    buffer::Memory{UInt8}
    filled::Int
end

function ZstdWriter(sink::AbstractBufWriter; bufsize::Integer = IO_BUFFER_SIZE, options...)
    bufsize ≥ 1 || throw(ArgumentError("bufsize must be positive"))
    ZstdWriter(sink, ZstdCompressor(; options...), Memory{UInt8}(undef, bufsize), 0)
end

ZstdWriter(io::IO; kwargs...) = ZstdWriter(BufWriter(io, IO_BUFFER_SIZE); kwargs...)

function ZstdWriter(f, sink::Union{IO, AbstractBufWriter}; kwargs...)
    writer = ZstdWriter(sink; kwargs...)
    result = try
        f(writer)
    catch
        release!(writer)
        rethrow()
    end
    close(writer)
    result
end

Base.show(io::IO, writer::ZstdWriter) = print(io, ZstdWriter, '(', writer.sink, ')')

BufferIO.get_buffer(writer::ZstdWriter) = MemoryView(writer.buffer)[writer.filled+1:end]

function BufferIO.consume(writer::ZstdWriter, n::Int)
    @boundscheck 0 ≤ n ≤ length(get_buffer(writer)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    writer.filled += n
    nothing
end

BufferIO.grow_buffer(writer::ZstdWriter) = shallow_flush(writer)

function BufferIO.shallow_flush(writer::ZstdWriter)
    isopen(writer) || throw(IOError(IOErrorKinds.ClosedIO))
    n = writer.filled
    encode!(writer, LibZstd.E_CONTINUE)
    n
end

function Base.flush(writer::ZstdWriter)
    isopen(writer) || throw(IOError(IOErrorKinds.ClosedIO))
    encode!(writer, LibZstd.E_FLUSH)
    flush(writer.sink)
end

Base.isopen(writer::ZstdWriter) = !isempty(writer.buffer)

function Base.close(writer::ZstdWriter)
    isopen(writer) || return nothing
    encode!(writer, LibZstd.E_END)
    release!(writer)
end

# After a failure the compressor's state is unknown, so release the writer, leaving the frame unfinished.
function encode!(writer::ZstdWriter, directive::Cint)
    (; sink, compressor) = writer
    input = ImmutableMemoryView(writer.buffer)[1:writer.filled]
    try
        while true
            output = get_nonempty_buffer(sink)
            isnothing(output) && throw(IOError(IOErrorKinds.WriterFull))
            used, made, ret = LibZstd.compressstream2!(compressor.cctx, input, output, directive)
            consume(sink, made)
            input = input[used+1:end]
            unflushed = check(:compress, ret)
            isempty(input) && (directive == LibZstd.E_CONTINUE || iszero(unflushed)) && break
        end
    catch
        release!(writer)
        rethrow()
    end
    writer.filled = 0
end

function release!(writer::ZstdWriter)
    isopen(writer) || return nothing
    finalize(writer.compressor)
    writer.buffer = Memory{UInt8}()
    writer.filled = 0
    close(writer.sink)
end
