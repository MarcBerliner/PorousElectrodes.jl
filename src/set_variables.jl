@inline function set_vars!(model::R1, p::R2, Y::R3, YP::R3, t::R4, run::R5, opts::R6, bounds::R7;
    modify!::R8=set_var!,
    init_all::Bool=false
    ) where {
        R1<:model_output,
        R2<:param,
        R3<:Vector{Float64},
        R4<:Float64,
        R5<:AbstractRun,
        R6<:options_model,
        R7<:boundary_stop_conditions,
        R8<:Function,
        }
    """
    Sets all the outputs for the model. There are three kinds of variable outputs:
    
    1. `keep.x = true`: The variable is calculated and saved on every iteration
    
    2. `keep.x = false` WITHOUT the check `if keep.x ... end`: These variables  MUST be
        calculated to ensure that `check_simulation_stop!` works properly (e.g., check if
        `V > V_max` or `SOC > SOC_max`), but they are not saved on every iteration
    
    3. `keep.x = false` WITH the check `if keep.x ... end`: These variables are not
        evaluated at all and may not even be calculable (e.g., `T` if there is no
        temperature enabled)
    """
    ind = p.ind
    keep = opts.var_keep

    # these variables must be calculated, but they may not necessarily be kept
    modify!(model.t,   (keep.t   || init_all), t + run.t0     )
    modify!(model.I,   (keep.I   || init_all), calc_I(Y, p)   )
    modify!(model.V,   (keep.V   || init_all), calc_V(Y, p)   )
    modify!(model.P,   (keep.P   || init_all), calc_P(Y, p)   )
    modify!(model.SOC, (keep.SOC || init_all), calc_SOC(Y, p) )
    
    # these variables do not need to be calculated
    if keep.YP      modify!(model.YP,      true, copy(YP)                        ) end
    if keep.c_e     modify!(model.c_e,     true, @views @inbounds Y[ind.c_e]     ) end
    if keep.c_s_avg modify!(model.c_s_avg, true, @views @inbounds Y[ind.c_s_avg] ) end
    if keep.j       modify!(model.j,       true, @views @inbounds Y[ind.j]       ) end
    if keep.Φ_e     modify!(model.Φ_e,     true, @views @inbounds Y[ind.Φ_e]     ) end
    if keep.Φ_s     modify!(model.Φ_s,     true, @views @inbounds Y[ind.Φ_s]     ) end
    
    # exist as an optional output if the model uses them
    if ( p.numerics.temperature === true           && keep.T    ) modify!(model.T,    true, @views @inbounds Y[ind.T]    ) end
    if ( p.numerics.aging === :SEI                 && keep.film ) modify!(model.film, true, @views @inbounds Y[ind.film] ) end
    if ( !(p.numerics.aging === false)             && keep.j_s  ) modify!(model.j_s,  true, @views @inbounds Y[ind.j_s]  ) end
    if ( p.numerics.solid_diffusion === :quadratic && keep.Q    ) modify!(model.Q,    true, @views @inbounds Y[ind.Q]    ) end

    return nothing
end

@inline function set_var!(x::T1, append::Bool, x_val::T2) where {T1<:Vector{Float64},T2<:Float64}
    append ? push!(x, x_val) : (@inbounds x[1] = x_val)
end
@inline function set_var!(x::T1, append::Bool, x_val::T2) where {T1<:VectorOfArray{Float64,2,Array{Array{Float64,1},1}},T2<:AbstractVector{Float64}}
    append ? push!(x, x_val) : (@inbounds x[1] .= x_val)
end

@inline function set_var_last!(x::T1, append, x_val::T2) where {T1<:Vector{Float64},T2<:Float64}
    @inbounds x[end] = x_val
end
@inline function set_var_last!(x::T1, append, x_val::T2) where {T1<:VectorOfArray{Float64,2,Array{Array{Float64,1},1}},T2<:AbstractVector{Float64}}
    @inbounds x[end] .= x_val
end

@inline function remove_last!(x::T, append, x_val) where {T<:AbstractArray}
    if append deleteat!(x, length(x)) end
end
@inline function remove_secondlast!(x::T, append, x_val) where {T<:AbstractArray}
    if append deleteat!(x, length(x)-1) end
end

@inline function interpolate_model(model::R1, tspan::T1, interp_bc::Symbol) where {R1<:model_output,T1<:Union{Number,AbstractVector}}
    dummy = similar(model.t)

    if tspan isa UnitRange
        t = collect(tspan)
    elseif tspan isa Real
        t = Float64[tspan]
    else
        t = tspan
    end

    f(x) = interpolate_variable(x, model, t, dummy, interp_bc)
    
    # collect all the variables for interpolation
    states_tot = Any[]
    @inbounds for field in fieldnames(model_output)
        if field === :t
            push!(states_tot, tspan)
        else
            x = getproperty(model, field)
            if x isa AbstractArray{Float64} && length(x) > 1
                push!(states_tot, f(x))
            else
                push!(states_tot, x)
            end
        end
        
    end

    model = R1(states_tot...)

    return model
end
@inline function interpolate_variable(x::R1, model::R2, tspan::T1, dummy::Vector{Float64}, interp_bc::Symbol) where {R1<:Vector{Float64},R2<:model_output,T1<:Union{Real,AbstractArray}}
    spl = Spline1D(model.t, x; bc = (interp_bc == :interpolate ? "nearest" : (interp_bc == :extrapolate ? "extrapolate" : error("Invalid interp_bc method."))))
    out = spl(tspan)
    
    return out
end
@inline function interpolate_variable(x::R1, model::R2, tspan::T1, dummy::Vector{Float64}, interp_bc::Symbol) where {R1<:Union{VectorOfArray{Float64,2,Array{Array{Float64,1},1}},Vector{Vector{Float64}}},R2<:model_output,T1<:Union{Real,AbstractArray}}
    @inbounds out = [copy(x[1]) for _ in tspan]

    @inbounds for i in eachindex(x[1])

        @inbounds for j in eachindex(x)
            @inbounds dummy[j] = x[j][i]
        end

        spl = Spline1D(model.t, dummy; bc = (interp_bc == :interpolate ? "nearest" : (interp_bc == :extrapolate ? "extrapolate" : error("Invalid interp_bc method."))))

        @inbounds for (j,t) in enumerate(tspan)
            @inbounds out[j][i] = spl(t)
        end

    end

    return VectorOfArray(out)
end