#!/bin/sh

set -o errexit
set -o nounset

# Check if running on a CI
CI_WORKSPACE=${CI_WORKSPACE:-}

LOCAL=${CI_WORKSPACE:-/tmp/adm}
PROFILE=${PROFILE:-generic}
REPO="https://git.cleganebowl.io/ddt/adm.git"
TAGS=${TAGS:-all}

check_deps() {
  info "Checking dependencies ---"
  missing_deps=false
  
  command_exists ansible || {
    missing_deps=true
      error "ansible is not installed ---"
  }

  command_exists git || {
    missing_deps=true
      error "git is not installed ---"
  }

  if [ "$missing_deps" = true ]; then
    exit 1
  fi
}

clone_repo() {
  if [ -n "$CI_WORKSPACE" ]; then
    warning "Running on a CI workflow. Skipping cloning ---"
  else
    if [ -d ${LOCAL} ]; then
      info "Old installation found. Deleting ---" 
      rm -rf ${LOCAL}
    fi

    info "Cloning repo into '${LOCAL}' ---"
    mkdir -p $LOCAL
    git clone $REPO $LOCAL
  fi
}

command_exists() {
  command -v "$@" >/dev/null 2>&1  
}

error() {
  echo ${RED}"Error: $@ ---"${RESET} >&2;
}

info() {
  echo ${GREEN}"$@ ---"${RESET}
}

install_deps() {
  info "Installing dependencies ---"
  apt install \
    ansible \
    git \
    -y 
}

run_playbook() { 
  info "Running playbook ---"
  cd $LOCAL
  ansible-playbook \
    --ask-become-pass \
    --diff \
    -i inventory \
    --limit $PROFILE \
    --tags $TAGS \
    ./tasks/base.yml
}

setup_colors() {
  if [ -t 1 ]; then
    GREEN=$(printf '\033[32m')
    RED=$(printf '\033[31m')
    RESET=$(printf '\033[m')
    YELLOW=$(printf '\033[33m')
  else
    GREEN="";
    RED="";
    RESET="";
    YELLOW=""
  fi
}

warning() {
  info ${YELLOW}"Warning: $@ ---"${RESET}
}

main() {
  if ! [ $(id -u) = 0 ]; then
    error "This must be executed by root ---"
    exit 1
  fi
 
  setup_colors

  install_deps
  check_deps
  clone_repo
  run_playbook
}

main "$@"
