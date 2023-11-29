open Common
open Fpath_.Operators

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* This is a command to install semgrep in CI for the current repo
 * or for a given repository.
 *)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let chop_origin_if_needed branch : string =
  match branch with
  | "main"
  | "master"
  | "develop" ->
      (* NOTE: we use develop as the default branch for the workflow file as
       * it is the default branch for the semgrep repo
       *)
      "develop"
  (* let's chop the origin *)
  | _ when Base.String.is_prefix ~prefix:"origin/" branch ->
      Base.String.chop_prefix_exn ~prefix:"origin/" branch
  | _ -> branch

(* coupling: this should be roughly the same config than the one in
 * https://semgrep.dev/docs/semgrep-ci/sample-ci-configs/#github-actions
 *)
let gha_semgrep_ci_workflow ~default_branch : string =
  (* Custom branch name if not from main list *)
  let branch = chop_origin_if_needed default_branch in
  (* Coerce branch name into develop if already present in main list *)
  let branch =
    if branch = "main" || branch = "master" then "develop" else branch
  in
  Printf.sprintf
    {|
# Autogenerated by `semgrep install-ci`:
# This workflow runs Semgrep on pull requests and pushes to the main branch

name: semgrep
on:
  workflow_dispatch: {}
  pull_request_target: {}
  push:
    branches:
    # This workflow will run against PRs on the following default branches
      - %s
      - main
      - master

jobs:
    semgrep:
        name: semgrep/ci
        runs-on: ubuntu-latest
        if: (github.actor != 'dependabot[bot]')
        env:
            SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}
        container:
            image: returntocorp/semgrep
        steps:
            - uses: actions/checkout@v3
            - run: semgrep ci
|}
    branch

(* arbitrary name where we do our work *)
let get_new_branch () : string =
  let version = "v1" in
  Printf.sprintf "semgrep/install-ci-%s" version

let mkdir_if_needed path : unit =
  if not (Sys.file_exists path) then Unix.mkdir path 0o777

(*****************************************************************************)
(* gh (github CLI) setup *)
(*****************************************************************************)
(* We're using gh to automatically create a PR for the user, to setup
 * the SEMGREP_APP_TOKEN secret in github, and more.
 *)

let install_gh_cli () : unit =
  (* NOTE: This only supports mac users and we would need to direct users to
     their own platform-specific instructions at https://github.com/cli/cli#installation
  *)
  let cmd = Bos.Cmd.(v "brew" % "install" % "github") in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> Logs.app (fun m -> m "Github cli installed successfully")
  | _ ->
      Logs.err (fun m -> m "%s Github cli failed to install" (Logs_.err_tag ()));
      (* TODO? we could instead just remove the last step of 'install-ci'
       * and let the user commit the workflow by himself?
       *)
      Error.abort
        (Printf.sprintf
           "Please install the Github CLI manually by following the \
            instructions at %s"
           "https://github.com/cli/cli#installation")

let gh_cli_exists () : bool =
  (* 'command' can be used to test the presence of another command
   * see https://askubuntu.com/questions/512770/what-is-the-bash-command-command
   * alt: run gh --version and check for exit code
   *)
  let cmd = Bos.Cmd.(v "command" % "-v" % "gh") in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> true
  | _ -> false

let install_gh_cli_if_needed () : unit =
  if gh_cli_exists () then
    Logs.info (fun m -> m "Github CLI already installed, skipping installation")
  else (
    Logs.info (fun m -> m "Github CLI not installed, installing now");
    install_gh_cli ())

let gh_authed () : bool =
  let cmd = Bos.Cmd.(v "gh" % "auth" % "status") in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> true
  | _ -> false

let prompt_gh_auth () : unit =
  let cmd = Bos.Cmd.(v "gh" % "auth" % "login" % "--web") in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | _ -> ()

let prompt_gh_auth_if_needed () : unit =
  if gh_authed () then
    Logs.info (fun m ->
        m "Github CLI already logged in, skipping authentication")
  else (
    Logs.info (fun m -> m "Prompting Github CLI authentication");
    prompt_gh_auth ())

