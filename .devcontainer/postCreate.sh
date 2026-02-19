#!/usr/bin/env bash
set -euo pipefail

if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

fix_yarn_repo_key() {
  local yarn_list="/etc/apt/sources.list.d/yarn.list"
  local yarn_keyring="/usr/share/keyrings/yarn-archive-keyring.gpg"

  if [ ! -f "${yarn_list}" ] || ! grep -q "dl.yarnpkg.com/debian" "${yarn_list}"; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
    return 1
  fi

  echo "detected yarn apt source, refreshing yarn keyring."
  if curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg | ${SUDO} gpg --dearmor --batch --yes -o "${yarn_keyring}"; then
    ${SUDO} chmod a+r "${yarn_keyring}" || true
    echo "yarn keyring refreshed."
    return 0
  fi

  echo "warning: failed to refresh yarn keyring."
  return 1
}

disable_yarn_repo() {
  local yarn_list="/etc/apt/sources.list.d/yarn.list"
  local disabled_yarn_list="${yarn_list}.disabled-by-postcreate"

  if [ ! -f "${yarn_list}" ] || ! grep -q "dl.yarnpkg.com/debian" "${yarn_list}"; then
    return 1
  fi
  if [ -f "${disabled_yarn_list}" ]; then
    return 1
  fi

  if ${SUDO} mv "${yarn_list}" "${disabled_yarn_list}"; then
    echo "warning: disabled invalid yarn apt source: ${yarn_list}"
    echo "warning: restore it manually after fixing key/import if yarn is needed."
    return 0
  fi

  echo "warning: failed to disable yarn apt source: ${yarn_list}"
  return 1
}

apt_update_with_recovery() {
  if ${SUDO} apt-get update; then
    return 0
  fi

  echo "warning: apt-get update failed, trying recovery steps."
  if fix_yarn_repo_key && ${SUDO} apt-get update; then
    return 0
  fi
  if disable_yarn_repo && ${SUDO} apt-get update; then
    return 0
  fi

  echo "error: apt-get update failed after recovery attempts."
  return 1
}

ensure_docker_socket_access_now() {
  local socket_path="$1"
  local current_user="$2"
  local current_gid
  local current_group
  current_gid="$(id -g "${current_user}")"
  current_group="$(id -gn "${current_user}")"

  if docker version >/dev/null 2>&1; then
    echo "docker daemon is already reachable in current shell."
    return 0
  fi

  if ${SUDO} chgrp "${current_gid}" "${socket_path}" && ${SUDO} chmod g+rw "${socket_path}"; then
    echo "adjusted ${socket_path} group to ${current_group} (gid=${current_gid}) for immediate access."
    return 0
  fi

  echo "warning: failed to adjust ${socket_path} group/permissions for immediate access."
  return 1
}

install_docker_cli() {
  if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
    echo "docker cli and buildx already installed, skip install."
    return
  fi

  apt_update_with_recovery
  ${SUDO} apt-get install -y ca-certificates curl gnupg

  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt_update_with_recovery
  ${SUDO} apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin
}

configure_docker_socket_group() {
  local socket_path="/var/run/docker.sock"
  local current_user
  current_user="${USER:-$(id -un)}"

  if [ ! -S "${socket_path}" ]; then
    echo "warning: ${socket_path} not found, skip group configuration."
    return
  fi

  local socket_gid
  socket_gid="$(stat -c '%g' "${socket_path}")"

  if [ "${socket_gid}" = "0" ]; then
    echo "warning: docker socket maps to root group (gid=0)."
    echo "warning: trying immediate socket permission fix for current user ${current_user}."
    if ensure_docker_socket_access_now "${socket_path}" "${current_user}"; then
      return 0
    fi
    echo "warning: fallback to group-based setup, session refresh may still be required."
  fi

  local group_name
  group_name="$(getent group "${socket_gid}" | cut -d: -f1 || true)"
  if [ -z "${group_name}" ]; then
    group_name="docker-host"
    if getent group "${group_name}" >/dev/null 2>&1; then
      group_name="docker-host-${socket_gid}"
    fi
    if ! ${SUDO} groupadd --gid "${socket_gid}" "${group_name}"; then
      echo "error: failed to create group ${group_name} with gid ${socket_gid}."
      echo "check sudo permissions and whether gid ${socket_gid} is already used."
      return 1
    fi
  fi

  if ! id -nG "${current_user}" | tr ' ' '\n' | grep -qx "${group_name}"; then
    if [ "${group_name}" = "root" ]; then
      echo "warning: adding ${current_user} to root group grants elevated privileges."
    fi
    if ! ${SUDO} usermod -aG "${group_name}" "${current_user}"; then
      echo "error: failed to add ${current_user} to group ${group_name}."
      echo "check sudo permissions and /etc/group write access."
      return 1
    fi
    echo "added ${current_user} to group ${group_name}."
    echo "reopen terminal or rebuild container to refresh group membership."
  else
    echo "${current_user} is already in group ${group_name}, skip usermod."
  fi
}

run_existing_bootstrap() {
  go version
  node --version
  if npm install -g ccman @openai/codex; then
    echo "global npm tools installed: ccman, @openai/codex."
  else
    echo "warning: failed to install global npm tools."
    echo "you can retry manually: npm install -g ccman @openai/codex"
  fi
}

validate_docker_tools() {
  docker --version
  docker buildx version || true

  if docker version >/dev/null 2>&1; then
    echo "docker daemon connectivity check passed."
  else
    echo "warning: cannot access docker daemon in current shell yet."
    echo "check whether /var/run/docker.sock is mounted and host docker daemon is running."
    echo "if group membership was updated, reopen terminal or rebuild container and run: docker version"
  fi
}

install_docker_cli
configure_docker_socket_group
run_existing_bootstrap
validate_docker_tools
