open Flx_util
open Flx_ast
open Flx_types
open Flx_mtypes2
open Flx_print
open Flx_typing
open Flx_srcref
open List
open Flx_lookup
open Flx_exceptions

let null_tab = Hashtbl.create 3
let dfltvs_aux = { raw_type_constraint=`TYP_tuple []; raw_typeclass_reqs=[]}
let dfltvs = [],dfltvs_aux


(* use fresh variables, but preserve names *)
let mkentry syms (vs:ivs_list_t) i =
  let n = length (fst vs) in
  let base = !(syms.counter) in syms.counter := !(syms.counter) + n;
  let ts = map (fun i -> `BTYP_var (i+base,`BTYP_type 0)) (nlist n) in
  let vs = map2 (fun i (n,_,_) -> n,i+base) (nlist n) (fst vs) in
  (*
  print_endline ("Make entry " ^ si i ^ ", " ^ "vs =" ^
    catmap "," (fun (s,i) -> s^ "<" ^ si i ^">") vs ^
    ", ts=" ^ catmap "," (sbt syms.dfns) ts
  );
  *)
  {base_sym=i; spec_vs=vs; sub_ts=ts}

let merge_ivs
  (vs1,{raw_type_constraint=con1; raw_typeclass_reqs=rtcr1})
  (vs2,{raw_type_constraint=con2; raw_typeclass_reqs=rtcr2})
:ivs_list_t =
  let t =
    match con1,con2 with
    | `TYP_tuple[],`TYP_tuple[] -> `TYP_tuple[]
    | `TYP_tuple[],b -> b
    | a,`TYP_tuple[] -> a
    | `TYP_intersect a, `TYP_intersect b -> `TYP_intersect (a@b)
    | `TYP_intersect a, b -> `TYP_intersect (a @[b])
    | a,`TYP_intersect b -> `TYP_intersect (a::b)
    | a,b -> `TYP_intersect [a;b]
  and
    rtcr = uniq_list (rtcr1 @ rtcr2)
  in
  vs1 @ vs2,
  { raw_type_constraint=t; raw_typeclass_reqs=rtcr}



let split_asms asms :
  (range_srcref * id_t * int option * access_t * vs_list_t * dcl_t) list *
  sexe_t list *
  (range_srcref * iface_t) list *
  dir_t list
=
  let rec aux asms dcls exes ifaces dirs =
    match asms with
    | [] -> (dcls,exes,ifaces, dirs)
    | h :: t ->
      match h with
      | `Exe (sr,exe) -> aux t dcls ((sr,exe) :: exes) ifaces dirs
      | `Dcl (sr,id,seq,access,vs,dcl) -> aux t ((sr,id,seq,access,vs,dcl) :: dcls) exes ifaces dirs
      | `Iface (sr,iface) -> aux t dcls exes ((sr,iface) :: ifaces) dirs
      | `Dir dir -> aux t dcls exes ifaces (dir::dirs)
  in
    aux asms [] [] [] []

let dump_name_to_int_map level name name_map =
  let spc = spaces level in
  print_endline (spc ^ "//Name to int map for " ^ name);
  print_endline (spc ^ "//---------------");
  Hashtbl.iter
  (
    fun id n ->
      print_endline ( "//" ^ spc ^ id ^ ": " ^ si n)
  )
  name_map
  ;
  print_endline ""

let strp = function | Some x -> si x | None -> "none"

let full_add_unique syms sr (vs:ivs_list_t) table key value =
  try
    let entry = Hashtbl.find table key in
    match entry with
    | `NonFunctionEntry (idx)
    | `FunctionEntry (idx :: _ ) ->
       (match Hashtbl.find syms.dfns (sye idx)  with
       | { sr=sr2 } ->
         clierr2 sr sr2
         ("[build_tables] Duplicate non-function " ^ key ^ "<"^si (sye idx)^">")
       )
     | `FunctionEntry [] -> assert false
  with Not_found ->
    Hashtbl.add table key (`NonFunctionEntry (mkentry syms vs value))

let full_add_typevar syms sr table key value =
  try
    let entry = Hashtbl.find table key in
    match entry with
    | `NonFunctionEntry (idx)
    | `FunctionEntry (idx :: _ ) ->
       (match Hashtbl.find syms.dfns (sye idx)  with
       | { sr=sr2 } ->
         clierr2 sr sr2
         ("[build_tables] Duplicate non-function " ^ key ^ "<"^si (sye idx)^">")
       )
     | `FunctionEntry [] -> assert false
  with Not_found ->
    Hashtbl.add table key (`NonFunctionEntry (mkentry syms dfltvs value))


let full_add_function syms sr (vs:ivs_list_t) table key value =
  try
    match Hashtbl.find table key with
    | `NonFunctionEntry entry ->
      begin
        match Hashtbl.find syms.dfns ( sye entry ) with
        { id=id; sr=sr2 } ->
        clierr2 sr sr2
        (
          "[build_tables] Cannot overload " ^
          key ^ "<" ^ si value ^ ">" ^
          " with non-function " ^
          id ^ "<" ^ si (sye entry) ^ ">"
        )
      end

    | `FunctionEntry fs ->
      Hashtbl.remove table key;
      Hashtbl.add table key (`FunctionEntry (mkentry syms vs value :: fs))
  with Not_found ->
    Hashtbl.add table key (`FunctionEntry [mkentry syms vs value])

(* this routine takes a partially filled unbound definition table,
  'dfns' and a counter 'counter', and adds entries to the table
  at locations equal to and above the counter

  Each entity is also added to the name map of the parent entity.

  We use recursive descent, noting that the whilst an entity
  is not registered until its children are completely registered,
  its index is allocated before descending into child structures,
  so the index of children is always higher than its parent numerically

  The parent index is passed down so an uplink to the parent can
  be created in the child, but it cannot be followed until
  registration of all the children and their parent is complete
*)


let rec build_tables syms name inherit_vs
  level parent grandparent root is_class asms
