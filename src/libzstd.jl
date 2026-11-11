# SPDX-FileCopyrightText: © 2026 TEC <contact@tecosaur.net>
# SPDX-License-Identifier: MPL-2.0

module LibZstd

using MemoryViews: ImmutableMemoryView, MutableMemoryView
using Zstd_jll: libzstd

# ZSTD_ErrorCode, from zstd_errors.h
const ERROR_PREFIX_UNKNOWN           = Cint(10)
const ERROR_VERSION_UNSUPPORTED      = Cint(12)
const ERROR_FRAMEPARAMETER_UNSUPPORTED = Cint(14)
const ERROR_WINDOW_TOO_LARGE         = Cint(16)
const ERROR_CORRUPTION_DETECTED      = Cint(20)
const ERROR_CHECKSUM_WRONG           = Cint(22)
const ERROR_LITERALS_HEADER_WRONG    = Cint(24)
const ERROR_DICTIONARY_CORRUPTED     = Cint(30)
const ERROR_DICTIONARY_WRONG         = Cint(32)
const ERROR_MEMORY_ALLOCATION        = Cint(64)
const ERROR_DSTSIZE_TOOSMALL         = Cint(70)
const ERROR_SRCSIZE_WRONG            = Cint(72)

# ZSTD_EndDirective
const E_CONTINUE = Cint(0)
const E_FLUSH    = Cint(1)
const E_END      = Cint(2)

# ZSTD_cParameter and ZSTD_dParameter
const C_COMPRESSION_LEVEL = Cint(100)
const C_CHECKSUM_FLAG     = Cint(201)
const C_NB_WORKERS        = Cint(400)
const C_FORCE_ATTACH_DICT = Cint(1001)  # ZSTD_c_experimentalParam4

const DICT_FORCE_ATTACH = Cint(1)  # ZSTD_dictForceAttach
const D_WINDOW_LOG_MAX    = Cint(100)

const RESET_SESSION_ONLY = Cint(1)

const CONTENTSIZE_UNKNOWN = typemax(UInt64)
const CONTENTSIZE_ERROR = typemax(UInt64) - 1

const FRAME_HEADER_SIZE_MAX = 18
const BLOCKSIZE_MAX = 128 * 1024
const DICT_MAGIC = (0x37, 0xa4, 0x30, 0xec)  # 0xec30a437, little-endian

struct Bounds
    error::Csize_t
    lower::Cint
    upper::Cint
end

struct InBuffer
    src::Ptr{UInt8}
    size::Csize_t
    pos::Csize_t
end

struct OutBuffer
    dst::Ptr{UInt8}
    size::Csize_t
    pos::Csize_t
end

iserror(code::Csize_t) = !iszero(@ccall libzstd.ZSTD_isError(code::Csize_t)::Cuint)
errorcode(code::Csize_t) = @ccall libzstd.ZSTD_getErrorCode(code::Csize_t)::Cint

cparam_bounds(param::Cint) = @ccall libzstd.ZSTD_cParam_getBounds(param::Cint)::Bounds
dparam_bounds(param::Cint) = @ccall libzstd.ZSTD_dParam_getBounds(param::Cint)::Bounds

minlevel() = Int(@ccall libzstd.ZSTD_minCLevel()::Cint)
maxlevel() = Int(@ccall libzstd.ZSTD_maxCLevel()::Cint)
version() = VersionNumber(unsafe_string(@ccall libzstd.ZSTD_versionString()::Cstring))

createcctx() = @ccall libzstd.ZSTD_createCCtx()::Ptr{Cvoid}
freecctx(cctx::Ptr{Cvoid}) = @ccall libzstd.ZSTD_freeCCtx(cctx::Ptr{Cvoid})::Csize_t
createdctx() = @ccall libzstd.ZSTD_createDCtx()::Ptr{Cvoid}
freedctx(dctx::Ptr{Cvoid}) = @ccall libzstd.ZSTD_freeDCtx(dctx::Ptr{Cvoid})::Csize_t

cctx_setparameter(cctx::Ptr{Cvoid}, param::Cint, value::Integer) =
    @ccall libzstd.ZSTD_CCtx_setParameter(cctx::Ptr{Cvoid}, param::Cint, value::Cint)::Csize_t
dctx_setparameter(dctx::Ptr{Cvoid}, param::Cint, value::Integer) =
    @ccall libzstd.ZSTD_DCtx_setParameter(dctx::Ptr{Cvoid}, param::Cint, value::Cint)::Csize_t
dctx_reset(dctx::Ptr{Cvoid}) = @ccall libzstd.ZSTD_DCtx_reset(dctx::Ptr{Cvoid}, RESET_SESSION_ONLY::Cint)::Csize_t

createcdict(dict::Memory{UInt8}, level::Integer) =
    @ccall libzstd.ZSTD_createCDict(dict::Ptr{UInt8}, length(dict)::Csize_t, level::Cint)::Ptr{Cvoid}
