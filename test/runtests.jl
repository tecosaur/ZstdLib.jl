# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

using ZstdLib
using ZstdLib: LibZstd, ImmutableMemoryView, MemoryView, dictionaryid, framelayout, framesize
using BufferIO: BufferIO, CursorReader, IOError, VecWriter
using BufferIO.Testing: BoundedReader, BoundedWriter
using Random
using Test

# Made by `printf foo | zstd -c --no-check` and `--check` with zstd 1.5.7. Being
# piped, neither records its content size.
const FOO = UInt8[0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x58, 0x19, 0x00, 0x00, 0x66, 0x6f, 0x6f]
const FOO_CHECKED = UInt8[0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x19, 0x00, 0x00, 0x66, 0x6f, 0x6f,
                          0x3f, 0xba, 0xc4, 0x59]

skippable(payload) = vcat(reinterpret(UInt8, [htol(0x184d2a50), htol(UInt32(length(payload)))]), payload)

const RECORDS = ["{\"id\": $i, \"title\": \"Record number $i\", \"tags\": [\"t$(i % 7)\", \"u$(i % 11)\"], \"score\": $(i * 37 % 1000)}"
                 for i in 1:20_000]
const SAMPLE = Vector{UInt8}(codeunits(join(RECORDS[1:5000], '\n')))
const NOISE = rand(Xoshiro(5), UInt8, 300_000)

# A frame of one raw block holding "abc", claiming `contentsize` bytes of content.
misclaimed(contentsize) = vcat(UInt8[0x28, 0xb5, 0x2f, 0xfd, 0xe0], reinterpret(UInt8, [htol(UInt64(contentsize))]),
                               UInt8[0x19, 0x00, 0x00], b"abc")

geterror(f) = try f(); nothing catch err; err end

# Fails once, on its `failat`th attempt to make room, like a transient disk error.
mutable struct FlakySink <: BufferIO.AbstractBufWriter
    const inner::BoundedWriter
    failat::Int
end
FlakySink(sink::Vector{UInt8}, failat::Int) = FlakySink(BoundedWriter(sink, 4096), failat)
BufferIO.get_buffer(sink::FlakySink) = BufferIO.get_buffer(sink.inner)
BufferIO.consume(sink::FlakySink, n::Int) = BufferIO.consume(sink.inner, n)
BufferIO.grow_buffer(sink::FlakySink) =
    if iszero(sink.failat -= 1) error("transient failure") else BufferIO.grow_buffer(sink.inner) end
Base.flush(sink::FlakySink) = flush(sink.inner)
Base.close(sink::FlakySink) = close(sink.inner)
Base.isopen(sink::FlakySink) = isopen(sink.inner)

const DICTIONARY = train_dictionary(RECORDS[5001:end]; size = 8192)
const OTHER_DICTIONARY = train_dictionary(reverse.(RECORDS[5001:end]); size = 4096)
const RAW_DICTIONARY = ZstdDictionary(SAMPLE[1:4096])

function streamed(data; kwargs...)
    sink = VecWriter()
    ZstdWriter(writer -> write(writer, data), sink; kwargs...)
    sink.vec
end

# Flushing after each record ends a block early, so libzstd's bound on the content is far too loose to allocate.
function flushed(records; kwargs...)
    sink = VecWriter()
    ZstdWriter(writer -> foreach(record -> (write(writer, record); flush(writer)), records), sink; kwargs...)
    sink.vec
end

function framesof(data)
    frames, rest = typeof(view(data, 1:0))[], view(data, :)
    while !isempty(rest)
        n = framesize(rest)
        push!(frames, view(rest, 1:n))
        rest = view(rest, n+1:length(rest))
    end
    frames
end

# Read all of `reader` in pieces made by every kind of read, of sizes around and well past
# `bufsize`, or `nothing` if its position ever strays from the count of bytes read.
function readinpieces(reader, rng, bufsize)
    out, positioned = UInt8[], true
    while !eof(reader)
        n = rand(rng, rand(rng, (1:2bufsize, bufsize:4bufsize, 1:300_000)))
        op = rand(rng, 1:5)
        piece = if rand(rng) < 0.05
            read(reader)
        elseif op == 1
            read(reader, n)
        elseif op == 2
            dst = Vector{UInt8}(undef, n)
            dst[1:BufferIO.read_into!(reader, MemoryView(dst))]
        elseif op == 3
            bytes = UInt8[]
            readbytes!(reader, bytes, n)
            bytes
        elseif op == 4
            read!(reader, Vector{UInt8}(undef, min(n, bytesavailable(reader))))
        else
            codeunits(readline(reader; keep = true))
        end
        append!(out, piece)
        positioned &= position(reader) == length(out)
    end
    if positioned out end
