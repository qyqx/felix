open List

open Flx_bbdcl
open Flx_beta
open Flx_bexe
open Flx_bexpr
open Flx_bparameter
open Flx_btype
open Flx_cexpr
open Flx_ctorgen
open Flx_ctypes
open Flx_display
open Flx_egen
open Flx_exceptions
open Flx_label
open Flx_list
open Flx_maps
open Flx_mtypes2
open Flx_name
open Flx_ogen
open Flx_options
open Flx_pgen
open Flx_print
open Flx_types
open Flx_typing
open Flx_unify
open Flx_util
open Flx_gen_helper

let gen_fun_header syms bsym_table kind index export_name modulename =
    let mname = Flx_name.cid_of_flxid modulename in
    let bsym =
      try Flx_bsym_table.find bsym_table index with Not_found ->
        failwith ("[gen_biface_header] Can't find index " ^ string_of_bid index)
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,vs,(ps,traint),ret,_) ->
      let display = get_display_list bsym_table index in
      if length display <> 0
      then clierr (Flx_bsym.sr bsym) ("Can't export nested function " ^ export_name);

      let arglist =
        List.map
        (fun {ptyp=t} -> cpp_typename syms bsym_table t)
        ps
      in
      let arglist = "  " ^
        match kind with 
        | `Fun -> 
           (if length ps = 0 then "FLX_FPAR_DECL_ONLY"
           else "FLX_FPAR_DECL\n" ^ cat ",\n  " arglist
           )
        | `Cfun -> cat ",\n  " arglist
      in
      let name, rettypename =
        match ret with
        | BTYP_void -> "PROCEDURE", "::flx::rtl::con_t * "
        | _ -> "FUNCTION", cpp_typename syms bsym_table ret
      in

      "//EXPORT " ^ name ^ " " ^ cpp_instance_name syms bsym_table index [] ^
      " as " ^ export_name ^ "\n" ^
      "extern \"C\" {\n" ^
      "  using namespace ::flxusr::" ^ mname ^";\n" ^
      "  FLX_EXTERN_"^mname ^ " " ^rettypename ^ " " ^
      export_name ^ "(\n" ^ arglist ^ "\n);\n}\n"

    | _ -> failwith "Not implemented: export non-function/procedure"
    end


let gen_biface_header syms bsym_table modulename biface = 
  let mname = Flx_name.cid_of_flxid modulename in
  match biface with
  | BIFACE_export_python_fun (sr,index, export_name) ->
     "// PYTHON FUNCTION " ^ export_name ^ " header to go here??\n"

  | BIFACE_export_fun (sr,index, export_name) ->
    gen_fun_header syms bsym_table `Fun index export_name modulename

  | BIFACE_export_cfun (sr,index, export_name) ->
    gen_fun_header syms bsym_table `Cfun index export_name modulename

  | BIFACE_export_type (sr, typ, export_name) ->
    "//EXPORT type " ^ sbt bsym_table typ ^ " as " ^ export_name  ^ "\n" ^
    "typedef " ^ cpp_type_classname syms bsym_table typ ^ " " ^ export_name ^ "_class;\n" ^
    "typedef " ^ cpp_typename syms bsym_table typ ^ " " ^ export_name ^ ";\n"

  | BIFACE_export_struct (sr,idx) ->
    let bsym = Flx_bsym_table.find bsym_table idx in
    let sname = Flx_bsym.id bsym in
    let bbdcl = Flx_bsym.bbdcl bsym in
    let typ = Flx_btype.btyp_inst (idx,[]) in
    let classname = cpp_type_classname syms bsym_table typ in
    "//EXPORT struct " ^ sname ^ "\n" ^
    "typedef ::flxusr::" ^ mname ^ "::" ^ classname ^ " " ^ sname ^ ";\n"

