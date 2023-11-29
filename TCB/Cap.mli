(* Capabilities implemented as simple abstract types and explicit
 * parameters ("Lambda the ultimate security tool").
 *
 * Note that most of the types below are on purpose [abstract] and there is
 * no way to build/forge them except by calling the restricted (statically
 * and dynamically) Cap.main() below which is passing all capabilities
 * to the entry point of your program.
 *)

(**************************************************************************)
(* Standard capabilities *)
(**************************************************************************)

module Console : sig
  type stdin
  type stdout
  (* stderr and logs are an "ambient" authority *)
end

module Process : sig
  (* basic stuff *)
  type argv
  type env

  (* advanced stuff *)
  type signal
  type exit

  (* See also the separate Exec.t *)
  type fork
  type thread
  type domain
end

(* read/write on root/cwd/tmp *)
module FS : sig
  type root_r
  type root_w
  type cwd_r
  type cwd_w
  type tmp_r
  type tmp_w
end

module Exec : sig
  type t
end

module File : sig
  type in_channel = Stdlib.in_channel
  type out_channel = Stdlib.out_channel
end

module Network : sig
  type t
end

module Misc : sig
  type time
  type random
end

(**************************************************************************)
(* Powerbox *)
(**************************************************************************)

type fs_powerbox =
  < root_r : FS.root_r
  ; root_w : FS.root_w
  ; cwd_r : FS.cwd_r
  ; cwd_w : FS.cwd_w
  ; tmp_r : FS.tmp_r
  ; tmp_w : FS.tmp_w >

(* TODO: split in multiple parts *)
type process_powerbox =
  < stdin : Console.stdin
  ; stdout : Console.stdout
  ; argv : Process.argv
  ; env : Process.env
  ; (* advanced stuff *)
  signal : Process.signal
  ; fork : Process.fork
  ; exit : Process.exit
  ; domain : Process.domain
  ; thread : Process.thread >

type misc_powerbox = < time : Misc.time ; random : Misc.random >

(* alt: called "Stdenv.Base.env" in EIO *)
type all_caps =
  < process_powerbox
  ; fs_powerbox
  ; exec : Exec.t
  ; network : Network.t
  ; misc_powerbox >

(* you can also pass individual capabilities like just
 * stdout with 'Console.stdout'
 *)

(* pure computation, just cpu/ram *)
type no_cap

(**************************************************************************)
(* Entry point *)
(**************************************************************************)

(* Only way to access capabilities. This must be restricted to be called
 * only from a Main.ml (or Test.ml).
 *)
val main : (all_caps -> 'a) -> 'a
