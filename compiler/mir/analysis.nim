## This module implements various data-flow related analysis for MIR code.
## They're based on the ``mirexec`` traversal algorithms and require a
## ``Values`` dictionary and a ``ControlFlowGraph`` object, both
## corresponding to the code fragment (i.e. ``MirTree``) that is analysed.
##
## A ``Values`` dictionary stores information about the result of operations,
## namely, whether the value is owned and, for lvalues, the root. It also
## stores the lvalue effects of operations. An instance of the dictionary is
## created and initialized via the ``computeValuesAndEffects`` procedure.
##
## Each location that is not allocated via ``new`` or ``alloc`` is owned by a
## single handle (the name of a local, global, etc.), but can be aliased
## through both pointers and views. Once the owning handle goes out of scope,
## the lifetime of the corresponding locatins ends, irrespective of whether an
## unsafe alias (pointer) of it still exists.
##
## Instead of assigning a unique ID to each value/lvalue, they're identified
## via the operation sequence that produces them (stored as a ``NodePosition``
## tuple). While the comparision is not as efficient as an equality test
## between two integers, it is still relatively cheap, and, in addition, also
## allows for part-of analysis without requiring complex algorithms or
## data-structures.
##
## Do note that it is assumed that there only exists one handle for each
## location -- pointers or views are not tracked. Reads or writes through
## aliases are not detected.
##
## ..note:: implementing this is possible. A second step after
##          ``computeValuesAndEffects`` could perform an abstract execution of
##          the MIR code to produce a conservative set of possible handles for
##          each pointer-like dereferencing operation. The analysis routines
##          would then compare the analysed handle with each set element,
##          optionally taking types into account in order to reduce the number
##          of comparisons (i.e. by not comparing handles of differing type)
##
## When a "before" or "after" relationship is mentioned in the context of
## operations, it doesn't refer to the relative memory location of the
## nodes representing the operations, but rather to the operations'
## control-flow relationship. If control-flow visits A first and then B, A is
## said to come before B and B to come after A. Not all operations are
## connected to each other through control-flow however, in which case the
## aforementioned relationship doesn't exist.

import
  std/[
    hashes,
    tables
  ],
  compiler/ast/[
    ast_types,
    ast_query
  ],
  compiler/mir/[
    mirtrees
  ],
  compiler/sem/[
    aliasanalysis,
    mirexec,
    typeallowed
  ],
  compiler/utils/[
    containers
  ],
  experimental/[
    dod_helpers
  ]

import std/packedsets

type
  Owned* {.pure.} = enum
    no
    yes
    weak ## values derived from compound values (e.g. ``object``, ``tuple``,
         ## etc.) that are weakly owned decay to no ownership. Rvalues are
         ## weakly owned -- they can be consumed directly, but sub-values of
         ## them can't
    unknown

  ValueInfo = object
    root: opt(NodeInstance) ## the root of the value (or 'none' if the
                            ## ``ValueInfo`` is invalid)
    owns: Owned             ## whether the handle owns its value

  Effect = object
    kind: EffectKind
    loc: OpValue ## the lvalue the effect applies to

  EffectMap = object
    ## Accelerator structure that maps each operation to its lvalue effects.
    list: seq[Effect]
    map: Table[Operation, Slice[uint32]]

  Values* = object
    ## Stores information about the produced values plus the lvalue effects of
    ## operations
    values: OrdinalSeq[OpValue, ValueInfo]
    # XXX: `values` currently stores an entry for each *node*. Not every node
    #      represents an operation and we're also not interested in the value
    #      of every operation, only of those that appear in specific contexts.
    #      A ``Table`` could be used, but that would make lookup less
    #      efficient (although less used memory could also mean better memory
    #      locality)
    effects: EffectMap

  AliveState = enum
    unchanged
    dead
    alive

  ComputeAliveProc[T] =
    proc(tree: MirTree, values: Values, loc: T, n: MirNode,
         op: Operation): AliveState {.nimcall, noSideEffect.}

const
  ConsumeCtx* = {mnkConsume, mnkRaise, mnkDefUnpack}
    ## if an lvalue is used as an operand to these operators, the value stored
    ## in the named location is considered to be consumed (ownership over it
    ## transfered to the operation)
  UseContext* = {mnkArg, mnkDeref, mnkDerefView, mnkCast, mnkVoid, mnkIf,
                 mnkCase} + ConsumeCtx
    ## using an lvalue as the operand to one of these operators means that
    ## the content of the location is observed (when control-flow reaches the
    ## operator). In other words, applying the operator result in a read
    # FIXME: none-lvalue-conversions also count as reads, but because no
    #        distinction is being made between lvalue- and value-conversions
    #        at the MIR level, they're currently not considered. This is an
    #        issue and it needs to be fixed

  OpsWithEffects = {mnkCall, mnkMagic, mnkAsgn, mnkFastAsgn, mnkSwitch,
                    mnkInit, mnkRegion}
    ## the set of operations that can have lvalue-parameterized or general
    ## effects

