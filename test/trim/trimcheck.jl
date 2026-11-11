# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Exercises the whole public API, to be compiled with `juliac --trim=safe`, which rejects
# any call it cannot resolve statically. Exits non-zero if a result is wrong.

using ZstdLib
using BufferIO: VecWriter, CursorReader

report(name, ok::Bool) = (println(Core.stdout, if ok "ok    " else "FAIL  " end, name); ok)

function (@main)(args::Vector{String})::Cint
    records = ["{\"id\": $i, \"name\": \"item $i\", \"tags\": [\"a\", \"b\"], \"score\": $(i * 37 % 1000)}" for i in 1:5000]
    data = Vector{UInt8}(codeunits(join(records, '\n')))
    ok = true
    # Whole buffers
    frame = compress_zstd(data; level = 5, checksum = true)
    ok &= report("compress_zstd / decompress_zstd", decompress_zstd(frame) == data)
    ok &= report("string input", decompress_zstd(compress_zstd("hello")) == codeunits("hello"))
    compressor, decompressor = ZstdCompressor(; level = 3), ZstdDecompressor()
    out, back = UInt8[], UInt8[]
    compress_zstd!(out, compressor, data)
    ok &= report("reused state", decompress_zstd!(back, decompressor, out) == data)
    ok &= report("threads, compress", decompress_zstd(compress_zstd(data; threads = 2)) == data)
    frames = reduce(vcat, [compress_zstd(part) for part in Iterators.partition(data, 50_000)])
    ok &= report("several frames", decompress_zstd(frames) == data && decompress_zstd!(back, decompressor, frames) == data)
    ok &= report("threads, decompress sized", decompress_zstd(frames; threads = 3) == data)
    ok &= report("framesize", ZstdLib.framesize(frames) < length(frames))
    # Dictionaries
    dictionary = train_dictionary(records; size = 4096)
    primed = compress_zstd(records[1]; dictionary)
    ok &= report("dictionary round trip", decompress_zstd(primed; dictionaries = [dictionary]) == codeunits(records[1]))
    ok &= report("dictionaryid", ZstdLib.dictionaryid(primed) == dictionary.id)
    ok &= report("dictionary from bytes", ZstdDictionary(dictionary.data) == dictionary)
    # Streams
    sink = VecWriter()
    ZstdWriter(sink; level = 3) do writer
        write(writer, data)
    end
    ok &= report("ZstdWriter, then whole-buffer", decompress_zstd(sink.vec) == data)
    ok &= report("threads, decompress unsized", decompress_zstd(vcat(sink.vec, sink.vec); threads = 2) == vcat(data, data))
    ok &= report("ZstdReader read", ZstdReader(read, CursorReader(sink.vec)) == data)
    ok &= report("ZstdReader read, by count", ZstdReader(reader -> read(reader, length(data)), CursorReader(sink.vec)) == data)
    ok &= report("ZstdReader eachline", ZstdReader(reader -> count(_ -> true, eachline(reader)), IOBuffer(sink.vec)) == length(records))
    path = tempname()
    ZstdWriter(open(path, "w")) do writer
        write(writer, data)
    end
    ok &= report("files", ZstdReader(read, open(path)) == data)
    rm(path)
    # Errors
    err = try decompress_zstd(codeunits("definitely not zstd")); nothing catch e; e end
    ok &= report("ZstdError", err isa ZstdError && err.code === :format)
    err isa ZstdError && (showerror(Core.stdout, err); println(Core.stdout))
    Cint(!ok)
end
