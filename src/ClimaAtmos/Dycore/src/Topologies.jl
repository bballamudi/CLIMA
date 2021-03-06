module Topologies

export AbstractTopology, AbstractStackedTopology
export BrickTopology, StackedBrickTopology
export CubedShellTopology, StackedCubedSphereTopology

import Canary
using MPI
abstract type AbstractTopology{dim} end
abstract type AbstractStackedTopology{dim} <: AbstractTopology{dim} end

"""
    BrickTopology{dim, T}(mpicomm, elemrange; boundary, periodicity)

Generate a brick mesh topology with coordinates given by the tuple `elemrange`
and the periodic dimensions given by the `periodicity` tuple.

The elements of the brick are partitioned equally across the MPI ranks based
on a space-filling curve.

By default boundary faces will be marked with a one and other faces with a
zero.  Specific boundary numbers can also be passed for each face of the brick
in `boundary`.  This will mark the nonperiodic brick faces with the given
boundary number.

# Examples

We can build a 3 by 2 element two-dimensional mesh that is periodic in the
\$x_2\$-direction with
```jldoctest brickmesh

using CLIMAAtmosDycore
using CLIMAAtmosDycore.Topologies
using MPI
MPI.Init()
topology = BrickTopology(MPI.COMM_SELF, (2:5,4:6);
                         periodicity=(false,true),
                         boundary=[1 3; 2 4])
MPI.Finalize()
```
This returns the mesh structure for

             x_2

              ^
              |
             6-  +-----+-----+-----+
              |  |     |     |     |
              |  |  3  |  4  |  5  |
              |  |     |     |     |
             5-  +-----+-----+-----+
              |  |     |     |     |
              |  |  1  |  2  |  6  |
              |  |     |     |     |
             4-  +-----+-----+-----+
              |
              +--|-----|-----|-----|--> x_1
                 2     3     4     5

For example, the (dimension by number of corners by number of elements) array
`elemtocoord` gives the coordinates of the corners of each element.
```jldoctes brickmesh
julia> topology.elemtocoord
2×4×6 Array{Int64,3}:
[:, :, 1] =
 2  3  2  3
 4  4  5  5

[:, :, 2] =
 3  4  3  4
 4  4  5  5

[:, :, 3] =
 2  3  2  3
 5  5  6  6

[:, :, 4] =
 3  4  3  4
 5  5  6  6

[:, :, 5] =
 4  5  4  5
 5  5  6  6

[:, :, 6] =
 4  5  4  5
 4  4  5  5
```
Note that the corners are listed in Cartesian order.

The (number of faces by number of elements) array `elemtobndy` gives the
boundary number for each face of each element.  A zero will be given for
connected faces.
```jldoctest brickmesh
julia> topology.elemtobndy
4×6 Array{Int64,2}:
 1  0  1  0  0  0
 0  0  0  0  2  2
 0  0  0  0  0  0
 0  0  0  0  0  0
```
Note that the faces are listed in Cartesian order.

!!! todo

    We may/probably want to unify to a single Topology type which has different
    constructors since all the topologies we currently have are essentially the
    same

"""
struct BrickTopology{dim, T} <: AbstractTopology{dim}
  """
  mpi communicator use for spatial discretization are using
  """
  mpicomm::MPI.Comm

  """
  range of element indices
  """
  elems::UnitRange{Int64}

  """
  range of real (aka nonghost) element indices
  """
  realelems::UnitRange{Int64}

  """
  range of ghost element indices
  """
  ghostelems::UnitRange{Int64}

  """
  array of send element indices sorted so that
  """
  sendelems::Array{Int64, 1}

  """
  element to vertex coordinates

  `elemtocoord[d,i,e]` is the `d`th coordinate of corner `i` of element `e`

  !!! note
  currently coordinates always are of size 3 for `(x, y, z)`
  """
  elemtocoord::Array{T, 3}

  """
  element to neighboring element; `elemtoelem[f,e]` is the number of the element
  neighboring element `e` across face `f`.  If there is no neighboring element
  then `elemtoelem[f,e] == e`.
  """
  elemtoelem::Array{Int64, 2}

  """
  element to neighboring element face; `elemtoface[f,e]` is the face number of
  the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoface[f,e] == f`."
  """
  elemtoface::Array{Int64, 2}

  """
  element to neighboring element order; `elemtoordr[f,e]` is the ordering number
  of the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoordr[f,e] == 1`.
  """
  elemtoordr::Array{Int64, 2}

  """
  element to bounday number; `elemtobndy[f,e]` is the boundary number of face
  `f` of element `e`.  If there is a neighboring element then `elemtobndy[f,e]
  == 0`.
  """
  elemtobndy::Array{Int64, 2}

  """
  list of the MPI ranks for the neighboring processes
  """
  nabrtorank::Array{Int64, 1}

  """
  range in ghost elements to receive for each neighbor
  """
  nabrtorecv::Array{UnitRange{Int64}, 1}

  """
  range in `sendelems` to send for each neighbor
  """
  nabrtosend::Array{UnitRange{Int64}, 1}

  BrickTopology(mpicomm, Nelems::NTuple{N, Integer}; kw...) where N =
  BrickTopology(mpicomm, map(Ne->0:Ne, Nelems); kw...)

  function BrickTopology(mpicomm, elemrange;
                         boundary=ones(Int,2,length(elemrange)),
                         periodicity=ntuple(j->false, length(elemrange)),
                         connectivity=:face, ghostsize=1)

    # We cannot handle anything else right now...
    @assert connectivity == :face
    @assert ghostsize == 1

    mpirank = MPI.Comm_rank(mpicomm)
    mpisize = MPI.Comm_size(mpicomm)
    topology = Canary.brickmesh(elemrange, periodicity, part=mpirank+1,
                                numparts=mpisize, boundary=boundary)
    topology = Canary.partition(mpicomm, topology...)
    topology = Canary.connectmesh(mpicomm, topology...)

    dim = length(elemrange)
    T = eltype(topology.elemtocoord)
    new{dim, T}(mpicomm, topology.elems, topology.realelems,
                topology.ghostelems, topology.sendelems, topology.elemtocoord,
                topology.elemtoelem, topology.elemtoface, topology.elemtoordr,
                topology.elemtobndy, topology.nabrtorank, topology.nabrtorecv,
                topology.nabrtosend)
  end
