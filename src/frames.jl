# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

const DEFAULT_LEVEL = 3
const MAX_BOUND_EXPANSION = 32  # a bound on unrecorded content is allocated on trust up to this many times the frame

"""
    ZstdCompressor(; level=$DEFAULT_LEVEL, dictionary=nothing, checksum=false, threads=1)

Reusable state for compressing many inputs into zstd frames with
[`compress_zstd`](@ref) or [`compress_zstd!`](@ref), which avoids setting up
libzstd afresh for each. [`ZstdWriter`](@ref) takes the same keyword arguments.

A compressor is not safe to use from several tasks at once: give each task its
own. They can share a dictionary.

# Arguments

- `level`: compression level, from $(LibZstd.minlevel()) (fastest) to $(LibZstd.maxlevel())
  (smallest), where levels above 19 need much more memory to decompress and `0` means $DEFAULT_LEVEL
- `dictionary`: a [`ZstdDictionary`](@ref) to compress with, which decompression will then need.
  Each input refers to the dictionary in place rather than copying it, so a large
  dictionary costs nothing per input.
- `checksum`: whether frames end with a checksum of their content, verified when decompressed
- `threads`: number of compression threads, or `0` for one per Julia thread, which
  helps only with inputs of several megabytes or more

Throws `ArgumentError` for invalid arguments.
"""
mutable struct ZstdCompressor
    const cctx::Ptr{Cvoid}  # freed by the finalizer, which owners `finalize` early as the GC cannot see its size
    const level::Int
    const dictionary::Union{Nothing, ZstdDictionary}
end

function ZstdCompressor(; level::Integer = DEFAULT_LEVEL, dictionary::Union{Nothing, ZstdDictionary} = nothing,
                        checksum::Bool = false, threads::Integer = 1)
    LibZstd.minlevel() ≤ level ≤ LibZstd.maxlevel() ||
        throw(ArgumentError("compression level must be within $(LibZstd.minlevel())..$(LibZstd.maxlevel())"))
    workers = workercount(threads)
    cctx = LibZstd.createcctx()
    cctx == C_NULL && throw(ZstdError(:compress, :memory))
    compressor = finalizer(compressor -> LibZstd.freecctx(compressor.cctx), ZstdCompressor(cctx, level, dictionary))
    check(:compress, LibZstd.cctx_setparameter(cctx, LibZstd.C_COMPRESSION_LEVEL, level))
    check(:compress, LibZstd.cctx_setparameter(cctx, LibZstd.C_CHECKSUM_FLAG, checksum))
    check(:compress, LibZstd.cctx_setparameter(cctx, LibZstd.C_NB_WORKERS, workers))
    if !isnothing(dictionary)
        check(:compress, LibZstd.cctx_refcdict(cctx, compression_dictionary(dictionary, compressor.level)))
        check(:compress, LibZstd.cctx_setparameter(cctx, LibZstd.C_FORCE_ATTACH_DICT, LibZstd.DICT_FORCE_ATTACH))
    end
    compressor
end

# The libzstd workers that compress on `threads` threads (0 for one per Julia thread). With no
# workers, libzstd compresses on the calling thread, and builds without threading allow none.
function workercount(threads::Integer)
    threadlimit = max(LibZstd.cparam_bounds(LibZstd.C_NB_WORKERS).upper, 1)
    count = if iszero(threads) min(Threads.nthreads(), threadlimit) else threads end
    1 ≤ count ≤ threadlimit ||
        throw(ArgumentError("threads must be within 0..$threadlimit, with 0 picking one per Julia thread"))
    if count == 1 0 else count end
end

Base.show(io::IO, compressor::ZstdCompressor) =
    print(io, ZstdCompressor, "(level=", compressor.level,
          if isnothing(compressor.dictionary) "" else ", dictionary=$(compressor.dictionary.id)" end, ")")

