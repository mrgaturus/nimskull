## This module implements the interface between the VM and the rest of the
## compiler. The VM is only interacted with through this interface. Do note
## that right now, the compiler still indirectly interacts with the VM through
## the ``vmdef.PCtx`` object.
##
## The interface includes:
## - the procedure that sets up a VM instance for use during compilation
##   (``setupGlobalCtx``)
## - the routines for executing expressions, statements, and macros with the VM
## - an implementation of the ``passes`` interface that executes processed
##   code with the VM (``evalPass``)
## - the VM-related compilerapi

import
  std/[
    tables
  ],
  compiler/ast/[
    ast_types,
    ast,
    errorhandling,
    errorreporting,
    lineinfos,
    trees
  ],
  compiler/front/[
    msgs,
    options
  ],
  compiler/modules/[
    modulegraphs
  ],
  compiler/sem/[
    passes,
    transf
  ],
  compiler/utils/[
    debugutils,
    idioms
  ],
  compiler/vm/[
    vmcompilerserdes,
    vmdef,
    vmjit,
    vmlegacy,
    vmops,
    vmtypegen,
    vm
  ],
  experimental/[
    results
  ]

import std/options as std_options

from compiler/vm/vmgen import vmGenDiagToAstDiagVmGenError

# TODO: legacy report cruft remove from here
from compiler/ast/reports import wrap, toReportLineInfo
from compiler/ast/reports_vm import VMReport
from compiler/ast/reports_sem import SemReport
from compiler/ast/reports_internal import InternalReport
from compiler/ast/report_enums import ReportKind

type
  ExecErrorKind* = enum
    execErrorVm
    execErrorVmGen
    execErrorQuit

  ExecErrorReport* = object
    stackTrace*: VmStackTrace   ## The VM stack-trace
    location*: TLineInfo        ## Source location of the trace
    instLoc*: InstantiationInfo ## report instantiation location
    case kind*: ExecErrorKind   ## kind of error execution of vm code gen
      of execErrorVm:
        vmErr*: VmEvent
      of execErrorVmGen:
        genErr*: VmGenDiag
      of execErrorQuit:
        exitCode*: int

  ExecutionResult* = Result[PNode, ExecErrorReport]

# to prevent endless recursion in macro instantiation
const evalMacroLimit = 1000

# prevent a default `$` implementation from being generated
func `$`(e: ExecErrorReport): string {.error.}

proc putIntoReg(dest: var TFullReg; c: var TCtx, n: PNode, formal: PType) =
  ## Put the value that is represented by `n` (but not the node itself) into
  ## `dest`. Implicit conversion is also performed, if necessary.
  let t = formal.skipTypes(abstractInst+{tyStatic}-{tyTypeDesc})

  # XXX: instead of performing conversion here manually, sem could generate a
  #      small thunk for macro invocations that sets up static arguments and
  #      then invokes the macro. The thunk would be executed in the VM, making
  #      the code here obsolete while also eliminating unnecessary
  #      deserialize/serialize round-trips

  case t.kind
  of tyBool, tyChar, tyEnum, tyInt..tyInt64, tyUInt..tyUInt64:
    assert n.kind in nkCharLit..nkUInt64Lit
    dest.ensureKind(rkInt, c.memory)
    dest.intVal = n.intVal
  of tyFloat..tyFloat128:
    assert n.kind in nkFloatLit..nkFloat128Lit
    dest.ensureKind(rkFloat, c.memory)
    dest.floatVal = n.floatVal
  of tyNil, tyPtr, tyPointer:
    dest.ensureKind(rkAddress, c.memory)
    # XXX: it's currently forbidden to pass non-nil pointer to static
    #      parameters. `deserialize` already reports an error, so an
    #      assert is used here to make sure that it really got reported
    #      earlier
    assert n.kind == nkNilLit
  of tyOpenArray:
    # Handle `openArray` parameters the same way they're handled elsewhere
    # in the VM: simply pass the argument without a conversion
    let typ = c.getOrCreate(n.typ)
    dest.initLocReg(typ, c.memory)
    c.serialize(n, dest.handle)
  of tyProc:
    # XXX: a hack required to uphold some expectations. For example,
    #      `genEnumCaseStmt` would fail without this. Procedural types as
    #      static macro arguments are underspecified
    let pt =
      if t.callConv == ccClosure and n.kind == nkSym:
        # Force the location to be of non-closure type. This breaks other
        # assumptions!
        n.sym.typ
      else:
        t

    let typ = c.getOrCreate(pt)
    dest.initLocReg(typ, c.memory)
    c.serialize(n, dest.handle, pt)

  else:
    if t.kind == tyRef and t.sym != nil and t.sym.magic == mPNimrodNode:
      # A NimNode
      dest.ensureKind(rkNimNode, c.memory)
      dest.nimNode = n
    else:
      let typ = c.getOrCreate(formal)
      dest.initLocReg(typ, c.memory)
      # XXX: overriding the type (passing `formal`), leads to issues (internal
      #      compiler error) when passing an empty set to a static parameter
      c.serialize(n, dest.handle)#, formal)

