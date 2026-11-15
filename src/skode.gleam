//// Skode / "ands": a typed model of the Skred command language.
////
//// Follows the C lexer (parts/ands.c in octetta/pulp), not just the output of
//// any one converter:
////   * atoms are letters plus ! % ^ * _ = : " ' < > ? / \ | ` ; numbers are
////     [-.0-9]+, so `v0w1f440` is three commands and `440 f` works like `f440`
////   * `,` is whitespace; `;`, newline and EOT end a chunk
////   * `[text]` strings, `( ... )` float arrays with sentinels, `$N` `&N` `@N`
////   * `#` comments run to the end of the chunk (so `;` ends one)
////   * `+n` / `~n` defer the rest of the chunk (beats / seconds, negative = ticks);
////     blanks between the sigil and its amount are accepted (see `defer_blanks`)
////   * `[name]: body;` macro definitions (text substitution happens at runtime,
////     so a macro *call* is just an atom here)
//// Commands run "one step behind": an atom takes every number up to the next
//// atom (at most 8), plus numbers that came before it if nothing was pending.
////
//// Not modelled: macro expansion and `$$N`, the C parser's persistent
//// string/array buffers beyond what was parsed since a command last fired,
//// and anything the engine does with a command once it is dispatched.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ---- Types ----

pub type Num {
  Value(Float)
  /// lone `-` `e` `--` `---`: plain NaN, "keep the existing value" / rest
  Rest
  /// lone `.` `_` `..` `...` `__`: NaN with payload 0x7FF8000000000001, a tie
  Tie
}

pub type Arg {
  Lit(Num)
  VarRef(Int)
  StreamRef(Int)
  ReturnRef(Int)
}

/// `+` is beats, `~` is seconds. A negative amount means ticks (tempo steps).
pub type DeferMode {
  Beats
  Seconds
}

pub type Command {
  Command(
    atom: String,
    args: List(Arg),
    array: Option(List(Arg)),
    string: Option(String),
  )
}