end

# What each way of decoding `data` makes of it, each starting afresh, but for one
# decompressor kept from frame to frame.
function decodeeveryway(data; dictionaries = ())
    decompressor = ZstdDecompressor(; dictionaries)
    (; whole = decompress_zstd(data; dictionaries),
       threaded = decompress_zstd(data; dictionaries, threads = 3),
       autothreaded = decompress_zstd(data; dictionaries, threads = 0),
       into_reused_output = decompress_zstd!(rand(UInt8, 100), ZstdDecompressor(; dictionaries), data),
       frame_by_frame = reduce(vcat, (decompress_zstd(decompressor, frame) for frame in framesof(data)); init = UInt8[]),
       reader = ZstdReader(CursorReader(data); dictionaries) do reader
           out = read(reader)
           if position(reader) == length(out) out end
       end,
       reader_in_pieces = ZstdReader(reader -> readinpieces(reader, Xoshiro(length(data)), 64),
                                     BoundedReader(data, 64; max_fill = 7); dictionaries, bufsize = 64),
       reader_through_tiny_buffers = ZstdReader(reader -> readinpieces(reader, Xoshiro(length(data)), 2),
                                                BoundedReader(data, 5; max_fill = 3); dictionaries, bufsize = 2))
end

# The ways that did not make `expected`, so that a failure names them.
disagreeing(results, expected) = [way for (way, result) in pairs(results) if result != expected]

# Compress `data` through a `ZstdWriter`, written in pieces of every size, single bytes among
# them, returning the frame and whether each flush made everything written so far decodable.
function streaminpieces(data::Vector{UInt8}, rng; sinksize, bufsize, options...)
    frame, written, flushes = UInt8[], 0, true
    dictionaries = filter(!isnothing, [get(options, :dictionary, nothing)])
    # The first `n` bytes of the unfinished `frame`, read in pieces smaller than the reader's
    # buffer, so that each is decoded through it
    function decodedprefix(frame, n)
        reader, prefix = ZstdReader(CursorReader(copy(frame)); dictionaries), UInt8[]
        while length(prefix) < n
            append!(prefix, read(reader, min(rand(rng, 1:1 << 16), n - length(prefix))))
        end
        prefix
    end
    ZstdWriter(BoundedWriter(frame, sinksize); bufsize, options...) do writer
        while written < length(data)
            n = min(rand(rng, rand(rng, (1:1, 1:100, 1:100_000))), length(data) - written)
            if n == 1 write(writer, data[written+1]) else write(writer, view(data, written+1:written+n)) end
            written += n
            rand(rng) < 0.05 || continue
            flush(writer)
            flushes &= decodedprefix(frame, written) == data[1:written]
        end
    end
    frame, flushes
end

@testset "Round trips, through every encoder and decoder" begin
    @testset "$(length(data)) bytes, level $level, checksum=$checksum, threads=$threads, dictionary=$(!isnothing(dictionary))" for
            data in (UInt8[], [0x01], rand(Xoshiro(1), UInt8, 100), SubString("xHello, world!", 2), SAMPLE),
            level in (Int8(-5), Int32(3), UInt8(19)), checksum in (false, true), threads in (1, 4), dictionary in (nothing, DICTIONARY)
        options = (; level, checksum, threads, dictionary)
        content = Vector{UInt8}(if data isa AbstractString codeunits(data) else data end)
        dictionaries = filter(!isnothing, [dictionary])
        frame = compress_zstd(data; options...)
        compressor, reframed = ZstdCompressor(; options...), UInt8[]
        @test all(_ -> compress_zstd!(reframed, compressor, data) == frame, 1:2)
        rng = Xoshiro(length(content) + level)
        streams = [streaminpieces(content, rng; sinksize, bufsize, options...)
                   for (sinksize, bufsize) in ((7, 5), (1 << 17, ZstdLib.IO_BUFFER_SIZE))]
        @test all(last, streams)
        @test disagreeing(decodeeveryway(reduce(vcat, [frame; first.(streams)]); dictionaries), repeat(content, 3)) == []
        @test dictionaryid(frame) == if isnothing(dictionary) 0 else dictionary.id end
    end
    @testset "threads = 0 picks a count" begin
        @test decompress_zstd(compress_zstd(SAMPLE; threads = 0)) == SAMPLE
        @test decompress_zstd(streamed(SAMPLE; threads = 0)) == SAMPLE
    end
