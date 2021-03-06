(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

(* Take as input an ast file and a C or ObjectiveC file such that the ast file
   corresponds to the compilation of the C file with clang.
   Parse the ast file into a data structure and translates it into a cfg. *)

module L = Logging

let buffer_len = 262143

(* This function reads the json file in fname, validates it, and encoded in the AST data structure*)
(* defined in Clang_ast_t.  *)
let validate_decl_from_file fname =
  try
    Ag_util.Biniou.from_file ~len:buffer_len Clang_ast_b.read_decl fname
  with (Invalid_argument "Bi_inbuf.refill_from_channel") ->
    Logging.out "WARNING: biniou buffer too short, skipping the file\n";
    assert false

let validate_decl_from_stdin () =
  try
    Ag_util.Biniou.from_channel ~len:buffer_len Clang_ast_b.read_decl stdin
  with (Invalid_argument "Bi_inbuf.refill_from_channel") ->
    Logging.out "WARNING: biniou buffer too short, skipping the file\n";
    assert false

let register_perf_stats_report source_file =
  let stats_dir = Filename.concat Config.results_dir Config.frontend_stats_dir_name in
  let abbrev_source_file = DB.source_file_encoding source_file in
  let stats_file = Config.perf_stats_prefix ^ "_" ^ abbrev_source_file ^ ".json" in
  DB.create_dir Config.results_dir ;
  DB.create_dir stats_dir ;
  PerfStats.register_report_at_exit (Filename.concat stats_dir stats_file)

let init_global_state_for_capture_and_linters source_file =
  register_perf_stats_report source_file;
  Config.curr_language := Config.Clang;
  CFrontend_config.current_source := source_file;
  DB.Results_dir.init source_file

let do_run source_path ast_path =
  let init_time = Unix.gettimeofday () in
  let print_elapsed () =
    let elapsed = Unix.gettimeofday () -. init_time in
    Logging.out "Elapsed: %07.3f seconds.\n" elapsed in
  try
    let ast_filename, ast_decl =
      match ast_path with
      | Some path ->
          path, validate_decl_from_file path
      | None ->
          "stdin of " ^ source_path, validate_decl_from_stdin () in

    let decl_index, stmt_index, type_index, ivar_to_property_index =
      Clang_ast_main.index_node_pointers ast_decl in
    CFrontend_config.pointer_decl_index := decl_index;
    CFrontend_config.pointer_stmt_index := stmt_index;
    CFrontend_config.pointer_type_index := type_index;
    CFrontend_config.ivar_to_property_index := ivar_to_property_index;
    CFrontend_config.json := ast_filename;
    CLocation.check_source_file source_path;
    let source_file = CLocation.source_file_from_path source_path in
    Logging.out "Clang frontend action is  %s\n" Config.clang_frontend_action_string;
    Logging.out "Start %s of AST from %s\n" Config.clang_frontend_action_string
      !CFrontend_config.json;
    init_global_state_for_capture_and_linters source_file;
    if Config.clang_frontend_do_lint then
      CFrontend_checkers_main.do_frontend_checks source_file ast_decl;
    if Config.clang_frontend_do_capture then
      CFrontend.do_source_file source_file ast_decl;
    Logging.out "End translation AST file %s... OK!@\n" !CFrontend_config.json;
    print_elapsed ();
  with
    (Yojson.Json_error s) as exc ->
      Logging.err_debug "%s\n" s;
      print_elapsed ();
      raise exc

let () =
  match Config.source_file with
  | Some path ->
      do_run path Config.ast_file
  | None ->
      Logging.err_debug "Incorrect command line arguments\n";
      Config.print_usage_exit ()
