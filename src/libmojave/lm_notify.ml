let debug_notify =
   Lm_debug.create_debug {
      debug_name = "notify";
      debug_description = "Print the information on FAM events.";
      debug_value = false
   }

(*
 * Tables.
 *)
module IntCompare =
struct
   type t = int
   let compare (x : int) (y : int) = compare x y
end

module StringCompare =
struct
   type t = string
   let compare (x : string) (y : string) = compare x y
end

module IntTable = Lm_map.LmMake (IntCompare)
module StringTable = Lm_map.LmMake (StringCompare)

(*
 * The state of the notifier.
 *)
type request = int

type job =
   { dir       : string;
     path      : Lm_filename_util.root * string list;
     recursive : bool;
     request   : request;
     mutable running : bool
   }

type code =
   Changed
 | Deleted
 | StartExecuting
 | StopExecuting
 | Created
 | Moved
 | Acknowledge
 | Exists
 | EndExist
 | DirectoryChanged

type notify_event =
   { ne_request : request;
     ne_name    : string;
     ne_code    : code
   }

type event =
   { notify_code : code;
     notify_name : string
   }

type info

type t =
   { notify_info                 : info;
     notify_fd                   : Unix.file_descr option;
     mutable notify_dirs         : request StringTable.t;
     mutable notify_requests     : job IntTable.t
   }

(*
 * C stubs.
 *)
external notify_enabled            : unit -> bool                      = "om_notify_enabled"
external notify_open               : unit -> info                      = "om_notify_open"
external notify_close              : info -> unit                      = "om_notify_close"
external notify_fd                 : info -> Unix.file_descr           = "om_notify_fd"
external notify_monitor_directory  : info -> string -> bool -> request = "om_notify_monitor_directory"
external notify_suspend            : info -> request -> unit           = "om_notify_suspend"
external notify_resume             : info -> request -> unit           = "om_notify_resume"
external notify_cancel             : info -> request -> unit           = "om_notify_cancel"
external notify_pending            : info -> bool                      = "om_notify_pending"
external notify_next_event         : info -> notify_event              = "om_notify_next_event";;

(************************************************************************
 * Utilities
 *)

(*
 * Canonical name for a directory.
 *)
let name_of_dir dir =
   Lm_filename_util.normalize_string dir

let path_of_name name =
   match Lm_filename_util.filename_path name with
      Lm_filename_util.AbsolutePath (root, path) ->
         root, path
    | Lm_filename_util.RelativePath _ ->
         raise (Invalid_argument ("Lm_notify.path_of_name: " ^ name ^ ": all paths must be absolute"))

(*
 * Check if a filename is part of a directory tree.
 *)
let is_path_prefix (root1, path1) (root2, path2) =
   let rec is_prefix l1 l2 =
      match l1, l2 with
         h1 :: l1, h2 :: l2 ->
            h1 = h2 && is_prefix l1 l2
       | [], _ ->
            true
       | _, [] ->
            false
   in
      root1 = root2 && is_prefix path1 path2

let is_monitored_name requests name =
   let new_path = path_of_name name in
      IntTable.exists (fun _ job ->
            let { path = path;
                  recursive = recursive;
                  _
                } = job
            in
               new_path = path || (recursive && is_path_prefix path new_path)) requests

(************************************************************************
 * Notify API.
 *)

(*
 * Debugging.
 *)
let string_of_code code =
   match code with
   | Changed          -> "Changed"
   | Deleted          -> "Deleted"
   | StartExecuting   -> "StartExecuting"
   | StopExecuting    -> "StopExecuting"
   | Created          -> "Created"
   | Moved            -> "Moved"
   | Acknowledge      -> "Acknowledge"
   | Exists           -> "Exists"
    | EndExist         -> "EndExists"
    | DirectoryChanged -> "DirectoryChanged"

(*
 * Is this enabled?
 *)
let enabled = notify_enabled ()

(*
 * Open a connection.
 *)
let create () =
   let info = notify_open () in
   let fd =
      try 
         let fd = notify_fd info in
            if !debug_notify then
               Format.eprintf "Lm_notify.create: fd = %i@." (Lm_unix_util.int_of_fd fd);
            Some fd
      with Failure _ ->
         if !debug_notify then
            Format.eprintf "Lm_notify.create: no fd @.";
         None
   in
      { notify_info     = info;
        notify_fd       = fd;
        notify_dirs     = StringTable.empty;
        notify_requests = IntTable.empty
      }

