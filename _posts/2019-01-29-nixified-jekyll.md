---
layout: post
title:  "Nixified Jekyll setup"
date:   2019-01-29
categories: jekyll nix
---

What I particularly like about Nix is its ability to _encapsulate_ environments. No need to remember how to set up a certain environment, just encode it in a Nix expression, check it into version control and use `nix-shell`. This is especially useful when having to occasionally deal with certain environments, without being too familiar with the technical details. For me one such example is Jekyll, a Ruby application (and I am not familiar with Ruby).

I have created a new Jekyll blog and used [bundix](https://github.com/manveru/bundix) to convert a `Gemfile` into a Nix expression (`gemset.nix`). To this, add the following `default.nix`:

```nix
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
```

This expression contains two attributes: `shell` and `serve`. Thus, `nix-shell -A shell` spawns an interactive shell having Jekyll in path, while `nix-shell -A serve` spawn Jekyll to serve the page at `http://localhost:4000`. For details, check out the [repository](http://github.com/mtesseract/mtesseract.github.io) of this blog.