let gen_fun_body syms bsym_table kind index export_name =
    let bsym =
      try Flx_bsym_table.find bsym_table index with Not_found ->
        failwith ("[gen_biface_body] Can't find index " ^ string_of_bid index)
    in
    let sr = Flx_bsym.sr bsym in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,vs,(ps,traint),BTYP_void,_) ->
      if length vs <> 0
      then clierr sr ("Can't export generic procedure " ^ Flx_bsym.id bsym)
      ;
      let display = get_display_list bsym_table index in
      if length display <> 0
      then clierr (Flx_bsym.sr bsym) "Can't export nested function";

      let args = rev (fold_left (fun args
        ({ptyp=t; pid=name; pindex=pidx} as arg) ->
        try ignore(cpp_instance_name syms bsym_table pidx []); arg :: args
        with _ -> args
        )
        []
        ps)
      in
      let params =
        List.map
        (fun {ptyp=t; pindex=pidx; pid=name} ->
          cpp_typename syms bsym_table t ^ " " ^ name
        )
        ps
      in
      let strparams = "  " ^
        match kind with
        | `Fun ->
          (if length params = 0 then "FLX_FPAR_DECL_ONLY"
          else "FLX_FPAR_DECL\n  " ^ cat ",\n  " params
          )
        | `Cfun -> cat ",\n " params
      in
      let class_name = cpp_instance_name syms bsym_table index [] in
      let strargs =
        let ge = gen_expr syms bsym_table index [] [] in
        match ps with
        | [] -> "0"
        | [{ptyp=t; pid=name; pindex=idx}] -> "0" ^ ", " ^ name
        | _ ->
          let a =
            let counter = ref 0 in
            bexpr_tuple
              (btyp_tuple (Flx_bparameter.get_btypes ps))
              (
                List.map
                (fun {ptyp=t; pid=name; pindex=idx} ->
                  bexpr_expr (name,t)
                )
                ps
              )
          in
          "0" ^ ", " ^ ge sr a
      in
      let call_method = 
         if mem `Cfun props || mem `Pure props && mem `Stackable props then `C_call
         else if mem `Stackable props then `Stack_call
         else if mem `Heap_closure props then `Heap_call
         else 
           let bug = 
             "Function exported as " ^ export_name ^ " is neither stackable " ^
             " nor has a heap closure -- no way to call it" 
           in clierr sr bug
      in
      let requires_ptf = mem `Requires_ptf props in


      "//EXPORT PROC " ^ cpp_instance_name syms bsym_table index [] ^
      " as " ^ export_name ^ "\n" ^
      "::flx::rtl::con_t *" ^ export_name ^ "(\n" ^ strparams ^ "\n){\n" ^
      ( 
        match call_method with
        | `C_call ->
          "  " ^ class_name ^"(" ^
          (
            if requires_ptf then
            begin match kind with
            | `Fun ->
              if length args = 0
              then "FLX_APAR_PASS_ONLY "
              else "FLX_APAR_PASS "
            | `Cfun -> 
              clierr (Flx_bsym.sr bsym) ("Attempt to export procedure requiring thread frame with C interface: "^ Flx_bsym.id bsym)
            end
            else ""
          )
          ^
          cat ", " (Flx_bparameter.get_names args) ^ ");\n" ^
          "  return 0;\n"

        | `Stack_call ->
          "  " ^ class_name ^ "("^
          (
            if requires_ptf then
            begin match kind with
            | `Fun -> "_PTFV"
            | `Cfun -> 
              clierr (Flx_bsym.sr bsym) ("Attempt to export procedure requiring thread frame with C interface: "^ Flx_bsym.id bsym)
            end
            else ""
          )
          ^
          ")" ^
          ".stack_call(" ^ (catmap ", " (fun {pid=id}->id) args) ^ ");\n"
          ^
          "  return 0;\n"
        | `Heap_call ->
          "  return (new(*_PTF gcp,"^class_name^"_ptr_map,true)\n" ^
          "    " ^ class_name ^ "(_PTFV))" ^
          "\n      ->call(" ^ strargs ^ ");\n"
      )
      ^
      "}\n"

    | BBDCL_fun (props,vs,(ps,traint),ret,_) ->
      if length vs <> 0
      then clierr (Flx_bsym.sr bsym) ("Can't export generic function " ^ Flx_bsym.id bsym)
      ;
      let display = get_display_list bsym_table index in
      if length display <> 0
      then clierr sr "Can't export nested function";
      let arglist =
        List.map
        (fun {ptyp=t; pid=name} -> cpp_typename syms bsym_table t ^ " " ^ name)
        ps
      in
      let arglist = "  " ^
        match kind with
        | `Fun ->
          (if length ps = 0 then "FLX_FPAR_DECL_ONLY"
          else "FLX_FPAR_DECL\n  " ^ cat ",\n  " arglist
          )
        | `Cfun ->  cat ",\n " arglist
      in
