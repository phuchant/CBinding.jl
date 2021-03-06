

isanonymous(x) = isanonymous(typeof(x))
isanonymous(::Type) = false


abstract type Cstruct_anonymous <: Cstruct end
isanonymous(::Type{<:Cstruct_anonymous}) = true

abstract type Cunion_anonymous <: Cunion end
isanonymous(::Type{<:Cunion_anonymous}) = true


# <:Caggregate functions
function (::Type{CA})(init::Union{CA, Cconst{CA}, typeof(undef), typeof(zero)}; kwargs...) where {CA<:Caggregate}
	T = concrete(CA)
	result = T(undef)
	
	if init isa CA || init isa Cconst{CA}
		setfield!(result, :mem, getfield(init, :mem))
	elseif init isa typeof(zero)
		setfield!(result, :mem, map(init, getfield(result, :mem)))
	end
	
	T <: Cunion && length(kwargs) > 1 && error("Expected only a single keyword argument when constructing Cunion's")
	foreach(kwarg -> _initproperty!(result, kwarg...), kwargs)
	
	return result
end

function Base.read(io::IO, ::Type{CA}) where {CA<:Caggregate}
	result = CA(undef)
	setfield!(result, :mem, map(m -> read(io, typeof(m)), getfield(result, :mem)))
	return result
end

Base.zero(::Type{CA}) where {CA<:Caggregate} = CA(zero)
Base.convert(::Type{CA}, nt::NamedTuple) where {CA<:Caggregate} = CA(zero; nt...)
Base.isequal(x::CA, y::CA) where {CA<:Caggregate} = getfield(x, :mem) == getfield(y, :mem)
Base.:(==)(x::CA, y::CA) where {CA<:Caggregate} = isequal(x, y)

function Base.show(io::IO, ca::Union{Caggregate, Cconst{<:Caggregate}})
	if !(ca isa get(io, :typeinfo, Nothing))
		if ca isa Cconst
			print(io, typeof(ca).name, "(")
			show(io, nonconst(typeof(ca)))
		else
			show(io, typeof(ca))
		end
	end
	print(io, "(")
	for (ind, name) in enumerate(propertynames(typeof(ca)))
		print(io, ind > 1 ? ", " : "")
		print(io, name, "=")
		show(io, getproperty(ca, name))
	end
	print(io, ")")
	if !(ca isa get(io, :typeinfo, Nothing))
		ca isa Cconst && print(io, ")")
	end
end



macro cstruct(exprs...) return _caggregate(__module__, nothing, :cstruct, exprs...) end
macro cunion(exprs...) return _caggregate(__module__, nothing, :cunion, exprs...) end

function _caggregate(mod::Module, deps::Union{Vector{Pair{Symbol, Expr}}, Nothing}, kind::Symbol, name::Symbol)
	return _caggregate(mod, deps, kind, name, nothing, nothing)
end

function _caggregate(mod::Module, deps::Union{Vector{Pair{Symbol, Expr}}, Nothing}, kind::Symbol, body::Expr)
	return _caggregate(mod, deps, kind, nothing, body, nothing)
end

function _caggregate(mod::Module, deps::Union{Vector{Pair{Symbol, Expr}}, Nothing}, kind::Symbol, body::Expr, strategy::Symbol)
	return _caggregate(mod, deps, kind, nothing, body, strategy)
end

function _caggregate(mod::Module, deps::Union{Vector{Pair{Symbol, Expr}}, Nothing}, kind::Symbol, name::Union{Symbol, Expr, Nothing}, body::Union{Expr, Nothing})
	return _caggregate(mod, deps, kind, name, body, nothing)
end

