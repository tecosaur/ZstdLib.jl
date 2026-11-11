# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

# Where frames lie in data, and what their headers say of decoding them. Asking libzstd
# takes three calls a frame, a third of the time a small frame takes to decode, so ordinary
# frames are read here (RFC 8878 §3.1.1) and only the rest are put to libzstd.

const FRAME_MAGIC = 0xfd2fb528
const MAX_EXPANSION = LibZstd.BLOCKSIZE_MAX ÷ 4  # the densest block, RLE, spends 4 bytes on BLOCKSIZE_MAX
const FRAME_SIZE_MIN = 9  # magic, descriptor, a window or content size byte, and a block header
const WINDOW_EXPONENT_MAX = 20  # as large a window as every libzstd build accepts

# A frame's bytes, with the ID of the dictionary and the size of the content its header
# records: 0 for no dictionary, and `LibZstd.CONTENTSIZE_UNKNOWN` for no size.
struct Frame
    bytes::ImmutableMemoryView{UInt8}
    dictid::UInt32
    contentsize::UInt64
end

# The frames that make up `input`, in turn. Throws `ZstdError` on reaching bytes that do
# not begin a whole frame.
struct Frames
    input::ImmutableMemoryView{UInt8}
end

Base.IteratorSize(::Type{Frames}) = Base.SizeUnknown()
Base.eltype(::Type{Frames}) = Frame

function Base.iterate(frames::Frames, input::ImmutableMemoryView{UInt8} = frames.input)
    isempty(input) && return nothing
    frame = firstframe(input)
    (frame, input[length(frame.bytes)+1:end])
end

"""
    ZstdLib.framesize(data)::Int

The length of the zstd frame at the start of `data`, a byte vector, string, or
memory view, found from its headers alone, so that one frame can be taken from
data that run on past it.

Throws `ZstdError` if `data` do not start with a whole zstd frame.
"""
framesize(data) = length(firstframe(ImmutableMemoryView(data)).bytes)

# The frame at the start of `input`. libzstd judges whatever is not plainly an ordinary
# frame: skippable and legacy frames, and all that is malformed or cut short.
function firstframe(input::ImmutableMemoryView{UInt8})
    layout = framelayout(input)
    if isnothing(layout)
        bytes = input[1:check(:decompress, LibZstd.frame_compressedsize(input))]
        Frame(bytes, LibZstd.dictid_fromframe(bytes), LibZstd.frame_contentsize(bytes))
    else
        size, dictid, contentsize = layout
        Frame(input[1:size], dictid, contentsize)
    end
end

# The length, dictionary ID, and content size of the ordinary frame at the start of
# `input`, or `nothing` if it does not plainly begin with a whole one.
function framelayout(input::ImmutableMemoryView{UInt8})
    length(input) ≥ FRAME_SIZE_MIN && littleendian(input, 1, 4) == FRAME_MAGIC || return nothing
    descriptor = input[5]
    iszero(descriptor & 0x08) || return nothing  # reserved
    issinglesegment = !iszero(descriptor & 0x20)
    issinglesegment || input[6] >> 3 ≤ WINDOW_EXPONENT_MAX || return nothing
    idbytes = (0, 1, 2, 4)[(descriptor & 0x03) + 1]
    sizebytes = if iszero(descriptor >> 6) Int(issinglesegment) else 1 << (descriptor >> 6) end
    idstart = 6 + !issinglesegment
    position = idstart + idbytes + sizebytes
    position ≤ length(input) || return nothing
    dictid = littleendian(input, idstart, idbytes) % UInt32
    contentsize = if iszero(sizebytes)
        LibZstd.CONTENTSIZE_UNKNOWN
    else  # two-byte sizes are offset, to reach past what one byte holds
        littleendian(input, idstart + idbytes, sizebytes) + 256 * (sizebytes == 2)
    end
    # Blocks, each a 3-byte header of last-block flag, type, and size, then its content
    while true
        position + 2 ≤ length(input) || return nothing
        header = littleendian(input, position, 3) % UInt32
        kind = (header >> 1) & 0x03
        kind == 0x03 && return nothing
        position += 3 + if kind == 0x01 1 else Int(header >> 3) end  # a run-length block holds one byte
        isodd(header) && break
    end
    size = position - 1 + 4 * !iszero(descriptor & 0x04)  # a checksum ends the frame
    if size ≤ length(input); (size, dictid, contentsize) end
end

function littleendian(input::ImmutableMemoryView{UInt8}, start::Int, bytes::Int)
    value = zero(UInt64)
    for i in 0:bytes-1
        value |= UInt64(input[start+i]) << 8i
    end
    value
end

# The content size `frame` records, or `nothing` if it records none. More than the frame
# could hold is corrupt, and refused before anything is allocated for it.
function contentsize(frame::Frame)
    frame.contentsize == LibZstd.CONTENTSIZE_UNKNOWN && return nothing
    frame.contentsize ≤ length(frame.bytes) * MAX_EXPANSION || throw(ZstdError(:decompress, :corrupt))
    Int(frame.contentsize)
end