pub type Op {
  Voice(Int)
  Note(midi: Int, cents: Option(Float))
  Freq(Float)
  Amp(db: Float)
  Level(Float)
  Pan(Float)
  Wave(Int)
  Mode(Int)
  Loop(Bool)
  Bend(Float)
  BendRange(Int)
  Glide(time: Float, curve: Option(Int))
  Slew(time: Float, curve: Option(Int))
  Detune(wave: Int, cents: Float)
  SampleWindow(Option(#(Int, Int)))
  WaveLoop(wave: Int, start: Int, end: Int)
  Pattern(Int)
  MasterPattern(Int)
  PatternSpeed(Int)
  Run(Bool)
  QueueStart(Bool)
  ClockSpeed(Int)
  Ratchet(Int)
  Goto(Int)
  Clock(bpm: Int, subdivision: Int)
  EmitEvent(Int)
  /// `[ops] x12`
  Step(ops: List(Op), at: Int)
  /// `[ops] e>3`
  OnEvent(ops: List(Op), id: Int)
  Puts(String)
  LoadWave(path: String, id: Int)
  NameWave(name: String, id: Int)
  /// `+4 rest-of-chunk`; consecutive defers in one chunk accumulate in the engine
  Defer(mode: DeferMode, amount: Arg, body: List(Op))
  MacroDef(name: String, body: String)
  /// numbers with no command to take them (the C parser drops these)
  Stray(List(Arg))
  /// any other atom, or a known atom with sentinel/variable/odd arguments
  Generic(Command)
}

/// One chunk: what ends at `;`, a newline or EOT. A comment is always last.
pub type Chunk {
  Chunk(ops: List(Op), remark: Option(String))
}

// ---- Character classes (ASCII, as in the C macros) ----

fn is_digit(c: Int) -> Bool {
  c >= 48 && c <= 57
}

fn is_alpha(c: Int) -> Bool {
  { c >= 65 && c <= 90 } || { c >= 97 && c <= 122 }
}

fn is_num(c: Int) -> Bool {
  is_digit(c) || c == 45 || c == 46
}

fn is_numex(c: Int) -> Bool {
  is_digit(c)
  || { c >= 97 && c <= 102 }
  || { c >= 65 && c <= 70 }
  || list.contains([45, 46, 101, 69, 120, 88, 95], c)
}

fn is_sep(c: Int) -> Bool {
  c == 32 || { c >= 9 && c <= 13 } || c == 44
}

fn is_hsep(c: Int) -> Bool {
  c == 32 || c == 9 || c == 44
}

fn is_chunk_end(c: Int) -> Bool {
  c == 59 || c == 10 || c == 13 || c == 4
}

fn is_atom_char(c: Int) -> Bool {
  is_alpha(c)
  || list.contains(
    [33, 37, 94, 42, 95, 61, 58, 34, 39, 60, 62, 63, 47, 92, 124, 96],
    c,
  )
}

type Class {
  CNum
  CStr
  CArr
  CVar
  CStream
  CRet
  CComment
  CEnd
  CSep
  CDefer
  CCtl
  CAtom
}

fn classify(c: Int) -> Class {
  case is_num(c) {
    True -> CNum
    False ->
      case c {
        91 -> CStr
        40 -> CArr
        36 -> CVar
        38 -> CStream
        64 -> CRet
        35 -> CComment
        43 | 126 -> CDefer
        _ ->
          case is_chunk_end(c), is_sep(c) {
            True, _ -> CEnd
            _, True -> CSep
            _, _ ->
              case c < 32 || c == 127 {
                True -> CCtl
                False -> CAtom
              }
          }
      }
  }
}

// ---- Numbers (strtod as the C parser uses it) ----

fn is_digit_g(g: String) -> Bool {
  string.contains("0123456789", g)
}

fn is_hex_g(g: String) -> Bool {
  string.contains("0123456789abcdefABCDEF", g)
}

fn hex_value(cs: List(String)) -> Float {
  let digits = list.take_while(cs, is_hex_g) |> string.concat
  case int.base_parse(digits, 16) {
    Ok(i) -> int.to_float(i)
    Error(_) -> 0.0
  }
}

fn exponent(cs: List(String)) -> Int {
  case cs {
    [e, ..r] if e == "e" || e == "E" -> {
      let #(neg, r) = case r {
        ["-", ..t] -> #(True, t)
        ["+", ..t] -> #(False, t)
        _ -> #(False, r)
      }
      case list.take_while(r, is_digit_g) {
        [] -> 0
        ds -> {
          let n = result.unwrap(int.parse(string.concat(ds)), 0)
          case neg {
            True -> 0 - n
            False -> n
          }
        }
      }
    }
    _ -> 0
  }
}

fn exp10(n: Int) -> Float {
  case n {
    0 -> 1.0
    _ -> result.unwrap(float.power(10.0, int.to_float(n)), 1.0)
  }
}

fn dec_value(cs: List(String)) -> Float {
  let #(ip, r1) = list.split_while(cs, is_digit_g)
  let #(fp, r2) = case r1 {
    [".", ..r] -> list.split_while(r, is_digit_g)
    _ -> #([], r1)
  }
  case ip, fp {
    [], [] -> 0.0
    _, _ -> {
      let i = case ip {
        [] -> "0"
        _ -> string.concat(ip)
      }
      let f = case fp {
        [] -> "0"
        _ -> string.concat(fp)
      }
      result.unwrap(float.parse(i <> "." <> f), 0.0) *. exp10(exponent(r2))
    }
  }
}

fn strtod(s: String) -> Float {
  let cs = string.to_graphemes(s)
  let #(neg, cs) = case cs {
    ["-", ..r] -> #(True, r)
    ["+", ..r] -> #(False, r)
    _ -> #(False, cs)
  }
  let v = case cs {
    ["0", x, ..r] if x == "x" || x == "X" -> hex_value(r)
    _ -> dec_value(cs)
  }
  case neg {
    True -> float.negate(v)
    False -> v
  }
}

fn strtod_num(s: String) -> Num {
  case s {
    "-" | "e" | "--" | "---" -> Rest
    "." | "_" | ".." | "..." | "__" -> Tie
    _ -> Value(strtod(s))
  }
}

// ---- Lexer ----