# TODO:  need to handle unknown-length aggregates with last field like `char c[]`
function _caggregate(mod::Module, deps::Union{Vector{Pair{Symbol, Expr}}, Nothing}, kind::Symbol, name::Union{Symbol, Expr, Nothing}, body::Union{Expr, Nothing}, strategy::Union{Symbol, Nothing})
	isnothing(body) || Base.is_expr(body, :braces) || Base.is_expr(body, :bracescat) || error("Expected @$(kind) to have a `{ ... }` expression for the body of the type, but found `$(body)`")
	isnothing(body) && !isnothing(strategy) && error("Expected @$(kind) to have a body if alignment strategy is to be specified")
	isnothing(strategy) || (startswith(String(strategy), "__") && endswith(String(strategy), "__") && length(String(strategy)) > 4) || error("Expected @$(kind) to have packing specified as `__STRATEGY__`, such as `__packed__` or `__native__`")
	isnothing(name) || name isa Symbol || (Base.is_expr(name, :tuple, 1) && name.args[1] isa Symbol) || error("Expected @$(kind) to have a valid name")
	
	strategy = isnothing(strategy) ? :(ALIGN_NATIVE) : :(Calignment{$(QuoteNode(Symbol(String(strategy)[3:end-2])))})
	isanon = isnothing(name) || name isa Expr
	super = kind === :cunion ? (isanon ? :(Cunion_anonymous) : :(Cunion)) : (isanon ? :(Cstruct_anonymous) : :(Cstruct))
	name = isnothing(name) ? gensym("anonymous-$(kind)") : name isa Expr ? Symbol("($(name.args[1]))") : name
	escName = esc(name)
	concreteName = esc(gensym(name))
	
	isOuter = isnothing(deps)
	deps = isOuter ? Pair{Symbol, Expr}[] : deps
	if isnothing(body)
		push!(deps, name => quote
			abstract type $(escName) <: $(super) end
		end)
	else
		fields = []
		for arg in body.args
			arg = _expand(mod, deps, arg)
			if Base.is_expr(arg, :align, 1)
				align = arg.args[1]
				push!(fields, :(Calignment{$(align)}))
			else
				Base.is_expr(arg, :(::)) && length(arg.args) != 2 && error("Expected @$(kind) to have a `fieldName::FieldType` expression in the body of the type, but found `$(arg)`")
				
				arg = deepcopy(arg)
				argType = Base.is_expr(arg, :(::)) ? arg.args[end] : arg
				args = !Base.is_expr(arg, :(::)) ? nothing : arg.args[1]
				args = Base.is_expr(args, :tuple) ? args.args : (args,)
				for arg in args
					if isnothing(Base.is_expr(arg, :escape, 1) ? arg.args[1] : arg)
						push!(fields, :(Ctypespec($(argType))))
					elseif Base.is_expr(arg, :call, 3) && (Base.is_expr(arg.args[1], :escape, 1) ? arg.args[1].args[1] : arg.args[1]) === :(:) && arg.args[3] isa Integer
						push!(fields, :(Pair{$(QuoteNode(Base.is_expr(arg.args[2], :escape, 1) ? arg.args[2].args[1] : arg.args[2])), Ctypespec($(argType), Val($(arg.args[3])))}))
					else
						_augment(arg, argType)
						
						(aname, atype) = Base.is_expr(arg, :(::), 2) ? arg.args : (arg, argType)
						aname = Base.is_expr(aname, :escape, 1) ? aname.args[1] : aname
						push!(fields, :(Pair{$(QuoteNode(aname)), Ctypespec($(atype))}))
					end
				end
			end
		end
		
		push!(deps, name => quote
			abstract type $(escName) <: $(super) end
			mutable struct $(concreteName) <: $(escName)
				mem::NTuple{Ctypelayout(Ctypespec($(super), $(strategy), Tuple{$(fields...)})).size÷8, UInt8}
				
				$(concreteName)(::UndefInitializer) = new()
			end
			#=
				TypeSpec = Tuple{
					Pair{:sym1, Tuple{PrimType}},  # primitive field `sym1`
					Pair{:sym2, Tuple{PrimType, NBits}},  # bit field `sym2`
					Pair{:sym3, Ctypespec{FieldType, AggType, AggStrategy, AggTypeSpec}}},  # nested aggregate `sym3`
					Ctypespec{FieldType, AggType, AggStrategy, AggTypeSpec}},  # anonymous nested aggregate
					Calignment{align}  # alignment "field"
				}
			=#
			CBinding.concrete(::Type{$(escName)}) = $(concreteName)
			CBinding.concrete(::Type{$(concreteName)}) = $(concreteName)
			CBinding.strategy(::Type{$(concreteName)}) = $(strategy)
			CBinding.specification(::Type{$(concreteName)})  = Tuple{$(fields...)}
			Base.sizeof(::Type{$(escName)}) = sizeof(CBinding.concrete($(concreteName)))
		end)
	end
	
	return isOuter ? quote $(map(last, deps)...) ; $(escName) end : escName
end