proc unpackResult(res: sink ExecutionResult; config: ConfigRef, node: PNode): PNode =
  ## Unpacks the execution result. If the result represents a failure, returns
  ## a new `nkError` wrapping `node`. Otherwise, returns the value/tree result,
  ## optionally filling in the node's `info` with that of `node`, if not
  ## present already.
  if res.isOk:
    result = res.take
    if node != nil and result.info.line < 0:
      result.info = node.info
  else:
    let
      err = res.takeErr
      errKind = err.kind
      astDiagTrace = AstDiagVmTrace(
        currentExceptionA: err.stackTrace.currentExceptionA,
        currentExceptionB: err.stackTrace.currentExceptionB,
        stacktrace: err.stackTrace.stacktrace,
        skipped: err.stackTrace.skipped,
        location: err.location,
        instLoc: err.instLoc)
      astDiag =
        case errKind
        of execErrorVm:
          let location =
            case err.vmErr.kind
            of vmEvtUserError:         err.vmErr.errLoc
            of vmEvtArgNodeNotASymbol: err.vmErr.argAst.info
            else:                      err.location

          PAstDiag(
            kind: adVmError,
            location: location,
            instLoc: err.vmErr.instLoc,
            vmErr: vmEventToAstDiagVmError(err.vmErr),
            vmTrace: astDiagTrace)
        of execErrorVmGen:
          PAstDiag(
            kind: adVmGenError,
            location: err.genErr.location,
            instLoc: err.genErr.instLoc,
            vmGenErr: vmGenDiagToAstDiagVmGenError(err.genErr),
            duringJit: true,
            vmGenTrace: astDiagTrace)
        of execErrorQuit:
          PAstDiag(
            kind: adVmQuit,
            location: err.location,
            instLoc: err.instLoc,
            vmExitCode: err.exitCode,
            vmExitTrace: astDiagTrace)

    result = config.newError(node, astDiag, instLoc(-1))

proc buildError(c: TCtx, thread: VmThread, event: sink VmEvent): ExecErrorReport  =
  ## Creates an `ExecErrorReport` with the `event` and a stack-trace for
  ## `thread`
  ExecErrorReport(
    stackTrace: createStackTrace(c, thread),
    instLoc: instLoc(-1),
    location: source(c, thread),
    kind: execErrorVm,
    vmErr: event)

proc buildError(c: TCtx, thread: VmThread, diag: sink VmGenDiag): ExecErrorReport  =
  ## Creates an `ExecErrorReport` with the `diag` and a stack-trace for
  ## `thread`
  ExecErrorReport(
    stackTrace: createStackTrace(c, thread),
    instLoc: instLoc(-1),
    location: source(c, thread),
    kind: execErrorVmGen,
    genErr: diag)

proc buildQuit(c: TCtx, thread: VmThread, exitCode: int): ExecErrorReport =
  ## Creates an `ExecErrorReport` with the `exitCode` and a stack-trace for
  ## `thread`
  ExecErrorReport(
    stackTrace: createStackTrace(c, thread),
    instLoc: instLoc(-1),
    location: source(c, thread),
    kind: execErrorQuit,
    exitCode: exitCode)

