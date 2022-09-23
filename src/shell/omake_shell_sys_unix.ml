(*
 * System calls.
 *)
(*
 * These functions are directly exported.
 *)
external ext_set_tty_pgrp : 
  Omake_shell_sys_type.pgrp -> unit = "omake_shell_sys_set_tty_pgrp"
external ext_setpgid : 
  Omake_shell_sys_type.pid ->
  Omake_shell_sys_type.pid -> unit = "omake_shell_sys_setpgid"

let interact = ref (Lm_readline.isatty ())

let set_interactive flag =
   interact := flag

let set_tty_pgrp pgrp =
   if !interact then
      ext_set_tty_pgrp pgrp

let setpgid pid1 pid2 =
   if !interact then
      ext_setpgid pid1 pid2

(*
 * Close-on-exec flags.
 * We actually want a close-on-fork, so we keep track of
 * these descriptors.
 *)
module FdCompare =
struct
   type t = Unix.file_descr
   let compare = compare
end

module FdSet = Lm_set.LmMake (FdCompare);;

let close_on_fork = ref FdSet.empty

let close_fd fd =
   Unix.close fd;
   close_on_fork := FdSet.remove !close_on_fork fd

let set_close_on_exec fd =
   Unix.set_close_on_exec fd;
   close_on_fork := FdSet.add !close_on_fork fd

let clear_close_on_exec fd =
   Unix.clear_close_on_exec fd;
   close_on_fork := FdSet.remove !close_on_fork fd

let do_close_on_fork () =
   FdSet.iter Unix.close !close_on_fork;
   close_on_fork := FdSet.empty

(**  Send a signal to a process. *)
let signo_of_signal = function
  | Omake_shell_type.SigAbrt -> Sys.sigabrt
  | SigAlrm -> Sys.sigalrm
  | SigFPE  -> Sys.sigfpe
  | SigHup  -> Sys.sighup
  | SigIll  -> Sys.sigill
  | SigInt  -> Sys.sigint
  | SigKill -> Sys.sigkill
  | SigPipe -> Sys.sigpipe
  | SigQuit -> Sys.sigquit
  | SigSegv -> Sys.sigsegv
  | SigTerm -> Sys.sigterm
  | SigUsr1 -> Sys.sigusr1
  | SigUsr2 -> Sys.sigusr2
  | SigChld -> Sys.sigchld
  | SigCont -> Sys.sigcont
  | SigStop -> Sys.sigstop
  | SigTstp -> Sys.sigtstp
  | SigTtin -> Sys.sigttin
  | SigTtou -> Sys.sigttou
  | SigVTAlrm -> Sys.sigvtalrm
  | SigProf   -> Sys.sigprof
  | SigNum i  -> i

let kill pgrp signal =
   Unix.kill pgrp (signo_of_signal signal)

(*
 * Wait for a process to exit.
 * The leader flag indicates whether to wait for the leader.
 *)
let wait pgrp leader nohang =
   let flags =
      if !interact then
         [Unix.WUNTRACED]
      else
         []
   in
   let flags =
      if nohang then
         Unix.WNOHANG :: flags
      else
         flags
   in
   let pid =
      if pgrp = 0 then
         -1
      else if leader then
         pgrp
      else if !interact then
         -pgrp
      else
         -1
   in
      Unix.waitpid flags pid

(*
 * Duplicate file descriptors onto
 * their standard places.
 *)
let dup stdin stdout stderr =
   let stdin'  = Unix.dup stdin in
   let stdout' = Unix.dup stdout in
   let stderr' = Unix.dup stderr in
      Unix.close stdin;
      if (stdin <> stdout) then Unix.close stdout;
      if (stdin <> stderr && stdout <> stderr) then Unix.close stderr;
      Unix.dup2 stdin'  Unix.stdin;
      Unix.dup2 stdout' Unix.stdout;
      Unix.dup2 stderr' Unix.stderr;
      Unix.close stdin';
      Unix.close stdout';
      Unix.close stderr'

let dup_actions workfd stdin stdout stderr =
  (* Careful: dup2(fd1,fd2) also clears the close-on-exec flag for the
     duplicate. However, dup2(fd,fd) is, according to POSIX, a no-op.
     We work around by doing dup2(fd,workfd); dup2(workfd,fd) in sequence
     (where workfd is an arbitrary other file descriptor)
   *)
  let open Omake_shell_spawn in
  [ Fda_dup2(stdin, workfd);
    Fda_dup2(workfd, Unix.stdin);
    Fda_dup2(stdout, workfd);
    Fda_dup2(workfd, Unix.stdout);
    Fda_dup2(stderr, workfd);
    Fda_dup2(workfd, Unix.stderr);
    Fda_close(workfd);
  ] @
    ( if stdin <> Unix.stdin then [ Fda_close stdin ] else [] ) @
      ( if stdout <> Unix.stdout then [ Fda_close stdout ] else [] ) @
        ( if stderr <> Unix.stderr && stderr <> stdout then [ Fda_close stderr ] else [] )

(*
 * Create a thread.
 * This actually creates a process on Unix.
 *)
let create_thread info =
   let { Omake_shell_sys_type.create_thread_stdin = stdin;
         create_thread_stdout = stdout;
         create_thread_stderr = stderr;
         create_thread_pgrp = pgrp;
         create_thread_fun = f;
         create_thread_background = bg
       } = info
   in
   flush_all();
   Lm_unix_util.moncontrol false;
   let pid = Unix.fork () in
      if pid = 0 then
         let code =
            try
               let pgrp =
                  if pgrp = 0 then
                     let pid = Unix.getpid () in
                        setpgid pid pid;
                        if not bg then
                           set_tty_pgrp pgrp;
                        pid
                  else
                     pgrp
               in
               dup stdin stdout stderr;
               do_close_on_fork ();
               ignore (Sys.signal Sys.sigint  Sys.Signal_default);
               ignore (Sys.signal Sys.sigquit Sys.Signal_default);
               ignore (Sys.signal Sys.sigtstp Sys.Signal_default);
               f Unix.stdin Unix.stdout Unix.stderr pgrp
            with
               Omake_value_type.ExitException (_, code) ->
                  code
             | exn ->
                  let () =
                     try Format.eprintf "%a@." Omake_exn_print.pp_print_exn exn with _ -> ()
                  in
                     Omake_state.exn_error_code
         in
            exit code
      else
         pid

(*
 * Create a process.
 *)
let create_process info =
  match info with
    {Omake_shell_sys_type.create_process_stdin = stdin;
     create_process_stdout = stdout;
     create_process_stderr = stderr;
     create_process_pgrp = pgrp;
     create_process_dir = dir;
     create_process_env = env;
     create_process_exe = exe;
     create_process_argv = argv;
     create_process_background = bg} ->

    Lm_unix_util.moncontrol false;
    let workfd = Unix.openfile "." [Unix.O_RDONLY] 0 in
      let pid =
        Omake_shell_spawn.spawn
          ~chdir:(Omake_shell_spawn.Wd_chdir dir)
          ~env
          ~pg:(if !interact && pgrp = 0 then
                 begin
                   if bg then
                     Omake_shell_spawn.Pg_new_bg_group
                   else
                     Omake_shell_spawn.Pg_new_fg_group
                 end
               else
                 Omake_shell_spawn.Pg_keep)
          ~fd_actions:(dup_actions workfd stdin stdout stderr)
          exe
          argv in
        Unix.close workfd;
        Lm_unix_util.moncontrol true;
        pid
