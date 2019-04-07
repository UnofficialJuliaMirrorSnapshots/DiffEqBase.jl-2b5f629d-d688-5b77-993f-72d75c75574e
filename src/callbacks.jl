# Necessary to have initialize set u_modified to false if all don't do anything
# otherwise unnecessary save
INITIALIZE_DEFAULT(cb,u,t,integrator) = u_modified!(integrator, false)

struct ContinuousCallback{F1,F2,F3,F4,T,T2,I} <: AbstractContinuousCallback
  condition::F1
  affect!::F2
  affect_neg!::F3
  initialize::F4
  idxs::I
  rootfind::Bool
  interp_points::Int
  save_positions::BitArray{1}
  abstol::T
  reltol::T2
  ContinuousCallback(condition::F1,affect!::F2,affect_neg!::F3,
                     initialize::F4,idxs::I,rootfind,
                     interp_points,save_positions,abstol::T,reltol::T2) where {F1,F2,F3,F4,T,T2,I} =
                       new{F1,F2,F3,F4,T,T2,I}(condition,
                                               affect!,affect_neg!,
                                               initialize,idxs,rootfind,interp_points,
                                               BitArray(collect(save_positions)),
                                               abstol,reltol)
end

ContinuousCallback(condition,affect!,affect_neg!;
                   initialize = INITIALIZE_DEFAULT,
                   idxs = nothing,
                   rootfind=true,
                   save_positions=(true,true),
                   interp_points=10,
                   abstol=10eps(),reltol=0) = ContinuousCallback(
                              condition,affect!,affect_neg!,initialize,
                              idxs,
                              rootfind,interp_points,
                              save_positions,abstol,reltol)

function ContinuousCallback(condition,affect!;
                   initialize = INITIALIZE_DEFAULT,
                   idxs = nothing,
                   rootfind=true,
                   save_positions=(true,true),
                   affect_neg! = affect!,
                   interp_points=10,
                   abstol=10eps(),reltol=0)

 ContinuousCallback(
            condition,affect!,affect_neg!,initialize,idxs,
            rootfind,interp_points,
            collect(save_positions),abstol,reltol)

end

struct DiscreteCallback{F1,F2,F3} <: AbstractDiscreteCallback
  condition::F1
  affect!::F2
  initialize::F3
  save_positions::BitArray{1}
  DiscreteCallback(condition::F1,affect!::F2,
                   initialize::F3,save_positions) where {F1,F2,F3} = new{F1,F2,F3}(condition,
                                                                                   affect!,initialize,
                                                                                   BitArray(collect(save_positions)))
end
DiscreteCallback(condition,affect!;
        initialize = INITIALIZE_DEFAULT,save_positions=(true,true)) = DiscreteCallback(condition,affect!,initialize,save_positions)

# DiscreteCallback(condition,affect!,save_positions) = DiscreteCallback(condition,affect!,save_positions)

struct CallbackSet{T1<:Tuple,T2<:Tuple} <: DECallback
  continuous_callbacks::T1
  discrete_callbacks::T2
end

CallbackSet(callback::AbstractDiscreteCallback) = CallbackSet((),(callback,))
CallbackSet(callback::AbstractContinuousCallback) = CallbackSet((callback,),())
CallbackSet() = CallbackSet((),())
CallbackSet(cb::Nothing) = CallbackSet()

# For Varargs, use recursion to make it type-stable
CallbackSet(callbacks::Union{DECallback,Nothing}...) = CallbackSet(split_callbacks((), (), callbacks...)...)

@inline split_callbacks(cs, ds) = cs, ds
@inline split_callbacks(cs, ds, c::Nothing, args...) = split_callbacks(cs, ds, args...)
@inline split_callbacks(cs, ds, c::AbstractContinuousCallback, args...) = split_callbacks((cs..., c), ds, args...)
@inline split_callbacks(cs, ds, d::AbstractDiscreteCallback, args...) = split_callbacks(cs, (ds..., d), args...)
@inline function split_callbacks(cs, ds, d::CallbackSet, args...)
  split_callbacks((cs...,d.continuous_callbacks...), (ds..., d.discrete_callbacks...), args...)