end

"""
    StackedBrickTopology{dim, T}(mpicomm, elemrange; boundary, periodicity)

Generate a stacked brick mesh topology with coordinates given by the tuple
`elemrange` and the periodic dimensions given by the `periodicity` tuple.

The elements are stacked such that the elements associated with range
`elemrange[dim]` are contiguous in the element ordering.

The elements of the brick are partitioned equally across the MPI ranks based
on a space-filling curve.  Further, stacks are not split at MPI boundaries.

By default boundary faces will be marked with a one and other faces with a
zero.  Specific boundary numbers can also be passed for each face of the brick
in `boundary`.  This will mark the nonperiodic brick faces with the given
boundary number.

# Examples

We can build a 3 by 2 element two-dimensional mesh that is periodic in the
\$x_2\$-direction with
```jldoctest brickmesh

using CLIMAAtmosDycore
using CLIMAAtmosDycore.Topologies
using MPI
MPI.Init()
topology = StackedBrickTopology(MPI.COMM_SELF, (2:5,4:6);
                                periodicity=(false,true),
                                boundary=[1 3; 2 4])
MPI.Finalize()
```
This returns the mesh structure stacked in the \$x_2\$-direction for

             x_2

              ^
              |
             6-  +-----+-----+-----+
              |  |     |     |     |
              |  |  2  |  4  |  6  |
              |  |     |     |     |
             5-  +-----+-----+-----+
              |  |     |     |     |
              |  |  1  |  3  |  5  |
              |  |     |     |     |
             4-  +-----+-----+-----+
              |
              +--|-----|-----|-----|--> x_1
                 2     3     4     5

For example, the (dimension by number of corners by number of elements) array
`elemtocoord` gives the coordinates of the corners of each element.
```jldoctes brickmesh
julia> topology.elemtocoord
2×4×6 Array{Int64,3}:
[:, :, 1] =
 2  3  2  3
 4  4  5  5

[:, :, 2] =
 2  3  2  3
 5  5  6  6

[:, :, 3] =
 3  4  3  4
 4  4  5  5

[:, :, 4] =
 3  4  3  4
 5  5  6  6

[:, :, 5] =
 4  5  4  5
 4  4  5  5

[:, :, 6] =
 4  5  4  5
 5  5  6  6
```
Note that the corners are listed in Cartesian order.

The (number of faces by number of elements) array `elemtobndy` gives the
boundary number for each face of each element.  A zero will be given for
connected faces.
```jldoctest brickmesh
julia> topology.elemtobndy
4×6 Array{Int64,2}:
 1  0  1  0  0  0
 0  0  0  0  2  2
 0  0  0  0  0  0
 0  0  0  0  0  0
```
Note that the faces are listed in Cartesian order.
"""

