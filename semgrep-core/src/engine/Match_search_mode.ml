(* Yoann Padioleau
 *
 * Copyright (C) 2019-2022 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common
module R = Rule
module XP = Xpattern
module MR = Mini_rule
module PM = Pattern_match
module G = AST_generic
module PI = Parse_info
module MV = Metavariable
module RP = Report
module S = Specialize_formula
module RM = Range_with_metavars
module E = Semgrep_error_code
module Resp = Output_from_core_t
module Out = Output_from_core_t
open Match_env

let logger = Logging.get_logger [ __MODULE__ ]

(* debugging flags *)
let debug_timeout = ref false
let debug_matches = ref false

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* The core engine of Semgrep.
 *
 * This module implements the boolean composition of patterns.
 * See Match_patterns.ml for the code to handle a single pattern and
 * the visitor/matching engine.
 *
 * Thus, we can decompose the engine in 3 main components:
 *  - composing matching results using boolean/set logic (this file)
 *  - visiting code (=~ Match_patterns.ml)
 *  - matching code (=~ Generic_vs_generic.ml)
 *
 * There are also "preprocessing" work before:
 *  - parsing (lexing, parsing) rules, code, patterns
 *  - normalizing (convert to a generic AST)
 *  - naming (but bugs probably)
 *  - typing (propagating type decls at least and small inference)
 *  - analyzing (dataflow constant propagation)
 *    but we could do much more: deep static analysis using Datalog?
 *
 * TODO
 *  - associate the metavariable-regexp to the appropriate pattern
 *    to get the right scope (right now we accept the wrong scope but
 *    this forces to extend some ranges with metavars from other ranges)
 *
 * LATER (if really decide to rewrite the whole python wrapper code in OCaml):
 *  - paths
 *  - autofix
 *  - adjust messages with metavariable content
 *  - ...
 *
 * FUTURE WORK:
 * update: TODO move in DeepSemgrep
 * Right now we just analyze one file at a time. Later we could
 * maybe take a list of files and do some global analysis for:
 *     * caller/callee in different files
 *       which can be useful to understand keyword arguments
 *     * inheritance awareness, because right now we can't match
 *       code that inherits indirectly form a class mentioned in a pattern
 * There are different options for such global analysis:
 *  - generate a giant file a la CIL, but scale?
 *    (there is a recent LLVM project that does the same)
 *  - do it via a 2 passes process. 1st pass iterates over all files, report
 *    already matches, record semantic information (e.g., inheritance tree,
 *    call graph, etc.) as it goes, and let the matching engine report
 *    todo_second_pass if for example is_children returned a Maybe.
 *    Then in 2nd pass just process the files that were marked as todo.
 *  - use LSP, so don't even need 2 pass and can even work when passing
 *    a single file or subdir to semgrep
 *
 * Note that we opted here for simple patterns with simple extensions
 * to the grammar (metavar, ellipsis) with simple (but powerful) logic
 * compositions of patterns.
 * Coccinelle instead opted for very complex patterns and using CTL to
 * hold of that together.
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)
(* The types are now defined in Match_env.ml *)

type matching_explanation = {
  op : matching_operation;
  children : matching_explanation list;
  (* resulting ranges *)
  ranges : RM.ranges;
  (* TODO: should be a range loc in the rule file *)
  pos : Rule.tok;
}

(* TODO:
 * - tainting source/sink/sanitizer
 * - subpattern EllipsisAndStmt, ClassHeaderAndElems
 * - Where filters (metavar-comparison, etc)
 *)
and matching_operation =
  | OpAnd
  | OpOr
  (*  | OpNot *)
  | OpXPattern

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)
let ( let* ) = Option.bind

let xpatterns_in_formula (e : S.sformula) : (Xpattern.t * R.inside option) list
    =
  let res = ref [] in
  e |> S.visit_sformula (fun xpat inside -> Common.push (xpat, inside) res);
  !res