end

@testset "Every decoder agrees on a stream of every kind of frame" begin
    loose, loosecontent = flushed(RECORDS[1:2000]), codeunits(join(RECORDS[1:2000]))
    # Each kind of frame, with its content and the dictionary it names. The empty frames
    # follow one whose content fills exactly the room its recorded size made.
    frames = [(compress_zstd(SAMPLE; checksum = true), SAMPLE, 0),
              (compress_zstd(""), UInt8[], 0), (streamed(UInt8[]), UInt8[], 0),
              (FOO, b"foo", 0), (FOO_CHECKED, b"foo", 0),
              (skippable(b"ignored"), UInt8[], 0),
              (streamed(SAMPLE), SAMPLE, 0),
              (loose, loosecontent, 0),
              (compress_zstd(NOISE), NOISE, 0),
              (compress_zstd(RECORDS[1]; dictionary = DICTIONARY), codeunits(RECORDS[1]), DICTIONARY.id),
              (compress_zstd(RECORDS[2]; dictionary = OTHER_DICTIONARY), codeunits(RECORDS[2]), OTHER_DICTIONARY.id),
              (compress_zstd(RECORDS[3]), codeunits(RECORDS[3]), 0),
              (streamed(SAMPLE; dictionary = DICTIONARY, level = 19), SAMPLE, DICTIONARY.id),
              (compress_zstd(RECORDS[4]; dictionary = RAW_DICTIONARY), codeunits(RECORDS[4]), 0),
              (compress_zstd(RECORDS[5]; dictionary = DICTIONARY), codeunits(RECORDS[5]), DICTIONARY.id)]
    data, expected = reduce(vcat, first.(frames)), reduce(vcat, getindex.(frames, 2))
    padded = vcat(zeros(UInt8, 3), data, zeros(UInt8, 3))
    data = view(padded, 4:length(padded)-3)
    dictionaries = [DICTIONARY, OTHER_DICTIONARY, RAW_DICTIONARY]
    @test disagreeing(decodeeveryway(data; dictionaries), expected) == []
    @test length.(framesof(data)) == length.(first.(frames))
    @test dictionaryid.(framesof(data)) == last.(frames)
    # Output is sized to its content, even when a frame records no size and bounds it loosely
    @test Base.summarysize(decompress_zstd(FOO)) < 1024
    @test Base.summarysize(decompress_zstd(loose)) < 2 * length(loosecontent)
end

@testset "Damaged data fail alike through every decoder, which stay usable" begin
    good = compress_zstd(SAMPLE)
    corrupted(frame, at = lastindex(frame)) = (frame = copy(frame); frame[at] ⊻= 0xff; frame)
    loose = flushed(RECORDS[1:2000]; checksum = true)
    needsdictionary = compress_zstd(RECORDS[1]; dictionary = DICTIONARY)
    # A truncated frame is only told from a corrupt one at the end of the data, as anything
    # following it reads as its continuation. The reader meets the bomb's claim as a window too
    # large to decode in, where the whole-buffer decoders refuse to make room for it.
    damages = [(b"not zstd at all", :format, :format),
               (vcat(good, good[1:end-5]), :truncated, :truncated),
               (vcat(good, streamed(SAMPLE)[1:end-100]), :truncated, :truncated),
               (vcat(good, corrupted(compress_zstd(SAMPLE; checksum = true)), good), :corrupt, :corrupt),
               (vcat(good, corrupted(streamed(SAMPLE; checksum = true)), good), :corrupt, :corrupt),
               (vcat(good, corrupted(loose, length(loose) ÷ 2), good), :corrupt, :corrupt),
               (vcat(good, misclaimed(10), good), :corrupt, :corrupt),
               (vcat(good, misclaimed(2), good), :corrupt, :corrupt),
               (vcat(good, misclaimed(1 << 42), good), :corrupt, :memlimit),
               (vcat(good, needsdictionary, good), :dictionary, :dictionary)]
    # A frame named by the one dictionary given, first to follow a failure, which may have left
    # the decompressor part-way through a frame
    dictionaries = [OTHER_DICTIONARY]
    recovery = vcat(compress_zstd(RECORDS[2]; dictionary = OTHER_DICTIONARY), good, streamed(SAMPLE))
    for (data, code, readercode) in damages
        decompressor = ZstdDecompressor(; dictionaries)
        reader = ZstdReader(BoundedReader(data, 64; max_fill = 7); dictionaries, bufsize = 64)
        errors = (; whole = geterror(() -> decompress_zstd(data; dictionaries)),
                  threaded = geterror(() -> decompress_zstd(data; dictionaries, threads = 3)),
                  into_reused_output = geterror(() -> decompress_zstd!(UInt8[], decompressor, data)),
                  reader = geterror(() -> readinpieces(reader, Xoshiro(1), 64)))
        @test map(err -> err isa ZstdError ? err.code : err, errors) ==
              (; whole = code, threaded = code, into_reused_output = code, reader = readercode)
        message = sprint(showerror, errors.whole)
        @test occursin("could not decompress", message) && (code !== :dictionary || occursin("ID $(DICTIONARY.id)", message))
        @test decompress_zstd(decompressor, recovery) == vcat(codeunits(RECORDS[2]), SAMPLE, SAMPLE)
        @test geterror(() -> read(reader)) === errors.reader
    end
    @test_throws ZstdError framesize(good[1:end-1])
    @test_throws ZstdError framesize(b"not zstd")
    @test dictionaryid(b"not zstd") == 0
