using LinearAlgebra, SparseArrays, SuiteSparse
mutable struct LinSolveFactorize{F}
  factorization::F
  A
end
LinSolveFactorize(factorization) = LinSolveFactorize(factorization,nothing)
function (p::LinSolveFactorize)(x,A,b,update_matrix=false;kwargs...)
  if update_matrix
    p.A = p.factorization(A)
  end
  if typeof(p.A) <: SuiteSparse.UMFPACK.UmfpackLU || typeof(p.factorization) <: typeof(lu)
    ldiv!(x,p.A,b) # No 2-arg form for SparseArrays!
  else
    x .= b
    ldiv!(p.A,x)
  end
end
function (p::LinSolveFactorize)(::Type{Val{:init}},f,u0_prototype)
  LinSolveFactorize(p.factorization,nothing)
end

### Default Linsolve

# Try to be as smart as possible
# lu! if Matrix
# lu if sparse
# gmres if operator

mutable struct DefaultLinSolve
  A
  iterable
end
DefaultLinSolve() = DefaultLinSolve(nothing, nothing)

function (p::DefaultLinSolve)(x,A,b,update_matrix=false;tol=nothing, kwargs...)
  if update_matrix
    if typeof(A) <: Matrix
      blasvendor = BLAS.vendor()
      if (blasvendor === :openblas || blasvendor === :openblas64) && size(A,1) <= 500 # if the user doesn't use OpenBLAS, we assume that is a much better BLAS implementation like MKL
        p.A = RecursiveFactorization.lu!(A)
      else
        p.A = lu!(A)
      end
    elseif typeof(A) <: SparseMatrixCSC
      p.A = factorize(A)
    elseif !(typeof(A) <: AbstractDiffEqOperator)
      # Most likely QR is the one that is overloaded
      # Works on things like CuArrays
      p.A = qr(A)
    end
  end

  if typeof(A) <: Matrix # No 2-arg form for SparseArrays!
    x .= b
    ldiv!(p.A,x)
  # Missing a little bit of efficiency in a rare case
  #elseif typeof(A) <: DiffEqArrayOperator
  #  ldiv!(x,p.A,b)
  elseif typeof(A) <: AbstractDiffEqOperator
    # No good starting guess, so guess zero
    if p.iterable === nothing
      p.iterable = IterativeSolvers.gmres_iterable!(x,A,b;initially_zero=true,restart=5,maxiter=5,tol=1e-16,kwargs...)
      p.iterable.reltol = tol
    end
    x .= false
    iter = p.iterable
    purge_history!(iter, x, b)

    for residual in iter
    end
  else
    ldiv!(x,p.A,b)
  end
  return nothing
end

function (p::DefaultLinSolve)(::Type{Val{:init}},f,u0_prototype)
  DefaultLinSolve()
end

const DEFAULT_LINSOLVE = DefaultLinSolve()

### Default GMRES

# Easily change to GMRES

mutable struct LinSolveGMRES{PL,PR,A}
  iterable
  Pl::PL
  Pr::PR
  kwargs::A
end
LinSolveGMRES(;Pl=IterativeSolvers.Identity(), Pr=IterativeSolvers.Identity(), kwargs...) = LinSolveGMRES(nothing, Pl, Pr, kwargs)

function (f::LinSolveGMRES)(x,A,b,update_matrix=false; Pl=nothing, Pr=nothing, tol=nothing, kwargs...)
  if f.iterable === nothing
    Pl = ComposePreconditioner(f.Pl, Pl, true)
    Pr = ComposePreconditioner(f.Pr, Pr, false)
    f.iterable = IterativeSolvers.gmres_iterable!(x,A,b;initially_zero=true,restart=5,maxiter=5,tol=1e-16,Pl=Pl,Pr=Pr,f.kwargs...,kwargs...)
    tol′ = get(f.kwargs, :tol, nothing)
    tol′ !== nothing && (tol = tol′)
    f.iterable.reltol = tol
  end
  x .= false
  iter = f.iterable
  purge_history!(iter, x, b)

  for residual in iter
  end
  return nothing
end

function (p::LinSolveGMRES)(::Type{Val{:init}},f,u0_prototype)
  LinSolveGMRES(nothing, p.Pl, p.Pr, p.kwargs)
end

# scaling for iterative solvers
struct ScaleVector{T}
  x::T
  isleft::Bool
end
function LinearAlgebra.ldiv!(v::ScaleVector, x)
  if v.isleft
    return @.. x = x * v.x
  else
    return @.. x = x / v.x
  end
end
function LinearAlgebra.ldiv!(y, v::ScaleVector, x)
  if v.isleft
    return @.. y = x * v.x
  else
    return @.. y = x / v.x
  end
end

struct ComposePreconditioner{P, S<:Union{ScaleVector,Nothing}}
  P::P
  scale::S
  isleft::Bool
end

function LinearAlgebra.ldiv!(v::ComposePreconditioner, x)
  isid = v.P isa IterativeSolvers.Identity
  isid || ldiv!(v.P, x)
  s = v.scale
  s === nothing && return x
  ldiv!(s, x)
  return x
end

function LinearAlgebra.ldiv!(y, v::ComposePreconditioner, x)
  isid = v.P isa IterativeSolvers.Identity
  isid || ldiv!(y, v.P, x)
  s = v.scale
  s === nothing && return x
  if isid
    ldiv!(y, s, x)
  else
    if v.isleft
      @.. y = y * s.x
    else
      @.. y = y / s.x
    end
  end
  return y
end

function purge_history!(iter::IterativeSolvers.GMRESIterable, x, b)
  iter.k = 1
  iter.x  = x
  iter.b  = b

  iter.residual.current = IterativeSolvers.init!(iter.arnoldi, iter.x, iter.b, iter.Pl, iter.Ax, initially_zero = true)
  IterativeSolvers.init_residual!(iter.residual, iter.residual.current)
  iter.β = iter.residual.current
  nothing
end
