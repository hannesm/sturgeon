open Emacs_hyperprint

type t

val make : cursor -> t
val add : ?children:(t -> unit) -> ?action:action option -> t -> cursor
val clear : t -> unit
