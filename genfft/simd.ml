(*
 * Copyright (c) 1997-1999 Massachusetts Institute of Technology
 * Copyright (c) 2000 Matteo Frigo
 * Copyright (c) 2000 Steven G. Johnson
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 *)
(* $Id: simd.ml,v 1.3 2002-06-22 02:19:20 athena Exp $ *)

open Expr
open List
open Printf
open Variable
open Annotate
open Simdmagic
open C

let realtype = "V"
let realtypep = realtype ^ " *"
let constrealtype = "const " ^ realtype
let constrealtypep = constrealtype ^ " *"


(*
 * SIMD C AST unparser 
 *)
let foldr_string_concat l = fold_right (^) l ""

let first_simd_load v = function 
  | MUseReIm(MLoad,v1,e1,v2,e2) -> v == v1	(* wait for 1st load *)
  | _ -> false

let first_simd_twiddle_load v = function
  | MTwid2(_,s1,_,_) -> s1 == v
  | _ -> false

let second_simd_store v = function 
  | MUseReIm(MStore,v1,e1,v2,e2) -> v == v2	(* wait for 2nd store *)
  | _ -> false

let simdLoadString () =  ("LD", "ivs")

let simdStoreString () = ("ST", "ovs")

let cmp_locations v v' = compare (var_index v) (var_index v')

let rec last = function
  | [] -> failwith "last"
  | [a] -> a
  | _::xs -> last xs

let last_transpose_simd_store dst = function
  | MTransposes zs -> Variable.same (fst (last zs)) dst
  | _ 		   -> false

let rec listToString toString separator = function
  | [] -> ""
  | [x] -> toString x
  | x::xs -> (toString x) ^ separator ^ (listToString toString separator xs)