end

# Recursively apply initialize! and return whether any modified u
function initialize!(cb::CallbackSet,u,t,integrator::DEIntegrator)
  initialize!(u,t,integrator,false,cb.continuous_callbacks...,cb.discrete_callbacks...)
end
initialize!(cb::CallbackSet{Tuple{},Tuple{}},u,t,integrator::DEIntegrator) = false
function initialize!(u,t,integrator::DEIntegrator,any_modified::Bool,
                     c::DECallback,cs::DECallback...)
  c.initialize(c,u,t,integrator)
  initialize!(u,t,integrator,any_modified || integrator.u_modified,cs...)
end
function initialize!(u,t,integrator::DEIntegrator,any_modified::Bool,
                     c::DECallback)
  c.initialize(c,u,t,integrator)
  any_modified || integrator.u_modified
end

# Helpers
Base.isempty(cb::CallbackSet) = isempty(cb.continuous_callbacks) && isempty(cb.discrete_callbacks)
Base.isempty(cb::AbstractContinuousCallback) = false
Base.isempty(cb::AbstractDiscreteCallback) = false

#======================================================#
# Callback handling
#======================================================#

function get_tmp(integrator::DEIntegrator, callback)
  _tmp = get_tmp_cache(integrator)
  _tmp === nothing && return nothing
  _cache = first(_tmp)
  if callback.idxs isa Nothing
    tmp = _cache
  elseif !(callback.idxs isa Number)
    tmp = @view _cache[callback.idxs]
  else
    tmp = nothing
  end
  return tmp
end

function get_condition(integrator::DEIntegrator, callback, abst)
  tmp = get_tmp(integrator, callback)
  ismutable = !(tmp === nothing)
  ismutable && !(typeof(callback.idxs) isa Number) ? integrator(tmp,abst,Val{0},idxs=callback.idxs) :
                                                     tmp = integrator(abst,Val{0},idxs=callback.idxs)
  integrator.sol.destats.ncondition += 1
  return callback.condition(tmp,abst,integrator)
end

# Use Recursion to find the first callback for type-stability

# Base Case: Only one callback
function find_first_continuous_callback(integrator, callback::AbstractContinuousCallback)
  (find_callback_time(integrator,callback,1)...,1,1)
end

# Starting Case: Compute on the first callback
function find_first_continuous_callback(integrator, callback::AbstractContinuousCallback, args...)
  find_first_continuous_callback(integrator,find_callback_time(integrator,callback,1)...,1,1,args...)
end

function find_first_continuous_callback(integrator,tmin::Number,upcrossing::Number,
                                        event_occured::Bool,idx::Int,counter::Int,
                                        callback2)
  counter += 1 # counter is idx for callback2.
  tmin2,upcrossing2,event_occurred2 = find_callback_time(integrator,callback2,counter)

  if event_occurred2 && (tmin2 < tmin || !event_occured)
    return tmin2,upcrossing2,true,counter,counter
  else
    return tmin,upcrossing,event_occured,idx,counter
  end
end

function find_first_continuous_callback(integrator,tmin::Number,upcrossing::Number,event_occured::Bool,idx::Int,counter::Int,callback2,args...)
  find_first_continuous_callback(integrator,find_first_continuous_callback(integrator,tmin,upcrossing,event_occured,idx,counter,callback2)...,args...)
end