proc createLegacyStackTrace(
    c: TCtx, 
    thread: VmThread, 
    instLoc: InstantiationInfo = instLoc(-1)
  ): VMReport =
  let st = createStackTrace(c, thread)
  result = VMReport(kind: rvmStackTrace,
                    currentExceptionA: st.currentExceptionA,
                    currentExceptionB: st.currentExceptionB,
                    stacktrace: st.stacktrace,
                    skipped: st.skipped,
                    location: some source(c, thread),
                    reportInst: toReportLineInfo(instLoc))

proc execute(c: var TCtx, start: int, frame: sink TStackFrame;
             cb: proc(c: TCtx, r: TFullReg): PNode
            ): ExecutionResult {.inline.} =
  ## This is the entry point for invoking the VM to execute code at
  ## compile-time. The `cb` callback is used to deserialize the result stored
  ## as VM data into ``PNode`` AST, and is invoked with the register that
  ## holds the result
  var thread = initVmThread(c, start, frame)

  # run the VM until either no code is left to execute or an event implying
  # execution can't go on occurs
  while true:
    var r = execute(c, thread)
    case r.kind
    of yrkDone:
      # execution is finished
      result.initSuccess cb(c, c.sframes[0].slots[r.reg.get])
      break
    of yrkError:
      result.initFailure buildError(c, thread, r.error)
      break
    of yrkQuit:
      case c.mode
      of emRepl, emStaticExpr, emStaticStmt:
        # XXX: should code run at compile time really be able to force-quit
        #      the compiler? It currently can.
        localReport(c.config, createLegacyStackTrace(c, thread))
        localReport(c.config, InternalReport(kind: rintQuitCalled))
        # FIXME: this will crash the compiler (RangeDefect) if `quit` is
        #        called with a value outside of int8 range!
        msgQuit(int8(r.exitCode))
      of emConst, emOptimize:
        result.initFailure buildQuit(c, thread, r.exitCode)
        break
      of emStandalone:
        unreachable("not valid at compile-time")
    of yrkMissingProcedure:
      # a stub entry was encountered -> generate the code for the
      # corresponding procedure
      let res = compile(c, r.entry)
      if res.isErr:
        # code-generation failed
        result.initFailure:
          buildError(c, thread, res.takeErr)
        break

      # success! ``compile`` updated the procedure's entry, so we can
      # continue execution

  dispose(c, thread)

proc execute(c: var TCtx, info: CodeInfo): ExecutionResult =
  var tos = TStackFrame(prc: nil, comesFrom: 0, next: -1)
  tos.slots.newSeq(info.regCount)
  execute(c, info.start, tos,
          proc(c: TCtx, r: TFullReg): PNode = c.graph.emptyNode)

template returnOnErr(res: VmGenResult, config: ConfigRef, node: PNode): CodeInfo =
  ## Unpacks the vmgen result. If the result represents an error, exits the
  ## calling function by returning a new `nkError` wrapping `node`
  let r = res
  if r.isOk:
    r.take
  else:
    let
      vmGenDiag = r.takeErr
      diag = PAstDiag(
              kind: adVmGenError,
              location: vmGenDiag.location,
              instLoc: vmGenDiag.instLoc,
              vmGenErr: vmGenDiagToAstDiagVmGenError(vmGenDiag),
              duringJit: false)

    return config.newError(node, diag, instLoc())

proc reportIfError(config: ConfigRef, n: PNode) =
  ## If `n` is a `nkError`, reports the error via `handleReport`. This is
  ## only meant for errors from vm/vmgen invocations and is also only a
  ## transition helper until all vm invocation functions properly propagate
  ## `nkError`
  if n.isError:
    # Errors from direct vmgen invocations don't have a stack-trace
    if n.diag.kind == adVmGenError and n.diag.duringJit or
        n.diag.kind == adVmError:
      let st =
        case n.diag.kind
        of adVmGenError: n.diag.vmGenTrace
        of adVmError:    n.diag.vmTrace
        else:            unreachable()

      config.handleReport(
                wrap(VMReport(kind: rvmStackTrace,
                        currentExceptionA: st.currentExceptionA,
                        currentExceptionB: st.currentExceptionB,
                        stacktrace: st.stacktrace,
                        skipped: st.skipped,
                        location: some st.location,
                        reportInst: toReportLineInfo(st.instLoc))),
                instLoc(-1))

    config.localReport(n)