func hash(x: Operation): Hash {.borrow.}

func skipConversions(tree: MirTree, val: OpValue): OpValue =
  ## Returns the value without conversions applied
  var p = NodePosition(val)
  while tree[p].kind in {mnkStdConv, mnkConv}:
    p = previous(tree, p)

  result = OpValue(p)

template getRoot*(v: Values, val: OpValue): OpValue =
  OpValue v.values[val].root[]

template owned*(v: Values, val: OpValue): Owned =
  v.values[val].owns

func setOwned*(v: var Values, val: OpValue, owns: Owned) {.inline.} =
  v.values[val].owns = owns

func toLvalue*(v: Values, val: OpValue): LvalueExpr {.inline.} =
  (NodePosition v.values[val].root[],
   NodePosition val)

iterator effects(v: Values, op: Operation): lent Effect =
  ## Yields all location-related effects of the given operation `op` in the
  ## order they were registered
  let s = v.effects.map.getOrDefault(op, 1.uint32..0.uint32)
  for i in s:
    yield v.effects.list[i]

func decayed(x: ValueInfo): ValueInfo {.inline.} =
  ## Turns 'weak' ownership into 'no' ownership
  result = x
  if result.owns == Owned.weak:
    result.owns = Owned.no

func add(m: var EffectMap, op: Operation, effects: openArray[Effect]) =
  ## Registers `effects` with `op` in the map `m`
  let start = m.list.len
  m.list.add effects
  m.map[op] = start.uint32 .. m.list.high.uint32

func computeValuesAndEffects*(body: MirTree): Values =
  ## Creates a ``Values`` dictionary with all operation effects collected and
  ## (static) value roots computed. Value ownership is already computed where it
  ## is possible to do so by just taking the static operation sequences into
  ## account (i.e. no control- or data-flow analysis is performed)
  var
    stack: seq[Effect]
    # more than 65K nested effects seems unlikely
    num: seq[uint16]

  result.values.newSeq(body.len)

  template inherit(i, source: NodePosition) =
    result.values[OpValue i] = result.values[OpValue source]

  template inheritDecay(i, source: NodePosition) =
    result.values[OpValue i] = decayed result.values[OpValue source]

  template popEffects(op: Operation) =
    let v = num.pop().int
    if v < stack.len:
      result.effects.add op, toOpenArray(stack, v, stack.high)
      stack.setLen(v)

  # we're doing three things here:
  # 1. propagate the value root
  # 2. propagate ownership status
  # 3. collect the lvalue effects for operations
  #
  # This is done in a single forward iteration over all nodes in the code
  # fragment -- nodes that don't represent operations are ignored.
  # Effects are collected by looking for 'tag' operations. Each occurrence of
  # an 'arg-block' node starts a new "frame". When a 'tag' operation is
  # encountered, the corresponding ``Effect`` information is added to the
  # frame. At the end of the 'arg-block', the frame is popped and the effects
  # collected as part of it are registered to the arg-block's corresponding
  # operation

  for i, n in body.pairs:
    template start(owned: Owned) =
      result.values[OpValue i] =
        ValueInfo(root: someOpt(NodeInstance i), owns: owned)

    case n.kind
    of mnkOpParam:
      # XXX: the body of regions are not yet analysed (they're skipped over).
      #      Once they are, the ownership status of an `opParam` depends on
      #      the corresponding argument. Values coming from 'name' and 'arg'
      #      arguments are not owned, but for those coming from 'consume'
      #      arguments, it depends (i.e. ``unknown``)
      start: Owned.no
    of mnkDeref, mnkDerefView, mnkConst, mnkType, mnkNone, mnkCast:
      start: Owned.no
    of mnkLiteral, mnkProc:
      # literals are always owned (each instance can be mutated without
      # impacting the others). Because of their copy-on-write mechanism,
      # this also includes string literals
      start: Owned.yes
    of mnkTemp, mnkLocal, mnkGlobal, mnkParam:
      # more context is required to know whether the value is owned
      start: Owned.unknown
    of mnkConstr:
      # the result of a ``seq`` construction via ``constr`` is essentially a
      # non-owning view into constant data
      start:
        if n.typ.skipTypes(abstractInst).kind == tySequence: Owned.no
        else: Owned.weak
    of mnkObjConstr:
      start:
        if n.typ.skipTypes(abstractInst).kind == tyRef: Owned.yes
        else: Owned.weak
      # ``mnkObjConstr`` is a sub-tree, so in order to keep the inheriting
      # logic simple, the 'end' node for the sub-tree uses the same
      # ``ValueInfo`` as the start node
      inherit(findEnd(body, i), i)
    of mnkCall, mnkMagic:
      # we currently can't reason about which location(s) views alias, so
      # we always treat values accessed through them as not owned
      start:
        if directViewType(n.typ) != noView: Owned.no
        else: Owned.weak
    of mnkStdConv, mnkConv:
      inherit(i, i - 1)
    of mnkAddr, mnkView, mnkPathPos, mnkPathVariant:
      inheritDecay(i, i - 1)
    of mnkPathArray:
      # inherit from the first operand (i.e. the array-like value)
      inheritDecay(i, NodePosition operand(body, Operation(i), 0))
    of mnkPathNamed:
      inheritDecay(i, i - 1)
      if sfCursor in n.field.flags:
        # any lvalue derived from a cursor location is non-owning
        result.values[OpValue i].owns = Owned.no

    of mnkArgBlock:
      num.add stack.len.uint16 # remember the current top-of-stack
    of mnkTag:
      stack.add Effect(kind: n.effect, loc: OpValue(i - 1))
    of mnkEnd:
      if n.start == mnkArgBlock:
        popEffects(Operation(i+1))

    of AllNodeKinds - InOutNodes - InputNodes - {mnkEnd}:
      discard "leave uninitialized"

