(* $Id$ *)

open Printf

open Cppo_types

module S = Set.Make (String)
module M = Map.Make (String)

let line_directive buf prev_file pos =
  let file = pos.Lexing.pos_fname in
  (match prev_file with
       Some s when s = file ->
	 bprintf buf "\n# %i\n"
	   pos.Lexing.pos_lnum
     | _ ->
	 bprintf buf "\n# %i %S\n"
	   pos.Lexing.pos_lnum
	   pos.Lexing.pos_fname
  );
  bprintf buf "%s" (String.make (pos.Lexing.pos_cnum - pos.Lexing.pos_bol) ' ')
    
let rec add_sep sep last = function
    [] -> [ last ]
  | [x] -> [ x; last ]
  | x :: l -> x :: sep :: add_sep sep last l 


let strip s =
  let len = String.length s in
  let is_space = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false in
  let first = 
    let x = ref len in
    (try
       for i = 0 to len - 1 do
	 if not (is_space s.[i]) then (
	   x := i;
	   raise Exit
	 )
       done
     with Exit -> ()
    );
    !x
  in
  let last =
    let x = ref (-1) in
    (try
       for i = len - 1 downto 0 do
	 if not (is_space s.[i]) then (
	   x := i;
	   raise Exit
	 )
       done
     with Exit -> ()
    );
    !x
  in
  if first <= last then
    String.sub s first (last - first + 1)
  else
    ""

let int_of_string_with_space s =
  try Some (Int64.of_string (strip s))
  with _ -> None

let remove_space l =
  List.filter (function `Text (_, (true, _)) -> false | _ -> true) l


let rec eval_int env (x : arith_expr) : int64 =
  match x with
      `Int x -> x
    | `Ident (loc, name) ->
	let l =
	  try
	    match M.find name env with
		`Def (_, _, l, _) -> l
	      | `Defun _ -> 
		  error loc (sprintf "%S expects arguments" name)
	  with Not_found -> error loc (sprintf "Undefined identifier %S" name)
	in
	(try
	   match remove_space l with
	       [ `Ident (loc, name, None) ] -> 
		 eval_int env (`Ident (loc, name))
	     | _ ->
		 let text =
		   List.map (
		     function
			 `Text (_, (is_space, s)) -> s
		       | _ ->
			   error loc
			     (sprintf
				"Identifier %S is not bound to a constant"
				name)
		   ) l
		 in
		 let s = String.concat "" text in
		 (match int_of_string_with_space s with
		      None -> 
			error loc 
			  (sprintf
			     "Identifier %S is not bound to an int literal"
			     name)
		    | Some n -> n
		 )
	 with Cppo_error s ->
	   error loc (sprintf "Identifier %S does not expand to an int:\n%s"
			name s)
	)

    | `Neg x -> Int64.neg (eval_int env x)
    | `Add (a, b) -> Int64.add (eval_int env a) (eval_int env b)
    | `Sub (a, b) -> Int64.sub (eval_int env a) (eval_int env b)
    | `Mul (a, b) -> Int64.mul (eval_int env a) (eval_int env b)
    | `Div (loc, a, b) ->
	(try Int64.div (eval_int env a) (eval_int env b)
	 with Division_by_zero ->
	   error loc "Division by zero")

    | `Mod (loc, a, b) -> 
	(try Int64.rem (eval_int env a) (eval_int env b)
	 with Division_by_zero ->
	   error loc "Division by zero")

    | `Lnot a -> Int64.lognot (eval_int env a)

    | `Lsl (a, b) ->
	let n = eval_int env a in
	let shift = eval_int env b in
	if shift >= 64L || shift <= -64L then 0L
	else 
	  Int64.shift_left n (Int64.to_int shift)

    | `Lsr (a, b) ->
	let n = eval_int env a in
	let shift = eval_int env b in
	if shift >= 64L || shift <= -64L then 0L
	else 
	  Int64.shift_right_logical n (Int64.to_int shift)

    | `Asr (a, b) ->
	let n = eval_int env a in
	let shift = eval_int env b in
	if shift >= 64L || shift <= -64L then 0L
	else 
	  Int64.shift_right n (Int64.to_int shift)

    | `Land (a, b) -> Int64.logand (eval_int env a) (eval_int env b)
    | `Lor (a, b) -> Int64.logor (eval_int env a) (eval_int env b)
    | `Lxor (a, b) -> Int64.logxor (eval_int env a) (eval_int env b)
	

let rec eval_bool env (x : bool_expr) =
  match x with
      `True -> true
    | `False -> false
    | `Defined s -> M.mem s env
    | `Not x -> not (eval_bool env x)
    | `And (a, b) -> eval_bool env a && eval_bool env b
    | `Or (a, b) -> eval_bool env a || eval_bool env b
    | `Eq (a, b) -> eval_int env a = eval_int env b
    | `Lt (a, b) -> eval_int env a < eval_int env b
    | `Gt (a, b) -> eval_int env a > eval_int env b

    
type globals = {
  call_loc : Cppo_types.loc;
    (* location used to set the value of
       __FILE__ and __LINE__ global variables *)

  buf : Buffer.t;
    (* buffer where the output is written *)

  included : S.t;
    (* set of already-included files *)

  require_location : bool ref;
    (* whether a line directive should be printed before outputting the next
       token *)

  last_file_loc : string option ref;
    (* used to test whether a line directive should include the file name *)
}

