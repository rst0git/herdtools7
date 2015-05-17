module Make (C:Arch.Config) (V:Value.S) =
  struct
    include AArch64Base

    type lannot = A | XA | L | XL | X | N
					 
    let empty_annot = N

    let is_barrier b1 b2 = barrier_compare b1 b2 = 0
						     
    let is_atomic = function
      | XA | XL | X -> true
      | _ -> false

    let is_acquire = function
      | A | XA -> true
      | _ -> false

    let is_release = function
      | L | XL -> true
      | _ -> false

    let barrier_sets = 
      let barriers = do_fold_dmb_dsb (fun h t -> h::t) [] in
      List.map (fun b -> (pp_barrier_dot b,is_barrier b)) barriers

    let annot_sets = [
      "X", is_atomic;
      "A", is_acquire;
      "L", is_release
    ]

    let is_isync = is_barrier ISB
    let pp_isync = "isb"

    let pp_annot = function
      | XA -> "Acq*"
      | A -> "Acq"
      | XL -> "Rel*"
      | L -> "Rel"
      | X -> "*"
      | N -> ""

    module V = V

    include ArchExtra.Make(C)
	(struct
	  module V = V 

	  type arch_reg = reg
	  let pp_reg = pp_reg
	  let reg_compare = reg_compare

	  type arch_instruction = instruction
	end)
	  
  end