#! /bin/sh

set -e

git submodule update --init --recursive

if ! test -f .venv/pyvenv.cfg; then
    python3 -m venv .venv
fi

source .venv/bin/activate

pip install -r kubespray/requirements.txt
