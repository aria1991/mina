open Core
open Signature_lib
open Transaction_logic

module Location : Merkle_ledger.Location_intf.S

module Db :
  Merkle_ledger.Database_intf.S
    with module Location = Location
    with module Addr = Location.Addr
    with type root_hash := Ledger_hash.t
     and type hash := Ledger_hash.t
     and type account := Account.t
     and type key := Public_key.Compressed.t
     and type token_id := Token_id.t
     and type token_id_set := Token_id.Set.t
     and type account_id := Account_id.t
     and type account_id_set := Account_id.Set.t

module Any_ledger :
  Merkle_ledger.Any_ledger.S
    with module Location = Location
    with type account := Account.t
     and type key := Public_key.Compressed.t
     and type token_id := Token_id.t
     and type token_id_set := Token_id.Set.t
     and type account_id := Account_id.t
     and type account_id_set := Account_id.Set.t
     and type hash := Ledger_hash.t

module Mask :
  Merkle_mask.Masking_merkle_tree_intf.S
    with module Location = Location
     and module Attached.Addr = Location.Addr
    with type account := Account.t
     and type key := Public_key.Compressed.t
     and type token_id := Token_id.t
     and type token_id_set := Token_id.Set.t
     and type account_id := Account_id.t
     and type account_id_set := Account_id.Set.t
     and type hash := Ledger_hash.t
     and type location := Location.t
     and type parent := Any_ledger.M.t

module Maskable :
  Merkle_mask.Maskable_merkle_tree_intf.S
    with module Location = Location
    with module Addr = Location.Addr
    with type account := Account.t
     and type key := Public_key.Compressed.t
     and type token_id := Token_id.t
     and type token_id_set := Token_id.Set.t
     and type account_id := Account_id.t
     and type account_id_set := Account_id.Set.t
     and type hash := Ledger_hash.t
     and type root_hash := Ledger_hash.t
     and type unattached_mask := Mask.t
     and type attached_mask := Mask.Attached.t
     and type t := Any_ledger.M.t

include
  Merkle_mask.Maskable_merkle_tree_intf.S
    with module Location := Location
    with module Addr = Location.Addr
    with type root_hash := Ledger_hash.t
     and type hash := Ledger_hash.t
     and type account := Account.t
     and type key := Public_key.Compressed.t
     and type token_id := Token_id.t
     and type token_id_set := Token_id.Set.t
     and type account_id := Account_id.t
     and type account_id_set := Account_id.Set.t
     and type t = Mask.Attached.t
     and type attached_mask = Mask.Attached.t
     and type unattached_mask = Mask.t

(* We override the type of unregister_mask_exn that comes from
   Merkle_mask.Maskable_merkle_tree_intf.S because at this level callers aren't
   doing reparenting and shouldn't be able to turn off the check parameter.
*)
val unregister_mask_exn : loc:string -> Mask.Attached.t -> Mask.t

(* The maskable ledger is t = Mask.Attached.t because register/unregister
 * work off of this type *)
type maskable_ledger = t

val with_ledger : depth:int -> f:(t -> 'a) -> 'a

val with_ephemeral_ledger : depth:int -> f:(t -> 'a) -> 'a

val create : ?directory_name:string -> depth:int -> unit -> t

val create_ephemeral : depth:int -> unit -> t

val of_database : Db.t -> t

(** This is not _really_ copy, merely a stop-gap until we remove usages of copy in our codebase. What this actually does is creates a new empty mask on top of the current ledger *)
val copy : t -> t

val register_mask : t -> Mask.t -> Mask.Attached.t

val commit : Mask.Attached.t -> unit

val unsafe_create_account :
  t -> Account_id.t -> Account.t -> Location.t Or_error.t

(** Raises if the ledger is full, or if an account already exists for the given
    [Account_id.t].
*)
val create_new_account_exn : t -> Account_id.t -> Account.t -> unit

val apply_user_command :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> txn_global_slot:Mina_numbers.Global_slot.t
  -> t
  -> Signed_command.With_valid_signature.t
  -> Transaction_applied.Signed_command_applied.t Or_error.t

val apply_fee_transfer :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> txn_global_slot:Mina_numbers.Global_slot.t
  -> t
  -> Fee_transfer.t
  -> Transaction_applied.Fee_transfer_applied.t Or_error.t

val apply_coinbase :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> txn_global_slot:Mina_numbers.Global_slot.t
  -> t
  -> Coinbase.t
  -> Transaction_applied.Coinbase_applied.t Or_error.t

val apply_transaction :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> txn_state_view:Snapp_predicate.Protocol_state.View.t
  -> t
  -> Transaction.t
  -> Transaction_applied.t Or_error.t

val apply_parties_unchecked :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> state_view:Snapp_predicate.Protocol_state.View.t
  -> t
  -> Parties.t
  -> ( Transaction_applied.Parties_applied.t
     * ( ( Party.t list
         , Token_id.t
         , Currency.Amount.t
         , t
         , bool
         , unit )
         Parties_logic.Local_state.t
       * Currency.Amount.t ) )
     Or_error.t

val undo :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> t
  -> Transaction_applied.t
  -> unit Or_error.t

val has_locked_tokens :
     global_slot:Mina_numbers.Global_slot.t
  -> account_id:Account_id.t
  -> t
  -> bool Or_error.t

val merkle_root_after_parties_exn :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> txn_state_view:Snapp_predicate.Protocol_state.View.t
  -> t
  -> Parties.Valid.t
  -> Ledger_hash.t * [ `Next_available_token of Token_id.t ]

val merkle_root_after_user_command_exn :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> txn_global_slot:Mina_numbers.Global_slot.t
  -> t
  -> Signed_command.With_valid_signature.t
  -> Ledger_hash.t * [ `Next_available_token of Token_id.t ]

(** Raises if the ledger is full. *)
val create_empty_exn : t -> Account_id.t -> Path.t * Account.t

val num_accounts : t -> int

(** Generate an initial ledger state. There can't be a regular Quickcheck
    generator for this type because you need to detach a mask from it's parent
    when you're done with it - the GC doesn't take care of that. *)
val gen_initial_ledger_state :
  ( Signature_lib.Keypair.t
  * Currency.Amount.t
  * Mina_numbers.Account_nonce.t
  * Account_timing.t )
  array
  Quickcheck.Generator.t

type init_state =
  ( Signature_lib.Keypair.t
  * Currency.Amount.t
  * Mina_numbers.Account_nonce.t
  * Account_timing.t )
  array
[@@deriving sexp_of]

(** Apply a generated state to a blank, concrete ledger. *)
val apply_initial_ledger_state : t -> init_state -> unit

module Ledger_inner : Transaction_logic.Ledger_intf with type t = t