end

@testset "Frame layout, read without libzstd, agrees with it" begin
    # What libzstd makes of the frame starting `data`, or `nothing` where it finds no whole frame
    function reference(data)
        view = ImmutableMemoryView(data)
        size = LibZstd.frame_compressedsize(view)
        if !LibZstd.iserror(size); (Int(size), LibZstd.dictid_fromframe(view), LibZstd.frame_contentsize(view)) end
    end
    rng = Xoshiro(7)
    frames = [compress_zstd(rand(rng, UInt8, n); checksum) for n in (0, 1, 255, 256, 65_791, 65_792, 300_000) for checksum in (false, true)]
    append!(frames, [compress_zstd(zeros(UInt8, n)) for n in (1, 1000, 1 << 20)])
    append!(frames, [compress_zstd(repeat(SAMPLE, 8); level) for level in (-5, 3, 19)])
    append!(frames, [streamed(SAMPLE), streamed(SAMPLE; checksum = true), streamed(UInt8[]), streamed(rand(rng, UInt8, 300_000)), FOO, FOO_CHECKED])
    append!(frames, [compress_zstd(RECORDS[1]; dictionary) for dictionary in (DICTIONARY, OTHER_DICTIONARY, RAW_DICTIONARY)])
    push!(frames, flushed(RECORDS[1:50]))
    @testset "whole frames" begin
        @test all(frame -> framelayout(ImmutableMemoryView(frame)) == reference(frame), frames)
        @test all(frame -> framelayout(ImmutableMemoryView(vcat(frame, FOO, 0x00))) == reference(frame), frames)
    end
    @testset "frames cut short" begin
        @test all(isnothing(framelayout(ImmutableMemoryView(frame)[1:n])) for frame in frames for n in 0:min(length(frame) - 1, 400))
        @test all(isnothing(framelayout(ImmutableMemoryView(frame)[1:end-1])) for frame in frames)
    end
    @testset "what is not an ordinary frame is left to libzstd" begin
        @test isnothing(framelayout(ImmutableMemoryView(skippable(b"ignored"))))
        @test isnothing(framelayout(ImmutableMemoryView(rand(rng, UInt8, 64))))
    end
    @testset "damaged headers are never read differently" begin
        isconsistent = true
        for frame in frames, _ in 1:300
            damaged = copy(frame)
            for _ in 1:rand(rng, 1:3)
                damaged[rand(rng, 1:min(length(damaged), 24))] = rand(rng, UInt8)
            end
            layout = framelayout(ImmutableMemoryView(damaged))
            isconsistent &= isnothing(layout) || layout == reference(damaged)
        end
        @test isconsistent
    end
end