(* TODO: handle GitHub Enterprise *)
let set_ssh_as_default () : unit =
  let cmd =
    Bos.Cmd.(
      v "gh" % "config" % "set" % "git_protocol" % "ssh" % "--host"
      % "github.com")
  in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> ()
  | _ -> Error.abort "failed to set git_protocol as ssh"

(*****************************************************************************)
(* gh use *)
(*****************************************************************************)

(* NOTE: we use the gh repo clone subcommand over
   the regular git clone as the subcommand allows for
   both OWNER/REPO and cannonical GitHub URLs as arguments
   to clone the repo.
*)
let clone_repo ~repo : unit =
  let cmd =
    Bos.Cmd.(v "gh" % "repo" % "clone" % repo % "--" % "--depth" % "1")
  in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> ()
  | _ -> Error.abort (Printf.sprintf "failed to clone remote repo: %s" repo)

let clone_repo_to ~repo ~dst : unit =
  match Bos.OS.Dir.with_current dst (fun () -> clone_repo ~repo) () with
  | Ok _ -> Logs.info (fun m -> m "Cloned repo %s to %s." repo !!dst)
  | _ -> Logs.warn (fun m -> m "Failed to clone repo %s to %s." repo !!dst)

let create_pr ~default_branch:branch : unit =
  let branch = chop_origin_if_needed branch in
  let cmd =
    Bos.Cmd.(
      v "gh" % "pr" % "create" % "--title" % "Add Semgrep workflow" % "--body"
      % {|
## Description
This PR enables Semgrep scans with your repository.
|}
      % "--base" % branch % "--head" % get_new_branch ())
  in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok out -> Logs.app (fun m -> m "Created PR: %s" out)
  | _ ->
      Logs.warn (fun m -> m "Failed to create PR!");
      Error.abort "Failed to create PR. Please create manually"

let merge_pr () : unit =
  let cmd =
    Bos.Cmd.(
      v "gh" % "pr" % "merge" % "--merge" % "--subject" % "Add Semgrep workflow"
      % "--body" % "Enabling scans with Semgrep" % get_new_branch ())
  in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok out -> Logs.app (fun m -> m "Merged PR: %s" out)
  | _ ->
      Logs.warn (fun m -> m "Failed to merge PR!");
      Error.abort "Failed to merge PR. Please merge manually"

let semgrep_app_token_secret_exists ~git_dir:dir : bool =
  let cmd = Bos.Cmd.(v "gh" % "secret" % "list" % "-a" % "actions") in
  match
    Bos.OS.Dir.with_current dir
      (fun () ->
        match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_lines with
        | Ok lines ->
            List.exists
              (fun line -> String.starts_with ~prefix:"SEMGREP_APP_TOKEN" line)
              lines
        | _ ->
            Logs.warn (fun m -> m "Failed to list secrets for %s" !!dir);
            Error.abort
              "Failed to check for SEMGREP_APP_TOKEN. Please add it manually")
      ()
  with
  (* bugfix: was Ok _ -> true, but we should return the boolean instead *)
  | Ok b -> b
  | _ -> false

let add_semgrep_gh_secret ~git_dir:dir ~token : unit =
  let cmd =
    Bos.Cmd.(
      v "gh" % "secret" % "set" % "SEMGREP_APP_TOKEN" % "-a" % "actions"
      % "--body" % token)
  in
  Bos.OS.Dir.with_current dir
    (fun () ->
      match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
      | Ok _ -> Logs.debug (fun m -> m "Set SEMGREP_APP_TOKEN=%s" token)
      | _ ->
          Logs.warn (fun m -> m "Failed to set SEMGREP_APP_TOKEN for %s" !!dir);
          Error.abort "Failed to set SEMGREP_APP_TOKEN. Please add it manually")
    ()
  |> ignore

