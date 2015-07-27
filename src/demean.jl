
##############################################################################
##
## Fe and FixedEffectSlope
##
##############################################################################
abstract AbstractFixedEffect 

type FixedEffectIntercept{R, W <: AbstractVector{Float64}} <: AbstractFixedEffect
	refs::Vector{R}        # Refs corresponding to the refs field of the original PooledDataVector
	w::W 				   # weights
	scale::Vector{Float64} # 1/(sum of scale) within each group
	name::Symbol           # Name of variable in the original dataframe
	id::Symbol
end

type FixedEffectSlope{R, W <: AbstractVector{Float64}} <: AbstractFixedEffect
	refs::Vector{R}              # Refs corresponding to the refs field of the original PooledDataVector
	w::W           				 # weights
	scale::Vector{Float64}       # 1/(sum of weights * x) for each group
	interaction::Vector{Float64} # the continuous interaction 
	name::Symbol                 # Name of factor variable in the original dataframe
	interactionname::Symbol      # Name of continuous variable in the original dataframe
	id::Symbol
end


function FixedEffectIntercept{R}(f::PooledDataVector{R}, w::AbstractVector{Float64}, name::Symbol, id::Symbol)
	scale = fill(zero(Float64), length(f.pool))
	refs = f.refs
	@inbounds @simd  for i in 1:length(refs)
		scale[refs[i]] += abs2(w[i])
	end
	@inbounds @simd  for i in 1:length(scale)
		scale[i] = scale[i] > 0 ? (one(Float64) / scale[i]) : zero(Float64)
	end
	FixedEffectIntercept(refs, w, scale, name, id)
end

function FixedEffectSlope{R}(f::PooledDataVector{R}, w::AbstractVector{Float64}, interaction::Vector{Float64}, name::Symbol, interactionname::Symbol, id::Symbol)
	scale = fill(zero(Float64), length(f.pool))
	refs = f.refs
	@inbounds @simd for i in 1:length(refs)
		 scale[refs[i]] += abs2((interaction[i] * w[i]))
	end
	@inbounds @simd for i in 1:length(scale)
		scale[i] = scale[i] > 0 ? (one(Float64) / scale[i]) : zero(Float64)
	end
	FixedEffectSlope(refs, w, scale, interaction, name, interactionname, id)
end

function FixedEffect(df::AbstractDataFrame, a::Expr, w::AbstractVector{Float64})
	if a.args[1] == :&
		id = convert(Symbol, "$(a.args[2])x$(a.args[3])")
		if (typeof(df[a.args[2]]) <: PooledDataVector) && !(typeof(df[a.args[3]]) <: PooledDataVector)
			f = df[a.args[2]]
			x = convert(Vector{Float64}, df[a.args[3]])
			return FixedEffectSlope(f, w, x, a.args[2], a.args[3], id)
		elseif (typeof(df[a.args[3]]) <: PooledDataVector) && !(typeof(df[a.args[2]]) <: PooledDataVector)
			f = df[a.args[3]]
			x = convert(Vector{Float64}, df[a.args[2]])
			return FixedEffectSlope(f, w, x, a.args[3], a.args[2], id)
		else
			error("& is not of the form factor & nonfactor")
		end
	else
		error("Formula should be composed of & and symbols")
	end
end

function FixedEffect(df::AbstractDataFrame, a::Symbol, w::AbstractVector{Float64})
	if typeof(df[a]) <: PooledDataVector
		return FixedEffectIntercept(df[a], w, a, a)
	else
		error("$(a) is not a pooled data array")
	end
end




##############################################################################
##
## Demean algorithm
##
##############################################################################

# Algorithm from lfe: http://cran.r-project.org/web/packages/lfe/vignettes/lfehow.pdf

function demean_factor!{R, W}(x::Vector{Float64}, fe::FixedEffectIntercept{R, W}, means::Vector{Float64})
	scale = fe.scale ; refs = fe.refs ; w = fe.w
	@inbounds @simd for i in 1:length(x)
		 means[refs[i]] += x[i] * w[i]
	end
	@inbounds @simd for i in 1:length(scale)
		 means[i] *= scale[i] 
	end
	@inbounds @simd for i in 1:length(x)
		 x[i] -= means[refs[i]] * w[i]
	end
end

function demean_factor!{R, W}(x::Vector{Float64}, fe::FixedEffectSlope{R, W}, means::Vector{Float64})
	scale = fe.scale ; refs = fe.refs ; interaction = fe.interaction ; w = fe.w
	@inbounds @simd for i in 1:length(x)
		 means[refs[i]] += x[i] * interaction[i] * w[i]
	end
	@inbounds @simd for i in 1:length(scale)
		 means[i] *= scale[i] 
	end
	@inbounds @simd for i in 1:length(x)
		 x[i] -= means[refs[i]] * interaction[i] * w[i]
	end
end

function demean!(x::Vector{Float64}, iterationsv::Vector{Int}, convergedv::Vector{Bool},  fes::Vector{AbstractFixedEffect}; maxiter::Int = 1000, tol::Float64 = 1e-8)
	# allocate array of means for each factor
	dict = Dict{AbstractFixedEffect, Vector{Float64}}()
	for fe in fes
		dict[fe] = zeros(Float64, length(fe.scale))
	end
	iterations = maxiter
	converged = false
	if length(fes) == 1 && typeof(fes[1]) <: FixedEffectIntercept
		converged = true
		iterations = 1
		maxiter = 1
	end
	delta = 1.0
	olx = similar(x)
	for iter in 1:maxiter
		@inbounds @simd for i in 1:length(x)
			olx[i] = x[i]
		end
		for fe in fes
			means = dict[fe]
			fill!(means, zero(Float64))
			demean_factor!(x, fe, means)
		end
		delta = chebyshev(x, olx)
		if delta < tol
			converged = true
			iterations = iter
			break
		end
	end
	push!(iterationsv, iterations)
	push!(convergedv, converged)
	return x
end

function demean!(X::Matrix{Float64}, iterations::Vector{Int}, converged::Vector{Bool}, fes::Vector{AbstractFixedEffect}; maxiter::Int = 1000, tol::Float64 = 1e-8)
	for j in 1:size(X, 2)
		X[:, j] = demean!(X[:, j], iterations, converged, fes, maxiter = maxiter, tol = tol)
	end
end

demean!(X::Array, iterations::Vector{Int}, converged::Vector{Bool}, fes::Nothing; maxiter::Int = 1000, tol::Float64 = 1e-8) = nothing


function demean(x::DataVector{Float64}, fes::Vector{AbstractFixedEffect}; maxiter::Int = 1000, tol::Float64 = 1e-8)
	X = convert(Vector{Float64}, x)
	iterations = Int[]
	converged = Bool[]
	demean!(X, iterations, converged, fes, maxiter = maxiter, tol = tol)
	return X, iterations, converged
end