@inline function determine_event_occurance(integrator,callback,counter)
  event_occurred = false
  if callback.interp_points!=0
    addsteps!(integrator)
  end
  Θs = range(typeof(integrator.t)(0), stop=typeof(integrator.t)(1), length=callback.interp_points)
  interp_index = 0
  # Check if the event occured
  if typeof(callback.idxs) <: Nothing
    previous_condition = callback.condition(integrator.uprev,integrator.tprev,integrator)
  else
    @views previous_condition = callback.condition(integrator.uprev[callback.idxs],integrator.tprev,integrator)
  end
  integrator.sol.destats.ncondition += 1

  if integrator.event_last_time == counter && ODE_DEFAULT_NORM(previous_condition,integrator.t) < 100ODE_DEFAULT_NORM(integrator.last_event_error,integrator.t)

    # If there was a previous event, utilize the derivative at the start to
    # chose the previous sign. If the derivative is positive at tprev, then
    # we treat the value as positive, and derivative is negative then we
    # treat the value as negative, reguardless of the postiivity/negativity
    # of the true value due to it being =0 sans floating point issues.

    # Only due this if the discontinuity did not move it far away from an event
    # Since near even we use direction instead of location to reset

    if callback.interp_points==0
      addsteps!(integrator)
    end

    abst = integrator.tprev+sign(integrator.dt)*100*eps(integrator.tprev) # Evaluate condition slightly in future
    tmp_condition = get_condition(integrator, callback, abst)
    prev_sign = tmp_condition > previous_condition ? 1.0 : -1.0
  else
    prev_sign = sign(previous_condition)
  end

  prev_sign_index = 1
  if typeof(callback.idxs) <: Nothing
    next_sign = sign(callback.condition(integrator.u,integrator.t,integrator))
  else
    @views next_sign = sign(callback.condition(integrator.u[callback.idxs],integrator.t,integrator))
  end
  integrator.sol.destats.ncondition += 1

  if ((prev_sign<0 && !(typeof(callback.affect!)<:Nothing)) || (prev_sign>0 && !(typeof(callback.affect_neg!)<:Nothing))) && prev_sign*next_sign<=0
    event_occurred = true
    interp_index = callback.interp_points
  elseif callback.interp_points!=0 && !isdiscrete(integrator.alg) # Use the interpolants for safety checking
    for i in 2:length(Θs)
      abst = integrator.tprev+integrator.dt*Θs[i]
      new_sign = get_condition(integrator, callback, abst)
      if ((prev_sign<0 && !(typeof(callback.affect!)<:Nothing)) || (prev_sign>0 && !(typeof(callback.affect_neg!)<:Nothing))) && prev_sign*new_sign<0
        event_occurred = true
        interp_index = i
        break
      else
        prev_sign_index = i
      end
    end
  end

  event_occurred,interp_index,Θs,prev_sign,prev_sign_index
end

function find_callback_time(integrator,callback,counter)
  event_occurred,interp_index,Θs,prev_sign,prev_sign_index = determine_event_occurance(integrator,callback,counter)
  if event_occurred
    if typeof(callback.condition) <: Nothing
      new_t = zero(typeof(integrator.t))
    else
      if callback.interp_points!=0
        top_Θ = Θs[interp_index] # Top at the smallest
        bottom_θ = Θs[prev_sign_index]
      else
        top_Θ = typeof(integrator.t)(1)
        bottom_θ = typeof(integrator.t)(0)
      end
      if callback.rootfind && !isdiscrete(integrator.alg)
        zero_func = (Θ) -> begin
          abst = integrator.tprev+integrator.dt*Θ
          return get_condition(integrator, callback, abst)
        end
        if zero_func(top_Θ) == 0
          Θ = top_Θ
        else
          if integrator.event_last_time == counter &&
            abs(zero_func(bottom_θ)) < 100abs(integrator.last_event_error) &&
            prev_sign_index == 1

            # Determined that there is an event by derivative
            # But floating point error may make the end point negative

            sign_top = sign(zero_func(top_Θ))
            bottom_θ += 2eps(typeof(bottom_θ))
            iter = 1
            while sign(zero_func(bottom_θ)) == sign_top && iter < 12
              bottom_θ *= 5
              iter += 1
            end
            iter == 12 && error("Double callback crossing floating pointer reducer errored. Report this issue.")
          end
          Θ = prevfloat(find_zero(zero_func, (bottom_θ,top_Θ), Roots.AlefeldPotraShi(), atol = callback.abstol/100))
          integrator.last_event_error = ODE_DEFAULT_NORM(zero_func(Θ),integrator.t+integrator.dt*Θ)
        end
        #Θ = prevfloat(...)
        # prevfloat guerentees that the new time is either 1 floating point
        # numbers just before the event or directly at zero, but not after.
        # If there's a barrier which is never supposed to be crossed,
        # then this will ensure that
        # The item never leaves the domain. Otherwise Roots.jl can return
        # a float which is slightly after, making it out of the domain, causing
        # havoc.
        new_t = integrator.dt*Θ
      elseif interp_index != callback.interp_points && !isdiscrete(integrator.alg)
        new_t = integrator.dt*Θs[interp_index]
      else
        # If no solve and no interpolants, just use endpoint
        new_t = integrator.dt
      end
    end
  else
    new_t = zero(typeof(integrator.t))
  end

  new_t,prev_sign,event_occurred