freecdict(cdict::Ptr{Cvoid}) = @ccall libzstd.ZSTD_freeCDict(cdict::Ptr{Cvoid})::Csize_t
createddict(dict::Memory{UInt8}) =
    @ccall libzstd.ZSTD_createDDict(dict::Ptr{UInt8}, length(dict)::Csize_t)::Ptr{Cvoid}
freeddict(ddict::Ptr{Cvoid}) = @ccall libzstd.ZSTD_freeDDict(ddict::Ptr{Cvoid})::Csize_t
cctx_refcdict(cctx::Ptr{Cvoid}, cdict::Ptr{Cvoid}) =
    @ccall libzstd.ZSTD_CCtx_refCDict(cctx::Ptr{Cvoid}, cdict::Ptr{Cvoid})::Csize_t
dctx_refddict(dctx::Ptr{Cvoid}, ddict::Ptr{Cvoid}) =
    @ccall libzstd.ZSTD_DCtx_refDDict(dctx::Ptr{Cvoid}, ddict::Ptr{Cvoid})::Csize_t

dictid_fromdict(dict::Memory{UInt8}) =
    @ccall libzstd.ZSTD_getDictID_fromDict(dict::Ptr{UInt8}, length(dict)::Csize_t)::Cuint

dictid_fromframe(frame::ImmutableMemoryView{UInt8}) =
    GC.@preserve frame @ccall libzstd.ZSTD_getDictID_fromFrame(pointer(frame)::Ptr{UInt8}, length(frame)::Csize_t)::Cuint

frame_contentsize(frame::ImmutableMemoryView{UInt8}) =
    GC.@preserve frame @ccall libzstd.ZSTD_getFrameContentSize(pointer(frame)::Ptr{UInt8}, length(frame)::Csize_t)::UInt64

frame_compressedsize(data::ImmutableMemoryView{UInt8}) =
    GC.@preserve data @ccall libzstd.ZSTD_findFrameCompressedSize(pointer(data)::Ptr{UInt8}, length(data)::Csize_t)::Csize_t

decompressbound(frame::ImmutableMemoryView{UInt8}) =
    GC.@preserve frame @ccall libzstd.ZSTD_decompressBound(pointer(frame)::Ptr{UInt8}, length(frame)::Csize_t)::UInt64

compressbound(n::Integer) = Int(@ccall libzstd.ZSTD_compressBound(n::Csize_t)::Csize_t)

function compress2!(cctx::Ptr{Cvoid}, output::MutableMemoryView{UInt8}, input::ImmutableMemoryView{UInt8})
    GC.@preserve input output @ccall gc_safe=true libzstd.ZSTD_compress2(
        cctx::Ptr{Cvoid}, pointer(output)::Ptr{UInt8}, length(output)::Csize_t,
        pointer(input)::Ptr{UInt8}, length(input)::Csize_t)::Csize_t
end

function decompressdctx!(dctx::Ptr{Cvoid}, output::MutableMemoryView{UInt8}, input::ImmutableMemoryView{UInt8})
    GC.@preserve input output @ccall gc_safe=true libzstd.ZSTD_decompressDCtx(
        dctx::Ptr{Cvoid}, pointer(output)::Ptr{UInt8}, length(output)::Csize_t,
        pointer(input)::Ptr{UInt8}, length(input)::Csize_t)::Csize_t
end

# Return the bytes used and made, and libzstd's return code. This is a GC safepoint,
# since callers loop without allocating, so might otherwise never let GC run.
function stream!(f::Function, ctx::Ptr{Cvoid}, input::ImmutableMemoryView{UInt8}, output::MutableMemoryView{UInt8})
    GC.@preserve input output begin
        inbuf = Ref(InBuffer(pointer(input), length(input), 0))
        outbuf = Ref(OutBuffer(pointer(output), length(output), 0))
        ret = f(ctx, outbuf, inbuf)
    end
    GC.safepoint()
    (Int(inbuf[].pos), Int(outbuf[].pos), ret)
end

function compressstream2!(cctx::Ptr{Cvoid}, input, output, directive::Cint)
    stream!(cctx, input, output) do cctx, outbuf, inbuf
        @ccall gc_safe=true libzstd.ZSTD_compressStream2(cctx::Ptr{Cvoid}, outbuf::Ref{OutBuffer},
                                            inbuf::Ref{InBuffer}, directive::Cint)::Csize_t
    end
end

function decompressstream!(dctx::Ptr{Cvoid}, input, output)
    stream!(dctx, input, output) do dctx, outbuf, inbuf
        @ccall gc_safe=true libzstd.ZSTD_decompressStream(dctx::Ptr{Cvoid}, outbuf::Ref{OutBuffer}, inbuf::Ref{InBuffer})::Csize_t
    end
end

trainfrombuffer!(dict::Vector{UInt8}, samples::Vector{UInt8}, sizes::Vector{Csize_t}) =
    @ccall gc_safe=true libzstd.ZDICT_trainFromBuffer(dict::Ptr{UInt8}, length(dict)::Csize_t, samples::Ptr{UInt8},
                                                      sizes::Ptr{Csize_t}, length(sizes)::Cuint)::Csize_t

end