template mkCallback(cn, rn, body): untyped =
  let p = proc(cn: TCtx, rn: TFullReg): PNode = body
  p

proc evalStmt(c: var TCtx, n: PNode): PNode =
  let n = transformExpr(c.graph, c.idgen, c.module, n)
  let info = genStmt(c, n).returnOnErr(c.config, n)

  # execute new instructions; this redundant opcEof check saves us lots
  # of allocations in 'execute':
  if c.code[info.start].opcode != opcEof:
    result = execute(c, info).unpackResult(c.config, n)
  else:
    result = c.graph.emptyNode

proc setupGlobalCtx*(module: PSym; graph: ModuleGraph; idgen: IdGenerator) =
  addInNimDebugUtils(graph.config, "setupGlobalCtx")
  if graph.vm.isNil:
    let
      ctx = newCtx(module, graph.cache, graph, idgen, legacyReportsVmTracer)
      disallowDangerous =
        defined(nimsuggest) or graph.config.cmd == cmdCheck or
        vmopsDanger notin ctx.config.features

    ctx.codegenInOut.flags = {cgfAllowMeta}
    registerAdditionalOps(ctx[], disallowDangerous)

    graph.vm = ctx
  else:
    let c = PCtx(graph.vm)
    refresh(c[], module, idgen)

proc evalConstExprAux(module: PSym; idgen: IdGenerator;
                      g: ModuleGraph; prc: PSym, n: PNode,
                      mode: TEvalMode): PNode =
  addInNimDebugUtils(g.config, "evalConstExprAux", prc, n, result)
  #if g.config.errorCounter > 0: return n
  let n = transformExpr(g, idgen, module, n)
  setupGlobalCtx(module, g, idgen)
  let c = PCtx g.vm
  let oldMode = c.mode
  c.mode = mode
  defer:
    c.mode = oldMode

  let requiresValue = mode!=emStaticStmt
  let (start, regCount) = genExpr(c[], n, requiresValue).returnOnErr(c.config, n)

  if c.code[start].opcode == opcEof: return newNodeI(nkEmpty, n.info)
  assert c.code[start].opcode != opcEof
  when defined(nimVMDebugGenerate):
    c.config.localReport():
      initVmCodeListingReport(c[], prc, n)

  var tos = TStackFrame(prc: prc, comesFrom: 0, next: -1)
  tos.slots.newSeq(regCount)
  #for i in 0..<regCount: tos.slots[i] = newNode(nkEmpty)
  let cb =
    if requiresValue:
      mkCallback(c, r): c.regToNode(r, n.typ, n.info)
    else:
      mkCallback(c, r): newNodeI(nkEmpty, n.info)

  result = execute(c[], start, tos, cb).unpackResult(c.config, n)

proc evalConstExpr*(module: PSym; idgen: IdGenerator; g: ModuleGraph; e: PNode): PNode {.inline.} =
  result = evalConstExprAux(module, idgen, g, nil, e, emConst)

proc evalStaticExpr*(module: PSym; idgen: IdGenerator; g: ModuleGraph; e: PNode, prc: PSym): PNode {.inline.} =
  result = evalConstExprAux(module, idgen, g, prc, e, emStaticExpr)

proc evalStaticStmt*(module: PSym; idgen: IdGenerator; g: ModuleGraph; e: PNode, prc: PSym) {.inline.} =
  let r = evalConstExprAux(module, idgen, g, prc, e, emStaticStmt)
  # TODO: the node needs to be returned to the caller instead
  reportIfError(g.config, r)

proc setupCompileTimeVar*(module: PSym; idgen: IdGenerator; g: ModuleGraph; n: PNode) {.inline.} =
  let r = evalConstExprAux(module, idgen, g, nil, n, emStaticStmt)
  # TODO: the node needs to be returned to the caller instead
  reportIfError(g.config, r)

proc setupMacroParam(reg: var TFullReg, c: var TCtx, x: PNode, typ: PType) =
  case typ.kind
  of tyStatic:
    putIntoReg(reg, c, x, typ)
  else:
    var n = x
    if n.kind in {nkHiddenSubConv, nkHiddenStdConv}: n = n[1]
    # TODO: is anyone on the callsite dependent on this modifiction of `x`?
    n.typ = x.typ
    reg = TFullReg(kind: rkNimNode, nimNode: n)