let partition_xpatterns xs =
  let semgrep = ref [] in
  let spacegrep = ref [] in
  let regexp = ref [] in
  let comby = ref [] in
  xs
  |> List.iter (fun (xpat, inside) ->
         let { XP.pid; pstr = str, _; pat } = xpat in
         match pat with
         | XP.Sem (x, _lang) -> Common.push (x, inside, pid, str) semgrep
         | XP.Spacegrep x -> Common.push (x, pid, str) spacegrep
         | XP.Regexp x -> Common.push (x, pid, str) regexp
         | XP.Comby x -> Common.push (x, pid, str) comby);
  (List.rev !semgrep, List.rev !spacegrep, List.rev !regexp, List.rev !comby)

let group_matches_per_pattern_id (xs : Pattern_match.t list) :
    id_to_match_results =
  let h = Hashtbl.create 101 in
  xs
  |> List.iter (fun m ->
         let id = int_of_string m.PM.rule_id.id in
         Hashtbl.add h id m);
  h

let error_with_rule_id rule_id (error : E.error) =
  match error.typ with
  (* Don't add the rule id for consistency with other parse errors *)
  | PartialParsing _ -> error
  | _ -> { error with rule_id = Some rule_id }

let lazy_force x = Lazy.force x [@@profiling]

let _if_explanations env f xs =
  if env.matching_explanations then Some (f (Common.map_filter (fun x -> x) xs))
  else None

(*****************************************************************************)
(* Adapters *)
(*****************************************************************************)

(* old: Before we used to pass the entire rule and we got the list of languages
 * from there. But after metavariable-pattern we can now recursively call
 * evaluate_formula using a different language than the one used by the rule!
 * If the rule is a generic one, but the nested pattern formula is not, then
 * this will raise Impossible... Thus, now we have to pass the language(s) that
 * we are specifically targeting. *)
let (mini_rule_of_pattern :
      Xlang.t ->
      Pattern.t * R.inside option * Xpattern.pattern_id * string ->
      MR.t) =
 fun xlang (pattern, inside, id, pstr) ->
  {
    MR.id = string_of_int id;
    pattern;
    inside = Option.is_some inside;
    (* parts that are not really needed I think in this context, since
     * we just care about the matching result.
     *)
    message = "";
    severity = R.Error;
    languages =
      (match xlang with
      | L (x, xs) -> x :: xs
      | LRegex
      | LGeneric ->
          raise Impossible);
    (* useful for debugging timeout *)
    pattern_string = pstr;
  }

(*****************************************************************************)
(* Debugging semgrep *)
(*****************************************************************************)

let debug_semgrep config mini_rules file lang ast =
  (* process one mini rule at a time *)
  logger#info "DEBUG SEMGREP MODE!";
  mini_rules
  |> Common.map (fun mr ->
         logger#debug "Checking mini rule with pattern %s" mr.MR.pattern_string;
         let res =
           Match_patterns.check
             ~hook:(fun _ -> ())
             config [ mr ] (file, lang, ast)
         in
         if !debug_matches then
           (* TODO
              let json = res |> List.map (fun x ->
                   x |> JSON_report.match_to_match_ |> SJ.string_of_match_) in
              let json_uniq = Common.uniq_by ( = ) json in
              let res_uniq =
                Common.uniq_by (AST_utils.with_structural_equal PM.equal) res
              in
              logger#debug
                "Found %d mini rule matches (uniq = %d) (json_uniq = %d)"
                (List.length res) (List.length res_uniq) (List.length json_uniq);
           *)
           res |> List.iter (fun m -> logger#debug "match = %s" (PM.show m));
         res)
  |> List.flatten

(*****************************************************************************)
(* Evaluating Semgrep patterns *)
(*****************************************************************************)

let matches_of_patterns ?mvar_context ?range_filter (xconf : xconfig)
    (xtarget : Xtarget.t)
    (patterns :
      (Pattern.t * R.inside option * Xpattern.pattern_id * string) list) :
    RP.times RP.match_result =
  let { Xtarget.file; xlang; lazy_ast_and_errors; lazy_content = _ } =
    xtarget
  in
  let config = (xconf.config, xconf.equivs) in
  match xlang with
  | Xlang.L (lang, _) ->
      let (ast, skipped_tokens), parse_time =
        Common.with_time (fun () -> lazy_force lazy_ast_and_errors)
      in
      let matches, match_time =
        Common.with_time (fun () ->
            let mini_rules =
              patterns |> Common.map (mini_rule_of_pattern xlang)
            in

            if !debug_timeout || !debug_matches then
              (* debugging path *)
              debug_semgrep config mini_rules file lang ast
            else
              (* regular path *)
              Match_patterns.check
                ~hook:(fun _ -> ())
                ?mvar_context ?range_filter config mini_rules (file, lang, ast))
      in
      let errors = Parse_target.errors_from_skipped_tokens skipped_tokens in
      RP.make_match_result matches errors { RP.parse_time; match_time }
  | _ -> RP.empty_semgrep_result

(*****************************************************************************)
(* Specializations *)
(*****************************************************************************)

let run_selector_on_ranges env selector_opt ranges =
  match (selector_opt, ranges) with
  | _, [] ->
      (* Empty context, nothing to select from. *)
      []
  | None, ranges ->
      (* Nothing to select. *)
      ranges
  | Some { S.pattern; pid; pstr; _ }, ranges ->
      (* Find matches of `pattern` *but* only inside `ranges`, this prevents
       * matching and allocations that are wasteful because they are going to
       * be thrown away later when interesecting the results. *)
      let range_filter (tok1, tok2) =
        let r = Range.range_of_token_locations tok1 tok2 in
        List.exists (fun rwm -> Range.( $<=$ ) r rwm.RM.r) ranges
      in
      let patterns = [ (pattern, None, pid, fst pstr) ] in
      let res =
        matches_of_patterns ~range_filter env.xconf env.xtarget patterns
      in
      logger#info "run_selector_on_ranges: found %d matches"
        (List.length res.matches);
      res.matches
      |> Common.map RM.match_result_to_range
      |> RM.intersect_ranges env.xconf.config !debug_matches ranges

let apply_focus_on_ranges env focus ranges : RM.ranges =
  let apply_focus_mvar range focus_mvar =
    let* _mvar, mval =
      List.find_opt
        (fun (mvar, _mval) -> MV.equal_mvar focus_mvar mvar)
        range.RM.mvars
    in
    let* range_loc = Visitor_AST.range_of_any_opt (MV.mvalue_to_any mval) in
    let focus_match =
      {
        PM.rule_id = fake_rule_id (-1, focus_mvar);
        PM.file = env.xtarget.file;
        PM.range_loc;
        PM.tokens = lazy (MV.ii_of_mval mval);
        PM.env = range.mvars;
        PM.taint_trace = None;
      }
    in
    let focus_range = RM.match_result_to_range focus_match in
    (* Essentially, we are intersecting the ranges. *)
    if Range.( $<=$ ) focus_range.r range.r then Some focus_range
    else if Range.( $<=$ ) range.r focus_range.r then Some range
    else None
  in
  let apply_focus init_range =
    focus
    |> List.fold_left
         (fun opt_range focus_mvar ->
           let* range = opt_range in
           apply_focus_mvar range focus_mvar)
         (Some init_range)
  in
  ranges |> List.filter_map apply_focus

(*****************************************************************************)
(* Evaluating xpatterns *)
(*****************************************************************************)

let matches_of_xpatterns ~mvar_context (xconf : xconfig) (xtarget : Xtarget.t)
    (xpatterns : (Xpattern.t * R.inside option) list) : RP.times RP.match_result
    =
  let { Xtarget.file; lazy_content; _ } = xtarget in
  (* Right now you can only mix semgrep/regexps and spacegrep/regexps, but
   * in theory we could mix all of them together. This is why below
   * I don't match over xlang and instead assume we could have multiple
   * kinds of patterns at the same time.
   *)
  let patterns, spacegreps, regexps, combys = partition_xpatterns xpatterns in

  (* final result *)
  RP.collate_pattern_results
    [
      matches_of_patterns ~mvar_context xconf xtarget patterns;
      (let config = (xconf.config, xconf.equivs) in
       Xpattern_match_spacegrep.matches_of_spacegrep config spacegreps file);
      Xpattern_match_regexp.matches_of_regexs regexps lazy_content file;
      Xpattern_match_comby.matches_of_combys combys lazy_content file;
    ]
  [@@profiling]

(*****************************************************************************)
(* Formula evaluation *)
(*****************************************************************************)

let rec filter_ranges (env : env) (xs : RM.ranges) (cond : R.metavar_cond) :
    RM.ranges =
  xs
  |> List.filter (fun r ->
         let bindings = r.RM.mvars in
         match cond with
         | R.CondEval e ->
             let env = Eval_generic.bindings_to_env env.xconf.config bindings in
             Eval_generic.eval_bool env e
         | R.CondNestedFormula (mvar, opt_lang, formula) ->
             Metavariable_pattern.satisfies_metavar_pattern_condition
               nested_formula_has_matches env r mvar opt_lang formula
         (* todo: would be nice to have CondRegexp also work on
          * eval'ed bindings.
          * We could also use re.match(), to be close to python, but really
          * Eval_generic must do something special here with the metavariable
          * which may not always be a string. The regexp is really done on
          * the text representation of the metavar content.
          *)
         | R.CondRegexp (mvar, re, const_prop) ->
             let fk = PI.unsafe_fake_info "" in
             let fki = AST_generic.empty_id_info () in
             let e =
               (* old: spf "semgrep_re_match(%s, \"%s\")" mvar re_str
                * but too many possible escaping problems, so easier to build
                * an expression manually.
                *)
               let re_str = Regexp_engine.pcre_pattern re in
               let re_exp = G.L (G.String (re_str, fk)) |> G.e in
               let mvar_exp = G.N (G.Id ((mvar, fk), fki)) |> G.e in
               let call_re_match re_exp str_exp =
                 G.Call
                   ( G.DotAccess
                       ( G.N (G.Id (("re", fk), fki)) |> G.e,
                         fk,
                         FN (Id (("match", fk), fki)) )
                     |> G.e,
                     (fk, [ G.Arg re_exp; G.Arg str_exp ], fk) )
                 |> G.e
               in
               let call_str x =
                 G.Call
                   (G.N (G.Id (("str", fk), fki)) |> G.e, (fk, [ G.Arg x ], fk))
                 |> G.e
               in
               (* We generate a fake expression:
                     re.match(re_str, str($MVAR))
                  that matches `re_str` against the string representation of
                  $MVAR's value. *)
               call_re_match re_exp (call_str mvar_exp)
             in
             let config = env.xconf.config in
             let env =
               if const_prop && config.constant_propagation then
                 Eval_generic.bindings_to_env config bindings
               else Eval_generic.bindings_to_env_just_strings config bindings
             in
             Eval_generic.eval_bool env e
         | R.CondAnalysis (mvar, CondEntropy) ->
             let bindings = r.mvars in
             Metavariable_analysis.analyze_string_metavar env bindings mvar
               Entropy.has_high_score
         | R.CondAnalysis (mvar, CondReDoS) ->
             let bindings = r.mvars in
             let analyze re_str =
               logger#debug
                 "Analyze regexp captured by %s for ReDoS vulnerability: %s"
                 mvar re_str;
               match ReDoS.find_vulnerable_subpatterns re_str with
               | Ok [] -> false
               | Ok subpatterns ->
                   subpatterns
                   |> List.iter (fun pat ->
                          logger#info
                            "The following subpattern was predicted to be \
                             vulnerable to ReDoS attacks: %s"
                            pat);
                   true
               | Error () ->
                   logger#debug
                     "Failed to parse metavariable %s's value as a regexp: %s"
                     mvar re_str;
                   false
             in
             Metavariable_analysis.analyze_string_metavar env bindings mvar
               analyze)

and nested_formula_has_matches env formula opt_context =
  let res, final_ranges =
    matches_of_formula env.xconf env.rule env.xtarget formula opt_context
  in
  env.errors := Report.ErrorSet.union res.RP.errors !(env.errors);
  match final_ranges with
  | [] -> false
  | _ :: _ -> true

(* less: use Set instead of list? *)
and evaluate_formula (env : env) (opt_context : RM.t option) (e : S.sformula) :
    RM.ranges * matching_explanation option =
  match e with
  | S.Leaf (({ XP.pid = id; pstr = _, tok; _ } as xpat), inside) ->
      let match_results =
        try Hashtbl.find_all env.pattern_matches id with
        | Not_found -> []
      in
      let kind =
        match inside with
        | Some R.Inside -> RM.Inside
        | None when Xpattern.is_regexp xpat -> RM.Regexp
        | None -> RM.Plain
      in
      let ranges =
        match_results
        |> Common.map RM.match_result_to_range
        |> Common.map (fun r -> { r with RM.kind })
      in
      let exp = Some { op = OpXPattern; ranges; children = []; pos = tok } in
      (ranges, exp)
  | S.Or (tok, xs) ->
      let ranges, exps =
        xs |> Common.map (evaluate_formula env opt_context) |> Common2.unzip
      in
      let ranges = List.flatten ranges in
      let exp =
        Some
          {
            op = OpOr;
            ranges;
            pos = tok;
            children = exps |> Common.map_filter (fun x -> x);
          }
      in
      (ranges, exp)
  | S.And
      ( tok,
        {
          selector_opt;
          positives = pos;
          negatives = neg;
          conditionals = conds;
          focus;
        } ) -> (
      (* we now treat pattern: and pattern-inside: differently. We first
       * process the pattern: and then the pattern-inside.
       * This fixed only one mismatch in semgrep-rules.
       *
       * old: the old code was simpler ... but incorrect.
       *  (match pos with
       *  | [] -> failwith "empty And; no positive terms in And"
       *  | start::pos ->
       *     let res = evaluate_formula env start in
       *    let res = pos |> List.fold_left (fun acc x ->
       *      intersect_ranges acc (evaluate_formula env x)
       * ...
       *)

      (* let's start with the positive ranges *)
      let posrs, posrs_exps =
        Common.map (evaluate_formula env opt_context) pos |> Common2.unzip
      in
      (* subtle: we need to process and intersect the pattern-inside after
       * (see tests/OTHER/rules/inside.yaml).
       * TODO: this is ugly; AND should be commutative, so we should just
       * merge ranges, not just filter one or the other.
       * update: however we have some tests that rely on pattern-inside:
       * being special, see tests/OTHER/rules/and_inside.yaml.
       *)
      let posrs, posrs_inside =
        posrs
        |> Common.partition_either (fun xs ->
               match xs with
               (* todo? should we double check they are all inside? *)
               | { RM.kind = Inside; _ } :: _ -> Right xs
               | _ -> Left xs)
      in
      let all_posr =
        match posrs @ posrs_inside with
        | [] -> (
            match opt_context with
            | None -> failwith "empty And; no positive terms in And"
            | Some r -> [ [ r ] ])
        | ps -> ps
      in
      match all_posr with
      | [] -> failwith "FIXME"
      | posr :: posrs ->
          let ranges = posr in
          let ranges =
            posrs
            |> List.fold_left
                 (fun acc r ->
                   RM.intersect_ranges env.xconf.config !debug_matches acc r)
                 ranges
          in

          (* optimization of `pattern: $X` *)
          let ranges = run_selector_on_ranges env selector_opt ranges in

          (* let's remove the negative ranges *)
          let ranges, negs_exps =
            neg
            |> List.fold_left
                 (fun (ranges, acc_exps) x ->
                   let ranges_neg, exp = evaluate_formula env opt_context x in
                   let ranges =
                     RM.difference_ranges env.xconf.config ranges ranges_neg
                   in
                   (ranges, exp :: acc_exps))
                 (ranges, [])
          in
          (* let's apply additional filters.
           * TODO: Note that some metavariable-regexp may be part of an
           * AND where not all patterns define the metavar, e.g.,
           *   pattern-inside: def $FUNC() ...
           *   pattern: return $X
           *   metavariable-regexp: $FUNC regex: (foo|bar)
           * in which case the order in which we do the operation matters
           * (at this point intersect_range will have filtered the
           *  range of the pattern_inside).
           * alternative solutions?
           *  - bind closer metavariable-regexp with the relevant pattern
           *  - propagate metavariables when intersecting ranges
           *  - distribute filter_range in intersect_range?
           * See https://github.com/returntocorp/semgrep/issues/2664
           *)
          let ranges =
            conds
            |> List.fold_left
                 (fun acc cond -> filter_ranges env acc cond)
                 ranges
          in

          let ranges = apply_focus_on_ranges env focus ranges in
          let exp =
            Some
              {
                op = OpAnd;
                ranges;
                (* TODO: add some intermediate OpNot *)
                pos = tok;
                children =
                  posrs_exps @ negs_exps |> Common.map_filter (fun x -> x);
              }
          in
          (ranges, exp))
  | S.Not _ -> failwith "Invalid Not; you can only negate inside an And"

and matches_of_formula xconf rule xtarget formula opt_context :
    RP.rule_profiling RP.match_result * RM.ranges =
  let formula = S.formula_to_sformula formula in
  let xpatterns = xpatterns_in_formula formula in
  let mvar_context : Metavariable.bindings option =
    Option.map (fun s -> s.RM.mvars) opt_context
  in
  let res =
    matches_of_xpatterns mvar_context xconf xtarget xpatterns
    |> RP.add_rule rule
  in
  logger#trace "found %d matches" (List.length res.matches);
  (* match results per minirule id which is the same than pattern_id in
   * the formula *)
  let pattern_matches_per_id = group_matches_per_pattern_id res.matches in
  let env =
    {
      xconf;
      pattern_matches = pattern_matches_per_id;
      xtarget;
      rule;
      errors = ref Report.ErrorSet.empty;
    }
  in
  logger#trace "evaluating the formula";
  let final_ranges, _exp = evaluate_formula env opt_context formula in
  logger#trace "found %d final ranges" (List.length final_ranges);
  let res' =
    { res with RP.errors = Report.ErrorSet.union res.RP.errors !(env.errors) }
  in
  (res', final_ranges)
  [@@profiling]

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

let check_rule ({ R.mode = `Search pformula; _ } as r) hook xconf xtarget =
  let xconf = Match_env.adjust_xconfig_with_rule_options xconf r.R.options in
  let rule_id = fst r.id in
  let formula = R.formula_of_pformula ~rule_id pformula in
  let res, final_ranges = matches_of_formula xconf r xtarget formula None in
  let errors = res.errors |> Report.ErrorSet.map (error_with_rule_id rule_id) in
  {
    RP.matches =
      final_ranges
      |> Common.map (RM.range_to_pattern_match_adjusted r)
      (* dedup similar findings (we do that also in Match_patterns.ml,
       * but different mini-rules matches can now become the same match)
       *)
      |> PM.uniq
      |> before_return (fun v ->
             v
             |> List.iter (fun (m : Pattern_match.t) ->
                    let str = spf "with rule %s" rule_id in
                    hook str m));
    errors;
    extra = res.extra;
  }
