#!/usr/bin/env bash
# This file:
#
#  Build Windows installer for Zim Wiki.
#
# Usage:
#
#  LOG_LEVEL=7 ./build.sh 
#
# Copyright (c) 2020 Fabian Stanke
#
# Based on a template by BASH3 Boilerplate v2.4.1
# http://bash3boilerplate.sh/#authors
# Copyright (c) 2013 Kevin van Zonneveld and contributors

# Exit on error. Append "|| true" if you expect an error.
set -o errexit
# Exit on error inside any functions or subshells.
set -o errtrace
# Do not allow use of undefined vars. Use ${VAR:-} to use an undefined VAR
set -o nounset
# Catch the error in case mysqldump fails (but gzip succeeds) in `mysqldump |gzip`
set -o pipefail
# Turn on traces, useful while debugging but commented out by default
# set -o xtrace

# Set magic variables for current file, directory, os, etc.
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"

# Define the environment variables (and their defaults) that this script depends on
LOG_LEVEL="${LOG_LEVEL:-6}" # 7 = debug -> 0 = emergency
NO_COLOR="${NO_COLOR:-}"    # true = disable color. otherwise autodetected

__old_pkg_config_path="${PKG_CONFIG_PATH:-}"
__old_path="${PATH:-}"

### Functions
##############################################################################

function __b3bp_log () {
  local log_level="${1}"
  shift

  # shellcheck disable=SC2034
  local color_debug="\\x1b[35m"
  # shellcheck disable=SC2034
  local color_info="\\x1b[32m"
  # shellcheck disable=SC2034
  local color_error="\\x1b[31m"
  # shellcheck disable=SC2034
  local color_emergency="\\x1b[1;4;5;37;41m"

  local colorvar="color_${log_level}"

  local color="${!colorvar:-${color_error}}"
  local color_reset="\\x1b[0m"

  if [[ "${NO_COLOR:-}" = "true" ]] || { [[ "${TERM:-}" != "xterm"* ]] && [[ "${TERM:-}" != "screen"* ]]; } || [[ ! -t 2 ]]; then
    if [[ "${NO_COLOR:-}" != "false" ]]; then
      # Don't use colors on pipes or non-recognized terminals
      color=""; color_reset=""
    fi
  fi

  # all remaining arguments are to be printed
  local log_line=""

  while IFS=$'\n' read -r log_line; do
    echo -e "$(date -u +"%Y-%m-%d %H:%M:%S UTC") ${color}$(printf "[%9s]" "${log_level}")${color_reset} ${log_line}" 1>&2
  done <<< "${@:-}"
}

function emergency () {                                  __b3bp_log emergency "${@}"; exit 1; }
function error ()     { [[ "${LOG_LEVEL:-0}" -ge 3 ]] && __b3bp_log error "${@}"; true; }
function info ()      { [[ "${LOG_LEVEL:-0}" -ge 6 ]] && __b3bp_log info "${@}"; true; }
function debug ()     { [[ "${LOG_LEVEL:-0}" -ge 7 ]] && __b3bp_log debug "${@}"; true; }

### Signal trapping and backtracing
##############################################################################

function __b3bp_cleanup_before_exit () {
  info "Cleaning up."
  export PKG_CONFIG_PATH="${__old_pkg_config_path}"
  export PATH="${__old_path}"
  info "Done."
}
trap __b3bp_cleanup_before_exit EXIT

# requires `set -o errtrace`
__b3bp_err_report() {
    local error_code=${?}
    error "Error in ${__file} in function ${1} on line ${2}"
    exit ${error_code}
}
# Uncomment the following line for always providing an error backtrace
trap '__b3bp_err_report "${FUNCNAME:-.}" ${LINENO}' ERR


### Build procedure
##############################################################################

__skip_deps=false

while getopts ":hs" opt; do
    case "$opt" in
    h|\?)
        echo "Usage:"
        echo " -s   Skip installing dependencies."
        echo ""
        exit 0
        ;;
    s)  __skip_deps=true
        ;;
    esac
done

if [[ ! "${__skip_deps}" = true ]]; then
  if [[ "$OSTYPE" == "msys" ]] && [[ "${MSYSTEM_CARCH:-}" ]]; then
    info "Installing MSys dependencies ..."

    # Skip font cache update
    export MSYS2_FC_CACHE_SKIP=1

    # Install build dependencies
    pacman --noconfirm -S --needed \
        make \
        unzip \
        mingw-w64-"${MSYSTEM_CARCH}"-gcc \
        mingw-w64-"${MSYSTEM_CARCH}"-gtk3 \
        mingw-w64-"${MSYSTEM_CARCH}"-pkg-config \
        mingw-w64-"${MSYSTEM_CARCH}"-cairo \
        mingw-w64-"${MSYSTEM_CARCH}"-gobject-introspection \
        mingw-w64-"${MSYSTEM_CARCH}"-python \
        mingw-w64-"${MSYSTEM_CARCH}"-python-gobject \
        mingw-w64-"${MSYSTEM_CARCH}"-python-cairo \
        mingw-w64-"${MSYSTEM_CARCH}"-python-xdg \
        mingw-w64-"${MSYSTEM_CARCH}"-gtksourceview3 \
        mingw-w64-"${MSYSTEM_CARCH}"-python-pip \
        mingw-w64-"${MSYSTEM_CARCH}"-nsis
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    hash brew 2>/dev/null || emergency "brew not found; Please install Homebrew first."

    info "Installing dependencies using Homebrew ..."

    brew install \
        pkg-config \
        python@3.8 \
        gtk+3 \
        adwaita-icon-theme  \
        gtksourceview3 \
        pygobject3 \
        librsvg
  fi
