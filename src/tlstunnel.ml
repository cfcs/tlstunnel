
open Lwt
open Lwt_unix

let server_config cert priv_key =
  X509_lwt.private_of_pems ~cert ~priv_key >|= fun cert ->
  Tls.Config.server ~certificates:(`Single cert) ()

let serve_ssl port cert key callback =
  server_config cert key >>= fun config ->

  let s = socket PF_INET SOCK_STREAM 0 in
  setsockopt s SO_REUSEADDR true ;
  bind s (ADDR_INET (Unix.inet_addr_any, port)) ;
  listen s 10 ;

  let rec loop () =
    Tls_lwt.Unix.accept config s >>= fun (t, addr) ->
    Lwt.async (fun () -> callback t addr) ;
    loop ()
  in
  loop ()

let safe op arg =
  try_lwt (op arg >> return_unit) with _ -> return_unit

let rec read_write closing close cnt buf ic oc =
  if !closing then
    close ()
  else
    try_lwt
      (Lwt_io.read_into ic buf 0 4096 >>= fun l ->
       cnt l ;
       if l > 0 then
         let s = Bytes.sub buf 0 l in
         Lwt_io.write oc s >>= fun () ->
         read_write closing close cnt buf ic oc
       else
         (closing := true ;
          close ()))
    with _ -> closing := true ; close ()


let resolve name port =
  gethostbyname name >|= fun he ->
  if Array.length he.h_addr_list > 0 then
    ADDR_INET (he.h_addr_list.(0), port)
  else
    let msg = "no address for " ^ name in
    invalid_arg msg

type stats = {
  mutable read : int ;
  mutable write : int
}

let epoch_data t =
  match Tls_lwt.Unix.epoch t with
  | `Ok data -> (data.Tls.Engine.protocol_version, data.Tls.Engine.ciphersuite)
  | `Error -> assert false

let worker log server t addr =
  let ic, oc = Tls_lwt.of_t t in
  let data =
    let version, cipher = epoch_data t in
    let v = Tls.Printer.tls_version_to_string version
    and c = Sexplib.Sexp.to_string_hum (Tls.Ciphersuite.sexp_of_ciphersuite cipher)
    in
    v ^ ", " ^ c
  in
  log addr ("connection established (" ^ data ^ ")") ;
  let fd = socket PF_INET SOCK_STREAM 0 in

  let stats = ref ({ read = 0 ; write = 0 }) in
  let closing = ref false in
  let close () =
    closing := true ;
    safe Lwt_unix.close fd >>= fun () ->
    safe Tls_lwt.Unix.close t
  in

  (try_lwt
     (connect fd server >>= fun () ->
      log addr "connection forwarded" ;
      let pic = Lwt_io.of_fd ~close ~mode:Lwt_io.Input fd
      and poc = Lwt_io.of_fd ~close ~mode:Lwt_io.Output fd
      in
      Lwt.join [
        read_write closing close (fun x -> !stats.read <- !stats.read + x) (Bytes.create 4096) ic poc ;
        read_write closing close (fun x -> !stats.write <- !stats.write + x) (Bytes.create 4096) pic oc
      ])
   with Unix.Unix_error (e, f, _) -> log addr (Unix.error_message e ^ " while calling " ^ f) ; close ()) >|= fun () ->
   let stats = "read " ^ (string_of_int !stats.read) ^ " bytes, wrote " ^ (string_of_int !stats.write) ^ " bytes" in
   log addr ("connection closed " ^ stats)

let log out addr event =
  let lt = Unix.localtime (Unix.time ()) in
  let source =
    match addr with
    | ADDR_INET (x, p) -> Unix.string_of_inet_addr x ^ ":" ^ string_of_int p
    | ADDR_UNIX s -> s
  in
  Printf.fprintf out "[%02d:%02d:%02d] %s: %s\n%!"
    lt.Unix.tm_hour lt.Unix.tm_min lt.Unix.tm_sec
    source event

let init out =
  Printexc.register_printer (function
      | Tls_lwt.Tls_alert x -> Some ("TLS alert: " ^ Tls.Packet.alert_type_to_string x)
      | Tls_lwt.Tls_failure f -> Some ("TLS failure: " ^ Tls.Engine.string_of_failure f)
      | _ -> None) ;
  Lwt.async_exception_hook := (fun exn ->
    Printf.fprintf out "async error %s\n%!" (Printexc.to_string exn))

let serve port target targetport certificate privkey logfd =
  let logchan = Unix.out_channel_of_descr logfd in
  init logchan ;
  Tls_lwt.rng_init () >>= fun () ->
  resolve target targetport >>= fun server ->
  serve_ssl port certificate privkey (worker (log logchan) server)

(*
let inetd logfile target targetport =
  (* we get the socket via stdin/stdout! *)
  let logfd = Unix.openfile logfile Unix.([O_WRONLY ; O_APPEND; O_CREAT]) 0o644 in
  let logchan = Unix.out_channel_of_descr logfd in
  init logchan ;
  Tls_lwt.rng_init () >>= fun () ->
  let sock = Lwt_unix.stdin in
  let addrinfo = Lwt_unix.getpeername sock in

  resolve target targetport >>= fun server ->
  server_config >>= fun config ->
  Tls_lwt.Unix.server_of_fd config sock >>= fun t ->
  worker (log logchan) server t addrinfo >|= fun () ->
  Unix.close logfd
*)

let run_server dest dport lport certificate privkey log =
  let logfd = match log with
    | None -> Unix.stdout
    | Some x -> Unix.openfile x Unix.([O_WRONLY ; O_APPEND; O_CREAT]) 0o644
  in
  Lwt_main.run (serve lport dest dport certificate privkey logfd)

open Cmdliner

let destination =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"destination"
         ~doc:"destination, the hostname of the actual service (e.g. 127.0.0.1)")

let destport =
  Arg.(required & pos 1 (some int) None & info [] ~docv:"destination_port"
         ~doc:"destination port of the actual service")

let listenport =
  Arg.(required & pos 2 (some int) None & info [] ~docv:"listening_port"
         ~doc:"listening port of tlstunnel")

let certificate =
  Arg.(required & pos 3 (some string) None & info [] ~docv:"certificate_chain"
         ~doc:"path to PEM encoded certificate chain")

let privkey =
  Arg.(required & pos 4 (some string) None & info [] ~docv:"private_key"
         ~doc:"path to PEM encoded unencrypted private key")

let log =
  Arg.(value & opt (some string) None & info ["l"; "logfile"]
         ~doc:"logfile")

let cmd =
  let doc = "proxy TLS connections to a standard TCP service" in
  let man = [
    `S "DESCRIPTION" ;
    `P "$(tname) listens on a given port and forwards request to the specified hostname" ]
  in
  Term.(pure run_server $ destination $ destport $ listenport $ certificate $ privkey $ log),
  Term.info "tlstunnel" ~version:"0.1.0" ~doc ~man

let () =
  match Term.eval cmd
  with `Error _ -> exit 1 | _ -> exit 0