struct StackedBrickTopology{dim, T} <: AbstractStackedTopology{dim}
  """
  mpi communicator use for spatial discretization are using
  """
  mpicomm::MPI.Comm

  """
  number of elements in a stack
  """
  stacksize::Int64

  """
  range of element indices
  """
  elems::UnitRange{Int64}

  """
  range of real (aka nonghost) element indices
  """
  realelems::UnitRange{Int64}

  """
  range of ghost element indices
  """
  ghostelems::UnitRange{Int64}

  """
  array of send element indices sorted so that
  """
  sendelems::Array{Int64, 1}

  """
  element to vertex coordinates

  `elemtocoord[d,i,e]` is the `d`th coordinate of corner `i` of element `e`

  !!! note
  currently coordinates always are of size 3 for `(x, y, z)`
  """
  elemtocoord::Array{T, 3}

  """
  element to neighboring element; `elemtoelem[f,e]` is the number of the element
  neighboring element `e` across face `f`.  If there is no neighboring element
  then `elemtoelem[f,e] == e`.
  """
  elemtoelem::Array{Int64, 2}

  """
  element to neighboring element face; `elemtoface[f,e]` is the face number of
  the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoface[f,e] == f`."
  """
  elemtoface::Array{Int64, 2}

  """
  element to neighboring element order; `elemtoordr[f,e]` is the ordering number
  of the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoordr[f,e] == 1`.
  """
  elemtoordr::Array{Int64, 2}

  """
  element to bounday number; `elemtobndy[f,e]` is the boundary number of face
  `f` of element `e`.  If there is a neighboring element then `elemtobndy[f,e]
  == 0`.
  """
  elemtobndy::Array{Int64, 2}

  """
  list of the MPI ranks for the neighboring processes
  """
  nabrtorank::Array{Int64, 1}

  """
  range in ghost elements to receive for each neighbor
  """
  nabrtorecv::Array{UnitRange{Int64}, 1}

  """
  range in `sendelems` to send for each neighbor
  """
  nabrtosend::Array{UnitRange{Int64}, 1}

  StackedBrickTopology(mpicomm, Nelems::NTuple{N, Integer}; kw...) where N =
  StackedBrickTopology(mpicomm, map(Ne->0:Ne, Nelems); kw...)

  function StackedBrickTopology(mpicomm, elemrange;
                         boundary=ones(Int,2,length(elemrange)),
                         periodicity=ntuple(j->false, length(elemrange)),
                         connectivity=:face, ghostsize=1)


    dim = length(elemrange)

    dim <= 1 && error("Stacked brick topology works for 2D and 3D")

    # Build the base topology
    basetopo = BrickTopology(mpicomm, elemrange[1:dim-1];
                       boundary=boundary[:,1:dim-1],
                       periodicity=periodicity[1:dim-1],
                       connectivity=connectivity,
                       ghostsize=ghostsize)


    # Use the base topology to build the stacked topology
    stack = elemrange[dim]
    stacksize = length(stack) - 1

    nvert = 2^dim
    nface = 2dim

    nreal = length(basetopo.realelems)*stacksize
    nghost = length(basetopo.ghostelems)*stacksize

    elems=1:(nreal+nghost)
    realelems=1:nreal
    ghostelems=nreal.+(1:nghost)

    sendelems = similar(basetopo.sendelems,
                        length(basetopo.sendelems)*stacksize)
    for i=1:length(basetopo.sendelems), j=1:stacksize
      sendelems[stacksize*(i-1) + j] = stacksize*(basetopo.sendelems[i]-1) + j
    end

    elemtocoord = similar(basetopo.elemtocoord, dim, nvert, length(elems))

    for i=1:length(basetopo.elems), j=1:stacksize
      e = stacksize*(i-1) + j

      for v = 1:2^(dim-1)
        for d = 1:(dim-1)
          elemtocoord[d, v, e] = basetopo.elemtocoord[d, v, i]
          elemtocoord[d, 2^(dim-1) + v, e] = basetopo.elemtocoord[d, v, i]
        end

        elemtocoord[dim, v, e] = stack[j]
        elemtocoord[dim, 2^(dim-1) + v, e] = stack[j+1]
      end
    end

    elemtoelem = similar(basetopo.elemtoelem, nface, length(elems))
    elemtoface = similar(basetopo.elemtoface, nface, length(elems))
    elemtoordr = similar(basetopo.elemtoordr, nface, length(elems))
    elemtobndy = similar(basetopo.elemtobndy, nface, length(elems))

    for e=1:length(basetopo.elems)*stacksize, f=1:nface
      elemtoelem[f, e] = e
      elemtoface[f, e] = f
      elemtoordr[f, e] = 1
      elemtobndy[f, e] = 0
    end

    for i=1:length(basetopo.realelems), j=1:stacksize
      e1 = stacksize*(i-1) + j

      for f = 1:2(dim-1)
        e2 = stacksize*(basetopo.elemtoelem[f, i]-1) + j

        elemtoelem[f, e1] = e2
        elemtoface[f, e1] = basetopo.elemtoface[f, i]

        # We assume a simple orientation right now
        @assert basetopo.elemtoordr[f, i] == 1
        elemtoordr[f, e1] = basetopo.elemtoordr[f, i]
      end

      et = stacksize*(i-1) + j + 1
      eb = stacksize*(i-1) + j - 1
      ft = 2(dim-1) + 1
      fb = 2(dim-1) + 2
      ot = 1
      ob = 1

      if j == stacksize
        et = periodicity[dim] ? stacksize*(i-1) + 1 : e1
        ft = periodicity[dim] ? ft : 2(dim-1) + 2
      elseif j == 1
        eb = periodicity[dim] ? stacksize*(i-1) + stacksize : e1
        fb = periodicity[dim] ? fb : 2(dim-1) + 1
      end

      elemtoelem[2(dim-1)+1, e1] = eb
      elemtoelem[2(dim-1)+2, e1] = et
      elemtoface[2(dim-1)+1, e1] = fb
      elemtoface[2(dim-1)+2, e1] = ft
      elemtoordr[2(dim-1)+1, e1] = ob
      elemtoordr[2(dim-1)+2, e1] = ot
    end

    for i=1:length(basetopo.elems), j=1:stacksize
      e1 = stacksize*(i-1) + j

      for f = 1:2(dim-1)
        elemtobndy[f, e1] = basetopo.elemtobndy[f, i]
      end

      bt = bb = 0

      if j == stacksize
        bt = periodicity[dim] ? bt : boundary[2,dim]
      elseif j == 1
        bb = periodicity[dim] ? bb : boundary[1,dim]
      end

      elemtobndy[2(dim-1)+1, e1] = bb
      elemtobndy[2(dim-1)+2, e1] = bt
    end

    nabrtorank = basetopo.nabrtorank
    nabrtorecv =
      UnitRange{Int}[UnitRange(stacksize*(first(basetopo.nabrtorecv[n])-1)+1,
                               stacksize*last(basetopo.nabrtorecv[n]))
                     for n = 1:length(nabrtorank)]
    nabrtosend =
      UnitRange{Int}[UnitRange(stacksize*(first(basetopo.nabrtosend[n])-1)+1,
                               stacksize*last(basetopo.nabrtosend[n]))
                     for n = 1:length(nabrtorank)]

    T = eltype(basetopo.elemtocoord)
    new{dim, T}(mpicomm, stacksize, elems, realelems, ghostelems, sendelems,
                elemtocoord, elemtoelem, elemtoface, elemtoordr, elemtobndy,
                nabrtorank, nabrtorecv, nabrtosend)
  end
