(****************************************************************************)
(*     Sail                                                                 *)
(*                                                                          *)
(*  Sail and the Sail architecture models here, comprising all files and    *)
(*  directories except the ASL-derived Sail code in the aarch64 directory,  *)
(*  are subject to the BSD two-clause licence below.                        *)
(*                                                                          *)
(*  The ASL derived parts of the ARMv8.3 specification in                   *)
(*  aarch64/no_vector and aarch64/full are copyright ARM Ltd.               *)
(*                                                                          *)
(*  Copyright (c) 2013-2021                                                 *)
(*    Kathyrn Gray                                                          *)
(*    Shaked Flur                                                           *)
(*    Stephen Kell                                                          *)
(*    Gabriel Kerneis                                                       *)
(*    Robert Norton-Wright                                                  *)
(*    Christopher Pulte                                                     *)
(*    Peter Sewell                                                          *)
(*    Alasdair Armstrong                                                    *)
(*    Brian Campbell                                                        *)
(*    Thomas Bauereiss                                                      *)
(*    Anthony Fox                                                           *)
(*    Jon French                                                            *)
(*    Dominic Mulligan                                                      *)
(*    Stephen Kell                                                          *)
(*    Mark Wassell                                                          *)
(*    Alastair Reid (Arm Ltd)                                               *)
(*                                                                          *)
(*  All rights reserved.                                                    *)
(*                                                                          *)
(*  This work was partially supported by EPSRC grant EP/K008528/1 <a        *)
(*  href="http://www.cl.cam.ac.uk/users/pes20/rems">REMS: Rigorous          *)
(*  Engineering for Mainstream Systems</a>, an ARM iCASE award, EPSRC IAA   *)
(*  KTF funding, and donations from Arm.  This project has received         *)
(*  funding from the European Research Council (ERC) under the European     *)
(*  Union’s Horizon 2020 research and innovation programme (grant           *)
(*  agreement No 789108, ELVER).                                            *)
(*                                                                          *)
(*  This software was developed by SRI International and the University of  *)
(*  Cambridge Computer Laboratory (Department of Computer Science and       *)
(*  Technology) under DARPA/AFRL contracts FA8650-18-C-7809 ("CIFV")        *)
(*  and FA8750-10-C-0237 ("CTSRD").                                         *)
(*                                                                          *)
(*  Redistribution and use in source and binary forms, with or without      *)
(*  modification, are permitted provided that the following conditions      *)
(*  are met:                                                                *)
(*  1. Redistributions of source code must retain the above copyright       *)
(*     notice, this list of conditions and the following disclaimer.        *)
(*  2. Redistributions in binary form must reproduce the above copyright    *)
(*     notice, this list of conditions and the following disclaimer in      *)
(*     the documentation and/or other materials provided with the           *)
(*     distribution.                                                        *)
(*                                                                          *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''      *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED       *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A         *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR     *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,            *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT        *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF        *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND     *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,      *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT      *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF      *)
(*  SUCH DAMAGE.                                                            *)
(****************************************************************************)

open Ast
open Ast_defs
open Ast_util
open Rewriter

type node =
  | Register of id
  | Function of id
  | Mapping of id
  | Letbind of id
  | Type of id
  | Overload of id
  | Constructor of id
  | FunctionMeasure of id
  | LoopMeasures of id
  | Outcome of id

let node_id = function
  | Register id -> id
  | Function id -> id
  | Mapping id -> id
  | Letbind id -> id
  | Type id -> id
  | Overload id -> id
  | Constructor id -> id
  | FunctionMeasure id -> id
  | LoopMeasures id -> id
  | Outcome id -> id

let node_kind = function
  | Register _ -> 0
  | Function _ -> 1
  | Mapping _ -> 2
  | Letbind _ -> 3
  | Type _ -> 4
  | Overload _ -> 5
  | Constructor _ -> 6
  | FunctionMeasure _ -> 7
  | LoopMeasures _ -> 8
  | Outcome _ -> 9

module Node = struct
  type t = node
  let compare n1 n2 =
    let lex_ord c1 c2 = if c1 = 0 then c2 else c1 in
    lex_ord (compare (node_kind n1) (node_kind n2)) (Id.compare (node_id n1) (node_id n2))
