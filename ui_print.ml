open Sexp
open Session

module Buf = Buf_naive

type substitution = {
  start: int;
  length: int;
  replacement: string;
  action: bool;
}

type command_stream = {
  mutable sink: t neg option;
  mutable closed: bool;
  mutable queue: substitution list;
}

let send_command sink {start; length; replacement; action} =
  let cmd = sexp_of_list [
      S "substitute";
      I start;
      I length;
      T replacement;
      (if action then sym_t else sym_nil);
    ]
  in
  sink (Feed cmd)

let push_command buffer cmd =
  (*let opt = function
    | None -> "None"
    | Some _ -> "Some _"
  in
  Printf.eprintf
    "{ start = %d; length = %d; replacement = %S; action = %b } / sink = %s\n"
    cmd.start cmd.length cmd.replacement cmd.action (opt buffer.sink);*)
  if buffer.closed then ()
  else match buffer.sink with
    | None -> buffer.queue <- cmd :: buffer.queue
    | Some sink -> send_command sink cmd

let replace_sink commands sink =
  begin match commands.sink with
    | Some sink' -> sink' (Quit sym_nil)
    | None -> ()
  end;
  commands.sink <- None;
  match sink with
  | Some f ->
    let rec aux = function
      | [] -> ()
      | ls ->
        commands.queue <- [];
        List.iter (send_command f) (List.rev ls);
        aux commands.queue
    in
    aux commands.queue;
    commands.sink <- sink
  | None -> ()

type cursor = {
  action: action option;
  commands: command_stream;
  buffer: cursor lazy_t Buf.t ref;
  beginning: cursor lazy_t Buf.cursor;
  position: cursor lazy_t Buf.cursor;
}

and action = cursor -> unit

let get_action c = (Lazy.force (Buf.content c)).action

let is_closed cursor = not (Buf.member !(cursor.buffer) cursor.position)

let sub ?action current =
  if is_closed current then current
  else
    let action = match action with
      | None -> get_action current.beginning
      | Some action -> action
    in
    let rec cursor = lazy begin
      let buffer = current.buffer in
      let buf', beginning = Buf.put_before !buffer current.position cursor in
      let buf', position  = Buf.put_after  buf'    beginning cursor in
      buffer := buf';
      {action; buffer; commands = current.commands; beginning; position}
    end in
    Lazy.force cursor


let text {buffer; commands; beginning; position} ?properties text =
  (*let cmd = match properties with
    | None -> [S "text"; T text]
    | Some props ->
      let props = transform_list ~inj:void ~map:(fun x -> x) props in
      [S "text"; T text; S ":properties"; props]
  in*)
  if Buf.member !buffer position then begin
    push_command commands
      { start = Buf.position !buffer position;
        length = 0;
        replacement = text;
        action = (get_action beginning <> None) };
    buffer := Buf.insert_before !buffer position (String.length text)
  end

let clear {buffer; commands; beginning; position} =
  if Buf.member !buffer position then begin
    let start = Buf.position !buffer beginning in
    let current = Buf.position !buffer position in
    push_command commands
      { start; length = current - start;
        replacement = ""; action = false };
    buffer := Buf.remove_between !buffer beginning position
  end

let link cursor ?properties msg action =
  let cursor = sub ~action:(Some action) cursor in
  text cursor ?properties msg

let printf (cursor : cursor) ?properties fmt =
  Printf.ksprintf (text cursor ?properties) fmt

let open_buffer endpoint name =
  let commands = {
    sink   = None;
    closed = false;
    queue  = [];
  } in
  let buffer = ref (Buf.create ()) in
  let handler = M (Sink (function
    | Feed (C (S "sink", M (Sink sink))) ->
      (*Printf.eprintf "GOT SINK!\n";*)
      replace_sink commands (Some sink)
    | Feed (C (S "click", I point)) ->
      (*Printf.eprintf "GOT CLICK %d!\n" point;*)
      begin match Buf.find_before !buffer point with
        | None ->
          (*Printf.eprintf "NO CURSOR AT %d :(!\n" point;*)
          ()
        | Some cursor ->
          match get_action cursor with
          | None ->
            (*Printf.eprintf "NO ACTION AT %d :(!\n" point;*)
            ()
          | Some action ->
            action (Lazy.force (Buf.content cursor))
      end;
    | Feed r -> cancel r
    | Quit (S "close") ->
      replace_sink commands None;
      commands.closed <- true;
      ()
    | Quit _ -> ()
    ))
  in
  let rec cursor = lazy begin
    let buf, beginning = Buf.put_cursor !buffer ~at:0 cursor in
    let buf, position  = Buf.put_after buf beginning cursor in
    buffer := buf;
    {buffer; beginning; position; commands; action = None}
  end
  in
    endpoint.query (sexp_of_list
                    [S "create-buffer"; T name; handler]);
  Lazy.force cursor