"""
    compress_zstd(data; kwargs...)::Vector{UInt8}
    compress_zstd(compressor::ZstdCompressor, data)::Vector{UInt8}

Compress `data`, a byte vector, string, or memory view, into a single zstd
frame. The keyword arguments are those of [`ZstdCompressor`](@ref).

The frame records the size of its content, so decompressing it needs no guesswork.

# Examples

```jldoctest
julia> using ZstdLib

julia> compressed = compress_zstd("Hello, world!");

julia> String(decompress_zstd(compressed))
"Hello, world!"
```
"""
function compress_zstd(data; kwargs...)
    compressor = ZstdCompressor(; kwargs...)
    try
        compress_zstd(compressor, data)
    finally
        finalize(compressor)
    end
end

compress_zstd(compressor::ZstdCompressor, data) = compress_zstd!(UInt8[], compressor, data)

"""
    compress_zstd!(output::Vector{UInt8}, compressor::ZstdCompressor, data) -> output

Compress `data` into a single zstd frame, replacing the contents of `output`,
which is reused to avoid allocating anew for each of many inputs.
"""
function compress_zstd!(output::Vector{UInt8}, compressor::ZstdCompressor, data)
    input = ImmutableMemoryView(data)
    resize!(output, LibZstd.compressbound(length(input)))
    made = check(:compress, LibZstd.compress2!(compressor.cctx, MemoryView(output), input))
    resize!(output, made)
end

"""
    ZstdDecompressor(; dictionaries=(), windowlog=0)

Reusable state for decompressing many inputs with [`decompress_zstd`](@ref) or
[`decompress_zstd!`](@ref), which avoids setting up libzstd afresh for each.
[`ZstdReader`](@ref) takes the same keyword arguments.

A decompressor is not safe to use from several tasks at once: give each task
its own. They can share dictionaries.

# Arguments

- `dictionaries`: the [`ZstdDictionary`](@ref)s that frames may need. Each frame
  is decompressed with the dictionary it names. A frame naming none, as those
  compressed with raw content or by `zstd --no-dictID` do, uses the raw content
  among `dictionaries`, or else the only dictionary given, like `zstd -D`.
- `windowlog`: the base-2 logarithm of the largest window streaming decompression
  may use, bounding its memory, or `0` for libzstd's default of 27 (128 MiB).
  Frames compressed with long-distance matching may need more. Frames recording
  their content size are decompressed straight into the output, so need no window.

Throws `ArgumentError` for invalid arguments.
"""
mutable struct ZstdDecompressor
    const dctx::Ptr{Cvoid}  # freed as `ZstdCompressor.cctx` is
    const dictionaries::Dict{UInt32, ZstdDictionary}
    frameid::Union{Nothing, UInt32}  # the ID named by the last frame, whose dictionary `dctx` still references
end

function ZstdDecompressor(; dictionaries = (), windowlog::Integer = 0)
    (; lower, upper) = LibZstd.dparam_bounds(LibZstd.D_WINDOW_LOG_MAX)
    iszero(windowlog) || lower ≤ windowlog ≤ upper ||
        throw(ArgumentError("windowlog must be within $lower..$upper, or 0 for the default"))
    byid = Dict{UInt32, ZstdDictionary}()
    for dictionary::ZstdDictionary in dictionaries
        haskey(byid, dictionary.id) &&
            throw(ArgumentError("dictionaries must have distinct IDs, but two have ID $(dictionary.id)"))
        byid[dictionary.id] = dictionary
    end
    length(byid) == 1 && (byid[0] = only(values(byid)))
    dctx = LibZstd.createdctx()
    dctx == C_NULL && throw(ZstdError(:decompress, :memory))
    decompressor = finalizer(decompressor -> LibZstd.freedctx(decompressor.dctx), ZstdDecompressor(dctx, byid, nothing))
    iszero(windowlog) || check(:decompress, LibZstd.dctx_setparameter(dctx, LibZstd.D_WINDOW_LOG_MAX, windowlog))
    decompressor
end

Base.show(io::IO, decompressor::ZstdDecompressor) =
    print(io, ZstdDecompressor, "(dictionaries=", sort!(unique(d.id for d in values(decompressor.dictionaries))), ")")