end

"""
    CubedShellTopology{T}(mpicomm, Nelem) <: AbstractTopology{2}

Generate a cubed shell mesh with the number of elements along each dimension of
the cubes being `Nelem`. This topology actual creates a cube mesh, and the
warping should be done after the grid is created using the `cubedshellwarp`
function. The coordinates of the points will be of type `T`.

The elements of the shell are partitioned equally across the MPI ranks based
on a space-filling curve.

Note that this topology is logically 2-D but embedded in a 3-D space

# Examples

We can build a cubed shell mesh with 10 elements on each cube, total elements is
`10 * 10 * 6 = 600`, with
```jldoctest brickmesh
using CLIMAAtmosDycore
using CLIMAAtmosDycore.Topologies
using MPI
MPI.Init()
topology = CubedShellTopology{Float64}(MPI.COMM_SELF, 10)

# Typically the warping would be done after the grid is created, but the cell
# corners could be warped with...

# Shell radius = 1
x, y, z = ntuple(j->topology.elemtocoord[j, :, :], 3)
for n = 1:length(x)
   x[n], y[n], z[n] = Topologies.cubedshellwarp(x[n], y[n], z[n])
end

# Shell radius = 10
x, y, z = ntuple(j->topology.elemtocoord[j, :, :], 3)
for n = 1:length(x)
  x[n], y[n], z[n] = Topologies.cubedshellwarp(x[n], y[n], z[n], 10)
end

MPI.Finalize()
```
"""
struct CubedShellTopology{T} <: AbstractTopology{2}
  """
  mpi communicator use for spatial discretization are using
  """
  mpicomm::MPI.Comm

  """
  range of element indices
  """
  elems::UnitRange{Int64}

  """
  range of real (aka nonghost) element indices
  """
  realelems::UnitRange{Int64}

  """
  range of ghost element indices
  """
  ghostelems::UnitRange{Int64}

  """
  array of send element indices sorted so that
  """
  sendelems::Array{Int64, 1}

  """
  element to vertex coordinates

  `elemtocoord[d,i,e]` is the `d`th coordinate of corner `i` of element `e`

  !!! note
  currently coordinates always are of size 3 for `(x, y, z)`
  """
  elemtocoord::Array{T, 3}

  """
  element to neighboring element; `elemtoelem[f,e]` is the number of the element
  neighboring element `e` across face `f`.  If there is no neighboring element
  then `elemtoelem[f,e] == e`.
  """
  elemtoelem::Array{Int64, 2}

  """
  element to neighboring element face; `elemtoface[f,e]` is the face number of
  the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoface[f,e] == f`."
  """
  elemtoface::Array{Int64, 2}

  """
  element to neighboring element order; `elemtoordr[f,e]` is the ordering number
  of the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoordr[f,e] == 1`.
  """
  elemtoordr::Array{Int64, 2}

  """
  element to bounday number; `elemtobndy[f,e]` is the boundary number of face
  `f` of element `e`.  If there is a neighboring element then `elemtobndy[f,e]
  == 0`.
  """
  elemtobndy::Array{Int64, 2}

  """
  list of the MPI ranks for the neighboring processes
  """
  nabrtorank::Array{Int64, 1}

  """
  range in ghost elements to receive for each neighbor
  """
  nabrtorecv::Array{UnitRange{Int64}, 1}

  """
  range in `sendelems` to send for each neighbor
  """
  nabrtosend::Array{UnitRange{Int64}, 1}


  function CubedShellTopology{T}(mpicomm, Neside; connectivity=:face,
                                 ghostsize=1) where T

    # We cannot handle anything else right now...
    @assert connectivity == :face
    @assert ghostsize == 1

    mpirank = MPI.Comm_rank(mpicomm)
    mpisize = MPI.Comm_size(mpicomm)

    topology = cubedshellmesh(Neside, part=mpirank+1, numparts=mpisize)

    topology = Canary.partition(mpicomm, topology...)

    dim, nvert = 3, 4
    elemtovert = topology[1]
    nelem = size(elemtovert, 2)
    elemtocoord = Array{T}(undef, dim, nvert, nelem)
    ind2vert = CartesianIndices((Neside+1, Neside+1, Neside+1))
    for e in 1:nelem
      for n = 1:nvert
        v = elemtovert[n, e]
        i, j, k = Tuple(ind2vert[v])
        elemtocoord[:, n, e] = (2*[i-1, j-1, k-1] .- Neside) / Neside
      end
    end

    topology = Canary.connectmesh(mpicomm, topology[1], elemtocoord, topology[3],
                                  topology[4]; dim = 2)

    new{T}(mpicomm, topology.elems, topology.realelems,
           topology.ghostelems, topology.sendelems, elemtocoord,
           topology.elemtoelem, topology.elemtoface, topology.elemtoordr,
           topology.elemtobndy, topology.nabrtorank, topology.nabrtorecv,
           topology.nabrtosend)
  end