let rec unparse_load vardeclinfo dst src = 
  (* TODO *)
  if true then
    sprintf "LD(%s,%s);\n" (Variable.unparse dst) (Variable.unparse src)
  else
    match Util.find_elem (first_simd_load src) vardeclinfo with
    | Some (MUseReIm(MLoad,v1,e1,v2,e2)) ->
	let (macro_name,ivectstride) = simdLoadString () in
	let (e1',e2') = 
	  if Variable.is_real v1 then (e1,e2) 
	  else if Variable.is_real v2 then (e2,e1)
	  else failwith "unparse_load"
	in sprintf 	"%s(%s,%s,%s%s);\n" 
	  macro_name 
	  (unparse_expr e1') 
	  (unparse_expr e2')
	  (Variable.unparse src)
	  ivectstride
    | _ -> ""

and unparse_store vardeclinfo dst src_expr =
  (* TODO *)
  if true then
    sprintf "ST(%s,%s);\n" (Variable.unparse dst) (unparse_expr src_expr)
  else
    match Util.find_elem (second_simd_store dst) vardeclinfo with
    | Some (MUseReIm(MStore,v1,e1,v2,e2)) ->
	let (macro_name, ovectstride) = simdStoreString () in
	let (e1',e2') = 
	  if Variable.is_real v1 then (e1,e2) 
	  else if Variable.is_real v2 then (e2,e1)
	  else failwith "unparse_store"
	in sprintf  "%s(%s,%s,%s%s);\n"
	  macro_name
	  (unparse_expr e1')
	  (unparse_expr e2')
	  (Variable.unparse dst)
	  ovectstride
    | _ -> ""


and unparse_store_transposed vardeclinfo  dst src_expr =
  match Util.find_elem (last_transpose_simd_store dst) vardeclinfo with
  | Some (MTransposes zs) ->
      let zs' = List.sort (fun (v,_) (v',_) -> cmp_locations v v') zs and
          mybase = (var_index dst / !vector_length) and
          myname = (if is_real dst then "r" else "i") and
          mystride = (!transform_length / !vector_length) in
      (if !vector_length = 4 then
	sprintf "ST4(%so + %d, %so + %d + %s, %so + %d + %s, %so + %d + %s, %s);\n"
	  myname mybase
	  myname mybase "ovs"
          myname mybase "2 * ovs"
          myname mybase "3 * ovs"
	  (listToString unparse_expr ", " (map snd zs'))
      else
	sprintf "ST2(%so + %d, %so + %d + %s, %s);\n"
	  myname mybase
	  myname mybase "ovs"
	  (listToString unparse_expr ", " (map snd zs'))
      )
  | _ -> ""

and unparse_load_twiddle_vect vardeclinfo  dst src = 
  sprintf "LD(%s,W+2 * (%s)+%s);\n" 
    (Variable.unparse dst) 
    (string_of_int (Variable.var_index src))
    (if Variable.is_real src then "0" else "1")


and unparse_expr =
  let rec unparse_plus = function
    | [a] -> unparse_expr a
    | (Uminus (Times (a, b))) :: c :: d -> op "VFNMS" a b (c :: d)
    | c :: (Uminus (Times (a, b))) :: d -> op "VFNMS" a b (c :: d)
    | (Times (a, b)) :: (Uminus c) :: d -> op "VFMS" a b (c :: negate d)
    | (Uminus c) :: (Times (a, b)) :: d -> op "VFMS" a b (c :: negate d)
    | (Times (a, b)) :: c :: d          -> op "VFMA" a b (c :: d)
    | c :: (Times (a, b)) :: d          -> op "VFMA" a b (c :: d)
    | (Uminus a :: b)                   -> op2 "VSUB" a b
    | (b :: Uminus a :: c)              -> op2 "VSUB" a (b :: c)
    | (a :: b)                          -> op2 "VADD" a b
    | [] -> failwith "unparse_plus"
  and op nam a b c =
    nam ^ "(" ^ (unparse_expr a) ^ ", " ^ (unparse_expr b) ^ ", " ^
    (unparse_plus c) ^ ")"
  and op2 nam a b = 
    nam ^ "(" ^ (unparse_expr a) ^ ", " ^ (unparse_plus b) ^ ")"
  and negate = function
    | [] -> []
    | (Uminus x) :: y -> x :: negate y
    | x :: y -> (Uminus x) :: negate y

  in function
    | Load v -> Variable.unparse v
    | Num n -> Number.to_konst n
    | Plus [] -> "0.0 /* bug */"
    | Plus [a] -> " /* bug */ " ^ (unparse_expr a)
    | Plus a -> unparse_plus a
    | Times(a,b) -> sprintf "VMUL(%s,%s)" (unparse_expr a) (unparse_expr b)
    | Uminus a -> failwith "SIMD Uminus"
    | _ -> failwith "unparse_expr"

and unparse_decl x = C.unparse_decl x

and unparse_ast' vardeclinfo ast = 
  let rec unparse_ast ast =
    let rec unparse_assignment = function
      |	Assign(dst, Load src) when 
	  Variable.is_constant src && 
	  (is_real src || is_imag src) &&
	  (not (Variable.is_locative dst)) -> 
	    unparse_load_twiddle_vect vardeclinfo dst src
      | Assign(dst, Load src) when (not (Variable.is_locative dst)) -> 
	    unparse_load vardeclinfo dst src
      | Assign (v, x) when Variable.is_locative v ->
	  if !store_transpose then
	    unparse_store_transposed vardeclinfo v x
	  else
	    unparse_store vardeclinfo v x
      | Assign (v, x) -> 
	  (Variable.unparse v) ^ " = " ^ (unparse_expr x) ^ ";\n"

    and unparse_annotated force_bracket = 
      let rec unparse_code = function
        | ADone -> ""
        | AInstr i -> unparse_assignment i
        | ASeq (a, b) -> 
	    (unparse_annotated false a) ^ (unparse_annotated false b)
      and declare_variables l = 
	let rec uvar = function
	    [] -> failwith "uvar"
	  |	[v] -> (Variable.unparse v) ^ ";\n"
	  | a :: b -> (Variable.unparse a) ^ ", " ^ (uvar b)
	in let rec vvar l = 
	  let s = if !Magic.compact then 10 else 1 in
	  if (List.length l <= s) then
	    match l with
	      [] -> ""
	    | _ -> realtype ^ " " ^ (uvar l)
	  else
	    (vvar (Util.take s l)) ^ (vvar (Util.drop s l))
	in vvar (List.filter Variable.is_temporary l)
      in function
          Annotate (_, _, decl, _, code) ->
            if (not force_bracket) && (Util.null decl) then 
              unparse_code code
            else "{\n" ^
              (declare_variables decl) ^
              (unparse_code code) ^
	      "}\n"

(* ---- *)
    and unparse_plus = function
      | [] -> ""
      | (CUminus a :: b) -> " - " ^ (parenthesize a) ^ (unparse_plus b)
      | (a :: b) -> " + " ^ (parenthesize a) ^ (unparse_plus b)
    and parenthesize x = match x with
      | (CVar _) -> unparse_ast x
      | (Integer _) -> unparse_ast x
      | _ -> "(" ^ (unparse_ast x) ^ ")"

    in match ast with 
    | Asch a -> (unparse_annotated true a)
    | Return x -> "return " ^ unparse_ast x ^ ";"
    | For (a, b, c, d) ->
	"for (" ^
	unparse_ast a ^ "; " ^ unparse_ast b ^ "; " ^ unparse_ast c
	^ ")" ^ unparse_ast d
    | If (a, d) ->
	"if (" ^
	unparse_ast a 
	^ ")" ^ unparse_ast d
    | Block (d, s) ->
	if (s == []) then ""
	else 
          "{\n"                                      ^ 
          foldr_string_concat (map unparse_decl d)   ^ 
          foldr_string_concat (map unparse_ast s)    ^
          "}\n"      
    | x -> C.unparse_ast x

  in unparse_ast ast

and unparse_function vardeclinfo = function
    Fcn (typ, name, args, body) ->
      let rec unparse_args = function
          [Decl (a, b)] -> a ^ " " ^ b 
	| (Decl (a, b)) :: s -> a ^ " " ^ b  ^ ", "
            ^  unparse_args s
	| [] -> ""
	| _ -> failwith "unparse_function"
      in 
      (typ ^ " " ^ name ^ "(" ^ unparse_args args ^ ")\n" ^
       unparse_ast' vardeclinfo body)