end

module NodeSet = Set.Make (Node)
module NS = NodeSet
module NodeMap = Map.Make (Node)
module G = Graph.Make (Node)

let builtins =
  let open Type_check in
  IdSet.of_list (List.map fst (Bindings.bindings Env.builtin_typs))

let rec constraint_ids' (NC_aux (aux, _)) =
  match aux with
  | NC_equal (n1, n2)
  | NC_bounded_le (n1, n2)
  | NC_bounded_ge (n1, n2)
  | NC_bounded_lt (n1, n2)
  | NC_bounded_gt (n1, n2)
  | NC_not_equal (n1, n2) ->
      IdSet.union (nexp_ids' n1) (nexp_ids' n2)
  | NC_or (nc1, nc2) | NC_and (nc1, nc2) -> IdSet.union (constraint_ids' nc1) (constraint_ids' nc2)
  | NC_var _ | NC_true | NC_false | NC_set _ -> IdSet.empty
  | NC_id id -> IdSet.singleton id
  | NC_app (id, args) -> IdSet.add id (List.fold_left IdSet.union IdSet.empty (List.map typ_arg_ids' args))

and nexp_ids' (Nexp_aux (aux, _)) =
  match aux with
  | Nexp_id id -> IdSet.singleton id
  | Nexp_app (id, nexps) -> IdSet.add id (List.fold_left IdSet.union IdSet.empty (List.map nexp_ids' nexps))
  | Nexp_var _ | Nexp_constant _ -> IdSet.empty
  | Nexp_exp n | Nexp_neg n -> nexp_ids' n
  | Nexp_times (n1, n2) | Nexp_sum (n1, n2) | Nexp_minus (n1, n2) -> IdSet.union (nexp_ids' n1) (nexp_ids' n2)
  | Nexp_if (i, t, e) -> IdSet.union (constraint_ids' i) (IdSet.union (nexp_ids' t) (nexp_ids' e))

and typ_ids' (Typ_aux (aux, _)) =
  match aux with
  | Typ_var _ | Typ_internal_unknown -> IdSet.empty
  | Typ_id id -> IdSet.singleton id
  | Typ_app (id, args) -> IdSet.add id (List.fold_left IdSet.union IdSet.empty (List.map typ_arg_ids' args))
  | Typ_fn (typs, typ) -> IdSet.union (typ_ids' typ) (List.fold_left IdSet.union IdSet.empty (List.map typ_ids' typs))
  | Typ_bidir (typ1, typ2) -> IdSet.union (typ_ids' typ1) (typ_ids' typ2)
  | Typ_tuple typs -> List.fold_left IdSet.union IdSet.empty (List.map typ_ids' typs)
  | Typ_exist (_, _, typ) -> typ_ids' typ

and typ_arg_ids' (A_aux (aux, _)) =
  match aux with A_typ typ -> typ_ids' typ | A_nexp nexp -> nexp_ids' nexp | A_bool nc -> constraint_ids' nc

let constraint_ids nc = IdSet.diff (constraint_ids' nc) builtins

and typ_ids typ = IdSet.diff (typ_ids' typ) builtins
let typ_arg_ids nc = IdSet.diff (typ_arg_ids' nc) builtins

type callgraph = Graph.Make(Node).graph

let add_def_to_graph graph (DEF_aux (def, def_annot)) =
  let open Type_check in
  let graph = ref graph in

  let scan_pat self p_aux annot =
    begin
      match p_aux with
      | P_app (id, _) -> graph := G.add_edge self (Constructor id) !graph
      | P_typ (typ, _) -> IdSet.iter (fun id -> graph := G.add_edge self (Type id) !graph) (typ_ids typ)
      | _ -> ()
    end;
    P_aux (p_aux, annot)
  in
  let rw_pat self = { id_pat_alg with p_aux = (fun (p_aux, annot) -> scan_pat self p_aux annot) } in

  let scan_lexp self lexp_aux annot =
    let env = env_of_annot annot in
    begin
      match lexp_aux with
      | LE_typ (typ, id) ->
          IdSet.iter (fun id -> graph := G.add_edge self (Type id) !graph) (typ_ids typ);
          begin
            match Env.lookup_id id env with
            | Register _ -> graph := G.add_edge self (Register id) !graph
            | Enum _ -> graph := G.add_edge self (Constructor id) !graph
            | _ -> if IdSet.mem id (Env.get_toplevel_lets env) then graph := G.add_edge self (Letbind id) !graph else ()
          end
      | LE_app (id, _) -> graph := G.add_edge self (Function id) !graph
      | LE_id id -> begin
          match Env.lookup_id id env with
          | Register _ -> graph := G.add_edge self (Register id) !graph
          | Enum _ -> graph := G.add_edge self (Constructor id) !graph
          | _ -> if IdSet.mem id (Env.get_toplevel_lets env) then graph := G.add_edge self (Letbind id) !graph else ()
        end
      | _ -> ()
    end;
    LE_aux (lexp_aux, annot)
  in

  let scan_exp self e_aux annot =
    let env = env_of_annot annot in
    begin
      match e_aux with
      | E_id id -> begin
          match Env.lookup_id id env with
          | Register _ -> graph := G.add_edge self (Register id) !graph
          | Enum _ -> graph := G.add_edge self (Constructor id) !graph
          | _ -> if IdSet.mem id (Env.get_toplevel_lets env) then graph := G.add_edge self (Letbind id) !graph else ()
        end
      | E_app (id, _) ->
          if Env.is_union_constructor id env then graph := G.add_edge self (Constructor id) !graph
          else graph := G.add_edge self (Function id) !graph
      | E_ref id -> graph := G.add_edge self (Register id) !graph
      | E_typ (typ, _) -> IdSet.iter (fun id -> graph := G.add_edge self (Type id) !graph) (typ_ids typ)
      | E_struct _ -> begin
          match typ_of_annot annot with
          | Typ_aux ((Typ_id id | Typ_app (id, _)), _) -> graph := G.add_edge self (Type id) !graph
          | _ -> Reporting.unreachable (fst annot) __POS__ "Struct without struct type"
        end
      | E_lit (L_aux (L_undef, l)) -> begin
          (* Make undefined literals depend on the undefined functions generated for the type (if any)
             to ensure that `rewrite_undefined` works *)
          try
            let typ = Env.expand_synonyms env (typ_of_annot annot) in
            let funcalls_of_exp =
              let e_app (id, args) =
                let arg_funcalls = List.fold_left IdSet.union IdSet.empty args in
                if Bindings.mem id (Env.get_val_specs env) then IdSet.add id arg_funcalls else arg_funcalls
              in
              fold_exp { (pure_exp_alg IdSet.empty IdSet.union) with e_app }
            in
            (* The `mwords` parameter of `undefined_of_type` shouldn't change the set of functions called,
               so just pass `true`. *)
            funcalls_of_exp (undefined_of_typ true l (fun _ -> empty_uannot) typ)
            |> IdSet.iter (fun f -> graph := G.add_edge self (Function f) !graph)
          with _ -> ()
        end
      | _ -> ()
    end;
    E_aux (e_aux, annot)
  in
  let rw_exp self =
    {
      id_exp_alg with
      e_aux = (fun (e_aux, annot) -> scan_exp self e_aux annot);
      le_aux = (fun (l_aux, annot) -> scan_lexp self l_aux annot);
      pat_alg = rw_pat self;
    }
  in

  let rewriters self =
    {
      rewriters_base with
      rewrite_exp = (fun _ -> fold_exp (rw_exp self));
      rewrite_pat = (fun _ -> fold_pat (rw_pat self));
      rewrite_let = (fun _ -> fold_letbind (rw_exp self));
    }
  in

  let scan_quant_item self (QI_aux (aux, _)) =
    match aux with
    | QI_id _ -> ()
    | QI_constraint nc -> IdSet.iter (fun id -> graph := G.add_edge self (Type id) !graph) (constraint_ids nc)
  in

  let scan_typquant self (TypQ_aux (aux, _)) =
    match aux with TypQ_no_forall -> () | TypQ_tq quants -> List.iter (scan_quant_item self) quants
  in

  let scan_loop_measure self (Loop (_, exp)) = ignore (fold_exp (rw_exp self) exp) in

  let add_type_def_to_graph (TD_aux (aux, (l, _))) =
    match aux with
    | TD_abbrev (id, typq, arg) ->
        graph := G.add_edges (Type id) (List.map (fun id -> Type id) (IdSet.elements (typ_arg_ids arg))) !graph;
        scan_typquant (Type id) typq
    | TD_record (id, typq, fields, _) ->
        let field_nodes =
          List.map (fun (typ, _) -> typ_ids typ) fields
          |> List.fold_left IdSet.union IdSet.empty |> IdSet.elements
          |> List.map (fun id -> Type id)
        in
        graph := G.add_edges (Type id) field_nodes !graph;
        scan_typquant (Type id) typq
    | TD_variant (id, typq, ctors, _) ->
        let ctor_nodes =
          List.map (fun (Tu_aux (Tu_ty_id (typ, ctor_id), _)) -> (typ_ids typ |> IdSet.remove id, ctor_id)) ctors
          |> List.fold_left
               (fun (ids, ctors) (ids', ctor) -> (IdSet.union ids ids', IdSet.add ctor ctors))
               (IdSet.empty, IdSet.empty)
        in
        IdSet.iter (fun ctor_id -> graph := G.add_edge (Constructor ctor_id) (Type id) !graph) (snd ctor_nodes);
        IdSet.iter (fun typ_id -> graph := G.add_edge (Type id) (Type typ_id) !graph) (fst ctor_nodes);
        scan_typquant (Type id) typq
    | TD_enum (id, ctors, _) ->
        List.iter (fun ctor_id -> graph := G.add_edge (Constructor ctor_id) (Type id) !graph) ctors
    | TD_abstract (id, _) -> graph := G.add_edges (Type id) [] !graph
    | TD_bitfield (id, typ, ranges) ->
        graph := G.add_edges (Type id) (List.map (fun id -> Type id) (IdSet.elements (typ_ids typ))) !graph
  in

  let scan_outcome_def l outcome (DEF_aux (aux, _)) =
    match aux with
    | DEF_val (VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (typq, typ), _), _, _), _)) ->
        graph := G.add_edges outcome [] !graph;
        scan_typquant outcome typq;
        IdSet.iter (fun typ_id -> graph := G.add_edge outcome (Type typ_id) !graph) (typ_ids typ)
    | DEF_impl (FCL_aux (FCL_funcl (_, pexp), _)) -> ignore (rewrite_pexp (rewriters outcome) pexp)
    | _ -> Reporting.unreachable l __POS__ "Unexpected definition in outcome block"
  in

  let scan_fundef_tannot self (FD_aux (FD_function (_, Typ_annot_opt_aux (tannotopt, _), _), _)) =
    match tannotopt with
    | Typ_annot_opt_none -> ()
    | Typ_annot_opt_some (typq, typ) ->
        scan_typquant self typq;
        IdSet.iter (fun typ_id -> graph := G.add_edge self (Type typ_id) !graph) (typ_ids typ)
  in

  begin
    match def with
    | DEF_val (VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (typq, (Typ_aux (Typ_bidir _, _) as typ)), _), id, _), _))
      ->
        graph := G.add_edges (Mapping id) [] !graph;
        List.iter
          (fun gen_id -> graph := G.add_edges (Function gen_id) [Mapping id] !graph)
          [
            append_id id "_forwards";
            append_id id "_forwards_matches";
            append_id id "_backwards";
            append_id id "_backwards_matches";
          ];
        scan_typquant (Mapping id) typq;
        IdSet.iter (fun typ_id -> graph := G.add_edge (Mapping id) (Type typ_id) !graph) (typ_ids typ)
    | DEF_val (VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (typq, typ), _), id, _), _)) ->
        graph := G.add_edges (Function id) [] !graph;
        scan_typquant (Function id) typq;
        IdSet.iter (fun typ_id -> graph := G.add_edge (Function id) (Type typ_id) !graph) (typ_ids typ)
    | DEF_fundef fdef ->
        let id = id_of_fundef fdef in
        graph := G.add_edges (Function id) [] !graph;
        scan_fundef_tannot (Function id) fdef;
        ignore (rewrite_fun (rewriters (Function id)) fdef)
    | DEF_mapdef mdef ->
        let id = id_of_mapdef mdef in
        graph := G.add_edges (Mapping id) [] !graph;
        ignore (rewrite_mapdef (rewriters (Mapping id)) mdef)
    | DEF_let (LB_aux (LB_val (pat, exp), _) as lb) ->
        let ids = pat_ids pat in
        IdSet.iter (fun id -> graph := G.add_edges (Letbind id) [] !graph) ids;
        IdSet.iter (fun id -> ignore (rewrite_let (rewriters (Letbind id)) lb)) ids
    | DEF_type tdef -> add_type_def_to_graph tdef
    | DEF_register (DEC_aux (DEC_reg (typ, id, opt_exp), annot)) ->
        (* Determine dependencies of initial expressions (or `undefined` if missing, which will add
           dependencies to `undefined_*` functions) *)
        let exp = match opt_exp with Some exp -> exp | None -> E_aux (E_lit (mk_lit L_undef), annot) in
        ignore (fold_exp (rw_exp (Register id)) exp);
        IdSet.iter (fun typ_id -> graph := G.add_edge (Register id) (Type typ_id) !graph) (typ_ids typ)
    | DEF_measure (id, pat, exp) ->
        graph := G.add_edges (FunctionMeasure id) [Function id] !graph;
        ignore (fold_pat (rw_pat (FunctionMeasure id)) pat);
        ignore (fold_exp (rw_exp (FunctionMeasure id)) exp)
    | DEF_loop_measures (id, measures) ->
        graph := G.add_edges (LoopMeasures id) [Function id] !graph;
        List.iter (scan_loop_measure (LoopMeasures id)) measures
    | DEF_outcome (OV_aux (OV_outcome (id, TypSchm_aux (TypSchm_ts (typq, typ), _), _), l), outcome_defs) ->
        graph := G.add_edges (Outcome id) [] !graph;
        scan_typquant (Outcome id) typq;
        IdSet.iter (fun typ_id -> graph := G.add_edge (Outcome id) (Type typ_id) !graph) (typ_ids typ);
        List.iter (scan_outcome_def l (Outcome id)) outcome_defs;
        (* Remove dependencies on functions declared within the outcome;  these are parameters of the outcome,
           and instantiations of these functions (possibly with a more constrained, architecture-specific type)
           and an `instantiation` declaration normally come later *)
        IdSet.iter (fun f -> graph := G.delete_edge (Outcome id) (Function f) !graph) (val_spec_ids outcome_defs)
    | DEF_instantiation (IN_aux (IN_id id, _), substs) ->
        graph := G.add_edges (Function id) [Outcome id] !graph;
        List.iter
          (function
            | IS_aux (IS_id (_, id_to), _) -> graph := G.add_edges (Function id) [Function id_to] !graph
            | IS_aux (IS_typ (_, typ), _) ->
                IdSet.iter (fun typ_id -> graph := G.add_edge (Function id) (Type typ_id) !graph) (typ_ids typ)
            )
          substs
    | DEF_scattered (SD_aux (sdef, _)) -> begin
        match sdef with
        | SD_funcl (FCL_aux (FCL_funcl (id, pexp), _)) -> ignore (rewrite_pexp (rewriters (Function id)) pexp)
        | _ -> ()
      end
    | DEF_overload (id, ids) ->
        List.iter
          (fun id' ->
            let n = if Env.is_union_constructor id' def_annot.env then Constructor id' else Function id' in
            graph := G.add_edge (Overload id) n !graph
          )
          ids
    | _ -> ()
  end;
  !graph

let rec graph_of_defs defs =
  match defs with
  | def :: defs ->
      let g = graph_of_defs defs in
      add_def_to_graph g def
  | [] -> G.empty

let graph_of_ast ast = graph_of_defs ast.defs

let id_of_reg_dec (DEC_aux (DEC_reg (_, id, _), _)) = id

let id_of_funcl (FCL_aux (FCL_funcl (id, _), _)) = id

let nodes_of_def (DEF_aux (def, _)) =
  match def with
  | DEF_fundef fundef -> NS.singleton (Function (id_of_fundef fundef))
  | DEF_val (VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (_, Typ_aux (Typ_bidir _, _)), _), id, _), _)) ->
      NS.of_list
        [
          Function (append_id id "_forwards");
          Function (append_id id "_forwards_matches");
          Function (append_id id "_backwards");
          Function (append_id id "_backwards_matches");
          Mapping id;
        ]
  | DEF_val vs -> NS.singleton (Function (id_of_val_spec vs))
  | DEF_scattered (SD_aux (SD_funcl funcl, _)) -> NS.singleton (Function (id_of_funcl funcl))
  | DEF_mapdef mdef -> NS.singleton (Mapping (id_of_mapdef mdef))
  | DEF_measure (id, _, _) -> NS.singleton (FunctionMeasure id)
  | DEF_loop_measures (id, _) -> NS.singleton (LoopMeasures id)
  | DEF_register rdec -> NS.singleton (Register (id_of_reg_dec rdec))
  | DEF_let (LB_aux (LB_val (pat, _), _)) ->
      pat_ids pat |> IdSet.elements |> List.map (fun id -> Letbind id) |> NS.of_list
  | DEF_type tdef -> NS.singleton (Type (id_of_type_def tdef))
  | DEF_outcome (OV_aux (OV_outcome (id, _, _), _), _) -> NS.singleton (Outcome id)
  | DEF_instantiation (IN_aux (IN_id id, _), _) -> NS.singleton (Function id)
  | DEF_overload (id, _) -> NS.singleton (Overload id)
  | _ -> NS.empty

