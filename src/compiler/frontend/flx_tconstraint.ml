open Flx_ast
open Flx_types
open Flx_mtypes1
open Flx_mtypes2
open Flx_tpat
open Flx_exceptions
open List
open Flx_print
open Flx_util

(* A type constraint written in a vs list is a simplification.
   The form

   v:p

   is short for

   typematch v with | p -> 1 | _ -> 0 endmatch

   BUT ONLY IF IT ISN'T INSTEAD AN ACTUAL METATYPE SPECIFICATION!
   (in which case it is constraint that v be a member of the
   metatype p, without other constraints!)
*)

let build_constraint_element syms bt sr i p1 =
  (* special case, no constraint, represent by just 'true' (unit type) *)
  match p1 with
  | `AST_patany _
  | `TYP_type
  | `TYP_function _
    -> `BTYP_tuple []
  | _ ->

  (* more general cases *)
  (*
  print_endline ("Build constraint " ^ string_of_typecode p1);
  *)
  let p1,explicit_vars1,any_vars1, as_vars1, eqns1 = type_of_tpattern syms p1 in

  (* check the pattern doesn't introduce any named variables *)
  (* later we may allow them as additional 'vs' variables .. but
    it is tricky because they'd have to be introduced 'in scope':
  *)
  (*
  if eqns1 <> [] then clierr sr
    "Type variable constraint may not have 'as' terms"
  ;
  if explicit_vars1 <> [] then clierr sr
    "Type variable constraint may not have named pattern variables"
  ;
  *)
  let varset1 =
    fold_left (fun s i -> IntSet.add i s)
    IntSet.empty any_vars1
  in
    let varset1 =
    fold_left (fun s (i,_) -> IntSet.add i s)
    varset1 as_vars1
  in
  let varset1 =
    fold_left (fun s (i,_) -> IntSet.add i s)
    varset1 explicit_vars1
  in
  let un = `BTYP_tuple [] in (* the 'true' value of the type system *)
  let elt = `BTYP_var (i,`BTYP_type 0) in
  let p1 = bt p1 in
  let rec fe t = match t with
  | `BTYP_typeset ls
  | `BTYP_typesetunion ls ->
     uniq_list (concat (map fe ls))

  | t -> [t]
  in
  let tyset ls =
    let e = IntSet.empty in
    let un = `BTYP_tuple [] in
    let lss = rev_map (fun t -> {pattern=t; pattern_vars=e; assignments=[]},un) ls in
    let fresh = !(syms.counter) in incr (syms.counter);
    let dflt =
      {
        pattern=`BTYP_var (fresh,`BTYP_type 0);
        pattern_vars = IntSet.singleton fresh;
        assignments=[]
      },
      `BTYP_void
    in
    let lss = rev (dflt :: lss) in
    `BTYP_type_match (elt, lss)
  in
    let tm = tyset (fe p1) in
    (* print_endline ("Bound typematch is " ^ sbt syms.dfns tm); *)
    tm

let build_type_constraints syms bt sr vs =
  let type_constraints =
    map (fun (s,i,tp) ->
      let tp = build_constraint_element syms bt sr i tp in
      (*
      if tp <> `BTYP_tuple [] then
        print_endline (
        " vs entry " ^ s ^ ", var " ^ si i ^
        " constraint " ^ sbt syms.dfns tp)
      ;
      *)
      tp
    )
    vs
  in
    `BTYP_intersect type_constraints