func isAlive*(tree: MirTree, cfg: ControlFlowGraph, v: Values,
             span: Slice[NodePosition], loc: LvalueExpr,
             pos: NodePosition): bool =
  ## Computes if the location named by `loc` does contain a value at `pos`
  ## (i.e. is alive). The performed data-flow analysis only considers code
  ## inside `span`
  template toLvalue(val: OpValue): LvalueExpr =
    toLvalue(v, val)

  template overlaps(val: OpValue): bool =
    overlaps(tree, loc, toLvalue val) != no

  # this is a reverse data-flow problem. We follow all control-flow paths from
  # `pos` backwards until either there's no path left to follow or one of them
  # reaches a potential mutation of `loc`, in which case the underlying location
  # is considered to be alive. A path is not followed further if it reaches an
  # operation that "kills" the `loc` (removes its value, e.g. by moving it
  # somewhere else)

  var exit = false
  for i, n in traverseReverse(tree, cfg, span, pos, exit):
    case n.kind
    of OpsWithEffects:
      # iterate over the effects and look for the ones involving the analysed
      # location
      for effect in effects(v, Operation i):
        case effect.kind
        of ekMutate, ekReassign:
          if overlaps(effect.loc):
            # consider ``a.b = x`` (A) and ``a.b.c.d.e = y`` (B). If the
            # analysed l-value expression is ``a.b.c`` then both A and B mutate
            # it (either fully or partially). If traversal reaches what's
            # possibly a mutation of the analysed location, it means that the
            # location needs to be treated as being alive at `pos`, so we can
            # return already
            return true

        of ekKill:
          if isPartOf(tree, loc, toLvalue effect.loc) == yes:
            exit = true
            break

        of ekInvalidate:
          discard

      if tree[loc.root].kind == mnkGlobal and
         n.kind == mnkCall and geMutateGlobal in n.effects:
        # an unspecified global is mutated and we're analysing a location
        # derived from a global -> assume the analysed global is mutated
        return true

    of ConsumeCtx:
      let opr = unaryOperand(tree, Operation i)
      if v.owned(opr) == Owned.yes:
        if isPartOf(tree, loc, toLvalue opr) == yes:
          # the location's value is consumed and it becomes empty. No operation
          # coming before the current one can change that, so we can stop
          # traversing the current path
          exit = true

        # partially consuming the location does *not* change the alive state

    else:
      discard "not relevant"

  # no mutation is directly connected to `pos`. The location is not alive
  result = false