let filter_ast_extra cuts g ast keep_std =
  let rec filter_ast' g =
    let module NM = Map.Make (Node) in
    let defines_nodes def = not (NS.is_empty (nodes_of_def def)) in
    let in_graph def = NS.exists (fun n -> NM.mem n g) (nodes_of_def def) in
    let is_cut def = NS.subset (nodes_of_def def) cuts in
    function
    | DEF_aux (DEF_overload (id, overloads), def_annot) :: defs -> begin
        let keep_overload overload =
          (NM.mem (Function overload) g || NM.mem (Constructor overload) g || NM.mem (Overload overload) g)
          && not
               (NS.mem (Function overload) cuts || NS.mem (Constructor overload) cuts || NS.mem (Overload overload) cuts)
        in
        let filtered = List.filter keep_overload overloads in
        match filtered with
        | [] -> filter_ast' g defs
        | _ -> DEF_aux (DEF_overload (id, filtered), def_annot) :: filter_ast' g defs
      end
    | DEF_aux (DEF_val vs, def_annot) :: defs when NM.mem (Function (id_of_val_spec vs)) g ->
        DEF_aux (DEF_val vs, def_annot) :: filter_ast' g defs
    | DEF_aux (DEF_val _, _) :: defs -> filter_ast' g defs
    | DEF_aux (DEF_measure (id, _, _), _) :: defs when NS.mem (Function id) cuts -> filter_ast' g defs
    | (DEF_aux (DEF_measure (id, _, _), _) as def) :: defs when NM.mem (Function id) g -> def :: filter_ast' g defs
    | DEF_aux (DEF_measure _, _) :: defs -> filter_ast' g defs
    | (DEF_aux (DEF_pragma ("include_start", file_name, _), _) as def) :: defs when keep_std ->
        (* TODO: proper check *)
        let d = Filename.dirname file_name in
        if Filename.basename d = "lib" && Filename.basename (Filename.dirname d) = "sail" then (
          let rec in_file = function
            | [] -> []
            | (DEF_aux (DEF_pragma ("include_end", file_name', _), _) as def) :: defs when file_name = file_name' ->
                def :: filter_ast' g defs
            | def :: defs -> def :: in_file defs
          in
          def :: in_file defs
        )
        else def :: filter_ast' g defs
    | def :: defs when defines_nodes def ->
        if in_graph def && not (is_cut def) then def :: filter_ast' g defs else filter_ast' g defs
    | def :: defs -> def :: filter_ast' g defs
    | [] -> []
  in
  { ast with defs = filter_ast' g ast.defs }

let filter_ast cuts g ast = filter_ast_extra cuts g ast false

let filter_ast_ids roots cuts ast =
  let g = graph_of_ast ast in
  let roots = roots |> IdSet.elements |> List.map (fun id -> Function id) |> NS.of_list in
  let cuts = cuts |> IdSet.elements |> List.map (fun id -> Function id) |> NS.of_list in
  let g = G.prune roots cuts g in
  filter_ast cuts g ast

let top_sort_defs ast =
  let module NM = Map.Make (Node) in
  (* Build callgraph, and collect definitions per node, so that we can efficiently reorder later *)
  let g = graph_of_ast ast in
  let defs_of_nodes =
    let add defs d =
      let update_node defs n = NM.update n (function Some ds -> Some (d :: ds) | None -> Some [d]) defs in
      List.fold_left update_node defs (NS.elements (nodes_of_def d))
    in
    List.fold_left add NM.empty ast.defs
  in
  (* Determine the original order of callgraph nodes for the stable sort.
     We have to be careful about forward declarations of functions,
     i.e. val specs of functions that are defined later.
     We want the reordering to push those down towards the definitions,
     rather than pulling the definitions up along with their dependencies.
     Hence, we only consider the definitions for the original order, not the specs.
     When rebuilding the AST using `defs_of_nodes`, the specs will be placed right
     before their corresponding function definitions. *)
  let fun_id_of_def = function DEF_aux (DEF_fundef fd, _) -> Some (id_of_fundef fd) | _ -> None in
  let defined_funs = List.filter_map fun_id_of_def ast.defs |> IdSet.of_list in
  let is_defined_val_spec = function
    | DEF_aux (DEF_val vs, _) when IdSet.mem (id_of_val_spec vs) defined_funs -> true
    | _ -> false
  in
  let defs = List.filter (fun d -> not (is_defined_val_spec d)) ast.defs in
  let original_order = List.map nodes_of_def defs |> List.map NS.elements |> List.concat in
  (* Topologically sort the callgraph *)
  let components = G.scc ~original_order g |> List.map NS.of_list in
  (* Stable reordering of definitions, keeping in place definitions that don't
     belong to a component, e.g. comments or pragmas *)
  let rec reorder already_seen acc = function
    | components, d :: defs when NS.is_empty (nodes_of_def d) -> reorder already_seen (d :: acc) (components, defs)
    | components, d :: defs when NS.subset (nodes_of_def d) already_seen -> reorder already_seen acc (components, defs)
    | c :: components, defs when NS.subset c already_seen -> reorder already_seen acc (components, defs)
    | c :: components, defs ->
        (* Look up the definitions for the nodes in the strongly connected component.
           Q: Do we need to deduplicate them, e.g. could we end up including a let-binding of
              multiple variables more than once?
           A: The nodes of a multi-variable let-binding *should* not depend on each other, so
              should not be part of the same component, so the code below should work. *)
        let cdefs = NS.elements c |> List.filter_map (fun n -> NM.find_opt n defs_of_nodes) |> List.concat in
        let already_seen' = List.fold_left NS.union already_seen (List.map nodes_of_def cdefs) in
        (* Merge mutually recursive functions *)
        let cdefs' =
          let get_fundefs = function
            | DEF_aux (DEF_fundef fundef, _) -> [fundef]
            | DEF_aux (DEF_internal_mutrec fundefs, _) -> fundefs
            | _ -> []
          in
          let fundefs = List.map get_fundefs cdefs |> List.concat in
          let other_defs = List.filter (fun d -> get_fundefs d = []) cdefs in
          if List.length fundefs > 1 then (
            let env = Util.last cdefs |> function DEF_aux (_, da) -> da.env in
            (* Mutrec definition, then others (including val-specs); will be reversed later *)
            mk_def (DEF_internal_mutrec fundefs) env :: other_defs
          )
          else cdefs
        in
        reorder already_seen' (cdefs' @ acc) (components, defs)
    | [], defs -> List.rev_append acc defs
  in
  { ast with defs = reorder NS.empty [] (components, defs) }