=
  (*
  print_endline ("//Building tables for " ^ name);
  *)
  let
    print_flag = syms.compiler_options.print_flag and
    dfns = syms.dfns and
    counter = syms.counter
  in
  let dcls,exes,ifaces,export_dirs = split_asms asms in
  let dcls,exes,ifaces,export_dirs =
    rev dcls,rev exes,rev ifaces, rev export_dirs
  in
  let ifaces = map (fun (i,j)-> i,j,parent) ifaces in
  let interfaces = ref ifaces in
  let spc = spaces level in
  let pub_name_map = Hashtbl.create 97 in
  let priv_name_map = Hashtbl.create 97 in

  (* check root index *)
  if level = 0
  then begin
    if root <> !counter
    then failwith "Wrong value for root index";
    begin match dcls with
    | [x] -> ()
    | _ -> failwith "Expected top level to contain exactly one module declaration"
    end
    ;
    if name <> "root"
    then failwith
      ("Expected top level to be called root, got " ^ name)
  end
  else
    if name = "root"
    then failwith ("Can't name non-toplevel module 'root'")
    else
      Hashtbl.add priv_name_map "root" (`NonFunctionEntry (mkentry syms dfltvs root))
  ;
  begin
    iter
    (
      fun (sr,id,seq,access,vs',dcl) ->
        let pubtab = Hashtbl.create 3 in (* dummy-ish table could contain type vars *)
        let privtab = Hashtbl.create 3 in (* dummy-ish table could contain type vars *)
        let n = match seq with
          | Some n -> (* print_endline ("SPECIAL " ^ id ^ si n); *) n
          | None -> let n = !counter in incr counter; n
        in
        if print_flag then begin
          let kind = match dcl with
          | `DCL_class _ -> "(class) "
          | `DCL_function _ -> "(function) "
          | `DCL_module _ -> "(module) "
          | `DCL_insert _ -> "(insert) "
          | `DCL_typeclass _ -> "(typeclass) "
          | `DCL_instance _ -> "(instance) "
          | `DCL_fun _ -> "(fun) "
          | `DCL_var _ -> "(var) "
          | `DCL_val _ -> "(val) "
          | _ -> ""
          in
          let vss = catmap "," fst (fst vs') in
          let vss = if vss <> "" then "["^vss^"]" else "" in
          print_endline
          (
            "//" ^ spc ^ si n ^ " -> " ^ id ^ vss ^
            " " ^ kind ^ short_string_of_src sr
          )
        end;
        let make_vs (vs',con) : ivs_list_t =
          map
          (
            fun (tid,tpat)-> let n = !counter in incr counter;
            if print_flag then
            print_endline ("//  "^spc ^ si n ^ " -> " ^ tid^ " (type variable)");
            tid,n,tpat
          )
          vs'
          ,
          con
        in
        let vs = make_vs vs' in

        (*
        begin
          match vs with (_,{raw_typeclass_reqs=rtcr})->
          match rtcr  with
          | _::_ ->
            print_endline (id^": TYPECLASS REQUIREMENTS " ^
            catmap "," string_of_qualified_name rtcr);
          | [] -> ();
        end;
        let rec addtc tcin dirsout = match tcin with
          | [] -> rev dirsout
          | h::t ->
            addtc t (DIR_typeclass_req h :: dirsout);
        in
        let typeclass_dirs =
          match vs with (_,{raw_typeclass_reqs=rtcr})-> addtc rtcr []
        in
        *)

        let add_unique table id idx = full_add_unique syms sr (merge_ivs vs inherit_vs) table id idx in
        let add_function table id idx = full_add_function syms sr (merge_ivs vs inherit_vs) table id idx in
        let add_tvars' parent table vs =
          iter
          (fun (tvid,i,tpat) ->
            let mt = match tpat with
              | `AST_patany _ -> `TYP_type (* default/unspecified *)
              (*
              | #suffixed_name_t as name ->
                print_endline ("Decoding type variable " ^ si i ^ " kind");
                print_endline ("Hacking suffixed kind name " ^ string_of_suffixed_name name ^ " to TYPE");
                `TYP_type (* HACK *)
              *)

              | `TYP_none -> `TYP_type
              | `TYP_ellipsis -> clierr sr "Ellipsis ... as metatype"
              | _ -> tpat
            in
            Hashtbl.add dfns i
            {
              id=tvid;
              sr=sr;
              parent=parent;
              vs=dfltvs;
              pubmap=null_tab;
              privmap=null_tab;
              dirs=[];
              symdef=`SYMDEF_typevar mt
            };
            full_add_typevar syms sr table tvid i
          )
          (fst vs)
        in
        let add_tvars table = add_tvars' (Some n) table vs in

        let handle_class class_kind classno sts tvars stype =
          if print_flag then
          print_endline ("//Interfaces for class " ^ si classno);
          (* projections *)
          iter
          (fun mem ->
            let kind, component_name,component_index,mvs,t,cc =
              match mem with
              | `MemberVar (n,t,cc) -> `Var,n,None,dfltvs,t,cc
              | `MemberVal (n,t,cc) -> `Val,n,None,dfltvs,t,cc
              | `MemberFun (n,mix,vs,t,cc) -> `Fun,n,mix,vs,t,cc
              | `MemberProc (n,mix,vs,t,cc) -> `Proc,n,mix,vs,t,cc
              | `MemberCtor (n,mix,t,cc) -> `Ctor,n,mix,dfltvs,t,cc
            in
            (*
            print_endline ("//Member " ^ component_name);
            print_endline ("vs= " ^ catmap "," (fun (n,i)->n) (fst mvs));
            *)
            let mtvars = map (fun (s,_)-> `AST_name (sr,s,[])) (fst mvs) in
            if print_flag then
            print_endline ("//Member " ^ component_name);
            if kind = `Ctor && class_kind = `CClass then
            begin
              let ctor_index = !(syms.counter) in incr (syms.counter);
              let ctor_name = "_ctor_" ^ id in
              let ct =
                match vs with
                | [],_ -> `StrTemplate("new "^ id^"($a)")
                | _ -> `StrTemplate("new "^ id^"<?a>($a)")
              in
              let argst = match t with
                | `TYP_tuple ls -> ls
                | x -> [x]
              in
              let symdef = `SYMDEF_fun ([],argst,stype,ct,`NREQ_true,"primary") in
              Hashtbl.add dfns ctor_index {
                id=ctor_name;sr=sr;parent=parent;
                vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];
                symdef=symdef
              }
              ;
              if access = `Public then add_function pub_name_map ctor_name ctor_index;
              add_function priv_name_map ctor_name ctor_index;
              if print_flag then print_endline ("//  " ^ spc ^ si ctor_index ^ " -> " ^ ctor_name ^ " [ctor]")
            end
            ;

            if (kind = `Fun || kind = `Proc) then
            begin
              let domain,codomain =
                match t with
                | `TYP_function (domain,codomain) when kind = `Fun ->
                  domain,codomain
                | domain when kind = `Proc ->
                  domain,`AST_void sr
                | _ -> clierr sr "Accessor method must have function type"
              in
              let obj_name = "_a_" ^ component_name in
              let getn = !counter in incr counter;
              let get_name = "get_" ^ component_name in
              let props = [] in
              let ps = [stype] in
              if print_flag then
              print_endline "//Get method for function";

              (* the return type of the get_f function *)
              let rett = `TYP_function (domain,codomain) in
              (* add parameters to symbol table of the function,
                there is only one, namely the object
              *)
              let objidx = !counter in incr counter;
              let get_asms =
                if class_kind = `CClass || cc <> None then
                begin
                 (* make applicator method. This precisely the function:

                       fun get_f(x:X) (a:arg_t): result_t => exec_f (x,a);

                       which reduces to

                       fun get_f(x:X): arg_t -> result_t = {
                         fun do_f(a:arg_t): result_t = {
                           fun exec_f: X * arg_t -> result_t = "$1->f($b)";
                           return exec_f (x,a);
                         }
                         return do_f;
                       }

                  *)

                    (* make the execute method *)
                    let argts = match domain with
                      | `TYP_tuple ls -> ls
                      | x -> [x]
                    in

                    (* The exec method *)
                    let execn = !counter in incr counter;
                    let exec_name = "exec_" ^ component_name in
                    let exec_asm =
                      let cc =
                        match cc with Some cc -> cc | None ->
                        let trail =
                          (match codomain with `AST_void _ -> ";" | _ -> "")
                        in
                          `StrTemplate("$1->" ^ component_name^"($b)" ^ trail)
                      in
                          `Dcl (sr,exec_name,Some execn,`Private,dfltvs, (* vs inherited *)
                            `DCL_fun ([],stype::argts,codomain, cc,`NREQ_true,"primary")
                          )
                    in

                    (* the do method *)
                    let don = !counter in incr counter;
                    let do_name = "_do_" ^ component_name in
                    let do_asm =
                      let f = `AST_index (sr,exec_name,execn)  in
                      let cnt = ref 1 in
                      let params =
                        map
                        (fun t ->
                          let i = !cnt in incr cnt;
                          let pname = "_" ^ si i in
                          (`PVal,pname,t,None)
                        )
                        argts
                      in
                      let args = map (fun(_,n,_,_)->n) params in
                      let arg = `AST_tuple (sr, map (fun n -> `AST_name (sr,n,[])) (obj_name::args)) in
                      let asms =
                        [
                          `Exe (sr,
                            (match codomain with
                            | `AST_void _ -> `EXE_call (f,arg)
                            | _ -> `EXE_fun_return (`AST_apply(sr,(f,arg)))
                            )
                          );
                          exec_asm
                        ]
                      in
                      `Dcl (sr,do_name,Some don, `Private,dfltvs, (* vs inherited *)
                        `DCL_function ((params,None),codomain,[],asms)
                      )
                    in
                    let get_asms =
                      [
                        `Exe (sr,`EXE_fun_return (`AST_index (sr,do_name,don)));
                        do_asm
                      ]
                    in
                    get_asms
                end else begin
                  match component_index with
                  | None -> assert false
                  | Some mix ->
                  let get_asms =
                      [
                        `Exe
                        (
                          sr,
                          `EXE_fun_return
                          (
                            `AST_get_named_method
                            (
                              sr,
                              (
                                component_name, mix,mtvars,
                                `AST_index (sr,obj_name,objidx)
                              )
                            )
                          )
                        )
                      ]
                  in
                  get_asms
                end
              in
              begin
                if print_flag then
                print_endline ("//Building tables for " ^ get_name);
                let pubtab,privtab, exes, ifaces,dirs =
                  build_tables syms get_name dfltvs (level+1)
                 (Some getn) parent root false get_asms
                in
                (* print_endline "Making fresh type variables"; *)
                let vs = make_vs vs' in
                let mvs = make_vs mvs in
                add_tvars' (Some getn) privtab (merge_ivs vs mvs);
                (* add the get method to the current sumbol table *)
                if print_flag then
                print_endline ("//Adding get method " ^ get_name ^ " with vs=" ^
                  print_ivs_with_index (merge_ivs vs mvs) ^ ", parent = " ^ strp parent
                );
                Hashtbl.add dfns getn {
                  id=get_name;sr=sr;parent=parent;
                  vs=merge_ivs vs mvs;pubmap=pubtab;privmap=privtab;dirs=dirs;
                  symdef=`SYMDEF_function (
                    ([`PVal,obj_name,stype,None],None), rett, props, exes
                  )
                };
                let xvs = merge_ivs vs mvs in
                let xvs = merge_ivs inherit_vs xvs in
                (*
                print_endline ("ADDING class method " ^ get_name);
                print_endline ("vs= " ^ catmap "," (fun (n,i,_)->n) (fst xvs));
                *)
                full_add_function syms sr xvs pub_name_map get_name getn;
                full_add_function syms sr xvs priv_name_map get_name getn;
                (*
                add_function pub_name_map get_name getn;
                add_function priv_name_map get_name getn;
                *)

                (* add parameter now *)
                if print_flag then
                print_endline ("//  "^spc ^ si objidx ^ " -> " ^ obj_name^ " (parameter)");
                Hashtbl.add dfns objidx {
                  id=obj_name;sr=sr;parent=Some getn;vs=dfltvs;
                  pubmap=null_tab;privmap=null_tab;dirs=[];
                  symdef=`SYMDEF_parameter (`PVal,stype)
                };
                (*
                if access = `Public then add_unique pubtab obj_name objidx;
                add_unique privtab obj_name objidx;
                *)
                if access = `Public then full_add_unique syms sr dfltvs pubtab obj_name objidx;
                full_add_unique syms sr dfltvs privtab obj_name objidx;

                interfaces := !interfaces @ ifaces
                ;
                if print_flag then
                print_endline ("//  " ^ spc ^ si getn ^ " -> " ^ get_name)
              end
            end
            ;
            if kind = `Var || kind = `Val then
            begin
              if print_flag then
              print_endline "//Get method for variable";
              let getn = !counter in incr counter;
              let get_name = "get_" ^ component_name in
              let funtab = Hashtbl.create 3 in
              let vs = make_vs vs' in
              add_tvars' (Some getn) funtab vs;
              (* add the get method to the current sumbol table *)
              if print_flag then
              print_endline ("//Adding get method " ^ get_name ^ " with vs=" ^
                  print_ivs_with_index vs ^ ", parent = " ^ strp parent
              );
              let get_dcl =
                if class_kind = `CClass then
                  `SYMDEF_fun ([],[stype],t,
                    `StrTemplate("$1->" ^ component_name),
                    `NREQ_true,"primary"
                  )
                else
                  let objix = !(syms.counter) in incr syms.counter;
                  let objname = "obj" in
                  Hashtbl.add dfns objix {
                    id=objname;sr=sr;parent=Some getn;
                    vs=dfltvs;pubmap=null_tab;privmap=null_tab;
                    dirs=[];symdef=`SYMDEF_parameter (`PVal,stype)
                  };
                  (*
                  add_unique funtab objname objix;
                  *)
                  full_add_unique syms sr dfltvs funtab objname objix;
                  let ps = [`PVal,"obj",stype,None],None in
                  let exes = [sr,
                    `EXE_fun_return (`AST_get_named_variable (sr,
                      (component_name,`AST_index (sr,"obj",objix))
                    ))
                  ]
                  in
                  `SYMDEF_function (ps,t,[`Inline],exes)
              in
              (* the get function, lives outside class *)
              Hashtbl.add dfns getn {
                id=get_name;sr=sr;parent=parent;vs=vs;
                pubmap=funtab;privmap=funtab;dirs=[];
                symdef=get_dcl
              };
              if access = `Public then add_function pub_name_map get_name getn;
              add_function priv_name_map get_name getn
              ;
              (*
              print_endline ("Added " ^ get_name ^ " to class parent");
              *)
              if print_flag then
              print_endline ("//  " ^ spc ^ si getn ^ " -> " ^ get_name)
            end
            ;
            (* LVALUE VARIATION *)
            if kind = `Var then
            begin
              let funtab = Hashtbl.create 3 in
              let getn = !counter in incr counter;
              let get_name = "get_" ^ component_name in
              let vs = make_vs vs' in
              add_tvars' (Some getn) funtab vs;
              let get_dcl =
                if class_kind = `CClass then
                 (* `SYMDEF_fun ([],[`TYP_lvalue stype],`TYP_lvalue t, *)
                 `SYMDEF_fun ([],[stype],t,
                   `StrTemplate ("$1->" ^ component_name),
                   `NREQ_true,"primary"
                 )
                else
                  let objix = !(syms.counter) in incr syms.counter;
                  let objname = "obj" in
                  Hashtbl.add dfns objix {
                    id=objname;sr=sr;parent=Some getn;
                    vs=dfltvs;pubmap=null_tab;privmap=null_tab;
                    (* dirs=[];symdef=`SYMDEF_parameter (`PVal,`TYP_lvalue stype) *)
                    dirs=[];symdef=`SYMDEF_parameter (`PVal,stype)
                  };
                  (*
                  add_unique funtab objname objix;
                  *)
                  full_add_unique syms sr dfltvs funtab objname objix;
                  (* let ps = [`PVal,"obj",`TYP_lvalue stype,None],None in *)
                  let ps = [`PVal,"obj",stype,None],None in
                  let exes = [sr,
                    `EXE_fun_return (`AST_get_named_variable (sr,
                      (component_name,`AST_index (sr,"obj",objix))
                    ))
                  ]
                  in
                  (* `SYMDEF_function (ps,`TYP_lvalue t,[`Inline],exes) *)
                  `SYMDEF_function (ps,t,[`Inline],exes)
              in
              Hashtbl.add dfns getn {
                id=get_name;sr=sr;parent=parent;vs=vs;
                pubmap=funtab;privmap=funtab;dirs=[];
                symdef=get_dcl
              };
              if access = `Public then add_function pub_name_map get_name getn;
              add_function priv_name_map get_name getn
              ;
              if print_flag then
              print_endline ("//  " ^ spc ^ si getn ^ " -> " ^ get_name ^ " [lvalue]")
            end

          )
          sts
          ;
          if print_flag then
          print_endline "//---- end interface----";
        in
        begin match (dcl:dcl_t) with
        | `DCL_regdef re ->
          if is_class then clierr sr "Regdef not allowed in class";
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];symdef=`SYMDEF_regdef re};
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_regmatch cls ->
          if is_class then clierr sr "Regmatch not allowed in class";
          let lexmod = `AST_name (sr,"Lexer",[]) in
          let ptyp = `AST_lookup (sr,(lexmod,"iterator",[])) in

          let p1 = !(syms.counter) in incr syms.counter;
          let p2 = !(syms.counter) in incr syms.counter;
          full_add_unique syms sr dfltvs privtab "lexeme_start" p1;
          full_add_unique syms sr dfltvs privtab "buffer_end" p2;
          Hashtbl.add dfns p1 {id="lexeme_start";sr=sr;
            parent=Some n;vs=vs;
            pubmap=Hashtbl.create 3;privmap=Hashtbl.create 3;dirs=[];
            symdef=`SYMDEF_parameter (`PVal,ptyp)
          };

          Hashtbl.add dfns p2 {id="buffer_end";sr=sr;
            parent=Some n;vs=vs;
            pubmap=Hashtbl.create 3;privmap=Hashtbl.create 3;dirs=[];
            symdef=`SYMDEF_parameter (`PVal,ptyp)
          };

          let ps = [`PVal,"lexeme_start",ptyp,None; `PVal,"buffer_end",ptyp,None],None in


          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;
            vs=vs; pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_regmatch (ps,cls)
          };
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_reglex cls ->
          if is_class then clierr sr "Reglex not allowed in class";
          let lexmod = `AST_name (sr,"Lexer",[]) in
          let ptyp = `AST_lookup (sr,(lexmod,"iterator",[])) in

          let p1 = !(syms.counter) in incr syms.counter;
          let p2 = !(syms.counter) in incr syms.counter;
          let v3 = !(syms.counter) in incr syms.counter;

          full_add_unique syms sr dfltvs privtab "lexeme_start" p1;
          full_add_unique syms sr dfltvs privtab "buffer_end" p2;
          full_add_unique syms sr dfltvs privtab "lexeme_end" v3;

          Hashtbl.add dfns p1 {id="lexeme_start";sr=sr;
            parent=Some n;vs=vs;
            pubmap=Hashtbl.create 3;privmap=Hashtbl.create 3;dirs=[];
            symdef=`SYMDEF_parameter (`PVal,ptyp)
          };

          Hashtbl.add dfns p2 {id="buffer_end";sr=sr;
            parent=Some n;vs=vs;
            pubmap=Hashtbl.create 3;privmap=Hashtbl.create 3;dirs=[];
            symdef=`SYMDEF_parameter (`PVal,ptyp)
          };

          Hashtbl.add dfns v3 {id="lexeme_end";sr=sr;
            parent=Some n;vs=vs;
            pubmap=Hashtbl.create 3;privmap=Hashtbl.create 3;dirs=[];
            symdef=`SYMDEF_var ptyp
          };

          let ps = [`PVal,"lexeme_start",ptyp,None; `PVal,"buffer_end",ptyp,None],None in

          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;
            vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_reglex (ps,v3,cls)
          };
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab


        | `DCL_reduce (ps,e1,e2) ->
          let fun_index = n in
          let ips = ref [] in
          iter (fun (name,typ) ->
            let n = !counter in incr counter;
            if print_flag then
            print_endline ("//  "^spc ^ si n ^ " -> " ^ name^ " (parameter)");
            Hashtbl.add dfns n {
              id=name;sr=sr;parent=Some fun_index;
              vs=dfltvs;pubmap=null_tab;privmap=null_tab;
              dirs=[];symdef=`SYMDEF_parameter (`PVal,typ)
            };
            if access = `Public then full_add_unique syms sr dfltvs pubtab name n;
            full_add_unique syms sr dfltvs privtab name n;
            ips := (`PVal,name,typ,None) :: !ips
          ) ps
          ;
          Hashtbl.add dfns fun_index {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_reduce (rev !ips, e1, e2)
          };
          ;
          add_tvars privtab

        | `DCL_axiom ((ps,pre),e1) ->
          let fun_index = n in
          let ips = ref [] in
          iter (fun (k,name,typ,dflt) ->
            let n = !counter in incr counter;
            if print_flag then
            print_endline ("//  "^spc ^ si n ^ " -> " ^ name^ " (parameter)");
            Hashtbl.add dfns n {
              id=name;sr=sr;parent=Some fun_index;
              vs=dfltvs;pubmap=null_tab;privmap=null_tab;
              dirs=[];symdef=`SYMDEF_parameter (k,typ)
            };
            if access = `Public then full_add_unique syms sr dfltvs pubtab name n;
            full_add_unique syms sr dfltvs privtab name n;
            ips := (k,name,typ,dflt) :: !ips
          ) ps
          ;
          Hashtbl.add dfns fun_index {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_axiom ((rev !ips, pre),e1)
          };
          ;
          add_tvars privtab

        | `DCL_lemma ((ps,pre),e1) ->
          let fun_index = n in
          let ips = ref [] in
          iter (fun (k,name,typ,dflt) ->
            let n = !counter in incr counter;
            if print_flag then
            print_endline ("//  "^spc ^ si n ^ " -> " ^ name^ " (parameter)");
            Hashtbl.add dfns n {
              id=name;sr=sr;parent=Some fun_index;
              vs=dfltvs;pubmap=null_tab;privmap=null_tab;
              dirs=[];symdef=`SYMDEF_parameter (k,typ)
            };
            if access = `Public then full_add_unique syms sr dfltvs pubtab name n;
            full_add_unique syms sr dfltvs privtab name n;
            ips := (k,name,typ,dflt) :: !ips
          ) ps
          ;
          Hashtbl.add dfns fun_index {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_lemma ((rev !ips, pre),e1)
          };
          ;
          add_tvars privtab


        | `DCL_function ((ps,pre),t,props,asms) ->
          let is_ctor =  mem `Ctor props in

          if is_ctor && id <> "__constructor__"
          then syserr sr
            "Function with constructor property not named __constructor__"
          ;

          if is_ctor && not is_class
          then clierr sr
            "Constructors must be defined directly inside a class"
          ;

          if is_ctor then
            begin match t with
            | `AST_void _ -> ()
            | _ -> syserr sr
              "Constructor should return type void"
            end
          ;

          (* change the name of a constructor to the class name
            prefixed by _ctor_
          *)
          let id = if is_ctor then "_ctor_" ^ name else id in
          (*
          if is_class && not is_ctor then
            print_endline ("TABLING METHOD " ^ id ^ " OF CLASS " ^ name);
          *)
          let fun_index = n in
          let t = if t = `TYP_none then `TYP_var fun_index else t in
          let pubtab,privtab, exes, ifaces,dirs =
            build_tables syms id dfltvs (level+1)
            (Some fun_index) parent root false asms
          in
          let ips = ref [] in
          iter (fun (k,name,typ,dflt) ->
            let n = !counter in incr counter;
            if print_flag then
            print_endline ("//  "^spc ^ si n ^ " -> " ^ name^ " (parameter)");
            Hashtbl.add dfns n {
              id=name;sr=sr;parent=Some fun_index;
              vs=dfltvs;pubmap=null_tab;privmap=null_tab;
              dirs=[];symdef=`SYMDEF_parameter (k,typ)
            };
            if access = `Public then full_add_unique syms sr dfltvs pubtab name n;
            full_add_unique syms sr dfltvs privtab name n;
            ips := (k,name,typ,dflt) :: !ips
          ) ps
          ;
          Hashtbl.add dfns fun_index {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;
            dirs=dirs;
            symdef=`SYMDEF_function ((rev !ips,pre), t, props, exes)
          };
          if access = `Public then add_function pub_name_map id fun_index;
          add_function priv_name_map id fun_index;
          interfaces := !interfaces @ ifaces
          ;
          add_tvars privtab

        | `DCL_match_check (pat,(mvname,match_var_index)) ->
          if is_class then clierr sr "Match check not allowed in class";
          assert (length (fst vs) = 0);
          let fun_index = n in
          Hashtbl.add dfns fun_index {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_match_check (pat, (mvname,match_var_index))}
          ;
          if access = `Public then add_function pub_name_map id fun_index ;
          add_function priv_name_map id fun_index ;
          interfaces := !interfaces @ ifaces
          ;
          add_tvars privtab

        | `DCL_match_handler (pat,(mvname,match_var_index),asms) ->
          if is_class then clierr sr "Match handler not allowed in class";
          (*
          print_endline ("Parent is " ^ match parent with Some i -> si i);
          print_endline ("Match handler, "^si n^", mvname = " ^ mvname);
          *)
          assert (length (fst vs) = 0);
          let vars = Hashtbl.create 97 in
          Flx_mbind.get_pattern_vars vars pat [];
          (*
          print_endline ("PATTERN IS " ^ string_of_pattern pat ^ ", VARIABLE=" ^ mvname);
          print_endline "VARIABLES ARE";
          Hashtbl.iter (fun vname (sr,extractor) ->
            let component =
              Flx_mbind.gen_extractor extractor (`AST_index (sr,mvname,match_var_index))
            in
            print_endline ("  " ^ vname ^ " := " ^ string_of_expr component);
          ) vars;
          *)

          let new_asms = ref asms in
          Hashtbl.iter
          (fun vname (sr,extractor) ->
            let component =
              Flx_mbind.gen_extractor extractor
              (`AST_index (sr,mvname,match_var_index))
            in
            let dcl =
              `Dcl (sr, vname, None,`Private, dfltvs,
                `DCL_val (`TYP_typeof (component))
              )
            and instr = `Exe (sr, `EXE_init (vname, component))
            in
              new_asms := dcl :: instr :: !new_asms;
          )
          vars;
          (*
          print_endline ("asms are" ^ string_of_desugared !new_asms);
          *)
          let fun_index = n in
          let pubtab,privtab, exes,ifaces,dirs =
            build_tables syms id dfltvs (level+1)
            (Some fun_index) parent root false !new_asms
          in
          Hashtbl.add dfns fun_index {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;
            dirs=dirs;
            symdef=`SYMDEF_function (([],None),`TYP_var fun_index, [`Generated "symtab:match handler" ; `Inline],exes)
          };
          if access = `Public then
            add_function pub_name_map id fun_index;
          add_function priv_name_map id fun_index;
          interfaces := !interfaces @ ifaces
          ;
          add_tvars privtab


        | `DCL_insert (s,ikind,reqs) ->
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_insert (s,ikind,reqs)
          };
          if access = `Public then add_function pub_name_map id n;
          add_function priv_name_map id n

        | `DCL_module asms ->
          if is_class then clierr sr "Module not allowed in class";
          let pubtab,privtab, exes,ifaces,dirs =
            build_tables syms id (merge_ivs inherit_vs vs)
            (level+1) (Some n) parent root false
            asms
          in
          Hashtbl.add dfns n {
            id=id;sr=sr;
            parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;
            dirs=dirs;
            symdef=`SYMDEF_module
          };
          let n' = !counter in
          incr counter;
          let init_def = `SYMDEF_function ( ([],None),`AST_void sr, [],exes) in
          if print_flag then
          print_endline ("//  "^spc ^ si n' ^ " -> _init_  (module "^id^")");
          Hashtbl.add dfns n' {id="_init_";sr=sr;parent=Some n;vs=vs;pubmap=null_tab;privmap=null_tab;dirs=[];symdef=init_def};

          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n;
          if access = `Public then add_function pubtab ("_init_") n';
          add_function privtab ("_init_") n';
          interfaces := !interfaces @ ifaces
          ;
          add_tvars privtab

        | `DCL_typeclass asms ->
          (*
          let symdef = `SYMDEF_typeclass in
          let tvars = map (fun (s,_,_)-> `AST_name (sr,s,[])) (fst vs) in
          let stype = `AST_name(sr,id,tvars) in
          *)
          if is_class then clierr sr "typeclass not allowed in class";

          let pubtab,privtab, exes,ifaces,dirs =
            build_tables syms id (merge_ivs inherit_vs vs)
            (level+1) (Some n) parent root false
            asms
          in
          let fudged_privtab = Hashtbl.create 97 in
          let vsl = length (fst inherit_vs) + length (fst vs) in
          (*
          print_endline ("Strip " ^ si vsl ^ " vs");
          *)
          let drop vs =
            let keep = length vs - vsl in
            if keep >= 0 then rev (list_prefix (rev vs) keep)
            else failwith "WEIRD CASE"
          in
          let nts = map (fun (s,i,t)-> `BTYP_var (i,`BTYP_type 0)) (fst vs) in
          (* fudge the private view to remove the vs *)
          let show { base_sym=i; spec_vs=vs; sub_ts=ts } =
          si i ^ " |-> " ^
            "vs= " ^catmap "," (fun (s,i) -> s^"<" ^si i^">") vs^
            "ts =" ^catmap  "," (sbt syms.dfns) ts
          in
          let fixup ({ base_sym=i; spec_vs=vs; sub_ts=ts } as e) =
            let e' = {
              base_sym=i;
              spec_vs=drop vs;
              sub_ts=nts @ drop ts
              }
            in
            (*
            print_endline (show e ^ " ===> " ^ show e');
            *)
            e'
          in
          Hashtbl.iter
          (fun s es ->
            (*
            print_endline ("Entry " ^ s );
            *)
            let nues =
              if s = "root" then es else
              match es with
              | `NonFunctionEntry e ->
                 `NonFunctionEntry (fixup e)
              | `FunctionEntry es ->
                `FunctionEntry (map fixup es)
             in
             Hashtbl.add fudged_privtab s nues
          )
          privtab
          ;
          Hashtbl.add dfns n {
            id=id;sr=sr;parent=parent;
            vs=vs;pubmap=pubtab;privmap=fudged_privtab;dirs=dirs;
            symdef=`SYMDEF_typeclass
          }
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n;
          interfaces := !interfaces @ ifaces
          ;
          add_tvars fudged_privtab


        | `DCL_instance (qn,asms) ->
          if is_class then clierr sr "instance not allowed in class";
          let pubtab,privtab, exes,ifaces,dirs =
            build_tables syms id dfltvs
            (level+1) (Some n) parent root false
            asms
          in
          Hashtbl.add dfns n {
            id=id;sr=sr;
            parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;
            dirs=dirs;
            symdef=`SYMDEF_instance qn
          };
          let inst_name = "_inst_" ^ id in
          if access = `Public then add_function pub_name_map inst_name n;
          add_function priv_name_map inst_name n;
          interfaces := !interfaces @ ifaces
          ;
          add_tvars privtab

        | `DCL_class asms ->
          if is_class then clierr sr "class not allowed in class";
          let pubtab,privtab, exes,ifaces,dirs =
            build_tables syms id dfltvs (level+1) (Some n) parent root true
            asms
          in
          Hashtbl.add dfns n {
            id=id;sr=sr;
            parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;
            dirs=dirs;
            symdef=`SYMDEF_class
          };
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n;
          interfaces := !interfaces @ ifaces
          ;
          add_tvars privtab
          ;
          let thisix = !(syms.counter) in incr counter;
          let dcl =`SYMDEF_const ([],`AST_index (sr,id,n),`Str "#this",`NREQ_true) in
          Hashtbl.add syms.dfns thisix {
            id="this";sr=sr;parent=Some n; vs=dfltvs;
            pubmap=null_tab; privmap=null_tab;
            dirs=[];symdef=dcl
          };
          full_add_unique syms sr dfltvs privtab "this" thisix;
          (*
          print_endline ("Added this: " ^ si thisix);
          *)

          (* Hack it by building an interface *)
          let tvars = map (fun (s,_,_)-> `AST_name (sr,s,[])) (fst vs) in
          let stype = `AST_name(sr,id,tvars) in


          (* THIS IS A SUPERIOR HACK!!!! *)
          let sts = ref [] in
          let detail {base_sym=idx} =
            match
              try Hashtbl.find syms.dfns idx
              with Not_found ->
                (*
                print_endline ("Wah! Can't find entry " ^ si idx);
                *)
                raise Not_found

            with
            | {id=id; vs=vs;symdef=symdef} ->
            let vs : vs_list_t = map (fun (s,i,pat) -> s,pat) (fst vs),snd vs in
            match symdef with
            | `SYMDEF_var t -> sts := `MemberVar (id,t,None) :: !sts
            | `SYMDEF_val t -> sts := `MemberVal (id,t,None) :: ! sts
            | `SYMDEF_function (ps,ret,props,_) ->
              if mem `Ctor props then () else
              let ps = map (fun(_,_,t,_)->t)(fst ps) in
              let a = match ps with
                | [x] -> x
                | x -> `TYP_tuple x
              in
              begin match ret with
              | `AST_void _ -> sts := `MemberProc (id,Some idx,vs,a,None) :: !sts
              | _ -> sts := `MemberFun (id,Some idx,vs,`TYP_function(a,ret),None) :: !sts
              end
            | _ -> ()
          in
          let detail x = try detail x with Not_found -> () in
          Hashtbl.iter
          (fun id entry -> match entry with
          | `NonFunctionEntry idx -> detail idx
          | `FunctionEntry idxs -> iter detail idxs
          )
          privtab
          ;
          handle_class `Class n (!sts) tvars stype

        | `DCL_val t ->
          let t = match t with | `TYP_none -> `TYP_var n | _ -> t in
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];symdef=`SYMDEF_val (t)}
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_var t ->
          let t = if t = `TYP_none then `TYP_var n else t in
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];symdef=
            (* `SYMDEF_var (`TYP_lvalue t) *)
            `SYMDEF_var t
          }
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_lazy (t,e) ->
          let t = if t = `TYP_none then `TYP_var n else t in
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];symdef=`SYMDEF_lazy (t,e)}
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_ref t ->
          let t = match t with | `TYP_none -> `TYP_var n | _ -> t in
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];symdef=`SYMDEF_ref (t)}
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_type_alias (t) ->
          if is_class then clierr sr "Type alias not allowed in class";
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];symdef=`SYMDEF_type_alias t}
          ;
          (* this is a hack, checking for a type function this way,
             since it will also incorrectly recognize a type lambda like:

             typedef f = fun(x:TYPE)=>x;

             With ordinary functions:

             f := fun (x:int)=>x;

             initialises a value, and this f cannot be overloaded.

             That is, a closure (object) and a function (class) are
             distinguished .. this should be the same for type
             functions as well.

             EVEN WORSE: our system is getting confused with
             unbound type variables which are HOLES in types, and
             parameters, which are bound variables: the latter
             are really just the same as type aliases where
             the alias isn't known. The problem is that we usually
             substitute names with what they alias, but we can't
             for parameters, so we replace them with undistinguished
             type variables.

             Consequently, for a type function with a type
             function as a parameter, the parameter name is being
             overloaded when it is applied, which is wrong.

             We need to do what we do with ordinary function:
             put the parameter names into the symbol table too:
             lookup_name_with_sig can handle this, because it checks
             both function set results and non-function results.
          *)
          begin match t with
          | `TYP_typefun _
          | `TYP_case _ ->
            if access = `Public then add_function pub_name_map id n;
            add_function priv_name_map id n
          | _ ->
            if access = `Public then add_unique pub_name_map id n;
            add_unique priv_name_map id n
          end;
          add_tvars privtab

        | `DCL_inherit qn ->
          Hashtbl.add dfns n
          {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;
          privmap=privtab;dirs=[];symdef=`SYMDEF_inherit qn}
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

         | `DCL_inherit_fun qn ->
          if is_class then clierr sr "inherit clause not allowed in class";
          Hashtbl.add dfns n
          {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;
          privmap=privtab;dirs=[];symdef=`SYMDEF_inherit_fun qn}
          ;
          if access = `Public then add_function pub_name_map id n;
          add_function priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_newtype t ->
          if is_class then clierr sr "Type abstraction not allowed in class";
          Hashtbl.add dfns n {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_newtype t
          }
          ;
          let n_repr = !(syms.counter) in incr (syms.counter);
          let piname = `AST_name (sr,id,[]) in
          Hashtbl.add dfns n_repr {
            id="_repr_";sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_fun ([],[piname],t,`Identity,`NREQ_true,"expr")
          }
          ;
          add_function priv_name_map "_repr_" n_repr
          ;
          let n_make = !(syms.counter) in incr (syms.counter);
          Hashtbl.add dfns n_make {
            id="_make_"^id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_fun ([],[t],piname,`Identity,`NREQ_true,"expr")
          }
          ;
          add_function priv_name_map ("_make_"^id) n_make
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_abs (quals,c, reqs) ->
          if is_class then clierr sr "Type binding not allowed in class";
          Hashtbl.add dfns n {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_abs (quals,c,reqs)
          }
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_const (props,t,c, reqs) ->
          if is_class then clierr sr "Const binding not allowed in class";
          let t = if t = `TYP_none then `TYP_var n else t in
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_const (props,t,c,reqs)
          }
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_glr (t,(p,e)) ->
          if is_class then clierr sr "GLR parsing not allowed in class";
          let fun_index = n in
          let asms = [`Exe (sr,`EXE_fun_return e)] in
          let pubtab,privtab, exes, ifaces,dirs =
            build_tables syms id dfltvs (level+1)
            (Some fun_index) parent root false asms
          in
          let ips = ref [] in
          iter (fun (name,typ) ->
            match name with
            | None -> ()
            | Some name ->
            let n = !counter in incr counter;
            if print_flag then
            print_endline ("//  "^spc ^ si n ^ " -> " ^ name^ ": "^string_of_typecode (typ:> typecode_t)^" (glr parameter)");
            Hashtbl.add dfns n {
              id=name;sr=sr;parent=Some fun_index;vs=dfltvs;
              pubmap=null_tab;
              privmap=null_tab;dirs=[];
              symdef=`SYMDEF_const ([],`TYP_glr_attr_type typ,
                `Str ("*"^name),`NREQ_true
              )
            };
            (*
            if access = `Public then add_unique pubtab name n;
            add_unique privtab name n;
            *)
            if access = `Public then full_add_unique syms sr dfltvs pubtab name n;
            full_add_unique syms sr dfltvs privtab name n;
            ips := (name,typ) :: !ips
          ) p
          ;

          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=dirs;
            symdef=`SYMDEF_glr (t,(p,exes))}
          ;
          if access = `Public then add_function pub_name_map id n;
          add_function priv_name_map id n
          ;
          add_tvars privtab
          ;


        | `DCL_fun (props, ts,t,c,reqs,prec) ->
          Hashtbl.add dfns n {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_fun (props, ts,t,c,reqs,prec)
          }
          ;
          if access = `Public then add_function pub_name_map id n;
          add_function priv_name_map id n
          ;
          add_tvars privtab

        (* A callback is just like a C function binding .. only it
          actually generates the function. It has a special argument
          the C function has as type void*, but which Felix must
          consider as the type of a closure with the same type
          as the C function, with this void* dropped.
        *)
        | `DCL_callback (props, ts,t,reqs) ->
          Hashtbl.add dfns n {id=id;sr=sr;parent=parent;vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_callback (props, ts,t,reqs)}
          ;
          if access = `Public then add_function pub_name_map id n;
          add_function priv_name_map id n
          ;
          add_tvars privtab

        | `DCL_union (its) ->
          if is_class then clierr sr "Union not allowed in class";
          let tvars = map (fun (s,_,_)-> `AST_name (sr,s,[])) (fst vs) in
          let utype = `AST_name(sr,id, tvars) in
          let its =
            let ccount = ref 0 in (* count component constructors *)
            map (fun (component_name,v,vs,t) ->
              (* ctor sequence in union *)
              let ctor_idx = match v with
                | None ->  !ccount
                | Some i -> ccount := i; i
              in
              incr ccount
              ;
              component_name,ctor_idx,vs,t
            )
            its
          in

          Hashtbl.add dfns n {
            id=id;sr=sr;parent=parent;vs=vs;
            pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=`SYMDEF_union (its)
          }
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;

          let unit_sum =
            fold_left
            (fun v (_,_,_,t) -> v && (match t with `AST_void _ -> true | _ -> false) )
            true
            its
          in
          iter
          (fun (component_name,ctor_idx,vs',t) ->
            let dfn_idx = !counter in incr counter; (* constructor *)
            let match_idx = !counter in incr counter; (* matcher *)

            (* existential type variables *)
            let evs = make_vs vs' in
            add_tvars' (Some dfn_idx) privtab evs;
            let ctor_dcl2 =
              if unit_sum
              then begin
                  if access = `Public then add_unique pub_name_map component_name dfn_idx;
                  add_unique priv_name_map component_name dfn_idx;
                  `SYMDEF_const_ctor (n,utype,ctor_idx,evs)
              end
              else
                match t with
                | `AST_void _ -> (* constant constructor *)
                  if access = `Public then add_unique pub_name_map component_name dfn_idx;
                  add_unique priv_name_map component_name dfn_idx;
                  `SYMDEF_const_ctor (n,utype,ctor_idx,evs)

                | `TYP_tuple ts -> (* non-constant constructor or 2 or more arguments *)
                  if access = `Public then add_function pub_name_map component_name dfn_idx;
                  add_function priv_name_map component_name dfn_idx;
                  `SYMDEF_nonconst_ctor (n,utype,ctor_idx,evs,t)

                | _ -> (* non-constant constructor of 1 argument *)
                  if access = `Public then add_function pub_name_map component_name dfn_idx;
                  add_function priv_name_map component_name dfn_idx;
                  `SYMDEF_nonconst_ctor (n,utype,ctor_idx,evs,t)
            in

            if print_flag then print_endline ("//  " ^ spc ^ si dfn_idx ^ " -> " ^ component_name);
            Hashtbl.add dfns dfn_idx {
              id=component_name;sr=sr;parent=parent;
              vs=vs;
              pubmap=pubtab;
              privmap=privtab;
              dirs=[];
              symdef=ctor_dcl2
            };
          )
          its
          ;
          add_tvars privtab

        | `DCL_cclass (sts) ->
          if is_class then clierr sr "cclass not allowed in class";
          let symdef = `SYMDEF_cclass sts in
          let tvars = map (fun (s,_,_)-> `AST_name (sr,s,[])) (fst vs) in
          let stype = `AST_name(sr,id,tvars) in
          Hashtbl.add dfns n {
            id=id;sr=sr;parent=parent;
            vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=symdef
          }
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          add_tvars privtab
          ;
          let dont_care = 0 in
          handle_class `CClass dont_care sts tvars stype

        | `DCL_cstruct (sts)
        | `DCL_struct (sts) ->
          (*
          print_endline ("Got a struct " ^ id);
          print_endline ("Members=" ^ catmap "; " (fun (id,t)->id ^ ":" ^ string_of_typecode t) sts);
          *)
          if is_class then clierr sr "(c)struct not allowed in class";
          let tvars = map (fun (s,_,_)-> `AST_name (sr,s,[])) (fst vs) in
          let stype = `AST_name(sr,id,tvars) in
          Hashtbl.add dfns n {
            id=id;sr=sr;parent=parent;
            vs=vs;pubmap=pubtab;privmap=privtab;dirs=[];
            symdef=(
              match dcl with
              | `DCL_struct _ -> `SYMDEF_struct (sts)
              | `DCL_cstruct _ -> `SYMDEF_cstruct (sts)
              | _ -> assert false
            )
          }
          ;
          if access = `Public then add_unique pub_name_map id n;
          add_unique priv_name_map id n
          ;
          (*
          (* projections *)
          iter
          (fun (component_name,t) ->
            begin
              let getn = !counter in incr counter;
              let get_name = "get_" ^ component_name in
              let get_dcl = `SYMDEF_fun ([],[stype],t,
                `StrTemplate("$1." ^ component_name),
                `NREQ_true,"primary")
              in
              Hashtbl.add dfns getn {
                id=get_name;sr=sr;parent=parent;vs=vs;
                pubmap=pubtab;privmap=privtab;dirs=[];
                symdef=get_dcl
              };
              if access = `Public then add_function pub_name_map get_name getn;
              add_function priv_name_map get_name getn
              ;
              if print_flag then print_endline ("//  " ^ spc ^ si getn ^ " -> " ^ get_name)
            end
            ;
            (* LVALUE VARIATION *)
            begin
              let getn = !counter in incr counter;
              let get_name = "get_" ^ component_name in
              let get_dcl = `SYMDEF_fun ([],[`TYP_lvalue stype],
                `TYP_lvalue t,
                `StrTemplate ("$1." ^ component_name),
                `NREQ_true,"primary")
              in
              Hashtbl.add dfns getn {
                id=get_name;sr=sr;parent=parent;vs=vs;
                pubmap=pubtab;privmap=privtab;dirs=[];
                symdef=get_dcl
              };
              if access = `Public then add_function pub_name_map get_name getn;
              add_function priv_name_map get_name getn
              ;
              if print_flag then print_endline ("//[lvalue]  " ^ spc ^ si getn ^ " -> " ^ get_name)
            end
            ;

          )
          sts
          ;
          *)
          add_tvars privtab

          (* NOTE: we don't add a type constructor for struct, because
          it would have the same name as the struct type ..
          we just check this case as required
          *)
        end
    )
    dcls
  end
  ;
  pub_name_map,priv_name_map,exes,!interfaces, export_dirs