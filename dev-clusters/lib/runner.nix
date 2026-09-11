{
  nixpkgs,
  vpsadminos,
  system,
  name,
  runnerLib,
  sharedRunnerLib,
}:
let
  pkgs = import nixpkgs {
    inherit system;
    overlays =
      if vpsadminos ? overlays.all then
        vpsadminos.overlays.all
      else
        throw "Development clusters require vpsAdminOS commit 6f9b2c755 or a compatible newer revision with overlays.all. Update the selected vpsadminos worktree.";
  };
  ruby = pkgs.ruby_vpsadminos;
  deps = pkgs.bundlerEnv {
    name = "devcluster-runner-deps";
    gemfile = vpsadminos.outPath + "/os/packages/test-runner/Gemfile";
    lockfile = vpsadminos.outPath + "/os/packages/test-runner/Gemfile.lock";
    gemset = vpsadminos.outPath + "/os/packages/test-runner/gemset.nix";
    groups = [ "default" ];
    inherit ruby;
    gemConfig = pkgs.vpsadminosRubyGemConfig;
  };
in
pkgs.writeShellScriptBin name ''
  export GEM_HOME=${deps}/${ruby.gemPath}
  export GEM_PATH=${deps}/${ruby.gemPath}
  export RUBYLIB=${runnerLib}:${sharedRunnerLib}:${vpsadminos.outPath}/test-runner/lib:${vpsadminos.outPath}/osvm/lib:${vpsadminos.outPath}/libosctl/lib

  exec ${ruby}/bin/ruby ${runnerLib}/devcluster-runner.rb "$@"
''