func isLastRead*(tree: MirTree, cfg: ControlFlowGraph, values: Values,
                 span: Slice[NodePosition], loc: LvalueExpr, pos: NodePosition
                ): bool =
  ## Performs data-flow analysis to compute whether the value that `loc`
  ## evaluates to at `pos` is *not* observed by operations that have a
  ## control-flow dependency on the operation/statement at `pos` and
  ## are located inside `span`.
  ## It's important to note that this analysis does not test whether the
  ## underlying *location* is accessed, but rather the *value* it stores. If a
  ## new value is assigned to the underlying location which is then accessed
  ## after, it won't cause the analysis to return false
  template toLvalue(val: OpValue): LvalueExpr =
    toLvalue(values, val)

  var state: TraverseState
  for i, n in traverse(tree, cfg, span, pos, state):
    case n.kind
    of OpsWithEffects:
      for effect in effects(values, Operation i):
        let cmp = compareLvalues(tree, loc, toLvalue effect.loc)
        case effect.kind
        of ekReassign:
          if isAPartOfB(cmp) == yes:
            # the location is reassigned -> all operations coming after will
            # observe a different value
            state.exit = true
            break
          elif isBPartOfA(cmp) != no:
            # the location is partially written to -> the relevant values is
            # observed
            return false

        of ekMutate:
          if cmp.overlaps != no:
            # the location is partially written to
            return false

        of ekKill:
          if isAPartOfB(cmp) == yes:
            # the location is definitely killed, it no longer stores the value
            # we're interested in
            state.exit = true
            break

        of ekInvalidate:
          discard

      if tree[loc.root].kind == mnkGlobal and
         n.kind == mnkCall and geMutateGlobal in n.effects:
        # an unspecified global is mutated and we're analysing a location
        # derived from a global -> assume that it's a read/use
        return false

    of UseContext - {mnkDefUnpack}:
      if overlaps(tree, loc, toLvalue unaryOperand(tree, Operation i)) != no:
        return false

    of DefNodes:
      # passing a value to a 'def' is also a use
      if hasInput(tree, Operation i) and
         overlaps(tree, loc, toLvalue unaryOperand(tree, Operation i)) != no:
        return false

    else:
      discard

  # no further read of the value is connected to `pos`
  result = true

func isLastWrite*(tree: MirTree, cfg: ControlFlowGraph, values: Values,
                  span: Slice[NodePosition], loc: LvalueExpr, pos: NodePosition
                 ): tuple[result, exits, escapes: bool] =
  ## Computes if the location `loc` is not reassigned to or modified while it
  ## still contains the value it contains at `pos`. In other words, computes
  ## whether a reassignment or mutation that has a control-flow dependency on
  ## `pos` and is located inside `span` observes the current value.
  ##
  ## In addition, whether the `pos` is connected to a structured or
  ## unstructured exit of `span` is also returned
  template toLvalue(val: OpValue): LvalueExpr =
    toLvalue(values, val)

  var state: TraverseState
  for i, n in traverse(tree, cfg, span, pos, state):
    case n.kind
    of OpsWithEffects:
      for effect in effects(values, Operation i):
        let cmp = compareLvalues(tree, loc, toLvalue effect.loc)
        case effect.kind
        of ekReassign, ekMutate, ekInvalidate:
          # note: since we don't know what happens to the location when it is
          # invalidated, the effect is also included here
          if cmp.overlaps != no:
            return (false, false, false)

        of ekKill:
          if isAPartOfB(cmp) == yes:
            state.exit = true
            break

          # partially killing the analysed location is not considered to be a
          # write

      if tree[loc.root].kind == mnkGlobal and
         n.kind == mnkCall and geMutateGlobal in n.effects:
        # an unspecified global is mutated and we're analysing a location
        # derived from a global
        return (false, false, false)

    else:
      discard

  result = (true, state.exit, state.escapes)

