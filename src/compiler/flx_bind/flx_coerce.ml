open Flx_types
open Flx_btype
open Flx_bexpr
open Flx_exceptions
open Flx_srcref

open Flx_lookup_state

let type_eq = Flx_unify.type_eq
let sbt = Flx_print.sbt
let sbe = Flx_print.sbe
let si = string_of_int

let record_coercion state bsym_table sr x' n t' t'' ls' ls'' = 
  try
  bexpr_record (* t'' *)
  (
    List.map
    (fun (s,t)->
      match Flx_list.list_assoc_index ls' s with
      | Some j ->
        let tt = List.assoc s ls' in
        if type_eq bsym_table state.Flx_lookup_state.counter t tt then
          s,(bexpr_get_n t j x')
        else clierr sr (
          "Source Record field '" ^ s ^ "' has type:\n" ^
          sbt bsym_table tt ^ "\n" ^
          "but coercion target has the different type:\n" ^
          sbt bsym_table t ^"\n" ^
          "The types must be the same!"
        )
      | None -> raise Not_found
    )
    ls''
  )
  with Not_found ->
    clierr sr
     (
     "Record coercion dst requires subset of fields of src:\n" ^
     sbe bsym_table x' ^ " has type " ^ sbt bsym_table t' ^
    "\nwhereas annotation requires " ^ sbt bsym_table t''
    )

let variant_coercion state bsym_table sr x' t' t'' lhs rhs = 
  try
    List.iter
    (fun (s,t)->
      match Flx_list.list_assoc_index rhs s with
      | Some j ->
        let tt = List.assoc s rhs in
        if not (type_eq bsym_table state.counter t tt) then
        clierr sr (
          "Source Variant field '" ^ s ^ "' has type:\n" ^
          sbt bsym_table t ^ "\n" ^
          "but coercion target has the different type:\n" ^
          sbt bsym_table tt ^"\n" ^
          "The types must be the same!"
        )
      | None -> raise Not_found
    )
    lhs
    ;
    print_endline ("Coercion of variant to type " ^ sbt bsym_table t'');
    bexpr_coerce (x',t'')
  with Not_found ->
    clierr sr
     (
     "Variant coercion src requires subset of fields of dst:\n" ^
     sbe bsym_table x' ^ " has type " ^ sbt bsym_table t' ^
    "\nwhereas annotation requires " ^ sbt bsym_table t''
    )

(* we start with v0 ^ ix0 cf v ^ (Pi ls)
   if length ls = 0 we require v0 = v and ix0 = unit, else
   if length ls = 1 we require v0 = v and ix0 = hd ls else
   we require v0 = v1 ^ ix1 and ix0 = hd ls and 
     recursively check v1 ^ ix1 cf v ^ Pi (tl ls)
*)
let catmap sep fn ls = String.concat sep (List.map fn ls)

let check_array bsym_table v0 ix0 v ls =
(*
print_endline ("Check (" ^ sbt bsym_table v0 ^ ") ^ (" ^ sbt bsym_table ix0 ^ ") == (" ^
  sbt bsym_table v ^ ") ^ ( " ^ catmap " * " (sbt bsym_table) ls ^ ")")
;
*)
let ls = List.rev ls in
  if List.length ls = 0 then v = v0 && ix0 = Flx_btype.btyp_tuple [] else
  let rec aux v0 ix0 ls = 
    if List.length ls = 1 then 
     begin 
(*
       print_endline "Terminal case"; 
*)
       v = v0 && ix0 =  List.hd ls 
      end 
    else
    match v0 with
    | BTYP_array (v1,ix1) ->
(*
print_endline ("  SubCheck " ^ 
   sbt bsym_table ix0 ^ " = " ^ sbt bsym_table (List.hd ls) ^ " and recurse " ^
   sbt bsym_table v1 ^ ", " ^ sbt bsym_table ix1 ^ ", (" ^ catmap " * " (sbt bsym_table) (List.tl ls) ^ ")"
 );
*)
      ix0 = List.hd ls && aux v1 ix1 (List.tl ls)
    | _ -> false
  in
  aux v0 ix0 ls



let coerce (state:Flx_lookup_state.lookup_state_t) bsym_table sr ((e',t') as x') t'' =
(*
print_endline ("Binding coercion " ^ sbe bsym_table x' ^ ": " ^ sbt bsym_table t' ^ " to " ^ sbt bsym_table t'');
*)
    if type_eq bsym_table state.Flx_lookup_state.counter t' t'' then x'
    else
    begin match t',t'' with
    | BTYP_inst (i,[]),t when Flx_btype.islinear_type bsym_table t->
      let n = Flx_btype.sizeof_linear_type bsym_table  t in
      begin match hfind "lookup" state.sym_table i with
      | { Flx_sym.id="int";
          symdef=SYMDEF_abs (_, Flx_code_spec.Str_template "int", _) }  ->
        begin match e' with
        | BEXPR_literal {Flx_literal.felix_type="int"; internal_value=big} ->
(*
print_endline "Coercion from int literal";
*)
          let m =
            try int_of_string big
            with _ -> clierr sr "Integer is too large for unitsum"
          in
          if m >=0 && m < n then
            bexpr_unitsum_case m n
          else
            clierr sr "Integer is out of range for unitsum"
        | _ ->
(*
print_endline "Coercion from int expression ";
*)
          let inttype = t' in
          let zero =
            bexpr_literal t' {Flx_literal.felix_type="int"; internal_value="0"; c_value="0"}
          in
          let xn =
            bexpr_literal t' {Flx_literal.felix_type="int"; internal_value=string_of_int n; c_value=string_of_int n}
          in
          let r = bexpr_coerce (bexpr_range_check t' (zero,x',xn),t'') in
(*
print_endline ("Coercion from int expression result is " ^ sbe bsym_table r);
*)
          r
        end
      | _ ->
        clierr sr ("Attempt to to coerce type:\n"^
        sbt bsym_table t'
        ^"to unitsum " ^ si n)
      end

    | t,(BTYP_inst (i,[]) as inttype) when Flx_btype.islinear_type bsym_table t->
      let n = Flx_btype.sizeof_linear_type bsym_table  t in
      begin match hfind "lookup" state.sym_table i with
      | { Flx_sym.id="int";
          symdef=SYMDEF_abs (_, Flx_code_spec.Str_template "int", _) }  ->
        Flx_bexpr.bexpr_coerce (x',inttype)

      | _ ->
        clierr sr ("Attempt to to coerce unitsum "^si n^" to type:\n"^
        sbt bsym_table t')
      end

    | BTYP_record (n',ls'),BTYP_record (n'',ls'') when n' = n''->
      let n = List.length ls' in
      record_coercion state bsym_table sr x' n t' t'' ls' ls'' 

    | BTYP_variant lhs,BTYP_variant rhs ->
      variant_coercion state bsym_table sr x' t' t'' lhs rhs 

    (* This isn't really right, but it's safe storage wise *)
    | BTYP_array (lhsv,lhst), BTYP_array (rhsv, rhst) 
      when lhsv = rhsv &&
      islinear_type bsym_table lhst && islinear_type bsym_table rhst &&
      sizeof_linear_type bsym_table lhst = sizeof_linear_type bsym_table rhst ->
      bexpr_coerce (x',t'')

    (* This isn't really right, but it's safe storage wise *)
    | BTYP_pointer lhst, BTYP_pointer rhst
    | lhst, rhst 
      when 
      islinear_type bsym_table lhst && islinear_type bsym_table rhst &&
      sizeof_linear_type bsym_table lhst = sizeof_linear_type bsym_table rhst ->
      bexpr_coerce (x',t'')

    | BTYP_array(v',BTYP_tuple ls),BTYP_array (v,ix)
    | BTYP_array (v,ix),BTYP_array(v',BTYP_tuple ls) 
    | BTYP_pointer (BTYP_array(v',BTYP_tuple ls)), BTYP_pointer (BTYP_array (v,ix))
    | BTYP_pointer (BTYP_array (v,ix)),BTYP_pointer (BTYP_array(v',BTYP_tuple ls))
      ->
      let result = check_array bsym_table v ix v' ls in
(*
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"));
*)
      if not result then
        clierr sr ("Incompatible types in array coercion: " ^
          sbt bsym_table t' ^ " is not isomorphic to " ^ sbt bsym_table t''
        )
      else 
        bexpr_coerce (x',t'')

    | BTYP_array(v',BTYP_array (ix',BTYP_unitsum n)),BTYP_array (v,ix)
    | BTYP_array (v,ix),BTYP_array(v',BTYP_array (ix',BTYP_unitsum n)) 
    | BTYP_pointer (BTYP_array(v',BTYP_array (ix',BTYP_unitsum n))), BTYP_pointer (BTYP_array (v,ix))
    | BTYP_pointer (BTYP_array (v,ix)),BTYP_pointer (BTYP_array(v',BTYP_array (ix',BTYP_unitsum n)))
      ->
      let ls = let rec aux n out = match n with 1 -> out | _ -> aux (n-1) (ix::out) in aux n [ix] in 
      assert (List.length ls = n);
      let result = check_array bsym_table v ix v' ls in
(*
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"));
*)
      if not result then
        clierr sr ("Incompatible types in array coercion: " ^
          sbt bsym_table t' ^ " is not isomorphic to " ^ sbt bsym_table t''
        )
      else 
        bexpr_coerce (x',t'')


(*
(* Array of array <-> array value conversions *)
    | BTYP_array (BTYP_array (v,ix1),ix2),BTYP_array(v',BTYP_tuple[ix1';ix2']) ->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix1';ix2'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array of arrays value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix1' || ix2 <> ix2' then
        clierr sr ("Coercion: source array of arrays value index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2 ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix2' ^ " and " ^ sbt bsym_table ix2')
      ; 
      bexpr_coerce (x',t'')

    | BTYP_array (BTYP_array (v,ix1),ix2),BTYP_array(v',BTYP_array(ix',BTYP_unitsum 2)) ->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix';ix'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array of arrays value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix' || ix2 <> ix' then
        clierr sr ("Coercion: source array of arrays value index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2 ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix' ^ " and " ^ sbt bsym_table ix')
      ; 
      bexpr_coerce (x',t'')


    | BTYP_array(v',BTYP_tuple[ix1';ix2']), BTYP_array (BTYP_array (v,ix1),ix2)->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix1';ix2'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix1' || ix2 <> ix2' then
        clierr sr ("Coercion: source array value index types " ^ 
          sbt bsym_table ix1' ^ " and " ^ sbt bsym_table ix2' ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2)
      ;
      bexpr_coerce (x',t'')

    | BTYP_array(v',BTYP_array(ix',BTYP_unitsum 2)), BTYP_array (BTYP_array (v,ix1),ix2)->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix';ix'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix' || ix2 <> ix' then
        clierr sr ("Coercion: source array value index types " ^ 
          sbt bsym_table ix' ^ " and " ^ sbt bsym_table ix' ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2)
      ;
      bexpr_coerce (x',t'')

(* Pointer variations of above 4 cases *)
    | BTYP_pointer (BTYP_array (BTYP_array (v,ix1),ix2)),BTYP_pointer (BTYP_array(v',BTYP_tuple[ix1';ix2'])) ->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix1';ix2'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array of arrays value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix1' || ix2 <> ix2' then
        clierr sr ("Coercion: source array of arrays value index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2 ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix2' ^ " and " ^ sbt bsym_table ix2')
      ; 
      bexpr_coerce (x',t'')

    | BTYP_pointer (BTYP_array (BTYP_array (v,ix1),ix2)),BTYP_pointer (BTYP_array(v',BTYP_array(ix',BTYP_unitsum 2))) ->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix';ix'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array of arrays value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix' || ix2 <> ix' then
        clierr sr ("Coercion: source array of arrays value index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2 ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix' ^ " and " ^ sbt bsym_table ix')
      ; 
      bexpr_coerce (x',t'')


    | BTYP_pointer (BTYP_array(v',BTYP_tuple[ix1';ix2'])), BTYP_pointer (BTYP_array (BTYP_array (v,ix1),ix2))->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix1';ix2'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix1' || ix2 <> ix2' then
        clierr sr ("Coercion: source array value index types " ^ 
          sbt bsym_table ix1' ^ " and " ^ sbt bsym_table ix2' ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2)
      ;
      bexpr_coerce (x',t'')

    | BTYP_pointer (BTYP_array(v',BTYP_array(ix',BTYP_unitsum 2))), BTYP_pointer (BTYP_array (BTYP_array (v,ix1),ix2))->
      let result = check_array bsym_table (btyp_array (v,ix1)) ix2 v' [ix';ix'] in
      print_endline ("Coercion: trial check " ^ (if result then "true" else "false"))
      ;
      if v <> v' then
        clierr sr ("Coercion: source array value type " ^ sbt bsym_table v ^
         " not equal to target value type " ^ sbt bsym_table v')
      ;
      if ix1 <> ix' || ix2 <> ix' then
        clierr sr ("Coercion: source array value index types " ^ 
          sbt bsym_table ix' ^ " and " ^ sbt bsym_table ix' ^ 
          " not equal to target index types " ^ 
          sbt bsym_table ix1 ^ " and " ^ sbt bsym_table ix2)
      ;
      bexpr_coerce (x',t'')

*)


    | _ ->
      (* clierr sr *)
      (*
      print_endline ("WARNING: " ^
      (
        "Wrong type in coercion src value \n" ^
        sbe bsym_table x' ^ " has type " ^ sbt bsym_table t' ^
        "\ncoercion to " ^ sbt bsym_table t'' ^ " not supported"
      )
      );
      *)
      bexpr_coerce (x',t'')
    end


