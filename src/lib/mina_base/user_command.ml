open Core_kernel

module Poly = struct
  [%%versioned
  module Stable = struct
    module V2 = struct
      type ('u, 's) t = Signed_command of 'u | Parties of 's
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest = Fn.id
    end

    module V1 = struct
      type ('u, 's) t = Signed_command of 'u | Snapp_command of 's
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest : _ t -> _ V2.t = function
        | Signed_command x ->
            Signed_command x
        | Snapp_command _ ->
            failwith "Snapp_command"
    end
  end]
end

type ('u, 's) t_ = ('u, 's) Poly.Stable.Latest.t =
  | Signed_command of 'u
  | Parties of 's

(* TODO: For now, we don't generate snapp transactions. *)
module Gen_make (C : Signed_command_intf.Gen_intf) = struct
  let f g = Quickcheck.Generator.map g ~f:(fun c -> Signed_command c)

  open C.Gen

  let payment ?sign_type ~key_gen ?nonce ~max_amount ?fee_token ?payment_token
      ~fee_range () =
    f
      (payment ?sign_type ~key_gen ?nonce ~max_amount ?fee_token ?payment_token
         ~fee_range ())

  let payment_with_random_participants ?sign_type ~keys ?nonce ~max_amount
      ?fee_token ?payment_token ~fee_range () =
    f
      (payment_with_random_participants ?sign_type ~keys ?nonce ~max_amount
         ?fee_token ?payment_token ~fee_range ())

  let stake_delegation ~key_gen ?nonce ?fee_token ~fee_range () =
    f (stake_delegation ~key_gen ?nonce ?fee_token ~fee_range ())

  let stake_delegation_with_random_participants ~keys ?nonce ?fee_token
      ~fee_range () =
    f
      (stake_delegation_with_random_participants ~keys ?nonce ?fee_token
         ~fee_range ())

  let sequence ?length ?sign_type a =
    Quickcheck.Generator.map
      (sequence ?length ?sign_type a)
      ~f:(List.map ~f:(fun c -> Signed_command c))
end

module Gen = Gen_make (Signed_command)

module Valid = struct
  [%%versioned
  module Stable = struct
    module V2 = struct
      type t =
        ( Signed_command.With_valid_signature.Stable.V1.t
        , Parties.Valid.Stable.V1.t )
        Poly.Stable.V2.t
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest = Fn.id
    end
  end]

  module Gen = Gen_make (Signed_command.With_valid_signature)
end

[%%versioned
module Stable = struct
  module V2 = struct
    type t = (Signed_command.Stable.V1.t, Parties.Stable.V1.t) Poly.Stable.V2.t
    [@@deriving sexp, compare, equal, hash, yojson]

    let to_latest = Fn.id
  end
end]

(*
include Allocation_functor.Make.Versioned_v1.Full_compare_eq_hash (struct
  let id = "user_command"

  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        (Signed_command.Stable.V1.t, Snapp_command.Stable.V1.t) Poly.Stable.V1.t
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest = Fn.id

      type 'a creator : Signed_command.t -> Snapp_command.t -> 'a

      let create cmd1 cmd2 = (cmd1, cmd2)
    end
  end]
end)
*)

module Zero_one_or_two = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type 'a t = [ `Zero | `One of 'a | `Two of 'a * 'a ]
      [@@deriving sexp, compare, equal, hash, yojson]
    end
  end]
end

module Verifiable = struct
  [%%versioned
  module Stable = struct
    module V2 = struct
      type t =
        ( Signed_command.Stable.V1.t
        , Snapp_predicate.Protocol_state.Stable.V1.t
          * ( Party.Stable.V1.t
            * Pickles.Side_loaded.Verification_key.Stable.V2.t option )
            list )
        Poly.Stable.V2.t
      [@@deriving sexp, compare, equal, hash, yojson]

      let to_latest = Fn.id
    end
  end]
end

let to_verifiable_exn (t : t) ~ledger ~get ~location_of_account =
  let find_vk (p : Party.t) =
    let ( ! ) x = Option.value_exn x in
    let id = Party.account_id p in
    let account : Account.t = !(get ledger !(location_of_account ledger id)) in
    !(!(account.snapp).verification_key).data
  in
  match t with
  | Signed_command c ->
      Signed_command c
  | Parties ps ->
      Parties
        ( ps.protocol_state
        , List.map (Parties.parties ps) ~f:(fun p ->
              (p, Option.try_with (fun () -> find_vk p))) )

let to_verifiable t ~ledger ~get ~location_of_account =
  Option.try_with (fun () ->
      to_verifiable_exn t ~ledger ~get ~location_of_account)

let fee_exn : t -> Currency.Fee.t = function
  | Signed_command x ->
      Signed_command.fee x
  | Parties p ->
      Parties.fee_lower_bound_exn p

(* for filtering *)
let minimum_fee = Mina_compile_config.minimum_user_command_fee

let has_insufficient_fee t = Currency.Fee.(fee_exn t < minimum_fee)

let accounts_accessed (t : t) ~next_available_token =
  match t with
  | Signed_command x ->
      Signed_command.accounts_accessed x ~next_available_token
  | Parties ps ->
      Parties.accounts_accessed ps

let next_available_token (t : t) tok =
  match t with
  | Signed_command x ->
      Signed_command.next_available_token x tok
  | Parties _ps ->
      tok

let to_base58_check (t : t) =
  match t with
  | Signed_command x ->
      Signed_command.to_base58_check x
  | Parties ps ->
      Parties.to_base58_check ps

let fee_payer (t : t) =
  match t with
  | Signed_command x ->
      Signed_command.fee_payer x
  | Parties p ->
      Parties.fee_payer p

let nonce_exn (t : t) =
  match t with
  | Signed_command x ->
      Signed_command.nonce x
  | Parties p ->
      Parties.nonce p

let check_tokens (t : t) =
  match t with
  | Signed_command x ->
      Signed_command.check_tokens x
  | Parties _ ->
      true

let fee_token (t : t) =
  match t with
  | Signed_command x ->
      Signed_command.fee_token x
  | Parties x ->
      Parties.fee_token x

let valid_until (t : t) =
  match t with
  | Signed_command x ->
      Signed_command.valid_until x
  | Parties _ ->
      Mina_numbers.Global_slot.max_value

let forget_check (t : Valid.t) : t = (t :> t)

let to_valid_unsafe (t : t) =
  `If_this_is_used_it_should_have_a_comment_justifying_it
    ( match t with
    | Parties x ->
        Parties x
    | Signed_command x ->
        (* This is safe due to being immediately wrapped again. *)
        let (`If_this_is_used_it_should_have_a_comment_justifying_it x) =
          Signed_command.to_valid_unsafe x
        in
        Signed_command x )

let filter_by_participant (commands : t list) public_key =
  List.filter commands ~f:(fun user_command ->
      Core_kernel.List.exists
        (accounts_accessed ~next_available_token:Token_id.invalid user_command)
        ~f:
          (Fn.compose
             (Signature_lib.Public_key.Compressed.equal public_key)
             Account_id.public_key))
