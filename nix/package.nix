# The Bear Cub mix release. Build knowledge lives with the code it builds
# (design §7); the homeassistant repo pins a rev of this repo and imports
# nix/module.nix, which callPackages this file.
{ lib
, beamPackages
, tailwindcss_4
, esbuild
}:

beamPackages.mixRelease rec {
  pname = "bear-cub";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../.;
    filter = path: type:
      let name = baseNameOf path; in
      !(builtins.elem name [ ".git" "_build" "deps" "node_modules" ".dexter" "_work" "docs" ])
      && !(lib.hasSuffix ".db" name)
      && !(lib.hasSuffix ".db-shm" name)
      && !(lib.hasSuffix ".db-wal" name);
  };

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "mix-deps-${pname}";
    inherit src version;
    # TOFU: build once, replace with the "got:" hash nix reports.
    hash = "sha256-kSCaV48LV1f4RJ+LLEiqEuZ0g+H9sJKZi9KAULqasfY=";
  };

  # exqlite (NIF via elixir_make) calls :filename.basedir(:user_cache, ...),
  # which falls back to "$HOME/.cache" and fails when HOME is the sandbox's
  # nonexistent /homeless-shelter. mixRelease already gives us a writable
  # $TEMPDIR for MIX_HOME/HEX_HOME; point HOME there too, before
  # configurePhase's `mix deps.compile` builds the NIF.
  #
  # exqlite must compile its NIF from source in the sandbox — the
  # precompiled-binary download is unreachable on a strict builder.
  # config/config.exs reads this env var and turns it into the
  # `config :exqlite, force_build: true` app env exqlite's mix.exs actually
  # checks (elixir_make has no such env var itself).
  ELIXIR_MAKE_FORCE_BUILD = "1";

  preConfigure = ''
    export HOME="$TEMPDIR"
  '';

  # Build digested assets inside the sandbox with nixpkgs-provided
  # binaries (design §7); config.exs picks the paths up from these
  # env vars. deps.loadpaths first: external tasks need the no-deps-
  # check workaround (phoenixframework/phoenix#2690).
  #
  # Runs in postBuild, not preBuild: mixRelease's default buildPhase is
  # `preBuild; mix compile; postBuild`, and assets.deploy needs the app
  # already compiled (Phoenix.LiveView.ColocatedCSS only writes
  # phoenix-colocated/bear_cub/colocated.css during that compile — running
  # this earlier makes tailwind fail to resolve that import).
  postBuild = ''
    export MIX_TAILWIND_PATH="${lib.getExe tailwindcss_4}"
    export MIX_ESBUILD_PATH="${lib.getExe esbuild}"
    mix do deps.loadpaths --no-deps-check, assets.deploy
  '';

  # Single-node app: no distribution, no cookie management needed.
  removeCookie = false;
}
