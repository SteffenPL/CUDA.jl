# Basic library functionality

#
# API versioning
#

const mapping = Dict{Symbol,Symbol}()
const minreq = Dict{Symbol,VersionNumber}()

if libcuda_version >= v"3.2"
    mapping[:cuDeviceTotalMem]           = :cuDeviceTotalMem_v2
    mapping[:cuCtxCreate]                = :cuCtxCreate_v2
    mapping[:cuModuleGetGlobal]          = :cuModuleGetGlobal_v2
    mapping[:cuMemGetInfo]               = :cuMemGetInfo_v2
    mapping[:cuMemAlloc]                 = :cuMemAlloc_v2
    mapping[:cuMemAllocPitch]            = :cuMemAllocPitch_v2
    mapping[:cuMemFree]                  = :cuMemFree_v2
    mapping[:cuMemGetAddressRange]       = :cuMemGetAddressRange_v2
    mapping[:cuMemAllocHost]             = :cuMemAllocHost_v2
    mapping[:cuMemHostGetDevicePointer]  = :cuMemHostGetDevicePointer_v2
    mapping[:cuMemcpyHtoD]               = :cuMemcpyHtoD_v2
    mapping[:cuMemcpyDtoH]               = :cuMemcpyDtoH_v2
    mapping[:cuMemcpyDtoD]               = :cuMemcpyDtoD_v2
    mapping[:cuMemcpyDtoA]               = :cuMemcpyDtoA_v2
    mapping[:cuMemcpyAtoD]               = :cuMemcpyAtoD_v2
    mapping[:cuMemcpyHtoA]               = :cuMemcpyHtoA_v2
    mapping[:cuMemcpyAtoH]               = :cuMemcpyAtoH_v2
    mapping[:cuMemcpyAtoA]               = :cuMemcpyAtoA_v2
    mapping[:cuMemcpyHtoAAsync]          = :cuMemcpyHtoAAsync_v2
    mapping[:cuMemcpyAtoHAsync]          = :cuMemcpyAtoHAsync_v2
    mapping[:cuMemcpy2D]                 = :cuMemcpy2D_v2
    mapping[:cuMemcpy2DUnaligned]        = :cuMemcpy2DUnaligned_v2
    mapping[:cuMemcpy3D]                 = :cuMemcpy3D_v2
    mapping[:cuMemcpyHtoDAsync]          = :cuMemcpyHtoDAsync_v2
    mapping[:cuMemcpyDtoHAsync]          = :cuMemcpyDtoHAsync_v2
    mapping[:cuMemcpyDtoDAsync]          = :cuMemcpyDtoDAsync_v2
    mapping[:cuMemcpy2DAsync]            = :cuMemcpy2DAsync_v2
    mapping[:cuMemcpy3DAsync]            = :cuMemcpy3DAsync_v2
    mapping[:cuMemsetD8]                 = :cuMemsetD8_v2
    mapping[:cuMemsetD16]                = :cuMemsetD16_v2
    mapping[:cuMemsetD32]                = :cuMemsetD32_v2
    mapping[:cuMemsetD2D8]               = :cuMemsetD2D8_v2
    mapping[:cuMemsetD2D16]              = :cuMemsetD2D16_v2
    mapping[:cuMemsetD2D32]              = :cuMemsetD2D32_v2
    mapping[:cuArrayCreate]              = :cuArrayCreate_v2
    mapping[:cuArrayGetDescriptor]       = :cuArrayGetDescriptor_v2
    mapping[:cuArray3DCreate]            = :cuArray3DCreate_v2
    mapping[:cuArray3DGetDescriptor]     = :cuArray3DGetDescriptor_v2
    mapping[:cuTexRefSetAddress]         = :cuTexRefSetAddress_v2
    mapping[:cuTexRefGetAddress]         = :cuTexRefGetAddress_v2
    mapping[:cuGraphicsResourceGetMappedPointer] = :cuGraphicsResourceGetMappedPointer_v2
end