# Ready `decompressor` for a frame naming the dictionary `id`.
# Resetting first abandons any frame left part-done by a failure, which would refuse a new dictionary.
function startframe!(decompressor::ZstdDecompressor, id::UInt32)
    (; dctx, dictionaries) = decompressor
    check(:decompress, LibZstd.dctx_reset(dctx))
    id === decompressor.frameid && return
    dictionary = get(dictionaries, id, nothing)
    isnothing(dictionary) && !iszero(id) && throw(ZstdError(:decompress, :dictionary, id))
    check(:decompress, LibZstd.dctx_refddict(dctx, if isnothing(dictionary) C_NULL else dictionary.ddict end))
    decompressor.frameid = id
end

"""
    decompress_zstd(data; threads=1, kwargs...)::Vector{UInt8}
    decompress_zstd(decompressor::ZstdDecompressor, data)::Vector{UInt8}

Decompress the zstd `data`, a byte vector, string, or memory view holding one or
more frames. The other keyword arguments are those of [`ZstdDecompressor`](@ref).

Skippable frames are skipped, and each frame is decompressed with the dictionary
it names. With `threads` above one, or `0` for one per Julia thread, the frames
are shared out between that many tasks, so only data of several frames gains.
When every frame records its content size, the tasks decompress straight into
the result.

Throws `ZstdError` if the data are not zstd data, are corrupt or truncated, or
need a dictionary that was not given.
"""
function decompress_zstd(data; threads::Integer = 1, kwargs...)
    threads ≥ 0 || throw(ArgumentError("threads must be non-negative, with 0 for one per Julia thread"))
    input = ImmutableMemoryView(data)
    taskcount = if iszero(threads) Threads.nthreads() else Int(threads) end
    decompress(frames) = withdecompressor(decompressor -> decompress_zstd(decompressor, frames); kwargs...)
    taskcount == 1 && return decompress(input)
    batches, spans = framebatches(input, taskcount)
    length(batches) ≤ 1 && return decompress(input)
    # A task's result, or its own error rather than the wrapper `fetch` throws
    function outcome(task::Task)
        try
            fetch(task)
        catch err
            err isa TaskFailedException || rethrow()
            throw(err.task.exception)
        end
    end
    if isnothing(spans)
        tasks = [Threads.@spawn decompress(batch) for batch in batches]
        reduce(vcat, [outcome(task)::Vector{UInt8} for task in tasks])
    else
        output = Vector{UInt8}(undef, last(last(spans)))
        tasks = [Threads.@spawn withdecompressor(; kwargs...) do decompressor
                     decompress_sized!(MemoryView(output)[span], decompressor, batch)
                 end for (batch, span) in zip(batches, spans)]
        foreach(outcome, tasks)
        output
    end
end

# A result keeps the room it was decoded into, which for a frame recording no content size
# is `IO_BUFFER_SIZE` at the least. A small result hands the excess back, being the kind
# held in numbers and cheap to copy.
function decompress_zstd(decompressor::ZstdDecompressor, data)
    output = decompress_zstd!(UInt8[], decompressor, data)
    if length(output) < IO_BUFFER_SIZE sizehint!(output, length(output)) else output end
end

function withdecompressor(f; kwargs...)
    decompressor = ZstdDecompressor(; kwargs...)
    try
        f(decompressor)
    finally
        finalize(decompressor)
    end
end

# Split `input` at frame boundaries into at most `n` runs of frames, of similar compressed
# size. With them come the spans of the whole output that each run's content fills, or
# `nothing` unless every frame records its content size.
function framebatches(input::ImmutableMemoryView{UInt8}, n::Int)
    ends, contentends, issized = [0], [0], true
    for frame in Frames(input)
        size = if issized contentsize(frame) end
        issized = !isnothing(size)
        push!(ends, last(ends) + length(frame.bytes))
        push!(contentends, last(contentends) + something(size, 0))
    end
    cuts = unique!([searchsortedfirst(ends, k * length(input) ÷ n) for k in 0:n])
    runs = zip(cuts, Iterators.drop(cuts, 1))
    batches = [input[ends[a]+1:ends[b]] for (a, b) in runs]
    spans = if issized; [contentends[a]+1:contentends[b] for (a, b) in runs] end
    (batches, spans)
