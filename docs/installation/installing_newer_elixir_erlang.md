# Installing newer versions of Elixir and Erlang

This guide is for installing newer versions of Elixir and/or Erlang on your system when installing Pleroma from source and your operating system repositories don't meet the minimum requirements listed below.
This guide assumes you are using Debian or Ubuntu.
**Using the system repositories is recommended if possible.**
**If a newer release of your operating system would meet the requirements, consider upgrading instead.**

Shell commands prepended with `#` in this page are supposed to be ran with root privileges, commands prepended with `$` are supposed to be ran as the Pleroma user unless noted otherwise.

!!!warning
    If you are, or will be, following the source install guide, make sure to switch to the Pleroma user before running any of the `mix` commands using `sudo -Hu pleroma /bin/bash`.
    Not doing so will result in `command not found` errors.

!!!info
    Most of this guide can be used to install Elixir and/or Erlang on operating systems that don't package either one.
    Installing Pleroma on such systems is largely untested.

## Requirements

{! backend/installation/erlang_elixir_requirements.include !}

Choose one of the following install methods:

## Install methods

* User level:
    * mise (Erlang and Elixir install methods are built-in; downloads binaries both for Elixir and Erlang)
    * asdf (plugin-based, plugins are shells scripts; builds Erlang from source)
    * pkgsrc (for advanced users, harder to install and maintain; builds Elixir and Erlang from source)
* System-wide:
    * pkgsrc (for advanced users, harder to install and maintain; builds Elixir and Erlang from source)

!!!warning
    **Ignore if using mise.**  
    You are about to compile Erlang on your server.
    If you are planning to run Pleroma on a VPS virtual machine, make sure you have enough disk space and system resources available.
    At least 2GB of RAM and 8GB of extra free disk space is required to continue in this guide.
    If your system does not meet these requirements, use [OTP install](./otp_en.md).  
    **This will take a considerable amount of time.**

!!!warning
    Before proceeding, stop Pleroma if already running and uninstall both Elixir and Erlang.
    Keeping Elixir will likely result in a non-functional Elixir install and keeping Erlang can result in various failures to compile Pleroma and its dependencies.

## mise