type Elem {
  EAtom(String)
  EArg(Arg)
  EArray(List(Arg))
  EStr(String)
  EComment(String)
  EDefer(DeferMode, Arg, String)
  EMacro(String, String)
  EEnd
}

fn codes(src: String) -> List(Int) {
  string.to_utf_codepoints(src) |> list.map(string.utf_codepoint_to_int)
}

fn text_fwd(cs: List(Int)) -> String {
  cs |> list.filter_map(string.utf_codepoint) |> string.from_utf_codepoints
}

fn text_rev(cs: List(Int)) -> String {
  text_fwd(list.reverse(cs))
}

/// Up to three digits, as `$N` `&N` `@N` take.
fn take_var(cs: List(Int)) -> #(Option(Int), List(Int)) {
  let #(ds, rest) = take_digits(cs, 3, [])
  case ds {
    [] -> #(None, cs)
    _ -> #(Some(list.fold(ds, 0, fn(n, c) { n * 10 + c - 48 })), rest)
  }
}

fn take_digits(
  cs: List(Int),
  n: Int,
  acc: List(Int),
) -> #(List(Int), List(Int)) {
  case n, cs {
    0, _ -> #(list.reverse(acc), cs)
    _, [c, ..rest] ->
      case is_digit(c) {
        True -> take_digits(rest, n - 1, [c, ..acc])
        False -> #(list.reverse(acc), cs)
      }
    _, [] -> #(list.reverse(acc), [])
  }
}

fn lex(cs: List(Int), acc: List(Elem)) -> List(Elem) {
  case cs {
    [] -> list.reverse(acc)
    [c, ..rest] ->
      case classify(c) {
        CNum -> {
          let #(more, rest) = list.split_while(rest, is_num)
          // the C parser swallows a `$` that directly follows a number
          let rest = case rest {
            [36, ..r] -> r
            _ -> rest
          }
          lex(rest, [EArg(Lit(strtod_num(text_fwd([c, ..more])))), ..acc])
        }
        CStr -> lex_bracket(rest, acc)
        CArr -> lex_array(rest, [], [], acc)
        CVar ->
          case take_var(rest) {
            #(Some(n), r) -> lex(r, [EArg(VarRef(n)), ..acc])
            #(None, r) -> lex(r, acc)
          }
        CStream ->
          case take_var(rest) {
            #(Some(n), r) -> lex(r, [EArg(StreamRef(n)), ..acc])
            #(None, r) -> lex(r, acc)
          }
        CRet ->
          case take_var(rest) {
            #(Some(n), r) -> lex(r, [EArg(ReturnRef(n)), ..acc])
            #(None, r) -> lex(r, acc)
          }
        CComment -> {
          let #(body, r) = list.split_while(rest, fn(x) { !is_chunk_end(x) })
          lex(r, [EComment(text_fwd(body)), ..acc])
        }
        CEnd -> lex(rest, [EEnd, ..acc])
        CSep | CCtl -> lex(rest, acc)
        // a defer sigil first ends the current chunk
        CDefer -> lex_defer(c, rest, [EEnd, ..acc])
        CAtom -> {
          let #(more, r) = list.split_while(rest, is_atom_char)
          lex(r, [EAtom(text_fwd([c, ..more])), ..acc])
        }
      }
  }
}

