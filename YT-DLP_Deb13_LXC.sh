#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.docker.com/

APP="Debian LXC"
var_tags="${var_tags:-debian}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  msg_info "Updating base system"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Base system updated"

  # --- Docker-related update sections have been removed ---

  msg_info "Cleaning up"
  $STD apt-get -y autoremove
  $STD apt-get -y autoclean
  msg_ok "Cleanup complete"
  exit
}

start
build_container
description

msg_info "Installing yt-dlp and all dependencies"
$STD apt-get update
$STD apt-get -y install yt-dlp ffmpeg aria2 python3-pycryptodome python3-mutagen
msg_ok "Installed yt-dlp and all dependencies"

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} container has been successfully initialized!${CL}"
