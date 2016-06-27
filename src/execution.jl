# Native execution support

export
    @cuda

# Convenience macro to support a naturally looking call
# eg. @cuda (len, 1) kernel_foo(bar)
macro cuda(config::Expr, callexpr::Expr)
    # Sanity checks
    if config.head != :tuple || !(2 <= length(config.args) <= 3)
        throw(ArgumentError("first argument to @cuda should be a tuple (gridDim, blockDim, [shmem])"))
    end
    if length(config.args) == 2
        push!(config.args, :0)
    end
    if callexpr.head != :call
        throw(ArgumentError("second argument to @cuda should be a function call"))
    end

    esc(:(CUDAnative.generate_cudacall($config, $(callexpr.args...))))
end

# Guess the intended kernel argument types from a given set of values.
# This is used to specialize the kernel function, and convert argument values.
function guess_types(argspec::Tuple)
    types = Array(Type, length(argspec))
    concrete = Array(Bool, length(argspec))

    for i in 1:length(argspec)
        types[i] = argspec[i]

        if !types[i].mutable && sizeof(types[i]) == 0
            # ghost type, ignored by the compiler
            concrete[i] = false
        elseif i==1 && types[i] <: Function
            # specialization on first function type
            concrete[i] = false
        else
            concrete[i] = true
        end

        if isbits(types[i])
            # these will be passed as-is
        elseif types[i] <: CUDAdrv.DevicePtr || types[i] <: CuArray
            # known convert to raw pointers
            types[i] = Ptr{eltype(types[i])}
        else
            warn("cannot guess kernel argument type from input argument of type $(types[i]), passing as-is")
        end
    end

    return tuple(types...), tuple(concrete...)
end

function compile_function{F<:Function}(ftype::Type{F}, types::Tuple{Vararg{Type}})
    debug("Compiling $ftype$types")

    # Try to get a hold of the original function
    # NOTE: this doesn't work for closures, as there can be multiple instances
    #       with each a different environment
    f = Nullable{Function}()
    try
        f = Nullable{Function}(ftype.instance)
    end

    @static if TRACE
        if !isnull(f)
            trace("Lowered AST:\n$(code_lowered(f, types))")
            trace("Typed AST (::ANY types shown in red):\n")
            code_warntype(STDERR, get(f), types)
        end
    end

    # Generate LLVM IR
    # NOTE: this is lifted from reflection.jl::_dump_function
    t = Base.tt_cons(ftype, Base.to_tuple_type(types))
    # Next call will trigger compilation (if necessary)
    llvmf = ccall(:jl_get_llvmf, Ptr{Void}, (Any, Bool, Bool), t, false, true)
    if llvmf == C_NULL
        error("no method found for kernel $ftype$types")
    end

    # Generate (PTX) assembly
    module_asm = ccall(:jl_dump_function_asm, Any, (Ptr{Void},Cint), llvmf, 0)::String

    # Get entry point
    module_entry = ccall(:jl_dump_function_name, Any, (Ptr{Void},), llvmf)::String

    trace("Function entry point: $module_entry")

    # DEBUG: dump the LLVM IR
    # TODO: this doesn't contain the full call cycle
    @static if TRACE
        if !isnull(f)
            # Generate a safe and unique name
            function_uid = "$(get(f))-"
            if length(types) > 0
                function_uid *= join([replace(string(x), r"\W", "")
                                    for x in types], '.')
            else
                function_uid *= "Void"
            end

            buf = IOBuffer()
            code_llvm(buf, get(f), types)
            module_llvm = String(buf)

            output = "$(dumpdir[])/$function_uid.ll"
            if isfile(output)
                warn("Could not write LLVM IR to $output (file already exists !?)")
            else
                open(output, "w") do io
                    write(io, module_llvm)
                end
                trace("Wrote kernel LLVM IR to $output")
            end
        end
    end

    # DEBUG: dump the (PTX) assembly
    @static if TRACE
        output = "$(dumpdir[])/$function_uid.ptx"
        if isfile(output)
            warn("Could not write (PTX) assembly to $output (file already exists !?)")
        else
            open(output, "w") do io
                write(io, module_asm)
            end
            trace("Wrote kernel (PTX) assembly to $output")
        end
    end

    # Return module & module entry containing function
    return (module_asm, module_entry)
end


# Generate a cudacall to a pre-compiled CUDA function
@generated function generate_cudacall(config::Tuple{CuDim, CuDim, Int},
                                      cuda_fun::CuFunction, argspec...)
    types, _ = guess_types(argspec)

    args = [:( argspec[$i] ) for i in 1:length(argspec)]
    kernel_call = :( cudacall(cuda_fun, config[1], config[2], $types, $(args...);
                              shmem_bytes=config[3]) )
end

# Compile a kernel and generate a cudacall
const func_cache = Dict{UInt, CuFunction}()
@generated function generate_cudacall{F<:Function}(config::Tuple{CuDim, CuDim, Int},
                                                   ftype::F, argspec...)
    args = [:( argspec[$i] ) for i in 1:length(argspec)]
    types, concrete = guess_types(argspec)
    key = hash((ftype, types))

    concrete_types = tuple(map(x->x[2], filter(x->x[1], zip(concrete, types)))...)
    concrete_args = tuple(map(x->x[2], filter(x->x[1], zip(concrete, args)))...)

    @gensym cuda_fun
    kernel_compilation = quote
        if (haskey(CUDAnative.func_cache, $key))
            $cuda_fun = CUDAnative.func_cache[$key]
        else
            (module_asm, module_entry) = CUDAnative.compile_function($ftype, $types)
            cuda_mod = CuModuleData(module_asm)
            $cuda_fun = CuFunction(cuda_mod, module_entry)
            CUDAnative.func_cache[$key] = $cuda_fun
        end
    end

    kernel_call = :( cudacall($cuda_fun, config[1], config[2],
                              $concrete_types, $(concrete_args...);
                              shmem_bytes=config[3]) )

    # Throw everything together
    exprs = Expr(:block)
    append!(exprs.args, kernel_compilation.args)
    push!(exprs.args, kernel_call)
    return exprs
end