if libcuda_version >= v"4.0"
    mapping[:cuCtxDestroy]               = :cuCtxDestroy_v2
    mapping[:cuCtxPopCurrent]            = :cuCtxPopCurrent_v2
    mapping[:cuCtxPushCurrent]           = :cuCtxPushCurrent_v2
    mapping[:cuStreamDestroy]            = :cuStreamDestroy_v2
    mapping[:cuEventDestroy]             = :cuEventDestroy_v2
end

if libcuda_version >= v"4.1"
    mapping[:cuTexRefSetAddress2D]       = :cuTexRefSetAddress2D_v3
end

if libcuda_version >= v"6.5"
    mapping[:cuLinkCreate]              = :cuLinkCreate_v2
    mapping[:cuLinkAddData]             = :cuLinkAddData_v2
    mapping[:cuLinkAddFile]             = :cuLinkAddFile_v2
end

if libcuda_version >= v"6.5"
    mapping[:cuMemHostRegister]         = :cuMemHostRegister_v2
    mapping[:cuGraphicsResourceSetMapFlags] = :cuGraphicsResourceSetMapFlags_v2
end

if v"3.2" <= libcuda_version < v"4.1"
    mapping[:cuTexRefSetAddress2D]      = :cuTexRefSetAddress2D_v2
end


## Version-dependent features

minreq[:cuLinkCreate]       = v"5.5"
minreq[:cuLinkDestroy]      = v"5.5"
minreq[:cuLinkComplete]     = v"5.5"
minreq[:cuLinkAddFile]      = v"5.5"
minreq[:cuLinkAddData]      = v"5.5"

minreq[:cuDummyAvailable]   = v"0"      # non-existing functions
minreq[:cuDummyUnavailable] = v"999"    # for testing purposes

# explicitly mark unavailable symbols, signaling `resolve` to error out
for (api_function, minimum_version) in minreq
    if libcuda_version < minimum_version
        mapping[api_function]      = Symbol()
    end
end

function resolve(f::Symbol)
    global mapping, version_requirements
    versioned_f = get(mapping, f, f)
    if versioned_f == Symbol()
        throw(CuVersionError(f, minreq[f]))
    end
    return versioned_f
end


#
# API call wrapper
#

# ccall wrapper for calling functions in the CUDA library
macro apicall(f, argtypes, args...)
    # Escape the tuple of arguments, making sure it is evaluated in caller scope
    # (there doesn't seem to be inline syntax like `$(esc(argtypes))` for this)
    esc_args = [esc(arg) for arg in args]

    blk = Expr(:block)

    if !isa(f, Expr) || f.head != :quote
        error("first argument to @apicall should be a symbol")
    end

    # Print the function name & arguments
    if TRACE
        push!(blk.args, :(trace($(sprint(Base.show_unquoted,f.args[1])*"("); line=false)))
        i=length(args)
        for arg in args
            i-=1
            sep = (i>0 ? ", " : "")

            # TODO: we should only do this if evaluating `arg` has no side effects
            push!(blk.args, :(trace(repr_indented($(esc(arg))), $sep;
                  prefix=$(sprint(Base.show_unquoted,arg))*"=", line=false)))
        end
        push!(blk.args, :(trace(""; prefix=") =", line=false)))
    end

    # Generate the actual call
    api_f = resolve(f.args[1])
    @gensym status
    push!(blk.args, quote
        $status = ccall(($(QuoteNode(api_f)), libcuda), Cint, $(esc(argtypes)), $(esc_args...))
    end)

    # Print the results
    if TRACE
        push!(blk.args, :(trace(CuError{$status}(); prefix=" ")))
    end

    # Check the return code
    push!(blk.args, quote
        if $status != code(SUCCESS)
            err = CuError{$status}()
            throw(err)
        end
    end)

    return blk
end


#
# Basic functionality
#

function vendor()
    return libcuda_vendor
end

"""
Returns the CUDA driver version as a VersionNumber.
"""
function version()
    version_ref = Ref{Cint}()
    @apicall(:cuDriverGetVersion, (Ptr{Cint},), version_ref)

    major = version_ref[] ÷ 1000
    minor = mod(version_ref[], 100) ÷ 10

    return VersionNumber(major, minor)
end
