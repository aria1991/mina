open Core
open Async
module Timeout = Timeout_lib.Core_time

(* module util with  *)

let run_cmd dir prog args =
  [%log' spam (Logger.create ())]
    "Running command (from %s): $command" dir
    ~metadata:[ ("command", `String (String.concat (prog :: args) ~sep:" ")) ] ;
  Process.create_exn ~working_dir:dir ~prog ~args ()
  >>= Process.collect_output_and_wait

let check_cmd_output ~prog ~args output =
  let open Process.Output in
  let print_output () =
    let indent str =
      String.split str ~on:'\n'
      |> List.map ~f:(fun s -> "    " ^ s)
      |> String.concat ~sep:"\n"
    in
    print_endline "=== COMMAND ===" ;
    print_endline
      (indent
         ( prog ^ " "
         ^ String.concat ~sep:" "
             (List.map args ~f:(fun arg -> "\"" ^ arg ^ "\"")) )) ;
    print_endline "=== STDOUT ===" ;
    print_endline (indent output.stdout) ;
    print_endline "=== STDERR ===" ;
    print_endline (indent output.stderr) ;
    Writer.(flushed (Lazy.force stdout))
  in
  match output.exit_status with
  | Ok () ->
      return (Ok output.stdout)
  | Error (`Exit_non_zero status) ->
      let%map () = print_output () in
      Or_error.errorf "command exited with status code %d" status
  | Error (`Signal signal) ->
      let%map () = print_output () in
      Or_error.errorf "command exited prematurely due to signal %d"
        (Signal.to_system_int signal)

let run_cmd_or_error_timeout ~timeout_seconds dir prog args =
  [%log' spam (Logger.create ())]
    "Running command (from %s): $command" dir
    ~metadata:[ ("command", `String (String.concat (prog :: args) ~sep:" ")) ] ;
  let open Deferred.Let_syntax in
  let%bind process = Process.create_exn ~working_dir:dir ~prog ~args () in
  let%bind res =
    match%map
      Timeout.await ()
        ~timeout_duration:(Time.Span.create ~sec:timeout_seconds ())
        (Process.collect_output_and_wait process)
    with
    | `Ok output ->
        check_cmd_output ~prog ~args output
    | `Timeout ->
        Deferred.return (Or_error.error_string "timed out running command")
  in
  res

let run_cmd_or_error dir prog args =
  let%bind output = run_cmd dir prog args in
  check_cmd_output ~prog ~args output

let run_cmd_exn dir prog args =
  match%map run_cmd_or_error dir prog args with
  | Ok output ->
      output
  | Error error ->
      Error.raise error

let run_cmd_exn_timeout ~timeout_seconds dir prog args =
  match%map run_cmd_or_error_timeout ~timeout_seconds dir prog args with
  | Ok output ->
      output
  | Error error ->
      Error.raise error

let rec prompt_continue prompt_string =
  print_string prompt_string ;
  let%bind () = Writer.flushed (Lazy.force Writer.stdout) in
  let c = Option.value_exn In_channel.(input_char stdin) in
  print_newline () ;
  if Char.equal c 'y' || Char.equal c 'Y' then Deferred.unit
  else prompt_continue prompt_string

module Make (Engine : Intf.Engine.S) = struct
  let pub_key_of_node node =
    let open Signature_lib in
    match Engine.Network.Node.network_keypair node with
    | Some nk ->
        Malleable_error.return (nk.keypair.public_key |> Public_key.compress)
    | None ->
        Malleable_error.hard_error_format
          "Node '%s' did not have a network keypair, if node is a block \
           producer this should not happen"
          (Engine.Network.Node.id node)

  let check_common_prefixes ~tolerance ~logger chains =
    assert (List.length chains > 1) ;
    let hashset_chains =
      List.map chains ~f:(Hash_set.of_list (module String))
    in
    let longest_chain_length =
      chains |> List.map ~f:List.length
      |> List.max_elt ~compare:Int.compare
      |> Option.value_exn
    in
    let common_prefixes =
      List.reduce hashset_chains ~f:Hash_set.inter |> Option.value_exn
    in
    let common_prefixes_length = Hash_set.length common_prefixes in
    let length_difference = longest_chain_length - common_prefixes_length in
    if length_difference = 0 || length_difference <= tolerance then
      Malleable_error.return ()
    else
      let error_str =
        sprintf
          "Chains have common prefix of %d blocks, longest absolute chain is \
           %d blocks.  the difference is %d blocks, which is greater than \
           allowed tolerance of %d blocks"
          common_prefixes_length longest_chain_length length_difference
          tolerance
      in
      [%log error] "%s" error_str ;
      Malleable_error.soft_error ~value:() (Error.of_string error_str)

  let check_peer_connectivity ~nodes_by_peer_id ~peer_id ~connected_peers =
    let get_node_id p =
      p |> String.Map.find_exn nodes_by_peer_id |> Engine.Network.Node.id
    in
    let expected_peers =
      nodes_by_peer_id |> String.Map.keys
      |> List.filter ~f:(fun p -> not (String.equal p peer_id))
    in
    Malleable_error.List.iter expected_peers ~f:(fun p ->
        let error =
          Printf.sprintf "node %s (id=%s) is not connected to node %s (id=%s)"
            (get_node_id peer_id) peer_id (get_node_id p) p
          |> Error.of_string
        in
        Malleable_error.ok_if_true
          (List.mem connected_peers p ~equal:String.equal)
          ~error_type:`Hard ~error)

  let check_peers ~logger nodes =
    let open Malleable_error.Let_syntax in
    let%bind nodes_and_responses =
      Malleable_error.List.map nodes ~f:(fun node ->
          let%map response =
            Engine.Network.Node.must_get_peer_id ~logger node
          in
          (node, response))
    in
    let nodes_by_peer_id =
      nodes_and_responses
      |> List.map ~f:(fun (node, (peer_id, _)) -> (peer_id, node))
      |> String.Map.of_alist_exn
    in
    Malleable_error.List.iter nodes_and_responses
      ~f:(fun (_, (peer_id, connected_peers)) ->
        check_peer_connectivity ~nodes_by_peer_id ~peer_id ~connected_peers)
end
