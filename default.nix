with (import <nixpkgs> {});
let
  ghPagesEnv = bundlerEnv {
    name = "mtesseract-github-pages-env";
    inherit ruby;
    gemdir = ./.;
  };
in
{
  shell = stdenv.mkDerivation {
    name = "mtesseract-github-pages";
    buildInputs = [ ghPagesEnv ];
  };
  serve = stdenv.mkDerivation {
    name = "mtesseract-github-pages-serve";
    buildInputs = [ ghPagesEnv ];
    shellHook = ''
      exec ${ghPagesEnv}/bin/jekyll serve --watch
    '';
  };
}