(*****************************************************************************)
(* Git calls *)
(*****************************************************************************)
(* TODO? add in Git_wrapper.ml instead? *)

let get_default_branch () : string =
  let cmd =
    Bos.Cmd.(v "git" % "symbolic-ref" % "refs/remotes/origin/HEAD" % "--short")
  in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok s -> s
  | _ ->
      Logs.warn (fun m -> m "Failed to get default branch");
      "origin/main"

let get_default_branch_in ~dst : string =
  let default = "origin/main" in
  let res = Bos.OS.Dir.with_current dst (fun () -> get_default_branch ()) () in
  match res with
  | Ok branch -> branch
  | _ ->
      Logs.warn (fun m ->
          m "Failed to get default branch in %s, defaulting to %s" !!dst default);
      default

let add_all_to_git () : unit =
  let cmd = Bos.Cmd.(v "git" % "add" % ".") in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> ()
  | _ -> Error.abort "Failed to add files to git"

let git_push () : unit =
  let branch = get_new_branch () in
  let cmd = Bos.Cmd.(v "git" % "push" % "--set-upstream" % "origin" % branch) in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> ()
  | _ ->
      Logs.warn (fun m -> m "Failed to push to branch %s" branch);
      Error.abort
        (Printf.sprintf "Failed to push to branch %s. Please push manually"
           branch)

let git_commit () : unit =
  let cmd =
    Bos.Cmd.(
      v "git" % "commit" % "-m" % "Add semgrep workflow"
      % "--author=\"Semgrep CI Installer <support@semgrep.com>\"")
  in
  match Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string with
  | Ok _ -> ()
  | _ ->
      Logs.warn (fun m -> m "Failed to commit changes to current branch!");
      Error.abort "Failed to commit changes. Please commit manually"

(*****************************************************************************)
(* GHA workflow helpers *)
(*****************************************************************************)

(* Checks whether the repo has a semgrep workflow file already.
 * NOTE: This only checks for the presence of the file, not the contents
 * or version
 *)
let semgrep_workflow_exists ~repo : bool =
  let dir, cmd =
    if Common2.dir_exists repo then
      ( Fpath.to_dir_path Fpath.(v repo),
        Bos.Cmd.(v "gh" % "workflow" % "view" % "semgrep.yml") )
    else
      ( Bos.OS.Dir.current () |> Rresult.R.get_ok,
        Bos.Cmd.(v "gh" % "workflow" % "view" % "semgrep.yml" % "--repo" % repo)
      )
  in
  Logs.debug (fun m -> m "Checking for semgrep workflow from %s" !!dir);
  let res =
    Bos.OS.Dir.with_current dir
      (fun () -> Bos.OS.Cmd.run_out cmd |> Bos.OS.Cmd.to_string)
      ()
  in
  match res with
  | Ok (Ok _) -> true
  | _else_ -> false

(* NOTE: If the repo is not checked out locally,
   we first clone the repo to a temporary directory,
   and then return the path to the cloned repo.
*)
let prep_repo (repo : string) : Fpath.t =
  if Common2.dir_exists repo then Fpath.v repo
  else
    let tmp_dir =
      Filename.concat
        (Filename.get_temp_dir_name ())
        (Printf.sprintf "semgrep_install_ci_%6X" (Random.int 0xFFFFFF))
    in
    mkdir_if_needed tmp_dir;
    clone_repo_to ~repo ~dst:(Fpath.v tmp_dir);
    (* NOTE: when we clone we get a directory with the repo name.
       we need to strip the owner from the repo name if it is present
       and then join the tmp_dir with the repo name to get the full path
    *)
    let repo =
      match String.split_on_char '/' repo with
      | [ _; repo ] -> repo
      | _ -> repo
    in
    Fpath.v (Filename.concat tmp_dir repo)