/// After `[`: a macro definition `[name]: body;` or a string up to the first `]`.
/// An unterminated string swallows the rest of the input, as in the C parser.
fn lex_bracket(rest: List(Int), acc: List(Elem)) -> List(Elem) {
  let #(inner, after) = list.split_while(rest, fn(x) { x != 93 })
  case after {
    [] -> list.reverse(acc)
    [_, ..tail] ->
      case macro_def(inner, tail) {
        Some(#(name, body, remaining)) ->
          lex(remaining, [EMacro(name, body), ..acc])
        None -> lex(tail, [EStr(text_fwd(inner)), ..acc])
      }
  }
}

fn macro_def(
  inner: List(Int),
  tail: List(Int),
) -> Option(#(String, String, List(Int))) {
  let valid =
    inner != [] && list.length(inner) <= 31 && list.all(inner, is_atom_char)
  case valid {
    False -> None
    True ->
      case list.drop_while(tail, is_hsep) {
        [58, ..body_start] -> {
          let #(body, remaining) =
            list.split_while(body_start, fn(x) { !is_chunk_end(x) })
          let remaining = case remaining {
            [59, ..r] -> r
            _ -> remaining
          }
          Some(#(text_fwd(inner), text_fwd(body), remaining))
        }
        _ -> None
      }
  }
}

fn flush_num(buf: List(Int), items: List(Arg)) -> List(Arg) {
  case buf {
    [] -> items
    _ -> [Lit(strtod_num(text_rev(buf))), ..items]
  }
}

/// Inside `( ... )`: separators (incl. newlines) split numbers, other
/// characters are ignored, and an unterminated array is never completed.
fn lex_array(
  cs: List(Int),
  buf: List(Int),
  items: List(Arg),
  acc: List(Elem),
) -> List(Elem) {
  case cs {
    [] -> list.reverse(acc)
    [c, ..rest] ->
      case c {
        41 -> lex(rest, [EArray(list.reverse(flush_num(buf, items))), ..acc])
        36 -> {
          let items = flush_num(buf, items)
          case take_var(rest) {
            #(Some(n), r) -> lex_array(r, [], [VarRef(n), ..items], acc)
            #(None, r) -> lex_array(r, [], items, acc)
          }
        }
        38 -> {
          let items = flush_num(buf, items)
          case take_var(rest) {
            #(Some(n), r) -> lex_array(r, [], [StreamRef(n), ..items], acc)
            #(None, r) -> lex_array(r, [], items, acc)
          }
        }
        _ ->
          case is_numex(c), is_sep(c) {
            True, _ -> lex_array(rest, [c, ..buf], items, acc)
            _, True -> lex_array(rest, [], flush_num(buf, items), acc)
            _, _ -> lex_array(rest, buf, items, acc)
          }
      }
  }
}

/// Whether `+ 4 v0` / `~ 1.5 f 440` (blanks between the sigil and its amount)
/// read as the guide documents them. This matches the fixed C parser
/// (ands-defer-space.patch). Set it to False to preview against an engine
/// build that predates the fix, where such a defer is a zero delay whose body
/// starts with the number.
pub const defer_blanks = True

/// Skip blanks after a defer sigil, but only when an amount (number, `$N`,
/// `&N`) follows them, and never across a chunk end.
fn skip_defer_blanks(cs: List(Int)) -> List(Int) {
  case defer_blanks {
    False -> cs
    True -> {
      let after = list.drop_while(cs, fn(x) { is_sep(x) && !is_chunk_end(x) })
      case after {
        [c, ..] ->
          case is_num(c) || c == 36 || c == 38 {
            True -> after
            False -> cs
          }
        [] -> cs
      }
    }
  }
}

/// `+n` / `~n` then the rest of the chunk, up to the next defer sigil. The
/// amount is a number, `$N` or `&N` (digits only after the sigil character).
fn lex_defer(c: Int, rest: List(Int), acc: List(Elem)) -> List(Elem) {
  let rest = skip_defer_blanks(rest)
  let mode = case c == 43 {
    True -> Beats
    False -> Seconds
  }
  let #(amount, after) = case rest {
    [36, ..r] ->
      case take_var(r) {
        #(Some(n), r2) -> #(VarRef(n), r2)
        #(None, r2) -> #(Lit(Value(0.0)), r2)
      }
    [38, ..r] ->
      case take_var(r) {
        #(Some(n), r2) -> #(StreamRef(n), r2)
        #(None, r2) -> #(Lit(Value(0.0)), r2)
      }
    _ -> {
      let #(ds, r) = list.split_while(rest, is_num)
      #(Lit(strtod_num(text_fwd(ds))), r)
    }
  }
  let #(body, tail) =
    list.split_while(after, fn(x) { x != 43 && x != 126 && !is_chunk_end(x) })
  let acc = [EDefer(mode, amount, text_fwd(body)), ..acc]
  case tail {
    [s, ..r] if s == 43 || s == 126 -> lex_defer(s, r, acc)
    [_, ..r] -> lex(r, [EEnd, ..acc])
    [] -> list.reverse(acc)
  }
}

// ---- Grouping: atoms take their arguments one step behind ----

const arg_max = 8

type Acc {
  Acc(
    done: List(Chunk),
    ops: List(Op),
    remark: Option(String),
    atom: Option(String),
    args: List(Arg),
    n: Int,
    arr: Option(List(Arg)),
    str: Option(String),
  )
}

fn fire(a: Acc) -> Acc {
  case a.atom {
    Some(atom) ->
      Acc(
        ..a,
        ops: [
          interpret(Command(atom, list.reverse(a.args), a.arr, a.str)),
          ..a.ops
        ],
        atom: None,
        args: [],
        n: 0,
        arr: None,
        str: None,
      )
    None -> a
  }
}

fn step(a: Acc, e: Elem) -> Acc {
  case e {
    EArg(x) ->
      case a.n < arg_max {
        True -> Acc(..a, args: [x, ..a.args], n: a.n + 1)
        False -> a
      }
    EArray(items) -> Acc(..a, arr: Some(items))
    EStr(s) -> Acc(..a, str: Some(s))
    EAtom(x) -> Acc(..fire(a), atom: Some(x))
    EComment(c) -> Acc(..a, remark: Some(c))
    EDefer(mode, amount, body) ->
      Acc(..a, ops: [Defer(mode, amount, parse_ops(body)), ..a.ops])
    EMacro(name, body) -> Acc(..a, ops: [MacroDef(name, body), ..a.ops])
    EEnd -> {
      let a = fire(a)
      let ops = case a.args {
        [] -> a.ops
        _ -> [Stray(list.reverse(a.args)), ..a.ops]
      }
      let done = case ops, a.remark {
        [], None -> a.done
        _, _ -> [Chunk(list.reverse(ops), a.remark), ..a.done]
      }
      Acc(..a, done: done, ops: [], remark: None, args: [], n: 0)
    }
  }
}

pub fn parse_program(src: String) -> List(Chunk) {
  let init =
    Acc(
      done: [],
      ops: [],
      remark: None,
      atom: None,
      args: [],
      n: 0,
      arr: None,
      str: None,
    )
  let a = list.fold(lex(codes(src), []), init, step)
  list.reverse(step(a, EEnd).done)
}

/// All ops of a program, chunk boundaries and comments dropped.
pub fn parse_ops(src: String) -> List(Op) {
  parse_program(src) |> list.flat_map(fn(c) { c.ops })
}

// ---- Typed interpretation of common commands ----

fn plain(args: List(Arg)) -> Option(List(Float)) {
  list.try_map(args, fn(a) {
    case a {
      Lit(Value(f)) -> Ok(f)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn as_int(f: Float) -> Option(Int) {
  let t = float.truncate(f)
  case int.to_float(t) == f {
    True -> Some(t)
    False -> None
  }
}

fn with_int(cmd: Command, f: Float, ctor: fn(Int) -> Op) -> Op {
  case as_int(f) {
    Some(i) -> ctor(i)
    None -> Generic(cmd)
  }
}

fn with_int2(cmd: Command, a: Float, b: Float, ctor: fn(Int, Int) -> Op) -> Op {
  case as_int(a), as_int(b) {
    Some(x), Some(y) -> ctor(x, y)
    _, _ -> Generic(cmd)
  }
}

fn interpret(cmd: Command) -> Op {
  case plain(cmd.args) {
    None -> Generic(cmd)
    Some(fs) -> typed(cmd, fs)
  }
}

fn typed(cmd: Command, fs: List(Float)) -> Op {
  case cmd.atom, fs, cmd.string, cmd.array {
    "v", [a], None, None -> with_int(cmd, a, Voice)
    "n", [a], None, None -> with_int(cmd, a, fn(m) { Note(m, None) })
    "n", [a, c], None, None -> with_int(cmd, a, fn(m) { Note(m, Some(c)) })
    "f", [a], None, None -> Freq(a)
    "a", [a], None, None -> Amp(a)
    "l", [a], None, None -> Level(a)
    "p", [a], None, None -> Pan(a)
    "w", [a], None, None -> with_int(cmd, a, Wave)
    "m", [a], None, None -> with_int(cmd, a, Mode)
    "B", [a], None, None -> Loop(a != 0.0)
    "fb", [a], None, None -> Bend(a)
    "fbp", [a], None, None -> with_int(cmd, a, BendRange)
    "g", [], None, None -> Glide(0.0, None)
    "g", [t], None, None -> Glide(t, None)
    "g", [t, c], None, None -> with_int(cmd, c, fn(ci) { Glide(t, Some(ci)) })
    "s", [t], None, None -> Slew(t, None)
    "s", [t, c], None, None -> with_int(cmd, c, fn(ci) { Slew(t, Some(ci)) })
    "N", [w, c], None, None -> with_int(cmd, w, fn(wi) { Detune(wi, c) })
    "VS", [], None, None -> SampleWindow(None)
    "VS", [a, b], None, None ->
      with_int2(cmd, a, b, fn(x, y) { SampleWindow(Some(#(x, y))) })
    "WL", [a, b, c], None, None ->
      with_int2(cmd, a, b, fn(x, y) {
        with_int(cmd, c, fn(z) { WaveLoop(x, y, z) })
      })
    "y", [a], None, None -> with_int(cmd, a, Pattern)
    "yp", [a], None, None -> with_int(cmd, a, MasterPattern)
    "%", [a], None, None -> with_int(cmd, a, PatternSpeed)
    "z", [a], None, None -> Run(a != 0.0)
    "zq", [a], None, None -> QueueStart(a != 0.0)
    "z%", [a], None, None -> with_int(cmd, a, ClockSpeed)
    "z*", [a], None, None -> with_int(cmd, a, Ratchet)
    "zg", [a], None, None -> with_int(cmd, a, Goto)
    "M", [a, b], None, None -> with_int2(cmd, a, b, Clock)
    "ce", [a], None, None -> with_int(cmd, a, EmitEvent)
    "x", [a], Some(s), None -> with_int(cmd, a, fn(i) { Step(parse_ops(s), i) })
    "e>", [a], Some(s), None ->
      with_int(cmd, a, fn(i) { OnEvent(parse_ops(s), i) })
    "puts", [], Some(s), None -> Puts(s)
    "/ws", [a], Some(s), None -> with_int(cmd, a, fn(i) { LoadWave(s, i) })
    "wt", [a], Some(s), None -> with_int(cmd, a, fn(i) { NameWave(s, i) })
    _, _, _, _ -> Generic(cmd)
  }
}

// ---- Printer (canonical: atom then comma-joined numbers) ----

/// Whole numbers print without a decimal point. A float Gleam would print in
/// exponent form (e.g. 1.0e-5) prints as its integer part, because the C lexer
/// has no exponent syntax outside arrays.
fn fmt(f: Float) -> String {
  let t = float.truncate(f)
  case int.to_float(t) == f {
    True -> int.to_string(t)
    False -> {
      let s = float.to_string(f)
      case string.contains(s, "e") {
        True -> int.to_string(t)
        False -> s
      }
    }
  }
}

fn i(x: Int) -> String {
  int.to_string(x)
}

fn digit(b: Bool) -> String {
  case b {
    True -> "1"
    False -> "0"
  }
}

fn curve(c: Option(Int)) -> String {
  case c {
    Some(n) -> "," <> i(n)
    None -> ""
  }
}

pub fn arg_to_string(a: Arg) -> String {
  case a {
    Lit(Value(f)) -> fmt(f)
    Lit(Rest) -> "-"
    Lit(Tie) -> "."
    VarRef(n) -> "$" <> i(n)
    StreamRef(n) -> "&" <> i(n)
    ReturnRef(n) -> "@" <> i(n)
  }
}

fn command_to_string(c: Command, first: Bool) -> String {
  let args = case c.args {
    [] -> ""
    xs -> string.join(list.map(xs, arg_to_string), ",")
  }
  let arr = case c.array {
    Some(xs) -> " ( " <> string.join(list.map(xs, arg_to_string), " ") <> " )"
    None -> ""
  }
  let body = c.atom <> args <> arr
  case c.string {
    Some(t) -> with_str(first, t, body)
    None -> body
  }
}

/// A string attaches to whichever atom fires next, so `[s] atom` only means
/// what it says at the start of a chunk; later in a chunk the string goes
/// after its atom's arguments.
fn with_str(first: Bool, s: String, atom_part: String) -> String {
  case first {
    True -> "[" <> s <> "] " <> atom_part
    False -> atom_part <> " [" <> s <> "]"
  }
}

pub fn op_to_string(op: Op) -> String {
  op_text(op, True)
}

fn op_text(op: Op, first: Bool) -> String {
  case op {
    Voice(n) -> "v" <> i(n)
    Note(m, None) -> "n" <> i(m)
    Note(m, Some(c)) -> "n" <> i(m) <> "," <> fmt(c)
    Freq(x) -> "f" <> fmt(x)
    Amp(x) -> "a" <> fmt(x)
    Level(x) -> "l" <> fmt(x)
    Pan(x) -> "p" <> fmt(x)
    Wave(n) -> "w" <> i(n)
    Mode(n) -> "m" <> i(n)
    Loop(b) -> "B" <> digit(b)
    Bend(x) -> "fb" <> fmt(x)
    BendRange(n) -> "fbp" <> i(n)
    Glide(t, c) -> "g" <> fmt(t) <> curve(c)
    Slew(t, c) -> "s" <> fmt(t) <> curve(c)
    Detune(w, c) -> "N" <> i(w) <> "," <> fmt(c)
    SampleWindow(None) -> "VS"
    SampleWindow(Some(#(a, b))) -> "VS" <> i(a) <> "," <> i(b)
    WaveLoop(w, a, b) -> "WL " <> i(w) <> "," <> i(a) <> "," <> i(b)
    Pattern(n) -> "y" <> i(n)
    MasterPattern(n) -> "yp" <> i(n)
    PatternSpeed(n) -> "%" <> i(n)
    Run(b) -> "z" <> digit(b)
    QueueStart(b) -> "zq" <> digit(b)
    ClockSpeed(n) -> "z%" <> i(n)
    Ratchet(n) -> "z*" <> i(n)
    Goto(n) -> "zg" <> i(n)
    Clock(b, d) -> "M" <> i(b) <> "," <> i(d)
    EmitEvent(n) -> "ce " <> i(n)
    Step(ops, at) -> with_str(first, ops_to_string(ops), "x" <> i(at))
    OnEvent(ops, id) -> with_str(first, ops_to_string(ops), "e>" <> i(id))
    Puts(t) -> with_str(first, t, "puts")
    LoadWave(p, n) -> with_str(first, p, "/ws " <> i(n))
    NameWave(name, n) -> with_str(first, name, "wt " <> i(n))
    Defer(mode, amount, body) ->
      case mode {
        Beats -> "+"
        Seconds -> "~"
      }
      <> arg_to_string(amount)
      <> " "
      <> ops_to_string(body)
    MacroDef(name, body) -> "[" <> name <> "]:" <> body <> ";"
    Stray(args) -> string.join(list.map(args, arg_to_string), " ")
    Generic(c) -> command_to_string(c, first)
  }
}

/// A defer swallows the rest of its chunk, so an op list that puts anything
/// after a Defer will not read back the same. Parsed chunks never do.
pub fn ops_to_string(ops: List(Op)) -> String {
  ops
  |> list.index_map(fn(op, idx) { op_text(op, idx == 0) })
  |> string.join(" ")
}

pub fn chunk_to_string(c: Chunk) -> String {
  let body = ops_to_string(c.ops)
  case c.remark {
    None -> body
    Some(r) ->
      case body {
        "" -> "#" <> r
        _ -> body <> " #" <> r
      }
  }
}

pub fn program_to_string(chunks: List(Chunk)) -> String {
  chunks |> list.map(chunk_to_string) |> string.join("\n")
}

/// Atoms the typed layer doesn't know (still valid, still sent as typed).
pub fn generic_atoms(ops: List(Op)) -> List(String) {
  list.flat_map(ops, fn(op) {
    case op {
      Generic(c) -> [c.atom]
      Step(inner, _) | OnEvent(inner, _) -> generic_atoms(inner)
      Defer(_, _, inner) -> generic_atoms(inner)
      _ -> []
    }
  })
}