end

"""
    cubedshellmesh(T, Ne; part=1, numparts=1)

Generate a cubed mesh with each of the "cubes" has an `Ne X Ne` grid of elements.

The mesh can optionally be partitioned into `numparts` and this returns
partition `part`.  This is a simple Cartesian partition and further partitioning
(e.g, based on a space-filling curve) should be done before the mesh is used for
computation.

This mesh returns the cubed spehere in a flatten fashion for the vertex values,
and a remapping is needed to embed the mesh in a 3-D space.

The mesh structures for the cubes is as follows:

```
x_2
   ^
   |
4Ne-           +-------+
   |           |       |
   |           |   6   |
   |           |       |
3Ne-           +-------+
   |           |       |
   |           |   5   |
   |           |       |
2Ne-           +-------+
   |           |       |
   |           |   4   |
   |           |       |
 Ne-   +-------+-------+-------+
   |   |       |       |       |
   |   |   1   |   2   |   3   |
   |   |       |       |       |
  0-   +-------+-------+-------+
   |
   +---|-------|-------|------|-> x_1
       0      Ne      2Ne    3Ne
```

"""
function cubedshellmesh(Ne; part=1, numparts=1)
  dim = 2
  @assert 1 <= part <= numparts

  globalnelems = 6 * Ne^2

  # How many vertices and faces per element
  nvert = 2^dim # 4
  nface = 2dim  # 4

  # linearly partition to figure out which elements we own
  elemlocal = Canary.linearpartition(prod(globalnelems), part, numparts)

  # elemen to vertex maps which we own
  elemtovert = Array{Int}(undef, nvert, length(elemlocal))
  elemtocoord = Array{Int}(undef, dim, nvert, length(elemlocal))

  nelemcube = Ne^dim # Ne^2

  etoijb = CartesianIndices((Ne, Ne, 6))
  bx = [0 Ne 2Ne  Ne  Ne  Ne]
  by = [0  0   0  Ne 2Ne 3Ne]

  vertmap = LinearIndices((Ne+1, Ne+1, Ne+1))
  for (le, e) = enumerate(elemlocal)
    i, j, blck = Tuple(etoijb[e])
    elemtocoord[1, :, le] = bx[blck] .+ [i-1 i i-1 i]
    elemtocoord[2, :, le] = by[blck] .+ [j-1 j-1 j j]

    for n = 1:4
      ix = i + mod(n-1, 2)
      jx = j + div(n-1, 2)
      # set the vertices like they are the face vertices of a cube
      if blck == 1
        elemtovert[n, le] = vertmap[   1   , Ne+2-ix,      jx]
      elseif blck == 2
        elemtovert[n, le] = vertmap[     ix,   1    ,      jx]
      elseif blck == 3
        elemtovert[n, le] = vertmap[Ne+1   ,      ix,      jx]
      elseif blck == 4
        elemtovert[n, le] = vertmap[     ix,      jx,  Ne+1  ]
      elseif blck == 5
        elemtovert[n, le] = vertmap[     ix, Ne+1   , Ne+2-jx]
      elseif blck == 6
        elemtovert[n, le] = vertmap[     ix, Ne+2-jx,    1   ]
      end
    end
  end

  # no boundaries for a shell
  elemtobndy = zeros(Int, nface, length(elemlocal))

  # no faceconnections for a shell
  faceconnections = Array{Array{Int, 1}}(undef, 0)

  (elemtovert, elemtocoord, elemtobndy, faceconnections)