let write_workflow_file ~git_dir:dir : unit =
  let commit = get_default_branch_in ~dst:dir in
  Logs.debug (fun m -> m "Using '%s' as default branch." commit);
  let res =
    Bos.OS.Dir.with_current dir
      (fun () ->
        Git_wrapper.run_with_worktree ~commit
          ~branch:(Some (get_new_branch ()))
          (fun () ->
            let github_dir = ".github" in
            mkdir_if_needed github_dir;
            let workflow_dir = Filename.concat github_dir "workflows" in
            mkdir_if_needed workflow_dir;
            let file = Filename.concat workflow_dir "semgrep.yml" in
            let oc = open_out_bin file in
            output_string oc (gha_semgrep_ci_workflow ~default_branch:commit);
            close_out oc;
            Logs.info (fun m -> m "Wrote semgrep workflow to %s" file);
            let cwd = Bos.OS.Dir.current () |> Rresult.R.get_ok in
            Logs.info (fun m ->
                m "Preparing to run git operations in dir: %s" !!cwd);
            add_all_to_git ();
            git_commit ();
            git_push ();
            create_pr ~default_branch:commit;
            merge_pr ()))
      ()
  in
  match res with
  | Ok () -> ()
  | _ -> Logs.err (fun m -> m "Failed to write workflow file")

(* Basic Outline:
   0. Check if the workflow file is already present (local or remote)
   1. Write the workflow file to the repo
   2. Commit and push changes to the repo
   3. Open a PR to the repo to merge the changes
*)
let add_semgrep_workflow ~token (conf : Install_CLI.conf) : unit =
  let (repo : string) =
    match conf.repo with
    | Dir v -> Fpath.to_dir_path v |> Fpath.rem_empty_seg |> Fpath.to_string
    | Repository (owner, repo) -> spf "%s/%s" owner repo
  in
  match () with
  | _ when conf.dry_run ->
      Logs.info (fun m -> m "Skipping actual workflow operations for dry-run")
  | _ when semgrep_workflow_exists ~repo && not conf.update ->
      Logs.info (fun m -> m "Semgrep workflow already present, skipping")
  | _else_ ->
      Logs.info (fun m -> m "Preparing Semgrep workflow for %s" repo);
      let dir = prep_repo repo in
      write_workflow_file ~git_dir:dir;
      if semgrep_app_token_secret_exists ~git_dir:dir && not conf.update then
        Logs.info (fun m -> m "Semgrep secret already present, skipping")
      else add_semgrep_gh_secret ~git_dir:dir ~token;
      Logs.info (fun m -> m "Semgrep workflow added to %s" repo)

(*****************************************************************************)
(* Main logic *)
(*****************************************************************************)

let run (conf : Install_CLI.conf) : Exit_code.t =
  CLI_common.setup_logging ~force_color:true ~level:conf.common.logging_level;
  (* In theory, we should use the same --metrics=xxx as in scan,
     but given that this is an experimental command that we need to validate
     in the wild, we are hard-coding the metrics config to On for now. We can
     revisit whether we should even support disabling metrics for this
     command at a later date.
  *)
  Metrics_.configure Metrics_.On;
  Logs.debug (fun m -> m "conf = %s" (Install_CLI.show_conf conf));
  let settings = Semgrep_settings.load () in
  let api_token = settings.Semgrep_settings.api_token in
  match api_token with
  | None ->
      Logs.err (fun m ->
          m
            "%s You are not logged in! Run `semgrep login` before using \
             `semgrep install-ci`"
            (Logs_.err_tag ()));
      Exit_code.fatal
  | Some token ->
      (* setup gh *)
      install_gh_cli_if_needed ();
      prompt_gh_auth_if_needed ();
      set_ssh_as_default ();
      (* let's go! this may raise some errors (catched in CLI.safe_run()) *)
      add_semgrep_workflow ~token conf;
      Logs.app (fun m ->
          m "%s Installed semgrep workflow for this repository"
            (Logs_.success_tag ()));
      Exit_code.ok

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)
let main (argv : string array) : Exit_code.t =
  let conf = Install_CLI.parse_argv argv in
  run conf