end

# Decompress the frames of `input`, which all record their content size, to fill `output` exactly.
function decompress_sized!(output::MutableMemoryView{UInt8}, decompressor::ZstdDecompressor, input::ImmutableMemoryView{UInt8})
    for frame in Frames(input)
        startframe!(decompressor, frame.dictid)
        made = check(:decompress, LibZstd.decompressdctx!(decompressor.dctx, output[1:contentsize(frame)], frame.bytes))
        output = output[made+1:end]
    end
end

"""
    decompress_zstd!(output::Vector{UInt8}, decompressor::ZstdDecompressor, data) -> output

Decompress the zstd `data`, replacing the contents of `output`, which is reused
to avoid allocating anew for each of many inputs. See [`decompress_zstd`](@ref).
"""
function decompress_zstd!(output::Vector{UInt8}, decompressor::ZstdDecompressor, data)
    input = ImmutableMemoryView(data)
    empty!(output)
    isempty(input) && return output
    frame = firstframe(input)
    # A lone frame, as most input is, has nothing further to make room for
    length(frame.bytes) == length(input) && return decompress_frame!(output, decompressor, frame)
    total = totalcontentsize(input)
    if isnothing(total)
        foreach(frame -> decompress_frame!(output, decompressor, frame), Frames(input))
    else
        decompress_sized!(MemoryView(resize!(output, total)), decompressor, input)
    end
    output
end

# The content size of all the frames of `input`, or `nothing` unless each records its own.
function totalcontentsize(input::ImmutableMemoryView{UInt8})
    total = 0
    for frame in Frames(input)
        size = contentsize(frame)
        isnothing(size) && return nothing
        total += size
    end
    total
end

# Decompress the whole of `frame`, appending to `output`: in one pass, without a window
# buffer, when the room its content needs is known up front.
function decompress_frame!(output::Vector{UInt8}, decompressor::ZstdDecompressor, frame::Frame)
    startframe!(decompressor, frame.dictid)
    filled = length(output)
    room = contentroom(frame)
    isnothing(room) && return decompress_growing!(output, decompressor, frame.bytes)
    resize!(output, filled + room)
    made = check(:decompress, LibZstd.decompressdctx!(decompressor.dctx, MemoryView(output)[filled+1:end], frame.bytes))
    resize!(output, filled + made)
end

# Room sure to hold the content of `frame`: the size it records, or else libzstd's bound
# on it, or `nothing` when that is too loose to allocate. The bound counts every block as
# full, so for a stream flushed often it is thousands of times the content.
function contentroom(frame::Frame)
    size = contentsize(frame)
    isnothing(size) || return size
    bound = LibZstd.decompressbound(frame.bytes)
    if bound ≤ max(MAX_BOUND_EXPANSION * length(frame.bytes), LibZstd.BLOCKSIZE_MAX) Int(bound) end
end

# Decompress the whole of `frame`, which `decompressor` is ready for, appending to
# `output` and growing it as the content arrives.
function decompress_growing!(output::Vector{UInt8}, decompressor::ZstdDecompressor, frame::ImmutableMemoryView{UInt8})
    filled = length(output)
    while true
        filled == length(output) && resize!(output, max(2 * filled, filled + IO_BUFFER_SIZE))
        used, made, ret = LibZstd.decompressstream!(decompressor.dctx, frame, MemoryView(output)[filled+1:end])
        frame = frame[used+1:end]
        filled += made
        iszero(check(:decompress, ret)) && break
        isempty(frame) && made == 0 && throw(ZstdError(:decompress, :truncated))
    end
    resize!(output, filled)
end