fi

info "Checking dependencies ..."

if [[ "$OSTYPE" == "darwin"* ]]; then
  hash /usr/local/opt/python@3.8/bin/python3 2>/dev/null || emergency "Python 3.8 not found."
else
  hash python3 2>/dev/null || emergency "Python 3.x not found. Have you started MSYS2 MinGW 64-bit?"
fi

hash pkg-config 2>/dev/null || emergency "pkg-config not found"
hash sed 2>/dev/null || emergency "sed not found"

pkg-config --print-errors --exists 'gobject-introspection-1.0 >= 1.46.0' >/dev/null 2>&1 || emergency "GObject-Introspection not found, Please check above errors and correct them"

__python_ver="$(python3 --version | sed 's/^Python \([0-9]\.[0-9]\).[0-9]$/\1/')"
[[ "${__python_ver:-}" ]] || emergency "Cannot determine Python version."

info "Preparing virtual environment for Zim ..."

__build_dir=${__dir}/build
__venv_dir=${__build_dir}/venv

rm -rf "${__venv_dir}"
if [[ "$OSTYPE" == "darwin"* ]]; then
  # Currently, the Gtk bindings in Homebrew are linked against Python 3.8
  /usr/local/opt/python@3.8/bin/python3 -m venv --prompt Zim "${__venv_dir}"
else
  python3 -m venv --prompt Zim "${__venv_dir}"
fi

info "Entering virtual environment ..."

# shellcheck source=/dev/null
source "${__venv_dir}/bin/activate"

info "Initializing virtual environment ..."

python -m pip install -U pip
pip install PyGObject xdg pyinstaller

info "Checking virtual environment ..."

check_module() {
  python -c "$1" 2>&- || emergency "$(echo -e "$2\n\nThe Command used to test this:\n\n    >>> $1\n\n")"
}
check_module \
  "import gi" \
  "PyGObject (gobject-introspection) can not be loaded"
check_module \
  "from gi.repository import Gtk" \
  "Gtk3 is not installed in a way it can be loaded in Python"

info "Determining Zim version ..."

__zim_ver=$(cd "${__dir}/.." && python setup.py --version)
[[ "${__zim_ver:-}" ]] || emergency "Cannot determine Zim version."
sed "s/__version__/${__zim_ver}/g" "${__dir}/src/file_version_info.txt.in" > "${__build_dir}/file_version_info.txt"

info "Installing Zim in the virtual environment ..."

(cd "${__dir}/.." && python setup.py -q install)
# Rename launcher to avoid conflict with module
if [[ "$OSTYPE" == "msys" ]]; then
  mv "${__venv_dir}/bin/zim.py" "${__venv_dir}/bin/zim_launch.py"
elif [[ "$OSTYPE" == "darwin"* ]]; then
  mv "${__venv_dir}/bin/zim" "${__venv_dir}/bin/zim_launch.py"
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
  info "Preparing app icon ..."

  __icon_source="${__dir}/../icons/zim48.svg"
  __icon_dir="${__build_dir}/Zim.iconset"
  mkdir -p "${__icon_dir}"

  sizes=(16 32 64 128 256 512)
  for s in "${sizes[@]}"; do
    rsvg-convert -h $((s)) "${__icon_source}" > "${__icon_dir}/icon_${s}x${s}.png"
    rsvg-convert -h $((s*2)) "${__icon_source}" > "${__icon_dir}/icon_${s}x${s}@2x.png"
  done

  iconutil -c icns "${__icon_dir}"
fi

info "Building distribution ..."

__dist_dir="${__dir}/dist/zim"
rm -rf "${__dist_dir}"

# set seed to a known repeatable integer value
PYTHONHASHSEED=1
export PYTHONHASHSEED
(cd "${__dir}" && pyinstaller -y src/zim.spec)
# let Python be unpredictable again
unset PYTHONHASHSEED

if [[ "$OSTYPE" == "msys" ]]; then
  info "Building Windows installer ..."

  (cd "${__dist_dir}" && makensis -NOCD -DVERSION="${__zim_ver}" "${__dir}/src/zim-installer.nsi")

  info "Setup file is at: ${__dist_dir}/zim-desktop-wiki-${__zim_ver}-setup.exe"
fi

info "Finished successfully."
