#!/usr/bin/env bash
# 批量添加 IPv4 地址：NetworkManager、Netplan、ifupdown 或 RHEL/CentOS network-scripts
set -o pipefail

err() { printf '错误：%s\n' "$*" >&2; }

ensure_mtr() {
  local mtr_bin
  local -a sudo_cmd=()
  mtr_bin=$(command -v mtr 2>/dev/null || command -v mtr-tiny 2>/dev/null || true)
  [[ -n $mtr_bin ]] && return 0

  if ((EUID != 0)); then
    if command -v sudo >/dev/null 2>&1; then sudo_cmd=(sudo)
    else err '自动安装 MTR 需要 root 或 sudo 权限。'; return 1
    fi
  fi

  echo '未检测到 MTR，正在根据系统自动安装…'
  if command -v dnf >/dev/null 2>&1; then
    "${sudo_cmd[@]}" dnf install -y mtr || return 1
  elif command -v yum >/dev/null 2>&1; then
    "${sudo_cmd[@]}" yum install -y mtr || return 1
  elif command -v apt-get >/dev/null 2>&1; then
    "${sudo_cmd[@]}" apt-get update && "${sudo_cmd[@]}" apt-get install -y mtr-tiny || return 1
  elif command -v apk >/dev/null 2>&1; then
    "${sudo_cmd[@]}" apk add --no-cache mtr || return 1
  else
    err '未识别到支持的包管理器（dnf/yum/apt-get/apk），无法自动安装 MTR。'; return 1
  fi

  mtr_bin=$(command -v mtr 2>/dev/null || command -v mtr-tiny 2>/dev/null || true)
  if [[ -z $mtr_bin ]]; then err '安装命令已结束，但仍找不到 mtr 可执行文件。'; return 1; fi
  return 0
}

