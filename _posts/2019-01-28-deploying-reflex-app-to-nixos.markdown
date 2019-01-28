---
layout: post
title:  "Deploying a Reflex Application to NixOS"
date:   2019-01-28
categories: reflex nix deployment
---

In the following post I describe how a simple Haskell web application built on top of [Reflex FRP](https://github.com/reflex-frp) can be deployed to a remote [NixOS](https://nixos.org/) server. If a remote NixOS server is available using it for deployment can be cheaper alternative to commercial cloud providers in case the features of those (e.g. scaling, hosted services, availability guarantees, etc.) are not strictly required.

The sample Reflex application can be found [on GitHub](https://github.com/mtesseract/reflex-app).

Our setting is as follows:

* The application, consisting of a frontend and a backend, is built with Nix
* The development system is a Mac (i.e., not `x86_64-linux`)
* The application supports some trivial database access
* The application is to be deployed to a remote server running NixOS (`x86_64-linux`)

## The Application Skeleton

The application is based on the [project skeleton](https://github.com/reflex-frp/reflex-platform/blob/develop/docs/project-development.md) as documented as part of the [Reflex Platform](https://github.com/reflex-frp/reflex-platform). It contains three Cabal projects (`common`, `frontend`, `backend`) and the `reflex-platform` as a Git submodule. Nix expressions are used for building the applications.

In addition, there is a top-level directory [deployment](https://github.com/mtesseract/reflex-app/tree/master/deployment) containing the deployment relevant code.

## Building on macOS for Linux

For deploying we want to transfer a complete build artifact, a Nix closure, to the remote server and activate it. Since the development computer is assumed to be running macOS and the application needs to be built for Linux (`x86_64-linux`), we use Docker and the [nix-docker project](https://github.com/LnL7/nix-docker). The included script `start-docker-nix-build-slave` assists in setting up a Nix remote builder.

The application skeletons needs a [tweak](https://github.com/reflex-frp/reflex-platform/pull/440) to the `default.nix` expression in order to respect the `system` parameter.

## Database Access

Our application server (the system on which the application frontend and backend will be deployed) runs in its own virtual machine managed via [libvirt](https://libvirt.org/). In order to separate the stateless and stateful aspects of the deployment, we set up a dedicated database server VM, i.e. a NixOS server running PostgreSQL. The database server is not directly connected to the internet, instead the database server and the application server are connected via an [internal bridge](https://wiki.libvirt.org/page/Networking#NAT_forwarding_.28aka_.22virtual_networks.22.29).

The NixOS configuration of the database server looks as follows:

```
{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/vda";

  networking = {
    hostName = "db";
    interfaces.ens3.ipv4.addresses = [ { address = "192.168.122.2"; prefixLength = 24; } ];
    nameservers = [ "8.8.8.8" ];
    defaultGateway = "192.168.122.1";
    firewall = {
      allowedTCPPorts = [ 22 5432 ];
      enable = true;
    };
  };

  time.timeZone = "Europe/Berlin";

  environment.systemPackages = with pkgs; [
    vim postgresql100
  ];

  services = {
    ntp = {
      enable = true;
    };
    openssh = {
      enable = true;
    };
    postgresql = {
      enable = true;
      package = pkgs.postgresql100;
      enableTCPIP = true;
      authentication = pkgs.lib.mkOverride 10 ''
        local all all trust
        host all all 192.168.122.0/24 trust
        '';
      initialScript = pkgs.writeText "backend-initScript" ''
        CREATE ROLE app WITH LOGIN PASSWORD 'app' CREATEDB;
        CREATE DATABASE app;
        GRANT ALL PRIVILEGES ON DATABASE app TO app;
      '';
    };
  };
  system.stateVersion = "18.09";
  users.users.root.openssh.authorizedKeys.keys = [ "ssh-rsa ..." ];
  environment.noXlibs = true;
  system.autoUpgrade.enable = true;
}
```

This configuration makes sure that a PostgreSQL role `app` with the same password and database name is initially created.

## Deploying

The Nix expressions needed for deployment together with a small shell script are stored in the directory `deployment/`:

* `pkgs.nix`: Expression pinning a specific version of `nixpkgs` for reproducibility of builds.
* `system.nix`: A complete NixOS system configuration including:
  - a systemd configuration for running the backend application
  - an nginx configuration for exposing the frontend and the backend via HTTPS using Let's Encrypt certificates
* `deploy.nix`: Wrapper for the system configuration using the pinned version of `pkgs.nix`. This expression can be used for building complete system configurations, which can be deployed to a remote server.

In addition the following Nix expressions are expected by this deployment setup:
* `dns.nix`: Containing the DNS entries for the backend and the frontend application. For example:
```
{
  frontend = "app.example";
  backend = "api.example";
}
```
* `network.nix`: The NixOS network configuration of the application server. For example
```
{
  hostName = "dev";
  interfaces = {
    ens3.ipv4.addresses = [ { address = "a.b.c.d"; prefixLength = 28; } ];
    ens9.ipv4.addresses = [ { address = "192.168.122.3"; prefixLength = 24; } ];
  };
  defaultGateway = "a.b.c.d";
  nameservers = [ "8.8.8.8" ];
  firewall.allowedTCPPorts = [ 22 443 ];
  extraHosts = ''
    192.168.122.2 db
  '';
}
```
Of course, the public IP address of the application server and the default gateway need to be filled in here. This configures two network interfaces, one public interface and one internal interface for talking to the database server (`db`).
* `ssh.nix`: List of public SSH keys which can be used for logging into the application server:
```
[ "ssh-rsa ..." ]
```

Having this in place the actual deployment procedure is straight-forward and described in the shell script `deploy.sh`:
```
#!/bin/sh

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <remote ssh>" >&2
    exit 1
fi

REMOTE="$1"
echo "**** Deploying to $1 ****"

nix-build --attr system deploy.nix
artifact=$(readlink result)
nix-copy-closure $REMOTE $artifact
ssh $REMOTE "${artifact}/bin/switch-to-configuration" switch
```

As can be seen, we build the system configuration from `deploy.nix` (using `nix-build --attr system`), then we transfer the closure of the built artifact to the remote system and finally activate it. The shell script expects a remote ssh login as parameter, e.g. `root@app.example`. Credits to Gabriel Gonzales, as this procedure is heavily inspired by his post [NixOS in production](http://www.haskellforall.com/2018/08/nixos-in-production.html).