proc evalMacroCall*(module: PSym; idgen: IdGenerator; g: ModuleGraph; templInstCounter: ref int;
                    n: PNode, sym: PSym): PNode =
  #if g.config.errorCounter > 0: return errorNode(idgen, module, n)

  # XXX globalReport() is ugly here, but I don't know a better solution for now
  inc(g.config.evalMacroCounter)
  if g.config.evalMacroCounter > evalMacroLimit:
    globalReport(g.config, n.info, VMReport(
      kind: rsemMacroInstantiationTooNested, ast: n))

  # immediate macros can bypass any type and arity checking so we check the
  # arity here too:
  if sym.typ.len > n.safeLen and sym.typ.len > 1:
    globalReport(g.config, n.info, SemReport(
      kind: rsemWrongNumberOfArguments,
      ast: n,
      countMismatch: (
        expected: sym.typ.len - 1,
        got: n.safeLen - 1)))

  setupGlobalCtx(module, g, idgen)
  let c = PCtx g.vm
  let oldMode = c.mode
  c.mode = emStaticStmt
  c.comesFromHeuristic.line = 0'u16
  c.callsite = n
  c.templInstCounter = templInstCounter

  defer:
    # restore the previous state when exiting this procedure
    # TODO: neither ``mode`` nor ``callsite`` should be stored as part of the
    #       global execution environment (i.e. ``TCtx``). ``callsite`` is part
    #       of the state that makes up a single VM invocation, and ``mode`` is
    #       only needed for ``vmgen``
    c.mode = oldMode
    c.callsite = nil

  let (start, regCount) = loadProc(c[], sym).returnOnErr(c.config, n)

  var tos = TStackFrame(prc: sym, comesFrom: 0, next: -1)
  tos.slots.newSeq(regCount)
  # setup arguments:
  var L = n.safeLen
  if L == 0: L = 1
  # This is wrong for tests/reject/tind1.nim where the passed 'else' part
  # doesn't end up in the parameter:
  #InternalAssert tos.slots.len >= L

  # return value:
  tos.slots[0] = TFullReg(kind: rkNimNode, nimNode: newNodeI(nkEmpty, n.info))

  # put macro call arguments into registers
  for i in 1..<sym.typ.len:
    setupMacroParam(tos.slots[i], c[], n[i], sym.typ[i])

  # put macro generic parameters into registers
  let gp = sym.ast[genericParamsPos]
  for i in 0..<gp.safeLen:
    let idx = sym.typ.len + i
    if idx < n.len:
      setupMacroParam(tos.slots[idx], c[], n[idx], gp[i].sym.typ)
    else:
      # TODO: the decrement here is wrong, but the else branch is likely
      #       currently not reached anyway
      dec(g.config.evalMacroCounter)
      localReport(c.config, n.info, SemReport(
        kind: rsemWrongNumberOfGenericParams,
        countMismatch: (
          expected: gp.len,
          got: idx)))

  # temporary storage:
  #for i in L..<maxSlots: tos.slots[i] = newNode(nkEmpty)

  # n.typ == nil is valid and means that resulting NimNode represents
  # a statement
  let cb = mkCallback(c, r): r.nimNode
  result = execute(c[], start, tos, cb).unpackResult(c.config, n)

  if result.kind != nkError and cyclicTree(result):
    globalReport(c.config, n.info, VMReport(
      kind: rsemCyclicTree, ast: n, sym: sym))

  dec(g.config.evalMacroCounter)


# ----------- the VM-related compilerapi -----------

# NOTE: it might make sense to move the VM-related compilerapi into
#       ``nimeval.nim`` -- the compiler itself doesn't depend on or uses it

