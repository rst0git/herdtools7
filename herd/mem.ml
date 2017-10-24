(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2010-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(** Produce event structures (which include variables) + constraints,
   using instruction semantics *)

module type Config = sig
  val verbose : int
  val optace : bool
  val unroll : int
  val speedcheck : Speed.t
  val debug : Debug_herd.t
  val observed_finals_only : bool
  val initwrites : bool
  val check_filter : bool
end

module type S = sig

  module S : Sem.Semantics


  type result =
     {
      event_structures : (int * S.M.VC.cnstrnts * S.event_structure) list ;
      too_far : bool ; (* some events structures discarded (loop) *)
     }

  val glommed_event_structures : S.test -> result



(* A first generator,
   calculate_rf_with_cnstrnts test es constraints kont kont_loop res,

   - test and es are test description and (abstract) event structure.
     By abstract, we here mean that some values and even
     memory locations in them are variables.

   - constraints is a set of constraint, which
     * Is solvable: ie resolution results
       in either an assigment of all variables in es, or
       in failure.
     * expresses the constraints generated by semantics.

   - kont : S.concrete -> 'a  -> 'a
     will be called on all generated concrete event structures, resulting
     in  computation:
     kont (esN (... (kont es1 res)))
     where esK is the
        + abstract es with variables replaced by constants
        + rfmap
        + final state (included in rfmap in fact)

   Additionnaly, the function detects loops (in fact
   two many passages by the same label).
   In such a case, kont_loop is called and not kont.

 *)


  val calculate_rf_with_cnstrnts :
      S.test -> S.event_structure -> S.M.VC.cnstrnts ->
        (S.concrete -> 'a -> 'a ) -> (* kont *)
        ('a -> 'a) ->                (* kont_loop *)
            'a -> 'a
end

open Printf

module Make(C:Config) (S:Sem.Semantics) : S with module S = S	=
  struct
    module S = S

    module A = S.A
    module V = A.V
    module E = S.E
    module EM = S.M
    module VC = EM.VC
    module U = MemUtils.Make(S)
    module W = Warn.Make(C)


(*****************************)
(* Event structure generator *)
(*****************************)

(* Relabeling (eiid) events so as to get memory events labeled by 0,1, etc *)
    module IMap =
      Map.Make
        (struct
          type t = E.eiid
          let compare = Misc.int_compare
        end)

    let count_mem evts =
      E.EventSet.fold
        (fun e k ->
          if E.is_mem e then k+1
          else k)
        evts 0

    let build_map n_mem evts =
      let build_bd e (next_mem,next_other,k) =
        let key = e.E.eiid in
        if E.is_mem e then
          (next_mem+1,next_other,IMap.add key next_mem k)
        else
          (next_mem,next_other+1,IMap.add key next_other k) in
      let _,_,r = E.EventSet.fold build_bd evts (0,n_mem,IMap.empty) in
      r


    let relabel es =
      let n_mem = count_mem es.E.events in
      let map = build_map n_mem es.E.events in
      let relabel_event e =
        try { e with E.eiid = IMap.find e.E.eiid map }
        with Not_found -> assert false in
      E.map_event_structure relabel_event es

    let (|*|) = EM.(|*|)
    let (>>>) = EM.(>>>)



    module Imap =
      Map.Make
        (struct type t = string let compare = String.compare end)

    let is_back_jump addr_jmp tgt = match tgt with
    | [] -> false
    | (addr_tgt,_)::_ -> Misc.int_compare addr_jmp addr_tgt >= 0

    type result =
        {
         event_structures : (int * S.M.VC.cnstrnts * S.event_structure) list ;
         too_far : bool ; (* some events structures discarded (loop) *)
        }

(* All locations from init state, a bit contrieved *)
    let get_all_locs_init init =
      let locs =
        List.fold_left
          (fun locs (loc,v) ->
            let locs =
              match loc with
              | A.Location_global _|A.Location_deref _ -> loc::locs
              | A.Location_reg _ -> locs in
            let locs = match v with
            | A.V.Val (Constant.Symbolic _) -> A.Location_global v::locs
            | _ -> locs in
            locs)
          [] (A.state_to_list init) in
      A.LocSet.of_list locs

    let get_all_mem_locs test =
      let locs_final =
        A.LocSet.filter
          (function
            | A.Location_global _|A.Location_deref _ -> true
            | A.Location_reg _ -> false)
          test.Test_herd.observed
      and locs_init = get_all_locs_init test.Test_herd.init_state in
      let locs = A.LocSet.union locs_final locs_init in
      let locs =
        List.fold_left
          (fun locs (_,code) ->
            List.fold_left
              (fun locs (_,ins) ->
                A.fold_addrs
                  (fun x ->
                    let loc = A.maybev_to_location x in
                    A.LocSet.add loc)
                  locs ins)
              locs code)
          locs
          test.Test_herd.start_points in
      let env =
        A.LocSet.fold
          (fun loc env ->
            try
              let v = A.look_in_state test.Test_herd.init_state loc in
              (loc,v)::env
            with A.LocUndetermined -> assert false)
          locs [] in
      env

    let glommed_event_structures (test:S.test) =
      let p = test.Test_herd.program in
      let starts = test.Test_herd.start_points in
      let procs = List.map fst starts in
      let tooFar = ref false in

      let module ValMap = MyMap.Make
       (struct
        type t = int
        let compare = Pervasives.compare
       end) in

      let instr2labels =
        let one_label lbl code res = match code with
          | [] -> res (* Luc, it is legal to have nothing after label *)
(*            assert false (*jade: case where there's nothing after the label*) *)
          | (addr,_)::_ ->
              let ins_lbls = ValMap.safe_find Label.Set.empty addr res in
              ValMap.add addr (Label.Set.add lbl ins_lbls) res in
        A.LabelMap.fold one_label p ValMap.empty in

      let labels_of_instr i = ValMap.safe_find Label.Set.empty i instr2labels in


      let see seen lbl =
        let x = try Imap.find lbl seen with Not_found -> 0 in
        let seen = Imap.add lbl (x+1) seen in
        x+1,seen in

      let fetch_code seen addr_jmp lbl =
        let tgt =
          try A.LabelMap.find lbl p
          with Not_found ->
            Warn.user_error
              "Segmentation fault (kidding, label %s not found)" lbl in
        if is_back_jump addr_jmp tgt then
          let x,seen = see seen lbl in
          if x > C.unroll then begin
            W.warn "loop unrolling limit reached: %s" lbl;
            None
          end else
            Some (tgt,seen)
        else
          Some (tgt,seen) in


      let rec add_next_instr proc prog_order seen addr inst nexts =
        let ii =
          { A.program_order_index = prog_order;
            proc = proc; inst = inst; unroll_count = 0;
            labels = labels_of_instr addr; }
        in
        S.build_semantics ii >>> fun (prog_order, branch) ->
          next_instr proc prog_order seen addr nexts branch

      and add_code proc prog_order seen nexts = match nexts with
      | [] -> EM.unitT ()
      | (addr,inst)::nexts ->
          add_next_instr proc prog_order seen addr inst nexts

      and add_lbl proc prog_order seen addr_jmp lbl =
        match fetch_code seen addr_jmp lbl with
        | None -> tooFar := true ; EM.tooFar lbl
        | Some (code,seen) -> add_code proc prog_order seen code

      and next_instr proc prog_order seen addr nexts b = match b with
      | S.B.Next -> add_code proc prog_order seen nexts
      | S.B.Jump lbl ->
          add_lbl proc prog_order seen addr lbl
      | S.B.CondJump (v,lbl) ->
          EM.choiceT v
            (add_lbl proc prog_order seen addr lbl)
            (add_code proc prog_order seen nexts) in

      let jump_start proc code =
        add_code proc  A.zero_po_index Imap.empty code in

      let add_events_for_a_processor (proc,code) evts =
        let evts_proc = jump_start proc code in
        evts_proc |*| evts in

      let add_inits env =
        if C.initwrites then  EM.initwrites env
        else EM.zeroT in

      let set_of_all_instr_events =
        List.fold_right
          add_events_for_a_processor
          starts
          (add_inits (get_all_mem_locs test)) in

      let rec index xs i = match xs with
      | [] ->
          W.warn "%i abstract event structures\n%!" i ;
          []
      | (vcl,es)::xs ->
          let es = { (relabel es) with E.procs = procs } in
          (i,vcl,es)::index xs (i+1) in
      let r = EM.get_output set_of_all_instr_events  in
      { event_structures=index r 0; too_far = !tooFar; }


(*******************)
(* Rfmap generator *)
(*******************)


(* Step 1. make rfmap for registers and reservations *)


let get_loc e = match E.location_of e with
| Some loc -> loc
| None -> assert false

and get_read e = match E.read_of e  with
| Some v -> v
| None -> assert false

and get_written e = match E.written_of e with
| Some v -> v
| None -> assert false




(* Add final edges in rfm, ie for all location,
   find the last (po) store to it *)

let add_finals es =
    U.LocEnv.fold
      (fun loc stores k -> match stores with
      | [] -> k
      | ew::stores ->
          let last =
            List.fold_right
              (fun ew0 _k ->
                if U.is_before_strict es ew0 ew then ew
                else begin
                  assert (U.is_before_strict es ew0 ew) ;
                  ew0
                end)
              stores ew in
          S.RFMap.add (S.Final loc) (S.Store last) k)

(*******************************)
(* Compute rfmap for registers *)
(*******************************)

let map_loc_find loc m =
  try U.LocEnv.find loc m
  with Not_found -> []

let match_reg_events es =
  let loc_loads = U.collect_reg_loads es
  and loc_stores = U.collect_reg_stores es in

(* For all loads find the right store, the one "just before" the load *)
  let rfm =
    U.LocEnv.fold
      (fun loc loads k ->
        let stores = map_loc_find loc loc_stores in
        List.fold_right
          (fun er k ->
            let rf =
              List.fold_left
                (fun rf ew ->
                  if U.is_before_strict es ew er then
                    match rf with
                    | S.Init -> S.Store ew
                    | S.Store ew0 ->
                        if U.is_before_strict es ew0 ew then
                          S.Store ew
                        else begin
                          (* store order is total *)
                          assert (U.is_before_strict es ew ew0) ;
                          rf
                        end
                  else rf)
                S.Init stores in
            S.RFMap.add (S.Load er) rf k)
          loads k)
      loc_loads S.RFMap.empty in
(* Complete with stores to final state *)
  add_finals es loc_stores rfm



let get_rf_value test read rf = match rf with
| S.Init ->
    let loc = get_loc read in
    begin try A.look_in_state test.Test_herd.init_state loc
    with A.LocUndetermined -> assert false end
| S.Store e -> get_written e

(* Add a constraint for two values *)

(* More like an optimization, adding constraint v1 := v2 should work *)

exception Contradiction

let add_eq v1 v2 eqs =
  if V.is_var_determined v1 then
    if V.is_var_determined v2 then
      if V.compare v1 v2 = 0 then
        eqs
      else
        raise Contradiction
    else
      VC.Assign (v2, VC.Atom v1)::eqs
  else
    VC.Assign (v1, VC.Atom v2)::eqs

let solve_regs test es csn =
  let rfm = match_reg_events es in
  let csn =
    S.RFMap.fold
      (fun wt rf csn -> match wt with
      | S.Final _ -> csn
      | S.Load load ->
          let v_loaded = get_read load in
          let v_stored = get_rf_value test load rf in
          try add_eq v_loaded v_stored csn
          with Contradiction -> assert false)
      rfm csn in
  match VC.solve csn with
  | VC.NoSolns ->
      if C.debug.Debug_herd.solver then begin
          let module PP = Pretty.Make(S) in
          prerr_endline "No solution at register level";
          PP.show_es_rfm test es rfm ;
      end ;
    None
  | VC.Maybe (sol,csn) ->
      Some
        (E.simplify_vars_in_event_structure sol es,
         S.simplify_vars_in_rfmap sol rfm,
         csn)

(**************************************)
(* Step 2. Generate rfmap for memory  *)
(**************************************)

let get_loc_as_value e = match  E.global_loc_of e with
  | None -> eprintf "%a\n" E.debug_event e ; assert false
  | Some v -> v

(* Compatible location are:
   - either both determined and equal,
   - or at least one location is undetermined. *)
let compatible_locs_mem e1 e2 =
  E.event_compare e1 e2 <> 0 && (* C RMWs cannot feed themselves *)
  begin
    let loc1 = get_loc e1
    and loc2 = get_loc e2 in
    let ov1 =  A.undetermined_vars_in_loc loc1
    and ov2 =  A.undetermined_vars_in_loc loc2 in
    match ov1,ov2 with
    | None,None -> E.same_location e1 e2
    | (Some _,None)|(None,Some _)
    | (Some _,Some _) -> true
  end

(* Add a constraint for a store/load match *)
    let add_mem_eqs test rf load eqs =
      let v_loaded = get_read load in
      match rf with
      | S.Init -> (* Tricky, if location (of load) is
                     not know yet, emit a specific constraint *)
          let state = test.Test_herd.init_state
          and loc_load = get_loc load in
          begin try
            let v_stored = A.look_in_state state loc_load in
            add_eq v_stored  v_loaded eqs
          with A.LocUndetermined ->
            VC.Assign
              (v_loaded, VC.ReadInit (loc_load,state))::eqs
          end
      | S.Store store ->
          add_eq v_loaded (get_written store)
            (add_eq
               (get_loc_as_value store)
               (get_loc_as_value load) eqs)

(* Our rather loose rfmaps can induce a cycle in
   causality. Check this. *)
    let rfmap_is_cyclic es rfm =
      let both =
        E.EventRel.union
          es.E.intra_causality_data
          es.E.intra_causality_control in
      let causality =
        S.RFMap.fold
          (fun load store k -> match load,store with
          | S.Load er,S.Store ew -> E.EventRel.add (ew,er) k
          | _,_ -> k)
          rfm both in
      match E.EventRel.get_cycle causality with
      | None -> prerr_endline "no cycle"; false
      | Some cy ->
          if C.debug.Debug_herd.rfm then begin
            let debug_event chan e = Printf.fprintf chan "%i" e.E.eiid in
            eprintf "cycle = %a\n" debug_event
              (match cy with e::_ -> e | [] -> assert false)
          end; true

(* solve_mem proper *)


(* refrain from being subtle: match a load with all compatible
   stores, and there may be many *)

(* First consider loads from init, in the initwrite case
   nothing to consider, as the initial stores should present
   as events *)
    let init = if C.initwrites then [] else [S.Init]
    let map_load_init loads =
      E.EventSet.fold
        (fun load k -> (load,init)::k)
        loads []

(* Consider all stores that may feed a load
   - Compatible location.
   - Not after in program order (suppressed when uniproc
     is not optmised early) *)
    let map_load_possible_stores es loads stores compat_locs =
      E.EventSet.fold
        (fun store map_load ->
          List.map
            (fun ((load,stores) as c) ->
              if
                compat_locs store load &&
                (if C.optace then
                  not (U.is_before_strict es load store)
                else true)
              then
                load,S.Store store::stores
              else c)
            map_load)
        stores (map_load_init loads)

(* Add memory events to rfmap *)
    let add_mem loads stores rfm =
      List.fold_right2
        (fun er -> S.RFMap.add (S.Load er))
        loads stores rfm



    let solve_mem_or_res test es rfm cns kont res loads stores compat_locs add_eqs =
      let loads,possible_stores =
        List.split (map_load_possible_stores es loads stores compat_locs) in
      (* Cross product fold. Probably an overkill here *)
      Misc.fold_cross possible_stores
        (fun stores res ->
          (* stores is a list of stores that may match the loads list.
             Both lists in same order [by List.split above]. *)
          try
            (* Add constraints now *)
            let cns =
              List.fold_right2
                (fun load rf -> add_eqs test rf load)
                loads stores cns in
            (* And solve *)
            match VC.solve cns with
            | VC.NoSolns -> res
            | VC.Maybe (sol,cs) ->
                (* Time to complete rfmap *)
                let rfm = add_mem loads stores rfm in
                (* And to make everything concrete *)
                let es = E.simplify_vars_in_event_structure sol es
                and rfm = S.simplify_vars_in_rfmap sol rfm in
                kont es rfm cs res
          with Contradiction -> res  (* can be raised by add_mem_eqs *)
          | e ->
              let rfm = add_mem loads stores rfm in
              let module PP = Pretty.Make(S) in
              prerr_endline "Exception" ;
              PP.show_es_rfm test es rfm ;
              raise e
        )
        res


    let when_unsolved test es rfm cs kont_loop res =
      (* This system in fact has no solution.
         In other words, it is not possible to make
         such event structures concrete.
         This occurs with cyclic rfmaps,
         or not enough unrolled loops -- hack *)
      let unroll_only =
        List.for_all
          (fun cn -> match cn with
          | VC.Unroll lbl ->
              Warn.warn_always
                "unrolling too deep at label: %s" lbl;
              true
          | VC.Assign _ -> false)
          cs in
      if unroll_only then
        kont_loop res
      else begin
        if C.debug.Debug_herd.solver then begin
          let module PP = Pretty.Make(S) in
          prerr_endline "Unsolvable system" ;
          PP.show_es_rfm test es rfm ;
        end ;
        assert (rfmap_is_cyclic es rfm);
        res
      end


    let solve_mem test es rfm cns kont res =
      let loads =  E.EventSet.filter E.is_mem_load es.E.events
      and stores = E.EventSet.filter E.is_mem_store es.E.events in
(*
      eprintf "Loads : %a\n"E.debug_events loads ;
      eprintf "Stores: %a\n"E.debug_events stores ;
*)
      let compat_locs = compatible_locs_mem in
      solve_mem_or_res test es rfm cns kont res
          loads stores compat_locs add_mem_eqs

(*************************************)
(* Final condition invalidation mode *)
(*************************************)

(* Internal filter *)
    let check_filter test fsc = match test.Test_herd.filter with
    | None -> true
    | Some p -> not C.check_filter || S.Cons.check_prop p fsc
(*
  A little optimisation: we check whether the existence/non-existence
  of some vo would help in validation/invalidating the constraint
  of the test.

  If no, not need to go on
*)

    let worth_going test fsc = match C.speedcheck with
    | Speed.True|Speed.Fast ->
        U.final_is_relevant test fsc
    | Speed.False -> true


(***************************)
(* Rfmap full exploitation *)
(***************************)

(* final state *)
    let compute_final_state test rfm =
      S.RFMap.fold
        (fun wt rf k -> match wt,rf with
        | S.Final loc,S.Store ew ->
            A.state_add k loc (get_written ew)
        | _,_ -> k)
        rfm test.Test_herd.init_state


(* View before relations easily available, from po_iico and rfmap *)


(* Preserved Program Order, per memory location - same processor *)
    let make_ppoloc po_iico_data es =
      let mem_evts = E.mem_of es in
      E.EventRel.of_pred mem_evts mem_evts
        (fun e1 e2 ->
          E.same_location e1 e2 &&
          E.EventRel.mem (e1,e2) po_iico_data)

(* Store is before rfm load successor *)
    let store_load rfm =
      S.RFMap.fold
        (fun wt rf k -> match wt,rf with
        | S.Load er,S.Store ew -> E.EventRel.add (ew,er) k
        | _,_ -> k)
        rfm E.EventRel.empty

(* Load from init is before all stores *)
    let init_load es rfm =
      let loc_stores = U.collect_stores es in
      S.RFMap.fold
        (fun wt rf k -> match wt,rf with
        | S.Load er,S.Init ->
            List.fold_left
              (fun k ew ->
                E.EventRel.add (er,ew) k)
              k (map_loc_find (get_loc er) loc_stores)
        | _,_ -> k)
        rfm E.EventRel.empty

(* Reconstruct load/store atomic pairs *)

    let make_atomic_load_store es =
      let all = E.atomics_of es.E.events in
      let atms = U.collect_atomics es in
      U.LocEnv.fold
        (fun _loc atms k ->
          let atms =
            List.filter
              (fun e -> not (E.is_load e && E.is_store e))
              atms in (* get rid of C RMW *)
          let rs,ws = List.partition E.is_load atms in
          List.fold_left
            (fun k r ->
              List.fold_left
                (fun k w ->
                  if
                    S.atomic_pair_allowed r w &&
                    U.is_before_strict es r w &&
                    not
                      (E.EventSet.exists
                         (fun e ->
                           U.is_before_strict es r e &&
                           U.is_before_strict es e w)
                         all)
                  then E.EventRel.add (r,w) k
                  else k)
                k ws)
            k rs)
        atms E.EventRel.empty


(* Retrieve last store from rfmap *)
    let get_max_store _test _es rfm loc =
      try match S.RFMap.find (S.Final loc) rfm with
      | S.Store ew -> Some ew
      | S.Init -> None       (* means no store to loc *)
      with Not_found -> None
(*
  let module PP = Pretty.Make(S) in
  eprintf "Uncomplete rfmap: %s\n%!" (A.pp_location loc) ;
  PP.show_es_rfm test es rfm ;
  assert false
 *)
(* Store to final state comes last *)
    let last_store test es rfm =
      let loc_stores = U.collect_stores es
      and loc_loads = U.collect_loads es in
      U.LocEnv.fold
        (fun loc ws k ->
          match get_max_store test es rfm loc with
          | None -> k
          | Some max ->
              let loads = map_loc_find loc loc_loads in
              let k =
                List.fold_left
                  (fun k er ->
                    if E.event_equal er max then k (* possible with RMW *)
                    else match S.RFMap.find (S.Load er) rfm with
                    | S.Init -> E.EventRel.add (er,max) k
                    | S.Store my_ew ->
                        if E.event_equal my_ew max then k
                        else E.EventRel.add (er,max) k)
                  k loads in
              List.fold_left
                (fun k ew ->
                  if E.event_equal ew max then k
                  else E.EventRel.add (ew,max) k)
                k ws)
        loc_stores E.EventRel.empty

    let fold_mem_finals test es rfm kont res =
      (* We can build those now *)
      let evts = es.E.events in
      let po_iico = U.po_iico es in
      let ppoloc = make_ppoloc po_iico evts in
      let store_load_vbf = store_load rfm
      and init_load_vbf = init_load es rfm in
(* Atomic load/store pairs *)
      let atomic_load_store = make_atomic_load_store es in
(* Now generate final stores *)
      let loc_stores = U.collect_mem_stores es in
      let loc_stores =
        if C.observed_finals_only then
          let observed_locs = S.observed_locations test in
(*          eprintf "Observed locs: {%s}\n"
            (S.LocSet.pp_str "," A.pp_location   observed_locs) ; *)
          U.LocEnv.fold
            (fun loc ws k ->
              if A.LocSet.mem loc observed_locs then
                U.LocEnv.add loc ws k
              else k)
            loc_stores U.LocEnv.empty
        else loc_stores in
      let possible_finals =
        if C.optace then
          U.LocEnv.fold
            (fun _loc ws k ->
              List.filter
                (fun w ->
                  not
                    (List.exists
                       (fun w' -> U.is_before_strict es w w') ws))
                ws::k)
            loc_stores []
        else
          U.LocEnv.fold (fun _loc ws k -> ws::k) loc_stores [] in
(* Add final loads from init for all locations, cleaner *)
      let loc_stores = U.collect_stores es
      and loc_loads = U.collect_loads es in
      let rfm =
        U.LocEnv.fold
          (fun loc _rs k ->
            try
              ignore (U.LocEnv.find loc loc_stores) ;
              k
            with Not_found -> S.RFMap.add (S.Final loc) S.Init k)
          loc_loads rfm in
      try
        let pco0 =
          if C.initwrites then U.compute_pco_init es
          else E.EventRel.empty in
        let pco =
          if not C.optace then
            pco0
          else
            match U.compute_pco rfm ppoloc with
            | None -> raise Exit
            | Some pco -> E.EventRel.union pco0 pco in
(* Cross product *)

        Misc.fold_cross
          possible_finals
          (fun ws res ->
(*
  eprintf "Finals:" ;
  List.iter
  (fun e -> eprintf " %a"  E.debug_event e) ws ;
  eprintf "\n";
 *)
            let rfm =
              List.fold_left
                (fun k w ->
                  S.RFMap.add (S.Final (get_loc w)) (S.Store w) k)
                rfm ws in
            let fsc = compute_final_state test rfm  in
            if check_filter test fsc && worth_going test fsc then begin
              if C.debug.Debug_herd.solver then begin
                let module PP = Pretty.Make(S) in
                prerr_endline "Final rfmap" ;
                PP.show_es_rfm test es rfm ;
              end ;
              let last_store_vbf = last_store test es rfm in
              let pco =
                E.EventRel.union pco
                  (U.restrict_to_mem_stores last_store_vbf) in
              if E.EventRel.is_acyclic pco then
                let conc =
                  {
                   S.str = es ;
                   rfmap = rfm ;
                   fs = fsc ;
                   po = po_iico ;
                   pos = ppoloc ;
                   pco = pco ;

                   store_load_vbf = store_load_vbf ;
                   init_load_vbf = init_load_vbf ;
                   last_store_vbf = last_store_vbf ;
                   atomic_load_store = atomic_load_store ;
                 } in
                kont conc res
              else begin res end
            end else res)
          res
      with Exit -> res


(* Initial check of rfmap validity: no intervening writes.
   Limited to memory, since  generated rfmaps are correct for registers *)
(* NOTE: this is more like an optimization,
   models should rule out those anyway *)
    let check_rfmap es rfm =
      let po_iico = U.is_before_strict es in

      S.for_all_in_rfmap
        (fun wt rf -> match wt with
        | S.Load er when E.is_mem_load er ->
            begin match rf with
            | S.Store ew ->
                assert (not (po_iico er ew)) ;
                (* ok by construction, in theory *)
                not
                  (E.EventSet.exists
                     (fun e ->
                       E.is_store e &&  E.same_location e ew &&
                       po_iico ew e &&
                       po_iico e er)
                     es.E.events)
            | S.Init ->
                not
                  (E.EventSet.exists
                     (fun e ->
                       E.is_store e && E.same_location e er &&
                       po_iico e er)
                     es.E.events)
            end
        | _ -> true)
        rfm

    let calculate_rf_with_cnstrnts test es cs kont kont_loop res =
      match solve_regs test es cs with
      | None -> res
      | Some (es,rfm,cs) ->
          if C.debug.Debug_herd.solver && C.verbose > 0 then begin
            let module PP = Pretty.Make(S) in
            prerr_endline "Reg solved" ;
            PP.show_es_rfm test es rfm ;
          end ;
          solve_mem test es rfm cs
            (fun es rfm cs res ->
              match cs with
              | [] ->
                  if C.debug.Debug_herd.solver && C.verbose > 0 then begin
                    let module PP = Pretty.Make(S) in
                    prerr_endline "Mem solved" ;
                    PP.show_es_rfm test es rfm
                  end ;
                  if
                    not (C.optace) ||  check_rfmap es rfm
                  then
                    fold_mem_finals test es rfm kont res
                  else begin
                    res
                  end
              | _ -> when_unsolved test es rfm cs kont_loop res)
            res

  end
