open Emacs_sexp

type 'a result =
  | Feed  of 'a
  | Close
  | Abort of basic

type 'a neg = 'a result -> unit

type dual =
  | Once of t neg
  | Sink of t neg

and t = dual sexp

let gensym () =
  let counter = ref 0 in
  fun () -> incr counter; !counter

let close_message = S "end"
let cancel_message = Abort (S "cancel")
let finalize_message = Abort (S "finalize")

let add_finalizer (dual : t neg) =
  let finalize f = f finalize_message in
  Gc.finalise finalize dual

exception Invalid_message of basic

let stderr ~exn msg =
  prerr_endline (Printexc.to_string exn ^ ": " ^ msg)

type endpoint = {
  stdout: basic -> unit;
  query: t -> unit;
}

(* Cancel : abort computation, release ressources  *)
let cancel' ~stderr (t : t) : basic =
  let map : basic -> basic = function
    | C (S "meta", x) -> C (S "meta", C (S "escape", x))
    | x -> x
  and inj (dual : dual) : basic =
    begin try
        let (Once t | Sink t) = dual in
        t cancel_message
      with exn ->
        stderr ~exn "while cancelling message"
    end;
    let sym = match dual with
      | Once _ -> S "once"
      | Sink _ -> S "sink"
    in
    C (S "meta", C (sym, sym_nil))
  in
  transform_list ~inj ~map t

let cancel ?(stderr=stderr) (t : t) =
  let rec aux = function
    | C (a, b) -> aux a; aux b
    | P t -> aux t
    | S _ | T _ -> ()
    | I _ | F _ -> ()
    | M (Once t | Sink t) ->
      try t cancel_message
      with exn ->
        stderr ~exn "while cancelling message"
  in
  aux t

let connect ?(stderr=stderr) {stdout; query} : endpoint =
  let eof = ref false in

  let gensym = gensym () in

  let table : (int, dual) Hashtbl.t = Hashtbl.create 7 in

  (* Lower: turn closures into ground sexp *)

  let lower (t : t) : basic =
    let map : basic -> basic = function
      | C (S "meta", x) -> C (S "meta", C (S "escape", x))
      | x -> x
    and inj (dual : dual) : basic =
      let addr = gensym () in
      Hashtbl.add table addr dual;
      let sym = match dual with
        | Once _ -> S "once"
        | Sink _ -> S "sink"
      in
      C (S "meta", C (sym, I addr))
    in
    transform_list ~inj ~map t
  in

  (* Upper: inject closures into ground sexp *)

  let upper (t : basic) : t =
    let map : t -> t = function
      | C (S "meta", C (S "escape", x)) ->
        C (S "meta", x)
      | C (S "meta", C (S ("once" | "sink" as kind), addr)) ->
        let addr = cancel' ~stderr addr in
        let is_once = kind = "once" in
        let closed = ref false in
        let dual msg =
          if !eof then
            match msg with
            | Feed x -> cancel ~stderr x
            | Abort _ | Close -> ()
          else if !closed then
            if msg == finalize_message then ()
            else raise (Invalid_message (match msg with
                | Abort b -> C (S "abort", b)
                | Close -> S "close"
                | Feed x -> C (S "feed", cancel' ~stderr x)
              ))
          else match msg with
            | Feed x ->
              closed := is_once;
              stdout (C (S "feed" , C (addr, lower x)))
            | Close ->
              closed := true;
              stdout (C (S "close", addr))
            | Abort x ->
              closed := true;
              stdout (C (S "abort", C (addr, x)))
        in
        add_finalizer dual;
        M (if is_once then Once dual else Sink dual)
      | x -> x
    and inj : void -> t = void
    in
    transform_list ~inj ~map t
  in

  let get_addr = function
    | I addr -> addr, Hashtbl.find table addr
    | _ -> raise Not_found
  in

  {
    stdout = begin
      if !eof then ignore
      else function
        | C (S "query", payload) ->
          query (upper payload)
        | C (S "feed" , C (addr, payload)) ->
          let x = upper payload in
          begin match get_addr addr with
            | addr, Once t ->
              Hashtbl.remove table addr;
              t (Feed x)
            | _, Sink t -> t (Feed x)
            | exception Not_found ->
              cancel ~stderr x
          end
        | C (S "abort" , C (addr, x)) ->
          begin match get_addr addr with
            | addr, (Once t | Sink t) ->
              Hashtbl.remove table addr;
              t (Abort x)
            | exception Not_found ->
              (* FIXME: Not_found *) ()
          end
        | C (S "close"    , addr) ->
          begin match get_addr addr with
            | addr, (Once t | Sink t) ->
              Hashtbl.remove table addr;
              t Close
            | exception Not_found ->
              (* FIXME: Not_found *) ()
          end
        | S "end" ->
          eof := true;
          stdout (S "end");
          Hashtbl.iter (fun _ (Sink t | Once t) ->
              try t cancel_message
              with _ -> (* FIXME: exn *) ()
            ) table;
          Hashtbl.reset table
        | _ -> invalid_arg "Unhandled command"
    end;

    query = begin fun t ->
      if !eof then cancel ~stderr t
      else stdout (C (S "query", lower t))
    end
  }

let close endpoint = endpoint.stdout close_message