(*
print_endline ("Export " ^ export_name ^ " properties " ^ string_of_properties props);
      if mem `Stackable props then print_endline ("Stackable " ^ export_name);
      if mem `Stack_closure props then print_endline ("Stack_closure" ^ export_name);
      if mem `Heap_closure props then print_endline ("Heap_closure" ^ export_name);
*)
      let call_method = 
         if mem `Pure props && mem `Stackable props then `C_call
         else if mem `Stackable props then `Stack_call
         else if mem `Heap_closure props then `Heap_call
         else 
           let bug = 
             "Function exported as " ^ export_name ^ " is neither stackable " ^
             " nor has a heap closure -- no way to call it" 
           in clierr sr bug
      in
      let requires_ptf = mem `Requires_ptf props in

      let rettypename = cpp_typename syms bsym_table ret in
      let class_name = cpp_instance_name syms bsym_table index [] in
      let ge = gen_expr syms bsym_table index [] [] in
      let args = match ps with
      | [] -> ""
      | [{pid=name}] -> name
      | _ ->
          let a =
            let counter = ref 0 in
            bexpr_tuple
              (btyp_tuple (Flx_bparameter.get_btypes ps))
              (
                List.map
                (fun {ptyp=t; pid=name; pindex=idx} ->
                  bexpr_expr (name,t)
                )
                ps
              )
          in
          ge sr a
      in


      "//EXPORT FUNCTION " ^ class_name ^
      " as " ^ export_name ^ "\n" ^
      rettypename ^" " ^ export_name ^ "(\n" ^ arglist ^ "\n){\n" ^
      begin match call_method with
      | `C_call -> 
        "  return " ^ class_name ^ "("^
        (if requires_ptf then "_PTFV"^(if List.length ps > 0 then ", " else "") else "") ^
        cat ", " (Flx_bparameter.get_names ps) ^ ");\n"

      | `Stack_call ->
        "  return " ^ class_name ^ "("^
          (if requires_ptf then "_PTFV" else "") ^").apply(" ^
          args^ ");\n"
      | `Heap_call ->
        "  return (new(*_PTF gcp,"^class_name^"_ptr_map,true)\n" ^
        "    " ^ class_name ^ "(_PTFV))\n" ^
        "    ->apply(" ^ args ^ ");\n"
      end 
      ^
      "}\n"

    | _ -> failwith "Not implemented: export non-function/procedure"
    end

let gen_biface_body syms bsym_table biface = match biface with
  | BIFACE_export_python_fun (sr,index, export_name) ->
     "// PYTHON FUNCTION " ^ export_name ^ " body to go here??\n"

  | BIFACE_export_fun (sr,index, export_name) ->
    gen_fun_body syms bsym_table `Fun index export_name

  | BIFACE_export_cfun (sr,index, export_name) ->
    gen_fun_body syms bsym_table `Cfun index export_name

  | BIFACE_export_type _ -> ""

  | BIFACE_export_struct _ -> ""

let gen_felix_binding syms bsym_table kind index export_name modulename =
  let mname = Flx_name.cid_of_flxid modulename in
  let bsym =
    try Flx_bsym_table.find bsym_table index with Not_found ->
      failwith ("[gen_biface_header] Can't find index " ^ string_of_bid index)
  in
  begin match Flx_bsym.bbdcl bsym with
  | BBDCL_fun (props,vs,(ps,traint),ret,_) ->
    let display = get_display_list bsym_table index in
    if length display <> 0
    then clierr (Flx_bsym.sr bsym) ("Can't export nested function " ^ export_name);

    (* THIS BIT FOR DOCO ONLY *)
    let n = List.length ps in
    let fkind, rettypename =
      match ret with
      | BTYP_void -> "proc", "::flx::rtl::con_t * "
      | _ -> "fun", cpp_typename syms bsym_table ret
    in
    let fkind = match kind with `Fun -> fkind | `Cfun -> "c" ^ fkind in
    (* THIS IS THE FELIX INTERFACE *)
    let fname = Flx_bsym.id bsym in
    let farglist = 
      List.map (fun {ptyp=t} -> sbt bsym_table t) ps
    in
    let argtype = if n = 0 then "1" else String.concat " * " farglist in
    let flx_binding =
      match kind with 
      | `Cfun -> 
        begin match ret with
        | BTYP_void -> "  proc " ^ export_name ^ " : " ^ argtype  ^ ";"
        | _ -> "  fun " ^ export_name ^ " : " ^ argtype ^ " -> " ^ sbt bsym_table ret ^ ";"
        end
      | `Fun -> 
        let carglist = ref [] in
        let nargs = for i = 1 to n do carglist := ("$" ^ string_of_int i) :: (!carglist) done in
        let carglist = String.concat "," (!carglist) in
        let carglist = 
            (* HACK to cast client thread frame pointer to this library, will NOT
               work if the library has any state i.e. variables, but is enough to 
               pass over the GC, provided the call is made in a suitable context.
             *)

            "(::flxusr::"^mname^"::thread_frame_t*)(void*)ptf" ^ if n = 0 then "" else ","^carglist
        in
        begin match ret with
        | BTYP_void -> "  proc " ^ export_name ^ " : " ^ argtype ^ " = " ^
          "\"" ^export_name ^ "(" ^carglist^ ")\" requires property \"needs_ptf\";" 
        | _ -> "  fun " ^ export_name ^ " : " ^ argtype ^ " -> " ^ sbt bsym_table ret ^ " = " ^
          "\"" ^ export_name ^ "("^carglist^");\" requires property \"needs_ptf\";" 
        end
    in
    flx_binding ^ " // "^fkind ^ " " ^ cpp_instance_name syms bsym_table index []^"\n"

  | _ -> failwith "Not implemented: export non-function/procedure"
  end

let gen_felix_struct_export syms bsym_table idx modulename =
  let bsym = Flx_bsym_table.find bsym_table idx in
  let sname = Flx_bsym.id bsym in
  let bbdcl = Flx_bsym.bbdcl bsym in
  let fields = match bbdcl with 
    | BBDCL_struct ([],fields) -> fields
    | _ -> assert false
  in
  let mkmem (id,t) = "      " ^ id ^ ": "^ sbt bsym_table t ^ ";\n" in
  let mems = catmap "" mkmem fields in
  "  cstruct " ^ sname ^ " {\n" ^
  mems ^
  "  };\n"

let gen_biface_felix1 syms bsym_table modulename biface = match biface with
  | BIFACE_export_python_fun (sr,index, export_name) ->
    "  // PYTHON FUNCTION " ^ export_name ^ "\n"

  | BIFACE_export_fun (sr,index, export_name) ->
    gen_felix_binding syms bsym_table `Fun index export_name modulename


  | BIFACE_export_cfun (sr,index, export_name) ->
    gen_felix_binding syms bsym_table `Cfun index export_name modulename

  | BIFACE_export_type (sr, typ, export_name) ->
     "  // TYPE " ^ export_name ^ "\n"

  | BIFACE_export_struct (sr,idx) ->
    gen_felix_struct_export syms bsym_table idx modulename


let gen_biface_headers syms bsym_table bifaces modulename =
  cat "" (List.map (gen_biface_header syms bsym_table modulename) bifaces)

let gen_biface_bodies syms bsym_table bifaces =
  cat "" (List.map (gen_biface_body syms bsym_table) bifaces)

let gen_biface_felix syms bsym_table bifaces modulename =
  let mname = Flx_name.cid_of_flxid modulename in
  "class " ^ modulename ^ "_interface {\n" ^
  "  requires header '''\n" ^
  "    #define FLX_EXTERN_" ^ mname ^ " FLX_IMPORT\n" ^
  "    #include \""^modulename^".hpp\"\n" ^
  "  ''';\n" ^
  cat "" (List.map (gen_biface_felix1 syms bsym_table modulename) bifaces) ^
  "}\n"