func computeAliveOp*[T: PSym | TempId](
  tree: MirTree, values: Values, loc: T, n: MirNode, op: Operation): AliveState =
  ## Computes the state of `loc` at the *end* of the given operation. The
  ## operands are expected to *not* alias with each other. The analysis
  ## result will be wrong if they do

  func isAnalysedLoc[T](n: MirNode, loc: T): bool =
    when T is TempId:
      n.kind == mnkTemp and n.temp == loc
    elif T is PSym:
      n.kind in {mnkLocal, mnkParam, mnkGlobal} and n.sym.id == loc.id
    else:
      {.error.}

  template isRootOf(val: OpValue): bool =
    isAnalysedLoc(tree[values.getRoot(val)], loc)

  template sameLocation(val: OpValue): bool =
    isAnalysedLoc(tree[skipConversions(tree, val)], loc)

  case n.kind
  of OpsWithEffects:
    # iterate over the lvalue effects of the processed operation and check
    # whether one of them affects the state of `loc`. If one does, further
    # iteration is not required, as the underlying locations of the operands
    # must not alias with each other.
    for effect in effects(values, op):
      case effect.kind
      of ekMutate, ekReassign:
        if isRootOf(effect.loc):
          # the analysed location or one derived from it is mutated
          return alive

      of ekKill:
        if sameLocation(effect.loc):
          # the location is killed
          return dead

      of ekInvalidate:
        discard "cannot be reasoned about here"

    when T is PSym:
      # XXX: testing the symbol's flags is okay for now, but a different
      #      approach has to be used once moving away from storing ``PSym``s
      #      in ``MirNodes``
      if sfGlobal in loc.flags and
          n.kind == mnkCall and geMutateGlobal in n.effects:
        # the operation mutates global state and we're analysing a global
        result = alive

  of ConsumeCtx:
    let opr = unaryOperand(tree, op)
    if values.owned(opr) == Owned.yes and sameLocation(opr):
      # the location's value is consumed
      result = dead

  else:
    discard

func computeAlive*[T](tree: MirTree, cfg: ControlFlowGraph, values: Values,
                      span: Slice[NodePosition], loc: T, hasInitialValue: bool,
                      op: static ComputeAliveProc[T]
                     ): tuple[alive, escapes: bool] =
  ## Computes whether the location is alive when `span` is exited via either
  ## structured or unstructured control-flow. A location is considered alive
  ## if it contains a value

  # assigning to or mutating the analysed location makes it become alive,
  # because it then stores a value. Consuming its value or using ``wasMoved``
  # on it "kills" it (it no longer contains a value)

  var exit = false
  for i, n in traverseFromExits(tree, cfg, span, exit):
    case op(tree, values, loc, n, Operation i)
    of dead:
      exit = true
    of alive:
      # the location is definitely alive when leaving the span via
      # unstructured control-flow
      return (true, true)
    of unchanged:
      discard

  if exit and hasInitialValue:
    # an unstructured exit is connected to the start of the span and the
    # location starts initialized
    return (true, true)

  # check if the location is alive at the structured exit of the span
  for i, n in traverseReverse(tree, cfg, span, span.b + 1, exit):
    case op(tree, values, loc, n, Operation i)
    of dead:
      exit = true
    of alive:
      # the location is definitely alive when leaving the span via
      # structured control-flow
      return (true, false)
    of unchanged:
      discard

  result = (exit and hasInitialValue, false)

proc doesGlobalEscape*(tree: MirTree, scope: Slice[NodePosition],
                       start: NodePosition, s: PSym): bool =
  ## Computes if the global `s` potentially "escapes". A global escapes if it
  ## is not declared at module scope and is used inside a procedure that is
  ## then called outside the analysed global's scope. Example:
  ##
  ## .. code-block:: nim
  ##
  ##   # a.nim
  ##   var p: proc()
  ##   block:
  ##     var x = Resource(...)
  ##     proc prc() =
  ##       echo x
  ##
  ##     p = prc # `x` "escapes" here
  ##     # uncommenting the below would make `x` not escape
  ##     # p = nil
  ##
  ##   p()
  ##
  # XXX: to implement this, one has to first collect side-effectful procedures
  #      defined inside either the same or nested scopes and their
  #      address taken (``sfSideEffect`` and ``sfAddrTaken``). The
  #      ``sfSideEffect`` flag only indicates whether a procedure accesses
  #      global state, not if the global in question (`s`) is modified /
  #      observed -- recursively applying the analysis to the procedures'
  #      bodies would be necessary for that.
  #      Then look for all assignments with one of the collect procedures as
  #      the source operand and perform an analysis similar to the one
  #      performed by ``isLastRead`` to check if the destination still
  #      contains the procedural value at the of the scope. If it does, the
  #      global escapes
  # XXX: as an escaping global is a semantic error, it would make more sense
  #      to detect and report it during semantic analysis instead -- the
  #      required DFA is not as simple there as it is with the MIR however
  result = false

func isConsumed*(tree: MirTree, val: OpValue): bool =
  ## Computes if `val` is definitely consumed. This is the case if it's
  ## directly used in a consume context, ignoring lvalue conversions
  var dest = NodePosition(val)
  while true:
    dest = sibling(tree, dest)

    case tree[dest].kind
    of mnkConv, mnkStdConv:
      # XXX: only lvalue conversions should be skipped
      discard "skip conversions"
    of ConsumeCtx:
      return true
    else:
      return false