(*
 * Close the connection.
 *)
let close notify =
   notify_close notify.notify_info

(*
 * Get the file descriptor.
 *)
let file_descr { notify_fd = fd ; _} =
   fd

(*
 * Monitoring.
 *)
let monitor notify dir recursive =
   let { notify_info = info;
         notify_dirs = dirs;
         notify_requests = requests;
         _
       } = notify
   in
   let name = name_of_dir dir in
      if not (is_monitored_name requests name) then begin
         if !debug_notify then
            Format.eprintf "Lm_notify.monitor: %s, recursive: %b@." name recursive;
         let request = notify_monitor_directory info dir recursive in
         let job =
            { dir       = dir;
              path      = path_of_name name;
              recursive = recursive;
              running   = true;
              request   = request
            }
         in
         let dirs = StringTable.add dirs name request in
         let requests = IntTable.add requests request job in
            notify.notify_dirs <- dirs;
            notify.notify_requests <- requests
      end

(*
 * Suspend notifications.
 *)
let suspend notify dir =
   let { notify_info = info;
         notify_dirs = dirs;
         notify_requests = requests;
         _
       } = notify
   in
   let dir = name_of_dir dir in
   let request =
      try StringTable.find dirs dir with
         Not_found ->
            raise (Invalid_argument "suspend_dir")
   in
   let job = IntTable.find requests request in
      if job.running then
         begin
            notify_suspend info job.request;
            job.running <- false
         end

let suspend_all notify =
   let { notify_info = info;
         notify_requests = requests;
         _
       } = notify
   in
      IntTable.iter (fun _ job ->
            if job.running then
               begin
                  notify_suspend info job.request;
                  job.running <- false
               end) requests

let resume notify dir =
   let { notify_info = info;
         notify_dirs = dirs;
         notify_requests = requests;
         _
       } = notify
   in
   let dir = name_of_dir dir in
   let request =
      try StringTable.find dirs dir with
         Not_found ->
            raise (Invalid_argument "resume_dir")
   in
   let job = IntTable.find requests request in
      if not job.running then
         begin
            notify_resume info job.request;
            job.running <- true
         end

let resume_all notify =
   let { notify_info = info;
         notify_requests = requests;
         _
       } = notify
   in
      IntTable.iter (fun _ job ->
            if not job.running then
               begin
                  notify_resume info job.request;
                  job.running <- true
               end) requests

(*
 * Cancel a request.
 *)
let cancel notify dir =
   let { notify_info = info;
         notify_dirs = dirs;
         notify_requests = requests;
         _
       } = notify
   in
   let dir = name_of_dir dir in
   let request =
      try StringTable.find dirs dir with
         Not_found ->
            raise (Invalid_argument "cancel_dir")
   in
   let job = IntTable.find requests request in
      notify_cancel info job.request;
      notify.notify_dirs <- StringTable.remove dirs dir;
      notify.notify_requests <- IntTable.remove requests request

let cancel_all notify =
   let { notify_info = info;
         notify_requests = requests;
         _
       } = notify
   in
      IntTable.iter (fun request _ -> notify_cancel info request) requests;
      notify.notify_dirs <- StringTable.empty;
      notify.notify_requests <- IntTable.empty

(*
 * Check for a pending event.
 *)
let pending notify =
   let pending = notify_pending notify.notify_info in
      if !debug_notify then
         Format.eprintf "Lm_notify.pending: %s@." (if pending then "true" else "false");
      pending

(*
 * Get the next event.
 *)
let next_event notify =
  if !debug_notify then
    Format.eprintf "Lm_notify.next_event: starting@.";
  let { ne_request = request;
        ne_name = name;
        ne_code = code
      } = notify_next_event notify.notify_info
  in
  if !debug_notify then
    Format.eprintf "Lm_notify.next_event: received event for name %s, code %s@." name (string_of_code code);
  let job =
    try IntTable.find notify.notify_requests request with
      Not_found ->
      raise (Invalid_argument "Lm_notify.next_event: unknown request")
  in
  let filename =
    if Filename.is_relative name then
      Filename.concat job.dir name
    else
      name
  in
  if !debug_notify then
    Format.eprintf "Lm_notify.next_event: filename is %s@." filename;
  { notify_code = code;
    notify_name = filename
  }

