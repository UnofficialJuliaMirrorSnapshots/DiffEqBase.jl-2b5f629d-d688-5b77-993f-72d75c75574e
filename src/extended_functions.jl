# Implements passing in Jacobians (and possibly other functions) via
# function overloading:
#
# - f(...) - objective function
# - f(Val{:jac}, ...) - Jacobian of objective function
# - the details of what `...` needs to be depends on the
#   AbstractODEProblem subtype

# Method_exists does not work:
#
# julia> f(::Val{:jac}, a, b, c) = 5
# f (generic function with 1 method)
#
# julia> hasmethod(f, Tuple{Val{:jac}, Vararg})
# false
#
# Thus hand-code it:
check_first_arg(f,T::Type) = check_first_arg(typeof(f),T)
function check_first_arg(::Type{F}, T::Type) where F
    typ = Tuple{Any, T, Vararg}
    typ2 = Tuple{Any, Type{T}, Vararg} # This one is required for overloaded types
    method_table = Base.MethodList(F.name.mt) # F.name.mt gets the method-table
    for m in method_table
        (m.sig<:typ || m.sig<:typ2) && return true
    end
    return false
end
# Standard
__has_jac(f) = check_first_arg(f, Val{:jac})
__has_tgrad(f) = check_first_arg(f, Val{:tgrad})

# Performance
__has_invW(f) = check_first_arg(f, Val{:invW})
__has_invW_t(f) = check_first_arg(f, Val{:invW_t})
has_invW(f::T) where {T} = istrait(HasInvW{T})
has_invW_t(f::T) where {T} = istrait(HasInvW_t{T})

# Parameter-Based
__has_paramderiv(f) = check_first_arg(f, Val{:deriv})
__has_paramjac(f) = check_first_arg(f, Val{:paramjac})

## Parameter Names Check
__has_syms(f) = isdefined(f, :syms)

## Analytical Solution Check
__has_analytic(f) = check_first_arg(f, Val{:analytic})