let parse file ic =
  let lexbuf = Lexing.from_channel ic in
  let lexer_env = Cppo_lexer.init file lexbuf in
  try
    Cppo_parser.main (Cppo_lexer.line lexer_env) lexbuf
  with Parsing.Parse_error ->
    error (Cppo_lexer.loc lexbuf) "syntax error"

let plural n =
  if abs n <= 1 then ""
  else "s"


let maybe_print_location g pos =
  let prev_file = !(g.last_file_loc) in
  let file = pos.Lexing.pos_fname in
  if !(g.require_location) then (
    line_directive g.buf prev_file pos;
    g.last_file_loc := Some file
  )

let rec include_file g file env =
  if S.mem file g.included then
    failwith (sprintf "Cyclic inclusion of file %S" file)
  else
    let ic = open_in_bin file in
    let l = parse file ic in
    close_in ic;
    expand_list { g with included = S.add file g.included } env l

and expand_list ?(top = false) g env l =
  List.fold_left (expand_node ~top g) env l

and expand_node ?(top = false) g env0 x =
  match x with
      `Ident (loc, name, opt_args) ->

	let def =
	  try Some (M.find name env0)
	  with Not_found -> None
	in
	let g =
	  if top && def <> None then
	    { g with call_loc = loc }
	  else g
	in

	if def = None then (
	  maybe_print_location g (fst loc);
	  g.require_location := false
	)
	else
	  g.require_location := true;

	(match def, opt_args with
	     None, None -> expand_node g env0 (`Text (loc, (false, name)))
	   | None, Some args ->
	       let with_sep = 
		 add_sep
		   [`Text (loc, (false, ","))]
		   [`Text (loc, (false, ")"))]
		   args in
	       let l =
		 `Text (loc, (false, name ^ "(")) :: List.flatten with_sep in
	       expand_list g env0 l
		 
	   | Some (`Defun (_, _, arg_names, _, _)), None ->
	       error loc 
		 (sprintf "%S expects %i arguments but is applied to none." 
		    name (List.length arg_names))
		 
	   | Some (`Def _), Some l ->
	       error loc 
		 (sprintf "%S expects no arguments" name)
		 
	   | Some (`Def (_, _, l, env)), None ->
	       ignore (expand_list g env l);
	       env0
		 
	   | Some (`Defun (_, _, arg_names, l, env)), Some args ->
	       let argc = List.length arg_names in
	       let n = List.length args in
	       let args =
		 (* it's ok to pass an empty arg if one arg
		    is expected *)
		 if n = 0 && argc = 1 then [[]]
		 else args
	       in
	       if argc <> n then
		 error loc
		   (sprintf "%S expects %i argument%s but is applied to \
                               %i argument%s."
		      name argc (plural argc) n (plural n))
	       else
		 let app_env =
		   List.fold_left2 (
		     fun env name l ->
		       M.add name (`Def (loc, name, l, env0)) env
		   ) env arg_names args
		 in
		 ignore (expand_list g app_env l);
		 env0
	)

    | `Def (loc, name, body)-> 
	g.require_location := true;
	if M.mem name env0 then
	  error loc (sprintf "%S is already defined" name)
	else
	  M.add name (`Def (loc, name, body, env0)) env0

    | `Defun (loc, name, arg_names, body) ->
	g.require_location := true;
	if M.mem name env0 then
	  error loc (sprintf "%S is already defined" name)
	else	
	  M.add name (`Defun (loc, name, arg_names, body, env0)) env0

    | `Undef (loc, name) ->
	g.require_location := true;
	M.remove name env0

    | `Include (loc, file) ->
	g.require_location := true;
	include_file g file env0

    | `Cond (loc, test, if_true, if_false) ->
	let l =
	  if eval_bool env0 test then if_true
	  else if_false
	in
	g.require_location := true;
	expand_list g env0 l

    | `Error (loc, msg) ->
	error loc msg

    | `Warning (loc, msg) ->
	warning loc msg;
	env0

    | `Text (loc, (is_space, s)) ->
	if not is_space then (
	  maybe_print_location g (fst loc);
	  g.require_location := false
	);
	Buffer.add_string g.buf s;
	env0

    | `Seq l ->
	expand_list g env0 l

    | `Line (opt_file, n) ->
	g.require_location := true;
	(match opt_file with
	     None -> bprintf g.buf "\n# %i\n" n
	   | Some file -> bprintf g.buf "\n# %i %S\n" n file
	);
	env0

    | `Current_line loc ->
	maybe_print_location g (fst loc);
	g.require_location := true;
	let pos, _ = g.call_loc in
	bprintf g.buf " %i " pos.Lexing.pos_lnum;
	env0

    | `Current_file loc ->
	maybe_print_location g (fst loc);
	g.require_location := true;
	let pos, _ = g.call_loc in
	bprintf g.buf " %S " pos.Lexing.pos_fname;
	env0

	  


let include_channels buf env l =
  List.fold_left (
    fun env (file, open_, close) ->
      let l = parse file (open_ ()) in
      close ();
      let g = {
	call_loc = dummy_loc;
	buf = buf;
	included = S.empty;
	require_location = ref true;
	last_file_loc = ref None
      }
      in
      expand_list ~top:true { g with included = S.add file g.included } env l
  ) env l