end


"""
    cubedshellwarp(a, b, c, R = max(abs(a), abs(b), abs(c)))

Given points `(a, b, c)` on the surface of a cube, warp the points out to a
spherical shell of radius `R` based on the equiangular gnomonic grid proposed by
Ronchi, Iacono, Paolucci (1996) <https://dx.doi.org/10.1006/jcph.1996.0047>

```
@article{RonchiIaconoPaolucci1996,
  title={The ``cubed sphere'': a new method for the solution of partial
         differential equations in spherical geometry},
  author={Ronchi, C. and Iacono, R. and Paolucci, P. S.},
  journal={Journal of Computational Physics},
  volume={124},
  number={1},
  pages={93--114},
  year={1996},
  doi={10.1006/jcph.1996.0047}
}
```

"""
function cubedshellwarp(a, b, c, R = max(abs(a), abs(b), abs(c)))

  fdim = argmax(abs.([a, b, c]))
  if fdim == 1 && a < 0
    # (-R, *, *) : Face I from Ronchi, Iacono, Paolucci (1996)
    ξ, η = b / a, c / a
    X, Y = tan(π * ξ / 4), tan(π * η / 4)
    x = -R / sqrt(X^2 + Y^2 + 1)
    y, z = X * x, Y * x
  elseif fdim == 2 && b < 0
    # ( *,-R, *) : Face I from Ronchi, Iacono, Paolucci (1996)
    ξ, η = a / b, c / b
    X, Y = tan(π * ξ / 4), tan(π * η / 4)
    y = -R / sqrt(X^2 + Y^2 + 1)
    x, z = X * y, Y * y
  elseif fdim == 1 && a > 0
    # (-R, *, *) : Face III from Ronchi, Iacono, Paolucci (1996)
    ξ, η = b / a, c / a
    X, Y = tan(π * ξ / 4), tan(π * η / 4)
    x = R / sqrt(X^2 + Y^2 + 1)
    y, z = X * x, Y * x
  elseif fdim == 2 && b > 0
    # ( *,-R, *) : Face IV from Ronchi, Iacono, Paolucci (1996)
    ξ, η = a / b, c / b
    X, Y = tan(π * ξ / 4), tan(π * η / 4)
    y = R / sqrt(X^2 + Y^2 + 1)
    x, z = X * y, Y * y
  elseif fdim == 3 && c > 0
    # ( *,-R, *) : Face V from Ronchi, Iacono, Paolucci (1996)
    ξ, η = b / c, a / c
    X, Y = tan(π * ξ / 4), tan(π * η / 4)
    z = R / sqrt(X^2 + Y^2 + 1)
    x, y = Y * z, X * z
  elseif fdim == 3 && c < 0
    # ( *,-R, *) : Face V from Ronchi, Iacono, Paolucci (1996)
    ξ, η = b / c, a / c
    X, Y = tan(π * ξ / 4), tan(π * η / 4)
    z = -R / sqrt(X^2 + Y^2 + 1)
    x, y = Y * z, X * z
  else
    error("invalid case for cubedshellwarp: $a, $b, $c")
  end

  x, y, z
