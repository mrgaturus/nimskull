discard """
  output: '''(repo: "", package: "meo", ext: "")
doing shady stuff...
3
6
(@[1], @[2])
192.168.0.1
192.168.0.1
192.168.0.1
192.168.0.1'''
  cmd: '''nim c --gc:arc --expandArc:newTarget --expandArc:delete --expandArc:p1 --expandArc:tt --hint:Performance:off --assertions:off --expandArc:extractConfig --expandArc:mergeShadowScope --expandArc:check $file'''
  nimout: '''--expandArc: newTarget

var splat
splat = splitFile(path)
var :tmp
:tmp = splat.dir
op(splat.dir)
var :tmp_1
:tmp_1 = splat.name
op(splat.name)
var :tmp_2
:tmp_2 = splat.ext
op(splat.ext)
result = (:tmp, :tmp_1, :tmp_2)
`=destroy`(splat)
-- end of expandArc ------------------------
--expandArc: delete

var sibling
var :tmp = target[].parent[].left
`=copy`(sibling, :tmp)
var saved
var :tmp_1 = sibling[].right
`=copy`(saved, :tmp_1)
var :tmp_2 = sibling[].right
var :tmp_3 = saved[].left
`=copy`(:tmp_2, :tmp_3)
var :tmp_4 = sibling[].parent
`=sink`(:tmp_4, saved)
`=destroy`(sibling)
-- end of expandArc ------------------------
--expandArc: p1

var lresult
lresult = `@`([123])
var lvalue
var lnext
var :tmp
:tmp = (lresult, ";")
lvalue = :tmp[0]
op(:tmp[0])
lnext = :tmp[1]
op(:tmp[1])
result.value = move(lvalue)
`=destroy`(:tmp)
`=destroy_1`(lnext)
`=destroy_2`(lvalue)
-- end of expandArc ------------------------
--expandArc: tt

var
  :tmp
  :tmp_1
var a
var :tmp_2
try:
  var it_cursor = x
  a = (
    :tmp = op()
    `=copy`(:tmp, it_cursor.key)
    :tmp,
    :tmp_1 = op()
    `=copy`(:tmp_1, it_cursor.val)
    :tmp_1)
  echo([
    var :tmp_3 = `$`(a)
    :tmp_2 = :tmp_3
    :tmp_2])
finally:
  `=destroy`(:tmp_2)
  `=destroy_1`(a)
-- end of expandArc ------------------------
--expandArc: extractConfig

var lan_ip
try:
  lan_ip = ""
  block label:
    var a_cursor = txt
    var i = 0
    var L = len(a_cursor)
    block label_1:
      while true:
        if op(`<`(i, L)):
          break
        block label_2:
          var splitted
          try:
            var line = a_cursor[i]
            splitted = split(line, " ", -1)
            if `==`(splitted[0], "opt"):
              var :tmp = splitted[1]
              `=copy`(lan_ip, :tmp)
            echo([lan_ip])
            echo([splitted[1]])
          finally:
            `=destroy`(splitted)
        inc(i, 1)
finally:
  `=destroy_1`(lan_ip)
--expandArc: mergeShadowScope

var shadowScope
try:
  var :tmp = c[].currentScope
  `=copy`(shadowScope, :tmp)
  rawCloseScope(c)
  block label:
    var a_cursor = shadowScope[].symbols
    var i = 0
    var L = len(a_cursor)
    block label_1:
      while true:
        if op(`<`(i, L)):
          break
        block label_2:
          var :tmp_1
          var sym = a_cursor[i]
          addInterfaceDecl(c):
            var :tmp_2 = sym
            :tmp_1 = op()
            `=copy_1`(:tmp_1, :tmp_2)
            :tmp_1
          inc(i, 1)
finally:
  `=destroy`(shadowScope)
-- end of expandArc ------------------------
--expandArc: check

var par
try:
  this[].isValid = fileExists(this[].value)
  block label:
    if dirExists(this[].value):
      var :tmp
      par = [type node]((
        var :tmp_1 = this[].value
        :tmp = op()
        `=copy`(:tmp, :tmp_1)
        :tmp, ""))
      break label
    var
      :tmp_2
      :tmp_3
      :tmp_4
    par = [type node]((parentDir(this[].value),
      :tmp_3 = splitPath do:
        var :tmp_5 = this[].value
        :tmp_2 = op()
        `=copy`(:tmp_2, :tmp_5)
        :tmp_2
      :tmp_4 = :tmp_3.tail
      op(:tmp_3.tail)
      :tmp_4))
    `=destroy`(:tmp_3)
  block label_1:
    if dirExists(par.dir):
      var :tmp_6 = this[].matchDirs
      var :tmp_7 = getSubDirs(par.dir, par.front)
      `=sink`(:tmp_6, :tmp_7)
      break label_1
    var :tmp_8 = this[].matchDirs
    var :tmp_9 = []
    `=sink`(:tmp_8, :tmp_9)
finally:
  `=destroy`(par)
-- end of expandArc ------------------------'''
"""

import os

type Target = tuple[repo, package, ext: string]

