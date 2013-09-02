(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open OpamTypes
open OpamFilename.OP

let seed_ref =
  ref 1664

let set_seed seed =
  seed_ref := seed

let seed () =
  !seed_ref

module Color = struct

  let red fmt =
    Printf.ksprintf (fun s -> Printf.sprintf "\027[31m%s\027[m" s) fmt

  let green fmt =
    Printf.ksprintf (fun s -> Printf.sprintf "\027[32m%s\027[m" s) fmt

  let yellow fmt =
    Printf.ksprintf (fun s -> Printf.sprintf "\027[33m%s\027[m" s) fmt

  let blue fmt =
    Printf.ksprintf (fun s -> Printf.sprintf "\027[34m%s\027[m" s) fmt

end

module Git = struct

  let exec repo command =
    OpamFilename.in_dir repo (fun () ->
        OpamSystem.command command
      )

  let return_one_line repo command =
    OpamFilename.in_dir repo (fun () ->
        List.hd (OpamSystem.read_command_output command)
      )

  let return repo command =
    OpamFilename.in_dir repo (fun () ->
        (OpamSystem.read_command_output command)
      )

  let commit repo fmt =
    Printf.kprintf (fun msg ->
        exec repo [ "git"; "commit"; "-a"; "-m"; msg; "--allow-empty" ]
      ) fmt

  let commit_file repo file fmt =
    Printf.kprintf (fun msg ->
        if OpamFilename.exists file then
          let file = OpamFilename.remove_prefix repo file in
          exec repo [ "git"; "add"; file ];
          exec repo [ "git"; "commit"; "-m"; msg; file; "--allow-empty" ];
        else
          OpamGlobals.error_and_exit "Cannot commit %s" (OpamFilename.to_string file);
      ) fmt

  let revision repo =
    return_one_line repo [ "git"; "rev-parse"; "HEAD" ]

  let commits repo =
    return repo ["git"; "log"; "master"; "--pretty=format:%H"]

  let init repo =
    exec repo ["git"; "init"]

  let test_tag = "test"

  let branch repo =
    exec repo ["git"; "checkout"; "-B"; test_tag]

  let add repo file =
    if OpamFilename.exists file then
      let file = OpamFilename.remove_prefix repo file in
      exec repo ["git"; "add"; file]

  let checkout repo hash =
    exec repo ["git"; "checkout"; hash];
    exec repo ["git"; "clean"; "-fdx"]

  let msg repo commit package fmt =
    Printf.kprintf (fun str ->
        OpamGlobals.msg "%-25s %s     %-10s %-30s\n"
          (OpamFilename.Dir.to_string repo)
          commit
          (OpamPackage.to_string package)
          str
      ) fmt

end

let random_string n =
  let s = String.create n in
  String.iteri (fun i _ ->
      let c = int_of_char 'A' + Random.int 58 in
      s.[i] <- char_of_int c
    ) s;
  s

let base = OpamFilename.Base.of_string

module Contents = struct

  let log = OpamGlobals.log "CONTENTS"

  type t = (basename * string) list

  let files seed = [
    base "x/a", random_string (1 + seed * 2);
    base "x/b", random_string (1 + seed * 3);
    base "c"  , random_string (1 + seed);
  ]

  let install name =
    base (OpamPackage.Name.to_string name ^ ".install"),
    Printf.sprintf
      "lib: [ \"x/a\" \"x/b\" \"?1\" \"?k/1\" { \"k/1\" }]\n\
       bin: [ \"c\" ]\n"

  let create nv seed =
    List.sort compare (install (OpamPackage.name nv) :: files seed)

  let read contents_root nv =
    log "read %s" (OpamPackage.to_string nv);
    let root = contents_root / OpamPackage.to_string nv in
    let files = OpamFilename.rec_files root in
    let files = List.map (fun file ->
        let base = base (OpamFilename.remove_prefix root file) in
        let content = OpamFilename.read file in
        base, content
      ) files in
    List.sort compare files

  let write contents_root nv t =
    log "write %s" (OpamPackage.to_string nv);
    let root = contents_root / OpamPackage.to_string nv in
    if not (OpamFilename.exists_dir root) then (
      OpamFilename.mkdir root;
      Git.init root;
    );
    List.iter (fun (base, contents) ->
        let file = OpamFilename.create root base in
        OpamFilename.write file contents;
        Git.add root file;
      ) t;
    Git.commit root "Add new content for package %s" (OpamPackage.to_string nv);
    let commit = Git.revision root in
    Git.msg root commit nv "Adding contents"

end

module Packages = struct

  let log = OpamGlobals.log "PACKAGES"

  open OpamFile

  type t = {
    nv      : package;
    prefix  : string option;
    opam    : OPAM.t;
    url     : URL.t option;
    descr   : Descr.t option;
    files   : (basename * string) list;
    contents: (basename * string) list;
    archive : string option;
  }

  let opam nv seed =
    let opam = OPAM.create nv in
    let maintainer = "test-" ^ string_of_int seed in
    OPAM.with_maintainer opam maintainer

  let add_depend t ?(formula=OpamFormula.Empty) name =
    let depends =
      OpamFormula.And
        (OPAM.depends t.opam,
         Atom (OpamPackage.Name.of_string name, formula)) in
    { t with opam = OPAM.with_depends t.opam depends }

  let add_depend_with_runtime_checks opam_root t ?formula name =
    let t = add_depend t ?formula name in
    let (/) = Filename.concat in
    let check_cmd =
      let l = [ "test"; "-d"; (OpamFilename.Dir.to_string opam_root/"system"/"lib"/name) ] in
      List.map (fun s -> CString s, None) l, None
    in
    let opam = t.opam in
    let opam = OpamFile.OPAM.with_build opam (OpamFile.OPAM.build opam @ [check_cmd]) in
    let opam = OpamFile.OPAM.with_remove opam (OpamFile.OPAM.remove opam @ [check_cmd]) in
    { t with opam }

  let url kind path = function
    | 0 -> None
    | i ->
      let path = match kind with
        | Some `git   -> (OpamFilename.Dir.to_string path, Some Git.test_tag)
        | None
        | Some `local -> (OpamFilename.Dir.to_string path, None)
        | _           -> failwith "TODO" in
      let url = URL.create kind path in
      let checksum = Printf.sprintf "checksum-%d" i in
      Some (URL.with_checksum url checksum)

  let descr = function
    | 0 -> None
    | i -> Some (Descr.of_string (Printf.sprintf "This is a very nice package (%d)!" i))

  let archive contents nv seed =
    match seed with
    | 0
    | 1
    | 3 -> None
    | _ ->
      let tmp_file = Filename.temp_file (OpamPackage.to_string nv) "archive" in
      log "Creating an archive file in %s" tmp_file;
      OpamFilename.with_tmp_dir (fun root ->
          let dir = root / OpamPackage.to_string nv in
          List.iter (fun (base, contents) ->
              let file = OpamFilename.create dir base in
              OpamFilename.write file contents
            ) contents;
          OpamFilename.exec root [
            ["tar"; "czf"; tmp_file; OpamPackage.to_string nv]
          ];
          let contents = OpamSystem.read tmp_file in
          OpamSystem.remove tmp_file;
          Some contents
        )

  let prefix nv =
    match OpamPackage.Version.to_string (OpamPackage.version nv) with
    | "1" -> None
    | _   ->
      let name = OpamPackage.Name.to_string (OpamPackage.name nv) in
      Some (Printf.sprintf "prefix-%s" name)

  let files = function
    | 0 -> []
    | i -> [ (base "1", random_string i); (base "k/1", random_string (i*2)) ]

  let file_list repo prefix nv =
    let opam = OpamPath.Repository.opam repo prefix nv in
    let descr = OpamPath.Repository.descr repo prefix nv in
    let url = OpamPath.Repository.url repo prefix nv in
    let files = OpamPath.Repository.files repo prefix nv in
    let archive = OpamPath.Repository.archive repo nv in
    opam, descr, url, files, archive

  let file_list_of_t repo t =
    file_list repo t.prefix t.nv

  let write_o f = function
    | None   -> ()
    | Some x -> f x

  let write repo contents_root t =
    let opam, descr, url, files, archive = file_list_of_t repo t in
    List.iter OpamFilename.remove [opam; descr; url; archive];
    OpamFilename.rmdir files;
    OPAM.write opam t.opam;
    write_o (Descr.write descr) t.descr;
    write_o (URL.write url) t.url;
    write_o (OpamFilename.write archive) t.archive;
    Contents.write contents_root t.nv t.contents;
    if t.files <> [] then (
      OpamFilename.mkdir files;
      List.iter (fun (base, str) ->
          let file = OpamFilename.create files base in
          OpamFilename.write file str
        ) t.files
    )

  let read_o f file =
    if OpamFilename.exists file then Some (f file)
    else None

  let read repo contents_root prefix nv =
    let opam, descr, url, files, archive = file_list repo prefix nv in
    let opam = OPAM.read opam in
    let descr = read_o Descr.read descr in
    let url = read_o URL.read url in
    let files =
      if not (OpamFilename.exists_dir files) then []
      else
        let all = OpamFilename.rec_files files in
        List.map (fun file ->
            OpamFilename.Base.of_string (OpamFilename.remove_prefix files file),
            OpamFilename.read file
          ) all in
    let contents = Contents.read contents_root nv in
    let archive = read_o OpamFilename.read archive in
    { nv; prefix; opam; descr; url; files; contents; archive }

  let add repo contents_root t =
    write repo contents_root t;
    let opam, descr, url, files, archive = file_list_of_t repo t in
    let commit file =
      if OpamFilename.exists file then (
        Git.add repo.repo_root file;
        Git.commit_file repo.repo_root file
          "Add package %s (%s)"
          (OpamPackage.to_string t.nv) (OpamFilename.to_string file);
        let commit = Git.revision repo.repo_root in
        Git.msg repo.repo_root commit t.nv "Add %s" (OpamFilename.to_string file);
      ) in
    List.iter commit [opam; descr; url; archive];
    if OpamFilename.exists_dir files then (
      let all = OpamFilename.rec_files files in
      List.iter (Git.add repo.repo_root) all;
      Git.commit_file repo.repo_root
        (OpamFilename.of_string (OpamFilename.Dir.to_string files))
        "Adding files/* for package %s" (OpamPackage.to_string t.nv);
      let commit = Git.revision repo.repo_root in
      Git.msg repo.repo_root commit t.nv "Add %s" (OpamFilename.Dir.to_string files)
    )

end

let read_url opam_root nv =
  let read file =
    if OpamFilename.exists file then Some (OpamFile.URL.read file) else None in
  let pinned_url =
    let nv = OpamPackage.pinned (OpamPackage.name nv) in
    OpamPath.Switch.Overlay.url opam_root OpamSwitch.default nv in
  let overlay_url = OpamPath.Switch.Overlay.url opam_root OpamSwitch.default nv in
  let url = OpamPath.url opam_root nv in
  match read pinned_url with
  | Some u -> Some u
  | None   ->
    match read overlay_url with
    | Some u -> Some u
    | None   ->
      match read url with
      | Some u -> Some u
      | None   -> None

module OPAM = struct

  let opam opam_root command args =
    OpamGlobals.msg "%s\n" (Color.blue ">> opam %s %s " command (String.concat " " args));
    let debug = if !OpamGlobals.debug then ["--debug"] else [] in
    OpamSystem.command
      ("opam" :: command ::
         "--yes" ::
         ["--root"; (OpamFilename.Dir.to_string opam_root)]
         @ debug
         @ args)

  let init opam_root repo =
    let kind = string_of_repository_kind repo.repo_kind in
    OpamGlobals.sync_archives := true;
    opam opam_root "init" [
      OpamRepositoryName.to_string repo.repo_name;
      string_of_address repo.repo_address;
      "--no-setup"; "--no-base-packages";
      "--kind"; kind
    ]

  let install opam_root ?version name =
    opam opam_root "install" [
      match version with
      | None -> OpamPackage.Name.to_string name
      | Some v -> OpamPackage.to_string (OpamPackage.create name v)
    ]

  let reinstall opam_root ?version name =
    opam opam_root "reinstall" [
      match version with
      | None -> OpamPackage.Name.to_string name
      | Some v -> OpamPackage.to_string (OpamPackage.create name v)
    ]

  let remove opam_root ?(auto=false) name =
    opam opam_root "remove"
      ((if auto then ["-a"] else [])
       @ [OpamPackage.Name.to_string name])

  let update opam_root =
    opam opam_root "update" ["--sync-archives"]

  let upgrade opam_root packages =
    opam opam_root "upgrade" (List.map OpamPackage.to_string packages)

  let pin opam_root name path =
    opam opam_root "pin"
      [OpamPackage.Name.to_string name; OpamFilename.Dir.to_string path]

end

module Check = struct

  module A = OpamFilename.Attribute

  type error = {
    source: string;
    attr  : file_attribute;
    file  : filename;
  }

  exception Sync_errors of error list

  let sync_errors errors =
    OpamGlobals.error "\n%s" (Color.red " -- Sync error --");
    List.iter (fun { source; attr; file } ->
        OpamGlobals.error "%s: %s\n%s\n%s\n"
          source
          (A.to_string attr) (OpamFilename.to_string file) (OpamFilename.read file)
      ) errors;
    raise (Sync_errors errors)

  let set map =
    A.Map.fold (fun a _ set -> A.Set.add a set) map A.Set.empty

  exception Found of file_attribute * filename

  let find_binding fn map =
    try A.Map.iter (fun a f -> if fn a f then raise (Found (a,f))) map; raise Not_found
    with Found (a,f) -> (a,f)

  let attributes ?filter dir =
    let filter = match filter with
      | None   -> fun _ -> Some dir
      | Some f -> f in
    let files = OpamFilename.rec_files dir in
    List.fold_left (fun attrs file ->
        match filter file with
        | None     -> attrs
        | Some dir ->
          let attr = OpamFilename.to_attribute dir file in
          A.Map.add attr file attrs
      ) A.Map.empty files

  let sym_diff (name1, a1) (name2, a2) =
    let s1 = set a1 in
    let s2 = set a2 in
    let diff1 = A.Set.diff s1 s2 in
    let diff2 = A.Set.diff s2 s1 in
    let diff = A.Set.union diff1 diff2 in
    A.Set.fold (fun a errors ->
        let source, attr, file =
          if A.Map.mem a a1 then
            (name1, a, A.Map.find a a1)
          else
            (name2, a, A.Map.find a a2) in
        { source; attr; file } :: errors
      ) diff []

  let check_attributes a1 a2 =
    match sym_diff a1 a2 with
    | [] -> ()
    | l  -> sync_errors l

  let check_dirs ?filter (n1, d1) (n2, d2) =
    let a1 = attributes ?filter d1 in
    let a2 = attributes ?filter d2 in
    check_attributes (n1, a1) (n2, a2)

  let packages repo root =
    (* metadata *)
    let r = OpamPath.Repository.packages_dir repo in
    let o = OpamPath.packages_dir root in
    let filter file =
      Some (OpamFilename.dirname_dir (OpamFilename.dirname file)) in
    check_dirs ~filter ("repo", r) ("opam", o);
    (* archives *)
    let r = OpamPath.Repository.archives_dir repo in
    let o = OpamPath.archives_dir root in
    check_dirs ("repo", r) ("opam", o)

  let files_dir opam_root nv =
    let pin = OpamPackage.pinned (OpamPackage.name nv) in
    let d1 = OpamPath.Switch.Overlay.files opam_root OpamSwitch.default pin in
    let d2 = OpamPath.Switch.Overlay.files opam_root OpamSwitch.default nv in
    let d3 = OpamPath.files opam_root nv in
    if OpamFilename.exists_dir d1 then Some d1
    else if OpamFilename.exists_dir d2 then Some d2
    else if OpamFilename.exists_dir d3 then Some d3
    else None

  let contents opam_root nv =

    let opam =
      let libs =
        OpamPath.Switch.lib opam_root OpamSwitch.default (OpamPackage.name nv) in
      let bins =
        OpamPath.Switch.bin opam_root OpamSwitch.default in
      A.Map.union
        (fun x y -> failwith "union") (attributes libs) (attributes bins) in

    let contents =
      match read_url opam_root nv with
      | None   -> A.Map.empty
      | Some u ->
        let base =
          let package_root = OpamFilename.Dir.of_string (fst (OpamFile.URL.url u)) in
          let filter file =
            if OpamFilename.starts_with (package_root / ".git") file then None
            else if OpamFilename.ends_with ".install" file then None
            else Some (OpamFilename.dirname file) in
          attributes ~filter package_root in
        let files = match files_dir opam_root nv with
          | None   -> A.Map.empty
          | Some d -> attributes d in

        A.Map.union (fun x y -> x) files base in

    check_attributes ("opam", opam) ("contents", contents)

end