proc execProc*(c: var TCtx; sym: PSym; args: openArray[PNode]): PNode =
  # XXX: `localReport` is still used here since execProc is only used by the
  # VM's compilerapi (`nimeval`) whose users don't know about nkError yet

  c.loopIterations = c.config.maxLoopIterationsVM
  if sym.kind in routineKinds:
    if sym.typ.len-1 != args.len:
      localReport(c.config, sym.info, SemReport(
        kind: rsemWrongNumberOfArguments,
        sym: sym,
        countMismatch: (
          expected: sym.typ.len - 1,
          got: args.len)))

    else:
      let (start, maxSlots) = block:
        # XXX: `returnOnErr` should be used here instead, but isn't for
        #      backwards compatiblity
        let r = loadProc(c, sym)
        if unlikely(r.isErr):
          localReport(c.config, vmGenDiagToLegacyVmReport(r.takeErr))
          return nil
        r.unsafeGet

      var tos = TStackFrame(prc: sym, comesFrom: 0, next: -1)
      tos.slots.newSeq(maxSlots)

      # setup parameters:
      if not isEmptyType(sym.typ[0]) or sym.kind == skMacro:
        let typ = c.getOrCreate(sym.typ[0])
        if not tos.slots[0].loadEmptyReg(typ, sym.info, c.memory):
          tos.slots[0].initLocReg(typ, c.memory)
      # XXX We could perform some type checking here.
      for i in 1..<sym.typ.len:
        putIntoReg(tos.slots[i], c, args[i-1], sym.typ[i])

      let cb =
        if not isEmptyType(sym.typ[0]):
          mkCallback(c, r): c.regToNode(r, sym.typ[0], sym.info)
        elif sym.kind == skMacro:
          # TODO: missing cyclic check
          mkCallback(c, r): r.nimNode
        else:
          mkCallback(c, r): newNodeI(nkEmpty, sym.info)

      let r = execute(c, start, tos, cb)
      result = r.unpackResult(c.config, c.graph.emptyNode)
      reportIfError(c.config, result)
      if result.isError:
        result = nil
  else:
    localReport(c.config, sym.info):
      VMReport(kind: rvmCallingNonRoutine, sym: sym)

# XXX: the compilerapi regarding globals (getGlobalValue/setGlobalValue)
#      doesn't work the same as before. Previously, the returned PNode
#      could be used to modify the actual global value, but this is not
#      possible anymore

proc getGlobalValue*(c: TCtx; s: PSym): PNode =
  ## Does not perform type checking, so ensure that `s.typ` matches the
  ## global's type
  internalAssert(c.config, s.kind in {skLet, skVar} and sfGlobal in s.flags)
  let slotIdx = c.globals[c.symToIndexTbl[s.id]]
  let slot = c.heap.slots[slotIdx]

  result = c.deserialize(slot.handle, s.typ, s.info)

proc setGlobalValue*(c: var TCtx; s: PSym, val: PNode) =
  ## Does not do type checking so ensure the `val` matches the `s.typ`
  internalAssert(c.config, s.kind in {skLet, skVar} and sfGlobal in s.flags)
  let slotIdx = c.globals[c.symToIndexTbl[s.id]]
  let slot = c.heap.slots[slotIdx]

  c.serialize(val, slot.handle)

## what follows is an implementation of the ``passes`` interface that evaluates
## the code directly inside the VM. It is used for NimScript execution and by
## the ``nimeval`` interface

proc myOpen(graph: ModuleGraph; module: PSym; idgen: IdGenerator): PPassContext {.nosinks.} =
  #var c = newEvalContext(module, emRepl)
  #c.features = {allowCast, allowInfiniteLoops}
  #pushStackFrame(c, newStackFrame())

  # XXX produce a new 'globals' environment here:
  setupGlobalCtx(module, graph, idgen)
  result = PCtx graph.vm

proc myProcess(c: PPassContext, n: PNode): PNode =
  let c = PCtx(c)
  # don't eval errornous code:
  if c.oldErrorCount == c.config.errorCounter:
    let r = evalStmt(c[], n)
    reportIfError(c.config, r)
    # TODO: use the node returned by evalStmt as the result and don't report
    #       the error here
    result = newNodeI(nkEmpty, n.info)
  else:
    result = n
  c.oldErrorCount = c.config.errorCounter

proc myClose(graph: ModuleGraph; c: PPassContext, n: PNode): PNode =
  result = myProcess(c, n)

const evalPass* = makePass(myOpen, myProcess, myClose)