end

"""
   StackedCubedSphereTopology(mpicomm, Nhorz, Rrange;
                              bc=(1,1)) <: AbstractTopology{3}

Generate a stacked cubed sphere topology with `Nhorz` by `Nhorz` cells for each
horizontal face and `Rrange` is the radius edges of the stacked elements.  This
topology actual creates a cube mesh, and the warping should be done after the
grid is created using the `cubedshellwarp` function. The coordinates of the
points will be of type `eltype(Rrange)`. The inner boundary condition type is
`bc[1]` and the outer boundary condition type is `bc[2]`.

The elements are stacked such that the vertical elements are contiguous in the
element ordering.

The elements of the brick are partitioned equally across the MPI ranks based
on a space-filling curve. Further, stacks are not split at MPI boundaries.

# Examples

We can build a cubed sphere mesh with 10 x 10 x 5 elements on each cube, total
elements is `10 * 10 * 5 * 6 = 3000`, with
```jldoctest brickmesh
using CLIMAAtmosDycore
using CLIMAAtmosDycore.Topologies
using MPI
MPI.Init()
Nhorz = 10
Nstack = 5
Rrange = Float64.(accumulate(+,1:Nstack+1))
topology = StackedCubedSphereTopology(MPI.COMM_SELF, Nhorz, Rrange)

x, y, z = ntuple(j->reshape(topology.elemtocoord[j, :, :],
                            2, 2, 2, length(topology.elems)), 3)
for n = 1:length(x)
   x[n], y[n], z[n] = Topologies.cubedshellwarp(x[n], y[n], z[n])
end

MPI.Finalize()
```
Note that the faces are listed in Cartesian order.
"""
struct StackedCubedSphereTopology{T} <: AbstractStackedTopology{3}
  """
  mpi communicator use for spatial discretization are using
  """
  mpicomm::MPI.Comm

  """
  number of elements in a stack
  """
  stacksize::Int64

  """
  range of element indices
  """
  elems::UnitRange{Int64}

  """
  range of real (aka nonghost) element indices
  """
  realelems::UnitRange{Int64}

  """
  range of ghost element indices
  """
  ghostelems::UnitRange{Int64}

  """
  array of send element indices sorted so that
  """
  sendelems::Array{Int64, 1}

  """
  element to vertex coordinates

  `elemtocoord[d,i,e]` is the `d`th coordinate of corner `i` of element `e`

  !!! note
  currently coordinates always are of size 3 for `(x, y, z)`
  """
  elemtocoord::Array{T, 3}

  """
  element to neighboring element; `elemtoelem[f,e]` is the number of the element
  neighboring element `e` across face `f`.  If there is no neighboring element
  then `elemtoelem[f,e] == e`.
  """
  elemtoelem::Array{Int64, 2}

  """
  element to neighboring element face; `elemtoface[f,e]` is the face number of
  the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoface[f,e] == f`."
  """
  elemtoface::Array{Int64, 2}

  """
  element to neighboring element order; `elemtoordr[f,e]` is the ordering number
  of the element neighboring element `e` across face `f`.  If there is no
  neighboring element then `elemtoordr[f,e] == 1`.
  """
  elemtoordr::Array{Int64, 2}

  """
  element to bounday number; `elemtobndy[f,e]` is the boundary number of face
  `f` of element `e`.  If there is a neighboring element then `elemtobndy[f,e]
  == 0`.
  """
  elemtobndy::Array{Int64, 2}

  """
  list of the MPI ranks for the neighboring processes
  """
  nabrtorank::Array{Int64, 1}

  """
  range in ghost elements to receive for each neighbor
  """
  nabrtorecv::Array{UnitRange{Int64}, 1}

  """
  range in `sendelems` to send for each neighbor
  """
  nabrtosend::Array{UnitRange{Int64}, 1}

  function StackedCubedSphereTopology(mpicomm, Nhorz, Rrange; bc = (1, 1),
                                      connectivity=:face, ghostsize=1)
    T = eltype(Rrange)

    basetopo = CubedShellTopology{T}(mpicomm, Nhorz; connectivity=connectivity,
                                     ghostsize=ghostsize)

    dim = 3
    nvert = 2^dim
    nface = 2dim
    stacksize = length(Rrange) - 1

    nreal = length(basetopo.realelems)*stacksize
    nghost = length(basetopo.ghostelems)*stacksize

    elems=1:(nreal+nghost)
    realelems=1:nreal
    ghostelems=nreal.+(1:nghost)

    sendelems = similar(basetopo.sendelems,
                        length(basetopo.sendelems)*stacksize)

    for i=1:length(basetopo.sendelems), j=1:stacksize
      sendelems[stacksize*(i-1) + j] = stacksize*(basetopo.sendelems[i]-1) + j
    end

    elemtocoord = similar(basetopo.elemtocoord, dim, nvert, length(elems))

    for i=1:length(basetopo.elems), j=1:stacksize
      # i is base element
      # e is stacked element
      e = stacksize*(i-1) + j


      # v is base vertex
      for v = 1:2^(dim-1)
        for d = 1:dim # dim here since shell is embedded in 3-D
          # v is lower stacked vertex
          elemtocoord[d, v, e] = basetopo.elemtocoord[d, v, i] * Rrange[j]
          # 2^(dim-1) + v is higher stacked vertex
          elemtocoord[d, 2^(dim-1) + v, e] = basetopo.elemtocoord[d, v, i] *
                                             Rrange[j+1]
        end
      end
    end

    elemtoelem = similar(basetopo.elemtoelem, nface, length(elems))
    elemtoface = similar(basetopo.elemtoface, nface, length(elems))
    elemtoordr = similar(basetopo.elemtoordr, nface, length(elems))
    elemtobndy = similar(basetopo.elemtobndy, nface, length(elems))

    for e=1:length(basetopo.elems)*stacksize, f=1:nface
      elemtoelem[f, e] = e
      elemtoface[f, e] = f
      elemtoordr[f, e] = 1
      elemtobndy[f, e] = 0
    end

    for i=1:length(basetopo.realelems), j=1:stacksize
      e1 = stacksize*(i-1) + j

      for f = 1:2(dim-1)
        e2 = stacksize*(basetopo.elemtoelem[f, i]-1) + j

        elemtoelem[f, e1] = e2
        elemtoface[f, e1] = basetopo.elemtoface[f, i]

        # since the basetopo is 2-D we only need to worry about two orientations
        @assert basetopo.elemtoordr[f, i] ∈ (1,2)
        #=
        orientation 1:
        2---3     2---3
        |   | --> |   |
        0---1     0---1
        same:
        (a,b) --> (a,b)

        orientation 3:
        2---3     3---2
        |   | --> |   |
        0---1     1---0
        reverse first index:
        (a,b) --> (N+1-a,b)
        =#
        elemtoordr[f, e1] = basetopo.elemtoordr[f, i] == 1 ? 1 : 3
      end

      # If top or bottom of stack set neighbor to self on respective face
      elemtoelem[2(dim-1)+1, e1] = j == 1         ? e1 : stacksize*(i-1) + j - 1
      elemtoelem[2(dim-1)+2, e1] = j == stacksize ? e1 : stacksize*(i-1) + j + 1

      elemtoface[2(dim-1)+1, e1] = j == 1         ? 2(dim-1) + 1 : 2(dim-1) + 2
      elemtoface[2(dim-1)+2, e1] = j == stacksize ? 2(dim-1) + 2 : 2(dim-1) + 1

      elemtoordr[2(dim-1)+1, e1] = 1
      elemtoordr[2(dim-1)+2, e1] = 1
    end

    # Set the top and bottom boundary condition
    for i=1:length(basetopo.elems)
      eb = stacksize*(i-1) + 1
      et = stacksize*(i-1) + stacksize

      elemtobndy[2(dim-1)+1, eb] = bc[1]
      elemtobndy[2(dim-1)+2, et] = bc[2]
    end

    nabrtorank = basetopo.nabrtorank
    nabrtorecv =
      UnitRange{Int}[UnitRange(stacksize*(first(basetopo.nabrtorecv[n])-1)+1,
                               stacksize*last(basetopo.nabrtorecv[n]))
                     for n = 1:length(nabrtorank)]
    nabrtosend =
      UnitRange{Int}[UnitRange(stacksize*(first(basetopo.nabrtosend[n])-1)+1,
                               stacksize*last(basetopo.nabrtosend[n]))
                     for n = 1:length(nabrtorank)]

    new{T}(mpicomm, stacksize, elems, realelems, ghostelems, sendelems,
           elemtocoord, elemtoelem, elemtoface, elemtoordr, elemtobndy,
           nabrtorank, nabrtorecv, nabrtosend)
  end
end

end