route_test() {
  local mtr_bin target carrier route_data ip_line label_line index
  ensure_mtr || return 1
  mtr_bin=$(command -v mtr 2>/dev/null || command -v mtr-tiny 2>/dev/null || true)

  route_data=''
  if command -v curl >/dev/null 2>&1; then
    route_data=$(curl -fsSL --connect-timeout 5 --max-time 15 \
      https://raw.githubusercontent.com/zhucaidan/mtr_trace/main/mtr_trace.sh 2>/dev/null || true)
  elif command -v wget >/dev/null 2>&1; then
    route_data=$(wget -qO- --timeout=15 \
      https://raw.githubusercontent.com/zhucaidan/mtr_trace/main/mtr_trace.sh 2>/dev/null || true)
  fi

  ip_line=$(printf '%s\n' "$route_data" | sed -nE 's/^[[:space:]]*iplise=\(([^)]*)\).*/\1/p' | head -n 1)
  label_line=$(printf '%s\n' "$route_data" | sed -nE 's/^[[:space:]]*iplocal=\(([^)]*)\).*/\1/p' | head -n 1)
  route_targets=()
  route_labels=()
  if [[ -n $ip_line && -n $label_line ]]; then
    read -r -a route_targets <<< "$ip_line"
    read -r -a route_labels <<< "$label_line"
  fi

  valid_list=1
  if ((${#route_targets[@]} == 0 || ${#route_targets[@]} != ${#route_labels[@]})); then
    valid_list=0
  else
    for target in "${route_targets[@]}"; do
      if ! awk -v ip="$target" 'BEGIN {n=split(ip,a,"."); if(n!=4) exit 1; for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]<0 || a[i]>255) exit 1}' ; then
        valid_list=0; break
      fi
    done
  fi
  if ((valid_list == 0)); then
    echo '未能读取有效的在线节点清单，改用内置备用节点。'
    route_targets=(58.60.188.222 210.21.196.6 120.196.165.24)
    route_labels=(深圳电信 深圳联通 深圳移动)
  else
    printf '已从维护中的节点清单获取 %s 个测试目标。\n' "${#route_targets[@]}"
  fi

  printf '服务器 → 中国大陆三网节点路由检测（IPv4 / ICMP MTR）\n'
  printf '每个目标探测 5 次；节点不可达或限制 ICMP 时，部分跳数可能显示为 *。\n\n'
  printf '此方向的结果通常用于查看服务器回大陆方向。大陆用户 → 服务器的去程，需要大陆侧探测节点，不能由本机单向测出。\n\n'
  for index in "${!route_targets[@]}"; do
    carrier=${route_labels[$index]}
    target=${route_targets[$index]}
    printf '\n========== %s（%s）==========\n' "$carrier" "$target"
    "$mtr_bin" -4 -r -w -n -c 5 "$target"
  done
}

switch_mirrors() {
  if ((EUID != 0)); then err '切换软件源需要 root 权限。'; return 1; fi
  local distro version provider mirror_host backup stamp file tmp changed=0 matched=0
  local apt_main_root='' apt_security_root='' apt_ports_root='' apt_codename='' apt_arch='' candidate name main_root security_root ports_root suite
  if [[ -r /etc/os-release ]]; then . /etc/os-release; else err '无法识别系统版本。'; return 1; fi
  distro=${ID:-}; version=${VERSION_ID:-}
  case "$distro" in
    centos|rhel|rocky|almalinux|ol|anolis) ;;
    ubuntu|debian) ;;
    *) err "暂不支持自动切换 $PRETTY_NAME 的软件源。"; return 1 ;;
  esac
  printf '检测到系统：%s %s\n' "$distro" "$version"
  if [[ $distro == ubuntu || $distro == debian ]]; then
    printf '1. 自动检测可用镜像（推荐）\n2. 阿里云\n3. 腾讯云\n4. 中科大\n5. 清华大学\nq. 返回\n'
    read -r -p '请选择 [1-5/q]: ' provider || return 0
    apt_codename=${VERSION_CODENAME:-}
    if [[ -z $apt_codename ]]; then apt_codename=$(awk -F= '$1=="VERSION_CODENAME" {gsub(/"/, "", $2); print $2}' /etc/os-release); fi
    [[ -n $apt_codename ]] || { err '无法读取发行版代号，不能探测匹配的软件源。'; return 1; }
    apt_arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    if [[ $distro == ubuntu && $apt_arch != amd64 && $apt_arch != i386 ]]; then
      apt_ports_root=true
    else
      apt_ports_root=false
    fi
    case "$provider" in
      1|2|3|4|5) ;;
      q|Q) return 0 ;;
      *) err '选项无效。'; return 1 ;;
    esac
    case "$provider" in
      1)
        if [[ $distro == debian ]]; then
          candidates=(
            '阿里云|https://mirrors.aliyun.com/debian|https://mirrors.aliyun.com/debian-security'
            '腾讯云|https://mirrors.cloud.tencent.com/debian|https://mirrors.cloud.tencent.com/debian-security'
            '中科大|https://mirrors.ustc.edu.cn/debian|https://mirrors.ustc.edu.cn/debian-security'
            '清华大学|https://mirrors.tuna.tsinghua.edu.cn/debian|https://mirrors.tuna.tsinghua.edu.cn/debian-security'
            'Debian 官方|https://deb.debian.org/debian|https://security.debian.org/debian-security'
          )
        else
          if [[ $apt_ports_root == true ]]; then
            candidates=(
              '阿里云|https://mirrors.aliyun.com/ubuntu-ports|https://mirrors.aliyun.com/ubuntu-ports'
              '腾讯云|https://mirrors.cloud.tencent.com/ubuntu-ports|https://mirrors.cloud.tencent.com/ubuntu-ports'
              '中科大|https://mirrors.ustc.edu.cn/ubuntu-ports|https://mirrors.ustc.edu.cn/ubuntu-ports'
              '清华大学|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports'
              'Ubuntu 官方|https://ports.ubuntu.com/ubuntu-ports|https://ports.ubuntu.com/ubuntu-ports'
            )
          else
            candidates=(
              '阿里云|https://mirrors.aliyun.com/ubuntu|https://mirrors.aliyun.com/ubuntu'
              '腾讯云|https://mirrors.cloud.tencent.com/ubuntu|https://mirrors.cloud.tencent.com/ubuntu'
              '中科大|https://mirrors.ustc.edu.cn/ubuntu|https://mirrors.ustc.edu.cn/ubuntu'
              '清华大学|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu'
              'Ubuntu 官方|https://archive.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu'
            )
          fi
        fi
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then err '自动探测需要 curl 或 wget。'; return 1; fi
        found_mirror=0
        for candidate in "${candidates[@]}"; do
          IFS='|' read -r name main_root security_root <<< "$candidate"
          mirror_ok=1
          for suite in "$apt_codename" "${apt_codename}-updates"; do
            probe_url="$main_root/dists/$suite/InRelease"
            if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 5 --max-time 12 "$probe_url" -o /dev/null >/dev/null 2>&1 || mirror_ok=0
            else wget -q --spider -T 12 "$probe_url" >/dev/null 2>&1 || mirror_ok=0; fi
          done
          if [[ $distro == debian ]]; then probe_url="$security_root/dists/${apt_codename}-security/InRelease"
          else probe_url="$security_root/dists/${apt_codename}-security/InRelease"; fi
          if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 5 --max-time 12 "$probe_url" -o /dev/null >/dev/null 2>&1 || mirror_ok=0
          else wget -q --spider -T 12 "$probe_url" >/dev/null 2>&1 || mirror_ok=0; fi
          if ((mirror_ok)); then found_mirror=1; break; fi
          printf '  %s：仓库索引不可达，继续检查下一个候选源。\n' "$name"
        done
        ((found_mirror)) || { err '候选镜像均未通过索引连通性检查，源配置未修改。'; return 1; }
        printf '自动选择可用镜像：%s\n' "$name"
        apt_main_root=$main_root; apt_security_root=$security_root
        if [[ $distro == ubuntu ]]; then apt_ports_root=$main_root; fi
        mirror_host=$name
        ;;
      2) name=阿里云; apt_main_root=https://mirrors.aliyun.com/debian; apt_security_root=https://mirrors.aliyun.com/debian-security; apt_ports_root=https://mirrors.aliyun.com/ubuntu-ports; mirror_host=mirrors.aliyun.com ;;
      3) name=腾讯云; apt_main_root=https://mirrors.cloud.tencent.com/debian; apt_security_root=https://mirrors.cloud.tencent.com/debian-security; apt_ports_root=https://mirrors.cloud.tencent.com/ubuntu-ports; mirror_host=mirrors.cloud.tencent.com ;;
      4) name=中科大; apt_main_root=https://mirrors.ustc.edu.cn/debian; apt_security_root=https://mirrors.ustc.edu.cn/debian-security; apt_ports_root=https://mirrors.ustc.edu.cn/ubuntu-ports; mirror_host=mirrors.ustc.edu.cn ;;
      5) name=清华大学; apt_main_root=https://mirrors.tuna.tsinghua.edu.cn/debian; apt_security_root=https://mirrors.tuna.tsinghua.edu.cn/debian-security; apt_ports_root=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports; mirror_host=mirrors.tuna.tsinghua.edu.cn ;;
    esac
    if [[ $distro == ubuntu ]]; then
      if [[ $apt_ports_root == true ]]; then apt_main_root=$apt_ports_root; apt_security_root=$apt_ports_root; fi
      if [[ $apt_ports_root != true && $apt_ports_root != https://* ]]; then apt_ports_root=$apt_main_root; fi
      # Provider roots for Ubuntu point to the same archive endpoint.
      if [[ $provider != 1 ]]; then apt_main_root=${apt_main_root/debian/ubuntu}; apt_security_root=$apt_main_root; fi
      if [[ $apt_ports_root != https://* ]]; then apt_ports_root=${apt_main_root%/ubuntu}/ubuntu-ports; fi
    fi
  else
    printf '1. 阿里云镜像\n2. 腾讯云镜像\nq. 返回\n'
    read -r -p '请选择镜像 [1-2/q]: ' provider || return 0
    case "$provider" in
      1) mirror_host=mirrors.aliyun.com ;;
      2) mirror_host=mirrors.cloud.tencent.com ;;
      q|Q) return 0 ;;
      *) err '选项无效。'; return 1 ;;
    esac
  fi

  stamp=$(date +%Y%m%d%H%M%S)
  backup="/root/peachtools-sources-backup-$stamp"
  mkdir -m 700 -p "$backup" || { err '无法创建源配置备份目录。'; return 1; }
  if [[ $distro == ubuntu || $distro == debian ]]; then
    command -v apt-get >/dev/null 2>&1 || { err '找不到 apt-get。'; return 1; }
    mkdir -p "$backup/apt"
    [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$backup/apt/"
    [[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$backup/apt/"
    # Replace only standard Ubuntu/Debian archive hosts; third-party repositories remain untouched.
    local -a aptfiles=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
    for file in "${aptfiles[@]}"; do
      [[ -f $file ]] || continue
      if [[ $distro == ubuntu ]]; then
        grep -Eq 'archive\.ubuntu\.com/ubuntu|security\.ubuntu\.com/ubuntu|ports\.ubuntu\.com/ubuntu-ports|mirrors\.(aliyun\.com|cloud\.tencent\.com|tencent\.com|ustc\.edu\.cn|tuna\.tsinghua\.edu\.cn)/ubuntu(-ports)?' "$file" || continue
      else
        grep -Eq '(deb|security|ftp)\.debian\.org/debian|mirrors\.(aliyun\.com|cloud\.tencent\.com|tencent\.com|ustc\.edu\.cn|tuna\.tsinghua\.edu\.cn)/debian(-security)?' "$file" || continue
      fi
      ((matched+=1))
      tmp=$(mktemp "${file}.peachtools.XXXXXX") || return 1
      cp -p "$file" "$tmp" || { rm -f "$tmp"; return 1; }
      if [[ $distro == ubuntu ]]; then
        if [[ $mirror_host == mirrors.aliyun.com ]]; then
          sed -i -E "s#https?://(archive|security)\\.ubuntu\\.com/ubuntu#${apt_main_root}#g; s#https?://ports\\.ubuntu\\.com/ubuntu-ports#${apt_ports_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/ubuntu-ports#${apt_ports_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/ubuntu#${apt_main_root}#g" "$tmp"
        else
          sed -i -E "s#https?://(archive|security)\\.ubuntu\\.com/ubuntu#${apt_main_root}#g; s#https?://ports\\.ubuntu\\.com/ubuntu-ports#${apt_ports_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/ubuntu-ports#${apt_ports_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/ubuntu#${apt_main_root}#g" "$tmp"
        fi
      else
        if [[ $mirror_host == mirrors.aliyun.com ]]; then
          sed -i -E "s#https?://(deb|security|ftp)\\.debian\\.org/debian-security#${apt_security_root}#g; s#https?://(deb|security|ftp)\\.debian\\.org/debian#${apt_main_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/debian-security#${apt_security_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/debian#${apt_main_root}#g" "$tmp"
        else
          sed -i -E "s#https?://(deb|security|ftp)\\.debian\\.org/debian-security#${apt_security_root}#g; s#https?://(deb|security|ftp)\\.debian\\.org/debian#${apt_main_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/debian-security#${apt_security_root}#g; s#https?://mirrors\\.(aliyun\\.com|cloud\\.tencent\\.com|tencent\\.com|ustc\\.edu\\.cn|tuna\\.tsinghua\\.edu\\.cn)/debian#${apt_main_root}#g" "$tmp"
        fi
      fi
      if ! cmp -s "$file" "$tmp"; then mv -f "$tmp" "$file" || return 1; ((changed+=1)); else rm -f "$tmp"; fi
    done
    # Fresh Debian/Ubuntu installs can contain only a CD-ROM source and no
    # internet repository. In that case, disable CD-ROM entries and add a
    # normal network source instead of treating the absence as an error.
    if ((matched == 0)); then
      local added_file=/etc/apt/sources.list
      for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [[ -f $file ]] || continue
        grep -Eiq '^[[:space:]]*deb(-src)?[[:space:]]+cdrom:' "$file" || continue
        tmp=$(mktemp "${file}.peachtools.XXXXXX") || return 1
        cp -p "$file" "$tmp" || { rm -f "$tmp"; return 1; }
        sed -i -E 's#^([[:space:]]*deb(-src)?[[:space:]]+cdrom:)#\# Disabled by Peach Tools (CD-ROM source): \1#I' "$tmp"
        if ! cmp -s "$file" "$tmp"; then mv -f "$tmp" "$file" || return 1; ((changed+=1)); else rm -f "$tmp"; fi
      done
      tmp=$(mktemp "${added_file}.peachtools.XXXXXX") || return 1
      if [[ -f $added_file ]]; then cp -p "$added_file" "$tmp" || { rm -f "$tmp"; return 1; }
      else chmod 644 "$tmp"; fi
      if [[ $distro == debian ]]; then
        if [[ ${version%%.*} -ge 12 ]]; then components='main contrib non-free non-free-firmware'; else components='main contrib non-free'; fi
      else components='main restricted universe multiverse'; fi
      {
        printf '\n# Peach Tools: detected usable network mirror\n'
        printf 'deb %s %s %s\n' "$apt_main_root" "$apt_codename" "$components"
        printf 'deb %s %s-updates %s\n' "$apt_main_root" "$apt_codename" "$components"
        printf 'deb %s %s-security %s\n' "$apt_security_root" "$apt_codename" "$components"
      } >> "$tmp"
      mv -f "$tmp" "$added_file" || { rm -f "$tmp"; err '新增网络软件源配置失败。'; return 1; }
      ((changed+=1))
      echo "未发现现有网络源，已新增：$added_file"
    fi
    if ((changed == 0 && matched > 0)); then
      echo '源配置已指向所选镜像，文件无需修改。'
      if apt-get update; then echo '完成：APT 软件包索引已刷新。'; else err 'apt-get update 失败，源配置未改动。'; return 1; fi
      return 0
    fi
    if ((changed == 0)); then err '没有找到可识别的 Ubuntu/Debian 官方或常见镜像源条目，配置未改动。'; return 1; fi
    echo "已备份原配置：$backup"
    if apt-get update; then echo '完成：APT 官方软件源已切换并刷新索引。'; else
      cp -a "$backup/apt/sources.list" /etc/apt/sources.list 2>/dev/null || true
      if [[ -d $backup/apt/sources.list.d ]]; then rm -rf /etc/apt/sources.list.d; cp -a "$backup/apt/sources.list.d" /etc/apt/; fi
      err "apt-get update 失败，已恢复备份配置：$backup"; return 1
    fi
  else
    local repo_dir=/etc/yum.repos.d
    [[ -d $repo_dir ]] || { err "找不到 $repo_dir。"; return 1; }
    command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || { err '找不到 dnf/yum。'; return 1; }
    cp -a "$repo_dir" "$backup/yum.repos.d" || { err 'YUM/DNF 配置备份失败。'; return 1; }
    # Switch only known upstream CentOS/RHEL mirror hosts, preserving repository paths and IDs.
    local old_hosts='mirror\.centos\.org|vault\.centos\.org|mirror\.stream\.centos\.org|download\.fedoraproject\.org|mirrors\.rockylinux\.org|repo\.almalinux\.org'
    local yum_root
    if [[ $mirror_host == mirrors.aliyun.com ]]; then yum_root=https://mirrors.aliyun.com; else yum_root=https://mirrors.cloud.tencent.com; fi
    # CentOS 7/8 are EOL: replacing only the hostname leaves obsolete mirrorlist
    # and release paths. Use the mirror providers' complete legacy repo files.
    local major=${version%%.*} repo_url repo_tmp repo_target
    if [[ $distro == centos && ( $major == 7 || $major == 8 ) ]]; then
      if [[ $major == 7 ]]; then
        if [[ $mirror_host == mirrors.aliyun.com ]]; then
          repo_url=https://mirrors.aliyun.com/repo/Centos-7.repo
        else
          repo_url=https://mirrors.tencent.com/repo/centos7_base.repo
        fi
      else
        if [[ $mirror_host == mirrors.aliyun.com ]]; then
          repo_url=https://mirrors.aliyun.com/repo/Centos-vault-8.5.2111.repo
        else
          repo_url=https://mirrors.tencent.com/repo/centos8_base.repo
        fi
      fi
      repo_target="$repo_dir/CentOS-Base.repo"
      repo_tmp=$(mktemp "$repo_dir/.CentOS-Base.repo.peachtools.XXXXXX") || return 1
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 8 --max-time 60 "$repo_url" -o "$repo_tmp"
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$repo_tmp" "$repo_url"
      else
        rm -f "$repo_tmp"; err '下载仓库配置需要 curl 或 wget。'; return 1
      fi
      if (($? != 0)) || ! grep -q '^\[' "$repo_tmp"; then
        rm -f "$repo_tmp"; err "无法从镜像站获取有效的 CentOS $major 仓库配置：$repo_url"; return 1
      fi
      chmod --reference="$repo_target" "$repo_tmp" 2>/dev/null || chmod 644 "$repo_tmp"
      if ! mv -f "$repo_tmp" "$repo_target"; then rm -f "$repo_tmp"; err '安装仓库配置失败。'; return 1; fi
      changed=1
    fi
    for file in "$repo_dir"/*.repo; do
      [[ -f $file ]] || continue
      # Legacy CentOS base repo was replaced with a complete provider template above.
      [[ $distro == centos && ( $major == 7 || $major == 8 ) && $file == "$repo_target" ]] && continue
      grep -Eq "$old_hosts" "$file" || continue
      tmp=$(mktemp "${file}.peachtools.XXXXXX") || return 1
      cp -p "$file" "$tmp" || { rm -f "$tmp"; return 1; }
      sed -i -E "s#https?://(mirror|vault)\\.centos\\.org#${yum_root}/centos#g; s#https?://mirror\\.stream\\.centos\\.org#${yum_root}/centos-stream#g; s#https?://download\\.fedoraproject\\.org/pub/epel#${yum_root}/epel#g; s#https?://mirrors\\.rockylinux\\.org#${yum_root}/rocky#g; s#https?://repo\\.almalinux\\.org#${yum_root}/almalinux#g" "$tmp"
      if ! cmp -s "$file" "$tmp"; then mv -f "$tmp" "$file" || return 1; ((changed+=1)); else rm -f "$tmp"; fi
    done
    if ((changed == 0)); then err '未找到已知官方仓库地址，配置未改动。该系统可能使用了厂商定制源。'; return 1; fi
    echo "已备份原配置：$backup"
    if command -v dnf >/dev/null 2>&1; then dnf clean all && dnf makecache; else yum clean all && yum makecache; fi
    if (($? == 0)); then echo '完成：YUM/DNF 官方软件源已切换并刷新缓存。'; else
      rm -rf "$repo_dir"; cp -a "$backup/yum.repos.d" "$repo_dir"
      err "仓库缓存刷新失败，已恢复备份配置：$backup"; return 1
    fi
  fi
}

install_ookla_speedtest() {
  local installer installer_url manager
  if ((EUID != 0)); then err '安装 Ookla Speedtest CLI 需要 root 权限。'; return 1; fi
  if command -v apt-get >/dev/null 2>&1; then
    installer_url=https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh
    manager=apt
  elif command -v dnf >/dev/null 2>&1; then
    installer_url=https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh
    manager=dnf
  elif command -v yum >/dev/null 2>&1; then
    installer_url=https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh
    manager=yum
  else
    err '未识别 apt/dnf/yum，无法安装 Ookla Speedtest CLI。'; return 1
  fi
  installer=$(mktemp) || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 8 --max-time 60 "$installer_url" -o "$installer"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$installer" "$installer_url"
  else
    rm -f "$installer"; err '安装 Ookla Speedtest CLI 需要 curl 或 wget。'; return 1
  fi
  if (($? != 0)) || ! head -n 1 "$installer" | grep -q '^#!/'; then
    rm -f "$installer"; err '未能下载有效的 Ookla 软件源安装脚本。'; return 1
  fi
  echo '未检测到 speedtest，正在添加 Ookla 官方软件源并安装客户端…'
  if ! bash "$installer"; then rm -f "$installer"; err 'Ookla 软件源配置失败。'; return 1; fi
  rm -f "$installer"
  case "$manager" in
    apt) apt-get update && apt-get install -y speedtest ;;
    dnf) dnf install -y speedtest ;;
    yum) yum install -y speedtest ;;
  esac
}

speed_test() {
  local speedtest_bin
  if ((EUID != 0)); then err '带宽测试功能需要 root 运行，以便自动安装测试客户端。'; return 1; fi
  speedtest_bin=$(command -v speedtest 2>/dev/null || true)
  if [[ -z $speedtest_bin ]]; then
    if command -v speedtest-cli >/dev/null 2>&1; then
      speedtest_bin=$(command -v speedtest-cli)
      echo '使用系统中已有的 speedtest-cli，自动选择低延迟测试节点。'
      "$speedtest_bin" --secure
      return $?
    fi
    install_ookla_speedtest || return 1
    speedtest_bin=$(command -v speedtest 2>/dev/null || true)
  fi
  [[ -n $speedtest_bin ]] || { err '安装完成后仍找不到 speedtest 命令。'; return 1; }
  printf '开始测速：Ookla 将自动选择低延迟节点，并测试下载、上传及延迟。\n'
  printf '测速会产生实际网络流量，期间结果会受线路负载和目标节点影响。\n\n'
  "$speedtest_bin" --accept-license --accept-gdpr
}

if [[ ${1:-} == --speed-test ]]; then
  speed_test
  exit $?
fi

if [[ ${1:-} == --mirror-source ]]; then
  switch_mirrors
  exit $?
fi

if [[ ${1:-} == --route-test ]]; then
  route_test
  exit $?
fi

if [[ ${1:-} != --batch-ip ]]; then
  while true; do
    cat <<'EOF'

========== Peach Tools ==========
1. 批量添加 IP
2. 中国大陆三网路由检测
3. 测试下载/上传带宽（自动选择就近节点）
4. 切换软件源（自动检测可用源）
5. 退出
===================================
EOF
    read -r -p '请选择功能 [1-5]: ' choice || exit 0
    case "$choice" in
      1) bash "$0" --batch-ip ;;
      2) bash "$0" --route-test ;;
      3) bash "$0" --speed-test ;;
      4) bash "$0" --mirror-source ;;
      5|q|Q|exit|EXIT) exit 0 ;;
      *) echo '选项无效，请输入 1、2、3、4 或 5。' ;;
    esac
  done
fi

if (( EUID != 0 )); then
  err '请使用 root 运行：bash peachtools.sh'
  exit 1
fi
command -v ip >/dev/null 2>&1 || { err '系统缺少 ip 命令（iproute/iproute2）。'; exit 1; }

# 识别系统版本
os_name=Linux
os_version=''
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  os_name=${PRETTY_NAME:-${NAME:-Linux}}
  os_version=${VERSION_ID:-}
elif [[ -r /etc/redhat-release ]]; then
  os_name=$(cat /etc/redhat-release)
fi

# 优先选择默认路由使用的网卡，允许用户确认或改选
iface=$(ip -o -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')
if [[ -z $iface ]]; then
  iface=$(ip -o link show | awk -F': ' '$2 != "lo" {sub(/@.*/, "", $2); print $2; exit}')
fi
if [[ -z $iface ]]; then err '没有找到可用网卡。'; exit 1; fi
printf '系统：%s' "$os_name"
[[ -n $os_version ]] && printf '（版本 %s）' "$os_version"
printf '\n自动选择网卡：%s\n' "$iface"
read -r -p '网卡名称（直接回车使用以上网卡）: ' selected
[[ -n $selected ]] && iface=$selected
ip link show dev "$iface" >/dev/null 2>&1 || { err "找不到网卡 $iface。"; exit 1; }

# 没输入前缀的 IP 沿用该网卡当前全局 IPv4 前缀
base_prefix=$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[2]}')
if [[ ! $base_prefix =~ ^[0-9]+$ ]]; then
  read -r -p '网卡没有 IPv4 地址，请输入新 IP 默认使用的前缀（例如 24）: ' base_prefix