@testset "Dictionaries" begin
    @testset "construction" begin
        @test DICTIONARY.id != 0 && DICTIONARY.id != OTHER_DICTIONARY.id && RAW_DICTIONARY.id == 0
        @test length(DICTIONARY.data) ≤ 8192
        @test ZstdDictionary(sprint(write, DICTIONARY) |> codeunits) == DICTIONARY
        @test occursin("id=$(DICTIONARY.id)", sprint(show, DICTIONARY))
        err = geterror(() -> train_dictionary(RECORDS[1:3]; size = 100_000))
        @test err isa ZstdError && err.code === :samples && occursin("more samples", sprint(showerror, err))
    end
    @testset "frames naming no dictionary use the only one given" begin
        compressor = ZstdCompressor(dictionary = DICTIONARY)
        ZstdLib.LibZstd.cctx_setparameter(compressor.cctx, Cint(202), 0)  # ZSTD_c_dictIDFlag, as `zstd --no-dictID`
        data = vcat(compress_zstd(compressor, RECORDS[3]), compress_zstd(RECORDS[4]))
        @test dictionaryid.(framesof(data)) == [0, 0]
        @test disagreeing(decodeeveryway(data; dictionaries = [DICTIONARY]), codeunits(RECORDS[3] * RECORDS[4])) == []
    end
    @testset "shared between tasks" begin
        results = Vector{Bool}(undef, 16)
        Threads.@threads for t in 1:16
            compressor = ZstdCompressor(level = 3 + t % 4, dictionary = DICTIONARY)
            decompressor = ZstdDecompressor(dictionaries = [DICTIONARY])
            results[t] = all(RECORDS[t:16:2000]) do record
                String(decompress_zstd(decompressor, compress_zstd(compressor, record))) == record
            end
        end
        @test all(results)
    end
end

@testset "Compression pays" begin
    @test length(compress_zstd(SAMPLE)) < length(SAMPLE) ÷ 5
    @test length(compress_zstd(SAMPLE; level = 19)) < length(compress_zstd(SAMPLE; level = 1))
    for dictionary in (DICTIONARY, RAW_DICTIONARY)
        plain = sum(r -> length(compress_zstd(r; level = 19)), RECORDS[1:500])
        primed = sum(r -> length(compress_zstd(r; level = 19, dictionary)), RECORDS[1:500])
        @test primed < plain ÷ 2
    end
end

@testset "Streams" begin
    @testset "window limit" begin
        compressed = streamed(rand(Xoshiro(3), UInt8, 4 << 20); level = 19)
        err = geterror(() -> ZstdReader(read, CursorReader(compressed); windowlog = 10))
        @test err isa ZstdError && err.code === :memlimit && occursin("windowlog", sprint(showerror, err))
        @test length(ZstdReader(read, CursorReader(compressed); windowlog = 23)) == 4 << 20
    end
    @testset "closing" begin
        reader = ZstdReader(IOBuffer(FOO))
        @test occursin("IOBuffer", sprint(show, reader))
        close(reader)
        @test !isopen(reader)
        @test_throws IOError read(reader, 1)
        @test_throws IOError read(reader)
        sink = VecWriter()
        writer = ZstdWriter(sink)
        write(writer, "abc")
        @test occursin("VecWriter", sprint(show, writer))
        close(writer)
        @test !isopen(writer)
        @test_throws IOError write(writer, "more")
        @test_throws IOError flush(writer)
        close(writer)
        @test decompress_zstd(sink.vec) == b"abc"
    end
    @testset "a failing function leaves the frame unfinished" begin
        sink = VecWriter()
        @test_throws ErrorException ZstdWriter(sink) do writer
            write(writer, SAMPLE)
            flush(writer)
            error("stop")
        end
        err = geterror(() -> decompress_zstd(sink.vec))
        @test err isa ZstdError && err.code === :truncated
    end
    @testset "a failing sink closes the writer" begin
        writer = ZstdWriter(FlakySink(UInt8[], 2); level = 1)
        @test_throws ErrorException write(writer, rand(Xoshiro(4), UInt8, 1 << 20))
        @test !isopen(writer)
    end
end

@testset "Invalid arguments" begin
    @test_throws ArgumentError ZstdCompressor(level = 23)
    @test_throws ArgumentError ZstdCompressor(threads = -1)
    @test_throws ArgumentError ZstdCompressor(threads = 100_000)
    @test_throws ArgumentError ZstdDecompressor(windowlog = 5)
    @test_throws ArgumentError ZstdDecompressor(dictionaries = [DICTIONARY, DICTIONARY])
    @test_throws ArgumentError decompress_zstd(SAMPLE; threads = -1)
    @test_throws ArgumentError ZstdDictionary(UInt8[0x37, 0xa4, 0x30, 0xec, 1, 2, 3, 4, 5, 6, 7, 8])
    @test_throws ArgumentError ZstdDictionary(UInt8[])
    @test_throws ArgumentError train_dictionary(RECORDS; size = 100)
    @test_throws ArgumentError ZstdReader(IOBuffer(FOO); bufsize = 0)
    @test_throws ArgumentError ZstdWriter(VecWriter(); bufsize = 0)
    @test_throws ArgumentError ZstdWriter(VecWriter(); level = 100)
end