To start, create the Pleroma user according to the [source install guide](./debian_based_en.md#install-pleromabe) and switch to the user using `sudo -Hu pleroma /bin/bash`.
Then follow the install steps from mise documentation and install it for the user Pleroma: [https://mise.jdx.dev/getting-started.html](https://mise.jdx.dev/getting-started.html)

Add the following to activate mise in the Pleroma user's shell configuration (`.bashrc` for bash):
```sh
# Modify to match the mise installation location
eval "$($HOME/.local/bin/mise activate bash)"
```

Source new profile settings:
```sh
$ source ~/.bashrc
```

If installing Pleroma, follow the [Pleroma source installation instructions](./debian_based_en.md) up to the point before downloading mix dependencies for Pleroma, ignoring the instructions to download Elixir/Erlang.

Install Erlang (replace `<version>` with a supported release meeting Pleroma's requirements, OTP 27 is recommended):
```sh
$ mise install erlang@<version>
```

!!!info
    To get a list of available versions, use `mise ls-remote <language/tool>`.

Then run the following in the Pleroma source code repository:
```sh
$ mise use erlang@<version>
```

Install Elixir (replace `<version>` with a supported release and `<OTP version>` with the mise-installed Erlang/OTP version, Elixir 1.18 is recommended):
```sh
$ mise install elixir@<version>-otp-<OTP version>
```

Then run the following in the Pleroma source code directory:
```sh
$ mise use elixir@<Elixir version>
```

If installing Pleroma, continue with the source install guide up to the point of installing the systemd Pleroma service.
Don't attempt to start the Pleroma service yet.

Create a `pleroma.sh` startup script owned by the Pleroma user in Pleroma user's home directory:
```sh
#!/bin/bash
# Modify to match the mise installation location
eval "$($HOME/.local/bin/mise activate bash)"

exec mix phx.server
```

Make the startup script executable:
```sh
chmod u+x pleroma.sh
```

Override the Pleroma service file to point to the new start up script, run `# systemctl edit pleroma` and add the following:
```ini
[Service]
ExecStart=
ExecStart=/var/lib/pleroma/pleroma.sh
```

You can now start the Pleroma service.
If you are installing Pleroma, continue with creating your first user according to the install guide.

## asdf

To start, create the Pleroma user according to the [source install guide](./debian_based_en.md#install-pleromabe) and switch to the user using `sudo -Hu pleroma /bin/bash`.
Then follow the install and configure steps from asdf documentation and install it for the user Pleroma: [https://asdf-vm.com/guide/getting-started.html](https://asdf-vm.com/guide/getting-started.html)

Install dependencies:
```
# apt install build-essential libssl-dev libncurses-dev git unzip
```

Add Erlang autotools configure options to Pleroma user's shell config (`.bashrc` for bash):
```sh
export KERL_CONFIGURE_OPTIONS="--without-javac --without-odbc --without-wx --without-ssh"
```

Source new profile settings:
```sh
$ source ~/.bashrc
```

Install the Erlang plugin:
```sh
$ asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
```

Build and install Erlang (replace `<version>` with a supported release meeting Pleroma's requirements, OTP 27 is recommended):
```sh
$ asdf install erlang <version>
```

!!!info
    To get a list of available versions, use `asdf list all <plugin>`.

Install the Elixir plugin:
```sh
$ asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
```

Install Elixir (replace `<version>` with a supported release and `<OTP version>` with the asdf-installed Erlang/OTP version, Elixir 1.18 is recommended):
```sh
$ asdf install elixir <version>-otp-<OTP version>
```

If installing Pleroma, follow the [Pleroma source installation instructions](./debian_based_en.md) up to the point before downloading mix dependencies for Pleroma, ignoring the instructions to download Elixir/Erlang.

Then run the following in the Pleroma source code directory:
```sh
$ asdf set erlang <OTP version>
$ asdf set elixir <Elixir version>
```

If installing Pleroma, continue with the source install guide up to the point of installing the systemd Pleroma service.
Don't attempt to start the Pleroma service yet.

Create a `pleroma.sh` startup script owned by the Pleroma user in Pleroma user's home directory:
```sh
#!/bin/sh
# Modify to match your .bashrc settings used when installing asdf
export ASDF_DATA_DIR="/your/custom/data/dir"
export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"

exec mix phx.server
```

Make the startup script executable:
```sh
chmod u+x pleroma.sh
```

Override the Pleroma service file to point to the new start up script, run `# systemctl edit pleroma` and add the following:
```ini
[Service]
ExecStart=
ExecStart=/var/lib/pleroma/pleroma.sh
```

You can now start the Pleroma service.
If you are installing Pleroma, continue with creating your first user according to the install guide.

## pkgsrc

pkgsrc is NetBSD's portable package building framework also supporting Linux.
Its use is discouraged for novice users as it is harder to maintain and keep up-to-date compared to other options in this guide.

Before installing pkgsrc, choose which install method (tarball or CVS) you want to use.
Both update differently and have their caveats, check NetBSD documentation for more info: [https://www.netbsd.org/docs/pkgsrc/getting.html#uptodate](https://www.netbsd.org/docs/pkgsrc/getting.html#uptodate)  
Using the stable branch is recommended.

!!!warning
    For CVS install, `cvs` might not be installed on your system, in which case it can be installed with `# apt install cvs`.

pkgsrc supports both user-level and system-wide package installation, hence why most commands below don't have a `#`/`$` prepended to them.
For user-level installs, use the Pleroma user created in the [source install guide](./debian_based_en.md#install-pleromabe).  
To start, follow the `quickstart -> install source packages` portion of the guide to acquire pkgsrc: [https://pkgsrc.org](https://pkgsrc.org)

### Bootstrap

Install build dependencies for bootstrap:
```
# apt install build-essential
```

For user-level installation run:
```sh
$ cd pkgsrc/bootstrap
$ ./bootstrap --prefer-pkgsrc yes --unprivileged --make-jobs <number of CPU cores - 1>
```

For system-wide installation run:
```
# cd pkgsrc/bootstrap
# ./bootstrap --prefer-pkgsrc yes --make-jobs <number of CPU cores - 1>
```

!!!info
    For more bootstrap options, run `./bootstrap --help`

Add pgksrc packages to `$PATH` in shell configuration (`.bashrc` for bash), default prefix is `$HOME/pkg` for user-level install and `/usr/pkg` for system-wide install:
```sh
export PATH="$PATH:<prefix for pkgsrc install>/bin"
```

Source new profile settings:
```sh
source ~/.bashrc
```

!!!info
    For system-wide installs, both the root user and Pleroma user need to have the `PATH` set accordingly.

### Package installation

Erlang:
```sh
cd pkgsrc/lang/erlang
bmake install clean
```

Elixir:
```sh
cd ../elixir
bmake install clean
```

### Pleroma startup script

If installing Pleroma, first follow the [Pleroma source installation instructions](./debian_based_en.md) up to the point of installing the systemd Pleroma service, ignoring the instruction to install Elixir/Erlang. Don't attempt to start the service yet.

Create a `pleroma.sh` startup script owned by the Pleroma user in Pleroma user's home directory:
```sh
#!/bin/sh
# Modify to match your .bashrc settings used when bootsrapping pkgsrc
export PATH="$PATH:<prefix for pkgsrc install>/bin"

exec mix phx.server
```

Make the startup script executable:
```sh
chmod u+x pleroma.sh
```

Override the Pleroma service file to point to the new start up script, run `# systemctl edit pleroma` and add the following:
```ini
[Service]
ExecStart=
ExecStart=/var/lib/pleroma/pleroma.sh
```

You can now start the Pleroma service.
If you are installing Pleroma, continue with creating your first user according to the install guide.

## Maintenance

Since Elixir and Erlang is no longer managed by the system package manager after following this guide, it is recommended to periodically check their respective websites/repositories for newer versions with security bug fixes.
When updating Elixir, Erlang or both, stop Pleroma before proceeding with the update.

Pleroma will likely need to be recompiled after the update by running the following command in the Pleroma source code directory as the Pleroma user:
```sh
MIX_ENV=prod mix compile
```

If Pleroma fails to compile or start after upgrading Elixir/Erlang, run the following as a troubleshooting step in the Pleroma source code directory as the Pleroma user:
```sh
mix clean
mix deps.clean --all
mix deps.get
MIX_ENV=prod mix compile
```

Then try to start Pleroma again. If that doesn't help, join the Matrix room or IRC channel mentioned below, or make an issue on [git.pleroma.social/pleroma/pleroma](https://git.pleroma.social/pleroma/pleroma/issues/new/choose) explaining the problem.

## Questions

Questions about the guide or it didn’t work as it should, ask in [#pleroma:libera.chat](https://matrix.to/#/#pleroma:libera.chat) via Matrix or **#pleroma** on **libera.chat** via IRC.

<!-- vim ts=4:sw=4 -->