fi
[[ $base_prefix =~ ^[0-9]+$ ]] && ((base_prefix <= 32)) || { err '无法确定有效的 IPv4 前缀。'; exit 1; }

mask_to_prefix() {
  awk -v mask="$1" 'BEGIN {
    n=split(mask,o,"."); if(n!=4) exit 1
    zeros=0; count=0
    for(i=1;i<=4;i++) {
      if(o[i] !~ /^[0-9]+$/ || o[i]<0 || o[i]>255) exit 1
      v=o[i]+0
      for(bit=7;bit>=0;bit--) {
        one=int(v/(2^bit))%2
        if(one) { if(zeros) exit 1; count++ } else zeros=1
      }
    }
    print count
  }'
}

normalize_ip() {
  local value=$1 addr suffix prefix
  if [[ $value == */* ]]; then
    addr=${value%/*}; suffix=${value#*/}
    if [[ $suffix =~ ^[0-9]+$ ]]; then
      prefix=$suffix
      ((prefix <= 32)) || return 1
    else
      prefix=$(mask_to_prefix "$suffix") || return 1
    fi
  else
    addr=$value; prefix=$base_prefix
  fi
  awk -v a="$addr" 'BEGIN {n=split(a,o,"."); if(n!=4) exit 1; for(i=1;i<=4;i++) if(o[i]!~/^[0-9]+$/ || o[i]<0 || o[i]>255) exit 1}' || return 1
  printf '%s/%s' "$addr" "$prefix"
}

read_ifcfg_value() {
  awk -F= -v key="$2" '$1==key {v=$2; gsub(/["[:space:]]/, "", v); print v; exit}' "$1"
}

is_simple_ifcfg_alias() {
  awk -F= '
    /^[[:space:]]*($|#)/ {next}
    {key=$1; gsub(/[[:space:]]/, "", key); if(key !~ /^(DEVICE|BOOTPROTO|ONBOOT|IPADDR|PREFIX|NETMASK)$/) bad=1}
    END {exit bad+0}
  ' "$1"
}

printf '\n请粘贴要添加的 IPv4 地址，每行一个；支持 IP、IP/前缀、IP/子网掩码和末段范围。\n'
printf '纯 IP 使用默认前缀 /%s。每行一个地址；输入 q 结束并确认添加。\n' "$base_prefix"
printf '示例：\n  192.168.1.24\n  192.168.1.25/24\n  192.168.1.26/255.255.255.0\n  123.123.10.2-30/27\n\n'
addresses=()
input_confirmed=0
while IFS= read -r line; do
  line=${line//$'\r'/}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z $line ]] && continue
  if [[ $line == q || $line == Q ]]; then input_confirmed=1; break; fi
  candidates=()
  if [[ $line =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.([0-9]{1,3})-([0-9]{1,3})(/[^/]+)?$ ]]; then
    range_base=${BASH_REMATCH[1]}
    range_start=$((10#${BASH_REMATCH[2]}))
    range_end=$((10#${BASH_REMATCH[3]}))
    range_suffix=${BASH_REMATCH[4]:-}
    if ((range_start > 255 || range_end > 255 || range_start > range_end)); then
      err "末段范围无效：$line"; exit 1
    fi
    for ((octet=range_start; octet<=range_end; octet++)); do candidates+=("$range_base.$octet$range_suffix"); done
  else
    candidates+=("$line")
  fi

  for candidate in "${candidates[@]}"; do
    if ! normalized=$(normalize_ip "$candidate"); then
      err "地址格式无效：$line（范围格式示例 123.123.10.2-30/27）"; exit 1
    fi
    duplicate=0
    for existing in "${addresses[@]}"; do [[ ${existing%/*} == ${normalized%/*} ]] && duplicate=1; done
    if (( duplicate )); then printf '跳过重复地址：%s\n' "$normalized"; continue; fi
    if ip -o -4 addr show dev "$iface" | awk -v a="${normalized%/*}" '{split($4,x,"/"); if(x[1]==a) found=1} END{exit !found}'; then
      printf '跳过已配置地址：%s\n' "$normalized"; continue
    fi
    addresses+=("$normalized")
  done
done

if ((input_confirmed == 0)); then
  echo '未输入 q 确认，已取消；系统未修改。'
  exit 0
fi

if ((${#addresses[@]} == 0)); then echo '没有需要添加的新 IP，未修改配置。'; exit 0; fi
printf '\n将添加到网卡 %s：\n' "$iface"
printf '  %s\n' "${addresses[@]}"
printf '\n收到 q，确认添加以上 IP。程序将写入永久配置并重启网络连接；远程 SSH 会话可能短暂中断。\n'

# NetworkManager：将新地址追加到活动连接配置，再重新激活该连接
nm_connection=''
if command -v nmcli >/dev/null 2>&1; then
  nm_connection=$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -n 1 || true)
  [[ $nm_connection == '--' ]] && nm_connection=''
fi
if [[ -n $nm_connection ]]; then
  # Migrate simple alias files created by older versions into the active profile.
  nm_alias_files=()
  nm_alias_addresses=()
  nm_cfg_dir=/etc/sysconfig/network-scripts
  for alias_cfg in "$nm_cfg_dir/ifcfg-$iface:"*; do
    [[ -f $alias_cfg ]] || continue
    is_simple_ifcfg_alias "$alias_cfg" || continue
    alias_ip=$(read_ifcfg_value "$alias_cfg" IPADDR)
    alias_prefix=$(read_ifcfg_value "$alias_cfg" PREFIX)
    if [[ -z $alias_prefix ]]; then
      alias_mask=$(read_ifcfg_value "$alias_cfg" NETMASK)
      [[ -n $alias_mask ]] && alias_prefix=$(mask_to_prefix "$alias_mask" 2>/dev/null || true)
    fi
    [[ -n $alias_prefix ]] || alias_prefix=$base_prefix
    if [[ -n $alias_ip ]] && alias_address=$(normalize_ip "$alias_ip/$alias_prefix" 2>/dev/null); then
      nm_alias_files+=("$alias_cfg")
      nm_alias_addresses+=("$alias_address")
    fi
  done
  for a in "${nm_alias_addresses[@]}"; do
    duplicate=0
    for existing in "${addresses[@]}"; do [[ ${existing%/*} == ${a%/*} ]] && duplicate=1; done
    ((duplicate)) || addresses+=("$a")
  done

  original_raw=$(nmcli -g ipv4.addresses connection show "$nm_connection" 2>/dev/null | tr ',' '\n' || true)
  mapfile -t original < <(printf '%s\n' "$original_raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')
  desired=()
  for a in "${original[@]}"; do desired+=("$a"); done
  for a in "${addresses[@]}"; do
    already=0
    for old_addr in "${desired[@]}"; do [[ ${old_addr%/*} == ${a%/*} ]] && already=1; done
    ((already)) || desired+=("$a")
  done
  saved_ifs=$IFS; IFS=,; desired_csv="${desired[*]}"; original_csv="${original[*]}"; IFS=$saved_ifs
  nm_alias_backup=''
  if ((${#nm_alias_files[@]})); then
    nm_alias_backup="/root/fastmos-ifcfg-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -m 700 "$nm_alias_backup" || { err '无法备份旧别名配置，未修改配置。'; exit 1; }
    for alias_cfg in "${nm_alias_files[@]}"; do
      cp -p "$alias_cfg" "$nm_alias_backup/" || { err '旧别名配置备份失败，未修改配置。'; exit 1; }
    done
  fi
  if ! nmcli connection modify "$nm_connection" ipv4.addresses "$desired_csv"; then
    err 'NetworkManager 写入配置失败。'; exit 1
  fi
  for alias_cfg in "${nm_alias_files[@]}"; do
    if ! rm -f -- "$alias_cfg"; then
      if ((${#original[@]})); then nmcli connection modify "$nm_connection" ipv4.addresses "$original_csv" >/dev/null 2>&1 || true
      else nmcli connection modify "$nm_connection" ipv4.addresses '' >/dev/null 2>&1 || true
      fi
      for restore_cfg in "${nm_alias_files[@]}"; do cp -p "$nm_alias_backup/$(basename "$restore_cfg")" "$restore_cfg" || true; done
      err "旧别名配置迁移失败；已尝试回滚。备份：$nm_alias_backup"; exit 1
    fi
  done
  if ! nmcli connection up "$nm_connection" ifname "$iface"; then
    if ((${#original[@]})); then nmcli connection modify "$nm_connection" ipv4.addresses "$original_csv" >/dev/null 2>&1 || true
    else nmcli connection modify "$nm_connection" ipv4.addresses '' >/dev/null 2>&1 || true
    fi
    for alias_cfg in "${nm_alias_files[@]}"; do cp -p "$nm_alias_backup/$(basename "$alias_cfg")" "$alias_cfg" || true; done
    err '连接重启失败，已尝试恢复原 IP 配置；请检查网络状态。'; exit 1
  fi
  echo '完成：IP 已写入单个 NetworkManager 连接配置并重新激活连接。'
  if ((${#nm_alias_files[@]})); then echo "已合并 $(( ${#nm_alias_files[@]} )) 个旧别名文件，备份目录：$nm_alias_backup"; fi
  exit 0
fi

# Netplan（Ubuntu 20/22/24 常见）：使用 netplan set 写入并应用 YAML 配置
if command -v netplan >/dev/null 2>&1 && compgen -G '/etc/netplan/*.yaml' >/dev/null; then
  if ! netplan get "ethernets.$iface" >/dev/null 2>&1; then
    err "Netplan 中找不到 ethernets.$iface 配置项；请核对网卡名称与 YAML 配置。"; exit 1
  fi
  existing_yaml=$(netplan get "ethernets.$iface.addresses" 2>/dev/null || true)
  desired=()
  while IFS= read -r item; do
    item=${item#-}; item=${item#"${item%%[![:space:]]*}"}; item=${item%"${item##*[![:space:]]}"}; item=${item#\"}; item=${item%\"}
    [[ -n $item && $item != "[]" && $item != "null" && $item != "~" ]] && desired+=("$item")
  done <<< "$existing_yaml"
  for a in "${addresses[@]}"; do
    already=0
    for old_addr in "${desired[@]}"; do [[ ${old_addr%/*} == ${a%/*} ]] && already=1; done
    ((already)) || desired+=("$a")
  done
  ((${#desired[@]})) || { err '无法读取现有 Netplan 地址配置，已停止以免覆盖配置。'; exit 1; }
  IFS=,; desired_csv="${desired[*]}"; unset IFS
  if ! netplan set "ethernets.$iface.addresses=[$desired_csv]" || ! netplan generate; then
    err 'Netplan 配置写入或校验失败；请检查 /etc/netplan。'; exit 1
  fi
  if netplan apply; then
    echo '完成：IP 已写入 Netplan 配置并应用。'
  else
    err 'Netplan apply 失败；配置已写入，请检查 netplan 状态。'; exit 1
  fi
  exit 0
fi
# 传统 CentOS/RHEL network-scripts：把所有附加地址写进主网卡配置文件
cfg_dir=/etc/sysconfig/network-scripts
cfg="$cfg_dir/ifcfg-$iface"
if [[ -d $cfg_dir && -f $cfg ]]; then
  config_has_ip() {
    local wanted=$1 file
    for file in "$cfg" "$cfg_dir/ifcfg-$iface:"*; do
      [[ -f $file ]] || continue
      if awk -F= -v wanted="$wanted" '$1 ~ /^IPADDR[0-9]*$/ {v=$2; gsub(/["[:space:]]/, "", v); if(v==wanted) found=1} END{exit !found}' "$file"; then
        return 0
      fi
    done
    return 1
  }

  # Import the simple alias files produced by older versions into the main file.
  alias_cfgs=()
  alias_addresses=()
  for alias_cfg in "$cfg_dir/ifcfg-$iface:"*; do
    [[ -f $alias_cfg ]] || continue
    # Only migrate the simple alias files generated by this tool; leave custom configs untouched.
    is_simple_ifcfg_alias "$alias_cfg" || continue
    alias_ip=$(read_ifcfg_value "$alias_cfg" IPADDR)
    alias_prefix=$(read_ifcfg_value "$alias_cfg" PREFIX)
    if [[ -z $alias_prefix ]]; then
      alias_mask=$(read_ifcfg_value "$alias_cfg" NETMASK)
      [[ -n $alias_mask ]] && alias_prefix=$(mask_to_prefix "$alias_mask" 2>/dev/null || true)
    fi
    [[ -n $alias_prefix ]] || alias_prefix=$base_prefix
    if [[ -n $alias_ip ]] && alias_address=$(normalize_ip "$alias_ip/$alias_prefix" 2>/dev/null); then
      alias_cfgs+=("$alias_cfg")
      alias_addresses+=("$alias_address")
    fi
  done

  additions=()
  # Keep addresses from recognized alias files, then add the user's new entries.
  for a in "${alias_addresses[@]}"; do
    addr=${a%/*}
    already_in_main=$(awk -F= -v wanted="$addr" '$1 ~ /^IPADDR[0-9]*$/ {v=$2; gsub(/["[:space:]]/, "", v); if(v==wanted) found=1} END{print found+0}' "$cfg")
    duplicate=0
    for existing in "${additions[@]}"; do [[ ${existing%/*} == "$addr" ]] && duplicate=1; done
    if [[ $already_in_main == 0 ]] && ((duplicate == 0)); then additions+=("$a"); fi
  done
  for a in "${addresses[@]}"; do
    addr=${a%/*}; prefix=${a#*/}
    duplicate=0
    for existing in "${additions[@]}"; do [[ ${existing%/*} == "$addr" ]] && duplicate=1; done
    if ! config_has_ip "$addr" && ((duplicate == 0)); then additions+=("$addr/$prefix"); fi
  done

  if ((${#additions[@]} == 0)); then
    echo '这些 IP 已存在于网卡配置中，无需重复写入。'; exit 0
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files network.service >/dev/null 2>&1; then
    restart_cmd=(systemctl restart network)
  elif command -v service >/dev/null 2>&1; then
    restart_cmd=(service network restart)
  else
    err '找不到 network 服务，未修改任何配置。'; exit 1
  fi

  backup_dir="/root/fastmos-ifcfg-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -m 700 "$backup_dir" || { err '无法创建配置备份目录。'; exit 1; }
  cp -p "$cfg" "$backup_dir/" || { err '主网卡配置备份失败，未修改配置。'; exit 1; }
  for alias_cfg in "${alias_cfgs[@]}"; do
    cp -p "$alias_cfg" "$backup_dir/" || { err '旧别名配置备份失败，未修改配置。'; exit 1; }
  done
  tmp_cfg=$(mktemp "$cfg_dir/.fastmos-ifcfg.XXXXXX") || { err '无法创建临时配置文件。'; exit 1; }
  if ! cp -p "$cfg" "$tmp_cfg"; then rm -f -- "$tmp_cfg"; err '复制主网卡配置失败。'; exit 1; fi

  address_id=1
  for a in "${additions[@]}"; do
    while grep -Eq "^[[:space:]]*(IPADDR|PREFIX)${address_id}=" "$tmp_cfg"; do ((address_id+=1)); done
    addr=${a%/*}; prefix=${a#*/}
    if ! printf 'IPADDR%s="%s"\nPREFIX%s="%s"\n' "$address_id" "$addr" "$address_id" "$prefix" >> "$tmp_cfg"; then
      rm -f -- "$tmp_cfg"; err '写入主网卡配置失败，原配置未修改。'; exit 1
    fi
    ((address_id+=1))
  done
  if ! mv -f -- "$tmp_cfg" "$cfg"; then rm -f -- "$tmp_cfg"; err '替换主网卡配置失败。'; exit 1; fi
  for alias_cfg in "${alias_cfgs[@]}"; do
    if ! rm -f -- "$alias_cfg"; then
      cp -p "$backup_dir/$(basename "$cfg")" "$cfg" || true
      for restore_cfg in "${alias_cfgs[@]}"; do cp -p "$backup_dir/$(basename "$restore_cfg")" "$restore_cfg" || true; done
      err "迁移旧别名配置失败；已尝试回滚。备份：$backup_dir"; exit 1
    fi
  done
  if "${restart_cmd[@]}"; then
    echo "完成：$(( ${#additions[@]} )) 个 IP 已写入主配置 $cfg，并重启 network 服务。"
    if ((${#alias_cfgs[@]})); then echo "已将 $(( ${#alias_cfgs[@]} )) 个旧别名配置合并到主文件。"; fi
    echo "回滚备份目录：$backup_dir"
  else
    cp -p "$backup_dir/$(basename "$cfg")" "$cfg" || true
    for alias_cfg in "${alias_cfgs[@]}"; do cp -p "$backup_dir/$(basename "$alias_cfg")" "$alias_cfg" || true; done
    err "network 服务重启失败；已尝试恢复原配置。备份：$backup_dir"
    exit 1
  fi
  exit 0
fi

# Debian ifupdown：通过 if-up.d hook 在网卡每次启动后恢复附加地址
if command -v ifup >/dev/null 2>&1 && command -v ifquery >/dev/null 2>&1 && [[ -r /etc/network/interfaces ]] && ifquery "$iface" >/dev/null 2>&1; then
  hook_dir=/etc/network/if-up.d
  hook="$hook_dir/fastmos-batch-ip-$iface"
  mkdir -p "$hook_dir" || { err '无法创建 if-up.d 目录。'; exit 1; }
  saved_ips=()
  if [[ -f $hook ]]; then mapfile -t saved_ips < <(sed -n 's/^# FASTMOS_IP=//p' "$hook"); fi
  desired=("${saved_ips[@]}")
  for a in "${addresses[@]}"; do
    already=0
    for old_addr in "${desired[@]}"; do [[ ${old_addr%/*} == ${a%/*} ]] && already=1; done
    ((already)) || desired+=("$a")
  done
  tmp_hook=$(mktemp "$hook_dir/.fastmos-ip.XXXXXX") || { err '无法创建网卡启动脚本。'; exit 1; }
  {
    printf '#!/bin/sh\n[ "${IFACE:-}" = %q ] || exit 0\n' "$iface"
    for a in "${desired[@]}"; do printf '# FASTMOS_IP=%s\n' "$a"; done
    printf 'for addr in'
    for a in "${desired[@]}"; do printf ' %q' "$a"; done
    printf '; do ip -4 addr replace "$addr" dev "$IFACE" || exit 1; done\n'
  } > "$tmp_hook"
  chmod 755 "$tmp_hook" && mv -f -- "$tmp_hook" "$hook" || { rm -f -- "$tmp_hook"; err '保存 if-up.d 配置失败。'; exit 1; }
  if ifdown --force "$iface" && ifup "$iface"; then
    echo '完成：IP 已加入 Debian ifupdown 启动钩子并重新启动网卡。'
  else
    err '网卡重启失败；持久配置已保存，请在本机控制台检查网络。'; exit 1
  fi
  exit 0
fi
err '未识别到可安全修改的受支持网络配置（NetworkManager、Netplan、network-scripts 或 Debian ifupdown）；系统未作修改。'
exit 1