end

function apply_callback!(integrator,callback::ContinuousCallback,cb_time,prev_sign)
  if cb_time == zero(typeof(integrator.t))
    error("Event repeated at the same time. Please report this error")
  end
  change_t_via_interpolation!(integrator,integrator.tprev+cb_time)

  # handle saveat
  _, savedexactly = savevalues!(integrator)
  saved_in_cb = true

  @inbounds if callback.save_positions[1]
    # if already saved then skip saving
    savedexactly || savevalues!(integrator,true)
  end

  integrator.u_modified = true

  if prev_sign < 0
    if typeof(callback.affect!) <: Nothing
      integrator.u_modified = false
    else
      callback.affect!(integrator)
    end
  elseif prev_sign > 0
    if typeof(callback.affect_neg!) <: Nothing
      integrator.u_modified = false
    else
      callback.affect_neg!(integrator)
    end
  end

  if integrator.u_modified
    reeval_internals_due_to_modification!(integrator)
    @inbounds if callback.save_positions[2]
      savevalues!(integrator,true)
      saved_in_cb = true
    end
    return true,saved_in_cb
  end
  false,saved_in_cb
end

#Base Case: Just one
@inline function apply_discrete_callback!(integrator,callback::DiscreteCallback)
  saved_in_cb = false
  if callback.condition(integrator.u,integrator.t,integrator)
    # handle saveat
    _, savedexactly = savevalues!(integrator)
    saved_in_cb = true
    @inbounds if callback.save_positions[1]
      # if already saved then skip saving
      savedexactly || savevalues!(integrator,true)
    end
    integrator.u_modified = true
    callback.affect!(integrator)
    @inbounds if callback.save_positions[2]
      savevalues!(integrator,true)
      saved_in_cb = true
    end
  end
  integrator.sol.destats.ncondition += 1
  integrator.u_modified,saved_in_cb
end

#Starting: Get bool from first and do next
@inline function apply_discrete_callback!(integrator,callback::DiscreteCallback,args...)
  apply_discrete_callback!(integrator,apply_discrete_callback!(integrator,callback)...,args...)
end

@inline function apply_discrete_callback!(integrator,discrete_modified::Bool,saved_in_cb::Bool,callback::DiscreteCallback,args...)
  bool,saved_in_cb2 = apply_discrete_callback!(integrator,apply_discrete_callback!(integrator,callback)...,args...)
  discrete_modified || bool, saved_in_cb || saved_in_cb2
end

@inline function apply_discrete_callback!(integrator,discrete_modified::Bool,saved_in_cb::Bool,callback::DiscreteCallback)
  bool,saved_in_cb2 = apply_discrete_callback!(integrator,callback)
  discrete_modified || bool, saved_in_cb || saved_in_cb2
end