proc newTarget*(path: string): Target =
  let splat = path.splitFile
  result = (repo: splat.dir, package: splat.name, ext: splat.ext)

echo newTarget("meo")

type
  Node = ref object
    left, right, parent: Node
    value: int

proc delete(target: var Node) =
  var sibling = target.parent.left # b3
  var saved = sibling.right # b3.right -> r4

  sibling.right = saved.left # b3.right -> r4.left = nil
  sibling.parent = saved # b3.parent -> r5 = r4

  #[after this proc:
        b 5
      /   \
    b 3     b 6
  ]#


#[before:
      r 5
    /   \
  b 3    b 6 - to delete
  /    \
empty  r 4
]#
proc main =
  var five = Node(value: 5)

  var six = Node(value: 6)
  six.parent = five
  five.right = six

  var three = Node(value: 3)
  three.parent = five
  five.left = three

  var four = Node(value: 4)
  four.parent = three
  three.right = four

  echo "doing shady stuff..."
  delete(six)
  # need both of these echos
  echo five.left.value
  echo five.right.value

# make sure that the expandArc output has the expected order by directly
# referencing ``delete`` here
let _ = topt_no_cursor.delete

main()

type
  Maybe = object
    value: seq[int]

proc p1(): Maybe =
  let lresult = @[123]
  var lvalue: seq[int]
  var lnext: string
  (lvalue, lnext) = (lresult, ";")

  result.value = move lvalue

proc tissue15130 =
  doAssert p1().value == @[123]

let _ = topt_no_cursor.p1

tissue15130()

type
  KeyValue = tuple[key, val: seq[int]]

proc tt(x: KeyValue) =
  var it = x
  let a = (it.key, it.val)
  echo a

proc encodedQuery =
  var query: seq[KeyValue]
  query.add (key: @[1], val: @[2])

  for elem in query:
    elem.tt()

let _ = topt_no_cursor.tt

encodedQuery()

# bug #15147

proc s(input: string): (string, string) =
  result = (";", "")

proc charmatch(input: string): (string, string) =
  result = ("123", input[0 .. input.high])

proc plus(input: string) =
  var
    lvalue, rvalue: string # cursors
    lnext: string # must be cursor!!!
    rnext: string # cursor
  let lresult = charmatch(input)
  (lvalue, lnext) = lresult

  let rresult = s(lnext)
  (rvalue, rnext) = rresult

plus("123;")

func substrEq(s: string, pos: int, substr: string): bool =
  var i = 0
  var length = substr.len
  while i < length and pos+i < s.len and s[pos+i] == substr[i]:
    inc i
  return i == length

template stringHasSep(s: string, index: int, sep: string): bool =
  s.substrEq(index, sep)

template splitCommon(s, sep, maxsplit, sepLen) =
  var last = 0
  var splits = maxsplit

  while last <= len(s):
    var first = last
    while last < len(s) and not stringHasSep(s, last, sep):
      inc(last)
    if splits == 0: last = len(s)
    yield substr(s, first, last-1)
    if splits == 0: break
    dec(splits)
    inc(last, sepLen)

iterator split(s: string, sep: string, maxsplit = -1): string =
  splitCommon(s, sep, maxsplit, sep.len)

template accResult(iter: untyped) =
  result = @[]
  for x in iter: add(result, x)

func split*(s: string, sep: string, maxsplit = -1): seq[string] =
  accResult(split(s, sep, maxsplit))


let txt = @["opt 192.168.0.1", "static_lease 192.168.0.1"]

# bug #17033

proc extractConfig() =
  var lan_ip = ""

  for line in txt:
    let splitted = line.split(" ")
    if splitted[0] == "opt":
      lan_ip = splitted[1] # "borrow" is conditional and inside a loop.
      # Not good enough...
      # we need a flag that live-ranges are disjoint
    echo lan_ip
    echo splitted[1] # Without this line everything works

extractConfig()


type
  Symbol = ref object
    name: string

  Scope = ref object
    parent: Scope
    symbols: seq[Symbol]

  PContext = ref object
    currentScope: Scope

proc rawCloseScope(c: PContext) =
  c.currentScope = c.currentScope.parent

proc addInterfaceDecl(c: PContext; s: Symbol) =
  c.currentScope.symbols.add s

proc mergeShadowScope*(c: PContext) =
  let shadowScope = c.currentScope
  c.rawCloseScope
  for sym in shadowScope.symbols:
    c.addInterfaceDecl(sym)

mergeShadowScope(PContext(currentScope: Scope(parent: Scope())))

type
  Foo = ref object
    isValid*: bool
    value*: string
    matchDirs*: seq[string]

proc getSubDirs(parent, front: string): seq[string] = @[]

method check(this: Foo) {.base.} =
  this.isValid = fileExists(this.value)
  let par = if dirExists(this.value): (dir: this.value, front: "")
            else: (dir: parentDir(this.value), front: splitPath(this.value).tail)
  if dirExists(par.dir):
    this.matchDirs = getSubDirs(par.dir, par.front)
  else:
    this.matchDirs = @[]

check(Foo())
